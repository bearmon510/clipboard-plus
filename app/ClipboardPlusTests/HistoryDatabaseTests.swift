import Foundation
import SQLite3
import XCTest
@testable import ClipboardPlus

final class HistoryDatabaseTests: XCTestCase {
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_000)
        func advance(_ seconds: TimeInterval = 1) { date.addTimeInterval(seconds) }
    }

    private func fixture() throws -> (HistoryDatabase, URL, Clock) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let clock = Clock()
        return (try HistoryDatabase(url: url, now: { clock.date }), url, clock)
    }

    private func scalar(_ sql: String, url: URL) throws -> Int {
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK else {
            sqlite3_close(connection)
            throw HistoryDatabaseError.invalidRow
        }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw HistoryDatabaseError.invalidRow
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw HistoryDatabaseError.invalidRow }
        return result == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    func testReopenPreservesEveryFieldAndPin() throws {
        let (_, url, clock) = try fixture()
        var database: HistoryDatabase? = try HistoryDatabase(url: url, now: { clock.date })
        let entry = try database!.collect("https://example.com/path", source: .manual)
        try database!.togglePin(id: entry.id)
        clock.advance()
        try database!.collect(entry.text, source: .drag)
        let expected = try database!.fetchAll()
        database = nil
        let reopened = try HistoryDatabase(url: url, now: { clock.date })
        XCTAssertEqual(try reopened.fetchAll(), expected)
        XCTAssertEqual(expected.first?.source, .drag)
        XCTAssertEqual(expected.first?.isPinned, true)
    }

    func testExactDuplicateUpdatesCountTimeAndOrderKeepingIdentity() throws {
        let (database, _, clock) = try fixture()
        let a = try database.collect("A", source: .automatic)
        try database.togglePin(id: a.id)
        clock.advance()
        let b = try database.collect("B", source: .automatic)
        clock.advance()
        let updated = try database.collect("A", source: .manual)
        XCTAssertEqual(updated.id, a.id)
        XCTAssertEqual(updated.savedAt, a.savedAt)
        XCTAssertEqual(updated.lastCollectedAt, clock.date)
        XCTAssertEqual(updated.collectionCount, 2)
        XCTAssertTrue(updated.isPinned)
        XCTAssertEqual(updated.source, .manual)
        XCTAssertEqual(try database.fetchAll().map(\.id), [a.id, b.id])
    }

    func testOlderDuplicateKeepsLatestTextTimeSourceAndOrder() throws {
        let (database, _, _) = try fixture()
        let latest = Date(timeIntervalSince1970: 200)
        let first = try database.collect("A", source: .automatic, at: latest)
        let other = try database.collect("B", source: .drag, at: latest.addingTimeInterval(-1))
        let duplicate = try database.collect("A", source: .manual, at: latest.addingTimeInterval(-2))
        XCTAssertEqual(duplicate.id, first.id)
        XCTAssertEqual(duplicate.savedAt, first.savedAt)
        XCTAssertEqual(duplicate.lastCollectedAt, latest)
        XCTAssertEqual(duplicate.source, .automatic)
        XCTAssertEqual(duplicate.collectionCount, 2)
        XCTAssertEqual(try database.fetchAll().map(\.id), [first.id, other.id])
    }

    func testSameTimeTextDuplicateUpdatesSourceAndCount() throws {
        let (database, _, _) = try fixture()
        let date = Date(timeIntervalSince1970: 200)
        try database.collect("A", source: .automatic, at: date)
        let duplicate = try database.collect("A", source: .manual, at: date)
        XCTAssertEqual(duplicate.lastCollectedAt, date)
        XCTAssertEqual(duplicate.source, .manual)
        XCTAssertEqual(duplicate.collectionCount, 2)
    }

    func testWhitespaceAndNewlineDifferencesRemainSeparate() throws {
        let (database, _, _) = try fixture()
        let texts = ["A", " A", "A ", "A\n", "A\r\n", "a", ""]
        for text in texts { try database.collect(text, source: .automatic) }
        XCTAssertEqual(try database.fetchAll().map(\.text), texts.reversed().map { $0 })
    }

    func testUnicodeNULAndSQLCharactersRoundTripExactly() throws {
        let (database, _, _) = try fixture()
        let texts = ["引用' ; DROP TABLE history; --", "絵文字😀\u{0}末尾", "é", "e\u{301}"]
        for text in texts { try database.collect(text, source: .manual) }
        try database.collect(texts[1], source: .manual)
        let values = try database.fetchAll()
        XCTAssertEqual(values.count, texts.count)
        for text in texts {
            XCTAssertEqual(values.filter { $0.text.utf8.elementsEqual(text.utf8) }.count, 1)
        }
        XCTAssertEqual(values.first { $0.text.utf8.elementsEqual(texts[1].utf8) }?.collectionCount, 2)
    }

    func testSelfCopyReadbackDoesNotUpdateTimestampOrOrder() throws {
        let (database, _, clock) = try fixture()
        var admission = HistoryAdmission()
        let a = try database.collect("A", source: .automatic)
        clock.advance()
        try database.collect("B", source: .automatic)
        let before = try database.fetchAll()
        admission.recordSelfCopy(a.text)
        clock.advance()
        let decision = admission.receive(a.text)
        if decision == .add { try database.collect(a.text, source: .automatic) }
        XCTAssertEqual(decision, .skip(reason: "直前の内容と同じ"))
        XCTAssertEqual(try database.fetchAll(), before)
        XCTAssertEqual(admission.receive(a.text), .add)
        try database.collect(a.text, source: .automatic)
        XCTAssertEqual(try database.fetchAll().first?.collectionCount, 2)
        XCTAssertEqual(try database.fetchAll().first?.lastCollectedAt, clock.date)
    }

    func testTogglePinDoesNotChangeCollectionMetadata() throws {
        let (database, _, _) = try fixture()
        let entry = try database.collect("A", source: .drag)
        try database.togglePin(id: entry.id)
        XCTAssertEqual(try database.fetchAll().first?.isPinned, true)
        try database.togglePin(id: entry.id)
        XCTAssertEqual(try database.fetchAll(), [entry])
    }

    func testSingleDeleteAndUndoRestoreOriginalMetadataAndOrder() throws {
        let (database, _, clock) = try fixture()
        let entry = try database.collect("A", source: .manual)
        try database.togglePin(id: entry.id)
        clock.advance()
        try database.collect("B", source: .automatic)
        let before = try database.fetchAll()
        let deletion = try XCTUnwrap(database.delete(id: entry.id))
        XCTAssertEqual(deletion.count, 1)
        XCTAssertEqual(try database.fetchAll().map(\.text), ["B"])
        clock.advance(4)
        XCTAssertTrue(try database.undo(deletion))
        XCTAssertEqual(try database.fetchAll(), before)
        XCTAssertFalse(try database.undo(deletion))
    }

    func testClearExcludingPinnedAndUndo() throws {
        let (database, _, _) = try fixture()
        let pinned = try database.collect("pin", source: .automatic)
        try database.togglePin(id: pinned.id)
        try database.collect("ordinary", source: .manual)
        let before = try database.fetchAll()
        let deletion = try XCTUnwrap(database.deleteAll(includePinned: false))
        XCTAssertEqual(deletion.count, 1)
        XCTAssertEqual(try database.fetchAll().map(\.id), [pinned.id])
        XCTAssertTrue(try database.undo(deletion))
        XCTAssertEqual(try database.fetchAll(), before)
    }

    func testClearIncludingPinnedAndUndo() throws {
        let (database, _, _) = try fixture()
        let pinned = try database.collect("pin", source: .automatic)
        try database.togglePin(id: pinned.id)
        try database.collect("ordinary", source: .drag)
        let before = try database.fetchAll()
        let deletion = try XCTUnwrap(database.deleteAll(includePinned: true))
        XCTAssertEqual(deletion.count, 2)
        XCTAssertTrue(try database.fetchAll().isEmpty)
        XCTAssertTrue(try database.undo(deletion))
        XCTAssertEqual(try database.fetchAll(), before)
    }

    func testExpiryPermanentlyDeletesRowsAtDeadline() throws {
        let (database, url, clock) = try fixture()
        let entry = try database.collect("A", source: .automatic)
        let deletion = try XCTUnwrap(database.delete(id: entry.id))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history", url: url), 1)
        clock.advance(HistoryDatabase.undoInterval)
        try database.purgeExpired()
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history", url: url), 0)
        XCTAssertFalse(try database.undo(deletion))
        XCTAssertNil(try database.latestDeletion())
    }

    func testReopenCleansExpiredDeletion() throws {
        let (database, url, clock) = try fixture()
        try database.collect("A", source: .automatic)
        let deletion = try XCTUnwrap(database.deleteAll(includePinned: true))
        clock.advance(6)
        let reopened = try HistoryDatabase(url: url, now: { clock.date })
        XCTAssertFalse(try reopened.undo(deletion))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history", url: url), 0)
    }

    func testReopenKeepsUnexpiredUndo() throws {
        let (database, url, clock) = try fixture()
        let entry = try database.collect("A", source: .automatic)
        let deletion = try XCTUnwrap(database.delete(id: entry.id))
        clock.advance(1)
        let reopened = try HistoryDatabase(url: url, now: { clock.date })
        XCTAssertEqual(try reopened.latestDeletion(), deletion)
        XCTAssertTrue(try reopened.undo(deletion))
        XCTAssertEqual(try reopened.fetchAll(), [entry])
    }

    func testUndoMergesRecollectedTextWithoutLosingNewCollection() throws {
        let (database, _, clock) = try fixture()
        let original = try database.collect("A", source: .automatic)
        try database.togglePin(id: original.id)
        let deletion = try XCTUnwrap(database.delete(id: original.id))
        clock.advance()
        try database.collect("A", source: .drag)
        XCTAssertTrue(try database.undo(deletion))
        let restored = try XCTUnwrap(database.fetchAll().first)
        XCTAssertEqual(try database.fetchAll().count, 1)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.savedAt, original.savedAt)
        XCTAssertEqual(restored.lastCollectedAt, clock.date)
        XCTAssertEqual(restored.collectionCount, 2)
        XCTAssertTrue(restored.isPinned)
        XCTAssertEqual(restored.source, .drag)
    }

    func testLimitKeepsThousandNewestUnpinnedAndEveryPinnedItem() throws {
        let (database, _, clock) = try fixture()
        let pinned = try database.collect("pinned", source: .manual)
        try database.togglePin(id: pinned.id)
        for index in 0..<1_002 {
            clock.advance()
            try database.collect("item \(index)", source: .automatic)
        }
        let entries = try database.fetchAll()
        XCTAssertEqual(entries.count, 1_001)
        XCTAssertEqual(entries.filter { !$0.isPinned }.count, 1_000)
        XCTAssertEqual(entries.last?.id, pinned.id)
        XCTAssertFalse(entries.contains { $0.text == "item 0" || $0.text == "item 1" })
        XCTAssertEqual(entries.first?.text, "item 1001")
        try database.togglePin(id: pinned.id)
        XCTAssertEqual(try database.fetchAll().count, 1_000)
        XCTAssertFalse(try database.fetchAll().contains { $0.id == pinned.id })
    }

    func testLimitUsesLastCollectionTimeAfterDuplicate() throws {
        let (database, _, clock) = try fixture()
        for index in 0..<1_000 {
            clock.advance()
            try database.collect("item \(index)", source: .automatic)
        }
        clock.advance()
        try database.collect("item 0", source: .automatic)
        clock.advance()
        try database.collect("new", source: .automatic)
        let entries = try database.fetchAll()
        XCTAssertTrue(entries.contains { $0.text == "item 0" })
        XCTAssertFalse(entries.contains { $0.text == "item 1" })
    }

    func testUndoAlsoEnforcesLimit() throws {
        let (database, _, clock) = try fixture()
        let old = try database.collect("old", source: .automatic)
        let deletion = try XCTUnwrap(database.delete(id: old.id))
        for index in 0..<1_001 {
            try database.collect("item \(index)", source: .automatic, at: clock.date.addingTimeInterval(1))
        }
        XCTAssertTrue(try database.undo(deletion))
        XCTAssertEqual(try database.fetchAll().count, 1_000)
        XCTAssertFalse(try database.fetchAll().contains { $0.id == old.id })
    }

    func testEmptyDeletionDoesNotCreateUndo() throws {
        let (database, _, _) = try fixture()
        XCTAssertNil(try database.delete(id: 42))
        XCTAssertNil(try database.deleteAll(includePinned: true))
        XCTAssertNil(try database.latestDeletion())
    }

    func testURLClassificationAndDomain() throws {
        let (database, _, _) = try fixture()
        for text in ["https://example.com/a?q=1#part", "HTTP://example.com", "https://例え.jp/道"] {
            let entry = try database.collect(text, source: .manual)
            XCTAssertEqual(entry.kind, .url, text)
            XCTAssertNotNil(entry.domain)
        }
        for text in ["example.com", "https://", "text https://example.com", "https://example.com\n", "ftp://example.com", ""] {
            XCTAssertEqual(HistoryKind.classify(text), .text, text)
        }
        XCTAssertEqual(try database.collect("https://example.com/path", source: .drag).domain, "example.com")
    }

    func testJSONIncludesVersionTimestampAndEveryEntryField() throws {
        let (database, _, clock) = try fixture()
        let first = try database.collect("https://example.com/path", source: .automatic)
        try database.togglePin(id: first.id)
        clock.advance()
        try database.collect(first.text, source: .drag)
        try database.collect("文章\n\"引用\"😀", source: .manual)
        let removed = try database.collect("deleted", source: .manual)
        _ = try database.delete(id: removed.id)
        let entries = try database.fetchAll()
        let data = try HistoryExport.data(entries: entries, exportedAt: clock.date)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["formatVersion"] as? Int, 4)
        XCTAssertEqual(root["exportedAt"] as? String, "1970-01-01T00:16:41.000Z")
        let rows = try XCTUnwrap(root["entries"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        for (row, entry) in zip(rows, entries) {
            XCTAssertEqual(row["id"] as? Int, entry.id)
            XCTAssertEqual(row["text"] as? String, entry.text)
            XCTAssertEqual(row["kind"] as? String, entry.kind.rawValue)
            XCTAssertEqual(row["collectionCount"] as? Int, entry.collectionCount)
            XCTAssertEqual(row["isPinned"] as? Bool, entry.isPinned)
            XCTAssertEqual(row["source"] as? String, entry.source.rawValue)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            XCTAssertEqual(formatter.date(from: try XCTUnwrap(row["savedAt"] as? String)), entry.savedAt)
            XCTAssertEqual(formatter.date(from: try XCTUnwrap(row["lastCollectedAt"] as? String)), entry.lastCollectedAt)
        }
    }

    func testSchemaVersionIsStoredAndPreservedOnReopen() throws {
        let (database, url, clock) = try fixture()
        XCTAssertEqual(try database.readSchemaVersion(), HistoryDatabase.schemaVersion)
        XCTAssertEqual(try scalar("PRAGMA user_version", url: url), HistoryDatabase.schemaVersion)
        let reopened = try HistoryDatabase(url: url, now: { clock.date })
        XCTAssertEqual(try reopened.readSchemaVersion(), HistoryDatabase.schemaVersion)
    }

    func testFutureSchemaIsRejectedWithoutChangingDataOrVersion() throws {
        let (database, url, clock) = try fixture()
        try database.collect("retained", source: .manual)
        _ = try scalar("PRAGMA user_version = 99", url: url)
        XCTAssertThrowsError(try HistoryDatabase(url: url, now: { clock.date }))
        XCTAssertEqual(try scalar("PRAGMA user_version", url: url), 99)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history", url: url), 1)
    }
}
