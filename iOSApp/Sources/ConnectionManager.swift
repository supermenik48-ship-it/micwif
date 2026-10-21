import Foundation
import Network
import UIKit
import Combine

public enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case streaming
    case reconnecting(attempt: Int)
    case error(String)

    public var isConnectedOrStreaming: Bool {
        switch self {
        case .connected, .streaming:
            return true
        default:
            return false
        }
    }

    public var statusDescription: String {
        switch self {
        case .disconnected:
            return "Отключено"
        case .connecting:
            return "Подключение..."
        case .connected:
            return "Подключено"
        case .streaming:
            return "Передача звука"
        case .reconnecting(let attempt):
            return "Переподключение (попытка \(attempt)/5)..."
        case .error(let msg):
            return "Ошибка: \(msg)"
        }
    }
}

public final class ConnectionManager: ObservableObject {
    // MARK: - Published Properties
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var serverName: String = "Неизвестно"
    @Published public private(set) var latencyMs: Double = 0.0
    @Published public private(set) var isStreaming: Bool = false

    // MARK: - Weak Audio Streamer Reference
    public weak var audioStreamer: AudioStreamer?

    // MARK: - Private State
    private let networkQueue = DispatchQueue(label: "com.wifimic.network", qos: .userInteractive)
    private var tcpConnection: NWConnection?
    private var udpConnection: NWConnection?

    private var currentHost: String?
    private var currentPort: UInt16?
    private var currentToken: UUID?
    private var currentUdpPort: UInt16 = 45456
    private var sessionTokenBytes: [UInt8] = []
    private var sequenceNumber: UInt32 = 0

    private var pingTimer: DispatchSourceTimer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var lastPongTimestamp: Date = Date()
    private var reconnectAttempt: Int = 0
    private var isIntentionalDisconnect: Bool = false
    private var internalStreaming: Bool = false
    private let maxReconnectAttempts = 5
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private func beginBackgroundTask() {
        endBackgroundTask()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "WifiMicStream") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    // MARK: - UserDefaults Keys
    private static let kLastHost = "wifimic_last_host"
    private static let kLastPort = "wifimic_last_port"
    private static let kLastToken = "wifimic_last_token"

    public init() {}

    deinit {
        disconnect()
    }

    // MARK: - Last Connection Storage
    public static var lastSavedConnection: (host: String, port: UInt16, token: UUID)? {
        guard let host = UserDefaults.standard.string(forKey: kLastHost),
              !host.isEmpty,
              let tokenStr = UserDefaults.standard.string(forKey: kLastToken),
              let token = UUID(uuidString: tokenStr) else {
            return nil
        }
        let portInt = UserDefaults.standard.integer(forKey: kLastPort)
        let port = portInt > 0 ? UInt16(portInt) : UInt16(45455)
        return (host, port, token)
    }

    private func saveLastConnection(host: String, port: UInt16, token: UUID) {
        UserDefaults.standard.set(host, forKey: Self.kLastHost)
        UserDefaults.standard.set(Int(port), forKey: Self.kLastPort)
        UserDefaults.standard.set(token.uuidString, forKey: Self.kLastToken)
    }

