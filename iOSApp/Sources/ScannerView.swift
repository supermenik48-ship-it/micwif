import SwiftUI
import AVFoundation
import UIKit
import VisionKit

public struct ScannerView: View {
    @Environment(\.dismiss) private var dismiss
    
    public var onScanSuccess: (String, UInt16, UUID) -> Void
    public var onManualEntryRequested: () -> Void

    @State private var cameraPermission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var scanErrorMessage: String?
    @State private var isProcessingScan: Bool = false

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
                    if DataScannerViewController.isSupported {
                        ModernDataScannerContainer(onCodeScanned: handleScannedString)
                            .ignoresSafeArea()
                    } else {
                        LegacyCameraScannerContainer(onCodeScanned: handleScannedString)
                            .ignoresSafeArea()
                    }

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
        guard !isProcessingScan else { return }
        if let result = Self.parseQrPayload(code) {
            isProcessingScan = true
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
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

// MARK: - Modern VisionKit DataScanner (iOS 16+)
private struct ModernDataScannerContainer: UIViewControllerRepresentable {
    var onCodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> CustomDataScannerVC {
        let scanner = CustomDataScannerVC(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: CustomDataScannerVC, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: CustomDataScannerVC, coordinator: Coordinator) {
        if uiViewController.isScanning {
            uiViewController.stopScanning()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned)
    }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCodeScanned: (String) -> Void
        private var hasScanned = false

        init(onCodeScanned: @escaping (String) -> Void) {
            self.onCodeScanned = onCodeScanned
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !hasScanned else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let val = barcode.payloadStringValue, !val.isEmpty {
                    hasScanned = true
                    dataScanner.stopScanning()
                    DispatchQueue.main.async {
                        self.onCodeScanned(val)
                    }
                    break
                }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            guard !hasScanned else { return }
            if case .barcode(let barcode) = item, let val = barcode.payloadStringValue, !val.isEmpty {
                hasScanned = true
                dataScanner.stopScanning()
                DispatchQueue.main.async {
                    self.onCodeScanned(val)
                }
            }
        }
    }
}

private class CustomDataScannerVC: DataScannerViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !isScanning {
            try? startScanning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isScanning {
            stopScanning()
        }
    }
}

// MARK: - Legacy AVFoundation Fallback
private struct LegacyCameraScannerContainer: UIViewControllerRepresentable {
    var onCodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> LegacyCameraViewController {
        let vc = LegacyCameraViewController()
        vc.onCodeScanned = onCodeScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: LegacyCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {}

    static func dismantleUIViewController(_ uiViewController: LegacyCameraViewController, coordinator: Coordinator) {
        uiViewController.tearDown()
    }
}

private class LegacyCameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let sessionQueue = DispatchQueue(label: "com.wifimic.camera.legacy")
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        sessionQueue.async { [weak self] in
            self?.setupSession()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func setupSession() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ?? AVCaptureDevice.default(for: .video) else {
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            let session = AVCaptureSession()
            session.beginConfiguration()

            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                session.commitConfiguration()
                return
            }

            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
            } else {
                session.commitConfiguration()
                return
            }

            session.commitConfiguration()

            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let preview = AVCaptureVideoPreviewLayer(session: session)
                preview.videoGravity = .resizeAspectFill
                preview.frame = self.view.bounds
                self.view.layer.addSublayer(preview)
                self.previewLayer = preview
            }

            session.startRunning()
            self.captureSession = session
        } catch {
            print("[Camera] Setup error: \(error)")
        }
    }

    func tearDown() {
        sessionQueue.async { [weak self] in
            guard let self = self, let session = self.captureSession else { return }
            if session.isRunning {
                session.stopRunning()
            }
            self.captureSession = nil
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned else { return }
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let str = obj.stringValue,
              !str.isEmpty else {
            return
        }

        hasScanned = true
        tearDown()
        onCodeScanned?(str)
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
                path.move(to: CGPoint(x: 0, y: cornerLength))
                path.addLine(to: CGPoint(x: 0, y: cornerRadius))
                path.addQuadCurve(to: CGPoint(x: cornerRadius, y: 0), control: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: cornerLength, y: 0))

                path.move(to: CGPoint(x: w - cornerLength, y: 0))
                path.addLine(to: CGPoint(x: w - cornerRadius, y: 0))
                path.addQuadCurve(to: CGPoint(x: w, y: cornerRadius), control: CGPoint(x: w, y: 0))
                path.addLine(to: CGPoint(x: w, y: cornerLength))

                path.move(to: CGPoint(x: w, y: h - cornerLength))
                path.addLine(to: CGPoint(x: w, y: h - cornerRadius))
                path.addQuadCurve(to: CGPoint(x: w - cornerRadius, y: h), control: CGPoint(x: w, y: h))
                path.addLine(to: CGPoint(x: w - cornerLength, y: h))

                path.move(to: CGPoint(x: cornerLength, y: h))
                path.addLine(to: CGPoint(x: cornerRadius, y: h))
                path.addQuadCurve(to: CGPoint(x: 0, y: h - cornerRadius), control: CGPoint(x: 0, y: h))
                path.addLine(to: CGPoint(x: 0, y: h - cornerLength))
            }
            .stroke(Color.blue, style: StrokeStyle(lineWidth: cornerThickness, lineCap: .round))
        }
    }
}
