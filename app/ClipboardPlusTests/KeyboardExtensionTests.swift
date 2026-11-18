import Foundation
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ClipboardPlus

final class KeyboardExtensionTests: XCTestCase {
    @MainActor
    private final class MockPasteboard: KeyboardPasteboardReadable {
        var types: [String] = []
        var hasStrings = false
        var hasURLs = false
        var string: String?
        var url: URL?
    }

    @MainActor
    private final class SpyPasteboard: KeyboardPasteboardReadable {
        private(set) var accessed = false
        var types: [String] { accessed = true; return [] }
        var hasStrings: Bool { accessed = true; return false }
        var hasURLs: Bool { accessed = true; return false }
        var string: String? { accessed = true; return nil }
        var url: URL? { accessed = true; return nil }
    }

    private func tempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeEntry(
        _ id: Int,
        kind: KeyboardHistoryEntry.Kind = .text,
        text: String = "sample",
        collectedAt: Date = Date(timeIntervalSince1970: 1_000),
        isTemplate: Bool = false,
        title: String? = nil,
        tag: String? = nil,
        templateOrder: Int? = nil,
        isFromPC: Bool = false
    ) -> KeyboardHistoryEntry {
        KeyboardHistoryEntry(
            id: id,
            kind: kind,
            text: text,
            lastCollectedAt: collectedAt,
            isTemplate: isTemplate,
            title: title,
            tag: tag,
            templateOrder: templateOrder,
            isFromPC: isFromPC
        )
    }

    // MARK: - List Ordering, Initial Tab, and Backward Compatibility

