import AppIntents
import Foundation
import XCTest
@testable import ClipboardPlus

final class TemplateHistoryTests: XCTestCase {
    private func fixture() throws -> (HistoryDatabase, URL) {
        let url = try ImageTestSupport.directory(self).appendingPathComponent("history.sqlite")
        return (try HistoryDatabase(url: url), url)
    }

    private let versionFourSQL = """
        CREATE TABLE history (
            id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, text TEXT NOT NULL COLLATE BINARY,
            saved_at REAL NOT NULL, collected_at REAL NOT NULL, collection_count INTEGER NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL, deletion_id TEXT, delete_after REAL,
            image_hash TEXT, image_file TEXT, thumbnail_file TEXT, image_bytes INTEGER,
            pixel_width INTEGER, pixel_height INTEGER, image_type TEXT,
            file_hash TEXT, file_name TEXT, original_filename TEXT, file_bytes INTEGER, file_type TEXT,
            title TEXT, pin_order INTEGER
        );
        CREATE UNIQUE INDEX history_active_text ON history(text) WHERE deletion_id IS NULL AND kind NOT IN ('image', 'file');
        CREATE UNIQUE INDEX history_active_image ON history(image_hash) WHERE deletion_id IS NULL AND kind = 'image';
        CREATE UNIQUE INDEX history_active_file ON history(file_hash) WHERE deletion_id IS NULL AND kind = 'file';
        INSERT INTO history(id, kind, text, saved_at, collected_at, collection_count, pinned, source, title, pin_order, deletion_id, delete_after)
            VALUES (1, 'text', 'one', 1, 20, 1, 1, 'manual', '名前', 50, NULL, NULL),
                   (2, 'text', 'two', 1, 30, 2, 1, 'automatic', NULL, -5, NULL, NULL),
                   (3, 'text', 'three', 1, 40, 1, 1, 'written', NULL, 3, 'undo', 1005),
                   (4, 'text', 'four', 1, 50, 1, 0, 'capture', NULL, NULL, NULL, NULL),
                   (5, 'text', 'five', 1, 60, 1, 0, 'drag', NULL, NULL, 'history-undo', 1004);
        PRAGMA user_version = 4;
        """

    func testV4MigrationPreservesCurrentOrderTitlesAndPendingDeletionFlags() throws {
        let url = try ImageTestSupport.directory(self).appendingPathComponent("v4.sqlite")
        try ImageTestSupport.sql(versionFourSQL, at: url)
        let now = Date(timeIntervalSince1970: 1000)
        var db: HistoryDatabase? = try HistoryDatabase(url: url, now: { now })
        XCTAssertEqual(try db!.readSchemaVersion(), 5)
        XCTAssertEqual(HistoryEntry.orderedTemplates(try db!.fetchAll().filter(\.isTemplate)).map(\.id), [2, 1])
        XCTAssertEqual(try ImageTestSupport.sql("SELECT pin_order FROM history WHERE id = 3", at: url), 1)
        XCTAssertEqual(try ImageTestSupport.sql("SELECT COUNT(*) FROM history WHERE deletion_id IS NOT NULL", at: url), 2)
        XCTAssertEqual(try ImageTestSupport.sql("SELECT COUNT(*) FROM history WHERE tag IS NULL", at: url), 5)
        XCTAssertTrue(try db!.undo(HistoryDeletion(id: "undo", expiresAt: now.addingTimeInterval(5), count: 1)))
        XCTAssertTrue(try db!.undo(HistoryDeletion(id: "history-undo", expiresAt: now.addingTimeInterval(4), count: 1)))
        let values = try db!.fetchAll()
        XCTAssertEqual(HistoryEntry.orderedTemplates(values.filter(\.isTemplate)).map(\.id), [2, 3, 1])
        XCTAssertEqual(values.first { $0.id == 1 }?.title, "名前")
        XCTAssertEqual(values.first { $0.id == 3 }?.source, .written)
        XCTAssertEqual(values.first { $0.id == 5 }?.isTemplate, false)
        db = nil
        XCTAssertEqual(try HistoryDatabase(url: url, now: { now }).fetchAll(), values)
    }

