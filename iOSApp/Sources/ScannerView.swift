import SwiftUI
import AVFoundation

public struct ScannerView: View {
    @Environment(\.dismiss) private var dismiss
    
    public var onScanSuccess: (String, UInt16, UUID) -> Void
    public var onManualEntryRequested: () -> Void

    @State private var isTorchOn: Bool = false
    @State private var cameraPermission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var scanErrorMessage: String?

    public init(
        onScanSuccess: @escaping (String, UInt16, UUID) -> Void,
        onManualEntryRequested: @escaping () -> Void
    ) {
        self.onScanSuccess = onScanSuccess
        self.onManualEntryRequested = onManualEntryRequested
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                switch cameraPermission {
                case .authorized:
                    QRCameraScannerContainer(
                        isTorchOn: isTorchOn,
                        onDetectedCode: handleScannedString
                    )
                    .ignoresSafeArea()

                    scannerOverlayView

                case .notDetermined:
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(.white)
                        Text("Запрос доступа к камере...")
                            .foregroundColor(.white)
                    }
                    .onAppear {
                        requestCameraPermission()
                    }

                case .denied, .restricted:
                    permissionDeniedView

                @unknown default:
                    permissionDeniedView
                }
            }
            .navigationTitle("Сканирование QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }

                if cameraPermission == .authorized {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isTorchOn.toggle()
                        } label: {
                            Image(systemName: isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                .foregroundColor(isTorchOn ? .yellow : .white)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Scanner Overlay
    private var scannerOverlayView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Viewfinder frame
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.3), lineWidth: 2)
                    .frame(width: 260, height: 260)

                // Corner accents
                ScannerCornersView()
                    .frame(width: 260, height: 260)
            }

            Text("Наведите камеру на QR-код в приложении Wi-Fi Mic на компьютере")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 32)

            if let errorMsg = scanErrorMessage {
                Text(errorMsg)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 24)
            }

            Spacer()

            Button {
                dismiss()
                onManualEntryRequested()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                    Text("Ввести вручную")
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(.white)
                .padding(.vertical, 14)
                .padding(.horizontal, 28)
                .background(Color.white.opacity(0.2))
                .clipShape(Capsule())
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - Permission Denied View
    private var permissionDeniedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 64))
                .foregroundColor(.orange)

            Text("Камера недоступна")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text("Wi-Fi Mic требуется доступ к камере для сканирования QR-кода с экрана компьютера.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 32)

            Button("Открыть настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.headline)
            .foregroundColor(.black)
            .padding(.vertical, 14)
            .padding(.horizontal, 32)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Button("Ввести вручную") {
                dismiss()
                onManualEntryRequested()
            }
            .foregroundColor(.white.opacity(0.8))
            .padding(.top, 8)
        }
    }

    // MARK: - Actions
    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                self.cameraPermission = granted ? .authorized : .denied
            }
        }
    }

    private func handleScannedString(_ code: String) {
        if let result = Self.parseQrPayload(code) {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                onScanSuccess(result.ip, result.port, result.token)
            }
        } else {
            scanErrorMessage = "Неверный формат QR-кода"
        }
    }

    // MARK: - QR Code Parser
    public static func parseQrPayload(_ string: String) -> (ip: String, port: UInt16, token: UUID)? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Format: wifimic://{ip}:{port}/{token}
        if trimmed.lowercased().hasPrefix("wifimic://") {
            let withoutScheme = String(trimmed.dropFirst("wifimic://".count))
            let parts = withoutScheme.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            if !parts.isEmpty {
                let hostPort = String(parts[0])
                let hp = hostPort.split(separator: ":")
                let ip = String(hp[0])
                let port = hp.count > 1 ? (UInt16(hp[1]) ?? 45455) : UInt16(45455)

                if parts.count >= 2 {
                    let tokenStr = String(parts[1])
                    if let token = UUID(uuidString: tokenStr), !ip.isEmpty {
                        return (ip, port, token)
                    }
                }
            }
        }

        // 2. Format: {ip};{port};{token}
        let semiParts = trimmed.split(separator: ";")
        if semiParts.count >= 3 {
            let ip = String(semiParts[0])
            let port = UInt16(semiParts[1]) ?? 45455
            let tokenStr = String(semiParts[2])
            if let token = UUID(uuidString: tokenStr), !ip.isEmpty {
                return (ip, port, token)
            }
        }

        // 3. Fallback: Generic URL parsing
        if let url = URL(string: trimmed), let host = url.host {
            let port = UInt16(url.port ?? 45455)
            let tokenStr = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let token = UUID(uuidString: tokenStr) {
                return (host, port, token)
            }
        }

        return nil
    }
}

