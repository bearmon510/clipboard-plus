import Foundation
import Combine
import UIKit
import XCTest
@testable import ClipboardPlus

final class BackupStoreTests: XCTestCase {
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
    func testSnapshotExcludesUndoPendingAndProtectsEvictedImageWhileCollectionContinues() throws {
        let root = try ImageTestSupport.directory(self)
        let databaseURL = root.appendingPathComponent("history.sqlite")
        let imageDirectory = root.appendingPathComponent("images")
        let worker = DispatchQueue(label: "test.backup")
        var entries: [HistoryEntry] = []
        let store = HistoryStore(retention: .never, makeDatabase: { try HistoryDatabase(url: databaseURL, unpinnedLimit: 1) },
                                 imageDirectory: imageDirectory, backupQueue: worker) { event in
            if case .saved(let entry, _) = event { entries.append(entry) }
        }
        store.collect("undo pending", source: .manual, at: Date(timeIntervalSince1970: 1))
        drain(store)
        let old = try XCTUnwrap(entries.first)
        let deleted = expectation(description: "deleted")
        store.delete(id: old.id) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            deleted.fulfill()
        }
        wait(for: [deleted], timeout: 5)
        store.collectImage(.data(ImageTestSupport.png(), typeIdentifier: "public.png"), source: .drag,
                           at: Date(timeIntervalSince1970: 2))
        drain(store)
        let image = try XCTUnwrap(entries.last?.image)
        // Delay I/O deterministically, without blocking the store's collection queue.
        worker.suspend()
        var resumed = false
        defer { if !resumed { worker.resume() } }
        var export: BackupExport?
        let created = expectation(description: "created")
        store.createBackup(cancellation: BackupCancellation(), progress: { _ in }) { result in
            if case .success(let value) = result { export = value }
            if case .failure(let error) = result { XCTFail("\(error)") }
            created.fulfill()
        }
        drain(store) // The snapshot and protection have been registered.
        store.collect("new collection", source: .automatic, at: Date(timeIntervalSince1970: 3))
        drain(store)
        XCTAssertEqual(entries.last?.text, "new collection")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageFiles.url(for: image.filename).path))
        worker.resume()
        resumed = true
        wait(for: [created], timeout: 10)
        let snapshot = try XCTUnwrap(export)
        defer { try? FileManager.default.removeItem(at: snapshot.url) }
        let backup = try HistoryBackup.validate(at: snapshot.url, temporaryRoot: root, cancellation: BackupCancellation())
        XCTAssertEqual(backup.entries.count, 1)
        XCTAssertEqual(backup.entries.first?.image?.hash, image.hash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageFiles.url(for: image.filename).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageFiles.url(for: image.thumbnailFilename).path))
    }

    @MainActor
    func testApplyReestimatesAfterCollectionAndReplacesTheVisibleListAndCleansLimitImages() throws {
        let root = try ImageTestSupport.directory(self)
        let originalFiles = HistoryImageFiles(directory: root.appendingPathComponent("originals"))
        let image = try ImageTestSupport.prepare(originalFiles)
        let source = try HistoryDatabase(url: root.appendingPathComponent("source.sqlite"))
        try source.collect("duplicate", source: .manual, at: Date(timeIntervalSince1970: 10))
        try source.collectImage(image, source: .drag, at: Date(timeIntervalSince1970: 11))
        let url = root.appendingPathComponent("test.clipboardplus")
        _ = try HistoryBackup.write(entries: source.fetchAll(), files: originalFiles, to: url, cancellation: BackupCancellation())
        let databaseURL = root.appendingPathComponent("target.sqlite")
        var replacement: [HistoryEntry] = []
        let store = HistoryStore(retention: .never, makeDatabase: { try HistoryDatabase(url: databaseURL, unpinnedLimit: 2) },
                                 imageDirectory: root.appendingPathComponent("targetImages")) { event in
            if case .replace(let entries) = event { replacement = entries }
        }
        store.collectImage(.data(ImageTestSupport.png(.blue), typeIdentifier: "public.png"), source: .manual,
                           at: Date(timeIntervalSince1970: 1))
        drain(store)
        let oldNames = try FileManager.default.contentsOfDirectory(atPath: store.imageFiles.directory.path)
        let validated = expectation(description: "validated")
        var prepared: ValidatedBackup?
        var estimate: RestoreCounts?
        store.validateBackup(at: url, cancellation: BackupCancellation(), progress: { _ in }) { result in
            if case .success(let (backup, counts)) = result { prepared = backup; estimate = counts }
            if case .failure(let error) = result { XCTFail("\(error)") }
            validated.fulfill()
        }
        wait(for: [validated], timeout: 10)
        let backup = try XCTUnwrap(prepared)
        XCTAssertEqual(estimate, RestoreCounts(added: 2, removedByLimit: 1))
        // Validation left the original directory and DB intact.
        XCTAssertEqual(try HistoryDatabase(url: databaseURL).fetchAll().count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.imageFiles.directory.path).sorted(), oldNames.sorted())
        store.collect("duplicate", source: .automatic, at: Date(timeIntervalSince1970: 20))
        drain(store)
        let applied = expectation(description: "applied")
        var actual: RestoreCounts?
        store.restoreBackup(backup, cancellation: BackupCancellation(), progress: { _ in }) { result in
            if case .success(let counts) = result { actual = counts }
            if case .failure(let error) = result { XCTFail("\(error)") }
            applied.fulfill()
        }
        wait(for: [applied], timeout: 10)
        XCTAssertEqual(actual, RestoreCounts(added: 1, updated: 1, removedByLimit: 1))
        XCTAssertEqual(replacement.count, 2)
        XCTAssertEqual(replacement.first?.source, .automatic)
        XCTAssertEqual(replacement.last?.image?.hash, image.hash)
        for name in oldNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageFiles.url(for: name).path))
        }
        waitForBackupCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.directory.path))
    }

    @MainActor
    func testCancelledSnapshotReleasesProtectionAndLeavesNoExport() throws {
        let root = try ImageTestSupport.directory(self)
        let worker = DispatchQueue(label: "test.cancel.backup")
        let databaseURL = root.appendingPathComponent("history.sqlite")
        let store = HistoryStore(retention: .never, makeDatabase: { try HistoryDatabase(url: databaseURL, unpinnedLimit: 1) },
                                 imageDirectory: root.appendingPathComponent("images"), backupQueue: worker) { _ in }
        store.collectImage(.data(ImageTestSupport.png(), typeIdentifier: "public.png"), source: .manual, at: Date())
        drain(store)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.imageFiles.directory.path)
        worker.suspend()
        var resumed = false
        defer { if !resumed { worker.resume() } }
        let token = BackupCancellation()
        let done = expectation(description: "cancelled")
        store.createBackup(cancellation: token, progress: { _ in }) { result in
            if case .success(let export) = result {
                try? FileManager.default.removeItem(at: export.url)
                XCTFail("Cancelled export unexpectedly succeeded")
            }
            done.fulfill()
        }
        drain(store)
        store.collect("new", source: .manual, at: Date().addingTimeInterval(1))
        drain(store)
        token.cancel()
        worker.resume()
        resumed = true
        wait(for: [done], timeout: 10)
        for name in names {
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageFiles.url(for: name).path))
        }
    }

    @MainActor
    func testControllerCleansSharedFileAndLogsCountsWithoutContentsOrProviderPaths() throws {
        let root = try ImageTestSupport.directory(self)
        let databaseURL = root.appendingPathComponent("history.sqlite")
        let store = HistoryStore(retention: .never, makeDatabase: { try HistoryDatabase(url: databaseURL) },
                                 imageDirectory: root.appendingPathComponent("images")) { _ in }
        let secret = "backup-test-original-not-for-log"
        store.collect(secret, source: .manual, at: Date())
        drain(store)
        var records: [String] = []
        var remembered: BackupExport?
        let controller = BackupController(store: store, record: { records.append($0 + ":" + $1) }, remember: { remembered = $0 })
        let done = expectation(description: "shared file ready")
        let subscription = controller.$export.compactMap { $0 }.first().sink { _ in done.fulfill() }
        defer { subscription.cancel() }
        controller.create()
        wait(for: [done], timeout: 10)
        let snapshot = try XCTUnwrap(remembered)
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.url.path))
        XCTAssertFalse(records.joined().contains(secret))
        XCTAssertTrue(records.contains { $0.contains("開始") })
        XCTAssertTrue(records.contains { $0.contains("完了") && $0.contains("件数=1") })
        controller.removeExport() // Shared sheet's onDismiss.
        waitForBackupCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.url.path))
        let providerSecret = "private-provider-file-name"
        controller.importFailed(NSError(domain: "provider", code: 1, userInfo: [NSLocalizedDescriptionKey: providerSecret]))
        XCTAssertFalse(records.joined().contains(providerSecret))
        XCTAssertFalse(controller.errorMessage?.contains(providerSecret) == true)
    }
}
