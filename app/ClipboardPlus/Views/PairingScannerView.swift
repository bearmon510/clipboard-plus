import AVFoundation
import SwiftUI
import UIKit

/// Reads the QR code that clipboard+ for Windows shows, to pair with that PC.
///
/// This uses AVFoundation rather than VisionKit's scanner: clipboard+ is mostly used in a side
/// window, where iPadOS stops the camera unless the session opts in to multitasking camera
/// access, and VisionKit's scanner gives no way to opt in.
struct PairingScannerView: View {
    /// Tries a scanned code. Returns a message to show when it is not a usable code, or nil
    /// when pairing worked and the sheet can close.
    let onCode: (String) -> String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var camera = QRCamera()
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var message: String?
    /// The camera reports the same code many times a second; try each one once.
    @State private var lastCode: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("QRコードを読む")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { dismiss() }
                    }
                }
        }
        .tint(Theme.accent)
        .task {
            if access == .notDetermined {
                access = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
            }
            guard access == .authorized, !Task.isCancelled else { return }
            camera.onCode = { handle($0) }
            camera.start()
        }
        .onDisappear { camera.stop() }
    }

    @ViewBuilder private var content: some View {
        switch access {
        case .notDetermined:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .authorized:
            scanner
        default:
            notice(symbol: "camera", title: "カメラが許可されていません",
                   text: "「設定」でclipboard+のカメラをオンにすると、QRコードを読めます。") {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        }
    }

    private var scanner: some View {
        ZStack {
            Color.black.ignoresSafeArea(edges: .bottom)
            CameraPreview(camera: camera)
                .ignoresSafeArea(edges: .bottom)
                .accessibilityHidden(true)
            switch camera.state {
            case .starting:
                ProgressView().tint(.white)
            case .running:
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 240, height: 240)
                    .accessibilityHidden(true)
                VStack {
                    Spacer()
                    guide
                }
            case .sideBySide:
                notice(symbol: "rectangle.split.2x1", title: "カメラが止められています",
                       text: "ほかのアプリと並べていると、カメラを使えないことがあります。clipboard+のウインドウを全画面にしてください。全画面にすると、そのまま読み取りが始まります。") {
                    Button("もう一度試す") { camera.start() }
                }
            case .busy:
                notice(symbol: "camera", title: "カメラを使えません",
                       text: "ほかのアプリがカメラを使っています。そのアプリを閉じてから、もう一度試してください。") {
                    Button("もう一度試す") { camera.start() }
                }
            case .failed:
                notice(symbol: "camera", title: "カメラを開けませんでした",
                       text: "少し待ってから、もう一度試してください。") {
                    Button("もう一度試す") { camera.start() }
                }
            }
        }
    }

    private var guide: some View {
        VStack(spacing: 6) {
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline.weight(.semibold))
            }
            Text("PCの「clipboard+ for Windows」に出ているQRコードを、枠の中に映してください。")
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .frame(maxWidth: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .padding(16)
    }

    private func notice<Action: View>(symbol: String, title: String, text: String,
                                      @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action()
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
        }
        .padding(24)
        .frame(maxWidth: 440)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .padding(20)
    }

    private func handle(_ code: String) {
        guard code != lastCode else { return }
        lastCode = code
        if let error = onCode(code) {
            message = error
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            camera.stop()
            dismiss()
        }
    }
}

/// The camera session that looks for QR codes, and why it is not showing anything.
final class QRCamera: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    enum State: Equatable {
        case starting, running
        /// iPadOS stopped the camera because other apps share the screen.
        case sideBySide
        /// Another app holds the camera, or the system needs it.
        case busy
        case failed
    }

    @Published private(set) var state = State.starting
    /// Called on the main thread with each code seen.
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    /// Configuring and starting the session block, so they run here, one at a time.
    private let queue = DispatchQueue(label: "clipboardplus.qr-camera")
    private var configured = false
    private var device: AVCaptureDevice?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session,
                               queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
                self?.interrupted(raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:)))
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session,
                               queue: .main) { [weak self] _ in
                self?.state = .running
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                               queue: .main) { [weak self] _ in
                self?.state = .failed
            },
        ]
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    func attach(_ layer: AVCaptureVideoPreviewLayer) {
        layer.session = session
        previewLayer = layer
        setUpRotation()
    }

    func start() {
        state = .starting
        queue.async { [self] in
            if !configured {
                configured = configure()
                guard configured else {
                    DispatchQueue.main.async { self.state = .failed }
                    return
                }
            }
            if !session.isRunning { session.startRunning() }
            let running = session.isRunning, interrupted = session.isInterrupted
            DispatchQueue.main.async {
                self.setUpRotation()
                // An interruption reported meanwhile has already set the precise state.
                guard self.state == .starting else { return }
                self.state = interrupted ? .sideBySide : running ? .running : .failed
            }
        }
    }

    func stop() {
        onCode = nil
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    /// Runs on `queue`.
    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else { return false }
        output.metadataObjectTypes = [.qr]
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Without this, a side window or Slide Over stops the camera as soon as it starts.
        // It is supported on iPads that can use Stage Manager with an external display.
        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }
        self.device = device
        return true
    }

    private func interrupted(_ reason: AVCaptureSession.InterruptionReason?) {
        switch reason {
        case .videoDeviceNotAvailableWithMultipleForegroundApps?: state = .sideBySide
        case .videoDeviceInUseByAnotherClient?, .videoDeviceNotAvailableDueToSystemPressure?: state = .busy
        // Leaving the screen; the camera comes back when the app does.
        case .videoDeviceNotAvailableInBackground?: state = .starting
        default: state = .busy
        }
    }

    /// Keeps the picture upright as the device turns.
    private func setUpRotation() {
        guard rotation == nil, let device, let layer = previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotation = coordinator
        applyRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                  options: [.new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { self?.applyRotation(angle) }
        }
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for object in metadataObjects {
            if let code = (object as? AVMetadataMachineReadableCodeObject)?.stringValue {
                onCode?(code)
                return
            }
        }
    }
}

private final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct CameraPreview: UIViewRepresentable {
    let camera: QRCamera

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attach(view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {}
}
