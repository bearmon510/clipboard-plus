import Foundation
import ImageIO
import SQLite3
import UIKit
import XCTest
@testable import ClipboardPlus

enum ImageTestSupport {
    static func directory(_ test: XCTestCase) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    static func png(_ color: UIColor = .red, size: CGSize = CGSize(width: 8, height: 6)) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    static func prepare(_ files: HistoryImageFiles, color: UIColor = .red) throws -> HistoryImage {
        let data = png(color)
        return try files.prepare(data, typeIdentifier: "public.png", hash: HistoryImageFiles.hash(data))
    }

    @discardableResult
    static func sql(_ sql: String, at url: URL) throws -> Int {
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK else {
            sqlite3_close(connection)
            throw HistoryDatabaseError.invalidRow
        }
        defer { sqlite3_close(connection) }
        // exec supports the complete v1 schema supplied by the test.
        if sql.contains(";") {
            guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw HistoryDatabaseError.invalidRow }
            return 0
        }
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

    static let versionOneSQL = """
        CREATE TABLE history (
            id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, text TEXT NOT NULL COLLATE BINARY,
            saved_at REAL NOT NULL, collected_at REAL NOT NULL, collection_count INTEGER NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL, deletion_id TEXT, delete_after REAL
        );
        CREATE UNIQUE INDEX history_active_text ON history(text) WHERE deletion_id IS NULL;
        CREATE INDEX history_order ON history(collected_at DESC, id DESC);
        INSERT INTO history VALUES (7, 'url', 'https://example.com', 100, 101, 4, 1, 'manual', NULL, NULL);
        INSERT INTO history VALUES (8, 'text', 'undo', 102, 103, 2, 0, 'drag', 'pending', 1005);
        PRAGMA user_version = 1;
        """
}

