import Foundation
import UIKit
import XCTest
@testable import ClipboardPlus

final class HistoryRetentionTests: XCTestCase {
    private let day: TimeInterval = 86_400

    @MainActor
    private func complete<T>(_ operation: (@escaping @MainActor (Result<T, Error>) -> Void) -> Void) {
        let done = expectation(description: "storage operation")
        operation { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testSettingsDefaultRoundTripAndInvalidValue() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(HistoryRetention.load(from: defaults), .thirtyDays)
        XCTAssertEqual(HistoryRetention.allCases.map(\.displayName), ["しない", "1日", "7日", "30日", "90日"])
        for value in HistoryRetention.allCases {
            value.save(to: defaults)
            XCTAssertEqual(HistoryRetention.load(from: defaults), value)
            XCTAssertEqual(value.seconds, value == .never ? nil : Double(value.rawValue) * day)
        }
        defaults.set(2, forKey: HistoryRetention.defaultsKey)
        XCTAssertEqual(HistoryRetention.load(from: defaults), .thirtyDays)
        defaults.set("invalid", forKey: HistoryRetention.defaultsKey)
        XCTAssertEqual(HistoryRetention.load(from: defaults), .thirtyDays)
    }

    func testDatabaseUsesStrictCutoffLastCollectionAndKeepsPins() throws {
        let root = try ImageTestSupport.directory(self)
        let now = Date(timeIntervalSince1970: 100 * day)
        let database = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"), now: { now })
        let cutoff = now.addingTimeInterval(-30 * day)
        let old = try database.collect("expired", source: .manual, at: cutoff.addingTimeInterval(-1))
        let url = try database.collect("https://example.com/expired", source: .manual, at: cutoff.addingTimeInterval(-1))
        let pin = try database.collect("pin", source: .manual, at: cutoff.addingTimeInterval(-1))
        try database.moveToTemplates(id: pin.id)
        let boundary = try database.collect("boundary", source: .manual, at: cutoff)
        let fresh = try database.collect("fresh", source: .manual, at: now)
        let recollected = try database.collect("recollected", source: .manual, at: cutoff.addingTimeInterval(-1))
        try database.collect(recollected.text, source: .automatic, at: now)
        XCTAssertEqual(try database.purgeHistory(olderThan: .thirtyDays), 2)
        XCTAssertEqual(Set(database.takeRemovals().map(\.id)), [old.id, url.id])
        XCTAssertEqual(Set(try database.fetchAll().map(\.id)), [pin.id, boundary.id, fresh.id, recollected.id])
        XCTAssertEqual(try database.purgeHistory(olderThan: .thirtyDays), 0)
        XCTAssertTrue(database.takeRemovals().isEmpty)
    }

    @MainActor
    func testLoadRemovesExpiredTextAndImagesAndUpdatesListAndUsage() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let files = HistoryImageFiles(directory: root.appendingPathComponent("images"))
        let oldImage = try ImageTestSupport.prepare(files)
        let pinnedImage = try ImageTestSupport.prepare(files, color: .blue)
        let recentImage = try ImageTestSupport.prepare(files, color: .green)
        let now = Date(timeIntervalSince1970: 100 * day)
        let old = now.addingTimeInterval(-31 * day)
        do {
            let database = try HistoryDatabase(url: url, now: { now })
            try database.collect("expired text", source: .manual, at: old)
            try database.collectImage(oldImage, source: .manual, at: old)
            let pin = try database.collectImage(pinnedImage, source: .manual, at: old)
            try database.moveToTemplates(id: pin.id)
            try database.collectImage(recentImage, source: .manual, at: now)
        }
        var entries: [HistoryEntry] = []
        var usage = HistoryImageUsage()
        var deleted: [Int] = []
        let store = HistoryStore(makeDatabase: { try HistoryDatabase(url: url, now: { now }) },
                                 imageDirectory: files.directory, now: { now }) { event in
            switch event {
            case .replace(let values): entries = values
            case .remove(let id): entries.removeAll { $0.id == id }
            case .imageUsage(let value): usage = value
            case .automaticallyDeleted(let count, let period):
                XCTAssertEqual(period, .thirtyDays)
                deleted.append(count)
            default: break
            }
        }
        complete { store.load(completion: $0) }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.compactMap { $0.image?.hash }), [pinnedImage.hash, recentImage.hash])
        XCTAssertEqual(usage.count, 2)
        XCTAssertEqual(usage.byteCount, pinnedImage.byteCount + recentImage.byteCount)
        XCTAssertEqual(deleted, [2])
        for name in oldImage.filenames { XCTAssertFalse(FileManager.default.fileExists(atPath: files.url(for: name).path)) }
        for name in pinnedImage.filenames.union(recentImage.filenames) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: files.url(for: name).path))
        }
        complete { store.maintain(completion: $0) }
        XCTAssertEqual(deleted, [2]) // Zero deletions do not emit a log event.
    }

    @MainActor
    func testNeverKeepsHistoryAndShorteningImmediatelyRemovesIt() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let now = Date(timeIntervalSince1970: 100 * day)
        var entries: [HistoryEntry] = []
        var counts: [Int] = []
        let store = HistoryStore(retention: .never, makeDatabase: { try HistoryDatabase(url: url, now: { now }) },
                                 imageDirectory: root.appendingPathComponent("images"), now: { now }) { event in
            switch event {
            case .replace(let values): entries = values
            case .saved(let value, _): HistoryList.upsert(value, into: &entries)
            case .remove(let id): entries.removeAll { $0.id == id }
            case .automaticallyDeleted(let count, _): counts.append(count)
            default: break
            }
        }
        store.collect("old", source: .manual, at: now.addingTimeInterval(-60 * day))
        store.collect("week", source: .manual, at: now.addingTimeInterval(-8 * day))
        store.collect("fresh", source: .manual, at: now)
        complete { store.load(completion: $0) }
        complete { store.maintain(forceRetention: true, completion: $0) }
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(counts.isEmpty)
        complete { store.setRetention(.thirtyDays, completion: $0) }
        XCTAssertEqual(entries.count, 2)
        complete { store.setRetention(.sevenDays, completion: $0) }
        XCTAssertEqual(entries.map(\.text), ["fresh"])
        XCTAssertEqual(counts, [1, 1])
    }

    @MainActor
    func testUndoPendingImageKeepsFilesUntilItsOwnDeadline() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let files = HistoryImageFiles(directory: root.appendingPathComponent("images"))
        let image = try ImageTestSupport.prepare(files)
        var now = Date(timeIntervalSince1970: 100 * day)
        let deletion: HistoryDeletion
        do {
            let database = try HistoryDatabase(url: url, now: { now })
            let entry = try database.collectImage(image, source: .manual, at: now.addingTimeInterval(-31 * day))
            deletion = try XCTUnwrap(database.delete(id: entry.id))
            XCTAssertEqual(try database.purgeHistory(olderThan: .oneDay), 0)
            XCTAssertTrue(database.takeRemovals().isEmpty)
        }
        var usage = HistoryImageUsage()
        let store = HistoryStore(makeDatabase: { try HistoryDatabase(url: url, now: { now }) },
                                 imageDirectory: files.directory, now: { now }) { event in
            if case .imageUsage(let value) = event { usage = value }
            if case .automaticallyDeleted = event { XCTFail("Undo expiry is not age deletion") }
        }
        complete { store.load(completion: $0) }
        now = deletion.expiresAt.addingTimeInterval(-1)
        complete { store.maintain(forceRetention: true, completion: $0) }
        XCTAssertEqual(usage.count, 1)
        for name in image.filenames { XCTAssertTrue(FileManager.default.fileExists(atPath: files.url(for: name).path)) }
        now = deletion.expiresAt
        complete { store.maintain(completion: $0) }
        XCTAssertEqual(usage.count, 0)
        for name in image.filenames { XCTAssertFalse(FileManager.default.fileExists(atPath: files.url(for: name).path)) }
    }

    @MainActor
    func testHourlyCheckUsesElapsedTimeAndForegroundCanForceIt() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        var now = Date(timeIntervalSince1970: 100 * day)
        var entries: [HistoryEntry] = []
        let store = HistoryStore(retention: .oneDay, makeDatabase: { try HistoryDatabase(url: url, now: { now }) },
                                 imageDirectory: root.appendingPathComponent("images"), now: { now }) { event in
            switch event {
            case .replace(let values): entries = values
            case .saved(let value, _): HistoryList.upsert(value, into: &entries)
            case .remove(let id): entries.removeAll { $0.id == id }
            default: break
            }
        }
        store.collect("boundary", source: .manual, at: now.addingTimeInterval(-day))
        complete { store.load(completion: $0) }
        now.addTimeInterval(3_599)
        complete { store.maintain(completion: $0) }
        XCTAssertEqual(entries.count, 1)
        now.addTimeInterval(1)
        complete { store.maintain(completion: $0) }
        XCTAssertTrue(entries.isEmpty)
        store.collect("second boundary", source: .manual, at: now.addingTimeInterval(-day))
        complete { store.maintain(completion: $0) }
        now.addTimeInterval(3_599)
        complete { store.maintain(completion: $0) }
        XCTAssertEqual(entries.count, 1)
        now.addTimeInterval(1)
        complete { store.maintain(completion: $0) }
        XCTAssertTrue(entries.isEmpty)
        store.collect("foreground", source: .manual, at: now.addingTimeInterval(-day - 1))
        complete { store.maintain(completion: $0) }
        XCTAssertEqual(entries.count, 1)
        complete { store.maintain(forceRetention: true, completion: $0) }
        XCTAssertTrue(entries.isEmpty)
    }

    func testRestoreEstimatesAgeAfterMergeBeforeCapsAndRollsBackRemovals() throws {
        let root = try ImageTestSupport.directory(self)
        let now = Date(timeIntervalSince1970: 100 * day)
        let cutoff = now.addingTimeInterval(-day)
        let database = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"), now: { now }, historyLimit: 2)
        let old = cutoff.addingTimeInterval(-1)
        try database.collect("newer wins", source: .automatic, at: now)
        let undo = try database.collect("undo", source: .manual, at: old)
        _ = try database.delete(id: undo.id)
        let incoming = [
            text("expired", at: old), text("newer wins", at: old), text("pin", at: old, pinned: true),
            text("recent", at: now.addingTimeInterval(1)), text("newest", at: now.addingTimeInterval(2))
        ]
        let before = try database.fetchAll()
        let estimate = try database.estimateBackup(incoming, retentionCutoff: cutoff)
        XCTAssertEqual(estimate.removedByRetention, 1)
        XCTAssertEqual(estimate.removedByLimit, 1)
        XCTAssertEqual(try database.fetchAll(), before)
        XCTAssertThrowsError(try database.mergeBackup(incoming, retentionCutoff: cutoff) { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        XCTAssertEqual(try database.fetchAll(), before)
        XCTAssertTrue(database.takeRemovals().isEmpty)
        let actual = try database.mergeBackup(incoming, retentionCutoff: cutoff) { _ in }
        XCTAssertEqual(actual, estimate)
        let removals = database.takeRemovals()
        XCTAssertEqual(removals.filter { !$0.isTemplate && $0.lastCollectedAt < cutoff }.count, estimate.removedByRetention)
        XCTAssertEqual(removals.count, estimate.removedByRetention + estimate.removedByLimit)
        XCTAssertEqual(Set(try database.fetchAll().map(\.text)), ["pin", "recent", "newest"])
        XCTAssertNotNil(try database.latestDeletion())
    }

    @MainActor
    func testBackupEstimateMatchesAppliedAgeDeletionsAndCleansImages() throws {
        let root = try ImageTestSupport.directory(self)
        let now = Date(timeIntervalSince1970: 100 * day)
        let old = now.addingTimeInterval(-31 * day)
        let sourceFiles = HistoryImageFiles(directory: root.appendingPathComponent("sourceImages"))
        let image = try ImageTestSupport.prepare(sourceFiles)
        let source = try HistoryDatabase(url: root.appendingPathComponent("source.sqlite"), now: { now })
        try source.collect("expired incoming", source: .manual, at: old)
        try source.collectImage(image, source: .manual, at: old)
        try source.collect("new incoming", source: .manual, at: now)
        let archive = root.appendingPathComponent("test.clipboardplus")
        _ = try HistoryBackup.write(entries: source.fetchAll(), files: sourceFiles, to: archive, cancellation: BackupCancellation())
        let url = root.appendingPathComponent("target.sqlite")
        let files = HistoryImageFiles(directory: root.appendingPathComponent("targetImages"))
        let targetImage = try ImageTestSupport.prepare(files, color: .blue)
        var replacement: [HistoryEntry] = []
        var deleted: [Int] = []
        var usage = HistoryImageUsage()
        let store = HistoryStore(makeDatabase: { try HistoryDatabase(url: url, now: { now }) },
                                 imageDirectory: files.directory, now: { now }) { event in
            if case .replace(let values) = event { replacement = values }
            if case .automaticallyDeleted(let count, _) = event { deleted.append(count) }
            if case .imageUsage(let value) = event { usage = value }
        }
        do {
            let database = try HistoryDatabase(url: url, now: { now })
            try database.collectImage(targetImage, source: .manual, at: now)
        }
        complete { store.load(completion: $0) }
        // Age the row after startup so restore itself performs the deletion.
        try ImageTestSupport.sql("UPDATE history SET saved_at = \(old.timeIntervalSince1970), collected_at = \(old.timeIntervalSince1970)", at: url)
        var prepared: ValidatedBackup?
        var estimate: RestoreCounts?
        let validated = expectation(description: "age estimate")
        store.validateBackup(at: archive, cancellation: BackupCancellation(), progress: { _ in }) { result in
            if case .success(let (backup, counts)) = result { prepared = backup; estimate = counts }
            if case .failure(let error) = result { XCTFail("\(error)") }
            validated.fulfill()
        }
        wait(for: [validated], timeout: 10)
        let backup = try XCTUnwrap(prepared)
        let expected = try XCTUnwrap(estimate)
        XCTAssertEqual(expected.removedByRetention, 3)
        XCTAssertEqual(expected.removedByLimit, 0)
        XCTAssertEqual(try HistoryDatabase(url: url, now: { now }).fetchAll().count, 1)
        for name in targetImage.filenames { XCTAssertTrue(FileManager.default.fileExists(atPath: files.url(for: name).path)) }
        let applied = expectation(description: "age restore")
        store.restoreBackup(backup, cancellation: BackupCancellation(), expectedCounts: expected, progress: { _ in }) { result in
            if case .success(let actual) = result { XCTAssertEqual(actual, expected) }
            if case .failure(let error) = result { XCTFail("\(error)") }
            applied.fulfill()
        }
        wait(for: [applied], timeout: 10)
        XCTAssertEqual(deleted, [expected.removedByRetention])
        XCTAssertEqual(replacement.map(\.text), ["new incoming"])
        XCTAssertEqual(usage.count, 0)
        XCTAssertEqual(usage.byteCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: files.directory.path), [])
        waitForBackupCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.directory.path))
    }

    @MainActor
    func testChangedEstimateRequiresConfirmationAndKeepsValidatedBackupForRetry() throws {
        let root = try ImageTestSupport.directory(self)
        var now = Date(timeIntervalSince1970: 100 * day)
        let originalDate = now
        let entries = [text("crosses boundary", at: now.addingTimeInterval(-day))]
        let archive = root.appendingPathComponent("test.clipboardplus")
        _ = try HistoryBackup.write(entries: entries, files: HistoryImageFiles(directory: root),
                                    to: archive, cancellation: BackupCancellation())
        let backup = try HistoryBackup.validate(at: archive, temporaryRoot: root, cancellation: BackupCancellation())
        let url = root.appendingPathComponent("target.sqlite")
        let store = HistoryStore(retention: .oneDay, makeDatabase: { try HistoryDatabase(url: url, now: { now }) },
                                 imageDirectory: root.appendingPathComponent("images"), now: { now }) { _ in }
        complete { store.load(completion: $0) }
        let expected = try HistoryDatabase(url: url, now: { now }).estimateBackup(
            backup.entries, retentionCutoff: HistoryRetention.oneDay.cutoff(relativeTo: originalDate))
        XCTAssertEqual(expected.removedByRetention, 0)
        now.addTimeInterval(1)
        var revised: RestoreCounts?
        let rejected = expectation(description: "requires renewed confirmation")
        store.restoreBackup(backup, cancellation: BackupCancellation(), expectedCounts: expected, progress: { _ in }) { result in
            if case .success = result { XCTFail("Unconfirmed counts must not be applied") }
            if case .failure(let error) = result {
                if let changed = error as? RestoreEstimateChanged { revised = changed.counts }
                else { XCTFail("\(error)") }
            }
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 5)
        XCTAssertTrue(try HistoryDatabase(url: url, now: { now }).fetchAll().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.directory.path))
        let confirmed = try XCTUnwrap(revised)
        XCTAssertEqual(confirmed.removedByRetention, 1)
        let restored = expectation(description: "confirmed revised estimate")
        store.restoreBackup(backup, cancellation: BackupCancellation(), expectedCounts: confirmed, progress: { _ in }) { result in
            if case .success(let actual) = result { XCTAssertEqual(actual, confirmed) }
            if case .failure(let error) = result { XCTFail("\(error)") }
            restored.fulfill()
        }
        wait(for: [restored], timeout: 5)
        waitForBackupCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.directory.path))
    }

    @MainActor
    func testMonitorLoadsAndPersistsPolicyLogsCountsAndRunsOnActiveScene() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        HistoryRetention.never.save(to: defaults)
        let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: root.appendingPathComponent("log.tsv")))
        log.includeTextPreview = true
        let secret = "retention-content-must-not-be-logged"
        do {
            let database = try HistoryDatabase(url: url)
            try database.collect(secret, source: .manual, at: Date().addingTimeInterval(-31 * day))
        }
        let monitor = ClipboardMonitor(defaults: defaults, log: log, makeDatabase: { try HistoryDatabase(url: url) },
                                       schedulesMaintenance: false, imageDirectory: root.appendingPathComponent("images"))
        drain(monitor)
        XCTAssertEqual(monitor.historyRetention, .never)
        XCTAssertEqual(monitor.entries.count, 1)
        monitor.setHistoryRetention(.thirtyDays)
        drain(monitor)
        XCTAssertTrue(monitor.entries.isEmpty)
        XCTAssertEqual(HistoryRetention.load(from: defaults), .thirtyDays)
        let records = log.lines.map(\.fileLine).joined(separator: "\n")
        XCTAssertTrue(records.contains("期限による自動削除"))
        XCTAssertTrue(records.contains("件数=1; 日数=30"))
        XCTAssertFalse(records.contains(secret))
        // A new old row after the previous check survives until a forced scene check.
        monitor.saveManually(["foreground test"], receivedAt: Date().addingTimeInterval(-31 * day))
        drain(monitor)
        XCTAssertEqual(monitor.entries.count, 1)
        monitor.updateScene("active")
        drain(monitor)
        XCTAssertTrue(monitor.entries.isEmpty)
    }

    func testRestoreNewerTimestampAndMergedPinProtectExpiredExistingRows() throws {
        let root = try ImageTestSupport.directory(self)
        let now = Date(timeIntervalSince1970: 100 * day)
        let old = now.addingTimeInterval(-31 * day)
        let database = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"), now: { now })
        try database.collect("rescued by collection", source: .manual, at: old)
        try database.collect("rescued by pin", source: .manual, at: old)
        let incoming = [text("rescued by collection", at: now), text("rescued by pin", at: old, pinned: true)]
        let cutoff = HistoryRetention.thirtyDays.cutoff(relativeTo: now)
        let estimate = try database.estimateBackup(incoming, retentionCutoff: cutoff)
        XCTAssertEqual(estimate, RestoreCounts(updated: 2))
        XCTAssertEqual(try database.mergeBackup(incoming, retentionCutoff: cutoff) { _ in }, estimate)
        XCTAssertEqual(try database.fetchAll().count, 2)
        XCTAssertEqual(try database.purgeHistory(olderThan: .thirtyDays), 0)
    }

    @MainActor
    func testFailedAgeDeletionRollsBackAndNextMaintenanceRetriesImmediately() throws {
        let root = try ImageTestSupport.directory(self)
        let url = root.appendingPathComponent("history.sqlite")
        let now = Date(timeIntervalSince1970: 100 * day)
        do {
            let database = try HistoryDatabase(url: url, now: { now })
            try database.collect("expired", source: .manual, at: now.addingTimeInterval(-31 * day))
        }
        try ImageTestSupport.sql("CREATE TRIGGER fail_age_delete BEFORE DELETE ON history BEGIN SELECT RAISE(ABORT, 'test failure'); END;", at: url)
        var deletions = 0
        let store = HistoryStore(makeDatabase: { try HistoryDatabase(url: url, now: { now }) },
                                 imageDirectory: root.appendingPathComponent("images"), now: { now }) { event in
            if case .automaticallyDeleted(let count, _) = event { deletions += count }
        }
        let failed = expectation(description: "age deletion failed")
        store.maintain { result in
            if case .success = result { XCTFail("Injected deletion failure must propagate") }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 5)
        XCTAssertEqual(deletions, 0)
        XCTAssertEqual(try HistoryDatabase(url: url, now: { now }).fetchAll().count, 1)
        try ImageTestSupport.sql("DROP TRIGGER fail_age_delete", at: url)
        complete { store.maintain(completion: $0) }
        XCTAssertEqual(deletions, 1)
        XCTAssertTrue(try HistoryDatabase(url: url, now: { now }).fetchAll().isEmpty)
    }

    @MainActor
    private func drain(_ monitor: ClipboardMonitor) {
        let done = expectation(description: "monitor drained")
        monitor.pendingDeletion { _ in
            monitor.log.flush(context: monitor.logContext()) { done.fulfill() }
        }
        wait(for: [done], timeout: 5)
        XCTAssertNil(monitor.storageError)
    }

    private func text(_ value: String, at date: Date, pinned: Bool = false) -> HistoryEntry {
        HistoryEntry(id: 0, kind: .text, text: value, savedAt: date, lastCollectedAt: date,
                     collectionCount: 1, isTemplate: pinned, source: .manual)
    }
}
