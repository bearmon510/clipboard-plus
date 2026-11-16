import AppIntents
import Foundation
import XCTest
@testable import ClipboardPlus

final class TemplateHistoryTests: XCTestCase {
    private func fixture() throws -> (HistoryDatabase, URL) {
        let url = try ImageTestSupport.directory(self).appendingPathComponent("history.sqlite")
        return (try HistoryDatabase(url: url), url)
    }

    func testV3MigrationNumbersExistingPinsByDateAndIDAndReopens() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("v3.sqlite")
        try ImageTestSupport.sql("""
            CREATE TABLE history (
                id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, text TEXT NOT NULL COLLATE BINARY,
                saved_at REAL NOT NULL, collected_at REAL NOT NULL, collection_count INTEGER NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL, deletion_id TEXT, delete_after REAL,
                image_hash TEXT, image_file TEXT, thumbnail_file TEXT, image_bytes INTEGER,
                pixel_width INTEGER, pixel_height INTEGER, image_type TEXT,
                file_hash TEXT, file_name TEXT, original_filename TEXT, file_bytes INTEGER, file_type TEXT
            );
            CREATE UNIQUE INDEX history_active_text ON history(text) WHERE deletion_id IS NULL AND kind NOT IN ('image', 'file');
            INSERT INTO history(id, kind, text, saved_at, collected_at, collection_count, pinned, source)
                VALUES (1, 'text', 'one', 1, 20, 1, 1, 'manual'),
                       (2, 'text', 'two', 1, 30, 2, 1, 'automatic'),
                       (3, 'text', 'three', 1, 30, 1, 1, 'drag'),
                       (4, 'text', 'four', 1, 40, 1, 0, 'capture');
            PRAGMA user_version = 3;
            """, at: url)
        var database: HistoryDatabase? = try HistoryDatabase(url: url)
        XCTAssertEqual(try database!.readSchemaVersion(), 4)
        let entries = try database!.fetchAll()
        XCTAssertEqual(HistoryEntry.orderedPins(entries.filter(\.isPinned)).map(\.id), [3, 2, 1])
        XCTAssertEqual(entries.filter(\.isPinned).compactMap(\.pinOrder), [0, 1, 2])
        XCTAssertNil(entries.first?.pinOrder)
        XCTAssertTrue(entries.allSatisfy { $0.title == nil })
        database = nil
        XCTAssertEqual(try HistoryDatabase(url: url).fetchAll(), entries)
    }

    func testCreateNewAndExistingTextPreservesIdentityAndDates() throws {
        let (db, _) = try fixture()
        let first = try db.createWritten(text: "本文", title: " 署名\n")
        XCTAssertEqual(first.source, .written)
        XCTAssertTrue(first.isPinned)
        XCTAssertEqual(first.title, "署名")
        XCTAssertNotNil(first.pinOrder)
        let reused = try db.createWritten(text: first.text, title: nil)
        XCTAssertEqual(reused, first)
        let existing = try db.collect("https://example.com", source: .automatic, at: Date(timeIntervalSince1970: 100))
        let pinned = try db.createWritten(text: existing.text, title: "サイト")
        XCTAssertEqual(pinned.id, existing.id)
        XCTAssertEqual(pinned.kind, .url)
        XCTAssertEqual(pinned.source, existing.source)
        XCTAssertEqual(pinned.collectionCount, existing.collectionCount)
        XCTAssertEqual(pinned.savedAt, existing.savedAt)
        XCTAssertEqual(pinned.lastCollectedAt, existing.lastCollectedAt)
        XCTAssertEqual(HistoryEntry.orderedPins(try db.fetchAll()).map(\.id), [pinned.id, first.id])
        XCTAssertThrowsError(try db.createWritten(text: " \n\t", title: nil)) { XCTAssertEqual($0 as? HistoryEditError, .empty) }
        XCTAssertEqual(try db.fetchAll().count, 2)
    }

    func testEditRejectsDuplicateAtomicallyAndReclassifiesWithoutMoving() throws {
        let (db, _) = try fixture()
        let first = try db.createWritten(text: "最初", title: "名前")
        let second = try db.createWritten(text: "別の本文", title: nil)
        let before = try db.fetchAll()
        XCTAssertThrowsError(try db.editText(id: first.id, text: second.text, title: "変更しない")) {
            XCTAssertEqual($0 as? HistoryEditError, .duplicate)
        }
        XCTAssertEqual(try db.fetchAll(), before)
        let url = try db.editText(id: first.id, text: "https://example.com/path", title: "リンク")
        XCTAssertEqual(url.kind, .url)
        XCTAssertEqual(url.id, first.id)
        XCTAssertEqual(url.isPinned, first.isPinned)
        XCTAssertEqual(url.pinOrder, first.pinOrder)
        XCTAssertEqual(url.savedAt, first.savedAt)
        XCTAssertEqual(url.lastCollectedAt, first.lastCollectedAt)
        XCTAssertEqual(url.collectionCount, first.collectionCount)
        XCTAssertEqual(try db.fetchAll().map(\.id), before.map(\.id))
        let text = try db.editText(id: first.id, text: "文章へ戻す", title: nil)
        XCTAssertEqual(text.kind, .text)
        XCTAssertNil(text.title)
        XCTAssertThrowsError(try db.editText(id: first.id, text: "\n", title: nil)) { XCTAssertEqual($0 as? HistoryEditError, .empty) }
        let image = try db.collectImage(HistoryImage(hash: "hash", filename: "a", thumbnailFilename: "b", byteCount: 1,
                                                   pixelWidth: 1, pixelHeight: 1, typeIdentifier: "public.png"), source: .manual, at: nil)
        XCTAssertThrowsError(try db.editText(id: image.id, text: "text", title: nil)) {
            XCTAssertEqual($0 as? HistoryEditError, .unsupportedKind)
        }
        try db.setTitle(" 画像名 ", id: image.id)
        XCTAssertEqual(try db.fetchAll().first { $0.id == image.id }?.title, "画像名")
    }

    func testTitleTrimsCapsCharactersAndStoresSQLNull() throws {
        let (db, url) = try fixture()
        let entry = try db.collect("本文", source: .manual)
        try db.setTitle(" \n名前\t", id: entry.id)
        XCTAssertEqual(try db.fetchAll().first?.title, "名前")
        try db.setTitle(String(repeating: "👨‍👩‍👧‍👦", count: 101), id: entry.id)
        XCTAssertEqual(try db.fetchAll().first?.title?.count, 100)
        for title in [" \n\t", nil] as [String?] {
            try db.setTitle(title, id: entry.id)
            XCTAssertNil(try db.fetchAll().first?.title)
            XCTAssertEqual(try ImageTestSupport.sql("SELECT title IS NULL FROM history WHERE id = \(entry.id)", at: url), 1)
        }
        try db.setTitle(String(repeating: "a", count: 99) + " b", id: entry.id)
        XCTAssertEqual(try db.fetchAll().first?.title, String(repeating: "a", count: 99))
    }

    func testPinAtIntegerMinimumRenumbersBeforeAddingAndDuplicateUsesBinaryText() throws {
        let (db, url) = try fixture()
        let first = try db.createWritten(text: "é", title: nil)
        try ImageTestSupport.sql("UPDATE history SET pin_order = -9223372036854775808 WHERE id = \(first.id)", at: url)
        let second = try db.createWritten(text: "e\u{301}", title: nil)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.pinOrder, -1)
        XCTAssertEqual(try db.fetchAll().first { $0.id == first.id }?.pinOrder, 0)
        let same = try db.createWritten(text: "é", title: "名前")
        XCTAssertEqual(same.id, first.id)
        XCTAssertEqual(same.pinOrder, 0)
        XCTAssertEqual(same.title, "名前")
    }

    func testReorderRecollectUnpinAndUndoKeepTemplateMetadata() throws {
        let (db, _) = try fixture()
        let a = try db.createWritten(text: "A", title: "甲")
        let b = try db.createWritten(text: "B", title: "乙")
        let c = try db.createWritten(text: "C", title: "丙")
        let unpinned = try db.collect("D", source: .manual)
        try db.reorderPins([b.id, b.id, unpinned.id, -1])
        XCTAssertEqual(HistoryEntry.orderedPins(try db.fetchAll().filter(\.isPinned)).map(\.id), [b.id, c.id, a.id])
        let before = try XCTUnwrap(db.fetchAll().first { $0.id == a.id })
        let collected = try db.collect(a.text, source: .automatic, at: Date().addingTimeInterval(100))
        XCTAssertEqual(collected.title, before.title)
        XCTAssertEqual(collected.pinOrder, before.pinOrder)
        let deletion = try XCTUnwrap(db.delete(id: a.id))
        XCTAssertTrue(try db.undo(deletion))
        XCTAssertEqual(try db.fetchAll().first { $0.id == a.id }, collected)
        let removed = try XCTUnwrap(db.togglePin(id: a.id))
        XCTAssertNil(removed.pinOrder)
        XCTAssertEqual(removed.title, a.title)
        let again = try XCTUnwrap(db.togglePin(id: a.id))
        XCTAssertEqual(HistoryEntry.orderedPins(try db.fetchAll().filter(\.isPinned)).first?.id, again.id)
        let deleted = try XCTUnwrap(db.delete(id: a.id))
        _ = try db.collect(a.text, source: .manual)
        XCTAssertTrue(try db.undo(deleted))
        let restored = try XCTUnwrap(db.fetchAll().first { $0.id == a.id })
        XCTAssertEqual(restored.title, again.title)
        XCTAssertEqual(restored.pinOrder, again.pinOrder)
    }

    private func entry(_ id: Int, order: Int?, title: String? = nil, pinned: Bool = true, kind: HistoryKind = .text) -> HistoryEntry {
        HistoryEntry(id: id, kind: kind, text: "本文\(id)", savedAt: Date(timeIntervalSince1970: 1),
                     lastCollectedAt: Date(timeIntervalSince1970: Double(id)), collectionCount: 1,
                     isPinned: pinned, source: .manual, title: title, pinOrder: order)
    }

    func testSectionsFilterSearchAndExactShortcutTitleRanking() {
        let values = [entry(5, order: nil, title: "署名を含む"), entry(4, order: 3),
                      entry(3, order: -2, title: " 署名 "), entry(2, order: nil),
                      entry(1, order: nil, title: "画像の名前", pinned: false, kind: .image)]
        let expected = [3, 4, 5, 2]
        XCTAssertEqual(EntrySections.make(values, separatesPinned: true, now: Date()).first?.entries.map(\.id), expected)
        XCTAssertEqual(HistoryFilter.entries(values, filter: .pinned, search: "").map(\.id), expected)
        XCTAssertEqual(HistoryFilter.entries(values, filter: .all, search: "").map(\.id), values.map(\.id))
        XCTAssertEqual(HistoryFilter.entries(values, filter: .images, search: "画像の名前").map(\.id), [1])
        XCTAssertEqual(ShortcutContent.matchingEntries(values, search: "署名").map(\.id), [3, 5])
        XCTAssertEqual(ShortcutContent.matchingEntries(values, filter: .pinned, search: "").map(\.id), expected)
        XCTAssertEqual(HistoryEntryEntity(entry: values[2]).displayTitle, "署名")
        XCTAssertNil(entry(0, order: nil, title: "\n ").displayTitle)
    }

    func testTemplateBackupRoundTripAndMergeOrderAreIdempotent() throws {
        let root = try ImageTestSupport.directory(self)
        let source = try HistoryDatabase(url: root.appendingPathComponent("source.sqlite"))
        let a = try source.createWritten(text: "A", title: "甲")
        _ = try source.createWritten(text: "B", title: "乙")
        let original = try source.fetchAll()
        let files = HistoryImageFiles(directory: root.appendingPathComponent("images"))
        let url = root.appendingPathComponent("backup.clipboardplus")
        _ = try HistoryBackup.write(entries: original, files: files, to: url, cancellation: BackupCancellation())
        let input = try FileHandle(forReadingFrom: url)
        _ = try input.read(upToCount: 8)
        let version = try HistoryBackup.readNumber(from: input)
        try input.close()
        XCTAssertEqual(version, 3)
        XCTAssertFalse((UInt64(1)...UInt64(2)).contains(version))
        let validated = try HistoryBackup.validate(at: url, temporaryRoot: root, cancellation: BackupCancellation())
        defer { validated.discard() }
        XCTAssertEqual(validated.entries, original)
        let target = try HistoryDatabase(url: root.appendingPathComponent("target.sqlite"))
        let local = try target.createWritten(text: a.text, title: "端末の名前")
        _ = try target.createWritten(text: "C", title: "端末のみ")
        _ = try target.mergeBackup(validated.entries) { _ in }
        let pins = HistoryEntry.orderedPins(try target.fetchAll())
        XCTAssertEqual(pins.map(\.text), ["C", "A", "B"])
        XCTAssertEqual(pins.first { $0.id == local.id }?.title, "端末の名前")
        XCTAssertEqual(pins.last?.title, "乙")
        let before = try target.fetchAll()
        _ = try target.mergeBackup(validated.entries) { _ in }
        XCTAssertEqual(try target.fetchAll(), before)
    }

    func testLegacyBackupFormatsWithoutOptionalKeysDecodeAndRestore() throws {
        let root = try ImageTestSupport.directory(self)
        for version in 1...2 {
            let json = Data("""
                {"formatVersion":\(version),"createdAt":1,"itemCount":1,"entries":[{"id":7,"kind":"text","text":"old","savedAt":1,"lastCollectedAt":2,"collectionCount":3,"isPinned":true,"source":"manual"}]}
                """.utf8)
            let manifest = try JSONDecoder().decode(BackupManifest.self, from: json)
            XCTAssertNil(manifest.entries.first?.title)
            XCTAssertNil(manifest.entries.first?.pinOrder)
            let url = root.appendingPathComponent("old-\(version).clipboardplus")
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let output = try FileHandle(forWritingTo: url)
            try output.write(contentsOf: HistoryBackup.magic)
            try HistoryBackup.writeNumber(UInt64(version), to: output)
            try HistoryBackup.writeNumber(UInt64(json.count), to: output)
            try output.write(contentsOf: json)
            try output.close()
            let backup = try HistoryBackup.validate(at: url, temporaryRoot: root, cancellation: BackupCancellation())
            defer { backup.discard() }
            let target = try HistoryDatabase(url: root.appendingPathComponent("target-\(version).sqlite"))
            _ = try target.mergeBackup(backup.entries) { _ in }
            XCTAssertEqual(try target.fetchAll().first?.pinOrder, 0)
            XCTAssertEqual(try target.fetchAll().first?.text, "old")
        }
    }

    func testFileBackupReadsFormatTwoAndPreservesTitleWhenRewritingAttachmentNames() throws {
        let root = try ImageTestSupport.directory(self)
        let files = HistoryImageFiles(directory: root.appendingPathComponent("attachments"))
        let file = try HistoryFileFiles(directory: files.directory).prepare(FileTestSupport.input(in: root))
        let database = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"))
        let entry = try database.collectFile(file, source: .manual, at: nil)
        let url = root.appendingPathComponent("file.clipboardplus")
        for version in [2, 3] {
            if version == 3 {
                try database.setTitle(" 資料 ", id: entry.id)
                try database.togglePin(id: entry.id)
            }
            _ = try HistoryBackup.write(entries: database.fetchAll(), files: files, to: url, cancellation: BackupCancellation())
            let input = try FileHandle(forReadingFrom: url)
            _ = try input.read(upToCount: 8)
            XCTAssertEqual(try HistoryBackup.readNumber(from: input), UInt64(version))
            try input.close()
            let backup = try HistoryBackup.validate(at: url, temporaryRoot: root, cancellation: BackupCancellation())
            defer { backup.discard() }
            let restored = try XCTUnwrap(backup.entries.first)
            XCTAssertEqual(restored.file?.hash, file.hash)
            XCTAssertNotEqual(restored.file?.filename, file.filename)
            XCTAssertEqual(restored.title, version == 3 ? "資料" : nil)
            XCTAssertEqual(restored.pinOrder, version == 3 ? 0 : nil)
        }
    }
}
