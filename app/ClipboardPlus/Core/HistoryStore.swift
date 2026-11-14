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
    func collectImage(_ image: HistoryImage, source: HistorySource, at date: Date?) throws -> HistoryEntry
    func takeRemovals() -> [HistoryEntry]
    func referencedImageFiles() throws -> Set<String>?
    func imageUsage() throws -> HistoryImageUsage
    func estimateBackup(_ entries: [HistoryEntry]) throws -> RestoreCounts
    func mergeBackup(_ entries: [HistoryEntry], beforeCommit: ([HistoryEntry]) throws -> Void) throws -> RestoreCounts
}

extension HistoryPersistence {
    func collectImage(_ image: HistoryImage, source: HistorySource, at date: Date?) throws -> HistoryEntry {
        throw HistoryImageError.unavailable
    }
    func takeRemovals() -> [HistoryEntry] { [] }
    func referencedImageFiles() throws -> Set<String>? { nil }
    func imageUsage() throws -> HistoryImageUsage { HistoryImageUsage() }
    func estimateBackup(_ entries: [HistoryEntry]) throws -> RestoreCounts { throw BackupError.unavailable }
    func mergeBackup(_ entries: [HistoryEntry], beforeCommit: ([HistoryEntry]) throws -> Void) throws -> RestoreCounts {
        throw BackupError.unavailable
    }
}

final class HistoryStore {
    static let dragProtectionInterval: TimeInterval = 5 * 60

    enum Event {
        case replace([HistoryEntry])
        case upsert(HistoryEntry)
        case remove(Int)
        case saved(HistoryEntry, retried: Bool)
        case saveFailed
        case imageProcessed(HistoryImage, details: String)
        case imageSkipped(String)
        case imageRejected(message: String, details: String)
        case imageUsage(HistoryImageUsage)
        case cleanupFailed
    }

    private struct PendingCollection {
        let text: String
        let source: HistorySource
        let date: Date
        var image: HistoryImage? = nil
        var failed = false
    }

    private let queue = DispatchQueue(label: "clipboardplus.history")
    private let backupQueue: DispatchQueue
    private let makeDatabase: () throws -> HistoryPersistence
    private let onEvent: @MainActor (Event) -> Void
    private let now: () -> Date
    private var database: HistoryPersistence?
    let imageFiles: HistoryImageFiles
    private var imageAdmission = ImageAdmission()
    private var didCleanFiles = false
    private var unusedFiles: Set<String> = []
    private var dragProtectedUntil: [String: Date] = [:]
    private var backupProtections: [UUID: Set<String>] = [:]
    // Pending images contain only metadata. Uncommitted files are cleaned on the next launch.
    private var pending: [PendingCollection] = []

    init(makeDatabase: (() throws -> HistoryPersistence)? = nil,
         imageDirectory: URL = HistoryImageFiles.defaultDirectory,
         now: @escaping () -> Date = Date.init,
         backupQueue: DispatchQueue = DispatchQueue(label: "clipboardplus.backup", qos: .userInitiated),
         onEvent: @escaping @MainActor (Event) -> Void) {
        self.makeDatabase = makeDatabase ?? { try HistoryStore.openDatabase() }
        self.onEvent = onEvent
        self.now = now
        self.backupQueue = backupQueue
        self.imageFiles = HistoryImageFiles(directory: imageDirectory)
    }

    deinit {
        // Keep the connection's final release on the same queue as its operations.
        if let database { queue.async { withExtendedLifetime(database) {} } }
        let abandoned = Set(pending.flatMap { $0.image?.filenames ?? [] }).union(unusedFiles)
        let files = imageFiles
        queue.async { try? files.remove(abandoned) }
    }

    func resetImageAdmission() { queue.async { self.imageAdmission.reset() } }

    func recordImageCopy(hash: String, changeCount: Int) {
        queue.async { self.imageAdmission.recordSelfCopy(hash: hash, changeCount: changeCount) }
    }

