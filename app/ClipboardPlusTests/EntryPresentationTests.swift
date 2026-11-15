import XCTest
@testable import ClipboardPlus

final class EntryPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    private func entry(_ id: Int, _ text: String = "text", kind: HistoryKind = .text, at date: Date, pinned: Bool = false) -> HistoryEntry {
        HistoryEntry(id: id, kind: kind, text: text, savedAt: date, lastCollectedAt: date,
                     collectionCount: 1, isPinned: pinned, source: .automatic)
    }

    // MARK: Flavor

    func testFlavorFollowsStoredKindForLinksAndImages() {
        let now = Date()
        XCTAssertEqual(EntryFlavor.detect(entry(1, "https://example.com/a", kind: .url, at: now)), .link)
        XCTAssertEqual(EntryFlavor.detect(entry(2, "", kind: .image, at: now)), .image)
    }

    func testFlavorRecognizesColorsEmailAndPhone() {
        XCTAssertEqual(EntryFlavor.detect(text: "#FF8000"), .color(red: 1, green: 128.0 / 255, blue: 0))
        XCTAssertEqual(EntryFlavor.detect(text: " #fff \n"), .color(red: 1, green: 1, blue: 1))
        XCTAssertEqual(EntryFlavor.detect(text: "#11223344"), .color(red: 17.0 / 255, green: 34.0 / 255, blue: 51.0 / 255))
        XCTAssertEqual(EntryFlavor.detect(text: "hello@example.com"), .email)
        XCTAssertEqual(EntryFlavor.detect(text: "090-1234-5678"), .phone)
        XCTAssertEqual(EntryFlavor.detect(text: "+81 90 1234 5678"), .phone)
    }

    func testFlavorLeavesOrdinaryTextAlone() {
        for text in ["", "FF8000", "#GGGGGG", "#12345", "2026-11-15", "1234567890", "hello@", "メモ #1", "a@b",
                     "090-1234-5678 に電話する", String(repeating: "a", count: 65) + "@example.com"] {
            XCTAssertEqual(EntryFlavor.detect(text: text), .text, text)
        }
    }

    // MARK: Links

    func testLinkPartsSplitHostFromTheRest() {
        XCTAssertEqual(EntryLinks.parts("https://example.com/docs/page?x=1#top"),
                       EntryLink(host: "example.com", remainder: "/docs/page?x=1#top"))
        XCTAssertEqual(EntryLinks.parts("https://example.com/"), EntryLink(host: "example.com", remainder: nil))
        XCTAssertEqual(EntryLinks.parts("https://example.com"), EntryLink(host: "example.com", remainder: nil))
        XCTAssertNil(EntryLinks.parts("ただの文章"))
    }

    // MARK: Time

    func testTimeLabelUsesRelativeWordsWithinAnHour() {
        let now = date(2026, 11, 15, 14, 30)
        XCTAssertEqual(EntryTime.label(for: now, now: now, includesDay: false, calendar: calendar), "たった今")
        XCTAssertEqual(EntryTime.label(for: now.addingTimeInterval(-9), now: now, includesDay: true, calendar: calendar), "たった今")
        XCTAssertEqual(EntryTime.label(for: now.addingTimeInterval(-45), now: now, includesDay: true, calendar: calendar), "45秒前")
        XCTAssertEqual(EntryTime.label(for: now.addingTimeInterval(-59 * 60), now: now, includesDay: true, calendar: calendar), "59分前")
        // A clock that moved backwards must not produce a negative label.
        XCTAssertEqual(EntryTime.label(for: now.addingTimeInterval(120), now: now, includesDay: true, calendar: calendar), "たった今")
    }

    func testTimeLabelUsesClockTimeAndDayForOlderItems() {
        let now = date(2026, 11, 15, 14, 30)
        XCTAssertEqual(EntryTime.label(for: date(2026, 11, 15, 9, 5), now: now, includesDay: false, calendar: calendar), "9:05")
        XCTAssertEqual(EntryTime.label(for: date(2026, 11, 3, 18, 40), now: now, includesDay: true, calendar: calendar), "11/3 18:40")
        XCTAssertEqual(EntryTime.label(for: date(2025, 12, 31, 23, 59), now: now, includesDay: true, calendar: calendar), "2025/12/31")
    }

    // MARK: Sections

    func testSectionsGroupByDayAndKeepOrder() {
        let now = date(2026, 11, 15, 14, 30)
        let entries = [
            entry(1, at: date(2026, 11, 15, 14, 0)),
            entry(2, at: date(2026, 11, 15, 0, 0)),
            entry(3, at: date(2026, 11, 14, 23, 59)),
            entry(4, at: date(2026, 11, 9, 0, 0)),
            entry(5, at: date(2026, 11, 8, 23, 59)),
        ]
        let sections = EntrySections.make(entries, separatesPinned: true, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.kind), [.today, .yesterday, .thisWeek, .earlier])
        XCTAssertEqual(sections.map { $0.entries.map(\.id) }, [[1, 2], [3], [4], [5]])
    }

    func testPinnedItemsFormTheirOwnSectionOnlyWhenAsked() {
        let now = date(2026, 11, 15, 14, 30)
        let entries = [
            entry(1, at: date(2026, 11, 15, 14, 0)),
            entry(2, at: date(2026, 11, 1, 8, 0), pinned: true),
            entry(3, at: date(2026, 11, 15, 9, 0), pinned: true),
        ]
        let separated = EntrySections.make(entries, separatesPinned: true, now: now, calendar: calendar)
        XCTAssertEqual(separated.map(\.kind), [.pinned, .today])
        XCTAssertEqual(separated.first?.entries.map(\.id), [2, 3])
        let merged = EntrySections.make(entries, separatesPinned: false, now: now, calendar: calendar)
        XCTAssertEqual(merged.map(\.kind), [.today, .earlier])
        XCTAssertEqual(merged.first?.entries.map(\.id), [1, 3])
        XCTAssertTrue(EntrySections.make([], separatesPinned: true, now: now, calendar: calendar).isEmpty)
    }

    // MARK: Columns

    func testColumnCountGrowsWithTheWindow() {
        XCTAssertEqual(EntryColumns.count(forWidth: 0), 1)
        XCTAssertEqual(EntryColumns.count(forWidth: 360), 1)
        XCTAssertEqual(EntryColumns.count(forWidth: 633), 1)
        XCTAssertEqual(EntryColumns.count(forWidth: 634), 2)
        XCTAssertEqual(EntryColumns.count(forWidth: 1_024), 3)
        XCTAssertEqual(EntryColumns.count(forWidth: 1_366), 4)
    }

    func testColumnsDealEntriesInTurnAndKeepEmptyColumns() {
        let now = Date()
        let entries = (1...5).map { entry($0, at: now) }
        XCTAssertEqual(EntryColumns.split(entries, into: 3).map { $0.map(\.id) }, [[1, 4], [2, 5], [3]])
        XCTAssertEqual(EntryColumns.split(Array(entries.prefix(2)), into: 3).map { $0.map(\.id) }, [[1], [2], []])
        XCTAssertEqual(EntryColumns.split(entries, into: 0).map { $0.map(\.id) }, [[1, 2, 3, 4, 5]])
    }

    // MARK: Snippets

    func testSnippetWithoutQueryIsTheTrimmedBeginning() {
        let snippet = EntryPreview.snippet("  \n最初の行\n二行目  ", query: "")
        XCTAssertEqual(snippet.text, "最初の行\n二行目")
        XCTAssertTrue(snippet.matches.isEmpty)
        XCTAssertEqual(EntryPreview.snippet(String(repeating: "あ", count: 500), query: "", limit: 280).text.count, 280)
    }

    func testSnippetStartsNearTheFirstMatchAndMarksEveryMatch() {
        let text = String(repeating: "前", count: 100) + "Needle と needle" + String(repeating: "後", count: 100)
        let snippet = EntryPreview.snippet(text, query: "NEEDLE", limit: 60, lead: 10)
        XCTAssertTrue(snippet.text.hasPrefix("…" + String(repeating: "前", count: 10) + "Needle"))
        XCTAssertEqual(snippet.matches.map { String(snippet.text[$0]) }, ["Needle", "needle"])
        XCTAssertEqual(snippet.text.count, 61)
    }

    func testSnippetAtTheStartHasNoEllipsisAndMissingQueryFallsBack() {
        let hit = EntryPreview.snippet("needle がある", query: "needle")
        XCTAssertEqual(hit.text, "needle がある")
        XCTAssertEqual(hit.matches.count, 1)
        let miss = EntryPreview.snippet("何もない文章", query: "needle")
        XCTAssertEqual(miss.text, "何もない文章")
        XCTAssertTrue(miss.matches.isEmpty)
    }

    // MARK: Filters

    func testNewFiltersSelectTextsAndLinks() {
        let now = Date()
        let entries = [
            entry(1, "メモ", at: now),
            entry(2, "https://example.com", kind: .url, at: now),
            entry(3, "", kind: .image, at: now),
        ]
        XCTAssertEqual(HistoryFilter.entries(entries, filter: .texts, search: "").map(\.id), [1])
        XCTAssertEqual(HistoryFilter.entries(entries, filter: .links, search: "").map(\.id), [2])
        XCTAssertEqual(HistoryFilter.entries(entries, filter: .links, search: "EXAMPLE").map(\.id), [2])
        XCTAssertTrue(HistoryFilter.entries(entries, filter: .texts, search: "example").isEmpty)
    }

    func testSearchIgnoresSpacesAroundTheTerm() {
        let now = Date()
        let entries = [entry(1, "needle がある", at: now), entry(2, "別の文章", at: now)]
        XCTAssertEqual(HistoryFilter.entries(entries, filter: .all, search: " needle　\n").map(\.id), [1])
        XCTAssertEqual(HistoryFilter.entries(entries, filter: .all, search: "   ").map(\.id), [1, 2])
        XCTAssertEqual(HistoryFilter.normalized("  a b  "), "a b")
    }
}