final class ImageHistoryTests: XCTestCase {
    func testVersionOneMigrationPreservesRowsPinsCountsAndUndo() throws {
        let directory = try ImageTestSupport.directory(self)
        let url = directory.appendingPathComponent("history.sqlite")
        try ImageTestSupport.sql(ImageTestSupport.versionOneSQL, at: url)
        let database = try HistoryDatabase(url: url, now: { Date(timeIntervalSince1970: 1000) })
        XCTAssertEqual(try database.readSchemaVersion(), 2)
        let row = try XCTUnwrap(database.fetchAll().first)
        XCTAssertEqual(row.id, 7)
        XCTAssertEqual(row.text, "https://example.com")
        XCTAssertEqual(row.kind, .url)
        XCTAssertTrue(row.isPinned)
        XCTAssertEqual(row.collectionCount, 4)
        XCTAssertEqual(row.savedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(row.lastCollectedAt, Date(timeIntervalSince1970: 101))
        XCTAssertEqual(row.source, .manual)
        XCTAssertNil(row.image)
        let deletion = try XCTUnwrap(database.latestDeletion())
        XCTAssertTrue(try database.undo(deletion))
        XCTAssertEqual(try database.fetchAll().map(\.id), [8, 7])
        XCTAssertEqual(try database.fetchAll().first?.collectionCount, 2)
        let reopened = try HistoryDatabase(url: url)
        XCTAssertEqual(try reopened.fetchAll(), try database.fetchAll())
    }

    func testFailedMigrationRollsBackColumnsIndexAndVersion() throws {
        let url = try ImageTestSupport.directory(self).appendingPathComponent("history.sqlite")
        try ImageTestSupport.sql(ImageTestSupport.versionOneSQL + "CREATE INDEX history_active_image ON history(text);", at: url)
        XCTAssertThrowsError(try HistoryDatabase(url: url))
        XCTAssertEqual(try ImageTestSupport.sql("PRAGMA user_version", at: url), 1)
        XCTAssertEqual(try ImageTestSupport.sql("SELECT COUNT(*) FROM pragma_table_info('history') WHERE name = 'image_hash'", at: url), 0)
        XCTAssertEqual(try ImageTestSupport.sql("SELECT COUNT(*) FROM history", at: url), 2)
        XCTAssertEqual(try ImageTestSupport.sql("SELECT COUNT(*) FROM sqlite_master WHERE name = 'history_active_text'", at: url), 1)
    }

    func testIdenticalImageMergesAndDifferentImagesDoNotCollideWithEmptyText() throws {
        let directory = try ImageTestSupport.directory(self)
        let files = HistoryImageFiles(directory: directory.appendingPathComponent("images"))
        let database = try HistoryDatabase(url: directory.appendingPathComponent("history.sqlite"))
        let red = try ImageTestSupport.prepare(files)
        let blue = try ImageTestSupport.prepare(files, color: .blue)
        let date = Date(timeIntervalSince1970: 100)
        let first = try database.collectImage(red, source: .manual, at: date)
        try database.togglePin(id: first.id)
        let second = try database.collectImage(blue, source: .drag, at: date.addingTimeInterval(1))
        let duplicate = try database.collectImage(red, source: .automatic, at: date.addingTimeInterval(2))
        let empty = try database.collect("", source: .automatic, at: date.addingTimeInterval(3))
        XCTAssertEqual(duplicate.id, first.id)
        XCTAssertEqual(duplicate.savedAt, date)
        XCTAssertEqual(duplicate.lastCollectedAt, date.addingTimeInterval(2))
        XCTAssertTrue(duplicate.isPinned)
        XCTAssertEqual(duplicate.collectionCount, 2)
        XCTAssertEqual(try database.fetchAll().map(\.id), [empty.id, first.id, second.id])
    }

    func testImageByteLimitRemovesOldestAndKeepsPins() throws {
        let directory = try ImageTestSupport.directory(self)
        let files = HistoryImageFiles(directory: directory.appendingPathComponent("images"))
        let red = try ImageTestSupport.prepare(files)
        let blue = try ImageTestSupport.prepare(files, color: .blue)
        let green = try ImageTestSupport.prepare(files, color: .green)
        let database = try HistoryDatabase(url: directory.appendingPathComponent("history.sqlite"), imageByteLimit: max(red.byteCount, max(blue.byteCount, green.byteCount)))
        let first = try database.collectImage(red, source: .manual, at: Date(timeIntervalSince1970: 1))
        try database.togglePin(id: first.id)
        let second = try database.collectImage(blue, source: .manual, at: Date(timeIntervalSince1970: 2))
        let third = try database.collectImage(green, source: .manual, at: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(try database.fetchAll().map(\.id), [third.id, first.id])
        let removed = database.takeRemovals()
        XCTAssertEqual(removed.map(\.id), [second.id])
        XCTAssertEqual(removed.first?.image?.filenames, blue.filenames)
        try database.togglePin(id: first.id)
        XCTAssertEqual(try database.fetchAll().map(\.id), [third.id])
    }

    func testCombinedCountLimitAndUndoMergeByHash() throws {
        let directory = try ImageTestSupport.directory(self)
        let files = HistoryImageFiles(directory: directory.appendingPathComponent("images"))
        let database = try HistoryDatabase(url: directory.appendingPathComponent("history.sqlite"), unpinnedLimit: 2)
        let first = try database.collectImage(ImageTestSupport.prepare(files), source: .manual, at: Date(timeIntervalSince1970: 1))
        try database.togglePin(id: first.id)
        let deletion = try XCTUnwrap(database.delete(id: first.id))
        let newer = try database.collectImage(ImageTestSupport.prepare(files), source: .drag, at: Date(timeIntervalSince1970: 2))
        XCTAssertTrue(try database.undo(deletion))
        let restored = try XCTUnwrap(database.fetchAll().first)
        XCTAssertEqual(restored.id, first.id)
        XCTAssertEqual(restored.image, first.image)
        XCTAssertEqual(restored.collectionCount, 2)
        XCTAssertEqual(restored.source, .drag)
        XCTAssertTrue(restored.isPinned)
        XCTAssertEqual(database.takeRemovals().first?.image, newer.image)
        try database.collect("text", source: .manual, at: Date(timeIntervalSince1970: 3))
        let blue = try database.collectImage(ImageTestSupport.prepare(files, color: .blue), source: .manual, at: Date(timeIntervalSince1970: 4))
        let newest = try database.collect("newest", source: .manual, at: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(try database.fetchAll().map(\.id), [newest.id, blue.id, first.id])
    }

    func testThumbnailIsJPEGAtMost480PixelsAndOriginalIsUnchanged() throws {
        let directory = try ImageTestSupport.directory(self)
        let files = HistoryImageFiles(directory: directory)
        let data = ImageTestSupport.png(size: CGSize(width: 1400, height: 700))
        let metadata = try files.prepare(data, typeIdentifier: "public.png", hash: HistoryImageFiles.hash(data))
        XCTAssertEqual(try files.read(metadata), data)
        XCTAssertEqual(metadata.pixelWidth, 1400)
        XCTAssertEqual(metadata.pixelHeight, 700)
        XCTAssertEqual(metadata.byteCount, data.count)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(files.url(for: metadata.thumbnailFilename) as CFURL, nil))
        XCTAssertEqual(try XCTUnwrap(CGImageSourceGetType(source)) as String, "public.jpeg")
        let thumbnail = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 480)
        XCTAssertEqual(thumbnail.width, thumbnail.height * 2)
    }

    func testInvalidAndOversizedDataAreRejectedWithoutFiles() throws {
        let directory = try ImageTestSupport.directory(self)
        let files = HistoryImageFiles(directory: directory)
        let invalid = Data("not an image".utf8)
        XCTAssertThrowsError(try files.prepare(invalid, typeIdentifier: "public.png", hash: HistoryImageFiles.hash(invalid)))
        var oversized = ImageTestSupport.png()
        oversized.append(Data(count: HistoryImageFiles.maximumByteCount + 1 - oversized.count))
        XCTAssertThrowsError(try HistoryImageFiles.hash(oversized))
        XCTAssertThrowsError(try files.prepare(oversized, typeIdentifier: "public.png", hash: "unused"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testVersionTwoExportContainsImageMetadataAndNoImagePayload() throws {
        let directory = try ImageTestSupport.directory(self)
        let files = HistoryImageFiles(directory: directory.appendingPathComponent("images"))
        let database = try HistoryDatabase(url: directory.appendingPathComponent("history.sqlite"))
        let metadata = try ImageTestSupport.prepare(files)
        let entry = try database.collectImage(metadata, source: .manual, at: Date(timeIntervalSince1970: 100))
        try database.togglePin(id: entry.id)
        let data = try HistoryExport.data(entries: database.fetchAll(), exportedAt: Date())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["formatVersion"] as? Int, 2)
        let row = try XCTUnwrap((root["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["kind"] as? String, "image")
        XCTAssertEqual(row["collectionCount"] as? Int, 1)
        XCTAssertEqual(row["isPinned"] as? Bool, true)
        let image = try XCTUnwrap(row["image"] as? [String: Any])
        XCTAssertEqual(Set(image.keys), Set(["hash", "filename", "thumbnailFilename", "byteCount", "pixelWidth", "pixelHeight", "typeIdentifier"]))
        XCTAssertEqual(image["hash"] as? String, metadata.hash)
        XCTAssertEqual(image["byteCount"] as? Int, metadata.byteCount)
        XCTAssertEqual(image["pixelWidth"] as? Int, metadata.pixelWidth)
        XCTAssertEqual(image["pixelHeight"] as? Int, metadata.pixelHeight)
        XCTAssertEqual(image["typeIdentifier"] as? String, "public.png")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(try files.read(metadata).base64EncodedString()))
    }

    func testImageFiltersExcludeImagesWhenSearching() throws {
        let directory = try ImageTestSupport.directory(self)
        let database = try HistoryDatabase(url: directory.appendingPathComponent("history.sqlite"))
        let image = try database.collectImage(ImageTestSupport.prepare(HistoryImageFiles(directory: directory.appendingPathComponent("images"))), source: .manual, at: nil)
        try database.togglePin(id: image.id)
        let text = try database.collect("Needle", source: .manual)
        let entries = try database.fetchAll()
        XCTAssertEqual(HistoryFilter.entries(entries, filter: .images, search: "").map(\.id), [image.id])
        XCTAssertEqual(HistoryFilter.entries(entries, filter: .pinned, search: "").map(\.id), [image.id])
        XCTAssertEqual(HistoryFilter.entries(entries, filter: .all, search: "needle").map(\.id), [text.id])
        XCTAssertTrue(HistoryFilter.entries(entries, filter: .images, search: "needle").isEmpty)
    }

    func testFailedLimitDeletionRollsBackInsertedRowAndRemovalJournal() throws {
        let directory = try ImageTestSupport.directory(self)
        let url = directory.appendingPathComponent("history.sqlite")
        let files = HistoryImageFiles(directory: directory.appendingPathComponent("images"))
        let database = try HistoryDatabase(url: url, unpinnedLimit: 1)
        let original = try database.collectImage(ImageTestSupport.prepare(files), source: .manual, at: Date(timeIntervalSince1970: 1))
        try ImageTestSupport.sql("CREATE TRIGGER fail_delete BEFORE DELETE ON history BEGIN SELECT RAISE(ABORT, 'test failure'); END;", at: url)
        XCTAssertThrowsError(try database.collect("new", source: .manual, at: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(try database.fetchAll(), [original])
        XCTAssertTrue(database.takeRemovals().isEmpty)
        XCTAssertEqual(try database.referencedImageFiles(), original.image?.filenames)
    }
}
