import AppIntents
import UIKit
import XCTest
@testable import ClipboardPlus

@MainActor
private final class TemplateTestPasteboard: ClipboardPasteboard {
    var changeCount = 0
    let hasImages = false
    var hasStrings: Bool { string != nil }
    var types: [String] { string == nil ? [] : ["public.utf8-plain-text"] }
    var string: String? {
        didSet { changeCount += 1 }
    }
    let image: UIImage? = nil
    func data(forPasteboardType pasteboardType: String) -> Data? { nil }
    func setData(_ data: Data, forPasteboardType pasteboardType: String) {}
}

final class TemplateMonitorTests: XCTestCase {
    @MainActor
    private func fixture() throws -> ClipboardMonitor {
        let root = try ImageTestSupport.directory(self)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(0, forKey: HistoryRetention.defaultsKey)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let monitor = ClipboardMonitor(defaults: defaults,
                                       log: MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log.tsv"))),
                                       makeDatabase: { try HistoryDatabase(url: root.appendingPathComponent("history.sqlite")) },
                                       schedulesMaintenance: false, imageDirectory: root.appendingPathComponent("attachments"),
                                       pasteboard: TemplateTestPasteboard())
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
    func testTemplateOperationsPublishAndLogWithoutPrivateMetadata() throws {
        let monitor = try fixture()
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
        let kinds = ["テンプレートに移動", "テンプレートの作成", "テンプレートの編集", "テンプレートの並べ替え", "タグ名の変更"]
        let lines = monitor.log.lines.map(\.fileLine).filter { line in kinds.contains { line.contains($0) } }
        for kind in kinds { XCTAssertTrue(lines.contains { $0.contains(kind) }) }
        let log = lines.joined()
        for secret in ["move-private-body", "create-private-body", "update-private-body", "private-title", "private-tag", "private-renamed-tag"] {
            XCTAssertFalse(log.contains(secret))
        }
    }

    @MainActor
    func testTemplateQueryFiltersHistoryAndRanksExactTitlesFirst() throws {
        let monitor = try fixture()
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
        let monitor = try fixture()
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

    @MainActor
    func testCopyingPCSyncedTemplateDoesNotLogTextPreviewEvenWhenEnabled() throws {
        let monitor = try fixture()
        monitor.log.includeTextPreview = true

        let syncedSecret = "PC由来テンプレートの秘密本文12345"
        let applied = expectation(description: "pc template synced")
        monitor.applySyncedTemplates(
            TemplateSyncSnapshot(
                sentAt: 1_794_873_600_000,
                templates: [
                    TemplateSyncItem(id: UUID(), kind: .text, text: syncedSecret, title: "PC秘密題", tag: "仕事", order: 0, updatedAt: 1_794_873_600_000)
                ],
                tombstones: []
            ),
            pushed: nil
        ) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            applied.fulfill()
        }
        wait(for: [applied], timeout: 5)
        drain(monitor)

        let syncedEntry = try XCTUnwrap(monitor.entries.first { $0.isTemplate && $0.text == syncedSecret })
        // 1. Copy while not recording (self-copy event only).
        let copiedIdle = expectation(description: "copied while idle")
        monitor.copy(syncedEntry) { ok in
            XCTAssertTrue(ok)
            copiedIdle.fulfill()
        }
        wait(for: [copiedIdle], timeout: 5)

        // 2. Copy while recording (self-copy event + self-copy readback path).
        monitor.start()
        defer { monitor.stop() }
        let copiedRecording = expectation(description: "copied while recording")
        monitor.copy(syncedEntry) { ok in
            XCTAssertTrue(ok)
            copiedRecording.fulfill()
        }
        wait(for: [copiedRecording], timeout: 5)
        drain(monitor)

        let allLines = monitor.log.lines.map(\.fileLine)
        XCTAssertTrue(allLines.contains { $0.contains("自己コピー") })
        for line in allLines {
            XCTAssertFalse(line.contains(syncedSecret))
            XCTAssertFalse(line.contains("PC由来テンプレート"))
            XCTAssertFalse(line.contains("PC秘密題"))
        }
    }
}