    func testV5MigrationFailureRollsBackTagOrdersIndexesAndVersion() throws {
        let url = try ImageTestSupport.directory(self).appendingPathComponent("v4.sqlite")
        try ImageTestSupport.sql(versionFourSQL + "CREATE TRIGGER fail_update BEFORE UPDATE ON history BEGIN SELECT RAISE(ABORT, 'failure'); END;", at: url)
        XCTAssertThrowsError(try HistoryDatabase(url: url))
        XCTAssertEqual(try ImageTestSupport.sql("PRAGMA user_version", at: url), 4)
        XCTAssertEqual(try ImageTestSupport.sql("SELECT COUNT(*) FROM pragma_table_info('history') WHERE name = 'tag'", at: url), 0)
        XCTAssertEqual(try ImageTestSupport.sql("SELECT pin_order FROM history WHERE id = 1", at: url), 50)
        XCTAssertEqual(try ImageTestSupport.sql("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name LIKE 'history_active_%'", at: url), 3)
    }

    func testCreateAndCollectCoexistInBothDirectionsAndDuplicatesAreAtomic() throws {
        let (db, _) = try fixture()
        let history = try db.collect("同じ本文", source: .automatic)
        let template = try db.createTemplate(text: history.text, title: " 名前 ", tag: " 仕事\n")
        XCTAssertNotEqual(history.id, template.id)
        XCTAssertEqual(template.title, "名前")
        XCTAssertEqual(template.tag, "仕事")
        XCTAssertEqual(template.source, .written)
        XCTAssertEqual(template.templateOrder, 0)
        let other = try db.createTemplate(text: "https://example.com", title: nil)
        XCTAssertEqual(other.kind, .url)
        let collected = try db.collect(other.text, source: .automatic)
        XCTAssertFalse(collected.isTemplate)
        XCTAssertNotEqual(collected.id, other.id)
        let bumped = try db.collect(other.text, source: .drag)
        XCTAssertEqual(bumped.id, collected.id)
        XCTAssertEqual(bumped.collectionCount, 2)
        XCTAssertEqual(try db.fetchAll().first { $0.id == other.id }, other)
        let before = try db.fetchAll()
        XCTAssertThrowsError(try db.createTemplate(text: template.text, title: "変更しない", tag: "別")) {
            XCTAssertEqual($0 as? HistoryEditError, .duplicate)
        }
        XCTAssertThrowsError(try db.moveToTemplates(id: history.id)) { XCTAssertEqual($0 as? HistoryEditError, .duplicate) }
        XCTAssertThrowsError(try db.moveToTemplates(id: template.id)) { XCTAssertEqual($0 as? HistoryEditError, .duplicate) }
        XCTAssertEqual(try db.fetchAll(), before)
        XCTAssertThrowsError(try db.createTemplate(text: " \n\t", title: nil)) { XCTAssertEqual($0 as? HistoryEditError, .empty) }
    }

