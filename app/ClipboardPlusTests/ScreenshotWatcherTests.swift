import Combine
import UIKit
import XCTest
@testable import ClipboardPlus

@MainActor
private final class ScreenshotTestClock {
    var date = Date(timeIntervalSince1970: 1_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

@MainActor
private final class FakeScreenshotLibrary: ScreenshotLibrary {
    var access: ScreenshotWatcher.Access = .authorized
    var requestedAccess = 0
    var observations = 0
    var observationStops = 0
    var onChange: (@MainActor (Date) -> Void)?
    var assets: [ScreenshotAsset] = []
    var queries: [Date] = []
    var loads: [String] = []
    var deleted: [[String]] = []
    var image = UIImage()
    var respectsWindow = true
    var deferAccess = false
    var deferFetch = false
    var deferLoad = false
    var deferDelete = false
    var accessCompletion: (@MainActor (ScreenshotWatcher.Access) -> Void)?
    var fetchCompletion: (@MainActor (ScreenshotAsset?) -> Void)?
    var loadCompletion: (@MainActor (Result<UIImage, Error>) -> Void)?
    var deleteCompletion: (@MainActor (Result<Int, Error>) -> Void)?
    var loadError: Error?
    var deleteError: Error?

    func requestAccess(completion: @escaping @MainActor (ScreenshotWatcher.Access) -> Void) {
        requestedAccess += 1
        if deferAccess { accessCompletion = completion }
        else { completion(access) }
    }
    func startObserving(onChange: @escaping @MainActor (Date) -> Void) {
        observations += 1
        self.onChange = onChange
    }
    func stopObserving() { observationStops += 1; onChange = nil }
    func latestScreenshot(since: Date, completion: @escaping @MainActor (ScreenshotAsset?) -> Void) {
        queries.append(since)
        if deferFetch { fetchCompletion = completion; return }
        completion(assets.filter { !respectsWindow || $0.takenAt >= since }.max { $0.takenAt < $1.takenAt })
    }
    func loadImage(for asset: ScreenshotAsset, completion: @escaping @MainActor (Result<UIImage, Error>) -> Void) {
        loads.append(asset.id)
        if deferLoad { loadCompletion = completion }
        else if let loadError { completion(.failure(loadError)) }
        else { completion(.success(image)) }
    }
    func delete(_ ids: [String], completion: @escaping @MainActor (Result<Int, Error>) -> Void) {
        deleted.append(ids)
        if deferDelete { deleteCompletion = completion }
        else if let deleteError { completion(.failure(deleteError)) }
        else { completion(.success(ids.count)) }
    }
}

final class ScreenshotWatcherTests: XCTestCase {
    @MainActor
    private func withWatcher(access: ScreenshotWatcher.Access = .authorized,
                             notificationCenter: NotificationCenter = NotificationCenter(),
                             _ body: (ScreenshotWatcher, FakeScreenshotLibrary, ScreenshotTestClock,
                                      UserDefaults, MeasurementLog) throws -> Void) throws {
        let root = try ImageTestSupport.directory(self)
        let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("screenshot-log.tsv")))
        let suite = "ScreenshotWatcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let library = FakeScreenshotLibrary()
        library.access = access
        let clock = ScreenshotTestClock()
        let watcher = ScreenshotWatcher(log: log, defaults: defaults, now: { clock.date }, library: library,
                                        notificationCenter: notificationCenter, schedulesTimers: false)
        defer {
            watcher.setEnabled(false)
            defaults.removePersistentDomain(forName: suite)
            let done = expectation(description: "screenshot log drained")
            log.flush(context: MeasurementEvent(kind: "test", changeCount: 0, scene: "active")) { done.fulfill() }
            wait(for: [done], timeout: 5)
            XCTAssertNil(log.errorMessage)
        }
        try body(watcher, library, clock, defaults, log)
    }