    @MainActor
    func testInitialTabAndHistoryOrderingFromSharedFiles() throws {
        let root = try tempDirectory()
        let historyURL = SharedAppGroup.keyboardHistoryURL(in: root)
        let settingsURL = SharedAppGroup.keyboardSettingsURL(in: root)
        let now = Date(timeIntervalSince1970: 5_000)

        try KeyboardSettingsFile.write(KeyboardSettings(initialTab: .templates, updatedAt: now), to: settingsURL)

        let unsorted = [
            makeEntry(1, text: "oldest", collectedAt: Date(timeIntervalSince1970: 100)),
            makeEntry(2, text: "tie-low", collectedAt: Date(timeIntervalSince1970: 300)),
            makeEntry(3, text: "tie-high", collectedAt: Date(timeIntervalSince1970: 300), isFromPC: true),
            makeEntry(4, text: "tpl", isTemplate: true, tag: "仕事", templateOrder: 0),
        ]
        try KeyboardHistoryFile.write(
            KeyboardHistory(formatVersion: KeyboardHistory.currentVersion, exportedAt: now, entries: unsorted),
            to: historyURL
        )

        let model = KeyboardViewModel(loadState: .loading)
        model.loadSynchronously(historyURL: historyURL, settingsURL: settingsURL)

        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.selectedTab, .templates)
        XCTAssertEqual(model.historyEntries.map(\.id), [3, 2, 1])
        XCTAssertEqual(model.historyEntries.first?.isFromPC, true)
        XCTAssertEqual(model.historyEntries.last?.isFromPC, false)
    }

    @MainActor
    func testMissingFilesProduceUnavailableStateAndDefaultHistoryTab() throws {
        let root = try tempDirectory()
        let missingHistory = SharedAppGroup.keyboardHistoryURL(in: root)
        let missingSettings = SharedAppGroup.keyboardSettingsURL(in: root)

        let model = KeyboardViewModel(loadState: .loading)
        model.loadSynchronously(historyURL: missingHistory, settingsURL: missingSettings)

        XCTAssertEqual(model.loadState, .unavailable)
        XCTAssertEqual(model.selectedTab, .history)
        XCTAssertTrue(model.historyEntries.isEmpty)
        XCTAssertTrue(model.templateGroups.isEmpty)

        // Empty valid history file results in .loaded with empty lists.
        try KeyboardHistoryFile.write(
            KeyboardHistory(formatVersion: KeyboardHistory.currentVersion, exportedAt: Date(), entries: []),
            to: missingHistory
        )
        model.loadSynchronously(historyURL: missingHistory, settingsURL: missingSettings)
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertTrue(model.historyEntries.isEmpty)
    }

    func testKeyboardHistoryEntryDecodesLegacyJSONWithoutIsFromPC() throws {
        let json = Data("""
            {
              "formatVersion": 1,
              "exportedAt": 1000,
              "entries": [
                {
                  "id": 10,
                  "kind": "text",
                  "text": "legacy",
                  "lastCollectedAt": 1000,
                  "isTemplate": false
                },
                {
                  "id": 11,
                  "kind": "url",
                  "text": "https://example.com",
                  "lastCollectedAt": 2000,
                  "isTemplate": false,
                  "isFromPC": true
                }
              ]
            }
            """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(KeyboardHistory.self, from: json)
        XCTAssertEqual(decoded.entries.map(\.isFromPC), [false, true])
    }

    // MARK: - Template Grouping

    func testTemplateGroupingMatchesMainAppOrder() {
        let entries = [
            makeEntry(1, isTemplate: false, tag: "無視"),
            makeEntry(2, isTemplate: true, tag: "Tag10", templateOrder: 0),
            makeEntry(3, isTemplate: true, tag: "Tag2", templateOrder: 1),
            makeEntry(4, isTemplate: true, tag: "Tag2", templateOrder: 0),
            makeEntry(5, isTemplate: true, tag: "Tag2", templateOrder: nil),
            makeEntry(6, isTemplate: true, tag: nil, templateOrder: 1),
            makeEntry(7, isTemplate: true, tag: "   ", templateOrder: 0),
        ]

        let groups = KeyboardTemplateGrouping.make(entries)
        XCTAssertEqual(groups.map(\.title), ["Tag2", "Tag10", "その他"])
        XCTAssertEqual(groups.map { $0.entries.map(\.id) }, [
            [4, 3, 5],
            [2],
            [7, 6],
        ])
        XCTAssertEqual(groups.last?.id, "")
    }

    // MARK: - Text Insertion & Alphanumeric Keypad

    @MainActor
    func testTapEntryInsertsExactTextWithoutTouchingPasteboard() {
        let spy = SpyPasteboard()
        var inserted: [String] = []
        let exactText = "  1行目\n2行目  "
        let historyItem = makeEntry(1, text: exactText)
        let templateItem = makeEntry(2, kind: .url, text: "https://example.com/a?x=1", isTemplate: true)

        let model = KeyboardViewModel(
            entries: [historyItem, templateItem],
            insertText: { inserted.append($0) },
            pasteboardProvider: { spy }
        )

        model.tapEntry(historyItem)
        XCTAssertEqual(model.flashedEntryID, 1)
        model.tapEntry(templateItem)
        XCTAssertEqual(model.flashedEntryID, 2)

        XCTAssertEqual(inserted, [exactText, "https://example.com/a?x=1"])
        XCTAssertFalse(spy.accessed)
    }

    @MainActor
    func testAlphanumericKeysShiftCapsLockSpaceDeleteAndReturn() {
        var currentTime = Date(timeIntervalSince1970: 1_000)
        var inserted: [String] = []
        var deleteCount = 0

        let model = KeyboardViewModel(
            mode: .alphanumeric,
            alphanumericPage: .letters,
            insertText: { inserted.append($0) },
            deleteBackward: { deleteCount += 1 },
            now: { currentTime }
        )

        model.tapCharacter("a")
        XCTAssertEqual(inserted, ["a"])

        // Single shift tap -> uppercase one letter then returns to .off.
        model.toggleShift()
        XCTAssertEqual(model.shiftState, .once)
        model.tapCharacter("b")
        model.tapCharacter("c")
        XCTAssertEqual(inserted, ["a", "B", "c"])
        XCTAssertEqual(model.shiftState, .off)

        // Double tap shift within 0.35s -> caps lock until tapped again.
        model.toggleShift()
        currentTime = currentTime.addingTimeInterval(0.1)
        model.toggleShift()
        XCTAssertEqual(model.shiftState, .locked)
        model.tapCharacter("d")
        model.tapCharacter("e")
        XCTAssertEqual(inserted, ["a", "B", "c", "D", "E"])
        XCTAssertEqual(model.shiftState, .locked)

        model.toggleShift()
        XCTAssertEqual(model.shiftState, .off)

        model.alphanumericPage = .numbers
        model.tapCharacter("7")
        model.tapCharacter("@")
        model.tapSpace()
        model.tapReturn()
        model.tapDelete()

        XCTAssertEqual(inserted, ["a", "B", "c", "D", "E", "7", "@", " ", "\n"])
        XCTAssertEqual(deleteCount, 1)

        model.switchToList()
        XCTAssertEqual(model.mode, .list)
    }

    // MARK: - Full Access Gating & Inbox Save

    @MainActor
    func testFullAccessControlsButtonVisibilityAndInboxWrite() throws {
        let root = try tempDirectory()
        let inboxURL = SharedAppGroup.inboxDirectoryURL(in: root)
        let pasteboard = MockPasteboard()
        pasteboard.hasStrings = true
        pasteboard.string = "saved from keyboard"

        let denied = KeyboardViewModel(
            hasFullAccess: false,
            pasteboardProvider: { pasteboard },
            inboxDirectoryProvider: { inboxURL }
        )
        XCTAssertFalse(denied.showsSaveClipboardButton)
        denied.saveFromPasteboard()
        XCTAssertTrue(SharedInbox.scan(directory: inboxURL).items.isEmpty)

        let allowed = KeyboardViewModel(
            hasFullAccess: true,
            pasteboardProvider: { pasteboard },
            inboxDirectoryProvider: { inboxURL },
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        XCTAssertTrue(allowed.showsSaveClipboardButton)
        allowed.saveFromPasteboard()

        let scanned = SharedInbox.scan(directory: inboxURL)
        XCTAssertEqual(scanned.items.count, 1)
        XCTAssertEqual(scanned.items.first?.item.text, "saved from keyboard")
        XCTAssertEqual(scanned.items.first?.item.origin, .keyboard)
        XCTAssertEqual(allowed.statusMessage?.message, "保存しました")
        XCTAssertEqual(allowed.statusMessage?.isError, false)

        // Concealed content must not be written to the inbox.
        pasteboard.types = ["org.nspasteboard.ConcealedType"]
        pasteboard.string = "secret-password"
        allowed.saveFromPasteboard()
        XCTAssertEqual(SharedInbox.scan(directory: inboxURL).items.count, 1)
        XCTAssertEqual(allowed.statusMessage?.message, "秘密の印があるため保存しませんでした")
    }

    @MainActor
    func testPasteboardExtractorAcceptsWebURLOnlyAndRejectsFiles() {
        let pasteboard = MockPasteboard()
        pasteboard.hasURLs = true
        pasteboard.url = URL(string: "https://example.com/docs")
        XCTAssertEqual(SharedTextExtractor.extractFromPasteboard(pasteboard), .text("https://example.com/docs"))

        pasteboard.types = [UTType.fileURL.identifier]
        pasteboard.url = URL(fileURLWithPath: "/tmp/sample.png")
        pasteboard.hasStrings = false
        XCTAssertEqual(SharedTextExtractor.extractFromPasteboard(pasteboard), .emptyOrUnsupported)

        pasteboard.types = []
        pasteboard.hasURLs = true
        pasteboard.url = URL(fileURLWithPath: "/tmp/sample.png")
        XCTAssertEqual(SharedTextExtractor.extractFromPasteboard(pasteboard), .emptyOrUnsupported)
    }

    // MARK: - Share Extension Extraction & Outcome

    func testSharedTextExtractorAcceptsTextAndWebURLAndRejectsFilesAndImages() async {
        let textProvider = NSItemProvider(object: "共有メモ" as NSString)
        let duplicateProvider = NSItemProvider(object: "共有メモ" as NSString)
        let whitespaceProvider = NSItemProvider(object: "  \n\t " as NSString)
        let urlProvider = NSItemProvider(object: URL(string: "https://example.com/path?q=1")! as NSURL)
        let fileURLProvider = NSItemProvider(
            item: URL(fileURLWithPath: "/tmp/photo.png") as NSURL,
            typeIdentifier: UTType.fileURL.identifier
        )
        let imageProvider = NSItemProvider(
            item: Data([0x89, 0x50, 0x4E, 0x47]) as NSData,
            typeIdentifier: UTType.png.identifier
        )

        let extracted = await SharedTextExtractor.extractTexts(from: [
            whitespaceProvider,
            imageProvider,
            fileURLProvider,
            urlProvider,
            textProvider,
            duplicateProvider,
        ])
        XCTAssertEqual(extracted, ["https://example.com/path?q=1", "共有メモ"])

        XCTAssertTrue(SharedTextExtractor.canAccept([textProvider]))
        XCTAssertTrue(SharedTextExtractor.canAccept([urlProvider]))
        XCTAssertFalse(SharedTextExtractor.canAccept([fileURLProvider]))
        XCTAssertFalse(SharedTextExtractor.canAccept([imageProvider]))
    }

    func testShareSaveOutcomeHandlesSavedEmptyAndMissingContainer() throws {
        let root = try tempDirectory()
        let inboxURL = SharedAppGroup.inboxDirectoryURL(in: root)

        XCTAssertEqual(
            ShareSaveOutcome.save(texts: [], inboxDirectory: inboxURL),
            .noSupportedContent
        )
        XCTAssertEqual(
            ShareSaveOutcome.save(texts: ["hello"], inboxDirectory: nil),
            .storageUnavailable
        )
        XCTAssertEqual(
            ShareSaveOutcome.save(texts: ["hello", "https://example.com"], inboxDirectory: inboxURL),
            .saved(count: 2)
        )
        let items = SharedInbox.scan(directory: inboxURL).items
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.item.origin == .shareExtension })
    }

    // MARK: - Formatting and Layout Metrics

    func testTimeLinkAndLayoutMetrics() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 15, minute: 30))!

        XCTAssertEqual(KeyboardTimeFormatter.label(for: now.addingTimeInterval(-5), now: now, calendar: calendar), "たった今")
        XCTAssertEqual(KeyboardTimeFormatter.label(for: now.addingTimeInterval(-42), now: now, calendar: calendar), "42秒前")
        XCTAssertEqual(KeyboardTimeFormatter.label(for: now.addingTimeInterval(-180), now: now, calendar: calendar), "3分前")
        XCTAssertEqual(
            KeyboardTimeFormatter.label(
                for: calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9, minute: 5))!,
                now: now, calendar: calendar
            ),
            "9:05"
        )
        XCTAssertEqual(
            KeyboardTimeFormatter.label(
                for: calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 21, minute: 0))!,
                now: now, calendar: calendar
            ),
            "11/17 21:00"
        )

        XCTAssertEqual(
            KeyboardLinkFormatting.parts("https://example.com/a/b?k=v"),
            KeyboardLinkFormatting.Parts(host: "example.com", remainder: "/a/b?k=v")
        )
        XCTAssertEqual(KeyboardLayoutMetrics.columnCount(forWidth: 393), 1)
        XCTAssertEqual(KeyboardLayoutMetrics.columnCount(forWidth: 768), 2)
        XCTAssertEqual(KeyboardLayoutMetrics.preferredHeight(idiom: .phone, verticalSizeClass: .regular, width: 393), 284)
        XCTAssertEqual(KeyboardLayoutMetrics.preferredHeight(idiom: .phone, verticalSizeClass: .compact, width: 852), 204)
        XCTAssertEqual(KeyboardLayoutMetrics.preferredHeight(idiom: .pad, verticalSizeClass: .regular, width: 1_024), 340)
    }
}
