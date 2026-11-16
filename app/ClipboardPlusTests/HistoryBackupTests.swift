import Foundation
import UIKit
import XCTest
@testable import ClipboardPlus

final class HistoryBackupTests: XCTestCase {
    private func text(_ value: String, saved: Double = 10, collected: Double = 20,
                      count: Int = 3, pin: Bool = false, source: HistorySource = .drag) -> HistoryEntry {
        HistoryEntry(id: 1, kind: HistoryKind.classify(value), text: value,
                     savedAt: Date(timeIntervalSince1970: saved), lastCollectedAt: Date(timeIntervalSince1970: collected),
                     collectionCount: count, isTemplate: pin, source: source)
    }

    private func semantic(_ entry: HistoryEntry) -> HistoryEntry {
        let image = entry.image.map {
            HistoryImage(hash: $0.hash, filename: "", thumbnailFilename: "", byteCount: $0.byteCount,
                         pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight, typeIdentifier: $0.typeIdentifier)
        }
        return HistoryEntry(id: 0, kind: entry.kind, text: entry.text, savedAt: entry.savedAt,
                            lastCollectedAt: entry.lastCollectedAt, collectionCount: entry.collectionCount,
                            isTemplate: entry.isTemplate, source: entry.source, image: image)
    }

    private func directoryContents(_ url: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    private func write(_ entries: [HistoryEntry], files: HistoryImageFiles, root: URL) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".clipboardplus")
        _ = try HistoryBackup.write(entries: entries, files: files, to: url, cancellation: BackupCancellation())
        return url
    }

    func testRoundTripPreservesTextURLImagesPinsTimesCountsAndSourcesAndIsIdempotent() throws {
        let root = try ImageTestSupport.directory(self)
        let originals = HistoryImageFiles(directory: root.appendingPathComponent("originals"))
        let source = try HistoryDatabase(url: root.appendingPathComponent("source.sqlite"))
        let first = try source.collect("文章\n\0原文", source: .automatic, at: Date(timeIntervalSince1970: 10.125))
        try source.collect(first.text, source: .drag, at: Date(timeIntervalSince1970: 30.375))
        try source.moveToTemplates(id: first.id)
        try source.collect("https://example.com/path", source: .manual, at: Date(timeIntervalSince1970: 15.5))
        let image = try ImageTestSupport.prepare(originals)
        let imageEntry = try source.collectImage(image, source: .manual, at: Date(timeIntervalSince1970: 12.25))
        try source.collectImage(image, source: .automatic, at: Date(timeIntervalSince1970: 40.75))
        try source.moveToTemplates(id: imageEntry.id)
        let entries = try source.fetchAll()
        let url = try write(entries, files: originals, root: root)
        let files = HistoryImageFiles(directory: root.appendingPathComponent("restored"))
        let database = try HistoryDatabase(url: root.appendingPathComponent("target.sqlite"))
        let backup = try HistoryBackup.validate(at: url, temporaryRoot: root, cancellation: BackupCancellation())
        XCTAssertTrue(try database.fetchAll().isEmpty)
        XCTAssertTrue(try directoryContents(files.directory).isEmpty)
        XCTAssertEqual(try database.estimateBackup(backup.entries), RestoreCounts(added: 3))
        let counts = try HistoryRestore.apply(backup, database: database, files: files, cancellation: BackupCancellation())
        XCTAssertEqual(counts, RestoreCounts(added: 3))
        let restored = try database.fetchAll()
        XCTAssertEqual(restored.map(semantic), entries.map(semantic))
        let restoredImage = try XCTUnwrap(restored.first?.image)
        XCTAssertEqual(try files.read(restoredImage), try originals.read(image))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.url(for: restoredImage.thumbnailFilename).path))
        waitForBackupCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.directory.path))

        let beforeFiles = try directoryContents(files.directory)
        let second = try HistoryBackup.validate(at: url, temporaryRoot: root, cancellation: BackupCancellation())
        XCTAssertEqual(try database.estimateBackup(second.entries), RestoreCounts(unchanged: 3))
        XCTAssertEqual(try HistoryRestore.apply(second, database: database, files: files, cancellation: BackupCancellation()),
                       RestoreCounts(unchanged: 3))
        XCTAssertEqual(try database.fetchAll(), restored)
        XCTAssertEqual(try directoryContents(files.directory), beforeFiles)
    }

    func testMergeRulesEarlierSavedLaterCollectedMaximumCountAndSourceTie() throws {
        let root = try ImageTestSupport.directory(self)
        let database = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"))
        let old = [text("later", saved: 20, collected: 30, count: 8, pin: true, source: .manual),
                   text("earlier", saved: 5, collected: 50, pin: true, source: .automatic),
                   text("tie", source: .manual)]
        _ = try database.mergeBackup(old) { _ in }
        let incoming = [text("later", saved: 10, collected: 40, count: 4, pin: true, source: .drag),
                        text("earlier", saved: 10, collected: 40, count: 9, pin: true, source: .drag),
                        text("tie", source: .drag)]
        XCTAssertEqual(try database.estimateBackup(incoming), RestoreCounts(updated: 2, unchanged: 1))
        _ = try database.mergeBackup(incoming) { _ in }
        let values = Dictionary(uniqueKeysWithValues: try database.fetchAll().map { ($0.text, semantic($0)) })
        XCTAssertEqual(values["later"], semantic(text("later", saved: 10, collected: 40, count: 8, pin: true)))
        XCTAssertEqual(values["earlier"], semantic(text("earlier", saved: 5, collected: 50, count: 9, pin: true, source: .automatic)))
        XCTAssertEqual(values["tie"]?.source, .manual)
        XCTAssertEqual(try database.mergeBackup(incoming) { _ in }, RestoreCounts(unchanged: 3))
    }

    func testMergeUsesExactUTF8AndTreatsImageHashAsIdentity() throws {
        let root = try ImageTestSupport.directory(self)
        let files = HistoryImageFiles(directory: root.appendingPathComponent("images"))
        let database = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"))
        let image = try ImageTestSupport.prepare(files)
        let existing = try database.collectImage(image, source: .manual, at: Date(timeIntervalSince1970: 10))
        try database.moveToTemplates(id: existing.id)
        let sameBytes = try ImageTestSupport.prepare(files)
        let incoming = HistoryEntry(id: 2, kind: .image, text: "", savedAt: Date(timeIntervalSince1970: 5),
                                    lastCollectedAt: Date(timeIntervalSince1970: 20), collectionCount: 6,
                                    isTemplate: true, source: .drag, image: sameBytes)
        let result = try database.mergeBackup([text("é"), text("e\u{301}"), incoming]) { _ in }
        XCTAssertEqual(result, RestoreCounts(added: 2, updated: 1))
        let rows = try database.fetchAll()
        XCTAssertEqual(rows.count, 3)
        let merged = try XCTUnwrap(rows.first { $0.kind == .image })
        XCTAssertEqual(merged.id, existing.id)
        XCTAssertEqual(merged.image, image)
        XCTAssertEqual(merged.savedAt, incoming.savedAt)
        XCTAssertEqual(merged.lastCollectedAt, incoming.lastCollectedAt)
        XCTAssertEqual(merged.collectionCount, 6)
        XCTAssertEqual(merged.source, .drag)
        XCTAssertTrue(merged.isTemplate)
    }

    private func replaceManifest(in data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        let length = data[16..<24].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data.subdata(in: 24..<(24 + Int(length)))) as? [String: Any])
        change(&object)
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var result = data.prefix(16)
        result.append(contentsOf: (0..<8).reversed().map { UInt8(truncatingIfNeeded: UInt64(json.count) >> ($0 * 8)) })
        result.append(json)
        result.append(data.suffix(from: 24 + Int(length)))
        return result
    }

    func testRejectsCountsAboveLimitIncludingNearIntMaxForTextAndImages() throws {
        let root = try ImageTestSupport.directory(self)
        let files = HistoryImageFiles(directory: root.appendingPathComponent("images"))
        let database = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"))
        try database.collect("original", source: .manual)
        try database.collectImage(ImageTestSupport.prepare(files), source: .manual, at: nil)
        let before = try database.fetchAll()
        let beforeFiles = try directoryContents(files.directory)
        let valid = try Data(contentsOf: write(before, files: files, root: root))
        for index in before.indices {
            for count in [HistoryCollectionCount.maximum, HistoryCollectionCount.maximum + 1, Int.max - 1, Int.max] {
                let data = try replaceManifest(in: valid) { object in
                    var entries = object["entries"] as! [[String: Any]]
                    entries[index]["collectionCount"] = count
                    object["entries"] = entries
                }
                let url = root.appendingPathComponent("count.clipboardplus")
                try data.write(to: url)
                if count == HistoryCollectionCount.maximum {
                    let backup = try HistoryBackup.validate(at: url, temporaryRoot: root, cancellation: BackupCancellation())
                    XCTAssertEqual(backup.entries[index].collectionCount, count)
                    backup.discard()
                } else {
                    XCTAssertThrowsError(try HistoryBackup.validate(at: url, temporaryRoot: root, cancellation: BackupCancellation())) { error in
                        guard case BackupError.manifest = error else { return XCTFail("Expected invalid manifest, got \(error)") }
                    }
                }
                waitForBackupCleanup()
                XCTAssertEqual(try database.fetchAll(), before)
                XCTAssertEqual(try directoryContents(files.directory), beforeFiles)
            }
        }
    }

    func testRejectsEntireCorruptArchiveWithoutChangingDatabaseOrImages() throws {
        let root = try ImageTestSupport.directory(self)
        let files = HistoryImageFiles(directory: root.appendingPathComponent("images"))
        let database = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"))
        try database.collect("keep", source: .manual)
        try database.collectImage(ImageTestSupport.prepare(files), source: .drag, at: nil)
        let before = try database.fetchAll()
        let beforeFiles = try directoryContents(files.directory)
        let validURL = try write(before, files: files, root: root)
        let valid = try Data(contentsOf: validURL)
        let manifestLength = valid[16..<24].reduce(0) { ($0 << 8) | Int($1) }
        var badHash = valid
        badHash[badHash.count - 1] ^= 1
        var badLength = valid
        badLength[24 + manifestLength + 7] ^= 1
        var badVersion = valid
        badVersion[15] = 2
        var badIdentifier = valid
        badIdentifier[0] = 0
        var badJSON = valid
        badJSON[24] = 0xff
        var trailing = valid
        trailing.append(0)
        let invalidKind = try replaceManifest(in: valid) { object in
            var entries = object["entries"] as! [[String: Any]]
            entries[0]["kind"] = "movie"
            object["entries"] = entries
        }
        let oversized = try replaceManifest(in: valid) { object in
            var entries = object["entries"] as! [[String: Any]]
            let index = entries.firstIndex { $0["kind"] as? String == "image" }!
            var image = entries[index]["image"] as! [String: Any]
            image["byteCount"] = HistoryImageFiles.maximumByteCount + 1
            entries[index]["image"] = image
            object["entries"] = entries
        }
        let byteMismatch = try replaceManifest(in: valid) { object in
            var entries = object["entries"] as! [[String: Any]]
            let index = entries.firstIndex { $0["kind"] as? String == "image" }!
            var image = entries[index]["image"] as! [String: Any]
            image["byteCount"] = (image["byteCount"] as! Int) + 1
            entries[index]["image"] = image
            object["entries"] = entries
        }
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let variants = [Data(valid.prefix(7)), Data(valid.dropLast()), badHash, badLength, badVersion,
                        badIdentifier, badJSON, trailing, invalidKind, oversized, byteMismatch]
        for (index, data) in variants.enumerated() {
            let url = root.appendingPathComponent("bad-\(index).clipboardplus")
            try data.write(to: url)
            XCTAssertThrowsError(try HistoryBackup.validate(at: url, temporaryRoot: staging, cancellation: BackupCancellation()), "variant \(index)")
            XCTAssertEqual(try database.fetchAll(), before)
            XCTAssertEqual(try directoryContents(files.directory), beforeFiles)
            waitForBackupCleanup()
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        }
    }

    func testFilePlacementFailureRollsBackSQLRemovalJournalAndAllPlacedFiles() throws {
        let root = try ImageTestSupport.directory(self)
        let files = HistoryImageFiles(directory: root.appendingPathComponent("images"))
        let database = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"), historyLimit: 1)
        let preserved = try database.collectImage(ImageTestSupport.prepare(files, color: .blue), source: .manual,
                                                  at: Date(timeIntervalSince1970: 0))
        try database.moveToTemplates(id: preserved.id)
        try database.collect("keep", source: .manual, at: Date(timeIntervalSince1970: 1))
        let originalFiles = HistoryImageFiles(directory: root.appendingPathComponent("originals"))
        let image = try ImageTestSupport.prepare(originalFiles)
        let incoming = HistoryEntry(id: 1, kind: .image, text: "", savedAt: Date(timeIntervalSince1970: 20),
                                    lastCollectedAt: Date(timeIntervalSince1970: 20), collectionCount: 4,
                                    isTemplate: false, source: .manual, image: image)
        let url = try write([text("new"), incoming], files: originalFiles, root: root)
        let backup = try HistoryBackup.validate(at: url, temporaryRoot: root, cancellation: BackupCancellation())
        let before = try database.fetchAll()
        let beforeFiles = try directoryContents(files.directory)
        var moves = 0
        XCTAssertThrowsError(try HistoryRestore.apply(backup, database: database, files: files, cancellation: BackupCancellation(), move: { from, to in
            try FileManager.default.moveItem(at: from, to: to)
            moves += 1
            if moves == 2 { throw BackupError.unavailable }
        }))
        XCTAssertEqual(moves, 2)
        XCTAssertEqual(try database.fetchAll(), before)
        XCTAssertTrue(database.takeRemovals().isEmpty)
        XCTAssertEqual(try directoryContents(files.directory), beforeFiles)
        waitForBackupCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.directory.path))
    }

    func testSQLFailureRollsBackEarlierWritesAndRemovesStaging() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let database = try HistoryDatabase(url: url)
        try database.collect("keep", source: .manual)
        let before = try database.fetchAll()
        try ImageTestSupport.sql("CREATE TRIGGER fail_restore BEFORE INSERT ON history WHEN NEW.text = 'fail' BEGIN SELECT RAISE(ABORT, 'test'); END;", at: url)
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let backup = ValidatedBackup(directory: staging, entries: [text("first"), text("fail")])
        let files = HistoryImageFiles(directory: root.appendingPathComponent("images"))
        XCTAssertThrowsError(try HistoryRestore.apply(backup, database: database, files: files, cancellation: BackupCancellation()))
        XCTAssertEqual(try database.fetchAll(), before)
        XCTAssertTrue(database.takeRemovals().isEmpty)
        XCTAssertTrue(try directoryContents(files.directory).isEmpty)
        waitForBackupCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testEstimateMatchesCountAndImageByteLimitsAndPinnedItemsSurvive() throws {
        let root = try ImageTestSupport.directory(self)
        let files = HistoryImageFiles(directory: root.appendingPathComponent("images"))
        let red = try ImageTestSupport.prepare(files)
        let blue = try ImageTestSupport.prepare(files, color: .blue)
        let database = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"),
                                           historyLimit: 3, imageByteLimit: max(red.byteCount, blue.byteCount))
        let old = try database.collect("old", source: .manual, at: Date(timeIntervalSince1970: 1))
        let pinned = text("pinned", saved: 1, collected: 1, pin: true)
        func imageEntry(_ image: HistoryImage, time: Double) -> HistoryEntry {
            HistoryEntry(id: 0, kind: .image, text: "", savedAt: Date(timeIntervalSince1970: time),
                         lastCollectedAt: Date(timeIntervalSince1970: time), collectionCount: 1,
                         isTemplate: false, source: .manual, image: image)
        }
        let incoming = [pinned, text("new", saved: 2, collected: 2), imageEntry(red, time: 3), imageEntry(blue, time: 4)]
        let estimate = try database.estimateBackup(incoming)
        XCTAssertEqual(estimate, RestoreCounts(added: 4, removedByLimit: 2))
        let actual = try database.mergeBackup(incoming) { _ in }
        XCTAssertEqual(actual, estimate)
        let removed = database.takeRemovals()
        XCTAssertEqual(removed.count, estimate.removedByLimit)
        XCTAssertTrue(removed.contains { $0.id == old.id })
        XCTAssertEqual(removed.compactMap { $0.image?.hash }, [red.hash])
        XCTAssertTrue(try database.fetchAll().contains { $0.text == "pinned" && $0.isTemplate })
    }

    func testCreateAndValidationCancellationRemovePartialFiles() throws {
        let root = try ImageTestSupport.directory(self)
        let files = HistoryImageFiles(directory: root.appendingPathComponent("images"))
        let image = try ImageTestSupport.prepare(files)
        let entry = HistoryEntry(id: 1, kind: .image, text: "", savedAt: Date(), lastCollectedAt: Date(),
                                 collectionCount: 1, isTemplate: false, source: .drag, image: image)
        let entries = [entry, text("later")]
        let url = root.appendingPathComponent("cancel.clipboardplus")
        let createToken = BackupCancellation()
        XCTAssertThrowsError(try HistoryBackup.write(entries: entries, files: files, to: url, cancellation: createToken) { value in
            if value.completed == 1 { createToken.cancel() }
        })
        waitForBackupCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let valid = try write(entries, files: files, root: root)
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let validateToken = BackupCancellation()
        XCTAssertThrowsError(try HistoryBackup.validate(at: valid, temporaryRoot: staging, cancellation: validateToken) { value in
            if value.completed == 1 { validateToken.cancel() }
        })
        waitForBackupCleanup()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        let prepared = try HistoryBackup.validate(at: valid, temporaryRoot: staging, cancellation: BackupCancellation())
        prepared.discard() // The confirmation's Cancel button uses this same operation.
        waitForBackupCleanup()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testRepeatedRestoreAtTiedLimitDoesNotDisplaceSurvivingItems() throws {
        let root = try ImageTestSupport.directory(self)
        let database = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"), historyLimit: 1)
        let incoming = [text("a"), text("b"), text("c")]
        let estimate = try database.estimateBackup(incoming)
        XCTAssertEqual(estimate.removedByLimit, 2)
        _ = try database.mergeBackup(incoming) { _ in }
        let first = try database.fetchAll()
        _ = try database.mergeBackup(incoming) { _ in }
        XCTAssertEqual(try database.fetchAll(), first)
    }

    func testCancellationDuringApplyRollsBackAndDeletesPlacedImages() throws {
        let root = try ImageTestSupport.directory(self)
        let sourceFiles = HistoryImageFiles(directory: root.appendingPathComponent("source"))
        let image = try ImageTestSupport.prepare(sourceFiles)
        let entry = HistoryEntry(id: 1, kind: .image, text: "", savedAt: Date(), lastCollectedAt: Date(),
                                 collectionCount: 1, isTemplate: false, source: .drag, image: image)
        let url = try write([entry, text("next")], files: sourceFiles, root: root)
        let backup = try HistoryBackup.validate(at: url, temporaryRoot: root, cancellation: BackupCancellation())
        let database = try HistoryDatabase(url: root.appendingPathComponent("target.sqlite"))
        let files = HistoryImageFiles(directory: root.appendingPathComponent("target"))
        let token = BackupCancellation()
        XCTAssertThrowsError(try HistoryRestore.apply(backup, database: database, files: files, cancellation: token, progress: { value in
            if value.completed == 1 { token.cancel() }
        }))
        XCTAssertTrue(try database.fetchAll().isEmpty)
        XCTAssertTrue(try directoryContents(files.directory).isEmpty)
        waitForBackupCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.directory.path))
    }

    func testManifestAndFileURLAreExcludedWithoutExcludingIndividualOriginals() throws {
        var admission = HistoryAdmission()
        let json = Data("{\"entries\":[\"private original\"]}".utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.clipboardplus")
        admission.recordBackup(manifestDigest: HistoryBackup.digest(json), url: url)
        XCTAssertEqual(admission.receive(String(decoding: json, as: UTF8.self)), .skip(reason: "このアプリが書き出した内容"))
        XCTAssertEqual(admission.receive(url.absoluteString), .skip(reason: "このアプリが書き出した内容"))
        XCTAssertEqual(admission.receive("private original"), .add)
        admission.recordExport("old JSON export")
        XCTAssertEqual(admission.receive("old JSON export"), .skip(reason: "このアプリが書き出した内容"))
        for version in 1...4 {
            let header = "CLIPPLUS" + String(repeating: "\0", count: 7) + String(UnicodeScalar(version)!)
            XCTAssertEqual(admission.receive(header + "payload"), .skip(reason: "このアプリが書き出した内容"))
        }
    }
}
