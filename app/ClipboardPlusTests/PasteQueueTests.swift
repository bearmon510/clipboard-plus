import AppIntents
import Combine
import UIKit
import XCTest
@testable import ClipboardPlus

@MainActor
private final class QueuePasteboard: ClipboardPasteboard {
    var changeCount = 0
    var contentReads = 0
    var rejectsWrites = false
    var writes: [NSItemProvider] = []
    private var providers: [NSItemProvider] = []
    private var text: String?
    var hasImages: Bool { contentReads += 1; return false }
    var hasStrings: Bool { contentReads += 1; return text != nil || !providers.isEmpty }
    var types: [String] { contentReads += 1; return providers.flatMap(\.registeredTypeIdentifiers) + (text == nil ? [] : ["public.utf8-plain-text"]) }
    var itemProviders: [NSItemProvider] { contentReads += 1; return providers }
    var image: UIImage? { contentReads += 1; return nil }
    var string: String? {
        get { contentReads += 1; return text }
        set { external(newValue) }
    }
    func external(_ value: String?) {
        text = value
        providers = []
        changeCount += 1
    }
    func data(forPasteboardType pasteboardType: String) -> Data? { contentReads += 1; return nil }
    func setData(_ data: Data, forPasteboardType pasteboardType: String) { external(nil) }
    func writeFileProviders(_ providers: [NSItemProvider]) -> Bool {
        guard !rejectsWrites else { return false }
        self.providers = providers
        writes.append(contentsOf: providers)
        text = nil
        changeCount += 1
        return true
    }
}

final class PasteQueueTests: XCTestCase {
    @MainActor
    func testEngineOnlyAcceptsTextAndURLAndIgnoresDuplicateIDs() {
        let engine = PasteQueue(entry: { _ in nil }, write: { _ in nil }, changeCount: { 0 },
                                scene: { "active" }, changed: { _ in }, log: { _, _, _ in })
        for (id, kind) in [HistoryKind.text, .url, .image, .file].enumerated() {
            let value = HistoryEntry(id: id, kind: kind, text: "body", savedAt: Date(), lastCollectedAt: Date(),
                                     collectionCount: 1, isTemplate: false, source: .manual)
            engine.enqueue(value)
            engine.enqueue(value)
        }
        XCTAssertEqual(engine.state.entryIDs, [0, 1])
        engine.remove(id: 99)
        XCTAssertEqual(engine.state.entryIDs, [0, 1])
        engine.stop()
    }

    @MainActor
    private func fixture(board: QueuePasteboard) throws -> ClipboardMonitor {
        let root = try ImageTestSupport.directory(self)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(0, forKey: HistoryRetention.defaultsKey)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let monitor = ClipboardMonitor(defaults: defaults,
                                       log: MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log.tsv"))),
                                       makeDatabase: { try HistoryDatabase(url: root.appendingPathComponent("history.sqlite")) },
                                       schedulesMaintenance: false, imageDirectory: root.appendingPathComponent("attachments"),
                                       pasteboard: board)
        drain(monitor)
        monitor.updateScene("active")
        return monitor
    }