    func testMoveEveryKindAndCollectEqualAttachmentsWithoutChangingTemplate() throws {
        let (db, url) = try fixture()
        let image = HistoryImage(hash: "image-hash", filename: "a", thumbnailFilename: "b", byteCount: 10,
                                 pixelWidth: 1, pixelHeight: 1, typeIdentifier: "public.png")
        let file = HistoryFile(hash: "file-hash", filename: "c", originalFilename: "資料.pdf", byteCount: 10, typeIdentifier: "com.adobe.pdf")
        let histories = [try db.collect("本文", source: .manual),
                         try db.collectImage(image, source: .manual, at: nil),
                         try db.collectFile(file, source: .drag, at: nil)]
        for (offset, history) in histories.enumerated() {
            try ImageTestSupport.sql("UPDATE history SET title = '既存名' WHERE id = \(history.id)", at: url)
            let moved = try db.moveToTemplates(id: history.id)
            XCTAssertTrue(moved.isTemplate)
            XCTAssertNil(moved.tag)
            XCTAssertEqual(moved.templateOrder, offset)
            XCTAssertEqual(moved.title, "既存名")
            XCTAssertEqual(moved.savedAt, history.savedAt)
            XCTAssertEqual(moved.lastCollectedAt, history.lastCollectedAt)
            XCTAssertEqual(moved.collectionCount, history.collectionCount)
            XCTAssertEqual(moved.source, history.source)
            XCTAssertEqual(moved.image, history.image)
            XCTAssertEqual(moved.file, history.file)
        }
        let templates = try db.fetchAll()
        let imageHistory = try db.collectImage(image, source: .automatic, at: nil)
        let fileHistory = try db.collectFile(file, source: .automatic, at: nil)
        for history in [imageHistory, fileHistory] {
            XCTAssertFalse(history.isTemplate)
            XCTAssertThrowsError(try db.moveToTemplates(id: history.id)) { XCTAssertEqual($0 as? HistoryEditError, .duplicate) }
            let edited = try db.updateTemplate(id: histories.first { $0.kind == history.kind }!.id,
                                              text: nil, title: "新しい名", tag: "添付")
            XCTAssertEqual(edited.image, history.image)
            XCTAssertEqual(edited.file, history.file)
            XCTAssertThrowsError(try db.updateTemplate(id: edited.id, text: "変更", title: nil, tag: nil)) {
                XCTAssertEqual($0 as? HistoryEditError, .unsupportedKind)
            }
        }
        XCTAssertEqual(try db.fetchAll().filter(\.isTemplate).count, templates.count)
        XCTAssertEqual(try db.fetchAll().filter { !$0.isTemplate }.count, 2)
    }

    func testUpdatePreservesIdentityReclassifiesAndAppendsToNewGroup() throws {
        let (db, _) = try fixture()
        let a = try db.createTemplate(text: "A", title: "名前", tag: "A")
        let b = try db.createTemplate(text: "B", title: nil, tag: "B")
        let c = try db.createTemplate(text: "C", title: nil, tag: "B")
        let history = try db.collect("https://example.com", source: .automatic)
        XCTAssertThrowsError(try db.updateTemplate(id: history.id, text: nil, title: nil, tag: nil)) {
            XCTAssertEqual($0 as? HistoryEditError, .unsupportedKind)
        }
        let before = try db.fetchAll()
        XCTAssertThrowsError(try db.updateTemplate(id: a.id, text: b.text, title: nil, tag: "B")) {
            XCTAssertEqual($0 as? HistoryEditError, .duplicate)
        }
        XCTAssertThrowsError(try db.updateTemplate(id: a.id, text: "\n", title: nil, tag: nil)) {
            XCTAssertEqual($0 as? HistoryEditError, .empty)
        }
        XCTAssertEqual(try db.fetchAll(), before)
        let edited = try db.updateTemplate(id: a.id, text: history.text, title: nil, tag: " B ")
        XCTAssertEqual(edited.kind, .url)
        XCTAssertEqual(edited.id, a.id)
        XCTAssertEqual(edited.savedAt, a.savedAt)
        XCTAssertEqual(edited.lastCollectedAt, a.lastCollectedAt)
        XCTAssertEqual(edited.collectionCount, a.collectionCount)
        XCTAssertNil(edited.title)
        XCTAssertEqual(edited.templateOrder, 2)
        XCTAssertEqual(TemplateGroups.make(try db.fetchAll(), search: "").first?.entries.map(\.id), [b.id, c.id, a.id])
        let unchanged = try db.updateTemplate(id: a.id, text: nil, title: "リンク", tag: "B")
        XCTAssertEqual(unchanged.text, edited.text)
        XCTAssertEqual(unchanged.templateOrder, edited.templateOrder)
        let textAgain = try db.updateTemplate(id: a.id, text: "文章", title: nil, tag: nil)
        XCTAssertEqual(textAgain.kind, .text)
        XCTAssertNil(textAgain.tag)
    }

