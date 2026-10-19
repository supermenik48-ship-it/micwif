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
    private let audioQueue = DispatchQueue(label: "com.wifimic.audio", qos: .userInteractive)
    private var sampleAccumulator = [Int16]()
    private let targetSampleCount = 480 // 10ms at 48kHz = 480 samples (960 bytes)
    private var wasInterruptedWhileStreaming = false
    private var hasTapInstalled = false

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
        audioQueue.sync {
            guard !isRunning else { return }
        }

        if !isMicrophoneAuthorized {
            requestMicrophonePermission { [weak self] granted in
                if granted {
                    try? self?.startInternal()
                } else {
                    self?.permissionDenied = true
                }
            }
            return
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
        // playAndRecord with allowBluetoothHFP and defaultToSpeaker for background execution when locked
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setPreferredSampleRate(48000.0)
        try session.setPreferredIOBufferDuration(0.01) // 10ms preferred buffer
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let busFormat = inputNode.outputFormat(forBus: 0)
        let sampleRate = busFormat.sampleRate > 0 ? busFormat.sampleRate : 48000.0
        let bufferSize = AVAudioFrameCount(max(512, Int(sampleRate * 0.02)))

        if hasTapInstalled {
            inputNode.removeTap(onBus: 0)
            hasTapInstalled = false
        }

        // Pass format: nil so CoreAudio never throws NSInvalidArgumentException
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, _ in
            self?.processIncomingBuffer(buffer)
        }
        hasTapInstalled = true

        // Keep main mixer volume muted so there is no speaker echo, but audio engine keeps session active in background
        audioEngine.mainMixerNode.outputVolume = 0.0

        audioEngine.prepare()
        try audioEngine.start()

        DispatchQueue.main.async {
            self.isRunning = true
            self.permissionDenied = false
        }
        print("[AudioStreamer] Capture started (Bus Rate: \(sampleRate)Hz, Channels: \(busFormat.channelCount))")
    }

    private func stopInternal() {
        if hasTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasTapInstalled = false
        }
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
        try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        try audioEngine.start()
        DispatchQueue.main.async {
            self.isRunning = true
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
