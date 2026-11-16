import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import ClipboardPlus

enum FileTestSupport {
    static let bytes = Data("%PDF-1.7\nfile history fixture\n%%EOF".utf8)

    static func input(in root: URL, bytes: Data = FileTestSupport.bytes, name: String? = "資料.pdf",
                      type: String = "com.adobe.pdf") throws -> HistoryFileInput {
        let source = root.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        return try HistoryFileFiles.stage(source, typeIdentifier: type, suggestedName: name)
    }

    static func entry(_ file: HistoryFile, id: Int = 1, at date: Date = Date(timeIntervalSince1970: 100)) -> HistoryEntry {
        HistoryEntry(id: id, kind: .file, text: "", savedAt: date, lastCollectedAt: date,
                     collectionCount: 1, isPinned: false, source: .manual, file: file)
    }
}

final class FileHistoryTests: XCTestCase {
    func testTypeSelectionRejectsTextURLImagesDynamicAndInternalTypes() {
        for type in ["com.adobe.pdf", "public.zip-archive", "public.mpeg-4", "com.apple.quicktime-movie"] {
            XCTAssertEqual(HistoryFileTypes.preferred(in: [type]), type)
        }
        for type in ["public.rtf", "public.html", "public.utf8-plain-text", "com.apple.flat-rtfd",
                     "com.apple.rtfd", "public.url", "public.file-url", "public.png", "public.jpeg",
                     "dyn.ah62d4rv4gk81g7d3ru", "com.apple.uikit.attributedstring", "com.apple.private.test",
                     "public.directory", "example.clipboardplus.backup"] {
            XCTAssertFalse(HistoryFileTypes.isFile(type), type)
            XCTAssertNil(HistoryFileTypes.preferred(in: [type]), type)
        }
        XCTAssertEqual(HistoryFileTypes.preferred(in: ["com.apple.uikit.attributedstring", "public.zip-archive", "com.adobe.pdf"]), "public.zip-archive")
        for type in ["public.rtf", "public.html", "com.apple.flat-rtfd", "public.url", "public.png"] {
            XCTAssertNil(HistoryFileTypes.preferred(in: ["com.adobe.pdf", type]), type)
        }
        XCTAssertNil(HistoryFileTypes.preferred(in: ["com.adobe.pdf", "org.nspasteboard.ConcealedType"]))
        XCTAssertEqual(HistoryFileTypes.preferred(in: ["public.file-url", "com.adobe.pdf"]), "com.adobe.pdf")
    }

    func testNamedTextFilesStayFilesButEditorTextAndLinksDoNot() throws {
        XCTAssertEqual(HistoryFileTypes.namedTextFile(types: ["public.plain-text"], suggestedName: "メモ.txt"), "public.plain-text")
        XCTAssertEqual(HistoryFileTypes.namedTextFile(types: ["public.utf8-plain-text", "public.comma-separated-values-text"],
                                                      suggestedName: "表.csv"), "public.comma-separated-values-text")
        XCTAssertEqual(HistoryFileTypes.namedTextFile(types: ["public.html"], suggestedName: "page.html"), "public.html")
        XCTAssertEqual(HistoryFileTypes.namedTextFile(types: ["public.file-url", "public.utf8-plain-text"],
                                                      suggestedName: "notes.txt"), "public.utf8-plain-text")
        XCTAssertNil(HistoryFileTypes.namedTextFile(types: ["public.utf8-plain-text"], suggestedName: nil))
        XCTAssertNil(HistoryFileTypes.namedTextFile(types: ["public.utf8-plain-text"], suggestedName: "見出し"))
        XCTAssertNil(HistoryFileTypes.namedTextFile(types: ["public.utf8-plain-text"], suggestedName: "資料.pdf"))
        XCTAssertNil(HistoryFileTypes.namedTextFile(types: ["public.url", "public.utf8-plain-text"], suggestedName: "readme.txt"))
        XCTAssertNil(HistoryFileTypes.namedTextFile(types: ["public.png", "public.utf8-plain-text"], suggestedName: "readme.txt"))
        XCTAssertNil(HistoryFileTypes.namedTextFile(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
                                                    suggestedName: "pw.txt"))
        XCTAssertTrue(HistoryFileTypes.isStorable("public.plain-text"))
        XCTAssertFalse(HistoryFileTypes.isFile("public.plain-text"))
        XCTAssertEqual(HistoryFileTypes.nameDiagnostic("秘密.csv"), ".csv")
        let root = try ImageTestSupport.directory(self)
        let csv = try FileTestSupport.input(in: root, bytes: Data("a,b\n1,2\n".utf8), name: "表.csv",
                                            type: "public.comma-separated-values-text")
        XCTAssertEqual(csv.file.originalFilename, "表.csv")
        XCTAssertEqual(csv.file.symbolName, "doc.plaintext")
    }

