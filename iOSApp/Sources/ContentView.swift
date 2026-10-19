import SwiftUI
import AVFoundation

public struct ContentView: View {
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var audioStreamer = AudioStreamer()

    @State private var showingScanner: Bool = false
    @State private var showingManualEntry: Bool = false
    @State private var showingHelp: Bool = false

    @State private var lastConnection: (host: String, port: UInt16, token: UUID)? = ConnectionManager.lastSavedConnection

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Top Status Bar
                    statusBarHeader
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))

                    Divider()

                    // Main Content
                    ScrollView {
                        VStack(spacing: 20) {
                            if audioStreamer.permissionDenied {
                                micPermissionDeniedCard
                            }

                            switch connectionManager.connectionState {
                            case .disconnected:
                                disconnectedSection

                            case .connecting:
                                connectingSection(title: "Подключение к серверу...")

                            case .reconnecting(let attempt):
                                connectingSection(title: "Переподключение (попытка \(attempt)/5)...")

                            case .connected, .streaming:
                                connectedSection

                            case .error(let errorMsg):
                                errorSection(message: errorMsg)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Wi-Fi Mic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                }
            }
            .sheet(isPresented: $showingScanner) {
                ScannerView { host, port, token in
                    connectToServer(host: host, port: port, token: token)
                } onManualEntryRequested: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showingManualEntry = true
                    }
                }
            }
            .sheet(isPresented: $showingManualEntry) {
                ManualEntryView(
                    initialIp: lastConnection?.host ?? "",
                    initialPort: lastConnection?.port ?? 45455,
                    initialToken: lastConnection?.token.uuidString ?? ""
                ) { host, port, token in
                    connectToServer(host: host, port: port, token: token)
                }
            }
            .sheet(isPresented: $showingHelp) {
                OnboardingView {
                    showingHelp = false
                }
            }
            .onAppear {
                setupBinding()
                refreshLastConnection()
                if audioStreamer.isMicrophoneDenied {
                    audioStreamer.permissionDenied = true
                }
            }
            .onChange(of: connectionManager.connectionState) { _ in
                refreshLastConnection()
            }
        }
    }

    // MARK: - Setup
    private func setupBinding() {
        connectionManager.audioStreamer = audioStreamer
        audioStreamer.connectionManager = connectionManager
    }

    private func refreshLastConnection() {
        lastConnection = ConnectionManager.lastSavedConnection
    }

    private func connectToServer(host: String, port: UInt16, token: UUID) {
        connectionManager.connect(host: host, port: port, token: token)
        refreshLastConnection()
    }

    // MARK: - Top Status Bar Header
    private var statusBarHeader: some View {
        HStack {
            // Status Indicator Dot & Label
            HStack(spacing: 8) {
                Circle()
                    .fill(statusIndicatorColor)
                    .frame(width: 10, height: 10)

                Text(connectionManager.connectionState.statusDescription)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
            }

            Spacer()

            // Latency Badge (when connected)
            if connectionManager.connectionState.isConnectedOrStreaming {
                HStack(spacing: 4) {
                    Image(systemName: "gauge.with.needle")
                        .font(.caption2)
                    Text(String(format: "%.0f мс", connectionManager.latencyMs))
                        .font(.caption.weight(.semibold))
                }
                .foregroundColor(latencyColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(latencyColor.opacity(0.12))
                .clipShape(Capsule())
            }
        }
    }

    private var statusIndicatorColor: Color {
        switch connectionManager.connectionState {
        case .disconnected:
            return .gray
        case .connecting, .reconnecting:
            return .orange
        case .connected:
            return .green
        case .streaming:
            return .blue
        case .error:
            return .red
        }
    }

    private var latencyColor: Color {
        if connectionManager.latencyMs < 20 {
            return .green
        } else if connectionManager.latencyMs < 60 {
            return .orange
        } else {
            return .red
        }
    }

    // MARK: - Disconnected View
    private var disconnectedSection: some View {
        VStack(spacing: 20) {
            // Primary Scan Button Card
            VStack(spacing: 16) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 56))
                    .foregroundColor(.blue)

                VStack(spacing: 4) {
                    Text("Сканировать QR-код")
                        .font(.title3.bold())

                    Text("Наведите камеру на QR-код в окне Wi-Fi Mic на компьютере")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                Button {
                    if audioStreamer.isMicrophoneUndetermined {
                        audioStreamer.requestMicrophonePermission { _ in
                            showingScanner = true
                        }
                    } else {
                        showingScanner = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "camera.fill")
                        Text("Открыть сканер")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            // Secondary: Manual Entry
            Button {
                if audioStreamer.isMicrophoneUndetermined {
                    audioStreamer.requestMicrophonePermission { _ in
                        showingManualEntry = true
                    }
                } else {
                    showingManualEntry = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                    Text("Ввести параметры вручную")
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(.blue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // Quick Reconnect Section
            if let last = lastConnection {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundColor(.secondary)
                        Text("Последнее подключение")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Компьютер:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(last.host):\(last.port)")
                                .font(.caption.weight(.semibold))
                        }

                        HStack {
                            Text("Токен:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(last.token.uuidString)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Button {
                        if audioStreamer.isMicrophoneUndetermined {
                            audioStreamer.requestMicrophonePermission { _ in
                                connectToServer(host: last.host, port: last.port, token: last.token)
                            }
                        } else {
                            connectToServer(host: last.host, port: last.port, token: last.token)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Подключиться повторно")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.green)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    // MARK: - Connecting / Reconnecting View
    private func connectingSection(title: String) -> some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
                .padding(.top, 32)

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)

                Text("Убедитесь, что сервер Wi-Fi Mic запущен на компьютере.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Button("Отмена") {
                connectionManager.disconnect()
            }
            .foregroundColor(.red)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Connected / Streaming View
    private var connectedSection: some View {
        VStack(spacing: 20) {
            // Server Info Card
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 3) {
                    Text(connectionManager.serverName)
                        .font(.headline)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionManager.isStreaming ? Color.blue : Color.green)
                            .frame(width: 8, height: 8)

                        Text(connectionManager.isStreaming ? "Идёт передача аудио" : "Готов к передаче")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // VU Meter Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Уровень микрофона")
                        .font(.subheadline.weight(.medium))

                    Spacer()

                    Text("\(Int(audioStreamer.audioLevel * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }

                AudioLevelMeterBar(level: audioStreamer.audioLevel)
                    .frame(height: 18)
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // Gain Control Card
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Усиление (Gain)")
                        .font(.subheadline.weight(.medium))

                    Spacer()

                    Text(String(format: "%.1f×", audioStreamer.gain))
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.blue)
                }

                Slider(value: $audioStreamer.gain, in: 0.5...4.0, step: 0.1)
                    .tint(.blue)

                HStack {
                    GainPresetButton(title: "0.5×", targetGain: 0.5, currentGain: $audioStreamer.gain)
                    GainPresetButton(title: "1.0× (Норма)", targetGain: 1.0, currentGain: $audioStreamer.gain)
                    GainPresetButton(title: "1.5×", targetGain: 1.5, currentGain: $audioStreamer.gain)
                    GainPresetButton(title: "2.0×", targetGain: 2.0, currentGain: $audioStreamer.gain)
                }
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // Large Streaming Action Button
            Button {
                let generator = UIImpactFeedbackGenerator(style: .heavy)
                generator.impactOccurred()
                if connectionManager.isStreaming {
                    connectionManager.stopStreaming()
                } else {
                    connectionManager.startStreaming()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: connectionManager.isStreaming ? "stop.fill" : "mic.fill")
                        .font(.title2)

                    Text(connectionManager.isStreaming ? "Остановить передачу" : "Начать передачу")
                        .font(.title3.bold())
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(connectionManager.isStreaming ? Color.red : Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(
                    color: (connectionManager.isStreaming ? Color.red : Color.blue).opacity(0.35),
                    radius: 10,
                    x: 0,
                    y: 6
                )
            }

            // Disconnect Button
            Button {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                connectionManager.disconnect()
            } label: {
                Text("Отключиться")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Error Section
    private func errorSection(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)

            Text("Ошибка соединения")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            HStack(spacing: 12) {
                Button("Назад") {
                    connectionManager.disconnect()
                }
                .buttonStyle(.bordered)

                if let last = lastConnection {
                    Button("Повторить") {
                        connectToServer(host: last.host, port: last.port, token: last.token)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Mic Permission Denied Card
    private var micPermissionDeniedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "mic.slash.fill")
                    .foregroundColor(.red)
                Text("Нет доступа к микрофону")
                    .font(.subheadline.bold())
                    .foregroundColor(.red)
            }

            Text("Wi-Fi Mic требуется доступ к микрофону для передачи звука. Перейдите в Настройки iOS и включите тумблер.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Открыть Настройки iOS")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(Color.red)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Gain Preset Button
private struct GainPresetButton: View {
    let title: String
    let targetGain: Float
    @Binding var currentGain: Float

    private var isSelected: Bool {
        abs(currentGain - targetGain) < 0.05
    }

    var body: some View {
        Button {
            currentGain = targetGain
        } label: {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundColor(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

// MARK: - Audio Level Meter Bar
private struct AudioLevelMeterBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let currentWidth = max(0, min(width, width * CGFloat(level)))

            ZStack(alignment: .leading) {
                // Background Track
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))

                // Active Level with Gradient
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .green, location: 0.0),
                                .init(color: .green, location: 0.6),
                                .init(color: .yellow, location: 0.8),
                                .init(color: .red, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: currentWidth)
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }
}
