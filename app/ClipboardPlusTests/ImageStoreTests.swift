import Foundation
import UIKit
import XCTest
@testable import ClipboardPlus

final class ImageStoreTests: XCTestCase {
    @MainActor
    private func drain(_ store: HistoryStore) {
        let done = expectation(description: "store drained")
        store.maintain { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    private func filenames(_ directory: URL) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    @MainActor
    func testDuplicateCleanupAndByteLimitRemoveFilesAndVisibleRowsButKeepPins() throws {
        let root = try ImageTestSupport.directory(self)
        let directory = root.appendingPathComponent("images")
        let url = root.appendingPathComponent("history.sqlite")
        let red = ImageTestSupport.png(), blue = ImageTestSupport.png(.blue), green = ImageTestSupport.png(.green)
        let limit = max(red.count, max(blue.count, green.count))
        var entries: [HistoryEntry] = []
        var saved: [HistoryEntry] = []
        var usage = HistoryImageUsage()
        let store = HistoryStore(retention: .never, makeDatabase: { try HistoryDatabase(url: url, imageByteLimit: limit) }, imageDirectory: directory) { event in
            switch event {
            case .saved(let entry, _): saved.append(entry); HistoryList.upsert(entry, into: &entries)
            case .upsert(let entry): HistoryList.upsert(entry, into: &entries)
            case .remove(let id): entries.removeAll { $0.id == id }
            case .replace(let values): entries = values
            case .imageUsage(let value): usage = value
            case .saveFailed, .imageRejected, .cleanupFailed: XCTFail("Unexpected storage failure")
            default: break
            }
        }
        store.collectImage(.data(red, typeIdentifier: "public.png"), source: .manual, at: Date(timeIntervalSince1970: 1))
        drain(store)
        let pinned = try XCTUnwrap(entries.first)
        let pinDone = expectation(description: "pin saved")
        store.togglePin(id: pinned.id) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            pinDone.fulfill()
        }
        wait(for: [pinDone], timeout: 5)
        store.collectImage(.data(blue, typeIdentifier: "public.png"), source: .manual, at: Date(timeIntervalSince1970: 2))
        store.collectImage(.data(blue, typeIdentifier: "public.png"), source: .drag, at: Date(timeIntervalSince1970: 3))
        drain(store)
        XCTAssertEqual(saved.last?.collectionCount, 2)
        XCTAssertEqual(try filenames(directory), Set(entries.flatMap { $0.image?.filenames ?? [] }))
        let removed = try XCTUnwrap(entries.first?.image)
        store.collectImage(.data(green, typeIdentifier: "public.png"), source: .manual, at: Date(timeIntervalSince1970: 4))
        drain(store)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains { $0.id == pinned.id && $0.isPinned })
        XCTAssertFalse(entries.contains { $0.image?.hash == removed.hash })
        XCTAssertTrue(try filenames(directory).isDisjoint(with: removed.filenames))
        XCTAssertEqual(try filenames(directory), Set(entries.flatMap { $0.image?.filenames ?? [] }))
        XCTAssertEqual(usage.count, 2)
        XCTAssertEqual(usage.byteCount, red.count + green.count)
        let database = try HistoryDatabase(url: url)
        XCTAssertEqual(try database.fetchAll(), entries)
    }

