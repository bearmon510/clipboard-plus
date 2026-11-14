import Foundation

protocol HistoryPersistence: AnyObject {
    func collect(_ text: String, source: HistorySource, at date: Date?) throws -> HistoryEntry
    func fetchAll() throws -> [HistoryEntry]
    func togglePin(id: Int) throws -> HistoryEntry?
    func delete(id: Int) throws -> HistoryDeletion?
    func deleteAll(includePinned: Bool) throws -> HistoryDeletion?
    func undo(_ deletion: HistoryDeletion) throws -> Bool
    func purgeExpired() throws -> Bool
    func latestDeletion() throws -> HistoryDeletion?
}

final class HistoryStore {
    enum Event {
        case replace([HistoryEntry])
        case upsert(HistoryEntry)
        case remove(Int)
        case saved(HistoryEntry, retried: Bool)
        case saveFailed
    }

    private struct PendingCollection {
        let text: String
        let source: HistorySource
        let date: Date
        var failed = false
    }

    private let queue = DispatchQueue(label: "clipboardplus.history")
    private let makeDatabase: () throws -> HistoryPersistence
    private let onEvent: @MainActor (Event) -> Void
    private var database: HistoryPersistence?
    // Stage 2 accepts losing unsaved collections when the process exits; this queue is memory-only.
    private var pending: [PendingCollection] = []

    init(makeDatabase: (() throws -> HistoryPersistence)? = nil,
         onEvent: @escaping @MainActor (Event) -> Void) {
        self.makeDatabase = makeDatabase ?? { try HistoryStore.openDatabase() }
        self.onEvent = onEvent
    }

    deinit {
        // Keep the connection's final release on the same queue as its operations.
        if let database { queue.async { withExtendedLifetime(database) {} } }
    }

    func collect(_ text: String, source: HistorySource, at date: Date) {
        queue.async {
            self.pending.append(PendingCollection(text: text, source: source, date: date))
            try? self.savePending()
        }
    }

    func load(completion: @escaping @MainActor (Result<HistoryDeletion?, Error>) -> Void) {
        perform({ database in
            self.emit(.replace(try database.fetchAll()))
            return try database.latestDeletion()
        }, completion: completion)
    }

    func maintain(completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        perform({ database in
            if try database.purgeExpired() { self.emit(.replace(try database.fetchAll())) }
        }, completion: completion)
    }

    func delete(id: Int, completion: @escaping @MainActor (Result<HistoryDeletion?, Error>) -> Void) {
        perform({ database in
            let deletion = try database.delete(id: id)
            self.emit(.remove(id))
            return deletion
        }, completion: completion)
    }

    func deleteAll(includePinned: Bool, completion: @escaping @MainActor (Result<HistoryDeletion?, Error>) -> Void) {
        perform({ database in
            let deletion = try database.deleteAll(includePinned: includePinned)
            self.emit(.replace(try database.fetchAll()))
            return deletion
        }, completion: completion)
    }

    func undo(_ deletion: HistoryDeletion, completion: @escaping @MainActor (Result<Bool, Error>) -> Void) {
        perform({ database in
            let restored = try database.undo(deletion)
            self.emit(.replace(try database.fetchAll()))
            return restored
        }, completion: completion)
    }

    func latestDeletion(completion: @escaping @MainActor (Result<HistoryDeletion?, Error>) -> Void) {
        perform({ try $0.latestDeletion() }, completion: completion)
    }

    func togglePin(id: Int, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        perform({ database in
            if let entry = try database.togglePin(id: id) {
                self.emit(.upsert(entry))
            } else {
                self.emit(.remove(id))
            }
        }, completion: completion)
    }

    func export(completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        perform({ database in
            let data = try HistoryExport.data(entries: database.fetchAll(), exportedAt: Date())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipboardplus-\(UUID().uuidString).json")
            try data.write(to: url, options: .atomic)
            return url
        }, completion: completion)
    }

    private func perform<T>(_ operation: @escaping (HistoryPersistence) throws -> T,
                            completion: @escaping @MainActor (Result<T, Error>) -> Void) {
        queue.async {
            let result: Result<T, Error>
            do {
                // Mutations and export must not overtake an older unsaved collection.
                try self.savePending()
                result = .success(try operation(self.requireDatabase()))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func savePending() throws {
        while !pending.isEmpty {
            do {
                let item = pending[0]
                let entry = try requireDatabase().collect(item.text, source: item.source, at: item.date)
                pending.removeFirst()
                emit(.saved(entry, retried: item.failed))
            } catch {
                pending[0].failed = true
                emit(.saveFailed)
                throw error
            }
        }
    }

    private func requireDatabase() throws -> HistoryPersistence {
        if let database { return database }
        let opened = try makeDatabase()
        database = opened
        return opened
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { self.onEvent(event) }
    }

    private static func openDatabase() throws -> HistoryPersistence {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return try HistoryDatabase(url: directory.appendingPathComponent("clipboardplus.sqlite"))
    }
}

enum HistoryList {
    static func upsert(_ entry: HistoryEntry, into entries: inout [HistoryEntry]) {
        entries.removeAll { $0.id == entry.id }
        let index = entries.firstIndex {
            $0.lastCollectedAt == entry.lastCollectedAt ? $0.id < entry.id : $0.lastCollectedAt < entry.lastCollectedAt
        } ?? entries.endIndex
        entries.insert(entry, at: index)
        var unpinned = 0
        entries.removeAll {
            if $0.isPinned { return false }
            unpinned += 1
            return unpinned > 1_000
        }
    }
}