    func testStreamingHashFilenameFallbackAndEmptyFiles() throws {
        let root = try ImageTestSupport.directory(self)
        let input = try FileTestSupport.input(in: root, name: nil)
        XCTAssertEqual(input.file.hash, HistoryBackup.digest(FileTestSupport.bytes))
        XCTAssertEqual(input.file.originalFilename, "ファイル.pdf")
        XCTAssertEqual(input.file.byteCount, FileTestSupport.bytes.count)
        XCTAssertEqual(try Data(contentsOf: input.url), FileTestSupport.bytes)
        XCTAssertEqual(HistoryFileTypes.filename("../../資料.pdf", typeIdentifier: "com.adobe.pdf"), "資料.pdf")
        XCTAssertEqual(HistoryFileTypes.filename("C:\\secret\\資料.pdf", typeIdentifier: "com.adobe.pdf"), "資料.pdf")
        let empty = try FileTestSupport.input(in: root, bytes: Data())
        XCTAssertEqual(empty.file.byteCount, 0)
        XCTAssertEqual(empty.file.hash, HistoryBackup.digest(Data()))
    }

    func testFiftyMillionByteBoundaryUsesFileInsteadOfLargeData() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("large.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(HistoryFileFiles.maximumByteCount))
        try handle.close()
        let accepted = try HistoryFileFiles.stage(url, typeIdentifier: "com.adobe.pdf", suggestedName: nil)
        XCTAssertEqual(accepted.file.byteCount, 50_000_000)
        let grow = try FileHandle(forWritingTo: url)
        try grow.truncate(atOffset: 50_000_001)
        try grow.close()
        XCTAssertThrowsError(try HistoryFileFiles.stage(url, typeIdentifier: "com.adobe.pdf", suggestedName: nil)) { error in
            guard case HistoryFileError.tooLarge = error else { return XCTFail("Unexpected error") }
        }
    }

