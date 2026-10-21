import AVFoundation
import Foundation
import Combine
import UIKit

public final class AudioStreamer: ObservableObject {
    // MARK: - Published Properties
    @Published public var audioLevel: Float = 0.0
    @Published public var gain: Float = 1.0 // 0.5 to 4.0
    @Published public private(set) var isRunning: Bool = false
    @Published public var permissionDenied: Bool = false

    // MARK: - Weak ConnectionManager
    public weak var connectionManager: ConnectionManager?

    // MARK: - Audio Processing
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isPlayerAttached = false
    private var hasTapInstalled = false
    private var silentBuffer: AVAudioPCMBuffer?

    private let audioQueue = DispatchQueue(label: "com.wifimic.audio", qos: .userInteractive)
    private var sampleAccumulator = [Int16]()
    private let targetSampleCount = 480 // 10ms at 48kHz = 480 samples (960 bytes)
    private var wasInterruptedWhileStreaming = false

    public init() {
        setupNotifications()
        checkPermission()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stop()
    }

    // MARK: - Permissions Helper
    public func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            DispatchQueue.main.async {
                self.permissionDenied = false
                completion(true)
            }
        case .denied:
            DispatchQueue.main.async {
                self.permissionDenied = true
                completion(false)
            }
        case .undetermined:
            session.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    self.permissionDenied = !granted
                    completion(granted)
                }
            }
        @unknown default:
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }

    public var isMicrophoneAuthorized: Bool {
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }

    public var isMicrophoneDenied: Bool {
        return AVAudioSession.sharedInstance().recordPermission == .denied
    }

    public var isMicrophoneUndetermined: Bool {
        return AVAudioSession.sharedInstance().recordPermission == .undetermined
    }

    public func checkPermission() {
        let session = AVAudioSession.sharedInstance()
        DispatchQueue.main.async {
            self.permissionDenied = (session.recordPermission == .denied)
        }
    }

    // MARK: - Public Controls
    public func start() throws {
        if !isMicrophoneAuthorized {
            requestMicrophonePermission { [weak self] granted in
                if granted {
                    self?.audioQueue.async {
                        try? self?.startInternal()
                    }
                } else {
                    DispatchQueue.main.async {
                        self?.permissionDenied = true
                    }
                }
            }
            return
        }

        try audioQueue.sync {
            try startInternal()
        }
    }

    public func stop() {
        audioQueue.sync {
            stopInternal()
        }
    }

    public func restart() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopInternal()
            try? self.startInternal()
        }
    }

    // MARK: - Internal Engine Management
    private func startInternal() throws {
        stopInternal()

        let session = AVAudioSession.sharedInstance()
        // playAndRecord + voiceChat + defaultToSpeaker + allowBluetooth + mixWithOthers
        // mode: .voiceChat explicitly tells iOS this is an active VoIP/mic communication app,
        // keeping the microphone indicator ON and preventing background suspension!
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
        )
        try session.setPreferredSampleRate(48000.0)
        try session.setPreferredIOBufferDuration(0.01) // 10ms preferred buffer
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let busFormat = inputNode.outputFormat(forBus: 0)
        let sampleRate = busFormat.sampleRate > 0 ? busFormat.sampleRate : 48000.0
        let bufferSize = AVAudioFrameCount(max(512, Int(sampleRate * 0.02)))

        // Always remove any previous tap on bus 0 before installing to prevent NSInvalidArgumentException
        inputNode.removeTap(onBus: 0)

        // Pass format: nil so CoreAudio never throws NSInvalidArgumentException
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, _ in
            self?.processIncomingBuffer(buffer)
        }
        hasTapInstalled = true

        // Safely attach silent player node to keep the iOS audio graph active in background / lock screen
        if playerNode.engine == nil {
            audioEngine.attach(playerNode)
        }
        isPlayerAttached = true

        let mixer = audioEngine.mainMixerNode
        audioEngine.connect(playerNode, to: mixer, format: nil)
        mixer.outputVolume = 0.0 // Muted so no sound comes out of the device speaker

        audioEngine.prepare()
        try audioEngine.start()

        // Schedule silent loop to maintain iOS background execution assertion
        startSilentAudioLoop()

        sampleAccumulator.removeAll(keepingCapacity: true)

        DispatchQueue.main.async {
            self.isRunning = true
            self.permissionDenied = false
        }
        print("[AudioStreamer] Capture started (Bus Rate: \(sampleRate)Hz, Channels: \(busFormat.channelCount))")
    }

    private func stopInternal() {
        playerNode.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        hasTapInstalled = false

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()

        if playerNode.engine != nil {
            audioEngine.detach(playerNode)
        }
        isPlayerAttached = false
        silentBuffer = nil

        sampleAccumulator.removeAll(keepingCapacity: true)

        DispatchQueue.main.async {
            self.isRunning = false
            self.audioLevel = 0.0
        }
        print("[AudioStreamer] Capture stopped")
    }

    private func pauseInternal() {
        audioEngine.pause()
        playerNode.pause()
        DispatchQueue.main.async {
            self.isRunning = false
            self.audioLevel = 0.0
        }
    }

    private func resumeInternal() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        try audioEngine.start()
        playerNode.play()
        DispatchQueue.main.async {
            self.isRunning = true
        }
    }

    // MARK: - Silent Audio Loop (Lock Screen / Background Keeper)
    private func startSilentAudioLoop() {
        let outputFormat = playerNode.outputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0 else { return }

        let frameCount: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        // Zero out channels for true digital silence
        if let floatData = buffer.floatChannelData {
            for ch in 0..<Int(outputFormat.channelCount) {
                memset(floatData[ch], 0, Int(frameCount) * MemoryLayout<Float>.size)
            }
        }
        self.silentBuffer = buffer

        playerNode.play()
        scheduleSilentLoop(buffer: buffer)
    }

    private func scheduleSilentLoop(buffer: AVAudioPCMBuffer) {
        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            self?.audioQueue.async {
                guard let self = self, self.isRunning, self.playerNode.isPlaying else { return }
                self.scheduleSilentLoop(buffer: buffer)
            }
        }
    }

    // MARK: - Buffer Conversion & Chunking (Float32/Int16 -> Int16 @ 48kHz)
    private func processIncomingBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        let frameCount = Int(inputBuffer.frameLength)
        guard frameCount > 0 else { return }

        let sampleRate = inputBuffer.format.sampleRate
        guard sampleRate > 0 else { return }

        let currentGain = self.gain
        var convertedSamples = [Int16]()
        var peak: Float = 0.0

        if let floatData = inputBuffer.floatChannelData {
            let channel0 = floatData[0]
            if abs(sampleRate - 48000.0) < 100.0 {
                // Native 48kHz: direct conversion
                convertedSamples.reserveCapacity(frameCount)
                for i in 0..<frameCount {
                    let f = channel0[i]
                    let boosted = f * currentGain
                    let clamped = Int16(clamping: Int(boosted * 32767.0))
                    convertedSamples.append(clamped)

                    let absVal = abs(boosted)
                    if absVal > peak { peak = absVal }
                }
            } else {
                // Linear resampling to 48kHz
                let ratio = 48000.0 / sampleRate
                let targetCount = max(1, Int(Double(frameCount) * ratio))
                convertedSamples.reserveCapacity(targetCount)

                for i in 0..<targetCount {
                    let srcIndex = Double(i) / ratio
                    let index0 = min(Int(srcIndex), frameCount - 1)
                    let index1 = min(index0 + 1, frameCount - 1)
                    let frac = Float(srcIndex - Double(index0))

                    let f = channel0[index0] * (1.0 - frac) + channel0[index1] * frac
                    let boosted = f * currentGain
                    let clamped = Int16(clamping: Int(boosted * 32767.0))
                    convertedSamples.append(clamped)

                    let absVal = abs(boosted)
                    if absVal > peak { peak = absVal }
                }
            }
        } else if let int16Data = inputBuffer.int16ChannelData {
            let channel0 = int16Data[0]
            if abs(sampleRate - 48000.0) < 100.0 {
                convertedSamples.reserveCapacity(frameCount)
                for i in 0..<frameCount {
                    let sample = Float(channel0[i]) / 32767.0
                    let boosted = sample * currentGain
                    let clamped = Int16(clamping: Int(boosted * 32767.0))
                    convertedSamples.append(clamped)

                    let absVal = abs(boosted)
                    if absVal > peak { peak = absVal }
                }
            } else {
                let ratio = 48000.0 / sampleRate
                let targetCount = max(1, Int(Double(frameCount) * ratio))
                convertedSamples.reserveCapacity(targetCount)

                for i in 0..<targetCount {
                    let srcIndex = Double(i) / ratio
                    let index0 = min(Int(srcIndex), frameCount - 1)
                    let index1 = min(index0 + 1, frameCount - 1)
                    let frac = Float(srcIndex - Double(index0))

                    let s0 = Float(channel0[index0]) / 32767.0
                    let s1 = Float(channel0[index1]) / 32767.0
                    let f = s0 * (1.0 - frac) + s1 * frac
                    let boosted = f * currentGain
                    let clamped = Int16(clamping: Int(boosted * 32767.0))
                    convertedSamples.append(clamped)

                    let absVal = abs(boosted)
                    if absVal > peak { peak = absVal }
                }
            }
        } else {
            return
        }

        // Update VU meter on UI only when app is visible (prevents dispatch queue buildup when screen is locked)
        if UIApplication.shared.applicationState != .background {
            let capturedPeak = min(1.0, peak)
            DispatchQueue.main.async {
                let previous = self.audioLevel
                let nextLevel = max(capturedPeak, previous * 0.7)
                self.audioLevel = min(1.0, nextLevel)
            }
        }

        // Accumulate and slice into exact 10ms chunks (480 samples = 960 bytes)
        audioQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.sampleAccumulator.append(contentsOf: convertedSamples)

            // Prevent buffer buildup if network was temporarily stalled (keep max 100ms)
            if self.sampleAccumulator.count > self.targetSampleCount * 10 {
                let excess = self.sampleAccumulator.count - (self.targetSampleCount * 5)
                self.sampleAccumulator.removeFirst(excess)
            }

            while self.sampleAccumulator.count >= self.targetSampleCount {
                let chunkSamples = Array(self.sampleAccumulator.prefix(self.targetSampleCount))
                self.sampleAccumulator.removeFirst(self.targetSampleCount)

                let data = chunkSamples.withUnsafeBufferPointer { buffer in
                    Data(buffer: buffer)
                }

                self.connectionManager?.sendAudio(data: data)
            }
        }
    }

    // MARK: - Notifications Setup
    private func setupNotifications() {
        let center = NotificationCenter.default

        center.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: audioEngine
        )
    }

    @objc private func handleAudioInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            print("[AudioStreamer] Audio interruption began")
            wasInterruptedWhileStreaming = isRunning
            if isRunning {
                audioQueue.sync { pauseInternal() }
            }

        case .ended:
            print("[AudioStreamer] Audio interruption ended")
            guard wasInterruptedWhileStreaming else { return }
            wasInterruptedWhileStreaming = false
            restart()

        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        print("[AudioStreamer] Route changed (reason: \(reason.rawValue))")
        if isRunning {
            restart()
        }
    }

    @objc private func handleEngineConfigurationChange(notification: Notification) {
        print("[AudioStreamer] Engine configuration changed (screen lock or route update)")
        audioQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            if !self.audioEngine.isRunning {
                print("[AudioStreamer] Audio engine was stopped, reviving capture")
                self.stopInternal()
                try? self.startInternal()
            }
        }
    }
}