    func testNormalizationSQLNullBinaryDuplicatesAndOrderOverflow() throws {
        let (db, url) = try fixture()
        XCTAssertNil(HistoryEntry.normalizedTag(" \n\t"))
        XCTAssertEqual(HistoryEntry.normalizedTag(String(repeating: "👨‍👩‍👧‍👦", count: 31))?.count, 30)
        let a = try db.createTemplate(text: "é", title: String(repeating: "名", count: 101), tag: " 仕事 ")
        XCTAssertEqual(a.title?.count, 100)
        try ImageTestSupport.sql("UPDATE history SET pin_order = 9223372036854775807 WHERE id = \(a.id)", at: url)
        let b = try db.createTemplate(text: "e\u{301}", title: nil, tag: "仕事")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(b.templateOrder, 1)
        XCTAssertEqual(try db.fetchAll().first { $0.id == a.id }?.templateOrder, 0)
        _ = try db.updateTemplate(id: a.id, text: nil, title: " \n", tag: " \t")
        XCTAssertEqual(try ImageTestSupport.sql("SELECT title IS NULL AND tag IS NULL FROM history WHERE id = \(a.id)", at: url), 1)
        XCTAssertEqual(HistoryEntry.normalizedTitle(String(repeating: "a", count: 99) + " b"), String(repeating: "a", count: 99))
    }