    func testVersionTwoMigrationAndFileDeduplicationKeepTextAndImageIndependent() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        // Genuine old schema, not a new database with a changed PRAGMA.
        try ImageTestSupport.sql(ImageTestSupport.versionOneSQL + """
            ALTER TABLE history ADD COLUMN image_hash TEXT;
            ALTER TABLE history ADD COLUMN image_file TEXT;
            ALTER TABLE history ADD COLUMN thumbnail_file TEXT;
            ALTER TABLE history ADD COLUMN image_bytes INTEGER;
            ALTER TABLE history ADD COLUMN pixel_width INTEGER;
            ALTER TABLE history ADD COLUMN pixel_height INTEGER;
            ALTER TABLE history ADD COLUMN image_type TEXT;
            DROP INDEX history_active_text;
            CREATE UNIQUE INDEX history_active_text ON history(text) WHERE deletion_id IS NULL AND kind != 'image';
            CREATE UNIQUE INDEX history_active_image ON history(image_hash) WHERE deletion_id IS NULL AND kind = 'image';
            PRAGMA user_version = 2;
            """, at: url)
        let database = try HistoryDatabase(url: url, now: { Date(timeIntervalSince1970: 1000) })
        XCTAssertEqual(try database.readSchemaVersion(), 3)
        XCTAssertEqual(try database.fetchAll().first?.id, 7)
        XCTAssertNotNil(try database.latestDeletion())
        let file = try FileTestSupport.input(in: root).file
        let first = try database.collectFile(file, source: .manual, at: Date(timeIntervalSince1970: 200))
        let renamed = try FileTestSupport.input(in: root, name: "別名.pdf").file
        let second = try database.collectFile(renamed, source: .automatic, at: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.collectionCount, 2)
        XCTAssertEqual(second.file, file) // Same bytes keep the first name/type, as images do.
        XCTAssertEqual(second.savedAt, first.savedAt)
        XCTAssertEqual(second.lastCollectedAt, Date(timeIntervalSince1970: 300))
        try database.collect("", source: .manual)
        try database.collect("資料.pdf", source: .manual)
        XCTAssertEqual(try database.fileUsage(), HistoryFileUsage(count: 1, byteCount: file.byteCount))
        XCTAssertEqual(try database.imageUsage(), HistoryImageUsage())
        XCTAssertEqual(try database.fetchAll().filter { $0.kind == .file }.count, 1)
    }

    func testFileSearchFilterAndPresentation() throws {
        let root = try ImageTestSupport.directory(self)
        let file = try FileTestSupport.input(in: root, name: "Report.PDF").file
        let entry = FileTestSupport.entry(file)
        XCTAssertEqual(HistoryFilter.files.title, "ファイル")
        XCTAssertEqual(HistoryFilter.entries([entry], filter: .files, search: " report "), [entry])
        XCTAssertTrue(HistoryFilter.entries([entry], filter: .texts, search: "").isEmpty)
        XCTAssertTrue(HistoryFilter.entries([entry], filter: .files, search: "unmatched").isEmpty)
        XCTAssertEqual(ShortcutContent.title(entry), "Report.PDF")
        XCTAssertEqual(file.symbolName, "doc.richtext")
        XCTAssertFalse(file.typeDescription.isEmpty)
        XCTAssertFalse(file.sizeDescription.isEmpty)
    }

    @MainActor
    private func drain(_ store: HistoryStore) {
        let done = expectation(description: "store drained")
        store.maintain { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testStoreDeduplicationDeleteAllUndoExpiryAndRetentionRemoveOriginals() throws {
        let root = try ImageTestSupport.directory(self)
        let directory = root.appendingPathComponent("attachments")
        var now = Date(timeIntervalSince1970: 1_000_000)
        var entries: [HistoryEntry] = []
        var usage = HistoryFileUsage()
        let store = HistoryStore(retention: .never,
                                 makeDatabase: { try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"), now: { now }) },
                                 imageDirectory: directory, now: { now }) { event in
            switch event {
            case .saved(let entry, _): HistoryList.upsert(entry, into: &entries)
            case .replace(let values): entries = values
            case .remove(let id): entries.removeAll { $0.id == id }
            case .fileUsage(let value): usage = value
            case .saveFailed, .fileRejected, .cleanupFailed: XCTFail("Unexpected failure")
            default: break
            }
        }
        for _ in 0..<2 { store.collectFile(try FileTestSupport.input(in: root), source: .manual, at: now) }
        drain(store)
        let entry = try XCTUnwrap(entries.first)
        let file = try XCTUnwrap(entry.file)
        XCTAssertEqual(entry.collectionCount, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [file.filename])
        XCTAssertEqual(usage, HistoryFileUsage(count: 1, byteCount: file.byteCount))
        var deletion: HistoryDeletion?
        let deleted = expectation(description: "deleted")
        store.deleteAll(includePinned: true) { result in
            switch result {
            case .success(let value): deletion = value
            case .failure(let error): XCTFail("\(error)")
            }
            deleted.fulfill()
        }
        wait(for: [deleted], timeout: 5)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileFiles.url(for: file).path))
        let undone = expectation(description: "undo")
        store.undo(try XCTUnwrap(deletion)) { result in
            switch result {
            case .success(let value): XCTAssertTrue(value)
            case .failure(let error): XCTFail("\(error)")
            }
            undone.fulfill()
        }
        wait(for: [undone], timeout: 5)
        XCTAssertEqual(entries, [entry])
        let deletedAgain = expectation(description: "deleted again")
        store.deleteAll(includePinned: true) { _ in deletedAgain.fulfill() }
        wait(for: [deletedAgain], timeout: 5)
        now.addTimeInterval(6)
        drain(store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileFiles.url(for: file).path))
        XCTAssertEqual(usage, HistoryFileUsage())
        store.collectFile(try FileTestSupport.input(in: root), source: .manual, at: now.addingTimeInterval(-86_401))
        drain(store)
        let expired = try XCTUnwrap(entries.first?.file)
        let retained = expectation(description: "retention")
        store.setRetention(.oneDay) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            retained.fulfill()
        }
        wait(for: [retained], timeout: 5)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileFiles.url(for: expired).path))
    }

    func testFileBackupRoundTripAndLegacyReaderRejectsVersionTwoBeforeJSON() throws {
        let root = try ImageTestSupport.directory(self)
        let originals = HistoryImageFiles(directory: root.appendingPathComponent("originals"))
        let file = try HistoryFileFiles(directory: originals.directory).prepare(FileTestSupport.input(in: root))
        let source = try HistoryDatabase(url: root.appendingPathComponent("source.sqlite"))
        let first = try source.collectFile(file, source: .drag, at: Date(timeIntervalSince1970: 20))
        try source.collectFile(file, source: .automatic, at: Date(timeIntervalSince1970: 30))
        try source.togglePin(id: first.id)
        try source.collect("文章", source: .manual)
        try source.collectImage(ImageTestSupport.prepare(originals), source: .manual, at: nil)
        let url = root.appendingPathComponent("backup.clipboardplus")
        _ = try HistoryBackup.write(entries: source.fetchAll(), files: originals, to: url, cancellation: BackupCancellation())
        let header = try FileHandle(forReadingFrom: url)
        XCTAssertEqual(try header.read(upToCount: 8), HistoryBackup.magic)
        let version = try HistoryBackup.readNumber(from: header)
        try header.close()
        XCTAssertEqual(version, 2)
        // The previous app has `guard readNumber(...) == 1 else { throw BackupError.version }`.
        XCTAssertNotEqual(version, 1)
        let backup = try HistoryBackup.validate(at: url, temporaryRoot: root, cancellation: BackupCancellation())
        let target = try HistoryDatabase(url: root.appendingPathComponent("target.sqlite"))
        let files = HistoryImageFiles(directory: root.appendingPathComponent("restored"))
        XCTAssertEqual(try HistoryRestore.apply(backup, database: target, files: files, cancellation: BackupCancellation()).added, 3)
        let entry = try XCTUnwrap(target.fetchAll().first { $0.kind == .file })
        let restored = try XCTUnwrap(entry.file)
        XCTAssertEqual(restored.hash, file.hash)
        XCTAssertEqual(restored.originalFilename, file.originalFilename)
        XCTAssertEqual(restored.typeIdentifier, file.typeIdentifier)
        XCTAssertEqual(entry.collectionCount, 2)
        XCTAssertTrue(entry.isPinned)
        XCTAssertEqual(try Data(contentsOf: files.url(for: restored.filename)), FileTestSupport.bytes)
        let second = try HistoryBackup.validate(at: url, temporaryRoot: root, cancellation: BackupCancellation())
        XCTAssertEqual(try HistoryRestore.apply(second, database: target, files: files, cancellation: BackupCancellation()), RestoreCounts(unchanged: 3))
    }

    func testVersionOneBackupWithoutFilePropertyStillLoads() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("old.clipboardplus")
        // Literal old metadata, independent of the current writer/Codable encoder.
        let json = Data(#"{"formatVersion":1,"createdAt":1,"itemCount":1,"entries":[{"id":7,"kind":"text","text":"old","savedAt":1,"lastCollectedAt":2,"collectionCount":3,"isPinned":true,"source":"manual"}]}"#.utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let output = try FileHandle(forWritingTo: url)
        try output.write(contentsOf: HistoryBackup.magic)
        try HistoryBackup.writeNumber(1, to: output)
        try HistoryBackup.writeNumber(UInt64(json.count), to: output)
        try output.write(contentsOf: json)
        try output.close()
        let backup = try HistoryBackup.validate(at: url, temporaryRoot: root, cancellation: BackupCancellation())
        XCTAssertEqual(backup.entries.first?.text, "old")
        XCTAssertNil(backup.entries.first?.file)
        let target = try HistoryDatabase(url: root.appendingPathComponent("target.sqlite"))
        _ = try HistoryRestore.apply(backup, database: target, files: HistoryImageFiles(directory: root.appendingPathComponent("files")), cancellation: BackupCancellation())
        XCTAssertEqual(try target.fetchAll().first?.collectionCount, 3)
    }

    func testFileRestoreFailureRollsBackRowsAndPlacedOriginal() throws {
        let root = try ImageTestSupport.directory(self)
        let staged = root.appendingPathComponent("staged")
        let file = try HistoryFileFiles(directory: staged).prepare(FileTestSupport.input(in: root))
        let backup = ValidatedBackup(directory: staged, entries: [FileTestSupport.entry(file)])
        let target = try HistoryDatabase(url: root.appendingPathComponent("target.sqlite"))
        let files = HistoryImageFiles(directory: root.appendingPathComponent("target"))
        XCTAssertThrowsError(try HistoryRestore.apply(backup, database: target, files: files, cancellation: BackupCancellation(), move: {
            try FileManager.default.moveItem(at: $0, to: $1)
            throw BackupError.unavailable
        }))
        XCTAssertTrue(try target.fetchAll().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.url(for: file.filename).path))
    }

    func testUndoMergesFileRecollectedDuringWindowAndClampsCount() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let database = try HistoryDatabase(url: url)
        let file = try FileTestSupport.input(in: root).file
        let old = try database.collectFile(file, source: .manual, at: Date(timeIntervalSince1970: 10))
        let deletion = try XCTUnwrap(database.delete(id: old.id))
        try ImageTestSupport.sql("UPDATE history SET collection_count = 1000000000", at: url)
        let fresh = try database.collectFile(file, source: .drag, at: Date(timeIntervalSince1970: 20))
        XCTAssertNotEqual(old.id, fresh.id)
        XCTAssertTrue(try database.undo(deletion))
        let restored = try XCTUnwrap(database.fetchAll().first)
        XCTAssertEqual(restored.id, old.id)
        XCTAssertEqual(restored.source, .drag)
        XCTAssertEqual(restored.collectionCount, HistoryCollectionCount.maximum)
        XCTAssertEqual(restored.savedAt, old.savedAt)
        XCTAssertEqual(restored.lastCollectedAt, fresh.lastCollectedAt)
        XCTAssertEqual(try database.fetchAll().count, 1)
        XCTAssertEqual(try database.referencedImageFiles(), file.filenames)
    }

    func testCombinedAttachmentLimitAndRestoreEstimateAgree() throws {
        let root = try ImageTestSupport.directory(self)
        let file = try FileTestSupport.input(in: root).file
        let images = HistoryImageFiles(directory: root.appendingPathComponent("images"))
        let image = try ImageTestSupport.prepare(images)
        let limit = max(file.byteCount, image.byteCount)
        let database = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"), imageByteLimit: limit)
        let fileEntry = try database.collectFile(file, source: .manual, at: Date(timeIntervalSince1970: 10))
        let imageEntry = try database.collectImage(image, source: .manual, at: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(try database.fetchAll(), [imageEntry])
        XCTAssertEqual(database.takeRemovals(), [fileEntry])
        let second = try FileTestSupport.input(in: root, bytes: Data("new".utf8)).file
        let incoming = FileTestSupport.entry(second, at: Date(timeIntervalSince1970: 30))
        let estimate = try database.estimateBackup([incoming])
        let actual = try database.mergeBackup([incoming]) { _ in }
        XCTAssertEqual(actual, estimate)
        XCTAssertEqual(estimate.removedByLimit, 1)
        XCTAssertEqual(try database.fetchAll().first?.file, second)
    }

    func testFileBackupRejectsCorruptBytesTruncationAndOversizeMetadata() throws {
        let root = try ImageTestSupport.directory(self)
        let files = HistoryImageFiles(directory: root.appendingPathComponent("files"))
        let file = try HistoryFileFiles(directory: files.directory).prepare(FileTestSupport.input(in: root))
        let entry = FileTestSupport.entry(file)
        let url = root.appendingPathComponent("backup.clipboardplus")
        _ = try HistoryBackup.write(entries: [entry], files: files, to: url, cancellation: BackupCancellation())
        let original = try Data(contentsOf: url)
        var corrupt = original
        corrupt[corrupt.count - 1] ^= 1
        var future = original
        future[15] = 99
        for data in [corrupt, Data(original.dropLast()), future] {
            let bad = root.appendingPathComponent(UUID().uuidString)
            try data.write(to: bad)
            XCTAssertThrowsError(try HistoryBackup.validate(at: bad, temporaryRoot: root, cancellation: BackupCancellation()))
        }
        let oversized = HistoryFile(hash: file.hash, filename: file.filename, originalFilename: file.originalFilename,
                                    byteCount: 50_000_001, typeIdentifier: file.typeIdentifier)
        XCTAssertThrowsError(try BackupManifest(formatVersion: 2, createdAt: Date(), itemCount: 1,
                                               entries: [entry.with(file: oversized)]).validate())
        XCTAssertThrowsError(try BackupManifest(formatVersion: 1, createdAt: Date(), itemCount: 1,
                                               entries: [entry]).validate())
        let json = try HistoryExport.data(entries: [entry], exportedAt: Date())
        XCTAssertEqual((try JSONSerialization.jsonObject(with: json) as? [String: Any])?["formatVersion"] as? Int, 3)
    }

    @MainActor
    func testFileBackupProtectsOriginalWhileHistoryIsDeleted() throws {
        let root = try ImageTestSupport.directory(self)
        var now = Date(timeIntervalSince1970: 100)
        var entry: HistoryEntry?
        let backupQueue = DispatchQueue(label: "test.file.backup")
        backupQueue.suspend()
        var resumed = false
        defer { if !resumed { backupQueue.resume() } }
        let store = HistoryStore(retention: .never,
                                 makeDatabase: { try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"), now: { now }) },
                                 imageDirectory: root.appendingPathComponent("files"), now: { now },
                                 backupQueue: backupQueue) { event in
            if case .saved(let value, _) = event { entry = value }
        }
        store.collectFile(try FileTestSupport.input(in: root), source: .manual, at: now)
        drain(store)
        let original = try XCTUnwrap(entry?.file)
        var exported: BackupExport?
        let completed = expectation(description: "backup completed")
        store.createBackup(cancellation: BackupCancellation(), progress: { _ in }) { result in
            switch result {
            case .success(let value): exported = value
            case .failure(let error): XCTFail("\(error)")
            }
            completed.fulfill()
        }
        let deleted = expectation(description: "deleted while backup queued")
        store.deleteAll(includePinned: true) { _ in deleted.fulfill() }
        wait(for: [deleted], timeout: 5)
        now.addTimeInterval(6)
        drain(store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileFiles.url(for: original).path))
        backupQueue.resume()
        resumed = true
        wait(for: [completed], timeout: 5)
        drain(store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileFiles.url(for: original).path))
        let backup = try HistoryBackup.validate(at: XCTUnwrap(exported).url, temporaryRoot: root, cancellation: BackupCancellation())
        XCTAssertEqual(backup.entries.first?.file?.hash, original.hash)
        if let exported { BackupTemporaryFiles.shared.remove(exported.url) }
    }
}