    func collectImage(_ input: HistoryImageInput, source: HistorySource, at date: Date,
                      before: Int? = nil, after: Int? = nil, details: String = "") {
        queue.async {
            autoreleasepool {
                var diagnostics = details
                do {
                    let (data, type) = try input.encoded()
                    diagnostics += "; 形式=\(type); バイト数=\(data.count)"
                    let hash = try HistoryImageFiles.hash(data)
                    let measured = "\(diagnostics); hash=\(hash.prefix(8))"
                    if source == .automatic, let before, let after,
                       case .skip(let reason) = self.imageAdmission.receive(hash: hash, before: before, after: after) {
                        self.emit(.imageSkipped("\(measured); 理由=\(reason)"))
                        return
                    }
                    let image = try self.imageFiles.prepare(data, typeIdentifier: type, hash: hash)
                    self.emit(.imageProcessed(image, details: measured))
                    self.pending.append(PendingCollection(text: "", source: source, date: date, image: image))
                } catch {
                    if source == .automatic { self.imageAdmission.reset() }
                    let failure = error as? HistoryImageError ?? .fileWrite
                    self.emit(.imageRejected(message: failure.message, details: "\(diagnostics); \(failure)"))
                    return
                }
                try? self.savePending()
            }
        }
    }

    func readImage(_ image: HistoryImage, completion: @escaping @MainActor (Result<Data, Error>) -> Void) {
        queue.async {
            let result = Result { try self.imageFiles.read(image) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func protectImageForDrag(_ image: HistoryImage) {
        queue.async {
            let expiry = self.now().addingTimeInterval(Self.dragProtectionInterval)
            for filename in image.filenames {
                self.dragProtectedUntil[filename] = max(self.dragProtectedUntil[filename] ?? expiry, expiry)
            }
        }
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

    func createBackup(cancellation: BackupCancellation,
                      progress: @escaping @MainActor (BackupProgress) -> Void,
                      completion: @escaping @MainActor (Result<BackupExport, Error>) -> Void) {
        queue.async {
            do {
                try cancellation.check()
                try self.savePending()
                let database = try self.requireDatabase()
                let entries = try database.fetchAll()
                let createdAt = self.now()
                let token = UUID()
                self.backupProtections[token] = Set(entries.flatMap { $0.image?.filenames ?? [] })
                self.backupQueue.async {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipboardplus-\(token).clipboardplus")
                    let result = Result {
                        try HistoryBackup.write(entries: entries, files: self.imageFiles, to: url,
                                                cancellation: cancellation, createdAt: createdAt) { value in
                            DispatchQueue.main.async { progress(value) }
                        }
                    }
                    self.queue.async {
                        self.backupProtections.removeValue(forKey: token)
                        self.finishChanges(database)
                        DispatchQueue.main.async { completion(result) }
                    }
                }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    func validateBackup(at url: URL, cancellation: BackupCancellation,
                        progress: @escaping @MainActor (BackupProgress) -> Void,
                        completion: @escaping @MainActor (Result<(ValidatedBackup, RestoreCounts), Error>) -> Void) {
        backupQueue.async {
            // Keep security-scoped access for the entire read, including cloud file coordination.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var result: Result<ValidatedBackup, Error> = .failure(BackupError.unavailable)
            let coordinator = NSFileCoordinator(filePresenter: nil)
            cancellation.setCancellationHandler { coordinator.cancel() }
            defer { cancellation.setCancellationHandler(nil) }
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                result = Result {
                    try HistoryBackup.validate(at: readable, cancellation: cancellation) { value in
                        DispatchQueue.main.async { progress(value) }
                    }
                }
            }
            if let error = coordinationError { result = .failure(error) }
            do { try cancellation.check() } catch { result = .failure(error) }
            switch result {
            case .failure(let error): DispatchQueue.main.async { completion(.failure(error)) }
            case .success(let backup):
                self.queue.async {
                    do {
                        try cancellation.check()
                        // Phase one is read-only: do not flush pending collections or purge deletions here.
                        // The normal load opens the store before settings becomes usable.
                        // If it failed, reject rather than letting validation initialize/purge/clean storage.
                        guard let database = self.database else { throw BackupError.unavailable }
                        let counts = try database.estimateBackup(backup.entries)
                        DispatchQueue.main.async { completion(.success((backup, counts))) }
                    } catch {
                        backup.discard()
                        DispatchQueue.main.async { completion(.failure(error)) }
                    }
                }
            }
        }
    }

    func restoreBackup(_ backup: ValidatedBackup, cancellation: BackupCancellation,
                       progress: @escaping @MainActor (BackupProgress) -> Void,
                       completion: @escaping @MainActor (Result<RestoreCounts, Error>) -> Void) {
        queue.async {
            let result: Result<RestoreCounts, Error>
            do {
                try cancellation.check()
                try self.savePending()
                let database = try self.requireDatabase()
                let counts = try HistoryRestore.apply(backup, database: database, files: self.imageFiles,
                                                      cancellation: cancellation) { value in
                    DispatchQueue.main.async { progress(value) }
                }
                self.finishChanges(database)
                // A read failure after COMMIT must not report the successful merge as rolled back.
                do { self.emit(.replace(try database.fetchAll())) }
                catch { self.emit(.saveFailed) }
                result = .success(counts)
            } catch {
                backup.discard()
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func perform<T>(_ operation: @escaping (HistoryPersistence) throws -> T,
                            completion: @escaping @MainActor (Result<T, Error>) -> Void) {
        queue.async {
            let result: Result<T, Error>
            do {
                // Mutations and export must not overtake an older unsaved collection.
                try self.savePending()
                let database = try self.requireDatabase()
                result = .success(try operation(database))
                self.finishChanges(database)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func savePending() throws {
        while !pending.isEmpty {
            let item = pending[0]
            let database: HistoryPersistence
            let entry: HistoryEntry
            do {
                database = try requireDatabase()
                if let image = item.image {
                    entry = try database.collectImage(image, source: item.source, at: item.date)
                } else {
                    entry = try database.collect(item.text, source: item.source, at: item.date)
                }
            } catch {
                pending[0].failed = true
                emit(.saveFailed)
                throw error
            }
            // A committed collection is never retried, even if subsequent file cleanup fails.
            pending.removeFirst()
            if let image = item.image, image.filename != entry.image?.filename {
                unusedFiles.formUnion(image.filenames)
            }
            emit(.saved(entry, retried: item.failed))
            finishChanges(database)
        }
    }

    private func requireDatabase() throws -> HistoryPersistence {
        let opened: HistoryPersistence
        if let database { opened = database } else {
            opened = try makeDatabase()
            database = opened
        }
        if !didCleanFiles {
            if let referenced = try opened.referencedImageFiles() {
                let pendingFiles = Set(pending.flatMap { $0.image?.filenames ?? [] })
                try imageFiles.cleanUnreferenced(keeping: referenced.union(pendingFiles))
            }
            didCleanFiles = true
        }
        return opened
    }

    private func finishChanges(_ database: HistoryPersistence) {
        let date = now()
        dragProtectedUntil = dragProtectedUntil.filter { $0.value > date }
        for entry in database.takeRemovals() {
            emit(.remove(entry.id))
            unusedFiles.formUnion(entry.image?.filenames ?? [])
        }
        do {
            if !unusedFiles.isEmpty, let referenced = try database.referencedImageFiles() {
                let pendingFiles = Set(pending.flatMap { $0.image?.filenames ?? [] })
                // Protected removals stay queued until a later maintenance pass.
                let disposable = unusedFiles.subtracting(referenced).subtracting(pendingFiles)
                    .subtracting(dragProtectedUntil.keys)
                    .subtracting(backupProtections.values.reduce(into: Set<String>()) { $0.formUnion($1) })
                try imageFiles.remove(disposable)
                unusedFiles.subtract(disposable)
            }
            emit(.imageUsage(try database.imageUsage()))
        } catch { emit(.cleanupFailed) }
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
