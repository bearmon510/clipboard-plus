import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol HistoryPersistence: AnyObject {
    func createTemplate(text: String, title: String?, tag: String?) throws -> HistoryEntry
    func renameTag(_ tag: String?, to newTag: String?) throws
    func updateTemplate(id: Int, text: String?, title: String?, tag: String?) throws -> HistoryEntry
    func reorderTemplates(_ orderedIDs: [Int]) throws
    func collect(_ text: String, source: HistorySource, at date: Date?) throws -> HistoryEntry
    func fetchAll() throws -> [HistoryEntry]
    func moveToTemplates(id: Int) throws -> HistoryEntry
    func delete(id: Int) throws -> HistoryDeletion?
    func deleteAll() throws -> HistoryDeletion?
    func undo(_ deletion: HistoryDeletion) throws -> Bool
    func purgeExpired() throws -> Bool
    func purgeHistory(olderThan retention: HistoryRetention) throws -> Int
    func latestDeletion() throws -> HistoryDeletion?
    func collectImage(_ image: HistoryImage, source: HistorySource, at date: Date?) throws -> HistoryEntry
    func collectFile(_ file: HistoryFile, source: HistorySource, at date: Date?) throws -> HistoryEntry
    func fileUsage() throws -> HistoryFileUsage
    func takeRemovals() -> [HistoryEntry]
    func referencedImageFiles() throws -> Set<String>?
    func imageUsage() throws -> HistoryImageUsage
    func estimateBackup(_ entries: [HistoryEntry], retentionCutoff: Date?) throws -> RestoreCounts
    func mergeBackup(_ entries: [HistoryEntry], retentionCutoff: Date?, beforeCommit: ([HistoryEntry]) throws -> Void) throws -> RestoreCounts
    func readTemplateSyncSnapshot() throws -> LocalTemplateSyncSnapshot
    func applySyncedTemplates(_ snapshot: TemplateSyncSnapshot, pushed: LocalTemplateSyncSnapshot?) throws -> TemplateSyncOutcome
    func resetTemplateSyncState() throws
}

extension HistoryPersistence {
    func moveToTemplates(id: Int) throws -> HistoryEntry { throw HistoryEditError.failed }
    func createTemplate(text: String, title: String?, tag: String?) throws -> HistoryEntry { throw HistoryEditError.failed }
    func renameTag(_ tag: String?, to newTag: String?) throws { throw HistoryEditError.failed }
    func updateTemplate(id: Int, text: String?, title: String?, tag: String?) throws -> HistoryEntry { throw HistoryEditError.failed }
    func reorderTemplates(_ orderedIDs: [Int]) throws { throw HistoryEditError.failed }
    func collectImage(_ image: HistoryImage, source: HistorySource, at date: Date?) throws -> HistoryEntry {
        throw HistoryImageError.unavailable
    }
    func collectFile(_ file: HistoryFile, source: HistorySource, at date: Date?) throws -> HistoryEntry {
        throw HistoryFileError.unavailable
    }
    func fileUsage() throws -> HistoryFileUsage { HistoryFileUsage() }
    func takeRemovals() -> [HistoryEntry] { [] }
    func referencedImageFiles() throws -> Set<String>? { nil }
    func imageUsage() throws -> HistoryImageUsage { HistoryImageUsage() }
    func estimateBackup(_ entries: [HistoryEntry], retentionCutoff: Date? = nil) throws -> RestoreCounts { throw BackupError.unavailable }
    func mergeBackup(_ entries: [HistoryEntry], retentionCutoff: Date? = nil, beforeCommit: ([HistoryEntry]) throws -> Void) throws -> RestoreCounts {
        throw BackupError.unavailable
    }
    func readTemplateSyncSnapshot() throws -> LocalTemplateSyncSnapshot { throw HistoryEditError.failed }
    func applySyncedTemplates(_ snapshot: TemplateSyncSnapshot, pushed: LocalTemplateSyncSnapshot?) throws -> TemplateSyncOutcome {
        throw HistoryEditError.failed
    }
    func resetTemplateSyncState() throws {}
}

