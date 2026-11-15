import AppIntents
import UIKit
import XCTest
@testable import ClipboardPlus

@MainActor
private final class ShortcutPasteboard: ClipboardPasteboard {
    private(set) var changeCount = 0
    private(set) var reads = 0
    private(set) var writes = 0
    private(set) var storedText: String?
    private(set) var storedImage: Data?
    var hasImages: Bool { reads += 1; return storedImage != nil }
    var hasStrings: Bool { reads += 1; return storedText != nil }
    var types: [String] { reads += 1; return storedImage == nil ? ["public.utf8-plain-text"] : ["public.png"] }
    var image: UIImage? { reads += 1; return storedImage.flatMap { UIImage(data: $0) } }
    var string: String? {
        get { reads += 1; return storedText }
        set { storedText = newValue; storedImage = nil; changeCount += 1; writes += 1 }
    }
    func data(forPasteboardType pasteboardType: String) -> Data? { reads += 1; return storedImage }
    func setData(_ data: Data, forPasteboardType pasteboardType: String) {
        storedImage = data; storedText = nil; changeCount += 1; writes += 1
    }
}

final class ShortcutMonitorTests: XCTestCase {
    @MainActor
    private func monitor(root: URL, pasteboard: ShortcutPasteboard,
                         recording: Bool = false, resumesOnInit: Bool = true,
                         makeDatabase: (() throws -> HistoryPersistence)? = nil) throws -> ClipboardMonitor {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(recording, forKey: "isRecording")
        HistoryRetention.never.save(to: defaults)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let monitor = ClipboardMonitor(defaults: defaults,
            log: MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log.tsv"))),
            makeDatabase: makeDatabase ?? { try HistoryDatabase(url: root.appendingPathComponent("history.sqlite")) },
            schedulesMaintenance: false, imageDirectory: root.appendingPathComponent("images"),
            pasteboard: pasteboard, resumesRecordingOnInit: resumesOnInit)
        addTeardownBlock { await MainActor.run { monitor.stop() } }
        return monitor
    }