    func testReorderTouchesOnlySuppliedGroupAndRenameAppendsInCurrentOrder() throws {
        let (db, _) = try fixture()
        let a = try db.createTemplate(text: "A", title: nil, tag: "元")
        let b = try db.createTemplate(text: "B", title: nil, tag: "元")
        let c = try db.createTemplate(text: "C", title: nil, tag: "先")
        let d = try db.createTemplate(text: "D", title: nil)
        try db.reorderTemplates([b.id, a.id])
        XCTAssertEqual(try db.fetchAll().first { $0.id == c.id }, c)
        XCTAssertEqual(try db.fetchAll().first { $0.id == d.id }, d)
        try db.renameTag(" 元 ", to: " 先 ")
        let groups = TemplateGroups.make(try db.fetchAll(), search: "")
        XCTAssertEqual(groups.first { $0.tag == "先" }?.entries.map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(groups.last?.entries, [d])
        let before = try db.fetchAll()
        try db.renameTag("先", to: "先\n")
        XCTAssertEqual(try db.fetchAll(), before)
        try db.renameTag(nil, to: "先")
        XCTAssertEqual(TemplateGroups.make(try db.fetchAll(), search: "").first?.entries.map(\.id), [c.id, b.id, a.id, d.id])
        let snapshot = try db.fetchAll()
        try db.reorderTemplates([a.id])
        XCTAssertEqual(try db.fetchAll().filter { $0.id != a.id }, snapshot.filter { $0.id != a.id })
    }

    /// A search can hide part of a group. Reordering the rest leaves the hidden rows in place.
    func testReorderKeepsRowsTheCallerLeftOut() throws {
        let (db, _) = try fixture()
        let c = try db.createTemplate(text: "C", title: nil, tag: "組")
        let a = try db.createTemplate(text: "A", title: nil, tag: "組")
        let b = try db.createTemplate(text: "B", title: nil, tag: "組")
        func group() throws -> [HistoryEntry] { TemplateGroups.make(try db.fetchAll(), search: "").first?.entries ?? [] }
        try db.reorderTemplates([a.id, b.id])
        XCTAssertEqual(try group().map(\.id), [c.id, a.id, b.id])
        try db.reorderTemplates([b.id, a.id])
        XCTAssertEqual(try group().map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(try group().map(\.templateOrder), [0, 1, 2])
    }

    private func entry(_ id: Int, tag: String? = nil, order: Int? = nil, title: String? = nil,
                       template: Bool = true, kind: HistoryKind = .text, file: HistoryFile? = nil) -> HistoryEntry {
        HistoryEntry(id: id, kind: kind, text: kind == .text ? "本文\(id)" : "", savedAt: Date(timeIntervalSince1970: 1),
                     lastCollectedAt: Date(timeIntervalSince1970: Double(id)), collectionCount: 1,
                     isTemplate: template, source: .manual, file: file, title: title, templateOrder: order, tag: tag)
    }

    func testGroupsOrderSearchAndHistoryExclusion() {
        let file = HistoryFile(hash: "hash", filename: "stored", originalFilename: "Report.pdf", byteCount: 1, typeIdentifier: "com.adobe.pdf")
        let values = [entry(6, title: "その他の名前"), entry(5, tag: "Tag10", order: 0),
                      entry(4, tag: "Tag2", title: "名前"), entry(3, tag: "Tag2", order: 0),
                      entry(2, tag: "Tag2", order: 0, kind: .file, file: file), entry(1, template: false)]
        let groups = TemplateGroups.make(values, search: "")
        XCTAssertEqual(groups.map(\.title), ["Tag2", "Tag10", "その他"])
        XCTAssertEqual(groups.map { $0.entries.map(\.id) }, [[2, 3, 4], [5], [6]])
        XCTAssertEqual(groups.last?.id, "")
        XCTAssertEqual(TemplateGroups.tags(values), ["Tag2", "Tag10"])
        XCTAssertEqual(TemplateGroups.make(values, search: " tag2 \n").first?.entries.map(\.id), [2, 3, 4])
        XCTAssertEqual(TemplateGroups.make(values, search: "REPORT").first?.entries.map(\.id), [2])
        XCTAssertEqual(TemplateGroups.make(values, search: "本文3").first?.entries.map(\.id), [3])
        XCTAssertEqual(TemplateGroups.make(values, search: "その他の名前").first?.entries.map(\.id), [6])
        XCTAssertTrue(TemplateGroups.make(values, search: "missing").isEmpty)
        XCTAssertEqual(HistoryFilter.history(values, search: "").map(\.id), [1])
        XCTAssertEqual(HistoryFilter.history([values[5], entry(7, template: false)], search: "本文").map(\.id), [1, 7])
        XCTAssertEqual(EntrySections.make(values, now: Date(timeIntervalSince1970: 100)).flatMap(\.entries).map(\.id), [1])
    }

    func testTemplateUndoNeverMergesWithEqualHistoryAndClearKeepsTemplates() throws {
        let (db, _) = try fixture()
        let template = try db.createTemplate(text: "同じ", title: "名前", tag: "仕事")
        let deletion = try XCTUnwrap(db.delete(id: template.id))
        let history = try db.collect(template.text, source: .automatic)
        XCTAssertTrue(try db.undo(deletion))
        XCTAssertEqual(try db.fetchAll().first { $0.id == template.id }, template)
        let clear = try XCTUnwrap(db.deleteAll())
        XCTAssertEqual(clear.count, 1)
        XCTAssertEqual(try db.fetchAll(), [template])
        XCTAssertTrue(try db.undo(clear))
        XCTAssertEqual(try db.fetchAll().first { $0.id == history.id }, history)
        let secondDelete = try XCTUnwrap(db.delete(id: template.id))
        _ = try db.createTemplate(text: template.text, title: nil)
        XCTAssertTrue(try db.undo(secondDelete))
        XCTAssertEqual(try db.fetchAll().filter(\.isTemplate).count, 1)
        XCTAssertEqual(try db.fetchAll().first { $0.id == template.id }?.tag, template.tag)
    }

    func testTemplatesSurviveRetentionCountAndAttachmentBudgetIncludingRestore() throws {
        let root = try ImageTestSupport.directory(self)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let db = try HistoryDatabase(url: root.appendingPathComponent("db"), now: { now }, historyLimit: 1, imageByteLimit: 10)
        let image = HistoryImage(hash: "image", filename: "a", thumbnailFilename: "b", byteCount: 10,
                                 pixelWidth: 1, pixelHeight: 1, typeIdentifier: "public.png")
        let file = HistoryFile(hash: "file", filename: "c", originalFilename: "data.pdf", byteCount: 10, typeIdentifier: "com.adobe.pdf")
        let imageRow = try db.collectImage(image, source: .manual, at: Date(timeIntervalSince1970: 1))
        let imageTemplate = try db.moveToTemplates(id: imageRow.id)
        let fileRow = try db.collectFile(file, source: .manual, at: Date(timeIntervalSince1970: 2))
        let fileTemplate = try db.moveToTemplates(id: fileRow.id)
        for index in 0..<3 { try db.collect("history\(index)", source: .manual) }
        XCTAssertEqual(try db.fetchAll().filter(\.isTemplate).count, 2)
        XCTAssertEqual(try db.purgeHistory(olderThan: .oneDay), 0)
        XCTAssertTrue(db.takeRemovals().allSatisfy { !$0.isTemplate })
        let restored = try HistoryDatabase(url: root.appendingPathComponent("restore"), historyLimit: 0, imageByteLimit: 0)
        _ = try restored.mergeBackup([imageTemplate, fileTemplate], retentionCutoff: now) { _ in }
        XCTAssertEqual(try restored.fetchAll().count, 2)
        XCTAssertTrue(try restored.fetchAll().allSatisfy(\.isTemplate))
    }

    func testBackupRoundTripSeparatesDomainsAndKeepsDeviceMetadataAndGroupOrder() throws {
        let root = try ImageTestSupport.directory(self)
        let source = try HistoryDatabase(url: root.appendingPathComponent("source.sqlite"))
        let a = try source.createTemplate(text: "A", title: "受信名", tag: "受信タグ")
        _ = try source.createTemplate(text: "B", title: "B名", tag: "端末タグ")
        _ = try source.collect(a.text, source: .automatic)
        let original = try source.fetchAll()
        let files = HistoryImageFiles(directory: root.appendingPathComponent("images"))
        let url = root.appendingPathComponent("backup.clipboardplus")
        _ = try HistoryBackup.write(entries: original, files: files, to: url, cancellation: BackupCancellation())
        let input = try FileHandle(forReadingFrom: url)
        _ = try input.read(upToCount: 8)
        let version = try HistoryBackup.readNumber(from: input)
        try input.close()
        XCTAssertEqual(version, 4)
        XCTAssertFalse((UInt64(1)...UInt64(3)).contains(version))
        let backup = try HistoryBackup.validate(at: url, temporaryRoot: root, cancellation: BackupCancellation())
        defer { backup.discard() }
        XCTAssertEqual(backup.entries, original)
        let target = try HistoryDatabase(url: root.appendingPathComponent("target.sqlite"))
        let local = try target.createTemplate(text: "A", title: "端末名", tag: "端末タグ")
        _ = try target.createTemplate(text: "C", title: nil, tag: "端末タグ")
        _ = try target.mergeBackup(backup.entries) { _ in }
        let values = try target.fetchAll()
        let kept = try XCTUnwrap(values.first { $0.id == local.id })
        XCTAssertEqual(kept.title, "端末名")
        XCTAssertEqual(kept.tag, "端末タグ")
        XCTAssertEqual(TemplateGroups.make(values, search: "").first?.entries.map(\.text), ["A", "C", "B"])
        XCTAssertEqual(values.filter { $0.text == "A" }.count, 2)
        _ = try target.mergeBackup(backup.entries) { _ in }
        XCTAssertEqual(try target.fetchAll(), values)
        let empty = try HistoryDatabase(url: root.appendingPathComponent("empty.sqlite"))
        _ = try empty.createTemplate(text: "A", title: nil)
        _ = try empty.mergeBackup(backup.entries) { _ in }
        XCTAssertEqual(try empty.fetchAll().first { $0.isTemplate && $0.text == "A" }?.tag, a.tag)
        XCTAssertEqual(try empty.fetchAll().first { $0.isTemplate && $0.text == "A" }?.title, a.title)
    }

    func testAttachmentBackupPreservesTemplateMetadataAndEqualHistoryRows() throws {
        let root = try ImageTestSupport.directory(self)
        let files = HistoryImageFiles(directory: root.appendingPathComponent("attachments"))
        let image = try ImageTestSupport.prepare(files)
        let file = try HistoryFileFiles(directory: files.directory).prepare(FileTestSupport.input(in: root))
        let source = try HistoryDatabase(url: root.appendingPathComponent("source.sqlite"))
        let imageRow = try source.collectImage(image, source: .manual, at: nil)
        let fileRow = try source.collectFile(file, source: .manual, at: nil)
        for row in [imageRow, fileRow] {
            try source.moveToTemplates(id: row.id)
            _ = try source.updateTemplate(id: row.id, text: nil, title: "添付の名前", tag: "添付タグ")
        }
        try source.collectImage(image, source: .automatic, at: nil)
        try source.collectFile(file, source: .automatic, at: nil)
        let before = try source.fetchAll()
        let archive = root.appendingPathComponent("attachments.clipboardplus")
        _ = try HistoryBackup.write(entries: before, files: files, to: archive, cancellation: BackupCancellation())
        let backup = try HistoryBackup.validate(at: archive, temporaryRoot: root, cancellation: BackupCancellation())
        XCTAssertEqual(backup.entries.count, 4)
        for old in before {
            let entry = try XCTUnwrap(backup.entries.first { $0.id == old.id })
            XCTAssertEqual(entry.title, old.title)
            XCTAssertEqual(entry.tag, old.tag)
            XCTAssertEqual(entry.templateOrder, old.templateOrder)
            XCTAssertEqual(entry.isTemplate, old.isTemplate)
            XCTAssertEqual(entry.image?.hash, old.image?.hash)
            XCTAssertEqual(entry.file?.hash, old.file?.hash)
            XCTAssertTrue(entry.attachmentFilenames.isDisjoint(with: old.attachmentFilenames))
        }
        let target = try HistoryDatabase(url: root.appendingPathComponent("target.sqlite"))
        let restoredFiles = HistoryImageFiles(directory: root.appendingPathComponent("restored"))
        _ = try HistoryRestore.apply(backup, database: target, files: restoredFiles, cancellation: BackupCancellation())
        let restored = try target.fetchAll()
        XCTAssertEqual(restored.filter(\.isTemplate).count, 2)
        XCTAssertEqual(restored.filter { !$0.isTemplate }.count, 2)
        XCTAssertEqual(TemplateGroups.make(restored, search: "添付タグ").first?.entries.map(\.kind), [.image, .file])
        for entry in restored {
            if let image = entry.image { XCTAssertEqual(try restoredFiles.read(image), try files.read(imageRow.image!)) }
            if let file = entry.file {
                XCTAssertEqual(try Data(contentsOf: restoredFiles.url(for: file.filename)), FileTestSupport.bytes)
            }
        }
    }

    func testLegacyFormatsAndJSONDecodePinsIntoOtherTemplates() throws {
        let root = try ImageTestSupport.directory(self)
        for version in 1...3 {
            let json = Data("""
                {"formatVersion":\(version),"createdAt":1,"itemCount":2,"entries":[
                {"id":7,"kind":"text","text":"old","savedAt":1,"lastCollectedAt":2,"collectionCount":3,"isPinned":true,"pinOrder":9,"title":"旧名","source":"manual"},
                {"id":8,"kind":"text","text":"first","savedAt":1,"lastCollectedAt":2,"collectionCount":1,"isPinned":true,"pinOrder":-2,"source":"automatic"}]}
                """.utf8)
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
            XCTAssertTrue(backup.entries.allSatisfy { $0.isTemplate && $0.tag == nil })
            let target = try HistoryDatabase(url: root.appendingPathComponent("target-\(version).sqlite"))
            _ = try target.mergeBackup(backup.entries) { _ in }
            let templates = HistoryEntry.orderedTemplates(try target.fetchAll())
            XCTAssertEqual(templates.map(\.text), ["first", "old"])
            XCTAssertEqual(templates.compactMap(\.templateOrder), [0, 1])
            XCTAssertEqual(templates.last?.title, "旧名")
        }
        let legacy = Data(#"{"id":1,"kind":"text","text":"legacy","savedAt":1,"lastCollectedAt":2,"collectionCount":1,"isPinned":true,"source":"manual"}"#.utf8)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: legacy)
        XCTAssertTrue(decoded.isTemplate)
        XCTAssertNil(decoded.templateOrder)
        XCTAssertNil(decoded.tag)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertEqual(encoded["isTemplate"] as? Bool, true)
        XCTAssertNil(encoded["isPinned"])
        XCTAssertNil(encoded["pinOrder"])
    }
}
