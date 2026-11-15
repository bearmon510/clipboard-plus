import Combine
import Foundation
import UIKit

struct DeliveredScreenshot: Identifiable, Equatable {
    let id: String
    let image: UIImage
    let takenAt: Date
}

struct ScreenshotAsset: Equatable {
    let id: String
    let takenAt: Date
    // Only the observer's incremental insertion establishes this timestamp.
    var insertedAt: Date? = nil
}

enum ScreenshotTrigger: String {
    case notification
    case libraryChange
}

enum ScreenshotLibraryError: Error {
    case accessDenied
    case imageUnavailable
    case decodingFailed
    case deletionFailed
    case deletionInProgress
}

// PhotoKit is confined to the adapter. All callbacks cross back to the main
// actor; fetching, reading and decoding must run on the adapter's worker queue.
@MainActor
protocol ScreenshotLibrary: AnyObject {
    var access: ScreenshotWatcher.Access { get }
    func requestAccess(completion: @escaping @MainActor (ScreenshotWatcher.Access) -> Void)
    func startObserving(onChange: @escaping @MainActor (Date) -> Void)
    func stopObserving()
    func screenshots(since: Date, completion: @escaping @MainActor ([ScreenshotAsset]) -> Void)
    func loadImage(for asset: ScreenshotAsset, completion: @escaping @MainActor (Result<UIImage, Error>) -> Void)
    func delete(_ ids: [String], completion: @escaping @MainActor (Result<Int, Error>) -> Void)
}

@MainActor
final class ScreenshotWatcher: ObservableObject {
    enum Access: Equatable { case notDetermined, denied, limited, authorized }
    @Published private(set) var isEnabled: Bool
    @Published private(set) var access: Access
    @Published private(set) var usedCount: Int
    @Published var delivered: DeliveredScreenshot?

    private let log: MeasurementLog
    private let defaults: UserDefaults
    private let library: ScreenshotLibrary
    private let now: () -> Date
    private let notificationCenter: NotificationCenter
    private let schedulesTimers: Bool
    private var notificationObserver: NSObjectProtocol?
    private var timer: Timer?
    private var sceneIsActive = true
    private var isMonitoring = false
    private var enabledSince: Date?
    private var monitoringSince: Date?
    private var notificationDates: [Date] = []
    private var hasReceivedNotification = false
    private var seen: Set<String> = []
    private var used: Set<String>
    private var deleting = false
    private var enableGeneration = UUID()
    private var generation = UUID()
    private var search: Search?

    private struct Search {
        let id = UUID()
        let triggeredAt: Date
        let since: Date
        let deadline: Date
        var nextAttempt: Date
        var busy = false
        var loading = false
        var reason = "no matching screenshot"
        // A change during an in-flight fetch/load may refer to a newer asset.
        var followup: (ScreenshotTrigger, Date)?
    }

    init(log: MeasurementLog, defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init, library: ScreenshotLibrary? = nil,
         notificationCenter: NotificationCenter = .default, schedulesTimers: Bool = true) {
        self.log = log
        self.defaults = defaults
        self.now = now
        self.library = library ?? PhotoScreenshotLibrary()
        self.notificationCenter = notificationCenter
        self.schedulesTimers = schedulesTimers
        let initialAccess = self.library.access
        let initialEnabled = defaults.bool(forKey: "screenshotCaptureEnabled") && initialAccess == .authorized
        let initialUsed = Set(defaults.stringArray(forKey: "screenshotCaptureUsedIDs") ?? [])
        access = initialAccess
        isEnabled = initialEnabled
        used = initialUsed
        usedCount = initialUsed.count
        seen = initialUsed
        defaults.set(initialEnabled, forKey: "screenshotCaptureEnabled")
        if initialEnabled {
            enabledSince = now()
            startMonitoring()
        }
    }

    deinit {
        timer?.invalidate()
        if let notificationObserver { notificationCenter.removeObserver(notificationObserver) }
        let library = library
        Task { @MainActor in library.stopObserving() }
    }

