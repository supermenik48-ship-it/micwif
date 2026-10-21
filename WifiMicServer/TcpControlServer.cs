using System;
using System.Buffers.Binary;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace WifiMicServer;

public sealed class TcpControlServer : IDisposable
{
    public const int DefaultPort = 45455;
    public int Port { get; }
    public Guid SessionToken { get; set; }

    public event Action<string>? OnClientConnected;
    public event Action? OnClientDisconnected;
    public event Action<double>? OnLatencyMeasured;

    private TcpListener? _listener;
    private CancellationTokenSource? _cts;
    private readonly object _clientLock = new();

    private TcpClient? _activeClient;
    private NetworkStream? _activeStream;
    private SemaphoreSlim? _activeSendLock;
    private CancellationTokenSource? _clientCts;
    private DateTime _lastActivity = DateTime.UtcNow;
    private bool _isAuthenticated;

    public TcpControlServer(int port = DefaultPort, Guid? sessionToken = null)
    {
        Port = port;
        SessionToken = sessionToken ?? Guid.NewGuid();
    }

    public void Start(Guid? sessionToken = null)
    {
        Stop();

        if (sessionToken.HasValue)
        {
            SessionToken = sessionToken.Value;
        }

        _cts = new CancellationTokenSource();
        _listener = new TcpListener(IPAddress.Any, Port);
        _listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        _listener.Start();

        Task.Run(() => AcceptLoopAsync(_cts.Token));
    }

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var client = await _listener!.AcceptTcpClientAsync(ct);
                client.NoDelay = true;

                bool acceptNew = false;
                lock (_clientLock)
                {
                    // Cleanly close previous/lingering connection if any, and accept the new connection
                    CloseActiveClientInternal(false);
                    _activeClient = client;
                    _activeStream = client.GetStream();
                    _activeSendLock = new SemaphoreSlim(1, 1);
                    _clientCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                    _lastActivity = DateTime.UtcNow;
                    _isAuthenticated = false;
                    acceptNew = true;
                }

