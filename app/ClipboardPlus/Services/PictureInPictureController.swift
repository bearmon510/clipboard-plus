import AVFoundation
import AVKit
import Combine

@MainActor
final class PictureInPictureController: NSObject, ObservableObject {
    static let enabledKey = "pictureInPictureEnabled"
    @Published private(set) var isEnabled = false
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false
    @Published private(set) var isStarting = false
    @Published private(set) var failureMessage: String?

    let isSupported = AVPictureInPictureController.isPictureInPictureSupported()
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

    init(monitor: ClipboardMonitor, defaults: UserDefaults = .standard) {
        self.monitor = monitor
        self.defaults = defaults
        super.init()
        if defaults.bool(forKey: Self.enabledKey) { setEnabled(true) }
    }

    deinit { timer?.invalidate() }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        failureMessage = nil
        if enabled {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
            } catch { recordAudioFailure(error, operation: "有効化") }
            guard isSupported else { return }
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
            timer?.invalidate()
            timer = nil
            statusSubscription = nil
            controller?.stopPictureInPicture()
            // Stopping PiP is asynchronous; keep its delegate alive to record didStop.
            deactivateAudio()
        }
    }

    func togglePictureInPicture() {
        guard isEnabled, let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible && !isStarting {
            failureMessage = nil
            isStarting = true
            enqueueFrame()
            controller.startPictureInPicture()
        }
    }

    private func prepareController() {
        displayLayer.videoGravity = .resizeAspect
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        // canStartPictureInPictureAutomaticallyFromInline stays at its default false.
        controller = pip
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            DispatchQueue.main.async { self?.isPossible = possible }
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
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStarting = false
        isActive = true
        record("PiPの開始")
        // Handle switching the setting off while the system was starting PiP.
        if !isEnabled { pictureInPictureController.stopPictureInPicture() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStarting = false
        isActive = false
        record("PiPの終了")
        if !isEnabled { deactivateAudio() }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        isStarting = false
        isActive = false
        let error = error as NSError
        record("PiPの開始失敗", details: "domain=\(error.domain); code=\(error.code)")
        failureMessage = "PiPを開始できませんでした。計測ログを確認してください。"
    }
}
