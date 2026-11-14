import Foundation
import XCTest
@testable import ClipboardPlus

final class HistoryStoreTests: XCTestCase {
    private final class DatabaseSpy: HistoryPersistence {
        let database: HistoryDatabase
        var failedAttempts: Set<Int> = []
        var attempts: [String] = []
        var fetchCount = 0
        var beforeCollect: (() -> Void)?

        init(url: URL, now: @escaping () -> Date = Date.init) throws {
            XCTAssertFalse(Thread.isMainThread)
            database = try HistoryDatabase(url: url, now: now)
        }

        func collect(_ text: String, source: HistorySource, at date: Date?) throws -> HistoryEntry {
            XCTAssertFalse(Thread.isMainThread)
            attempts.append(text)
            beforeCollect?()
            if failedAttempts.contains(attempts.count) { throw CocoaError(.fileWriteOutOfSpace) }
            return try database.collect(text, source: source, at: date)
        }

        func fetchAll() throws -> [HistoryEntry] {
            XCTAssertFalse(Thread.isMainThread)
            fetchCount += 1
            return try database.fetchAll()
        }

        func togglePin(id: Int) throws -> HistoryEntry? {
            XCTAssertFalse(Thread.isMainThread)
            return try database.togglePin(id: id)
        }

        func delete(id: Int) throws -> HistoryDeletion? {
            XCTAssertFalse(Thread.isMainThread)
            return try database.delete(id: id)
        }

        func deleteAll(includePinned: Bool) throws -> HistoryDeletion? {
            XCTAssertFalse(Thread.isMainThread)
            return try database.deleteAll(includePinned: includePinned)
        }

        func undo(_ deletion: HistoryDeletion) throws -> Bool {
            XCTAssertFalse(Thread.isMainThread)
            return try database.undo(deletion)
        }

        func purgeExpired() throws -> Bool {
            XCTAssertFalse(Thread.isMainThread)
            return try database.purgeExpired()
        }

        func latestDeletion() throws -> HistoryDeletion? {
            XCTAssertFalse(Thread.isMainThread)
            return try database.latestDeletion()
        }
    }