// MARK: - Corner Accents View
private struct ScannerCornersView: View {
    private let cornerLength: CGFloat = 28
    private let cornerThickness: CGFloat = 4
    private let cornerRadius: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            Path { path in
                // Top-Left
                path.move(to: CGPoint(x: 0, y: cornerLength))
                path.addLine(to: CGPoint(x: 0, y: cornerRadius))
                path.addQuadCurve(to: CGPoint(x: cornerRadius, y: 0), control: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: cornerLength, y: 0))

                // Top-Right
                path.move(to: CGPoint(x: w - cornerLength, y: 0))
                path.addLine(to: CGPoint(x: w - cornerRadius, y: 0))
                path.addQuadCurve(to: CGPoint(x: w, y: cornerRadius), control: CGPoint(x: w, y: 0))
                path.addLine(to: CGPoint(x: w, y: cornerLength))

                // Bottom-Right
                path.move(to: CGPoint(x: w, y: h - cornerLength))
                path.addLine(to: CGPoint(x: w, y: h - cornerRadius))
                path.addQuadCurve(to: CGPoint(x: w - cornerRadius, y: h), control: CGPoint(x: w, y: h))
                path.addLine(to: CGPoint(x: w - cornerLength, y: h))

                // Bottom-Left
                path.move(to: CGPoint(x: cornerLength, y: h))
                path.addLine(to: CGPoint(x: cornerRadius, y: h))
                path.addQuadCurve(to: CGPoint(x: 0, y: h - cornerRadius), control: CGPoint(x: 0, y: h))
                path.addLine(to: CGPoint(x: 0, y: h - cornerLength))
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: cornerThickness, lineCap: .round))
        }
    }
}

// MARK: - UIViewControllerRepresentable Camera
private struct QRCameraScannerContainer: UIViewControllerRepresentable {
    var isTorchOn: Bool
    var onDetectedCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRCameraViewController {
        let controller = QRCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCameraViewController, context: Context) {
        uiViewController.setTorch(on: isTorchOn)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDetectedCode: onDetectedCode)
    }

    class Coordinator: NSObject, QRCameraViewControllerDelegate {
        var onDetectedCode: (String) -> Void

        init(onDetectedCode: @escaping (String) -> Void) {
            self.onDetectedCode = onDetectedCode
        }

        func didFindCode(_ code: String) {
            self.onDetectedCode(code)
        }
    }
}

// MARK: - UIViewController Implementation
private protocol QRCameraViewControllerDelegate: AnyObject {
    func didFindCode(_ code: String)
}

private class QRCameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: QRCameraViewControllerDelegate?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let sessionQueue = DispatchQueue(label: "com.wifimic.camera.queue")
    private var hasScanned: Bool = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        sessionQueue.async { [weak self] in
            self?.setupCaptureSession()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [weak self] in
            if self?.captureSession.isRunning == false {
                self?.captureSession.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setTorch(on: false)
        sessionQueue.async { [weak self] in
            if self?.captureSession.isRunning == true {
                self?.captureSession.stopRunning()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func setupCaptureSession() {
        guard let videoDevice = AVCaptureDevice.default(for: .video) else {
            print("[Camera] No video device available")
            return
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            captureSession.beginConfiguration()

            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
            } else {
                captureSession.commitConfiguration()
                return
            }

            let metadataOutput = AVCaptureMetadataOutput()
            if captureSession.canAddOutput(metadataOutput) {
                captureSession.addOutput(metadataOutput)
                // Use sessionQueue instead of DispatchQueue.main to prevent UI lockup
                metadataOutput.setMetadataObjectsDelegate(self, queue: sessionQueue)
                if metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                    metadataOutput.metadataObjectTypes = [.qr]
                }
            }

            captureSession.commitConfiguration()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let preview = AVCaptureVideoPreviewLayer(session: self.captureSession)
                preview.videoGravity = .resizeAspectFill
                preview.frame = self.view.bounds
                self.view.layer.addSublayer(preview)
                self.previewLayer = preview
            }

            sessionQueue.async { [weak self] in
                self?.captureSession.startRunning()
            }
        } catch {
            print("[Camera] Failed to initialize camera input: \(error)")
        }
    }

    func setTorch(on: Bool) {
        sessionQueue.async {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  device.hasTorch else {
                return
            }
            do {
                try device.lockForConfiguration()
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
            } catch {
                print("[Camera] Torch error: \(error)")
            }
        }
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned else { return }
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadataObject.type == .qr,
              let stringValue = metadataObject.stringValue,
              !stringValue.isEmpty else {
            return
        }

        hasScanned = true

        // Stop session safely in background sessionQueue (NEVER block main thread)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didFindCode(stringValue)
        }
    }
}
