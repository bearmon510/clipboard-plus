import AppIntents
import XCTest
@testable import ClipboardPlus

final class ShortcutContentTests: XCTestCase {
    private func entry(_ id: Int, kind: HistoryKind = .text, text: String = "文章",
                       collected: Double = 10, pinned: Bool = false, image: HistoryImage? = nil) -> HistoryEntry {
        HistoryEntry(id: id, kind: kind, text: text, savedAt: Date(timeIntervalSince1970: 1),
                     lastCollectedAt: Date(timeIntervalSince1970: collected), collectionCount: 1,
                     isPinned: pinned, source: .manual, image: image)
    }

    func testLinesUseReadingOrderMergeSameRowAndRemoveWhitespaceOnlyLines() throws {
        let lines = [
            RecognizedLine(text: " 下の行 \r\n\n最後 ", box: CGRect(x: 0, y: 0.7, width: 0.8, height: 0.1)),
            RecognizedLine(text: "右", box: CGRect(x: 0.5, y: 0.1, width: 0.2, height: 0.1)),
            RecognizedLine(text: " \t\n ", box: CGRect(x: 0, y: 0.4, width: 0.8, height: 0.1)),
            RecognizedLine(text: "左", box: CGRect(x: 0, y: 0.1, width: 0.2, height: 0.1))
        ]
        XCTAssertEqual(try ShortcutContent.lines(lines), ["左 右", "下の行", "最後"])
        for empty in [[], [RecognizedLine(text: " \t\n", box: .zero)]] as [[RecognizedLine]] {
            XCTAssertThrowsError(try ShortcutContent.lines(empty)) { error in
                guard case ShortcutError.noText = error else { XCTFail("Unexpected error: \(error)"); return }
                XCTAssertTrue(error.localizedDescription.contains("文字が見つかりません"))
            }
        }
    }

    func testTextListIsOneItemAndPreservesNonemptyItemFormatting() {
        XCTAssertNil(ShortcutContent.joinedText(nil))
        XCTAssertNil(ShortcutContent.joinedText([]))
        XCTAssertNil(ShortcutContent.joinedText(["", " \n\t"]))
        XCTAssertEqual(ShortcutContent.joinedText(["A", "B"]), "A\nB")
        XCTAssertEqual(ShortcutContent.joinedText(["  コード\n", "", "\t字下げ"]), "  コード\n\n\t字下げ")
    }

    func testLimitsIncludingIntegerExtremes() {
        XCTAssertEqual(ShortcutContent.limit(Int.min), 1)
        XCTAssertEqual(ShortcutContent.limit(0), 1)
        XCTAssertEqual(ShortcutContent.limit(1), 1)
        XCTAssertEqual(ShortcutContent.limit(20), 20)
        XCTAssertEqual(ShortcutContent.limit(50), 50)
        XCTAssertEqual(ShortcutContent.limit(Int.max), 50)
        let entries = (1...60).map { entry($0) }
        XCTAssertEqual(ShortcutContent.entries(entries, limit: Int.max).count, 50)
        XCTAssertEqual(ShortcutContent.entries(entries, limit: 20).count, 20)
        XCTAssertEqual(ShortcutContent.entries(entries, limit: 0).map(\.id), [60])
        XCTAssertEqual(ShortcutContent.matchingEntries(entries, search: "文章").count, 60)
    }

    func testFiltersUseExistingKindsAndCollectedDateWithIDTiebreaker() {
        let entries = [entry(1, collected: 30), entry(2, kind: .url, collected: 20, pinned: true),
                       entry(3, kind: .image, collected: 30, pinned: true), entry(4, collected: 10)]
        let expected: [(HistoryFilterOption, [Int])] = [
            (.all, [3, 1, 2, 4]), (.pinned, [3, 2]), (.texts, [1, 4]), (.links, [2]), (.images, [3])
        ]
        for (option, ids) in expected {
            XCTAssertEqual(ShortcutContent.entries(entries, filter: option.filter).map(\.id), ids)
        }
        XCTAssertEqual(ShortcutContent.entries(entries, limit: 1).first?.id, 3)
    }

    func testSearchMatchesExistingRulesIncludingEmptySearchAndImages() {
        let entries = [entry(1, text: "Hello 日本語"),
                       entry(2, kind: .url, text: "https://example.com/HELLO"),
                       entry(3, kind: .image, text: "Hello"), entry(4, text: "else")]
        for query in [" hello \n", "日本語", "HEL", "", " \t\n", "not found"] {
            let expected = HistoryFilter.entries(entries, filter: .all, search: query).map(\.id).sorted(by: >)
            XCTAssertEqual(ShortcutContent.entries(entries, search: query).map(\.id), expected)
        }
        XCTAssertEqual(ShortcutContent.entries(entries, search: "hello").map(\.id), [2, 1])
        XCTAssertTrue(ShortcutContent.entries(entries, filter: .images, search: "hello").isEmpty)
    }

    func testEntityTextPropertiesAndDisplay() {
        let item = entry(7, text: "\n先頭の行\n二行目", pinned: true)
        let entity = HistoryEntryEntity(entry: item)
        XCTAssertEqual(entity.id, 7)
        XCTAssertEqual(entity.text, item.text)
        XCTAssertEqual(entity.kind, "文章")
        XCTAssertEqual(entity.savedAt, item.savedAt)
        XCTAssertTrue(entity.isPinned)
        XCTAssertNil(entity.picture)
        XCTAssertEqual(entity.displayTitle, "先頭の行")
        XCTAssertTrue(entity.displaySubtitle.contains("ピン留め"))
        XCTAssertTrue(entity.displaySubtitle.contains(item.savedAt.formatted(date: .abbreviated, time: .shortened)))
        XCTAssertEqual(String(localized: entity.displayRepresentation.title), entity.displayTitle)
        XCTAssertEqual(ShortcutContent.title(entry(8, text: String(repeating: "あ", count: 61))),
                       String(repeating: "あ", count: 60) + "…")
    }

    func testImageEntityPropertiesAndDisplay() {
        let image = HistoryImage(hash: "hash", filename: "test.png", thumbnailFilename: "thumb.jpg",
                                 byteCount: 100, pixelWidth: 1200, pixelHeight: 800, typeIdentifier: "public.png")
        let file = IntentFile(data: Data([1, 2]), filename: "test.png", type: .png)
        let entity = HistoryEntryEntity(entry: entry(1, kind: .image, text: "", image: image), picture: file)
        XCTAssertEqual(entity.displayTitle, "画像 1200×800")
        XCTAssertEqual(entity.kind, "画像")
        XCTAssertEqual(entity.text, "")
        XCTAssertEqual(entity.picture?.data, file.data)
        XCTAssertFalse(entity.isPinned)
        XCTAssertFalse(entity.displaySubtitle.contains("ピン留め"))
    }
}
