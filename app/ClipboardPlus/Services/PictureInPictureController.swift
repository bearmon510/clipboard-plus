import AVFoundation
import AVKit
import Combine

@MainActor
final class PictureInPictureController: NSObject, ObservableObject {
    static let enabledKey = "pictureInPictureEnabled"
    static let automaticallyStartsKey = "pictureInPictureAutomaticallyStarts"
    @Published private(set) var isEnabled = false
    @Published private(set) var automaticallyStarts: Bool
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false
    @Published private(set) var isStarting = false
    @Published private(set) var failureMessage: String?

    let isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    var canStartAutomatically: Bool {
        controller?.canStartPictureInPictureAutomaticallyFromInline ?? false
    }
    // Do not create a layer, controller, timer or audio session while disabled at launch.
    private(set) lazy var displayLayer = AVSampleBufferDisplayLayer()
    private let monitor: ClipboardMonitor
    private let defaults: UserDefaults
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var suspendedObservation: NSKeyValueObservation?
    private var statusSubscription: AnyCancellable?
    private var timer: Timer?
    private var status: PictureInPictureStatus?
    private var lastFrameError: String?
    private var lastLayerError: String?
    private var sourceIsReady = false
    private var startRequested = false
    private var startTimeout: Task<Void, Never>?

    init(monitor: ClipboardMonitor, defaults: UserDefaults = .standard) {
        self.monitor = monitor
        self.defaults = defaults
        automaticallyStarts = defaults.object(forKey: Self.automaticallyStartsKey) as? Bool ?? true
        super.init()
        if defaults.bool(forKey: Self.enabledKey) { setEnabled(true) }
    }

    deinit {
        timer?.invalidate()
        startTimeout?.cancel()
    }

    func setAutomaticallyStarts(_ enabled: Bool) {
        automaticallyStarts = enabled
        defaults.set(enabled, forKey: Self.automaticallyStartsKey)
        updateAutomaticStart()
    }

