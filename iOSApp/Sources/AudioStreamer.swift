import AVFoundation
import Foundation
import Combine
import UIKit

public final class AudioStreamer: ObservableObject {
    // MARK: - Published Properties
    @Published public var audioLevel: Float = 0.0
    @Published public var gain: Float = 1.0 // 0.5 to 4.0
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var permissionDenied: Bool = false

    // MARK: - Weak ConnectionManager
    public weak var connectionManager: ConnectionManager?

    // MARK: - Audio Processing
    private let audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private let targetFormat: AVAudioFormat

    private let audioQueue = DispatchQueue(label: "com.wifimic.audio", qos: .userInteractive)
    private var sampleAccumulator = [Int16]()
    private let targetSampleCount = 480 // 10ms at 48kHz = 480 samples (960 bytes)
    private var wasInterruptedWhileStreaming = false

    public init() {
        // Target format: PCM 16-bit, 48000 Hz, mono
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48000,
            channels: 1,
            interleaved: true
        ) else {
            fatalError("Failed to initialize target AVAudioFormat")
        }
        self.targetFormat = format

        setupNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stop()
    }

    // MARK: - Public Controls
    public func start() throws {
        audioQueue.sync {
            guard !isRunning else { return }
        }

        // Check microphone permission
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .undetermined:
            session.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        try? self?.startInternal()
                    } else {
                        self?.permissionDenied = true
                    }
                }
            }
            return
        case .denied:
            DispatchQueue.main.async { self.permissionDenied = true }
            throw NSError(
                domain: "WifiMic.AudioStreamer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Доступ к микрофону запрещён в настройках."]
            )
        case .granted:
            break
        @unknown default:
            break
        }

        try startInternal()
    }

    public func stop() {
        audioQueue.sync {
            guard isRunning else { return }
            stopInternal()
        }
    }

    public func restart() {
        audioQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.stopInternal()
            try? self.startInternal()
        }
    }

    // MARK: - Internal Engine Management
    private func startInternal() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setPreferredSampleRate(48000.0)
        try session.setPreferredIOBufferDuration(0.01) // 10ms preferred buffer
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw NSError(
                domain: "WifiMic.AudioStreamer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось получить формат входного аудио."]
            )
        }

        audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
        if audioConverter == nil {
            print("[AudioStreamer] Warning: Failed to initialize AVAudioConverter directly, will fallback")
        }

        // Buffer size roughly matching 10ms at hardware input sample rate
        let bufferSize = AVAudioFrameCount(max(256, Int(inputFormat.sampleRate * 0.01)))

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processIncomingBuffer(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        DispatchQueue.main.async {
            self.isRunning = true
            self.permissionDenied = false
        }
        print("[AudioStreamer] Capture started (Input rate: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch)")
    }

    private func stopInternal() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()
        audioConverter = nil

        sampleAccumulator.removeAll(keepingCapacity: true)

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        DispatchQueue.main.async {
            self.isRunning = false
            self.audioLevel = 0.0
        }
        print("[AudioStreamer] Capture stopped")
    }

    private func pauseInternal() {
        audioEngine.pause()
        DispatchQueue.main.async {
            self.isRunning = false
            self.audioLevel = 0.0
        }
    }

    private func resumeInternal() throws {
        try AVAudioSession.sharedInstance().setActive(true)
        try audioEngine.start()
        DispatchQueue.main.async {
            self.isRunning = true
        }
    }

    // MARK: - Buffer Conversion & Chunking
    private func processIncomingBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter else { return }

        // Calculate expected output frames for 48kHz
        let ratio = 48000.0 / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 128)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return
        }

        var error: NSError?
        var consumed = false

        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, error == nil, outputBuffer.frameLength > 0,
              let channelData = outputBuffer.int16ChannelData else {
            return
        }

        let frameCount = Int(outputBuffer.frameLength)
        let rawSamples = channelData[0]

        // Fetch current gain
        let currentGain = self.gain

        // Apply gain, calculate VU meter peak, and collect samples
        var peak: Float = 0.0
        var convertedSamples = [Int16](repeating: 0, count: frameCount)

        for i in 0..<frameCount {
            let original = rawSamples[i]
            let boosted = Float(original) * currentGain
            let clamped = Int16(clamping: Int(boosted))
            convertedSamples[i] = clamped

            let normalized = abs(Float(clamped)) / 32768.0
            if normalized > peak {
                peak = normalized
            }
        }

        // Update VU meter smoothly
        let capturedPeak = peak
        DispatchQueue.main.async {
            let previous = self.audioLevel
            // Instant attack, smooth exponential decay
            let nextLevel = max(capturedPeak, previous * 0.7)
            self.audioLevel = min(1.0, nextLevel)
        }

        // Accumulate and slice into exact 10ms chunks (480 samples = 960 bytes)
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.sampleAccumulator.append(contentsOf: convertedSamples)

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
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
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

            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    audioQueue.sync {
                        try? resumeInternal()
                    }
                }
            }

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

    @objc private func handleDidEnterBackground() {
        // Background audio: If not actively streaming, keep audio session deactivated
        if !isRunning {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    @objc private func handleWillEnterForeground() {
        // Nothing needed unless recovering from unexpected state
    }
}