    private func databaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("history.sqlite")
    }

    @MainActor
    func testFailedCollectionsRemainPendingAndPeriodicMaintenanceRetriesInOrder() throws {
        let url = try databaseURL()
        var spy: DatabaseSpy?
        var failures = 0
        var saved: [HistoryEntry] = []
        var retries: [Bool] = []
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = firstDate.addingTimeInterval(1)
        let done = expectation(description: "retried in order")
        let store = HistoryStore(makeDatabase: {
            let database = try DatabaseSpy(url: url)
            database.failedAttempts = [1, 2]
            spy = database
            return database
        }) { event in
            XCTAssertTrue(Thread.isMainThread)
            switch event {
            case .saveFailed:
                failures += 1
                XCTAssertTrue(saved.isEmpty)
            case .saved(let entry, let retried): saved.append(entry); retries.append(retried)
            default: break
            }
        }
        store.collect("A", source: .automatic, at: firstDate)
        store.collect("B", source: .drag, at: secondDate)
        store.maintain { result in
            XCTAssertNoThrow(try result.get())
            XCTAssertEqual(failures, 2)
            XCTAssertEqual(spy?.attempts, ["A", "A", "A", "B"])
            XCTAssertEqual(saved.map(\.text), ["A", "B"])
            XCTAssertEqual(saved.map(\.lastCollectedAt), [firstDate, secondDate])
            XCTAssertEqual(saved.map(\.source), [.automatic, .drag])
            XCTAssertEqual(retries, [true, false])
            XCTAssertEqual(spy?.fetchCount, 0)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testNextCollectionRetriesOlderFailureBeforeSavingNewText() throws {
        let url = try databaseURL()
        var saved: [String] = []
        var failures = 0
        let done = expectation(description: "next collection retries")
        let store = HistoryStore(makeDatabase: {
            let database = try DatabaseSpy(url: url)
            database.failedAttempts = [1]
            return database
        }) { event in
            switch event {
            case .saved(let entry, _): saved.append(entry.text)
            case .saveFailed: failures += 1
            default: break
            }
        }
        store.collect("A", source: .manual, at: Date())
        store.collect("B", source: .automatic, at: Date())
        store.latestDeletion { _ in
            XCTAssertEqual(failures, 1)
            XCTAssertEqual(saved, ["A", "B"])
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testPartiallySavedBatchDoesNotRepeatSuccessfulPrefix() throws {
        let url = try databaseURL()
        var spy: DatabaseSpy?
        var saved: [HistoryEntry] = []
        let done = expectation(description: "only failed suffix retried")
        let store = HistoryStore(makeDatabase: {
            let database = try DatabaseSpy(url: url)
            database.failedAttempts = [2, 3]
            spy = database
            return database
        }) { event in
            if case .saved(let entry, _) = event { saved.append(entry) }
        }
        for text in ["A", "B", "C"] { store.collect(text, source: .automatic, at: Date()) }
        store.maintain { result in
            XCTAssertNoThrow(try result.get())
            XCTAssertEqual(spy?.attempts, ["A", "B", "B", "B", "C"])
            XCTAssertEqual(saved.map(\.text), ["A", "B", "C"])
            XCTAssertEqual(saved.map(\.collectionCount), [1, 1, 1])
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testFailedConnectionIsRetriedWithoutLosingCollection() throws {
        let url = try databaseURL()
        var opens = 0
        var saved: [String] = []
        let done = expectation(description: "connection recovered")
        let store = HistoryStore(makeDatabase: {
            XCTAssertFalse(Thread.isMainThread)
            opens += 1
            if opens == 1 { throw CocoaError(.fileWriteOutOfSpace) }
            return try DatabaseSpy(url: url)
        }) { event in
            if case .saved(let entry, let retried) = event {
                XCTAssertTrue(retried)
                saved.append(entry.text)
            }
        }
        store.collect("A", source: .automatic, at: Date())
        store.maintain { result in
            XCTAssertNoThrow(try result.get())
            XCTAssertEqual(opens, 2)
            XCTAssertEqual(saved, ["A"])
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testSlowDatabaseDoesNotBlockMainThreadOrSubmissionOfNextCollection() throws {
        let url = try databaseURL()
        let entered = expectation(description: "database blocked")
        let released = DispatchSemaphore(value: 0)
        let done = expectation(description: "both collections completed")
        var saved: [String] = []
        let store = HistoryStore(makeDatabase: {
            let database = try DatabaseSpy(url: url)
            database.beforeCollect = { [weak database] in
                guard let database else { return }
                if database.attempts.count == 1 {
                    entered.fulfill()
                    XCTAssertEqual(released.wait(timeout: .now() + 5), .success)
                }
            }
            return database
        }) { event in
            if case .saved(let entry, _) = event { saved.append(entry.text) }
        }
        store.collect("A", source: .automatic, at: Date())
        wait(for: [entered], timeout: 5)
        store.collect("B", source: .automatic, at: Date())
        released.signal()
        store.maintain { result in
            XCTAssertNoThrow(try result.get())
            XCTAssertEqual(saved, ["A", "B"])
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testSavesUseIncrementalResultsAndDoNotFetchEntireHistory() throws {
        let url = try databaseURL()
        var spy: DatabaseSpy?
        var entries: [HistoryEntry] = []
        let done = expectation(description: "incremental duplicate update")
        let date = Date(timeIntervalSince1970: 100)
        let store = HistoryStore(makeDatabase: {
            let database = try DatabaseSpy(url: url)
            spy = database
            return database
        }) { event in
            switch event {
            case .replace(let values): entries = values
            case .saved(let entry, _): HistoryList.upsert(entry, into: &entries)
            default: break
            }
        }
        store.load { result in XCTAssertNoThrow(try result.get()) }
        for (index, text) in ["A", "B", "A"].enumerated() {
            store.collect(text, source: .automatic, at: date.addingTimeInterval(Double(index)))
        }
        store.maintain { result in
            XCTAssertNoThrow(try result.get())
            XCTAssertEqual(spy?.fetchCount, 1)
            XCTAssertEqual(entries.map(\.text), ["A", "B"])
            XCTAssertEqual(entries.map(\.collectionCount), [2, 1])
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testExpiredUndoReturnsFalseThroughMonitor() throws {
        let url = try databaseURL()
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let log = MeasurementLog(writer: MeasurementLogWriter(fileURL: url.deletingLastPathComponent().appendingPathComponent("log.tsv")))
        var now = Date(timeIntervalSince1970: 100)
        let done = expectation(description: "expired undo failed")
        let monitor = ClipboardMonitor(defaults: defaults, log: log,
                                       makeDatabase: { try DatabaseSpy(url: url, now: { now }) }, schedulesMaintenance: false)
        monitor.saveManually(["A"], receivedAt: now)
        monitor.deleteAllHistory(includePinned: true) { value in
            guard let deletion = value else {
                XCTFail("Expected a deletion"); done.fulfill(); return
            }
            now = deletion.expiresAt
            monitor.undo(deletion) { restored in
                XCTAssertFalse(restored)
                log.flush(context: monitor.logContext()) { done.fulfill() }
            }
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testClearFailsWhileOlderCollectionCannotBeSaved() throws {
        let url = try databaseURL()
        var saved = 0
        let done = expectation(description: "clear cannot overtake pending")
        let store = HistoryStore(makeDatabase: {
            let database = try DatabaseSpy(url: url)
            database.failedAttempts = [1, 2]
            return database
        }) { event in
            if case .saved = event { saved += 1 }
        }
        store.collect("A", source: .automatic, at: Date())
        store.deleteAll(includePinned: true) { result in
            if case .success = result { XCTFail("Clear must wait for older collections") }
            XCTAssertEqual(saved, 0)
            store.maintain { result in
                XCTAssertNoThrow(try result.get())
                XCTAssertEqual(saved, 1)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testExportRetriesPendingTextAndWritesSnapshot() throws {
        let url = try databaseURL()
        let done = expectation(description: "snapshot written")
        let store = HistoryStore(makeDatabase: {
            let database = try DatabaseSpy(url: url)
            database.failedAttempts = [1]
            return database
        }) { _ in }
        store.collect("A", source: .drag, at: Date(timeIntervalSince1970: 100))
        store.export { result in
            switch result {
            case .success(let url):
                defer { try? FileManager.default.removeItem(at: url) }
                do {
                    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                    let entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
                    XCTAssertEqual(entries.count, 1)
                    XCTAssertEqual(entries.first?["text"] as? String, "A")
                    XCTAssertEqual(entries.first?["source"] as? String, "drag")
                } catch { XCTFail("Expected valid JSON snapshot") }
            case .failure: XCTFail("Snapshot should succeed after retry")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testIncrementalListKeepsLimitPinsAndDatabaseTieOrder() {
        var entries: [HistoryEntry] = []
        let date = Date(timeIntervalSince1970: 100)
        for id in 0...1_002 {
            let entry = HistoryEntry(id: id, kind: .text, text: "item \(id)", savedAt: date,
                                     lastCollectedAt: date, collectionCount: 1, isPinned: id == 0, source: .automatic)
            HistoryList.upsert(entry, into: &entries)
        }
        XCTAssertEqual(entries.count, 1_001)
        XCTAssertEqual(entries.first?.id, 1_002)
        XCTAssertEqual(entries.last?.id, 0)
        XCTAssertFalse(entries.contains { $0.id == 1 || $0.id == 2 })
        let unpinned = HistoryEntry(id: 0, kind: .text, text: "item 0", savedAt: date,
                                    lastCollectedAt: date, collectionCount: 1, isPinned: false, source: .automatic)
        HistoryList.upsert(unpinned, into: &entries)
        XCTAssertEqual(entries.count, 1_000)
        XCTAssertFalse(entries.contains { $0.id == 0 })
    }
}