    @MainActor
    func testSystemNotificationIsObservedOnlyWhileEnabled() throws {
        let center = NotificationCenter()
        try withWatcher(notificationCenter: center) { watcher, library, clock, _, _ in
            clock.date = Date()
            center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
            XCTAssertTrue(library.queries.isEmpty)
            watcher.setEnabled(true)
            library.assets = [ScreenshotAsset(id: "notification", takenAt: clock.date)]
            let done = expectation(description: "system notification delivered")
            let subscription = watcher.$delivered.compactMap { $0 }.sink { _ in done.fulfill() }
            defer { subscription.cancel() }
            center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
            wait(for: [done], timeout: 5)
            XCTAssertEqual(watcher.delivered?.id, "notification")
            watcher.setEnabled(false)
            center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
            let drained = expectation(description: "notification queue drained")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 5)
            XCTAssertEqual(library.queries.count, 1)
        }
    }

    @MainActor
    func testFoundImageMayFinishDecodingAfterSearchDeadline() throws {
        try withWatcher { watcher, library, clock, _, _ in
            watcher.setEnabled(true)
            library.deferLoad = true
            library.assets = [ScreenshotAsset(id: "large-local-image", takenAt: clock.date)]
            watcher.receive(.notification, at: clock.date)
            clock.advance(5)
            watcher.checkForScreenshot()
            library.loadCompletion?(.success(library.image))
            XCTAssertEqual(watcher.delivered?.id, "large-local-image")
        }
    }

    @MainActor
    func testBothTriggerOrdersDeliverTheSameAssetOnlyOnce() throws {
        for first in [ScreenshotTrigger.notification, .libraryChange] {
            try withWatcher { watcher, library, clock, _, log in
                watcher.setEnabled(true)
                clock.advance(1)
                library.assets = [ScreenshotAsset(id: "test-shot", takenAt: clock.date)]
                library.deferLoad = true
                var deliveries = 0
                let subscription = watcher.$delivered.compactMap { $0 }.sink { _ in deliveries += 1 }
                defer { subscription.cancel() }
                watcher.receive(first, at: clock.date)
                watcher.receive(first == .notification ? .libraryChange : .notification, at: clock.date)
                XCTAssertEqual(library.loads.count, 1)
                library.loadCompletion?(.success(library.image))
                XCTAssertEqual(deliveries, 1)
                XCTAssertEqual(watcher.delivered?.id, "test-shot")
                watcher.delivered = nil
                clock.advance(0.3)
                watcher.checkForScreenshot()
                XCTAssertEqual(deliveries, 1)
                XCTAssertEqual(library.loads.count, 1)
                XCTAssertTrue(log.lines.contains { $0.fileLine.contains("trigger=notification") })
                XCTAssertTrue(log.lines.contains { $0.fileLine.contains("trigger=libraryChange") })
                XCTAssertFalse(log.lines.contains { $0.fileLine.contains("test-shot") })
            }
        }
    }

    @MainActor
    func testRejectsOlderThanFifteenSecondsAndBeforeEnabling() throws {
        for age in [16.0, 100.0] {
            try withWatcher { watcher, library, clock, _, _ in
                let enabledAt = clock.date
                watcher.setEnabled(true)
                clock.advance(30)
                library.respectsWindow = false // Controller also validates the adapter's result.
                library.assets = [ScreenshotAsset(id: "old", takenAt: clock.date.addingTimeInterval(-age))]
                watcher.receive(.notification, at: clock.date)
                XCTAssertEqual(library.queries.first, max(enabledAt, clock.date.addingTimeInterval(-15)))
                XCTAssertNil(watcher.delivered)
                XCTAssertTrue(library.loads.isEmpty)
            }
        }
        try withWatcher { watcher, library, clock, _, _ in
            library.assets = [ScreenshotAsset(id: "before-enable", takenAt: clock.date.addingTimeInterval(-1))]
            watcher.setEnabled(true)
            clock.advance(1)
            watcher.receive(.notification, at: clock.date)
            XCTAssertEqual(library.queries.first, clock.date.addingTimeInterval(-1))
            XCTAssertNil(watcher.delivered)
        }
    }

    @MainActor
    func testAcceptsExactFifteenSecondBoundaryAndChoosesNewest() throws {
        try withWatcher { watcher, library, clock, _, _ in
            watcher.setEnabled(true)
            clock.advance(30)
            library.assets = [ScreenshotAsset(id: "boundary", takenAt: clock.date.addingTimeInterval(-15)),
                              ScreenshotAsset(id: "too-old", takenAt: clock.date.addingTimeInterval(-16))]
            watcher.receive(.libraryChange, at: clock.date)
            XCTAssertEqual(watcher.delivered?.id, "boundary")
            watcher.delivered = nil
            clock.advance(1)
            library.assets.append(ScreenshotAsset(id: "newest", takenAt: clock.date))
            library.assets.append(ScreenshotAsset(id: "older", takenAt: clock.date.addingTimeInterval(-2)))
            library.onChange?(clock.date)
            XCTAssertEqual(watcher.delivered?.id, "newest")
        }
    }

    @MainActor
    func testRetriesAtPointThreeSecondsUntilAssetAppears() throws {
        try withWatcher { watcher, library, clock, _, log in
            watcher.setEnabled(true)
            clock.advance(1)
            watcher.receive(.notification, at: clock.date)
            XCTAssertEqual(library.queries.count, 1)
            clock.advance(0.29)
            watcher.checkForScreenshot()
            XCTAssertEqual(library.queries.count, 1)
            clock.advance(0.02)
            watcher.checkForScreenshot()
            XCTAssertEqual(library.queries.count, 2)
            library.assets = [ScreenshotAsset(id: "delayed", takenAt: clock.date)]
            clock.advance(0.31)
            watcher.checkForScreenshot()
            XCTAssertEqual(watcher.delivered?.id, "delayed")
            XCTAssertEqual(library.queries.count, 3)
            XCTAssertTrue(log.lines.contains { $0.primaryText.contains("発見") && $0.fileLine.contains("elapsed_ms=") })
            XCTAssertTrue(log.lines.contains { $0.fileLine.contains("pixels=") })
        }
    }

    @MainActor
    func testRepeatedTriggersDoNotExtendFourSecondDeadline() throws {
        try withWatcher { watcher, library, clock, _, log in
            watcher.setEnabled(true)
            watcher.receive(.notification, at: clock.date)
            for _ in 0..<13 {
                clock.advance(0.3)
                watcher.receive(.libraryChange, at: clock.date)
                watcher.checkForScreenshot()
            }
            clock.advance(0.11)
            watcher.checkForScreenshot()
            let count = library.queries.count
            clock.advance(1)
            watcher.checkForScreenshot()
            XCTAssertEqual(library.queries.count, count)
            XCTAssertNil(watcher.delivered)
            XCTAssertTrue(log.lines.contains { $0.primaryText.contains("見つからない") && $0.fileLine.contains("reason=") })
        }
    }

    @MainActor
    func testLateFetchCannotCompleteADifferentSearchAfterTimeout() throws {
        try withWatcher { watcher, library, clock, _, _ in
            watcher.setEnabled(true)
            library.deferFetch = true
            watcher.receive(.notification, at: clock.date)
            let old = library.fetchCompletion
            clock.advance(4)
            watcher.checkForScreenshot()
            watcher.receive(.libraryChange, at: clock.date)
            old?(ScreenshotAsset(id: "late", takenAt: clock.date))
            XCTAssertTrue(library.loads.isEmpty)
            library.fetchCompletion?(ScreenshotAsset(id: "current", takenAt: clock.date))
            XCTAssertEqual(watcher.delivered?.id, "current")
        }
    }

    @MainActor
    func testLimitedAndDeniedNeverEnableOrObserve() throws {
        for access in [ScreenshotWatcher.Access.limited, .denied, .notDetermined] {
            try withWatcher(access: access) { watcher, library, clock, defaults, _ in
                XCTAssertFalse(watcher.isEnabled)
                watcher.setEnabled(true)
                XCTAssertEqual(library.requestedAccess, 1)
                XCTAssertEqual(watcher.access, access)
                XCTAssertFalse(watcher.isEnabled)
                XCTAssertFalse(defaults.bool(forKey: "screenshotCaptureEnabled"))
                XCTAssertEqual(library.observations, 0)
                watcher.receive(.notification, at: clock.date)
                XCTAssertTrue(library.queries.isEmpty)
            }
        }
    }

    @MainActor
    func testLateAuthorizationCannotReenableAfterUserDisables() throws {
        try withWatcher { watcher, library, _, _, _ in
            library.deferAccess = true
            watcher.setEnabled(true)
            watcher.setEnabled(false)
            library.accessCompletion?(.authorized)
            XCTAssertFalse(watcher.isEnabled)
            XCTAssertEqual(library.observations, 0)
        }
    }

    @MainActor
    func testBackgroundStopsObserversAndRejectsLateImageThenResumes() throws {
        try withWatcher { watcher, library, clock, _, _ in
            watcher.setEnabled(true)
            library.assets = [ScreenshotAsset(id: "in-flight", takenAt: clock.date)]
            library.deferLoad = true
            watcher.receive(.notification, at: clock.date)
            let oldChange = library.onChange
            watcher.sceneDidChange(isActive: false)
            XCTAssertNil(library.onChange)
            library.loadCompletion?(.success(library.image))
            oldChange?(clock.date)
            watcher.receive(.notification, at: clock.date)
            XCTAssertNil(watcher.delivered)
            XCTAssertEqual(library.queries.count, 1)
            clock.advance(10)
            watcher.sceneDidChange(isActive: true)
            XCTAssertEqual(library.observations, 2)
            library.deferLoad = false
            library.assets = [ScreenshotAsset(id: "new", takenAt: clock.date)]
            library.onChange?(clock.date)
            XCTAssertEqual(watcher.delivered?.id, "new")
        }
    }

    @MainActor
    func testForegroundRefreshesRevokedAccess() throws {
        try withWatcher { watcher, library, _, _, _ in
            watcher.setEnabled(true)
            watcher.sceneDidChange(isActive: false)
            library.access = .limited
            watcher.sceneDidChange(isActive: true)
            XCTAssertEqual(watcher.access, .limited)
            XCTAssertFalse(watcher.isEnabled)
            XCTAssertNil(library.onChange)
        }
    }

    @MainActor
    func testEnabledAndDeduplicatedUsedLedgerPersist() throws {
        try withWatcher { watcher, _, clock, defaults, log in
            watcher.setEnabled(true)
            watcher.markUsed("first")
            watcher.markUsed("first")
            watcher.markUsed("second")
            XCTAssertEqual(watcher.usedCount, 2)
            XCTAssertEqual(defaults.stringArray(forKey: "screenshotCaptureUsedIDs"), ["first", "second"])
            let replacementLibrary = FakeScreenshotLibrary()
            let replacement = ScreenshotWatcher(log: log, defaults: defaults, now: { clock.date },
                                                 library: replacementLibrary, schedulesTimers: false)
            XCTAssertTrue(replacement.isEnabled)
            XCTAssertEqual(replacement.usedCount, 2)
            XCTAssertEqual(replacementLibrary.observations, 1)
            replacement.setEnabled(false)
        }
    }

    @MainActor
    func testDeleteSuccessClearsOnlyTheSubmittedLedgerAndReportsCount() throws {
        try withWatcher { watcher, library, _, defaults, log in
            watcher.markUsed("first")
            watcher.markUsed("second")
            library.deferDelete = true
            var count: Int?
            watcher.deleteUsed {
                if case .failure(let error) = $0 { XCTFail("\(error)") }
                if case .success(let value) = $0 { count = value }
            }
            XCTAssertEqual(library.deleted, [["first", "second"]])
            watcher.markUsed("third")
            library.deleteCompletion?(.success(2))
            XCTAssertEqual(count, 2)
            XCTAssertEqual(watcher.usedCount, 1)
            XCTAssertEqual(defaults.stringArray(forKey: "screenshotCaptureUsedIDs"), ["third"])
            library.deferDelete = false
            watcher.deleteUsed { if case .failure(let error) = $0 { XCTFail("\(error)") } }
            XCTAssertEqual(watcher.usedCount, 0)
            XCTAssertEqual(defaults.stringArray(forKey: "screenshotCaptureUsedIDs"), [])
            XCTAssertTrue(log.lines.contains { $0.fileLine.contains("result=success; count=2") })
        }
    }

    @MainActor
    func testDeleteFailureRetainsLedgerWithoutLoggingIdentifiersOrDescription() throws {
        try withWatcher { watcher, library, _, _, log in
            watcher.markUsed("private-photo-id")
            library.deleteError = NSError(domain: "TestDelete", code: 7,
                                           userInfo: [NSLocalizedDescriptionKey: "private-image-content"])
            var failed = false
            watcher.deleteUsed { if case .failure = $0 { failed = true } }
            XCTAssertTrue(failed)
            XCTAssertEqual(watcher.usedCount, 1)
            XCTAssertTrue(log.lines.contains { $0.fileLine.contains("domain=TestDelete; code=7") })
            XCTAssertFalse(log.lines.contains { $0.fileLine.contains("private-") })
        }
    }

    @MainActor
    func testUnavailableImageRetriesThenReportsFailureReason() throws {
        try withWatcher { watcher, library, clock, _, log in
            watcher.setEnabled(true)
            library.assets = [ScreenshotAsset(id: "cloud-only", takenAt: clock.date)]
            library.loadError = ScreenshotLibraryError.imageUnavailable
            watcher.receive(.notification, at: clock.date)
            clock.advance(0.31)
            watcher.checkForScreenshot()
            XCTAssertEqual(library.loads.count, 2)
            clock.advance(4)
            watcher.checkForScreenshot()
            XCTAssertNil(watcher.delivered)
            XCTAssertTrue(log.lines.contains { $0.fileLine.contains("reason=image unavailable") })
        }
    }
}
