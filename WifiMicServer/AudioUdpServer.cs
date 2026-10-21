using System;
using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace WifiMicServer;

public sealed class AudioUdpServer : IDisposable
{
    private const ushort MagicMarker = 0x4D57; // 0x57, 0x4D in little-endian
    public const int DefaultPort = 45456;

    private Socket? _socket;
    private CancellationTokenSource? _cts;
    private byte[] _tokenBytesLE = new byte[16];
    private byte[] _tokenBytesBE = new byte[16];

    private uint _expectedSeqNum;
    private bool _isFirstPacket = true;
    private Guid _sessionToken;

    public int Port { get; }

    public Guid SessionToken
    {
        get => _sessionToken;
        set
        {
            _sessionToken = value;
            _tokenBytesLE = value.ToByteArray();
            _tokenBytesBE = value.ToByteArray(bigEndian: true);
            _isFirstPacket = true;
        }
    }

    public event Action<uint, ReadOnlyMemory<byte>>? OnAudioReceived;
    public event Action<uint, uint>? OnPacketLoss;

    public AudioUdpServer(int port = DefaultPort, Guid? sessionToken = null)
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

        _isFirstPacket = true;
        _expectedSeqNum = 0;

        _cts = new CancellationTokenSource();
        _socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp)
        {
            ReceiveBufferSize = 2 * 1024 * 1024 // 2MB buffer
        };

        _socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);

        // Disable SIO_UDP_CONNRESET on Windows so ICMP unreachable does not kill async UDP receive loop
        try
        {
            const int SIO_UDP_CONNRESET = -1744830452; // 0x9800000C
            _socket.IOControl(SIO_UDP_CONNRESET, new byte[] { 0, 0, 0, 0 }, null);
        }
        catch { }

        _socket.Bind(new IPEndPoint(IPAddress.Any, Port));

        Task.Run(() => ReceiveLoop(_cts.Token));
    }

    public void ResetState()
    {
        _isFirstPacket = true;
        _expectedSeqNum = 0;
    }

    private async Task ReceiveLoop(CancellationToken ct)
    {
        byte[] buffer = new byte[4096];
        EndPoint remoteEp = new IPEndPoint(IPAddress.Any, 0);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var res = await _socket!.ReceiveFromAsync(buffer.AsMemory(), SocketFlags.None, remoteEp, ct);
                if (res.ReceivedBytes < 25) continue;

                ProcessPacket(buffer, res.ReceivedBytes);
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (SocketException ex) when (ex.SocketErrorCode == SocketError.ConnectionReset)
            {
                // Normal transient UDP reset on Windows when remote endpoint closes
                continue;
            }
            catch { }
        }
    }

    private long _packetsReceived = 0;

    private void ProcessPacket(byte[] buffer, int receivedBytes)
    {
        ReadOnlySpan<byte> span = buffer.AsSpan(0, receivedBytes);

        // Validate magic: 0x57, 0x4D (0x4D57 uint16 LE)
        if (BinaryPrimitives.ReadUInt16LittleEndian(span[0..2]) != MagicMarker)
            return;

        if (Interlocked.Increment(ref _packetsReceived) == 1)
        {
            App.Log($"[UDP] Received first audio packet ({receivedBytes} bytes)");
        }

        byte version = span[2];
        int headerSize;
        uint seqNum;
        ReadOnlySpan<byte> tokenSpan;
        ushort payloadLength;

        if (version == 0x02)
        {
            if (receivedBytes < 26) return;
            headerSize = 26;
            seqNum = BinaryPrimitives.ReadUInt32LittleEndian(span[3..7]);
            tokenSpan = span.Slice(7, 16);
            byte codec = span[23]; // 0x01 = PCM 16-bit LE
            payloadLength = BinaryPrimitives.ReadUInt16LittleEndian(span[24..26]);
        }
        else if (version == 0x01)
        {
            headerSize = 25;
            seqNum = BinaryPrimitives.ReadUInt32LittleEndian(span[3..7]);
            tokenSpan = span.Slice(7, 16);
            payloadLength = BinaryPrimitives.ReadUInt16LittleEndian(span[23..25]);
        }
        else
        {
            return;
        }

        // Validate payload length
        if (receivedBytes < headerSize + payloadLength)
            return;

        // Sequence number and gap detection
        if (_isFirstPacket)
        {
            _isFirstPacket = false;
            _expectedSeqNum = seqNum + 1;
        }
        else
        {
            if (seqNum != _expectedSeqNum)
            {
                uint diff = seqNum - _expectedSeqNum;
                // If seqNum is ahead (taking uint32 wrap-around into account)
                if (diff > 0 && diff < 0x80000000)
                {
                    OnPacketLoss?.Invoke(_expectedSeqNum, seqNum);
                }
            }
            _expectedSeqNum = seqNum + 1;
        }

        OnAudioReceived?.Invoke(seqNum, buffer.AsMemory(headerSize, payloadLength));
    }

    public void Stop()
    {
        _cts?.Cancel();
        _cts?.Dispose();
        _cts = null;

        if (_socket != null)
        {
            try
            {
                _socket.Close();
                _socket.Dispose();
            }
            catch { }
            _socket = null;
        }

        _isFirstPacket = true;
        _expectedSeqNum = 0;
    }

    public void Dispose()
    {
        Stop();
    }
}