    @MainActor
    private func drain(_ monitor: ClipboardMonitor) {
        let done = expectation(description: "store and log drained")
        monitor.pendingDeletion { _ in monitor.log.flush(context: monitor.logContext()) { done.fulfill() } }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    private func create(_ text: String, title: String? = nil, monitor: ClipboardMonitor) throws -> HistoryEntry {
        let done = expectation(description: "created and published")
        var result: Result<HistoryEntry, HistoryEditError>?
        monitor.createTemplate(text: text, title: title, tag: nil) { value in
            result = value
            if case .success(let entry) = value { XCTAssertTrue(monitor.entries.contains(entry)) }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(result).get()
    }

    @MainActor
    private func settleLoads() {
        let done = expectation(description: "delayed provider callbacks settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    @MainActor
    private func load(_ provider: NSItemProvider, types: [String], expected: String) {
        let delivered = expectation(description: "destination receives bytes")
        delivered.expectedFulfillmentCount = types.count
        for type in types {
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                XCTAssertNil(error)
                XCTAssertEqual(data, Data(expected.utf8))
                delivered.fulfill()
            }
        }
        wait(for: [delivered], timeout: 5)
        settleLoads()
    }

    @MainActor
    func testStartLazyLoadsAdvanceOncePollingNeverReadsAndLastFinishes() throws {
        let board = QueuePasteboard()
        let monitor = try fixture(board: board)
        defer { monitor.stopPasteQueue(); monitor.stop() }
        monitor.log.includeTextPreview = true
        let a = try create("https://example.com/private-body", title: "秘密の名前", monitor: monitor)
        let b = try create("second-private-body", monitor: monitor)
        let c = try create("third-private-body", monitor: monitor)
        for entry in [a, b, a, c] { monitor.enqueueForPaste(entry) }
        XCTAssertEqual(monitor.pasteQueue.entryIDs, [a.id, b.id, c.id])
        monitor.start()
        let original = monitor.entries
        monitor.startPasteQueue()
        XCTAssertTrue(monitor.pasteQueue.isRunning)
        XCTAssertEqual(monitor.pasteQueue.currentIndex, 0)
        XCTAssertEqual(board.writes.count, 1)
        let first = try XCTUnwrap(board.writes.first)
        XCTAssertNil(first.suggestedName)
        XCTAssertTrue(first.registeredTypeIdentifiers.contains("public.url"))
        let reads = board.contentReads
        for _ in 0..<3 { monitor.pollPasteboard() }
        drain(monitor)
        XCTAssertEqual(board.contentReads, reads)
        XCTAssertEqual(monitor.entries, original)
        XCTAssertEqual(monitor.pendingSaveCount, 0)
        load(first, types: ["public.utf8-plain-text", "public.url", "public.utf8-plain-text"], expected: a.text)
        XCTAssertEqual(monitor.pasteQueue.currentIndex, 1)
        XCTAssertEqual(board.writes.count, 2)
        XCTAssertNotNil(monitor.pasteQueue.lastAdvance)
        // Even a late request for the previous provider cannot consume the current item.
        load(first, types: ["public.url"], expected: a.text)
        XCTAssertEqual(board.writes.count, 2)
        load(try XCTUnwrap(board.writes.last), types: ["public.utf8-plain-text"], expected: b.text)
        XCTAssertEqual(monitor.pasteQueue.currentIndex, 2)
        let last = try XCTUnwrap(board.writes.last)
        load(last, types: ["public.utf8-plain-text"], expected: c.text)
        XCTAssertFalse(monitor.pasteQueue.isRunning)
        XCTAssertFalse(monitor.pasteQueue.isPaused)
        XCTAssertEqual(board.writes.count, 3)
        monitor.pollPasteboard()
        drain(monitor)
        XCTAssertEqual(board.contentReads, reads)
        XCTAssertEqual(monitor.entries, original)
        let logs = monitor.log.lines.map(\.fileLine).joined()
        XCTAssertTrue(logs.contains("連続貼り付けの読み込み要求"))
        XCTAssertTrue(logs.contains("型=public.url"))
        XCTAssertTrue(logs.contains("index=0"))
        XCTAssertFalse(logs.contains(a.text))
        XCTAssertFalse(logs.contains(b.text))
        XCTAssertFalse(logs.contains("秘密の名前"))
        monitor.stopPasteQueue()
        XCTAssertEqual(monitor.pasteQueue, PasteQueueState())
        load(last, types: ["public.utf8-plain-text"], expected: c.text)
        XCTAssertEqual(board.writes.count, 3)
    }

    @MainActor
    func testExternalCopyPausesAndNextRewritesCurrentInsteadOfSkippingIt() throws {
        let board = QueuePasteboard()
        let monitor = try fixture(board: board)
        defer { monitor.stopPasteQueue(); monitor.stop() }
        let a = try create("A", monitor: monitor)
        let b = try create("B", monitor: monitor)
        monitor.enqueueForPaste(a)
        monitor.enqueueForPaste(b)
        monitor.start()
        monitor.startPasteQueue()
        let stale = try XCTUnwrap(board.writes.last)
        board.external("外からのコピー")
        monitor.pollPasteboard()
        XCTAssertTrue(monitor.pasteQueue.isRunning)
        XCTAssertTrue(monitor.pasteQueue.isPaused)
        drain(monitor)
        XCTAssertEqual(monitor.entries.first?.text, "外からのコピー")
        load(stale, types: ["public.utf8-plain-text"], expected: "A")
        XCTAssertEqual(board.writes.count, 1)
        monitor.advancePasteQueue()
        XCTAssertFalse(monitor.pasteQueue.isPaused)
        XCTAssertEqual(monitor.pasteQueue.currentIndex, 0)
        XCTAssertEqual(board.writes.count, 2)
        monitor.advancePasteQueue()
        XCTAssertEqual(monitor.pasteQueue.currentIndex, 1)
        monitor.rewindPasteQueue()
        XCTAssertEqual(monitor.pasteQueue.currentIndex, 0)
        load(try XCTUnwrap(board.writes.last), types: ["public.utf8-plain-text"], expected: "A")
        XCTAssertEqual(monitor.pasteQueue.currentIndex, 1)
    }

    @MainActor
    func testBackgroundPausesAndActiveRewritesWithoutLoadingOldProvider() throws {
        let board = QueuePasteboard()
        let monitor = try fixture(board: board)
        defer { monitor.stopPasteQueue() }
        let a = try create("A", monitor: monitor)
        let b = try create("B", monitor: monitor)
        monitor.enqueueForPaste(a)
        monitor.enqueueForPaste(b)
        monitor.startPasteQueue()
        let stale = try XCTUnwrap(board.writes.last)
        monitor.updateScene("background")
        XCTAssertTrue(monitor.pasteQueue.isPaused)
        load(stale, types: ["public.utf8-plain-text"], expected: "A")
        XCTAssertEqual(monitor.pasteQueue.currentIndex, 0)
        XCTAssertEqual(board.writes.count, 1)
        monitor.updateScene("active")
        XCTAssertFalse(monitor.pasteQueue.isPaused)
        XCTAssertEqual(board.writes.count, 2)
        load(stale, types: ["public.utf8-plain-text"], expected: "A")
        XCTAssertEqual(board.writes.count, 2)
        load(try XCTUnwrap(board.writes.last), types: ["public.utf8-plain-text"], expected: "A")
        XCTAssertEqual(monitor.pasteQueue.currentIndex, 1)
    }

    @MainActor
    func testDeletionDropsCurrentAndPriorIDsAndClearsAfterDeleteAll() throws {
        let board = QueuePasteboard()
        let monitor = try fixture(board: board)
        defer { monitor.stopPasteQueue() }
        let a = try create("A", monitor: monitor)
        let b = try create("B", monitor: monitor)
        let c = try create("C", monitor: monitor)
        for value in [a, b, c] { monitor.enqueueForPaste(value) }
        monitor.startPasteQueue()
        monitor.advancePasteQueue()
        monitor.removeFromPasteQueue(id: a.id)
        XCTAssertEqual(monitor.pasteQueue.entryIDs, [b.id, c.id])
        XCTAssertEqual(monitor.pasteQueue.currentIndex, 0)
        let done = expectation(description: "deleted current entry")
        monitor.delete(b) { deletion in XCTAssertNotNil(deletion); done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(monitor.pasteQueue.entryIDs, [c.id])
        XCTAssertEqual(monitor.pasteQueue.currentIndex, 0)
        load(try XCTUnwrap(board.writes.last), types: ["public.utf8-plain-text"], expected: "C")
        XCTAssertFalse(monitor.pasteQueue.isRunning)
        let all = expectation(description: "history clear keeps templates")
        monitor.deleteAllHistory() { _ in all.fulfill() }
        wait(for: [all], timeout: 5)
        XCTAssertEqual(monitor.pasteQueue.entryIDs, [c.id])
    }

    @MainActor
    func testWriteFailurePausesAndRecordingDisabledStillDetectsExternalCopy() throws {
        let board = QueuePasteboard()
        let monitor = try fixture(board: board)
        defer { monitor.stopPasteQueue() }
        let a = try create("A", monitor: monitor)
        monitor.enqueueForPaste(a)
        board.rejectsWrites = true
        monitor.startPasteQueue()
        XCTAssertTrue(monitor.pasteQueue.isPaused)
        board.rejectsWrites = false
        monitor.startPasteQueue()
        XCTAssertFalse(monitor.pasteQueue.isPaused)
        XCTAssertFalse(monitor.isRecording)
        board.external("outside")
        monitor.pollPasteboard()
        XCTAssertTrue(monitor.pasteQueue.isPaused)
        XCTAssertEqual(monitor.entries.count, 1)
    }

    @MainActor
    func testPasteInOrderReplacesQueueFiltersAttachmentsAndStartsInGivenOrder() throws {
        let board = QueuePasteboard()
        let monitor = try fixture(board: board)
        defer { monitor.stopPasteQueue() }
        let a = try create("A", monitor: monitor)
        let b = try create("https://example.com", monitor: monitor)
        let c = try create("C", monitor: monitor)
        monitor.enqueueForPaste(c)
        monitor.startPasteQueue()
        let image = HistoryEntry(id: -1, kind: .image, text: "", savedAt: Date(), lastCollectedAt: Date(),
                                 collectionCount: 1, isTemplate: true, source: .manual)
        monitor.pasteInOrder([b, image, a])
        XCTAssertEqual(monitor.pasteQueue.entryIDs, [b.id, a.id])
        XCTAssertTrue(monitor.pasteQueue.isRunning)
        XCTAssertEqual(monitor.pasteQueue.currentIndex, 0)
        load(try XCTUnwrap(board.writes.last), types: ["public.utf8-plain-text"], expected: b.text)
        XCTAssertEqual(monitor.pasteQueue.currentIndex, 1)
        drain(monitor)
        XCTAssertEqual(monitor.entries.count, 3)
        monitor.pasteInOrder([])
        XCTAssertEqual(monitor.pasteQueue, PasteQueueState())
    }

    @MainActor
    func testTemplateOperationsPublishAndLogWithoutPrivateMetadata() throws {
        let board = QueuePasteboard()
        let monitor = try fixture(board: board)
        defer { monitor.stopPasteQueue() }
        monitor.saveManually(["move-private-body"], receivedAt: Date())
        drain(monitor)
        let history = try XCTUnwrap(monitor.entries.first)
        monitor.log.includeTextPreview = true
        let moved = expectation(description: "move published")
        monitor.moveToTemplates(history) { result in
            do {
                let value = try result.get()
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertTrue(value.isTemplate)
                XCTAssertTrue(monitor.entries.contains(value))
            } catch { XCTFail("\(error)") }
            moved.fulfill()
        }
        wait(for: [moved], timeout: 5)
        let a = try create("create-private-body", title: "private-title", monitor: monitor)
        let edited = expectation(description: "tag edit published")
        monitor.updateTemplate(a, text: "update-private-body", title: "private-title", tag: "private-tag") { result in
            do {
                let value = try result.get()
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertTrue(monitor.entries.contains(value))
            } catch { XCTFail("\(error)") }
            edited.fulfill()
        }
        wait(for: [edited], timeout: 5)
        monitor.reorderTemplates([a.id])
        monitor.renameTag("private-tag", to: "private-renamed-tag")
        drain(monitor)
        XCTAssertEqual(monitor.entries.first { $0.id == a.id }?.tag, "private-renamed-tag")
        monitor.pasteInOrder([a])
        drain(monitor)
        let kinds = ["テンプレートに移動", "テンプレートの作成", "テンプレートの編集", "テンプレートの並べ替え", "タグ名の変更", "順に貼る"]
        let lines = monitor.log.lines.map(\.fileLine).filter { line in kinds.contains { line.contains($0) } }
        for kind in kinds { XCTAssertTrue(lines.contains { $0.contains(kind) }) }
        let log = lines.joined()
        for secret in ["move-private-body", "create-private-body", "update-private-body", "private-title", "private-tag", "private-renamed-tag"] {
            XCTAssertFalse(log.contains(secret))
        }
    }

    @MainActor
    func testTemplateQueryFiltersHistoryAndRanksExactTitlesFirst() throws {
        let board = QueuePasteboard()
        let monitor = try fixture(board: board)
        let a = try create("private", title: "署名", monitor: monitor)
        let b = try create("署名の本文", monitor: monitor)
        monitor.saveManually(["署名の履歴"], receivedAt: Date())
        drain(monitor)
        let done = expectation(description: "template and general queries")
        Task { @MainActor in
            do {
                let templates = try await TemplateEntryQuery().entities(matching: "署名", monitor: monitor)
                XCTAssertEqual(templates.map(\.id), [a.id, b.id])
                XCTAssertEqual(templates.first?.title, "署名")
                let all = try await HistoryEntryQuery().entities(matching: "署名", monitor: monitor)
                XCTAssertEqual(all.first?.id, a.id)
                XCTAssertEqual(all.count, 3)
            } catch { XCTFail("\(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(HistoryFilterOption(rawValue: "pinned"), .templates)
        XCTAssertFalse(CopyTemplateIntent.openAppWhenRun)
        XCTAssertEqual(String(localized: CopyTemplateIntent.title), "テンプレートをコピー")
    }

    @MainActor
    func testMonitorEditingPublishesBeforeCompletionAndQueryMatchesTitle() throws {
        let board = QueuePasteboard()
        let monitor = try fixture(board: board)
        monitor.log.includeTextPreview = true
        let a = try create("private-body", title: "署名", monitor: monitor)
        let b = try create("署名に関する本文", monitor: monitor)
        let query = expectation(description: "entity title query")
        Task { @MainActor in
            do {
                let matches = try await HistoryEntryQuery().entities(matching: "署名", monitor: monitor)
                XCTAssertEqual(matches.map(\.id), [a.id, b.id])
                XCTAssertEqual(matches.first?.displayTitle, "署名")
            } catch { XCTFail("Query failed: \(error)") }
            query.fulfill()
        }
        wait(for: [query], timeout: 5)
        monitor.updateTemplate(a, text: nil, title: " 新しい名前 ", tag: nil) { _ in }
        monitor.reorderTemplates([a.id])
        drain(monitor)
        XCTAssertEqual(monitor.entries.first { $0.id == a.id }?.title, "新しい名前")
        XCTAssertEqual(HistoryEntry.orderedTemplates(monitor.entries).first?.id, a.id)
        let edited = expectation(description: "edit published")
        monitor.updateTemplate(a, text: "https://example.com/private-edit", title: "編集後", tag: nil) { result in
            do {
                let entry = try result.get()
                XCTAssertEqual(entry.kind, .url)
                XCTAssertTrue(monitor.entries.contains(entry))
            } catch { XCTFail("Edit failed: \(error)") }
            edited.fulfill()
        }
        wait(for: [edited], timeout: 5)
        let duplicate = expectation(description: "duplicate rejected")
        let before = monitor.entries
        monitor.updateTemplate(a, text: b.text, title: nil, tag: nil) { result in
            XCTAssertEqual(result, .failure(.duplicate))
            XCTAssertEqual(monitor.entries, before)
            duplicate.fulfill()
        }
        wait(for: [duplicate], timeout: 5)
        let logs = monitor.log.lines.map(\.fileLine).joined()
        XCTAssertTrue(logs.contains("テンプレートの編集"))
        XCTAssertTrue(logs.contains("テンプレートの並べ替え"))
        XCTAssertFalse(logs.contains("private-body"))
        XCTAssertFalse(logs.contains("private-edit"))
        XCTAssertFalse(logs.contains("編集後"))
    }
}
