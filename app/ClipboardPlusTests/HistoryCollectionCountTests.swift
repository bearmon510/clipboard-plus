import Foundation
import XCTest
@testable import ClipboardPlus

final class HistoryCollectionCountTests: XCTestCase {
    private let image = HistoryImage(hash: String(repeating: "a", count: 64), filename: "original.png",
                                     thumbnailFilename: "thumbnail.jpg", byteCount: 1,
                                     pixelWidth: 1, pixelHeight: 1, typeIdentifier: "public.png")

    private func collect(_ database: HistoryDatabase, image: Bool) throws -> HistoryEntry {
        if image { return try database.collectImage(self.image, source: .manual, at: nil) }
        return try database.collect("same original", source: .manual)
    }

    func testTextAndImageCollectionSaturateEvenForLegacyIntMaxRowsAndKeepIntegerStorage() throws {
        for isImage in [false, true] {
            let root = try ImageTestSupport.directory(self)
            let url = root.appendingPathComponent("history.sqlite")
            let database = try HistoryDatabase(url: url)
            let entry = try collect(database, image: isImage)
            for count in [HistoryCollectionCount.maximum - 2, HistoryCollectionCount.maximum - 1,
                          HistoryCollectionCount.maximum, Int.max - 1, Int.max] {
                try ImageTestSupport.sql("UPDATE history SET collection_count = \(count) WHERE id = \(entry.id)", at: url)
                let updated = try collect(database, image: isImage)
                XCTAssertEqual(updated.collectionCount, count < HistoryCollectionCount.maximum ? count + 1 : HistoryCollectionCount.maximum)
                XCTAssertEqual(try ImageTestSupport.sql("SELECT COUNT(*) FROM history WHERE typeof(collection_count) = 'integer'", at: url), 1)
            }
        }
    }

    func testTextAndImageUndoSaturateWhenRecollectedDuringDeletionWindow() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        for isImage in [false, true] {
            for count in [HistoryCollectionCount.maximum, Int.max - 1, Int.max] {
                let root = try ImageTestSupport.directory(self)
                let url = root.appendingPathComponent("history.sqlite")
                let database = try HistoryDatabase(url: url, now: { now })
                let original = try collect(database, image: isImage)
                try ImageTestSupport.sql("UPDATE history SET collection_count = \(count) WHERE id = \(original.id)", at: url)
                let deletion = try XCTUnwrap(database.delete(id: original.id))
                _ = try collect(database, image: isImage)
                _ = try collect(database, image: isImage) // Int.max - 1 plus 2 previously trapped.
                XCTAssertTrue(try database.undo(deletion))
                let rows = try database.fetchAll()
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows.first?.id, original.id)
                XCTAssertEqual(rows.first?.collectionCount, HistoryCollectionCount.maximum)
            }
        }
    }

    func testRestoreClampsNewRowsIncomingCountsAndLegacyExistingCounts() throws {
        for isImage in [false, true] {
            let root = try ImageTestSupport.directory(self)
            let url = root.appendingPathComponent("history.sqlite")
            let database = try HistoryDatabase(url: url)
            func incoming(_ count: Int) -> HistoryEntry {
                HistoryEntry(id: 1, kind: isImage ? .image : .text, text: isImage ? "" : "same original",
                             savedAt: Date(timeIntervalSince1970: 10), lastCollectedAt: Date(timeIntervalSince1970: 20),
                             collectionCount: count, isTemplate: false, source: .manual, image: isImage ? image : nil)
            }
            // The persistence boundary remains defensive even without archive validation.
            _ = try database.mergeBackup([incoming(Int.max)]) { _ in }
            XCTAssertEqual(try database.fetchAll().first?.collectionCount, HistoryCollectionCount.maximum)
            try ImageTestSupport.sql("UPDATE history SET collection_count = 1", at: url)
            _ = try database.mergeBackup([incoming(Int.max)]) { _ in }
            XCTAssertEqual(try database.fetchAll().first?.collectionCount, HistoryCollectionCount.maximum)
            try ImageTestSupport.sql("UPDATE history SET collection_count = \(Int.max)", at: url)
            let estimate = try database.estimateBackup([incoming(1)])
            XCTAssertEqual(estimate, RestoreCounts(updated: 1))
            XCTAssertEqual(try database.mergeBackup([incoming(1)]) { _ in }, estimate)
            XCTAssertEqual(try database.fetchAll().first?.collectionCount, HistoryCollectionCount.maximum)
            XCTAssertEqual(try database.mergeBackup([incoming(1)]) { _ in }, RestoreCounts(unchanged: 1))
        }
    }
}
