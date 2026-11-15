import Combine
import Foundation
import UIKit

enum ScreenCaptureError: Error, Equatable {
    case unsupported
    case declined
    case failed(String)
    case timeout
}

// The controller and its tests do not depend on ScreenCaptureKit. A source owns
// just the latest buffer and converts it off the main thread only on demand.
enum ScreenCaptureSourceEvent {
    case permissionGranted(contentRect: CGRect, pointPixelScale: CGFloat)
    case started(Date)
    case frameReceived(at: Date, width: Int, height: Int)
    case frameInvalidated
    case declined
    case failed(domain: String, code: Int)
}

// A frame can become unavailable while conversion is queued/in progress. This
// is a retryable source condition, not a failure of the public request.
enum ScreenCaptureFrameResult {
    case success(UIImage)
    case unavailable
    case failure(ScreenCaptureError)
}

@MainActor
protocol ScreenCaptureSource: AnyObject {
    var isSupported: Bool { get }
    var onEvent: (@MainActor (ScreenCaptureSourceEvent) -> Void)? { get set }
    func requestPermission()
    func convertLatestFrame(notBefore: Date,
                            completion: @escaping @MainActor (ScreenCaptureFrameResult) -> Void)
    func stop()
}

@MainActor
final class ScreenCaptureController: ObservableObject {
    enum State: Equatable { case unsupported, idle, requestingPermission, starting, running }
    @Published private(set) var state: State
    var isSupported: Bool { source.isSupported }

    private let log: MeasurementLog
    private let now: () -> Date
    private let source: ScreenCaptureSource
    private let schedulesTimers: Bool
    private var timer: Timer?
    private var pending: [@MainActor (Result<UIImage, ScreenCaptureError>) -> Void] = []
    private var generation = UUID()
    private var requestedAt: Date?
    private var startedAt: Date?
    private var lastUsedAt: Date?
    private var requestDeadline: Date?
    private var hasUsableFrame = false
    private var isConverting = false
    private var frameValidity = UUID()
    private var frameVersion = UUID()
    private var sceneIsActive = true
    /// When the person approved capture in this session. The first frames after it can still
    /// show the system permission screen, so they are not used until that screen is gone.
    private var grantedAt: Date?
    /// When this app became active again after the approval, which happens as the system
    /// permission screen goes away. Nil until then.
    private var reactivatedAfterGrant: Date?

    private static let settlingInterval: TimeInterval = 0.6
    /// How long after this app becomes active again the permission screen is assumed gone.
    private static let afterReactivation: TimeInterval = 0.5
    /// Used when the app is never seen becoming active again after the approval.
    private static let afterGrantFallback: TimeInterval = 2.5
    private static let frameTimeout: TimeInterval = 8
    private static let idleTimeout: TimeInterval = 5 * 60

    init(log: MeasurementLog, now: @escaping () -> Date = Date.init,
         source: ScreenCaptureSource? = nil, schedulesTimers: Bool = true) {
        self.log = log
        self.now = now
        self.source = source ?? makeScreenCaptureSource()
        self.schedulesTimers = schedulesTimers
        state = self.source.isSupported ? .idle : .unsupported
    }

    deinit {
        timer?.invalidate()
        let source = source
        Task { @MainActor in
            source.onEvent = nil
            source.stop()
        }
    }

    /// 取り込み中なら最新の1コマを返し、停止中なら許可と開始を待つ。
    func requestFrame(completion: @escaping @MainActor (Result<UIImage, ScreenCaptureError>) -> Void) {
        guard isSupported else { completion(.failure(.unsupported)); return }
        guard sceneIsActive else { completion(.failure(.failed("scene inactive"))); return }
        checkDeadlines()
        pending.append(completion)
        if requestDeadline == nil, state == .starting || state == .running {
            requestDeadline = now().addingTimeInterval(Self.frameTimeout)
        }
        if state == .idle {
            generation = UUID()
            let token = generation
            source.onEvent = { [weak self] event in
                guard let self, self.generation == token else { return }
                self.receive(event)
            }
            requestedAt = now()
            state = .requestingPermission
            record("画面取り込みの許可画面を表示")
            startTimerIfNeeded()
            source.requestPermission()
        } else {
            deliverLatestFrameIfReady()
        }
    }

    func stop(reason: String) {
        finishSession(reason: reason, error: .failed(reason))
    }

    func sceneDidChange(isActive: Bool) {
        sceneIsActive = isActive
        if !isActive { stop(reason: "scene inactive") }
    }

    /// Called each time the scene becomes active. After an approval, the first such moment
    /// marks the system permission screen going away.
    func sceneDidActivate() {
        guard let grantedAt, reactivatedAfterGrant == nil else { return }
        let date = now()
        guard date >= grantedAt else { return }
        reactivatedAfterGrant = date
        record("許可後に前面へ復帰", details: "grant_ms=\(Int(date.timeIntervalSince(grantedAt) * 1000))")
        deliverLatestFrameIfReady()
    }

    /// Frames older than this may still show the permission screen or the moment before it.
    private var usableFrom: Date? {
        guard let startedAt else { return nil }
        var earliest = startedAt.addingTimeInterval(Self.settlingInterval)
        if let grantedAt {
            let afterPermission = reactivatedAfterGrant.map { $0.addingTimeInterval(Self.afterReactivation) }
                ?? grantedAt.addingTimeInterval(Self.afterGrantFallback)
            earliest = max(earliest, afterPermission)
        }
        return earliest
    }

