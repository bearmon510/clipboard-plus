import Foundation
import UIKit
import XCTest
@testable import ClipboardPlus

final class KeyboardFoundationTests: XCTestCase {
    @MainActor
    private final class IdlePasteboard: ClipboardPasteboard {
        let changeCount = 0
        let hasImages = false
        let hasStrings = false
        let types: [String] = []
        var string: String?
        let image: UIImage? = nil
        func data(forPasteboardType pasteboardType: String) -> Data? { nil }
        func setData(_ data: Data, forPasteboardType pasteboardType: String) {}
    }

    private func tempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func tempDefaults() throws -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        HistoryRetention.never.save(to: defaults)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func entry(
        _ id: Int,
        kind: HistoryKind = .text,
        text: String = "body",
        collectedAt: Date = Date(timeIntervalSince1970: 1_000),
        isTemplate: Bool = false,
        source: HistorySource = .automatic,
        title: String? = nil,
        templateOrder: Int? = nil,
        tag: String? = nil
    ) -> HistoryEntry {
        let image = kind == .image
            ? HistoryImage(hash: "img-\(id)", filename: "i-\(id).png", thumbnailFilename: "t-\(id).jpg",
                           byteCount: 100, pixelWidth: 10, pixelHeight: 10, typeIdentifier: "public.png")
            : nil
        let file = kind == .file
            ? HistoryFile(hash: "file-\(id)", filename: "f-\(id).pdf", originalFilename: "doc.pdf",
                          byteCount: 100, typeIdentifier: "com.adobe.pdf")
            : nil
        return HistoryEntry(
            id: id, kind: kind, text: text, savedAt: collectedAt, lastCollectedAt: collectedAt,
            collectionCount: 1, isTemplate: isTemplate, source: source,
            image: image, file: file, title: title, templateOrder: templateOrder, tag: tag
        )
    }

    func testBuilderIncludesTextURLPCAndTemplatesInExpectedOrderAndExcludesAttachmentsAndPendingDeletions() throws {
        let root = try tempDirectory()
        let exportedAt = Date(timeIntervalSince1970: 2_000)
        let entries = [
            entry(1, kind: .text, text: "older text", collectedAt: Date(timeIntervalSince1970: 100)),
            entry(2, kind: .url, text: "https://example.com/pc", collectedAt: Date(timeIntervalSince1970: 300), source: .pc),
            entry(3, kind: .text, text: "tie lower id", collectedAt: Date(timeIntervalSince1970: 200)),
            entry(4, kind: .text, text: "tie higher id", collectedAt: Date(timeIntervalSince1970: 200)),
            entry(5, kind: .image, text: "", collectedAt: Date(timeIntervalSince1970: 400)),
            entry(6, kind: .file, text: "", collectedAt: Date(timeIntervalSince1970: 450)),
            entry(7, kind: .text, text: "undo pending", collectedAt: Date(timeIntervalSince1970: 500)),
            entry(8, kind: .text, text: "untagged template", isTemplate: true, source: .written, title: "その他1", templateOrder: 0),
            entry(9, kind: .url, text: "https://example.com/form", isTemplate: true, source: .written, title: "  連絡先 ", templateOrder: 1, tag: "仕事"),
            entry(10, kind: .text, text: "first in tag", isTemplate: true, source: .written, title: nil, templateOrder: 0, tag: "仕事"),
            entry(11, kind: .image, text: "", isTemplate: true, source: .manual, title: "画像テンプレ", templateOrder: 0, tag: "仕事"),
        ]

        let built = KeyboardHistoryBuilder.build(entries: entries, pendingDeletionIDs: [7], exportedAt: exportedAt)
        XCTAssertEqual(built.formatVersion, KeyboardHistory.currentVersion)
        XCTAssertEqual(built.exportedAt, exportedAt)

        let history = built.entries.filter { !$0.isTemplate }
        XCTAssertEqual(history.map(\.id), [2, 4, 3, 1])
        XCTAssertEqual(history.first?.kind, .url)
        XCTAssertEqual(history.first?.text, "https://example.com/pc")

        let templates = built.entries.filter(\.isTemplate)
        XCTAssertEqual(templates.map(\.id), [10, 9, 8])
        XCTAssertEqual(templates.map(\.title), [nil, "連絡先", "その他1"])
        XCTAssertEqual(templates.map(\.tag), ["仕事", "仕事", nil])
        XCTAssertEqual(templates[1].kind, .url)

        let url = SharedAppGroup.keyboardHistoryURL(in: root)
        try KeyboardHistoryFile.write(built, to: url)
        let decoded = try XCTUnwrap(KeyboardHistoryFile.read(from: url))
        XCTAssertEqual(decoded, built)
    }