    @MainActor
    func testHeadlessLoadWaitsForDatabaseAndConcurrentWaitersSeeHistory() async throws {
        let root = try ImageTestSupport.directory(self)
        let pasteboard = ShortcutPasteboard()
        let entered = expectation(description: "opening database")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let monitor = try monitor(root: root, pasteboard: pasteboard, recording: true, resumesOnInit: false) {
            entered.fulfill()
            guard gate.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileReadUnknown) }
            let database = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"))
            try database.collect("起動前の履歴", source: .manual, at: nil)
            return database
        }
        let first = Task { try await monitor.historyForShortcuts() }
        let second = Task { try await monitor.historyForShortcuts() }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(monitor.entries.isEmpty)
        XCTAssertFalse(monitor.isRecording)
        monitor.pollPasteboard()
        XCTAssertEqual(pasteboard.reads, 0)
        gate.signal()
        let firstEntries = try await first.value
        let secondEntries = try await second.value
        XCTAssertEqual(firstEntries.map(\.text), ["起動前の履歴"])
        XCTAssertEqual(secondEntries, firstEntries)
        monitor.updateScene("active")
        XCTAssertTrue(monitor.isRecording)
        _ = try await monitor.historyForShortcuts()
    }

    @MainActor
    func testSaveOnlyCommitsBeforeReturnAndDoesNotTouchPasteboard() async throws {
        let root = try ImageTestSupport.directory(self)
        let pasteboard = ShortcutPasteboard()
        pasteboard.string = "既存のコピー"
        let monitor = try monitor(root: root, pasteboard: pasteboard)
        try await monitor.performShortcut("test-save-only") {
            try await monitor.saveFromShortcut(text: "行1\n行2", pngData: nil, copyToClipboard: false)
        }
        XCTAssertEqual(monitor.entries.map(\.text), ["行1\n行2"])
        XCTAssertEqual(monitor.entries.first?.source, .manual)
        XCTAssertEqual(monitor.pendingSaveCount, 0)
        XCTAssertEqual(pasteboard.reads, 0)
        XCTAssertEqual(pasteboard.writes, 1)
        XCTAssertEqual(pasteboard.storedText, "既存のコピー")
        let reopened = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"))
        XCTAssertEqual(try reopened.fetchAll(), monitor.entries)
        let log = try String(contentsOf: root.appendingPathComponent("log.tsv"), encoding: .utf8)
        XCTAssertTrue(log.contains("test-save-only"))
        XCTAssertTrue(log.contains("所要ms="))
        XCTAssertTrue(log.contains("成否=成功"))
    }

    @MainActor
    func testTextCopySkipsReadbackAndLaterExternalCopyOfSameTextCounts() async throws {
        let root = try ImageTestSupport.directory(self)
        let pasteboard = ShortcutPasteboard()
        let monitor = try monitor(root: root, pasteboard: pasteboard, recording: true)
        pasteboard.string = "上書き前の外部テキスト"
        try await monitor.performShortcut("test-copy") {
            monitor.pollPasteboard()
            try await monitor.saveFromShortcut(text: "同じ文字", pngData: nil, copyToClipboard: true)
            monitor.pollPasteboard()
        }
        monitor.pollPasteboard()
        XCTAssertEqual(pasteboard.reads, 0)
        XCTAssertEqual(pasteboard.storedText, "同じ文字")
        XCTAssertEqual(monitor.entries.count, 1)
        XCTAssertEqual(monitor.entries.first?.collectionCount, 1)
        pasteboard.string = "同じ文字"
        monitor.pollPasteboard()
        let entries = try await monitor.historyForShortcuts()
        XCTAssertEqual(entries.first?.collectionCount, 2)
    }

    @MainActor
    func testImageCopyAndEntityFileWithoutDuplicateCollection() async throws {
        let root = try ImageTestSupport.directory(self)
        let pasteboard = ShortcutPasteboard()
        let monitor = try monitor(root: root, pasteboard: pasteboard, recording: true)
        let png = ImageTestSupport.png()
        try await monitor.performShortcut("test-image") {
            try await monitor.saveFromShortcut(text: nil, pngData: png, copyToClipboard: true)
        }
        monitor.pollPasteboard()
        let entry = try XCTUnwrap(monitor.entries.first)
        XCTAssertEqual(entry.kind, .image)
        XCTAssertEqual(entry.collectionCount, 1)
        XCTAssertEqual(pasteboard.storedImage, png)
        XCTAssertEqual(pasteboard.reads, 0)
        let entity = try XCTUnwrap(HistoryEntryEntity.make([entry], monitor: monitor).first)
        XCTAssertEqual(entity.picture?.data, png)
        XCTAssertEqual(entity.picture?.removedOnCompletion, false)
        try await monitor.copyForShortcut(entry)
        monitor.pollPasteboard()
        XCTAssertEqual(pasteboard.reads, 0)
        XCTAssertEqual(monitor.entries.first?.collectionCount, 1)
    }

    @MainActor
    func testBothInputsAreSavedAndOnlyImageIsCopied() async throws {
        let root = try ImageTestSupport.directory(self)
        let pasteboard = ShortcutPasteboard()
        let monitor = try monitor(root: root, pasteboard: pasteboard)
        let png = ImageTestSupport.png()
        try await monitor.performShortcut("test-both") {
            try await monitor.saveFromShortcut(text: "文章", pngData: png, copyToClipboard: true)
        }
        XCTAssertEqual(monitor.entries.count, 2)
        XCTAssertEqual(monitor.pendingSaveCount, 0)
        XCTAssertEqual(pasteboard.writes, 1)
        XCTAssertEqual(pasteboard.storedImage, png)
    }

    @MainActor
    func testLoadFailureIsThrownAndLoggedInsteadOfReturningEmptyHistory() async throws {
        let root = try ImageTestSupport.directory(self)
        let pasteboard = ShortcutPasteboard()
        let monitor = try monitor(root: root, pasteboard: pasteboard) { throw CocoaError(.fileReadNoPermission) }
        var ranOperation = false
        do {
            try await monitor.performShortcut("test-load-failure") { ranOperation = true }
            XCTFail("Expected load failure")
        } catch {
            XCTAssertTrue(error is ShortcutError)
        }
        XCTAssertFalse(ranOperation)
        XCTAssertEqual(pasteboard.writes, 0)
        let log = try String(contentsOf: root.appendingPathComponent("log.tsv"), encoding: .utf8)
        XCTAssertTrue(log.contains("test-load-failure"))
        XCTAssertTrue(log.contains("成否=失敗"))
    }

    @MainActor
    func testInvalidImageIsNotCopiedOrQueuedForRetry() async throws {
        let root = try ImageTestSupport.directory(self)
        let pasteboard = ShortcutPasteboard()
        let monitor = try monitor(root: root, pasteboard: pasteboard)
        do {
            try await monitor.performShortcut("test-save-failure") {
                try await monitor.saveFromShortcut(text: nil, pngData: Data([0, 1]), copyToClipboard: true)
            }
            XCTFail("Expected image failure")
        } catch { XCTAssertTrue(error is ShortcutError) }
        let entries = try await monitor.historyForShortcuts()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(monitor.pendingSaveCount, 0)
        XCTAssertEqual(pasteboard.writes, 0)
    }

    @MainActor
    func testEmptyInputIsRejectedBeforeSavingOrCopying() async throws {
        let root = try ImageTestSupport.directory(self)
        let pasteboard = ShortcutPasteboard()
        let monitor = try monitor(root: root, pasteboard: pasteboard)
        for text in [nil, "", " \n\t"] as [String?] {
            do {
                try await monitor.saveFromShortcut(text: text, pngData: nil, copyToClipboard: true)
                XCTFail("Expected missing content")
            } catch {
                guard case ShortcutError.missingContent = error else { XCTFail("Unexpected error: \(error)"); continue }
            }
        }
        XCTAssertTrue(monitor.entries.isEmpty)
        XCTAssertEqual(monitor.pendingSaveCount, 0)
        XCTAssertEqual(pasteboard.writes, 0)
    }

    @MainActor
    func testFailedCommitDoesNotCopyOrRetryAfterReturningFailure() async throws {
        let root = try ImageTestSupport.directory(self)
        let pasteboard = ShortcutPasteboard()
        let monitor = try monitor(root: root, pasteboard: pasteboard)
        _ = try await monitor.historyForShortcuts()
        let url = root.appendingPathComponent("history.sqlite")
        try ImageTestSupport.sql("""
            CREATE TRIGGER reject_shortcut BEFORE INSERT ON history
            BEGIN SELECT RAISE(ABORT, 'test write failure'); END;
            """, at: url)
        do {
            try await monitor.performShortcut("test-commit-failure") {
                try await monitor.saveFromShortcut(text: "保存に失敗する文章", pngData: nil, copyToClipboard: true)
            }
            XCTFail("Expected storage failure")
        } catch {
            guard case ShortcutError.storageUnavailable = error else { XCTFail("Unexpected error: \(error)"); return }
        }
        XCTAssertEqual(monitor.pendingSaveCount, 0)
        XCTAssertEqual(monitor.savedCount, 0)
        XCTAssertEqual(pasteboard.writes, 0)
        try ImageTestSupport.sql("DROP TRIGGER reject_shortcut", at: url)
        let afterRecovery = try await monitor.historyForShortcuts()
        XCTAssertTrue(afterRecovery.isEmpty)
        try await monitor.performShortcut("test-after-recovery") {
            try await monitor.saveFromShortcut(text: "復旧後", pngData: nil, copyToClipboard: true)
        }
        XCTAssertEqual(monitor.entries.map(\.text), ["復旧後"])
        XCTAssertEqual(pasteboard.storedText, "復旧後")
        XCTAssertEqual(monitor.pendingSaveCount, 0)
    }
}