    func noteCaptureUsed() {
        guard state == .running else { return }
        lastUsedAt = now()
    }

    // Called by the production timer and directly with a fake clock in tests.
    func checkDeadlines() {
        let date = now()
        if let deadline = requestDeadline, date >= deadline {
            finishSession(reason: "frame timeout", error: .timeout)
        } else if let lastUsedAt, date.timeIntervalSince(lastUsedAt) >= Self.idleTimeout {
            stop(reason: "unused for 5 minutes")
        }
    }

    private func startTimerIfNeeded() {
        guard schedulesTimers, timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkDeadlines() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func receive(_ event: ScreenCaptureSourceEvent) {
        let token = generation
        checkDeadlines()
        guard generation == token else { return }
        guard state != .idle, state != .unsupported else { return }
        switch event {
        case .permissionGranted(let rect, let scale):
            guard state == .requestingPermission else { return }
            state = .starting
            grantedAt = now()
            reactivatedAfterGrant = nil
            requestDeadline = now().addingTimeInterval(Self.frameTimeout)
            record("画面取り込みの許可", details: "contentRect=\(rect); pointPixelScale=\(scale)")
        case .started(let date):
            guard state == .starting else { return }
            startedAt = date
            // Also stop abandoned crop sessions that never call noteCaptureUsed.
            lastUsedAt = date
            state = .running
            record("画面取り込みの開始成功")
        case .frameReceived(let date, let width, let height):
            guard state == .running, let startedAt, let usableFrom = self.usableFrom,
                  date >= usableFrom, width > 0, height > 0 else { return }
            if !hasUsableFrame {
                let elapsed = max(0, date.timeIntervalSince(requestedAt ?? startedAt))
                let streaming = max(0, date.timeIntervalSince(startedAt))
                record("画面取り込みの最初のコマ", details:
                    "request_ms=\(Int(elapsed * 1000)); start_ms=\(Int(streaming * 1000)); pixels=\(width)x\(height)")
            }
            hasUsableFrame = true
            frameVersion = UUID()
            deliverLatestFrameIfReady()
        case .frameInvalidated:
            hasUsableFrame = false
            frameValidity = UUID()
        case .declined:
            record("画面取り込みの許可取り消し")
            finishSession(reason: "picker cancelled", error: .declined)
        case .failed(let domain, let code):
            let reason = "\(domain) (\(code))"
            record(state == .running ? "画面取り込みの映像停止" : "画面取り込みの開始失敗",
                   details: "domain=\(domain); code=\(code)")
            finishSession(reason: reason, error: .failed(reason))
        }
    }

    private func deliverLatestFrameIfReady() {
        guard hasUsableFrame, !pending.isEmpty, !isConverting, let usableFrom else { return }
        isConverting = true
        let token = generation
        let validity = frameValidity
        let version = frameVersion
        source.convertLatestFrame(notBefore: usableFrom) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.checkDeadlines()
            guard self.generation == token else { return }
            self.isConverting = false
            guard self.frameValidity == validity else {
                self.deliverLatestFrameIfReady()
                return
            }
            switch result {
            case .success(let image):
                self.completeRequests(.success(image))
            case .unavailable:
                if self.frameVersion == version { self.hasUsableFrame = false }
                self.deliverLatestFrameIfReady()
            case .failure(let error):
                self.finishSession(reason: "frame conversion failed", error: error)
            }
        }
    }

    private func completeRequests(_ result: Result<UIImage, ScreenCaptureError>) {
        let callbacks = pending
        pending.removeAll()
        requestDeadline = nil
        // Clear bookkeeping before invoking clients, which may request again.
        for callback in callbacks { callback(result) }
    }

    private func finishSession(reason: String, error: ScreenCaptureError) {
        guard state != .idle, state != .unsupported else { return }
        generation = UUID()
        source.onEvent = nil
        source.stop()
        timer?.invalidate()
        timer = nil
        hasUsableFrame = false
        isConverting = false
        requestedAt = nil
        startedAt = nil
        lastUsedAt = nil
        grantedAt = nil
        reactivatedAfterGrant = nil
        state = .idle
        record("画面取り込みの停止", details: "reason=\(reason)")
        completeRequests(.failure(error))
    }

    private func record(_ kind: String, details: String = "") {
        // This path never reads the pasteboard or includes image/text content.
        log.append(MeasurementEvent(timestamp: now(), kind: kind, changeCount: 0,
                                    scene: sceneIsActive ? "active" : "inactive", details: details))
    }
}

@MainActor
private final class UnsupportedScreenCaptureSource: ScreenCaptureSource {
    let isSupported = false
    var onEvent: (@MainActor (ScreenCaptureSourceEvent) -> Void)?
    func requestPermission() {}
    func stop() {}
    func convertLatestFrame(notBefore: Date,
                            completion: @escaping @MainActor (ScreenCaptureFrameResult) -> Void) {
        completion(.failure(.unsupported))
    }
}

@MainActor
private func makeScreenCaptureSource() -> ScreenCaptureSource {
    #if canImport(ScreenCaptureKit)
    if #available(iOS 27.0, *) { return ScreenCaptureKitSource() }
    #endif
    return UnsupportedScreenCaptureSource()
}