    // MARK: - Public API
    public func connect(host: String, port: UInt16, token: UUID) {
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            // 1. Cancel previous pending reconnects and keepalives
            self.cancelReconnect()
            self.stopKeepalive()
            self.endBackgroundTask()
            self.internalStreaming = false

            // 2. Stop audio capture and close lingering sockets
            self.stopAudioStream()
            self.teardownUdp()
            self.teardownTcp()

            self.isIntentionalDisconnect = false
            self.reconnectAttempt = 0
            self.currentHost = host
            self.currentPort = port
            self.currentToken = token

            let u = token.uuid
            self.sessionTokenBytes = [
                u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15
            ]

            self.updateState(.connecting)
            self.startTcpConnection(host: host, port: port, token: token)
        }
    }

    public func disconnect() {
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            self.isIntentionalDisconnect = true
            self.internalStreaming = false
            self.endBackgroundTask()
            self.stopKeepalive()
            self.cancelReconnect()

            // Send bye if TCP is connected
            if self.tcpConnection?.state == .ready {
                self.sendTcpBye()
            }

            self.stopAudioStream()
            self.teardownUdp()
            self.teardownTcp()

            self.updateState(.disconnected)
            DispatchQueue.main.async {
                self.isStreaming = false
                self.latencyMs = 0
            }
        }
    }

    public func startStreaming() {
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.connectionState.isConnectedOrStreaming else { return }
            self.internalStreaming = true
            self.beginBackgroundTask()
            self.updateState(.streaming)
            DispatchQueue.main.async {
                self.isStreaming = true
                do {
                    try self.audioStreamer?.start()
                } catch {
                    print("[ConnectionManager] Failed to start audio streamer: \(error)")
                }
            }
        }
    }

    public func stopStreaming() {
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            self.internalStreaming = false
            self.endBackgroundTask()
            if self.connectionState == .streaming {
                self.updateState(.connected)
            }
            DispatchQueue.main.async {
                self.isStreaming = false
            }
            self.stopAudioStream()
        }
    }

    public func sendAudio(data: Data) {
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.internalStreaming, let udp = self.udpConnection, udp.state == .ready else { return }

            // 26-byte Protocol v2 header:
            // [0-1]   Magic: 0x57 0x4D
            // [2]     Version: 0x02
            // [3-6]   Sequence number (uint32 LE)
            // [7-22]  Session token (16 bytes, raw UUID)
            // [23]    Codec: 0x01 = PCM16
            // [24-25] Payload length (uint16 LE)
            // [26..]  Audio payload (PCM 16-bit LE, 48kHz, mono)

            var packet = Data(capacity: 26 + data.count)
            packet.append(contentsOf: [0x57, 0x4D, 0x02])

            var seqLE = self.sequenceNumber.littleEndian
            withUnsafeBytes(of: &seqLE) { packet.append(contentsOf: $0) }
            self.sequenceNumber &+= 1

            packet.append(contentsOf: self.sessionTokenBytes)
            packet.append(0x01) // PCM 16-bit

            var lengthLE = UInt16(data.count).littleEndian
            withUnsafeBytes(of: &lengthLE) { packet.append(contentsOf: $0) }

            packet.append(data)

            udp.send(content: packet, completion: .contentProcessed({ error in
                if let error = error {
                    print("[UDP] Packet send failed: \(error)")
                }
            }))
        }
    }

    // MARK: - TCP Connection Setup
    private func startTcpConnection(host: String, port: UInt16, token: UUID) {
        teardownTcp()

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            updateState(.error("Неверный номер порта: \(port)"))
            return
        }

        let endpoint = NWEndpoint.Host(host)
        let tcpParams = NWParameters.tcp
        tcpParams.allowLocalEndpointReuse = true

        let connection = NWConnection(host: endpoint, port: nwPort, using: tcpParams)
        self.tcpConnection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            self.networkQueue.async {
                self.handleTcpStateChange(state, host: host, port: port, token: token)
            }
        }

        connection.start(queue: networkQueue)
    }

    private func handleTcpStateChange(_ state: NWConnection.State, host: String, port: UInt16, token: UUID) {
        switch state {
        case .ready:
            print("[TCP] Connected to \(host):\(port)")
            sendHello(token: token)
            startReadingMessages()
            startKeepalive()

        case .waiting(let error):
            print("[TCP] Waiting: \(error)")

        case .failed(let error):
            print("[TCP] Connection failed: \(error)")
            handleDisconnect()

        case .cancelled:
            print("[TCP] Connection cancelled")

        default:
            break
        }
    }

    // MARK: - TCP Messaging
    private func sendHello(token: UUID) {
        let clientName = UIDevice.current.name
        let helloPayload: [String: Any] = [
            "type": "hello",
            "token": token.uuidString.lowercased(),
            "clientName": clientName,
            "platform": "ios",
            "version": 2
        ]
        sendTcpJson(helloPayload)
    }

    private func sendTcpBye() {
        let byePayload: [String: Any] = ["type": "bye"]
        sendTcpJson(byePayload)
    }

    private func sendTcpPing() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let pingPayload: [String: Any] = [
            "type": "ping",
            "ts": nowMs
        ]
        sendTcpJson(pingPayload)
    }

    private func sendTcpJson(_ dictionary: [String: Any]) {
        guard let tcp = tcpConnection, tcp.state == .ready else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dictionary, options: []) else {
            print("[TCP] Failed to serialize JSON")
            return
        }

        var lengthLE = UInt32(jsonData.count).littleEndian
        var packet = Data(bytes: &lengthLE, count: 4)
        packet.append(jsonData)

        tcp.send(content: packet, completion: .contentProcessed({ error in
            if let error = error {
                print("[TCP] Send error: \(error)")
            }
        }))
    }

    // MARK: - TCP Message Framing & Reading
    private func startReadingMessages() {
        readExactBytes(count: 4) { [weak self] lengthData in
            guard let self = self else { return }
            guard let lengthData = lengthData, lengthData.count == 4 else {
                print("[TCP] Failed to read message length, socket likely closed")
                self.handleDisconnect()
                return
            }

            let lengthLE = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }
            let payloadLength = Int(UInt32(littleEndian: lengthLE))

            guard payloadLength > 0 && payloadLength <= 1_048_576 else {
                print("[TCP] Invalid payload length received: \(payloadLength)")
                self.handleDisconnect()
                return
            }

            self.readExactBytes(count: payloadLength) { [weak self] payloadData in
                guard let self = self else { return }
                guard let payloadData = payloadData, payloadData.count == payloadLength else {
                    print("[TCP] Failed to read full message payload")
                    self.handleDisconnect()
                    return
                }

                self.processTcpMessage(payloadData)
                // Continue reading next message
                self.startReadingMessages()
            }
        }
    }

    private func readExactBytes(count: Int, accumulated: Data = Data(), completion: @escaping (Data?) -> Void) {
        guard let tcp = tcpConnection, tcp.state == .ready else {
            completion(nil)
            return
        }

        let needed = count - accumulated.count
        guard needed > 0 else {
            completion(accumulated)
            return
        }

        tcp.receive(minimumIncompleteLength: 1, maximumLength: needed) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                print("[TCP] Receive error: \(error)")
                completion(nil)
                return
            }

            var current = accumulated
            if let data = data, !data.isEmpty {
                current.append(data)
            }

            if current.count >= count {
                completion(current)
            } else if isComplete {
                completion(nil)
            } else {
                self.readExactBytes(count: count, accumulated: current, completion: completion)
            }
        }
    }

    private func processTcpMessage(_ data: Data) {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = jsonObject as? [String: Any],
              let type = dict["type"] as? String else {
            print("[TCP] Unparseable JSON received")
            return
        }

        switch type {
        case "welcome":
            handleWelcomeMessage(dict)

        case "rejected":
            handleRejectedMessage(dict)

        case "pong":
            handlePongMessage(dict)

        case "bye":
            handleServerBye()

        case "error":
            let msg = dict["message"] as? String ?? "Неизвестная ошибка сервера"
            print("[TCP] Server error received: \(msg)")
            updateState(.error(msg))

        default:
            print("[TCP] Unknown message type: \(type)")
        }
    }

    private func handleWelcomeMessage(_ dict: [String: Any]) {
        let sName = dict["serverName"] as? String ?? "Windows PC"
        let udpPort = (dict["udpPort"] as? NSNumber)?.uint16Value ?? 45456

        // Synchronize session token with server if updated
        if let tokenStr = dict["sessionToken"] as? String, let token = UUID(uuidString: tokenStr) {
            self.currentToken = token
            let u = token.uuid
            self.sessionTokenBytes = [
                u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15
            ]
        }

        self.currentUdpPort = udpPort
        self.reconnectAttempt = 0
        self.lastPongTimestamp = Date()

        if let host = currentHost, let port = currentPort, let token = currentToken {
            saveLastConnection(host: host, port: port, token: token)
        }

        DispatchQueue.main.async {
            self.serverName = sName
        }

        // Start UDP Audio Channel
        if let host = currentHost {
            startUdpChannel(host: host, port: udpPort)
        }

        self.internalStreaming = true
        self.beginBackgroundTask()
        updateState(.streaming)
        DispatchQueue.main.async {
            self.isStreaming = true
            do {
                try self.audioStreamer?.start()
            } catch {
                print("[ConnectionManager] Failed to start audio streamer: \(error)")
            }
        }
        print("[TCP] Handshake successful! Server: \(sName), UDP port: \(udpPort), auto-started streaming")
    }

    private func handleRejectedMessage(_ dict: [String: Any]) {
        let reason = dict["reason"] as? String ?? "Подключение отклонено"
        print("[TCP] Rejected: \(reason)")
        isIntentionalDisconnect = true
        stopKeepalive()
        teardownTcp()
        teardownUdp()
        stopAudioStream()
        updateState(.error(reason))
    }

    private func handlePongMessage(_ dict: [String: Any]) {
        lastPongTimestamp = Date()
        if let sentTs = dict["ts"] as? Double ?? (dict["ts"] as? NSNumber)?.doubleValue {
            let nowMs = Date().timeIntervalSince1970 * 1000
            let rtt = max(0.0, nowMs - sentTs)
            DispatchQueue.main.async {
                self.latencyMs = rtt
            }
        }
    }

    private func handleServerBye() {
        print("[TCP] Server sent bye (server was stopped)")
        isIntentionalDisconnect = true
        cancelReconnect()
        stopKeepalive()
        endBackgroundTask()
        internalStreaming = false
        stopAudioStream()
        teardownUdp()
        teardownTcp()
        updateState(.disconnected)
        DispatchQueue.main.async {
            self.isStreaming = false
            self.latencyMs = 0
        }
    }

    // MARK: - UDP Audio Channel Setup
    private func startUdpChannel(host: String, port: UInt16) {
        teardownUdp()

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let endpoint = NWEndpoint.Host(host)
        let udpParams = NWParameters.udp
        udpParams.allowLocalEndpointReuse = true

        let udp = NWConnection(host: endpoint, port: nwPort, using: udpParams)
        self.udpConnection = udp
        self.sequenceNumber = 0

        udp.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[UDP] Ready to send audio to \(host):\(port)")
            case .failed(let err):
                print("[UDP] Connection failed: \(err)")
            default:
                break
            }
        }

        udp.start(queue: networkQueue)
    }

    // MARK: - Keepalive Ping & Health Check
    private func startKeepalive() {
        stopKeepalive()

        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.tcpConnection?.state == .ready else { return }

            // Check if server is unresponsive (> 10s without pong)
            let elapsedSincePong = Date().timeIntervalSince(self.lastPongTimestamp)
            if elapsedSincePong > 10.0 {
                print("[TCP] Keepalive timeout (\(Int(elapsedSincePong))s without pong), triggering reconnect")
                self.handleDisconnect()
                return
            }

            self.sendTcpPing()
        }
        timer.resume()
        self.pingTimer = timer
    }

    private func stopKeepalive() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    // MARK: - Reconnection Logic
    private func handleDisconnect() {
        stopKeepalive()
        teardownTcp()
        teardownUdp()
        stopAudioStream()

        guard !isIntentionalDisconnect else {
            updateState(.disconnected)
            return
        }

        if reconnectAttempt < maxReconnectAttempts {
            reconnectAttempt += 1
            let delaySeconds = pow(2.0, Double(reconnectAttempt - 1)) // 1, 2, 4, 8, 16
            updateState(.reconnecting(attempt: reconnectAttempt))
            print("[ConnectionManager] Scheduling reconnect attempt \(reconnectAttempt)/\(maxReconnectAttempts) in \(delaySeconds)s")

            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, !self.isIntentionalDisconnect else { return }
                guard let host = self.currentHost, let port = self.currentPort, let token = self.currentToken else { return }
                self.startTcpConnection(host: host, port: port, token: token)
            }
            self.reconnectWorkItem = workItem
            networkQueue.asyncAfter(deadline: .now() + delaySeconds, execute: workItem)
        } else {
            print("[ConnectionManager] Max reconnect attempts reached")
            stopAudioStream()
            updateState(.error("Не удалось восстановить связь с сервером"))
        }
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    // MARK: - Teardown Helpers
    private func teardownTcp() {
        if let tcp = tcpConnection {
            tcp.stateUpdateHandler = nil
            tcp.cancel()
            tcpConnection = nil
        }
    }

    private func teardownUdp() {
        if let udp = udpConnection {
            udp.stateUpdateHandler = nil
            udp.cancel()
            udpConnection = nil
        }
    }

    private func stopAudioStream() {
        DispatchQueue.main.async { [weak self] in
            self?.audioStreamer?.stop()
        }
    }

    private func updateState(_ state: ConnectionState) {
        DispatchQueue.main.async {
            self.connectionState = state
        }
    }
}