final class HistoryStore {
    static let dragProtectionInterval: TimeInterval = 5 * 60
    static let retentionCheckInterval: TimeInterval = 60 * 60

    enum Event {
        case replace([HistoryEntry])
        case upsert(HistoryEntry)
        case remove(Int)
        case saved(HistoryEntry, retried: Bool)
        case localEntry(HistoryEntry, source: HistorySource, at: Date)
        case saveFailed
        case imageProcessed(HistoryImage, details: String)
        case imageSkipped(String)
        case imageRejected(message: String, details: String)
        case imageUsage(HistoryImageUsage)
        case fileProcessed(HistoryFile, details: String)
        case fileSkipped(String)
        case fileRejected(message: String, details: String)
        case fileUsage(HistoryFileUsage)
        case cleanupFailed
        case automaticallyDeleted(count: Int, retention: HistoryRetention)
        case keyboardWriteFailed
    }

    struct SharedInboxImportResult: Equatable {
        let importedCount: Int
        let origins: [SharedInboxItem.Origin]
    }

    private struct PendingCollection {
        let text: String
        let source: HistorySource
        let date: Date
        var image: HistoryImage? = nil
        var file: HistoryFile? = nil
        var filenames: Set<String> { (image?.filenames ?? []).union(file?.filenames ?? []) }
        var failed = false
    }

    private let queue = DispatchQueue(label: "clipboardplus.history")
    private let backupQueue: DispatchQueue
    let backupTemporaryFiles: BackupTemporaryFiles
    private let makeDatabase: () throws -> HistoryPersistence
    private let onEvent: @MainActor (Event) -> Void
    private let now: () -> Date
    private let keyboardContainerURL: () -> URL?
    private let inboxStateDefaults: UserDefaults?
    private let inboxSeenKey = "sharedInbox.seenIDs.v1"
    private let maxSeenInboxIDs = 500
    private var memorySeenInboxIDs: [UUID] = []
    private var currentKeyboardTab: KeyboardTab
    private var needsKeyboardExport = true
    private var needsKeyboardSettingsWrite = true
    private var lastKeyboardEntries: [KeyboardHistoryEntry]?
    private var lastKeyboardURL: URL?
    private var lastKeyboardSettingsTab: KeyboardTab?
    private var lastKeyboardSettingsURL: URL?
    private var didReportKeyboardWriteFailure = false
    private var database: HistoryPersistence?
    let imageFiles: HistoryImageFiles
    let fileFiles: HistoryFileFiles
    private var fileAdmission = ImageAdmission()
    private var imageAdmission = ImageAdmission()
    var syncEchoGuard: SyncEchoGuard?
    private var didCleanFiles = false
    private var didScheduleBackupCleanup = false
    private var unusedFiles: Set<String> = []
    private var dragProtectedUntil: [String: Date] = [:]
    private var backupProtections: [UUID: Set<String>] = [:]
    // Pending images contain only metadata. Uncommitted files are cleaned on the next launch.
    private var pending: [PendingCollection] = []
    private var retention: HistoryRetention
    private var lastRetentionCheck: Date?

    init(retention: HistoryRetention = .defaultValue,
         makeDatabase: (() throws -> HistoryPersistence)? = nil,
         imageDirectory: URL = HistoryImageFiles.defaultDirectory,
         now: @escaping () -> Date = Date.init,
         backupQueue: DispatchQueue = DispatchQueue(label: "clipboardplus.backup", qos: .userInitiated),
         backupTemporaryFiles: BackupTemporaryFiles = .shared,
         keyboardContainerURL: @escaping () -> URL? = { SharedAppGroup.containerURL() },
         inboxStateDefaults: UserDefaults? = nil,
         initialKeyboardTab: KeyboardTab = .defaultValue,
         onEvent: @escaping @MainActor (Event) -> Void) {
        self.retention = retention
        self.makeDatabase = makeDatabase ?? { try HistoryStore.openDatabase(now: now) }
        self.onEvent = onEvent
        self.now = now
        self.backupQueue = backupQueue
        self.backupTemporaryFiles = backupTemporaryFiles
        self.keyboardContainerURL = keyboardContainerURL
        self.inboxStateDefaults = inboxStateDefaults
        self.currentKeyboardTab = initialKeyboardTab
        self.imageFiles = HistoryImageFiles(directory: imageDirectory)
        // One attachment directory/journal keeps deletion, undo, drag and backup protection atomic.
        self.fileFiles = HistoryFileFiles(directory: imageDirectory)
    }