    private func updateAutomaticStart(recording: Bool? = nil) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = PictureInPicturePolicy.canStartAutomatically(
            isEnabled: isEnabled, isRecording: recording ?? monitor.isRecording, automaticallyStarts: automaticallyStarts
        )
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        failureMessage = nil
        updateAutomaticStart()
        if enabled {
            guard isSupported else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
            } catch { recordAudioFailure(error, operation: "有効化") }
            if controller == nil { prepareController() }
            statusSubscription = monitor.$entries.combineLatest(monitor.$isRecording, monitor.$savedCount)
                .sink { [weak self] entries, recording, saved in
                    guard let self else { return }
                    let recordingChanged = self.status?.isRecording != recording
                    self.status = PictureInPictureStatus(
                        isRecording: recording,
                        textCount: entries.filter { $0.kind != .image }.count,
                        imageCount: entries.filter { $0.kind == .image }.count,
                        lastCollectedAt: entries.map(\.lastCollectedAt).max(),
                        updatedAt: Date(), timeZone: .current, savedCount: saved
                    )
                    // @Published delivers in willSet; use the emitted value, not monitor.isRecording.
                    self.updateAutomaticStart(recording: recording)
                    if !recording { self.cancelPendingStart() }
                    if recordingChanged { self.controller?.invalidatePlaybackState() }
                    self.enqueueFrame()
                }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                // Keep the timer weak so the run loop cannot retain this owner forever.
                DispatchQueue.main.async { self?.enqueueFrame() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            cancelPendingStart()
            sourceIsReady = false
            timer?.invalidate()
            timer = nil
            statusSubscription = nil
            controller?.stopPictureInPicture()
            // Stopping PiP is asynchronous; keep its delegate alive to record didStop.
            deactivateAudio()
        }
    }

    // The request can be replaced in tests; enabling and recording use the real paths.
    func togglePictureInPicture(start: (() -> Void)? = nil) {
        if isActive {
            controller?.stopPictureInPicture()
            return
        }
        guard !isStarting else { return }
        setEnabled(true)
        if !monitor.isRecording { monitor.start() }
        if let start { start() } else { requestStart() }
    }

    private func requestStart() {
        guard isSupported, controller != nil else { return }
        failureMessage = nil
        startRequested = true
        isStarting = true
        // Enabling first inserts the UIView on the next SwiftUI update. Wait for
        // both its window/layout and AVKit's KVO readiness instead of requiring a second tap.
        startTimeout?.cancel()
        startTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard let self, self.startRequested else { return }
            self.cancelPendingStart()
            self.failureMessage = "PiPの準備ができませんでした。画面を開いたまま、もう一度PiPを押してください。"
            self.record("PiPの開始待ち時間切れ")
        }
        enqueueFrame()
        startIfReady()
    }

    func sourceReadinessChanged(_ ready: Bool) {
        sourceIsReady = ready
        startIfReady()
    }

    private func startIfReady() {
        guard startRequested, isEnabled, monitor.isRecording, sourceIsReady,
              let controller, controller.isPictureInPicturePossible else { return }
        startRequested = false
        startTimeout?.cancel()
        startTimeout = nil
        controller.startPictureInPicture()
    }

    private func cancelPendingStart() {
        guard startRequested else { return }
        startRequested = false
        isStarting = false
        startTimeout?.cancel()
        startTimeout = nil
    }

    private func prepareController() {
        displayLayer.videoGravity = .resizeAspect
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        controller = pip
        updateAutomaticStart()
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            DispatchQueue.main.async {
                self?.isPossible = possible
                self?.startIfReady()
            }
        }
        suspendedObservation = pip.observe(\.isPictureInPictureSuspended, options: [.new]) { [weak self] pip, _ in
            let suspended = pip.isPictureInPictureSuspended
            DispatchQueue.main.async {
                self?.record("PiPの中断状態", details: "isPictureInPictureSuspended=\(suspended)")
            }
        }
    }

    private func enqueueFrame() {
        guard isEnabled, let status else { return }
        let frameStatus = PictureInPictureStatus(
            isRecording: status.isRecording, textCount: status.textCount, imageCount: status.imageCount,
            lastCollectedAt: status.lastCollectedAt, updatedAt: Date(), timeZone: .current,
            savedCount: status.savedCount
        )
        do {
            let pixelBuffer = try PictureInPictureFrame.render(frameStatus)
            let sample = try PictureInPictureFrame.makeSampleBuffer(
                from: pixelBuffer, presentationTime: CMClockGetTime(CMClockGetHostTimeClock())
            )
            if displayLayer.status == .failed {
                // enqueue does not throw; the layer reports its asynchronous failure only here.
                let error = displayLayer.error as NSError?
                let message = "domain=\(error?.domain ?? "-"); code=\(error?.code ?? 0); requiresFlushToResumeDecoding=\(displayLayer.requiresFlushToResumeDecoding)"
                if message != lastLayerError { record("PiPの表示レイヤー失敗", details: message) }
                lastLayerError = message
                displayLayer.flush()
            } else {
                lastLayerError = nil
            }
            displayLayer.enqueue(sample)
            lastFrameError = nil
        } catch {
            let message = String(describing: error)
            // A persistent frame failure should not produce one log entry per second.
            if message != lastFrameError { record("PiPの描画失敗", details: message) }
            lastFrameError = message
            failureMessage = "PiPの画面を作れませんでした。計測ログを確認してください。"
        }
    }

    private func deactivateAudio() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch { recordAudioFailure(error, operation: "無効化") }
    }

    private func recordAudioFailure(_ error: Error, operation: String) {
        let error = error as NSError
        record("オーディオセッションの失敗", details: "操作=\(operation); domain=\(error.domain); code=\(error.code)")
        failureMessage = "オーディオセッションの設定に失敗しました。計測ログを確認してください。"
    }

    private func record(_ kind: String, details: String = "") {
        let context = monitor.logContext()
        monitor.log.append(MeasurementEvent(kind: kind, changeCount: context.changeCount, scene: context.scene, details: details))
    }
}

extension PictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        status?.isPlaybackPaused ?? true
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled else { return }
            self.record("PiPの再生操作（\(playing ? "開始" : "停止")）")
            if playing { self.monitor.start() } else { self.monitor.stop() }
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
}

extension PictureInPictureController: AVPictureInPictureControllerDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
        // The single-window root and its source view remain mounted while PiP is active.
        record("PiPから本体へ戻る")
        completionHandler(true)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        cancelPendingStart()
        isStarting = false
        isActive = true
        record("PiPの開始")
        // Handle switching the setting off while the system was starting PiP.
        if !isEnabled { pictureInPictureController.stopPictureInPicture() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        cancelPendingStart()
        isStarting = false
        isActive = false
        record("PiPの終了")
        if !isEnabled { deactivateAudio() }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        cancelPendingStart()
        isStarting = false
        isActive = false
        let error = error as NSError
        record("PiPの開始失敗", details: "domain=\(error.domain); code=\(error.code)")
        failureMessage = "PiPを開始できませんでした。計測ログを確認してください。"
    }
}