    func testBuilderAppliesCountAndByteLimitsWithoutDroppingNewerContiguousHistory() {
        let base = Date(timeIntervalSince1970: 1_000)
        var entries: [HistoryEntry] = []
        for id in 1...310 {
            entries.append(entry(id, text: "history-\(id)", collectedAt: base.addingTimeInterval(Double(id))))
        }
        for offset in 1...305 {
            let id = 1_000 + offset
            entries.append(entry(id, text: "tpl-\(offset)", collectedAt: base, isTemplate: true,
                                 templateOrder: offset, tag: "タグ"))
        }

        let countCapped = KeyboardHistoryBuilder.build(entries: entries, exportedAt: base)
        let history = countCapped.entries.filter { !$0.isTemplate }
        let templates = countCapped.entries.filter(\.isTemplate)
        XCTAssertEqual(history.count, KeyboardHistoryBuilder.historyLimit)
        XCTAssertEqual(history.first?.id, 310)
        XCTAssertEqual(history.last?.id, 11)
        XCTAssertEqual(templates.count, KeyboardHistoryBuilder.templateLimit)
        XCTAssertEqual(templates.first?.id, 1_001)
        XCTAssertEqual(templates.last?.id, 1_300)

        let byteTestEntries = [
            entry(1, text: String(repeating: "a", count: 30), collectedAt: Date(timeIntervalSince1970: 500)),
            entry(2, text: String(repeating: "b", count: 12), collectedAt: Date(timeIntervalSince1970: 400)),
            entry(3, text: String(repeating: "c", count: 12), collectedAt: Date(timeIntervalSince1970: 300)),
            entry(4, text: String(repeating: "d", count: 5), collectedAt: Date(timeIntervalSince1970: 200)),
            entry(5, text: String(repeating: "t", count: 6), isTemplate: true, templateOrder: 0),
        ]
        // Entry 1 (30 bytes) exceeds the 25-byte budget on its own and is skipped.
        // Entry 5 (template, 6 bytes) + Entry 2 (12 bytes) = 18 bytes <= 25; adding Entry 3 (12) would reach 30.
        // So Entry 3 and older Entry 4 are dropped, leaving [Entry 2, Entry 5].
        let byteCapped = KeyboardHistoryBuilder.build(
            entries: byteTestEntries,
            exportedAt: base,
            historyLimit: 10,
            templateLimit: 10,
            textByteLimit: 25
        )
        XCTAssertEqual(byteCapped.entries.map(\.id), [2, 5])
    }