    deinit {
        // Keep the connection's final release on the same queue as its operations.
        if let database { queue.async { withExtendedLifetime(database) {} } }
        let abandoned = Set(pending.flatMap { $0.filenames }).union(unusedFiles)
        let files = imageFiles
        queue.async { try? files.remove(abandoned) }
    }

    func resetFileAdmission() { queue.async { self.fileAdmission.reset() } }

    func recordFileCopy(hash: String, changeCount: Int) {
        queue.async { self.fileAdmission.recordSelfCopy(hash: hash, changeCount: changeCount) }
    }

    func collectFile(_ input: HistoryFileInput, source: HistorySource, at date: Date,
                     before: Int? = nil, after: Int? = nil, details: String = "") {
        queue.async {
            let file = input.file
            if source == .automatic || source == .manual, self.syncEchoGuard?.observe(kind: "file", hash: file.hash) == true {
                self.emit(.fileSkipped("理由=PC受信内容の共有; 件数=1")); return
            }
            let measured = "\(details); 形式=\(file.typeIdentifier); バイト数=\(file.byteCount); hash=\(file.hash.prefix(8))"
            if source == .automatic, let before, let after,
               case .skip(let reason) = self.fileAdmission.receive(hash: file.hash, before: before, after: after) {
                self.emit(.fileSkipped("\(measured); 理由=\(reason)"))
                return
            }
            do {
                let prepared = try self.fileFiles.prepare(input)
                self.emit(.fileProcessed(prepared, details: measured))
                self.pending.append(PendingCollection(text: "", source: source, date: date, file: prepared))
            } catch {
                if source == .automatic { self.fileAdmission.reset() }
                self.emit(.fileRejected(message: HistoryFileError.fileWrite.message, details: "\(measured); 理由=保存先への移動失敗"))
                return
            }
            try? self.savePending()
        }
    }