    func setEnabled(_ on: Bool) {
        enableGeneration = UUID()
        guard on else {
            hasReceivedNotification = false
            isEnabled = false
            defaults.set(false, forKey: "screenshotCaptureEnabled")
            enabledSince = nil
            stopMonitoring()
            return
        }
        access = library.access
        if isEnabled, access == .authorized { startMonitoring(); return }
        let token = enableGeneration
        library.requestAccess { [weak self] access in
            guard let self, self.enableGeneration == token else { return }
            self.access = access
            self.isEnabled = access == .authorized
            self.defaults.set(self.isEnabled, forKey: "screenshotCaptureEnabled")
            self.record("スクリーンショットの許可", details: "access=\(access)")
            if self.isEnabled {
                self.hasReceivedNotification = false
                self.enabledSince = self.now()
                self.startMonitoring()
            } else {
                self.enabledSince = nil
                self.stopMonitoring()
            }
        }
    }

    func sceneDidChange(isActive: Bool) {
        sceneIsActive = isActive
        if !isActive { stopMonitoring(); return }
        access = library.access
        if access != .authorized {
            isEnabled = false
            defaults.set(false, forKey: "screenshotCaptureEnabled")
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    private func startMonitoring() {
        guard isEnabled, sceneIsActive, !isMonitoring else { return }
        isMonitoring = true
        monitoringSince = now()
        notificationDates.removeAll()
        generation = UUID()
        let token = generation
        notificationObserver = notificationCenter.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Capture the receipt time before hopping to the actor.
            let date = Date()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.receive(.notification, at: date)
            }
        }
        library.startObserving { [weak self] date in
            guard let self, self.generation == token else { return }
            self.receive(.libraryChange, at: date)
        }
    }

    private func stopMonitoring() {
        generation = UUID()
        isMonitoring = false
        monitoringSince = nil
        if let notificationObserver { notificationCenter.removeObserver(notificationObserver) }
        notificationObserver = nil
        library.stopObserving()
        finishSearch()
        delivered = nil
    }