    func testSharedFileReadersRejectCorruptOrIncompatibleFilesSafely() throws {
        let root = try tempDirectory()
        let historyURL = SharedAppGroup.keyboardHistoryURL(in: root)
        let now = Date(timeIntervalSince1970: 1_000)
        let duplicateIDs = KeyboardHistory(
            formatVersion: KeyboardHistory.currentVersion,
            exportedAt: now,
            entries: [
                KeyboardHistoryEntry(id: 1, kind: .text, text: "a", lastCollectedAt: now, isTemplate: false),
                KeyboardHistoryEntry(id: 1, kind: .text, text: "b", lastCollectedAt: now, isTemplate: false),
            ]
        )
        try KeyboardHistoryFile.write(duplicateIDs, to: historyURL)
        XCTAssertNil(KeyboardHistoryFile.read(from: historyURL))
        XCTAssertTrue(KeyboardHistoryFile.readEntries(from: historyURL).isEmpty)

        let wrongVersion = Data(#"{"formatVersion":99,"exportedAt":1000,"entries":[]}"#.utf8)
        try wrongVersion.write(to: historyURL)
        XCTAssertNil(KeyboardHistoryFile.read(from: historyURL))

        let settingsURL = SharedAppGroup.keyboardSettingsURL(in: root)
        XCTAssertEqual(KeyboardSettingsFile.initialTab(from: nil), .history)
        XCTAssertEqual(KeyboardSettingsFile.initialTab(from: settingsURL), .history)
        try Data(#"{"formatVersion":99,"initialTab":"templates","updatedAt":1000}"#.utf8).write(to: settingsURL)
        XCTAssertEqual(KeyboardSettingsFile.initialTab(from: settingsURL), .history)
    }

    func testSharedAppGroupReturnsNilInsideTestEnvironment() {
        XCTAssertNil(SharedAppGroup.containerURL())
        XCTAssertNil(SharedAppGroup.keyboardHistoryURL())
        XCTAssertNil(SharedAppGroup.keyboardSettingsURL())
        XCTAssertNil(SharedAppGroup.inboxDirectoryURL())
    }

    @MainActor
    func testMonitorSilentlyIgnoresMissingSharedContainerAndUpdatesWhenAvailable() throws {
        let root = try tempDirectory()
        let dbURL = root.appendingPathComponent("history.sqlite")
        let containerURL = root.appendingPathComponent("group-container", isDirectory: true)
        let defaults = try tempDefaults()
        let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log.tsv")))

        // Unsigned/no-container mode must not fail or record errors.
        let headless = ClipboardMonitor(
            defaults: defaults,
            log: log,
            makeDatabase: { try HistoryDatabase(url: dbURL) },
            schedulesMaintenance: false,
            imageDirectory: root.appendingPathComponent("images-nil"),
            pasteboard: IdlePasteboard(),
            keyboardContainerURL: { nil }
        )
        headless.saveManually(["no container item"], receivedAt: Date(timeIntervalSince1970: 500))
        headless.setKeyboardInitialTab(.templates)
        let nilDone = expectation(description: "headless drained")
        headless.pendingDeletion { _ in nilDone.fulfill() }
        wait(for: [nilDone], timeout: 5)
        XCTAssertNil(headless.storageError)
        XCTAssertEqual(headless.keyboardInitialTab, .templates)

        // With a shared container, edits export keyboard history and settings atomically.
        let defaults2 = try tempDefaults()
        let log2 = MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log2.tsv")))
        let monitor = ClipboardMonitor(
            defaults: defaults2,
            log: log2,
            makeDatabase: { try HistoryDatabase(url: dbURL) },
            schedulesMaintenance: false,
            imageDirectory: root.appendingPathComponent("images"),
            pasteboard: IdlePasteboard(),
            keyboardContainerURL: { containerURL }
        )
        let created = expectation(description: "template created")
        monitor.createTemplate(text: "テンプレート本文", title: "定型", tag: "連絡") { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            created.fulfill()
        }
        wait(for: [created], timeout: 5)
        monitor.setKeyboardInitialTab(.templates)

        let drained = expectation(description: "container writes drained")
        monitor.pendingDeletion { _ in drained.fulfill() }
        wait(for: [drained], timeout: 5)

        let exported = try XCTUnwrap(KeyboardHistoryFile.read(from: SharedAppGroup.keyboardHistoryURL(in: containerURL)))
        XCTAssertEqual(exported.entries.map(\.text), ["no container item", "テンプレート本文"])
        XCTAssertEqual(exported.entries.last?.isTemplate, true)
        XCTAssertEqual(exported.entries.last?.title, "定型")
        XCTAssertEqual(exported.entries.last?.tag, "連絡")
        XCTAssertEqual(KeyboardSettingsFile.initialTab(from: SharedAppGroup.keyboardSettingsURL(in: containerURL)), .templates)
    }

    @MainActor
    func testInboxImportSavesInOrderTriggersPCSyncDeletesFilesAndPreventsDuplicates() throws {
        let root = try tempDirectory()
        let dbURL = root.appendingPathComponent("history.sqlite")
        let containerURL = root.appendingPathComponent("group-container", isDirectory: true)
        let inboxURL = SharedAppGroup.inboxDirectoryURL(in: containerURL)
        let defaults = try tempDefaults()

        let firstID = UUID()
        let secondID = UUID()
        try SharedInbox.write(
            text: "https://example.com/shared-url",
            origin: .shareExtension,
            id: firstID,
            createdAt: Date(timeIntervalSince1970: 1_000),
            to: inboxURL
        )
        try SharedInbox.write(
            text: "keyboard saved snippet",
            origin: .keyboard,
            id: secondID,
            createdAt: Date(timeIntervalSince1970: 1_010),
            to: inboxURL
        )
        // Corrupt and hidden files should not block valid inbox imports.
        try Data("not json".utf8).write(to: inboxURL.appendingPathComponent("corrupt.json"))
        try Data("ignore".utf8).write(to: inboxURL.appendingPathComponent(".DS_Store"))

        let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log.tsv")))
        let monitor = ClipboardMonitor(
            defaults: defaults,
            log: log,
            makeDatabase: { try HistoryDatabase(url: dbURL) },
            schedulesMaintenance: false,
            imageDirectory: root.appendingPathComponent("images"),
            pasteboard: IdlePasteboard(),
            keyboardContainerURL: { containerURL }
        )
        var forwardedToPC: [String] = []
        monitor.onLocalEntryForPC = { entry, _ in
            forwardedToPC.append(entry.text)
        }

        let launched = expectation(description: "launch import finished")
        monitor.pendingDeletion { _ in
            monitor.log.flush(context: monitor.logContext()) { launched.fulfill() }
        }
        wait(for: [launched], timeout: 5)

        XCTAssertEqual(monitor.entries.map(\.text), ["keyboard saved snippet", "https://example.com/shared-url"])
        XCTAssertEqual(monitor.entries.last?.kind, .url)
        XCTAssertEqual(monitor.entries.map(\.collectionCount), [1, 1])
        XCTAssertEqual(forwardedToPC, ["https://example.com/shared-url", "keyboard saved snippet"])
        XCTAssertEqual(monitor.savedCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inboxURL.appendingPathComponent("\(firstID.uuidString).json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inboxURL.appendingPathComponent("\(secondID.uuidString).json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inboxURL.appendingPathComponent("corrupt.json").path))

        let exported = try XCTUnwrap(KeyboardHistoryFile.read(from: SharedAppGroup.keyboardHistoryURL(in: containerURL)))
        XCTAssertEqual(exported.entries.map(\.text), ["keyboard saved snippet", "https://example.com/shared-url"])

        // Ensure plaintext is never logged on inbox import.
        let logs = monitor.log.lines.map(\.fileLine).joined(separator: "\n")
        XCTAssertTrue(logs.contains("受け取り箱から保存"))
        XCTAssertFalse(logs.contains("shared-url"))
        XCTAssertFalse(logs.contains("keyboard saved snippet"))

        // Re-writing the exact same UUID (e.g. simulated leftover file across relaunch) must be ignored.
        try SharedInbox.write(
            text: "https://example.com/shared-url",
            origin: .shareExtension,
            id: firstID,
            createdAt: Date(timeIntervalSince1970: 1_000),
            to: inboxURL
        )
        let relaunched = ClipboardMonitor(
            defaults: defaults,
            log: MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log2.tsv"))),
            makeDatabase: { try HistoryDatabase(url: dbURL) },
            schedulesMaintenance: false,
            imageDirectory: root.appendingPathComponent("images"),
            pasteboard: IdlePasteboard(),
            keyboardContainerURL: { containerURL }
        )
        var duplicateForwarded: [String] = []
        relaunched.onLocalEntryForPC = { entry, _ in duplicateForwarded.append(entry.text) }

        let deduped = expectation(description: "duplicate uuid ignored")
        relaunched.pendingDeletion { _ in deduped.fulfill() }
        wait(for: [deduped], timeout: 5)

        XCTAssertTrue(duplicateForwarded.isEmpty)
        XCTAssertEqual(relaunched.entries.first { $0.text == "https://example.com/shared-url" }?.collectionCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inboxURL.appendingPathComponent("\(firstID.uuidString).json").path))

        // Foreground transition imports a newly added inbox file with a fresh UUID.
        let thirdID = UUID()
        try SharedInbox.write(
            text: "https://example.com/shared-url",
            origin: .shareExtension,
            id: thirdID,
            createdAt: Date(timeIntervalSince1970: 1_020),
            to: inboxURL
        )
        relaunched.updateScene("active")
        let foregrounded = expectation(description: "foreground import finished")
        relaunched.pendingDeletion { _ in foregrounded.fulfill() }
        wait(for: [foregrounded], timeout: 5)

        XCTAssertEqual(duplicateForwarded, ["https://example.com/shared-url"])
        XCTAssertEqual(relaunched.entries.first { $0.text == "https://example.com/shared-url" }?.collectionCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inboxURL.appendingPathComponent("\(thirdID.uuidString).json").path))
    }
}