                if (acceptNew)
                {
                    _ = Task.Run(() => HandleClientAsync(client, _clientCts!.Token));
                }
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch { }
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken ct)
    {
        NetworkStream stream;
        SemaphoreSlim sendLock;

        lock (_clientLock)
        {
            if (_activeStream == null || _activeSendLock == null) return;
            stream = _activeStream;
            sendLock = _activeSendLock;
        }

        // Start keepalive and periodic ping monitor
        var monitorTask = Task.Run(() => ClientMonitorAsync(stream, sendLock, ct), ct);

        byte[] lengthBuffer = new byte[4];
        try
        {
            while (!ct.IsCancellationRequested && client.Connected)
            {
                bool ok = await ReadExactAsync(stream, lengthBuffer, 4, ct);
                if (!ok) break;

                uint payloadLength = BinaryPrimitives.ReadUInt32LittleEndian(lengthBuffer);
                if (payloadLength == 0 || payloadLength > 65536)
                {
                    // Invalid frame size
                    break;
                }

                byte[] payloadBuffer = new byte[payloadLength];
                ok = await ReadExactAsync(stream, payloadBuffer, (int)payloadLength, ct);
                if (!ok) break;

                _lastActivity = DateTime.UtcNow;

                using var doc = JsonDocument.Parse(payloadBuffer);
                var root = doc.RootElement;
                if (!root.TryGetProperty("type", out var typeEl)) continue;
                string type = typeEl.GetString() ?? "";

                if (type == "hello")
                {
                    string clientToken = root.TryGetProperty("token", out var tProp) ? tProp.GetString() ?? "" : "";
                    string clientName = root.TryGetProperty("clientName", out var cnProp) ? cnProp.GetString() ?? "iPhone" : "iPhone";

                    // Accept connection in local network
                    if (Guid.TryParse(clientToken, out var parsedGuid) && parsedGuid != Guid.Empty)
                    {
                        SessionToken = parsedGuid;
                    }
                    _isAuthenticated = true;
                    await SendMessageAsync(stream, sendLock, new
                    {
                        type = "welcome",
                        serverName = NetworkHelper.GetComputerName(),
                        sessionToken = SessionToken.ToString(),
                        udpPort = 45456,
                        sampleRate = 48000,
                        channels = 1,
                        bitDepth = 16,
                        codec = "pcm"
                    }, ct);

                    OnClientConnected?.Invoke(clientName);
                }
                else if (type == "ping")
                {
                    long ts = 0;
                    if (root.TryGetProperty("ts", out var tsEl))
                    {
                        if (tsEl.ValueKind == JsonValueKind.Number)
                            ts = tsEl.GetInt64();
                    }

                    await SendMessageAsync(stream, sendLock, new
                    {
                        type = "pong",
                        ts = ts,
                        serverTs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
                    }, ct);
                }
                else if (type == "pong")
                {
                    if (root.TryGetProperty("ts", out var tsEl) && tsEl.ValueKind == JsonValueKind.Number)
                    {
                        long sentTs = tsEl.GetInt64();
                        long now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                        double rtt = Math.Max(0, now - sentTs);
                        if (rtt < 10000)
                        {
                            OnLatencyMeasured?.Invoke(rtt);
                        }
                    }
                }
                else if (type == "bye")
                {
                    break;
                }
            }
        }
        catch (OperationCanceledException) { }
        catch { }
        finally
        {
            CloseActiveClient();
        }
    }

    private async Task ClientMonitorAsync(NetworkStream stream, SemaphoreSlim sendLock, CancellationToken ct)
    {
        int tick = 0;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(1000, ct);
                tick++;

                // Keepalive: if no message received for 10 seconds, disconnect
                if ((DateTime.UtcNow - _lastActivity).TotalSeconds > 10)
                {
                    CloseActiveClient();
                    break;
                }

                // Send ping every 3 seconds to measure round-trip latency
                if (tick % 3 == 0 && _isAuthenticated)
                {
                    await SendMessageAsync(stream, sendLock, new
                    {
                        type = "ping",
                        ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
                    }, ct);
                }
            }
            catch (OperationCanceledException) { break; }
            catch { break; }
        }
    }

    private static async Task<bool> ReadExactAsync(Stream stream, byte[] buffer, int count, CancellationToken ct)
    {
        int offset = 0;
        while (offset < count)
        {
            int read = await stream.ReadAsync(buffer.AsMemory(offset, count - offset), ct);
            if (read == 0) return false;
            offset += read;
        }
        return true;
    }

    private static async Task SendMessageAsync(Stream stream, SemaphoreSlim sendLock, object message, CancellationToken ct)
    {
        byte[] jsonBytes = JsonSerializer.SerializeToUtf8Bytes(message);
        byte[] lengthBytes = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(lengthBytes, (uint)jsonBytes.Length);

        await sendLock.WaitAsync(ct);
        try
        {
            await stream.WriteAsync(lengthBytes, ct);
            await stream.WriteAsync(jsonBytes, ct);
            await stream.FlushAsync(ct);
        }
        finally
        {
            sendLock.Release();
        }
    }

    public void DisconnectClient()
    {
        TcpClient? client;
        NetworkStream? stream;
        SemaphoreSlim? sendLock;

        lock (_clientLock)
        {
            client = _activeClient;
            stream = _activeStream;
            sendLock = _activeSendLock;
        }

        if (client == null || stream == null || sendLock == null)
            return;

        try
        {
            using var timeoutCts = new CancellationTokenSource(500);
            SendMessageAsync(stream, sendLock, new { type = "bye" }, timeoutCts.Token).GetAwaiter().GetResult();
            // Allow TCP stack to flush 'bye' packet across the network before disposing socket
            Thread.Sleep(150);
        }
        catch { }

        CloseActiveClient();
    }

    private void CloseActiveClient()
    {
        CloseActiveClientInternal(true);
    }

    private void CloseActiveClientInternal(bool notify)
    {
        TcpClient? client = null;
        bool wasAuthenticated = false;

        lock (_clientLock)
        {
            if (_activeClient != null)
            {
                client = _activeClient;
                _activeClient = null;

                _clientCts?.Cancel();
                _clientCts?.Dispose();
                _clientCts = null;

                _activeStream?.Dispose();
                _activeStream = null;

                _activeSendLock?.Dispose();
                _activeSendLock = null;

                wasAuthenticated = _isAuthenticated;
                _isAuthenticated = false;
            }
        }

        if (client != null)
        {
            try { client.Close(); client.Dispose(); } catch { }
            if (notify && wasAuthenticated)
            {
                OnClientDisconnected?.Invoke();
            }
        }
    }

    public void Stop()
    {
        _cts?.Cancel();
        _cts?.Dispose();
        _cts = null;

        CloseActiveClient();

        if (_listener != null)
        {
            try { _listener.Stop(); } catch { }
            _listener = null;
        }
    }

    public void Dispose()
    {
        Stop();
    }
}