    @MainActor
    func testDeleteUndoAndExpiryKeepThenRemoveOriginalAndThumbnail() throws {
        let root = try ImageTestSupport.directory(self)
        let directory = root.appendingPathComponent("images")
        let url = root.appendingPathComponent("history.sqlite")
        var now = Date(timeIntervalSince1970: 100)
        var entry: HistoryEntry?
        var usage = HistoryImageUsage()
        let store = HistoryStore(retention: .never, makeDatabase: { try HistoryDatabase(url: url, now: { now }) }, imageDirectory: directory) { event in
            if case .saved(let value, _) = event { entry = value }
            if case .imageUsage(let value) = event { usage = value }
        }
        store.collectImage(.data(ImageTestSupport.png(), typeIdentifier: "public.png"), source: .manual, at: now)
        drain(store)
        let original = try XCTUnwrap(entry)
        let image = try XCTUnwrap(original.image)
        var deletion: HistoryDeletion?
        let deleted = expectation(description: "soft deleted")
        store.delete(id: original.id) { result in
            switch result {
            case .success(let value): deletion = value
            case .failure(let error): XCTFail("\(error)")
            }
            deleted.fulfill()
        }
        wait(for: [deleted], timeout: 5)
        XCTAssertEqual(try filenames(directory), image.filenames)
        XCTAssertEqual(usage.count, 1)
        now.addTimeInterval(4)
        drain(store)
        XCTAssertEqual(try filenames(directory), image.filenames)
        let restored = expectation(description: "restored")
        store.undo(try XCTUnwrap(deletion)) { result in
            switch result {
            case .success(let value): XCTAssertTrue(value)
            case .failure(let error): XCTFail("\(error)")
            }
            restored.fulfill()
        }
        wait(for: [restored], timeout: 5)
        let database = try HistoryDatabase(url: url, now: { now })
        XCTAssertEqual(try database.fetchAll(), [original])
        XCTAssertEqual(try filenames(directory), image.filenames)
        let deletedAgain = expectation(description: "deleted again")
        store.delete(id: original.id) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            deletedAgain.fulfill()
        }
        wait(for: [deletedAgain], timeout: 5)
        now.addTimeInterval(5)
        drain(store)
        XCTAssertTrue(try filenames(directory).isEmpty)
        XCTAssertEqual(usage, HistoryImageUsage())
    }

    @MainActor
    func testStartupCleanupKeepsActiveAndUndoPendingFiles() throws {
        let root = try ImageTestSupport.directory(self)
        let directory = root.appendingPathComponent("images")
        let url = root.appendingPathComponent("history.sqlite")
        let files = HistoryImageFiles(directory: directory)
        let active = try ImageTestSupport.prepare(files)
        let pending = try ImageTestSupport.prepare(files, color: .blue)
        let orphan = try ImageTestSupport.prepare(files, color: .green)
        let now = Date(timeIntervalSince1970: 100)
        do {
            let database = try HistoryDatabase(url: url, now: { now })
            try database.collectImage(active, source: .manual, at: now)
            let row = try database.collectImage(pending, source: .manual, at: now)
            try database.delete(id: row.id)
        }
        var loaded: [HistoryEntry] = []
        let store = HistoryStore(retention: .never, makeDatabase: { try HistoryDatabase(url: url, now: { now }) }, imageDirectory: directory) { event in
            if case .replace(let values) = event { loaded = values }
        }
        let done = expectation(description: "startup cleanup")
        store.load { result in
            switch result {
            case .success(let deletion): XCTAssertNotNil(deletion)
            case .failure(let error): XCTFail("\(error)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(loaded.map(\.image), [active])
        XCTAssertEqual(try filenames(directory), active.filenames.union(pending.filenames))
        XCTAssertTrue(try filenames(directory).isDisjoint(with: orphan.filenames))
    }

    @MainActor
    func testDatabaseFailureRetainsFilesAndRetriesWithoutPreparingAgain() throws {
        let root = try ImageTestSupport.directory(self)
        let directory = root.appendingPathComponent("images")
        let url = root.appendingPathComponent("history.sqlite")
        do { _ = try HistoryDatabase(url: url) }
        try ImageTestSupport.sql("CREATE TRIGGER fail_image BEFORE INSERT ON history WHEN NEW.kind = 'image' BEGIN SELECT RAISE(ABORT, 'test failure'); END;", at: url)
        var prepared: [HistoryImage] = []
        var saved: [HistoryEntry] = []
        let failed = expectation(description: "DB failed")
        let store = HistoryStore(retention: .never, makeDatabase: {
            XCTAssertFalse(Thread.isMainThread)
            return try HistoryDatabase(url: url)
        }, imageDirectory: directory) { event in
            switch event {
            case .imageProcessed(let image, _): prepared.append(image)
            case .saveFailed: failed.fulfill()
            case .saved(let entry, let retried):
                XCTAssertTrue(retried)
                saved.append(entry)
            default: break
            }
        }
        let data = ImageTestSupport.png()
        store.collectImage(.data(data, typeIdentifier: "public.png"), source: .manual, at: Date())
        wait(for: [failed], timeout: 5)
        let staged = try XCTUnwrap(prepared.first)
        XCTAssertEqual(try filenames(directory), staged.filenames)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(staged.filename)), data)
        XCTAssertTrue(saved.isEmpty)
        try ImageTestSupport.sql("DROP TRIGGER fail_image", at: url)
        drain(store)
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.image, staged)
        XCTAssertEqual(saved.first?.collectionCount, 1)
        XCTAssertEqual(try filenames(directory), staged.filenames)
    }

    @MainActor
    func testInvalidAndOversizedCollectionsNeverReachDatabase() throws {
        let root = try ImageTestSupport.directory(self)
        let directory = root.appendingPathComponent("images")
        let url = root.appendingPathComponent("history.sqlite")
        var rejections: [String] = []
        let store = HistoryStore(retention: .never, makeDatabase: { try HistoryDatabase(url: url) }, imageDirectory: directory) { event in
            switch event {
            case .imageRejected(let message, let details): rejections.append(message + details)
            case .saved, .saveFailed: XCTFail("Rejected image must not enter the save queue")
            default: break
            }
        }
        store.collectImage(.data(Data("invalid".utf8), typeIdentifier: "public.png"), source: .manual, at: Date())
        store.collectImage(.data(Data(count: 20_000_001), typeIdentifier: "public.png"), source: .manual, at: Date())
        drain(store)
        XCTAssertEqual(rejections.count, 2)
        XCTAssertTrue(rejections[1].contains("画像が大きすぎるため保存しませんでした"))
        XCTAssertTrue(rejections[1].contains("20000001"))
        XCTAssertTrue(try filenames(directory).isEmpty)
        let database = try HistoryDatabase(url: url)
        XCTAssertTrue(try database.fetchAll().isEmpty)
    }

    @MainActor
    func testFileWriteFailureIsAbandonedAndReportedWithoutPendingRetry() throws {
        let root = try ImageTestSupport.directory(self)
        let directory = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: directory)
        let url = root.appendingPathComponent("history.sqlite")
        var rejected = 0
        let store = HistoryStore(retention: .never, makeDatabase: { try HistoryDatabase(url: url) }, imageDirectory: directory) { event in
            if case .imageRejected(let message, _) = event {
                rejected += 1
                XCTAssertEqual(message, HistoryImageError.fileWrite.message)
            }
            if case .saveFailed = event { XCTFail("File failure must not be queued") }
        }
        store.collectImage(.data(ImageTestSupport.png(), typeIdentifier: "public.png"), source: .manual, at: Date())
        // Remove the deliberate directory obstruction before normal startup cleanup.
        let rejectedDone = expectation(description: "rejection delivered")
        store.readImage(HistoryImage(hash: "", filename: "missing", thumbnailFilename: "missing", byteCount: 0,
                                    pixelWidth: 0, pixelHeight: 0, typeIdentifier: "public.png")) { _ in rejectedDone.fulfill() }
        wait(for: [rejectedDone], timeout: 5)
        try FileManager.default.removeItem(at: directory)
        drain(store)
        XCTAssertEqual(rejected, 1)
        XCTAssertTrue(try HistoryDatabase(url: url).fetchAll().isEmpty)
    }

    @MainActor
    func testSelfCopyLeavesTimeAndCountUnchangedThenExternalCopyIncrements() throws {
        let root = try ImageTestSupport.directory(self)
        let directory = root.appendingPathComponent("images")
        let url = root.appendingPathComponent("history.sqlite")
        let data = ImageTestSupport.png()
        let hash = try HistoryImageFiles.hash(data)
        var saved: [HistoryEntry] = []
        var skipped = 0
        let store = HistoryStore(retention: .never, makeDatabase: { try HistoryDatabase(url: url) }, imageDirectory: directory) { event in
            if case .saved(let entry, _) = event { saved.append(entry) }
            if case .imageSkipped = event { skipped += 1 }
        }
        let first = Date(timeIntervalSince1970: 100)
        store.collectImage(.data(data, typeIdentifier: "public.png"), source: .automatic, at: first, before: 1, after: 1)
        store.recordImageCopy(hash: hash, changeCount: 2)
        store.collectImage(.data(data, typeIdentifier: "public.png"), source: .automatic, at: first.addingTimeInterval(1), before: 2, after: 2)
        drain(store)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.collectionCount, 1)
        XCTAssertEqual(saved.first?.lastCollectedAt, first)
        XCTAssertEqual(skipped, 1)
        store.collectImage(.data(data, typeIdentifier: "public.png"), source: .automatic, at: first.addingTimeInterval(2), before: 3, after: 3)
        drain(store)
        XCTAssertEqual(saved.last?.collectionCount, 2)
        XCTAssertEqual(saved.last?.lastCollectedAt, first.addingTimeInterval(2))
        XCTAssertEqual(try filenames(directory).count, 2)
    }

    @MainActor
    func testCountLimitRemovesImageFilesWhenNewTextArrives() throws {
        let root = try ImageTestSupport.directory(self)
        let directory = root.appendingPathComponent("images")
        let url = root.appendingPathComponent("history.sqlite")
        var entries: [HistoryEntry] = []
        let store = HistoryStore(retention: .never, makeDatabase: { try HistoryDatabase(url: url, unpinnedLimit: 1) }, imageDirectory: directory) { event in
            if case .saved(let entry, _) = event { HistoryList.upsert(entry, into: &entries) }
            if case .remove(let id) = event { entries.removeAll { $0.id == id } }
        }
        store.collectImage(.data(ImageTestSupport.png(), typeIdentifier: "public.png"), source: .manual, at: Date(timeIntervalSince1970: 1))
        store.collect("new text", source: .manual, at: Date(timeIntervalSince1970: 2))
        drain(store)
        XCTAssertEqual(entries.map(\.text), ["new text"])
        XCTAssertTrue(try filenames(directory).isEmpty)
    }

    @MainActor
    func testDragProviderKeepsEvictedImageUntilProtectionExpires() throws {
        let root = try ImageTestSupport.directory(self)
        let directory = root.appendingPathComponent("images")
        let url = root.appendingPathComponent("history.sqlite")
        var now = Date(timeIntervalSince1970: 100)
        var entries: [HistoryEntry] = []
        let store = HistoryStore(retention: .never, makeDatabase: { try HistoryDatabase(url: url, unpinnedLimit: 1) },
                                 imageDirectory: directory, now: { now }) { event in
            if case .saved(let entry, _) = event { HistoryList.upsert(entry, into: &entries) }
            if case .remove(let id) = event { entries.removeAll { $0.id == id } }
            if case .cleanupFailed = event { XCTFail("Unexpected cleanup failure") }
        }
        let data = ImageTestSupport.png()
        store.collectImage(.data(data, typeIdentifier: "public.png"), source: .manual, at: now)
        drain(store)
        let image = try XCTUnwrap(entries.first?.image)
        // Creating the provider must register protection before subsequent mutations.
        let provider = HistoryImageLoader.rowProvider(image: image, store: store)
        store.collect("new text", source: .automatic, at: now.addingTimeInterval(1))
        drain(store)
        XCTAssertEqual(entries.map(\.text), ["new text"])
        XCTAssertEqual(try HistoryDatabase(url: url).fetchAll().map(\.text), ["new text"])
        XCTAssertEqual(try filenames(directory), image.filenames)

        now.addTimeInterval(HistoryStore.dragProtectionInterval - 1)
        drain(store)
        XCTAssertEqual(try filenames(directory), image.filenames)
        let loaded = expectation(description: "evicted image still provided to drag destination")
        provider.loadDataRepresentation(forTypeIdentifier: image.typeIdentifier) { original, error in
            XCTAssertNil(error)
            XCTAssertEqual(original, data)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)

        now.addTimeInterval(1)
        drain(store)
        XCTAssertTrue(try filenames(directory).isEmpty)
        XCTAssertEqual(entries.map(\.text), ["new text"])
    }

    @MainActor
    func testDragProtectionOutlastsUndoExpiryAndRepeatedDragExtendsDeadline() throws {
        let root = try ImageTestSupport.directory(self)
        let directory = root.appendingPathComponent("images")
        let url = root.appendingPathComponent("history.sqlite")
        var now = Date(timeIntervalSince1970: 100)
        var entry: HistoryEntry?
        let store = HistoryStore(retention: .never, makeDatabase: { try HistoryDatabase(url: url, now: { now }) },
                                 imageDirectory: directory, now: { now }) { event in
            if case .saved(let value, _) = event { entry = value }
            if case .cleanupFailed = event { XCTFail("Unexpected cleanup failure") }
        }
        store.collectImage(.data(ImageTestSupport.png(), typeIdentifier: "public.png"), source: .manual, at: now)
        drain(store)
        let original = try XCTUnwrap(entry)
        let image = try XCTUnwrap(original.image)
        store.protectImageForDrag(image)
        drain(store)
        now.addTimeInterval(10)
        store.protectImageForDrag(image)
        let deleted = expectation(description: "dragged image deleted")
        store.delete(id: original.id) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            deleted.fulfill()
        }
        wait(for: [deleted], timeout: 5)
        now.addTimeInterval(HistoryDatabase.undoInterval)
        drain(store)
        XCTAssertEqual(try filenames(directory), image.filenames)
        XCTAssertEqual(try HistoryDatabase(url: url, now: { now }).imageUsage(), HistoryImageUsage())

        now = Date(timeIntervalSince1970: 100).addingTimeInterval(HistoryStore.dragProtectionInterval)
        drain(store)
        XCTAssertEqual(try filenames(directory), image.filenames)
        now.addTimeInterval(10)
        drain(store)
        XCTAssertTrue(try filenames(directory).isEmpty)
    }

    @MainActor
    func testUndoMergeDiscardsRecollectedFilesAndKeepsOriginalFiles() throws {
        let root = try ImageTestSupport.directory(self)
        let directory = root.appendingPathComponent("images")
        let url = root.appendingPathComponent("history.sqlite")
        var saved: [HistoryEntry] = []
        let store = HistoryStore(retention: .never, makeDatabase: { try HistoryDatabase(url: url) }, imageDirectory: directory) { event in
            if case .saved(let value, _) = event { saved.append(value) }
        }
        let data = ImageTestSupport.png()
        store.collectImage(.data(data, typeIdentifier: "public.png"), source: .manual, at: Date())
        drain(store)
        let original = try XCTUnwrap(saved.first)
        var deletion: HistoryDeletion?
        let deleted = expectation(description: "deleted before recollect")
        store.delete(id: original.id) { result in
            switch result {
            case .success(let value): deletion = value
            case .failure(let error): XCTFail("\(error)")
            }
            deleted.fulfill()
        }
        wait(for: [deleted], timeout: 5)
        store.collectImage(.data(data, typeIdentifier: "public.png"), source: .drag, at: Date())
        drain(store)
        XCTAssertEqual(try filenames(directory).count, 4)
        let undone = expectation(description: "merged undo")
        store.undo(try XCTUnwrap(deletion)) { result in
            switch result {
            case .success(let value): XCTAssertTrue(value)
            case .failure(let error): XCTFail("\(error)")
            }
            undone.fulfill()
        }
        wait(for: [undone], timeout: 5)
        XCTAssertEqual(try filenames(directory), original.image?.filenames)
        let rows = try HistoryDatabase(url: url).fetchAll()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, original.id)
        XCTAssertEqual(rows.first?.collectionCount, 2)
    }
}