    // Internal entry point also permits deterministic trigger/clock tests.
    func receive(_ trigger: ScreenshotTrigger, at date: Date) {
        guard isEnabled, isMonitoring, sceneIsActive,
              let enabledSince, let monitoringSince, date >= monitoringSince else { return }
        guard library.access == .authorized else {
            access = library.access
            isEnabled = false
            defaults.set(false, forKey: "screenshotCaptureEnabled")
            stopMonitoring()
            return
        }
        record("スクリーンショットのきっかけ", details: "trigger=\(trigger.rawValue)")
        if trigger == .notification {
            hasReceivedNotification = true
            notificationDates.append(date)
        }
        if let search, !search.loading, now() >= search.deadline { checkForScreenshot() }
        if search != nil {
            // Do not move the deadline when the second notification arrives.
            if search?.busy == true { search?.followup = (trigger, date) }
            return
        }
        let since = max(max(enabledSince, monitoringSince), date.addingTimeInterval(-15))
        search = Search(triggeredAt: date, since: since,
                        deadline: date.addingTimeInterval(4), nextAttempt: now())
        if schedulesTimers {
            // A fine tick handles the 4-second deadline; actual fetches stay 0.3s apart.
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.checkForScreenshot() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        checkForScreenshot()
    }

    func checkForScreenshot() {
        guard let search, isMonitoring else { return }
        // The four-second budget is for finding the asset, not decoding a large
        // local image that has already been found. Stop/background still cancels delivery.
        guard !search.loading else { return }
        if now() >= search.deadline {
            record("スクリーンショットが見つからない", details:
                "elapsed_ms=\(elapsed(since: search.triggeredAt)); reason=\(search.reason)")
            finishSearch()
            return
        }
        guard !search.busy, now() >= search.nextAttempt else { return }
        self.search?.busy = true
        let token = generation
        library.screenshots(since: search.since) { [weak self] assets in
            guard let self, self.generation == token, let current = self.search, current.id == search.id else { return }
            guard self.now() < current.deadline else { self.checkForScreenshot(); return }
            // Filter before choosing the newest: a future-dated or already seen
            // asset must not starve other eligible insertions.
            guard let asset = assets.filter({
                !self.seen.contains($0.id) && self.deliveryRoute(for: $0, search: current) != nil
            }).max(by: { $0.takenAt < $1.takenAt }) else {
                self.retry(reason: "no matching insertion"); return
            }
            self.record("スクリーンショットを発見", details: "elapsed_ms=\(self.elapsed(since: current.triggeredAt))")
            self.search?.loading = true
            self.library.loadImage(for: asset) { [weak self] result in
                guard let self, self.generation == token, let current = self.search, current.id == search.id else { return }
                switch result {
                case .success(let image):
                    // A first notification can arrive while decoding a fallback
                    // candidate. Apply the stricter rule before exposing the image.
                    guard let route = self.deliveryRoute(for: asset, search: current) else {
                        self.retry(reason: "notification no longer matches insertion"); return
                    }
                    guard self.seen.insert(asset.id).inserted else { self.retry(reason: "already delivered"); return }
                    let followup = current.followup
                    self.record("スクリーンショットを受け取り", details:
                        "elapsed_ms=\(self.elapsed(since: current.triggeredAt)); route=\(route); pixels=\(image.cgImage?.width ?? 0)x\(image.cgImage?.height ?? 0)")
                    self.finishSearch()
                    self.delivered = DeliveredScreenshot(id: asset.id, image: image, takenAt: asset.takenAt)
                    if let followup { self.receive(followup.0, at: followup.1) }
                case .failure(let error):
                    // Never log a description/userInfo, which may contain paths or IDs.
                    let error = error as NSError
                    self.retry(reason: "image unavailable; domain=\(error.domain); code=\(error.code)")
                }
            }
        }
    }

    private func deliveryRoute(for asset: ScreenshotAsset, search: Search) -> String? {
        guard let monitoringSince, let insertedAt = asset.insertedAt,
              insertedAt >= monitoringSince, insertedAt <= now(),
              asset.takenAt >= search.since,
              asset.takenAt <= search.triggeredAt.addingTimeInterval(5),
              asset.takenAt <= insertedAt.addingTimeInterval(5) else { return nil }
        if hasReceivedNotification {
            return notificationDates.contains { abs(insertedAt.timeIntervalSince($0)) <= 5 }
                ? "notification" : nil
        }
        return asset.takenAt >= insertedAt.addingTimeInterval(-10) ? "insertionFallback" : nil
    }

    private func retry(reason: String) {
        search?.busy = false
        search?.loading = false
        search?.reason = reason
        search?.nextAttempt = now().addingTimeInterval(0.3)
    }

    private func finishSearch() {
        // Invalidate outstanding fetch/load completions, including after timeout.
        search = nil
        timer?.invalidate()
        timer = nil
    }

    func markUsed(_ id: String) {
        guard !id.isEmpty, used.insert(id).inserted else { return }
        saveUsed()
    }

    func deleteUsed(completion: @escaping @MainActor (Result<Int, Error>) -> Void) {
        guard !deleting else {
            record("スクリーンショットの削除", details: "result=skipped; reason=in progress")
            completion(.failure(ScreenshotLibraryError.deletionInProgress)); return
        }
        access = library.access
        guard access == .authorized else {
            record("スクリーンショットの削除", details: "result=failure; reason=access denied")
            completion(.failure(ScreenshotLibraryError.accessDenied)); return
        }
        let deletingIDs = used
        guard !deletingIDs.isEmpty else {
            record("スクリーンショットの削除", details: "result=success; count=0")
            completion(.success(0)); return
        }
        deleting = true
        library.delete(deletingIDs.sorted()) { [self] result in
            deleting = false
            switch result {
            case .success(let count):
                // Preserve screenshots marked while the system confirmation was open.
                used.subtract(deletingIDs)
                saveUsed()
                record("スクリーンショットの削除", details: "result=success; count=\(count)")
            case .failure(let error):
                let error = error as NSError
                record("スクリーンショットの削除", details: "result=failure; domain=\(error.domain); code=\(error.code)")
            }
            completion(result)
        }
    }

    private func saveUsed() {
        defaults.set(used.sorted(), forKey: "screenshotCaptureUsedIDs")
        usedCount = used.count
    }

    private func elapsed(since date: Date) -> Int { Int(max(0, now().timeIntervalSince(date)) * 1000) }

    private func record(_ kind: String, details: String) {
        log.append(MeasurementEvent(timestamp: now(), kind: kind, changeCount: 0,
                                    scene: sceneIsActive ? "active" : "inactive", details: details))
    }
}
