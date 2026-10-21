using System;
using System.Buffers.Binary;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using NAudio.CoreAudioApi;
using QRCoder;
using Forms = System.Windows.Forms;
using Color = System.Windows.Media.Color;
using Application = System.Windows.Application;
using MessageBox = System.Windows.MessageBox;

namespace WifiMicServer;

public partial class MainWindow : Window
{
    private enum StatusState
    {
        Waiting,
        Connected,
        Error,
        Stopped
    }

    private TcpControlServer? _tcpServer;
    private AudioUdpServer? _udpServer;
    private readonly AudioPlaybackBridge _bridge = new();
    private Forms.NotifyIcon? _notifyIcon;
    private bool _isExplicitExit;

    private Guid _sessionToken;
    private bool _isServerRunning;
    private string _localIp = "127.0.0.1";
    private DateTime _lastVu = DateTime.MinValue;

    public MainWindow()
    {
        App.Log("MainWindow constructor enter");
        InitializeComponent();
        App.Log("MainWindow InitializeComponent done");
        Loaded += OnLoaded;
        Closing += MainWindow_Closing;
        Closed += (_, _) => Cleanup();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        App.Log("MainWindow OnLoaded enter");
        try
        {
            try
            {
                string icoPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "app.ico");
                if (File.Exists(icoPath))
                {
                    Icon = BitmapFrame.Create(new Uri(icoPath, UriKind.Absolute));
                }
            }
            catch { }

            SetupTrayIcon();
            App.Log("SetupTrayIcon done");

            App.Log("Step 1: Network");
            _localIp = NetworkHelper.GetLocalIPv4();
            string hostName = NetworkHelper.GetComputerName();
            HostInfoLabel.Text = $"ПК: {hostName}  •  IP: {_localIp}";
            App.Log($"Network done: {_localIp}");

            // 2. Automatically bind to VB-CABLE Input
            App.Log("Step 2: FindVbCable");
            var vbCable = _bridge.FindVbCable();
            if (vbCable != null)
            {
                App.Log($"Found VbCable: {vbCable.FriendlyName}, starting bridge");
                _bridge.Start(vbCable);
                MicStatusLabel.Text = "CABLE Output (VB-Audio Virtual Cable)";
                MicStatusLabel.Foreground = new SolidColorBrush(Color.FromRgb(56, 189, 248));
            }
            else
            {
                App.Log("VbCable not found, fallback");
                var fallback = _bridge.GetOutputDevices().FirstOrDefault();
                if (fallback != null)
                {
                    _bridge.Start(fallback);
                }
                MicStatusLabel.Text = "VB-CABLE не найден! Установите VB-CABLE";
                MicStatusLabel.Foreground = new SolidColorBrush(Color.FromRgb(239, 68, 68));
            }

            // 3. Initialize Audio DSP settings
            App.Log("Step 3: DSP settings");
            _bridge.Volume = (float)(VolumeSlider.Value / 100.0);
            _bridge.GainDb = (float)GainSlider.Value;
            _bridge.NoiseGateEnabled = NoiseGateCheck.IsChecked == true;

            // 4. Start Server automatically
            App.Log("Step 4: StartServer call");
            StartServer();
            App.Log("OnLoaded successfully completed!");
        }
        catch (Exception ex)
        {
            App.Log($"OnLoaded EXCEPTION: {ex}");
            ShowError($"Ошибка инициализации: {ex.Message}");
        }
    }

    private void SetupTrayIcon()
    {
        try
        {
            System.Drawing.Icon appIcon = System.Drawing.SystemIcons.Application;
            string icoPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "app.ico");
            if (File.Exists(icoPath))
            {
                try { appIcon = new System.Drawing.Icon(icoPath); } catch { }
            }

            _notifyIcon = new Forms.NotifyIcon
            {
                Icon = appIcon,
                Text = "Wi-Fi Microphone",
                Visible = true
            };

            var contextMenu = new Forms.ContextMenuStrip();

            var openItem = new Forms.ToolStripMenuItem("Открыть окно", null, (_, _) => RestoreFromTray());
            openItem.Font = new System.Drawing.Font(openItem.Font, System.Drawing.FontStyle.Bold);
            contextMenu.Items.Add(openItem);

            contextMenu.Items.Add(new Forms.ToolStripMenuItem("Отключить телефон", null, (_, _) =>
            {
                try { _tcpServer?.DisconnectClient(); } catch { }
            }));

            contextMenu.Items.Add(new Forms.ToolStripSeparator());

            contextMenu.Items.Add(new Forms.ToolStripMenuItem("Выход", null, (_, _) => ExitApplication()));

            _notifyIcon.ContextMenuStrip = contextMenu;
            _notifyIcon.DoubleClick += (_, _) => RestoreFromTray();
            _notifyIcon.MouseClick += (s, e) =>
            {
                if (e.Button == Forms.MouseButtons.Left)
                {
                    RestoreFromTray();
                }
            };
        }
        catch { }
    }

    private void MainWindow_Closing(object? sender, CancelEventArgs e)
    {
        if (!_isExplicitExit)
        {
            e.Cancel = true;
            Hide();
            try
            {
                _notifyIcon?.ShowBalloonTip(1500, "Wi-Fi Microphone", "Приложение работает в фоновом режиме (в трее).", Forms.ToolTipIcon.Info);
            }
            catch { }
        }
    }

    public void RestoreFromTray()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
    }

    public void ExitApplication()
    {
        _isExplicitExit = true;
        try
        {
            _notifyIcon?.Dispose();
            _notifyIcon = null;
        }
        catch { }
        Close();
        Application.Current.Shutdown();
    }


    private void StartServer()
    {
        try
        {
            ClearError();
            _sessionToken = Guid.NewGuid();

            // 1. Start UDP Server on 45456
            _udpServer?.Dispose();
            _udpServer = new AudioUdpServer(45456, _sessionToken);
            _udpServer.OnAudioReceived += (seqNum, data) =>
            {
                _bridge.EnqueueAudio(seqNum, data);
                UpdateVu(data);
            };
            _udpServer.Start();

            // 2. Start TCP Server on 45455
            _tcpServer?.Dispose();
            _tcpServer = new TcpControlServer(45455, _sessionToken);
            _tcpServer.OnClientConnected += clientName => Dispatcher.InvokeAsync(() =>
            {
                if (_tcpServer.SessionToken != Guid.Empty && _tcpServer.SessionToken != _sessionToken)
                {
                    _sessionToken = _tcpServer.SessionToken;
                    if (_udpServer != null)
                    {
                        _udpServer.SessionToken = _sessionToken;
                    }
                }

                _bridge.ResetState();
                _udpServer?.ResetState();

                SetStatus(StatusState.Connected, $"Подключен: {clientName}");
                DisconnectButton.IsEnabled = true;
            });

            _tcpServer.OnClientDisconnected += () => Dispatcher.InvokeAsync(() =>
            {
                _bridge.ResetState();
                _udpServer?.ResetState();

                SetStatus(StatusState.Waiting, "Ожидание подключения...");
                DisconnectButton.IsEnabled = false;
                LatencyLabel.Text = "-- мс";
                VuBar.Value = 0;
                VuLabel.Text = "0%";
            });

            _tcpServer.OnLatencyMeasured += ms => Dispatcher.InvokeAsync(() =>
            {
                LatencyLabel.Text = $"{ms:F0} мс";
            });

            _tcpServer.Start();

            // 3. Generate QR code
            string qrPayload = $"wifimic://{_localIp}:45455/{_sessionToken}";
            GenerateQrCode(qrPayload);

            // 4. Update UI
            _isServerRunning = true;
            IpPortLabel.Text = $"IP: {_localIp}  •  Порт: 45455";
            ServerToggleButton.Content = "Остановить сервер";
            ServerToggleButton.Background = new SolidColorBrush(Color.FromRgb(239, 68, 68)); // red
            SetStatus(StatusState.Waiting, "Ожидание подключения...");
        }
        catch (Exception ex)
        {
            ShowError($"Ошибка запуска сервера: {ex.Message}");
            SetStatus(StatusState.Error, "Ошибка запуска сервера");
        }
    }

    private void StopServer()
    {
        try
        {
            ClearError();

            if (_tcpServer != null)
            {
                _tcpServer.DisconnectClient();
                System.Threading.Thread.Sleep(50);
                _tcpServer.Stop();
                _tcpServer.Dispose();
                _tcpServer = null;
            }

            if (_udpServer != null)
            {
                _udpServer.Stop();
                _udpServer.Dispose();
                _udpServer = null;
            }

            _bridge.ResetState();

            _isServerRunning = false;
            QrImage.Source = null;
            ServerToggleButton.Content = "Запустить сервер";
            ServerToggleButton.Background = new SolidColorBrush(Color.FromRgb(16, 185, 129)); // green
            DisconnectButton.IsEnabled = false;
            SetStatus(StatusState.Stopped, "Сервер остановлен");

            LatencyLabel.Text = "-- мс";
            VuBar.Value = 0;
            VuLabel.Text = "0%";
        }
        catch (Exception ex)
        {
            ShowError($"Ошибка остановки сервера: {ex.Message}");
        }
    }

    private void GenerateQrCode(string payload)
    {
        using var qrGen = new QRCodeGenerator();
        using var qrData = qrGen.CreateQrCode(payload, QRCodeGenerator.ECCLevel.M);
        using var png = new PngByteQRCode(qrData);

        var bmp = new BitmapImage();
        using var ms = new MemoryStream(png.GetGraphic(20));
        bmp.BeginInit();
        bmp.CacheOption = BitmapCacheOption.OnLoad;
        bmp.StreamSource = ms;
        bmp.EndInit();
        bmp.Freeze();
        QrImage.Source = bmp;
    }

    private void UpdateVu(ReadOnlyMemory<byte> data)
    {
        if ((DateTime.UtcNow - _lastVu).TotalMilliseconds < 33) return;
        _lastVu = DateTime.UtcNow;

        var span = data.Span;
        int peak = 0;
        for (int i = 0; i < span.Length - 1; i += 2)
        {
            int val = Math.Abs((int)BinaryPrimitives.ReadInt16LittleEndian(span.Slice(i, 2)));
            if (val > peak) peak = val;
        }

        double pct = Math.Min(100.0, (peak / 32768.0) * 100.0);
        Dispatcher.InvokeAsync(() =>
        {
            VuBar.Value = pct;
            VuLabel.Text = $"{(int)pct}%";
        });
    }

    private void SetStatus(StatusState state, string message)
    {
        StatusLabel.Text = message;
        switch (state)
        {
            case StatusState.Connected:
                StatusDot.Fill = new SolidColorBrush(Color.FromRgb(16, 185, 129)); // green
                break;
            case StatusState.Waiting:
                StatusDot.Fill = new SolidColorBrush(Color.FromRgb(245, 158, 11)); // yellow
                break;
            case StatusState.Error:
                StatusDot.Fill = new SolidColorBrush(Color.FromRgb(239, 68, 68)); // red
                break;
            case StatusState.Stopped:
                StatusDot.Fill = new SolidColorBrush(Color.FromRgb(100, 116, 139)); // gray
                break;
        }
    }

    private void VolumeSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (VolumeLabel != null)
        {
            VolumeLabel.Text = $"{(int)e.NewValue}%";
            _bridge.Volume = (float)(e.NewValue / 100.0);
        }
    }

    private void GainSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (GainLabel != null)
        {
            GainLabel.Text = $"{(int)e.NewValue} dB";
            _bridge.GainDb = (float)e.NewValue;
        }
    }

    private void NoiseGateCheck_Changed(object sender, RoutedEventArgs e)
    {
        _bridge.NoiseGateEnabled = NoiseGateCheck.IsChecked == true;
    }

    private void ServerToggleButton_Click(object sender, RoutedEventArgs e)
    {
        if (_isServerRunning)
        {
            StopServer();
        }
        else
        {
            StartServer();
        }
    }

    private void DisconnectButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            _tcpServer?.DisconnectClient();
        }
        catch (Exception ex)
        {
            ShowError($"Ошибка отключения клиента: {ex.Message}");
        }
    }

    private void ShowError(string message)
    {
        Dispatcher.InvokeAsync(() =>
        {
            ErrorLabel.Text = message;
        });
    }

    private void ClearError()
    {
        ErrorLabel.Text = "";
    }

    private void Cleanup()
    {
        try { _bridge.Dispose(); } catch { }
        try { _tcpServer?.Dispose(); } catch { }
        try { _udpServer?.Dispose(); } catch { }
        try { _notifyIcon?.Dispose(); } catch { }
    }
}
