import Foundation
import XCTest
@testable import ClipboardPlus

extension XCTestCase {
    func makeBackupTemporaryFiles(root: URL, label: String = "test.backup.cleanup") -> BackupTemporaryFiles {
        BackupTemporaryFiles(
            root: root.appendingPathComponent("ClipboardPlusBackup", isDirectory: true),
            cleanupQueue: DispatchQueue(label: label, qos: .userInitiated)
        )
    }

    func waitForBackupCleanup(_ files: BackupTemporaryFiles,
                              file: StaticString = #filePath, line: UInt = #line) {
        let done = DispatchSemaphore(value: 0)
        files.afterPendingCleanup { _ = done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 60), .success,
                       "backup cleanup completed", file: file, line: line)
    }
}

final class BackupTemporaryFilesTests: XCTestCase {
    @MainActor
    func testFirstLoadCleansPreviousProcessButPreservesCurrentWorkOnBackgroundQueue() throws {
        let root = try ImageTestSupport.directory(self)
        let worker = DispatchQueue(label: "test.backup.cleanup", qos: .userInitiated)
        let files = BackupTemporaryFiles(root: root.appendingPathComponent("ClipboardPlusBackup"), cleanupQueue: worker)
        let abandoned = files.root.appendingPathComponent("previous-process/restore", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data([1]).write(to: abandoned.appendingPathComponent("image.png"))
        let oldExport = files.root.appendingPathComponent("previous-process/export.clipboardplus")
        try Data([2]).write(to: oldExport)
        // Work can start before the first load. The entire current directory is protected.
        let currentExport = try files.makeExportURL()
        try Data([3]).write(to: currentExport)
        let currentRestore = files.processDirectory.appendingPathComponent("restore", isDirectory: true)
        try FileManager.default.createDirectory(at: currentRestore, withIntermediateDirectories: true)
        let currentImage = currentRestore.appendingPathComponent("image.png")
        try Data([4]).write(to: currentImage)
        let unrelated = root.appendingPathComponent("unrelated.tmp")
        try Data([5]).write(to: unrelated)

        worker.suspend()
        var resumed = false
        defer { if !resumed { worker.resume() } }
        let store = HistoryStore(retention: .never,
                                 makeDatabase: { try HistoryDatabase(url: root.appendingPathComponent("history.sqlite")) },
                                 imageDirectory: root.appendingPathComponent("images"), backupTemporaryFiles: files) { _ in }
        let loaded = expectation(description: "load does not wait for cleanup")
        store.load { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldExport.path))
        worker.resume()
        resumed = true
        waitForBackupCleanup(files)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldExport.path))
        XCTAssertEqual(try Data(contentsOf: currentExport), Data([3]))
        XCTAssertEqual(try Data(contentsOf: currentImage), Data([4]))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([5]))
        // Multiple stores / cleanup requests within this process use the same identity.
        let second = BackupTemporaryFiles(root: files.root)
        XCTAssertEqual(second.processDirectory, files.processDirectory)
        second.cleanPreviousProcesses()
        waitForBackupCleanup(second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentImage.path))
    }

    @MainActor
    func testDiscardOnlySchedulesDeletionAndIsSafeToRepeat() throws {
        let root = try ImageTestSupport.directory(self)
        let worker = DispatchQueue(label: "test.backup.discard", qos: .userInitiated)
        let files = BackupTemporaryFiles(root: root, cleanupQueue: worker)
        let directory = files.processDirectory.appendingPathComponent("restore", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("image.png")
        try Data([1]).write(to: image)
        var backup: ValidatedBackup? = ValidatedBackup(directory: directory, entries: [], temporaryFiles: files)
        weak var released = backup
        worker.suspend()
        var resumed = false
        defer { if !resumed { worker.resume() } }
        backup?.discard()
        backup?.discard()
        backup = nil // deinit must neither block nor enqueue a job retaining self.
        XCTAssertNil(released)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        worker.resume()
        resumed = true
        waitForBackupCleanup(files)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testDeinitWithoutDiscardAlsoSchedulesDeletion() throws {
        let root = try ImageTestSupport.directory(self)
        let worker = DispatchQueue(label: "test.backup.deinit", qos: .userInitiated)
        let files = BackupTemporaryFiles(root: root, cleanupQueue: worker)
        let directory = files.processDirectory.appendingPathComponent("restore", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var backup: ValidatedBackup? = ValidatedBackup(directory: directory, entries: [], temporaryFiles: files)
        weak var released = backup
        worker.suspend()
        var resumed = false
        defer { if !resumed { worker.resume() } }
        backup = nil
        XCTAssertNil(released)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        worker.resume()
        resumed = true
        waitForBackupCleanup(files)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testStoreCreatesAndValidatesInsideCurrentProcessDirectory() throws {
        let root = try ImageTestSupport.directory(self)
        let files = BackupTemporaryFiles(root: root.appendingPathComponent("ClipboardPlusBackup"))
        let store = HistoryStore(retention: .never,
                                 makeDatabase: { try HistoryDatabase(url: root.appendingPathComponent("history.sqlite")) },
                                 imageDirectory: root.appendingPathComponent("images"), backupTemporaryFiles: files) { _ in }
        store.collect("backup", source: .manual, at: Date())
        var snapshot: BackupExport?
        let created = expectation(description: "created")
        store.createBackup(cancellation: BackupCancellation(), progress: { _ in }) { result in
            if case .success(let value) = result { snapshot = value }
            if case .failure(let error) = result { XCTFail("\(error)") }
            created.fulfill()
        }
        wait(for: [created], timeout: 5)
        let export = try XCTUnwrap(snapshot)
        XCTAssertEqual(export.url.deletingLastPathComponent().standardizedFileURL, files.processDirectory.standardizedFileURL)
        var prepared: ValidatedBackup?
        let validated = expectation(description: "validated")
        store.validateBackup(at: export.url, cancellation: BackupCancellation(), progress: { _ in }) { result in
            if case .success(let (backup, _)) = result { prepared = backup }
            if case .failure(let error) = result { XCTFail("\(error)") }
            validated.fulfill()
        }
        wait(for: [validated], timeout: 5)
        let backup = try XCTUnwrap(prepared)
        XCTAssertEqual(backup.directory.deletingLastPathComponent().standardizedFileURL, files.processDirectory.standardizedFileURL)
        backup.discard()
        files.remove(export.url)
        waitForBackupCleanup(files)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.url.path))
    }
}