    /// Snapshot creation is ordered before deletion on the store queue. The lease is held by
    /// the outbound NSItemProvider, so even a delayed paste survives removal of its history.
    func snapshotFile(_ file: HistoryFile, completion: @escaping @MainActor (Result<HistoryFileInput, Error>) -> Void) {
        queue.async {
            let result = Result {
                try HistoryFileFiles.stage(self.fileFiles.url(for: file), typeIdentifier: file.typeIdentifier,
                                           suggestedName: file.originalFilename)
            }
            DispatchQueue.main.async { completion(result) }
        }
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
                    if source == .automatic || source == .manual, self.syncEchoGuard?.observe(kind: "image", hash: hash) == true {
                        self.emit(.imageSkipped("理由=PC受信内容の共有; 件数=1")); return
                    }
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

    /// A remote sender owns retries until ACK. Do not also retain a failed write in pending.
    func collectFromPC(_ text: String, at date: Date,
                       completion: @escaping @MainActor (Result<HistoryEntry, Error>) -> Void) {
        perform({ database in
            let entry = try database.collect(text, source: .pc, at: date)
            self.needsKeyboardExport = true
            self.emit(.upsert(entry))
            return entry
        }, completion: completion)
    }

    struct SyncBody { let data: Data; let kind: String; let name: String; let type: String; let hash: String }
    func prepareForPC(_ entry: HistoryEntry, completion: @escaping @MainActor (Result<SyncBody, Error>) -> Void) {
        queue.async {
            let result = Result { () throws -> SyncBody in
                let data: Data, kind: String, name: String, type: String
                if let image = entry.image {
                    guard image.byteCount <= SyncProtocol.maxItemBytes,
                          image.pixelWidth > 0, image.pixelHeight > 0,
                          Int64(image.pixelWidth) <= SyncProtocol.maxImagePixels / Int64(image.pixelHeight) else {
                        throw SyncProtocolError.limit
                    }
                    let original = try self.imageFiles.read(image)
                    kind = "image"; name = ""
                    if ["public.png", "public.jpeg"].contains(image.typeIdentifier) { data = original; type = image.typeIdentifier }
                    else {
                        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
                              let bitmap = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SyncProtocolError.limit }
                        let png = NSMutableData()
                        guard let destination = CGImageDestinationCreateWithData(png as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { throw SyncProtocolError.format }
                        CGImageDestinationAddImage(destination, bitmap, nil)
                        guard CGImageDestinationFinalize(destination) else { throw SyncProtocolError.format }
                        data = png as Data; type = "public.png"
                    }
                } else if let file = entry.file {
                    guard file.byteCount <= SyncProtocol.maxItemBytes else { throw SyncProtocolError.limit }
                    data = try Data(contentsOf: self.fileFiles.url(for: file), options: .mappedIfSafe)
                    kind = "file"; name = file.originalFilename; type = file.typeIdentifier
                } else { data = Data(entry.text.utf8); kind = "text"; name = ""; type = "public.utf8-plain-text" }
                try SyncProtocol.require(data.count <= SyncProtocol.maxItemBytes, .limit)
                return SyncBody(data: data, kind: kind, name: name, type: type, hash: SyncEchoGuard.hash(data))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func collectFromPC(_ offer: SyncOffer, url: URL, completion: @escaping @MainActor (Result<HistoryEntry, Error>) -> Void) {
        perform({ database in
            let date = Date(timeIntervalSince1970: Double(offer.at) / 1000)
            let entry: HistoryEntry
            if offer.kind == "image" {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard ["public.png", "public.jpeg"].contains(offer.type) else {
                    throw SyncContentRejectedError(reason: .imageFormat)
                }
                guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let actualType = CGImageSourceGetType(source) else {
                    throw SyncContentRejectedError(reason: .imageCorrupt)
                }
                guard actualType as String == offer.type else {
                    throw SyncContentRejectedError(reason: .imageFormat)
                }
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                      width.intValue > 0, height.intValue > 0 else {
                    throw SyncContentRejectedError(reason: .imageCorrupt)
                }
                guard Int64(width.intValue) <= SyncProtocol.maxImagePixels / Int64(height.intValue) else {
                    throw SyncContentRejectedError(reason: .imageDimensions)
                }
                let image: HistoryImage
                do {
                    image = try self.imageFiles.prepare(data, typeIdentifier: offer.type, hash: offer.sha256)
                } catch HistoryImageError.invalidImage {
                    throw SyncContentRejectedError(reason: .imageCorrupt)
                } catch HistoryImageError.tooLarge {
                    throw SyncContentRejectedError(reason: .imageDimensions)
                }
                do {
                    entry = try database.collectImage(image, source: .pc, at: date)
                    if entry.image?.filename != image.filename { self.unusedFiles.formUnion(image.filenames) }
                }
                catch { try? self.imageFiles.remove(image.filenames); throw error }
            } else {
                let inferred = UTType(filenameExtension: (offer.filename as NSString).pathExtension)?.identifier ?? "public.data"
                let type = HistoryFileTypes.isStorable(offer.type) && offer.type != "public.data" ? offer.type : (HistoryFileTypes.isStorable(inferred) ? inferred : "public.data")
                let staged = try HistoryFileFiles.stage(url, typeIdentifier: type, suggestedName: offer.filename)
                let file = try self.fileFiles.prepare(staged)
                do {
                    entry = try database.collectFile(file, source: .pc, at: date)
                    if entry.file?.filename != file.filename { self.unusedFiles.formUnion(file.filenames) }
                }
                catch { try? self.imageFiles.remove(file.filenames); throw error }
            }
            self.needsKeyboardExport = true
            self.emit(.upsert(entry)); return entry
        }, completion: completion)
    }

    func load(completion: @escaping @MainActor (Result<HistoryDeletion?, Error>) -> Void) {
        perform({ database in
            self.needsKeyboardExport = true
            try self.applyRetention(database, force: true)
            self.emit(.replace(try database.fetchAll()))
            return try database.latestDeletion()
        }, completion: completion)
    }

    func setKeyboardInitialTab(_ value: KeyboardTab) {
        queue.async {
            self.currentKeyboardTab = value
            self.needsKeyboardSettingsWrite = true
            guard let containerURL = self.keyboardContainerURL() else { return }
            self.writeKeyboardSettingsIfNeeded(in: containerURL)
        }
    }

    func importSharedInbox(completion: @escaping @MainActor (Result<SharedInboxImportResult, Error>) -> Void) {
        queue.async {
            guard let containerURL = self.keyboardContainerURL() else {
                DispatchQueue.main.async {
                    completion(.success(SharedInboxImportResult(importedCount: 0, origins: [])))
                }
                return
            }
            let inboxURL = SharedAppGroup.inboxDirectoryURL(in: containerURL)
            let scan = SharedInbox.scan(directory: inboxURL)
            for corrupt in scan.corruptFiles {
                try? FileManager.default.removeItem(at: corrupt)
            }
            guard !scan.items.isEmpty else {
                DispatchQueue.main.async {
                    completion(.success(SharedInboxImportResult(importedCount: 0, origins: [])))
                }
                return
            }
            let result = Result { () throws -> SharedInboxImportResult in
                try self.savePending()
                let database = try self.requireDatabase()
                var importedCount = 0
                var origins: [SharedInboxItem.Origin] = []
                defer {
                    if importedCount > 0 {
                        self.finishChanges(database)
                    }
                }
                for pendingItem in scan.items {
                    let item = pendingItem.item
                    if self.hasSeenInboxID(item.id) || item.text.isEmpty {
                        try? FileManager.default.removeItem(at: pendingItem.fileURL)
                        continue
                    }
                    let entry = try database.collect(item.text, source: .manual, at: item.createdAt)
                    self.rememberInboxID(item.id)
                    try? FileManager.default.removeItem(at: pendingItem.fileURL)
                    self.needsKeyboardExport = true
                    self.emit(.upsert(entry))
                    self.emit(.localEntry(entry, source: .manual, at: item.createdAt))
                    importedCount += 1
                    origins.append(item.origin)
                }
                return SharedInboxImportResult(importedCount: importedCount, origins: origins)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Explicit shortcut saves report the committed result. A failed request is not retained
    /// for an invisible retry after Shortcuts has already reported failure.
    func saveFromShortcut(text: String, pngData: Data?,
                          completion: @escaping @MainActor (Result<HistoryEntry, Error>) -> Void) {
        perform({ database in
            let entry: HistoryEntry
            let date = self.now()
            if let data = pngData {
                let image = try self.imageFiles.prepare(data, typeIdentifier: "public.png",
                                                       hash: HistoryImageFiles.hash(data))
                do {
                    entry = try database.collectImage(image, source: .manual, at: date)
                } catch {
                    try? self.imageFiles.remove(image.filenames)
                    throw error
                }
                if image.filename != entry.image?.filename {
                    self.unusedFiles.formUnion(image.filenames)
                }
            } else {
                entry = try database.collect(text, source: .manual, at: date)
            }
            self.emit(.saved(entry, retried: false))
            self.emit(.localEntry(entry, source: .manual, at: date))
            self.needsKeyboardExport = true
            return entry
        }, completion: completion)
    }

    func maintain(forceRetention: Bool = false, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        perform({ database in
            if try database.purgeExpired() {
                self.needsKeyboardExport = true
                self.emit(.replace(try database.fetchAll()))
            }
            try self.applyRetention(database, force: forceRetention)
        }, completion: completion)
    }

    func setRetention(_ value: HistoryRetention, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        queue.async {
            self.retention = value
            // Keep the new policy due even if flushing pending writes fails.
            self.lastRetentionCheck = nil
            let result = Result {
                try self.savePending()
                let database = try self.requireDatabase()
                try self.applyRetention(database, force: true)
                self.finishChanges(database)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func applyRetention(_ database: HistoryPersistence, force: Bool) throws {
        let date = now()
        if !force, let lastRetentionCheck,
           date.timeIntervalSince(lastRetentionCheck) < Self.retentionCheckInterval,
           date >= lastRetentionCheck { return }
        let count = try database.purgeHistory(olderThan: retention)
        lastRetentionCheck = date
        recordAutomaticDeletion(count)
    }

    private func recordAutomaticDeletion(_ count: Int) {
        if count > 0 {
            needsKeyboardExport = true
            emit(.automaticallyDeleted(count: count, retention: retention))
        }
    }

    func delete(id: Int, completion: @escaping @MainActor (Result<HistoryDeletion?, Error>) -> Void) {
        perform({ database in
            let deletion = try database.delete(id: id)
            if deletion != nil { self.needsKeyboardExport = true }
            self.emit(.remove(id))
            return deletion
        }, completion: completion)
    }

    func deleteAll(completion: @escaping @MainActor (Result<HistoryDeletion?, Error>) -> Void) {
        perform({ database in
            let deletion = try database.deleteAll()
            if deletion != nil { self.needsKeyboardExport = true }
            self.emit(.replace(try database.fetchAll()))
            return deletion
        }, completion: completion)
    }

    func undo(_ deletion: HistoryDeletion, completion: @escaping @MainActor (Result<Bool, Error>) -> Void) {
        perform({ database in
            let restored = try database.undo(deletion)
            if restored { self.needsKeyboardExport = true }
            self.emit(.replace(try database.fetchAll()))
            return restored
        }, completion: completion)
    }

    func latestDeletion(completion: @escaping @MainActor (Result<HistoryDeletion?, Error>) -> Void) {
        perform({ try $0.latestDeletion() }, completion: completion)
    }

    func moveToTemplates(id: Int, completion: @escaping @MainActor (Result<HistoryEntry, HistoryEditError>) -> Void) {
        perform({ database in
            let entry = try database.moveToTemplates(id: id)
            self.needsKeyboardExport = true
            self.emit(.replace(try database.fetchAll()))
            return entry
        }) { result in completion(result.mapError { $0 as? HistoryEditError ?? .failed }) }
    }

    func createTemplate(text: String, title: String?, tag: String?, completion: @escaping @MainActor (Result<HistoryEntry, HistoryEditError>) -> Void) {
        perform({ database in
            let entry = try database.createTemplate(text: text, title: title, tag: tag)
            self.needsKeyboardExport = true
            self.emit(.replace(try database.fetchAll()))
            return entry
        }) { result in completion(result.mapError { $0 as? HistoryEditError ?? .failed }) }
    }

    func updateTemplate(id: Int, text: String?, title: String?, tag: String?, completion: @escaping @MainActor (Result<HistoryEntry, HistoryEditError>) -> Void) {
        perform({ database in
            let entry = try database.updateTemplate(id: id, text: text, title: title, tag: tag)
            self.needsKeyboardExport = true
            self.emit(.replace(try database.fetchAll()))
            return entry
        }) { result in completion(result.mapError { $0 as? HistoryEditError ?? .failed }) }
    }

    func reorderTemplates(_ orderedIDs: [Int], completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        perform({ database in
            try database.reorderTemplates(orderedIDs)
            self.needsKeyboardExport = true
            self.emit(.replace(try database.fetchAll()))
        }, completion: completion)
    }

    func renameTag(_ tag: String?, to newTag: String?, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        perform({ database in
            try database.renameTag(tag, to: newTag)
            self.needsKeyboardExport = true
            self.emit(.replace(try database.fetchAll()))
        }, completion: completion)
    }

    func readTemplateSyncSnapshot(completion: @escaping @MainActor (Result<LocalTemplateSyncSnapshot, Error>) -> Void) {
        perform({ database in
            try database.readTemplateSyncSnapshot()
        }, completion: completion)
    }

    func applySyncedTemplates(_ snapshot: TemplateSyncSnapshot, pushed: LocalTemplateSyncSnapshot?,
                              completion: @escaping @MainActor (Result<TemplateSyncOutcome, Error>) -> Void) {
        perform({ database in
            let outcome = try database.applySyncedTemplates(snapshot, pushed: pushed)
            self.needsKeyboardExport = true
            self.emit(.replace(try database.fetchAll()))
            return outcome
        }, completion: completion)
    }

    func resetTemplateSyncState(completion: (@MainActor (Result<Void, Error>) -> Void)? = nil) {
        perform({ database in
            try database.resetTemplateSyncState()
        }, completion: { result in
            completion?(result)
        })
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
                self.backupProtections[token] = Set(entries.flatMap { $0.attachmentFilenames })
                self.backupQueue.async {
                    let result = Result {
                        let url = try self.backupTemporaryFiles.makeExportURL()
                        return try HistoryBackup.write(entries: entries, files: self.imageFiles, to: url,
                                                cancellation: cancellation, createdAt: createdAt,
                                                temporaryFiles: self.backupTemporaryFiles) { value in
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
                    try HistoryBackup.validate(at: readable, cancellation: cancellation,
                                               temporaryFiles: self.backupTemporaryFiles) { value in
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
                        let counts = try database.estimateBackup(backup.entries,
                                                               retentionCutoff: self.retention.cutoff(relativeTo: self.now()))
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
                       expectedCounts: RestoreCounts? = nil,
                       progress: @escaping @MainActor (BackupProgress) -> Void,
                       completion: @escaping @MainActor (Result<RestoreCounts, Error>) -> Void) {
        queue.async {
            let result: Result<RestoreCounts, Error>
            do {
                try cancellation.check()
                try self.savePending()
                let database = try self.requireDatabase()
                // Freeze the cutoff for re-estimation and application on this serial queue.
                let date = self.now()
                let cutoff = self.retention.cutoff(relativeTo: date)
                let estimate = try database.estimateBackup(backup.entries, retentionCutoff: cutoff)
                if let expectedCounts, estimate != expectedCounts {
                    throw RestoreEstimateChanged(counts: estimate)
                }
                let counts = try HistoryRestore.apply(backup, database: database, files: self.imageFiles,
                                                      cancellation: cancellation, retentionCutoff: cutoff) { value in
                    DispatchQueue.main.async { progress(value) }
                }
                self.lastRetentionCheck = date
                self.recordAutomaticDeletion(counts.removedByRetention)
                self.needsKeyboardExport = true
                self.finishChanges(database)
                // A read failure after COMMIT must not report the successful merge as rolled back.
                do { self.emit(.replace(try database.fetchAll())) }
                catch { self.emit(.saveFailed) }
                result = .success(counts)
            } catch {
                if !(error is RestoreEstimateChanged) { backup.discard() }
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
                } else if let file = item.file {
                    entry = try database.collectFile(file, source: item.source, at: item.date)
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
            if let file = item.file, file.filename != entry.file?.filename {
                unusedFiles.formUnion(file.filenames)
            }
            emit(.saved(entry, retried: item.failed))
            if item.source != .pc { emit(.localEntry(entry, source: item.source, at: item.date)) }
            needsKeyboardExport = true
            finishChanges(database)
        }
    }

    private func requireDatabase() throws -> HistoryPersistence {
        if !didScheduleBackupCleanup {
            backupTemporaryFiles.cleanPreviousProcesses()
            didScheduleBackupCleanup = true
        }
        let opened: HistoryPersistence
        if let database { opened = database } else {
            opened = try makeDatabase()
            database = opened
        }
        if !didCleanFiles {
            if let referenced = try opened.referencedImageFiles() {
                let pendingFiles = Set(pending.flatMap { $0.filenames })
                try imageFiles.cleanUnreferenced(keeping: referenced.union(pendingFiles))
            }
            didCleanFiles = true
        }
        return opened
    }

    private func finishChanges(_ database: HistoryPersistence) {
        let date = now()
        dragProtectedUntil = dragProtectedUntil.filter { $0.value > date }
        let removals = database.takeRemovals()
        if !removals.isEmpty { needsKeyboardExport = true }
        for entry in removals {
            emit(.remove(entry.id))
            unusedFiles.formUnion(entry.attachmentFilenames)
        }
        do {
            if !unusedFiles.isEmpty, let referenced = try database.referencedImageFiles() {
                let pendingFiles = Set(pending.flatMap { $0.filenames })
                // Protected removals stay queued until a later maintenance pass.
                let disposable = unusedFiles.subtracting(referenced).subtracting(pendingFiles)
                    .subtracting(dragProtectedUntil.keys)
                    .subtracting(backupProtections.values.reduce(into: Set<String>()) { $0.formUnion($1) })
                try imageFiles.remove(disposable)
                unusedFiles.subtract(disposable)
            }
            emit(.imageUsage(try database.imageUsage()))
            emit(.fileUsage(try database.fileUsage()))
        } catch { emit(.cleanupFailed) }
        syncKeyboardFiles(database)
    }

    private func syncKeyboardFiles(_ database: HistoryPersistence) {
        guard let containerURL = keyboardContainerURL() else { return }
        writeKeyboardSettingsIfNeeded(in: containerURL)
        guard needsKeyboardExport else { return }
        let historyURL = SharedAppGroup.keyboardHistoryURL(in: containerURL)
        do {
            let entries = try database.fetchAll()
            let history = KeyboardHistoryBuilder.build(entries: entries, exportedAt: now())
            needsKeyboardExport = false
            guard history.entries != lastKeyboardEntries || historyURL != lastKeyboardURL else { return }
            try KeyboardHistoryFile.write(history, to: historyURL)
            lastKeyboardEntries = history.entries
            lastKeyboardURL = historyURL
            didReportKeyboardWriteFailure = false
        } catch {
            // Leave the database commit intact and retry on the next change or maintenance pass.
            needsKeyboardExport = true
            if !didReportKeyboardWriteFailure {
                didReportKeyboardWriteFailure = true
                emit(.keyboardWriteFailed)
            }
        }
    }

    private func writeKeyboardSettingsIfNeeded(in containerURL: URL) {
        let settingsURL = SharedAppGroup.keyboardSettingsURL(in: containerURL)
        guard needsKeyboardSettingsWrite || settingsURL != lastKeyboardSettingsURL || currentKeyboardTab != lastKeyboardSettingsTab else {
            return
        }
        do {
            let settings = KeyboardSettings(initialTab: currentKeyboardTab, updatedAt: now())
            try KeyboardSettingsFile.write(settings, to: settingsURL)
            lastKeyboardSettingsTab = currentKeyboardTab
            lastKeyboardSettingsURL = settingsURL
            needsKeyboardSettingsWrite = false
        } catch {
            needsKeyboardSettingsWrite = true
        }
    }

    private func loadSeenInboxIDs() -> [UUID] {
        guard let defaults = inboxStateDefaults else { return memorySeenInboxIDs }
        return (defaults.stringArray(forKey: inboxSeenKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    private func hasSeenInboxID(_ id: UUID) -> Bool {
        loadSeenInboxIDs().contains(id)
    }

    private func rememberInboxID(_ id: UUID) {
        var ids = loadSeenInboxIDs()
        ids.removeAll { $0 == id }
        ids.append(id)
        if ids.count > maxSeenInboxIDs {
            ids.removeFirst(ids.count - maxSeenInboxIDs)
        }
        memorySeenInboxIDs = ids
        inboxStateDefaults?.set(ids.map(\.uuidString), forKey: inboxSeenKey)
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { self.onEvent(event) }
    }

    private static func openDatabase(now: @escaping () -> Date) throws -> HistoryPersistence {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return try HistoryDatabase(url: directory.appendingPathComponent("clipboardplus.sqlite"), now: now)
    }
}

enum HistoryList {
    static func upsert(_ entry: HistoryEntry, into entries: inout [HistoryEntry]) {
        entries.removeAll { $0.id == entry.id }
        let index = entries.firstIndex {
            $0.lastCollectedAt == entry.lastCollectedAt ? $0.id < entry.id : $0.lastCollectedAt < entry.lastCollectedAt
        } ?? entries.endIndex
        entries.insert(entry, at: index)
        var historyCount = 0
        entries.removeAll {
            if $0.isTemplate { return false }
            historyCount += 1
            return historyCount > 1_000
        }
    }
}
