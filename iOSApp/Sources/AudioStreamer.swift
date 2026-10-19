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
    private let audioQueue = DispatchQueue(label: "com.wifimic.audio", qos: .userInteractive)
    private var sampleAccumulator = [Int16]()
    private let targetSampleCount = 480 // 10ms at 48kHz = 480 samples (960 bytes)
    private var wasInterruptedWhileStreaming = false

    public init() {
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
        // Use playAndRecord with mixWithOthers and defaultToSpeaker for background capability
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
        try session.setPreferredSampleRate(48000.0)
        try session.setPreferredIOBufferDuration(0.01) // 10ms preferred buffer
        try session.setActive(true)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            throw NSError(
                domain: "WifiMic.AudioStreamer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось получить формат входного аудио."]
            )
        }

        // Buffer size roughly matching 10-20ms
        let bufferSize = AVAudioFrameCount(max(512, Int(format.sampleRate * 0.02)))

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.processIncomingBuffer(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        DispatchQueue.main.async {
            self.isRunning = true
            self.permissionDenied = false
        }
        print("[AudioStreamer] Capture started (Rate: \(format.sampleRate)Hz, Channels: \(format.channelCount))")
    }

    private func stopInternal() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()

        sampleAccumulator.removeAll(keepingCapacity: true)

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

    // MARK: - Buffer Conversion & Chunking (Float32 -> Int16 @ 48kHz)
    private func processIncomingBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        guard let floatData = inputBuffer.floatChannelData else { return }
        let frameCount = Int(inputBuffer.frameLength)
        guard frameCount > 0 else { return }

        let sampleRate = inputBuffer.format.sampleRate
        let channel0 = floatData[0]
        let currentGain = self.gain

        var convertedSamples = [Int16]()
        var peak: Float = 0.0

        if abs(sampleRate - 48000.0) < 100.0 {
            // Native 48kHz: fast direct conversion
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
            // Linear resampling from input sampleRate to 48kHz
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

        // Update VU meter smoothly on UI
        let capturedPeak = min(1.0, peak)
        DispatchQueue.main.async {
            let previous = self.audioLevel
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
}
