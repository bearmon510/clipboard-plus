import Foundation

struct RestoreCounts: Equatable {
    var added = 0
    var updated = 0
    var unchanged = 0
    var removedByLimit = 0
    var removedByRetention = 0

    var description: String {
        "追加 \(added)件・更新 \(updated)件・変化なし \(unchanged)件\n上限で消える項目 \(removedByLimit)件\n期限を過ぎているため削除される \(removedByRetention)件"
    }
}

struct RestoreEstimateChanged: Error {
    let counts: RestoreCounts
}

// Estimate and application share the same pure plan. At equal timestamps, a stable
// content key prevents reimported, previously capped items from displacing survivors.
struct HistoryRestorePlan {
    let writes: [HistoryEntry]
    let survivors: [HistoryEntry]
    let removedIDs: Set<Int>
    let counts: RestoreCounts

    init(existing: [HistoryEntry], incoming: [HistoryEntry], lastID: Int,
         historyLimit: Int, imageByteLimit: Int, retentionCutoff: Date? = nil) throws {
        var counts = RestoreCounts()
        let existingByKey = Dictionary(
            existing.map { (Self.key($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var byKey = existingByKey
        var nextID = lastID
        for entry in incoming {
            let key = Self.key(entry)
            if let old = byKey[key] {
                // Equal timestamps retain the device source, making repeat restores stable.
                byKey[key] = HistoryEntry(
                    id: old.id, kind: old.kind, text: old.text, savedAt: min(old.savedAt, entry.savedAt),
                    lastCollectedAt: max(old.lastCollectedAt, entry.lastCollectedAt),
                    collectionCount: HistoryCollectionCount.clamped(max(old.collectionCount, entry.collectionCount)),
                    isTemplate: old.isTemplate,
                    source: entry.lastCollectedAt > old.lastCollectedAt ? entry.source : old.source, image: old.image, file: old.file,
                    title: HistoryEntry.normalizedTitle(old.title) ?? HistoryEntry.normalizedTitle(entry.title),
                    templateOrder: old.templateOrder, tag: old.tag ?? entry.tag)
            } else {
                guard nextID < Int.max else { throw BackupError.unavailable }
                nextID += 1
                let normalizedText = entry.isTemplate && (entry.kind == .text || entry.kind == .url)
                    ? TemplateSyncMerge.normalizeLineEndings(entry.text)
                    : entry.text
                byKey[key] = HistoryEntry(id: nextID, kind: entry.kind, text: normalizedText, savedAt: entry.savedAt,
                                         lastCollectedAt: entry.lastCollectedAt,
                                         collectionCount: HistoryCollectionCount.clamped(entry.collectionCount),
                                         isTemplate: entry.isTemplate, source: entry.source, image: entry.image, file: entry.file,
                                         title: HistoryEntry.normalizedTitle(entry.title), templateOrder: entry.templateOrder, tag: entry.tag)
            }
        }
        // Keep each device group first; append incoming/moved templates in archive order.
        // Legacy nil orders use the historical newest-first fallback.
        let incomingTemplates = incoming.filter(\.isTemplate).sorted {
            switch ($0.templateOrder, $1.templateOrder) {
            case let (a?, b?): return a == b ? $0.id < $1.id : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.lastCollectedAt == $1.lastCollectedAt ? $0.id > $1.id : $0.lastCollectedAt > $1.lastCollectedAt
            }
        }
        let existingTemplates = HistoryEntry.orderedTemplates(existing.filter(\.isTemplate))
        for group in TemplateGroups.make(Array(byKey.values), search: "") {
            var seen = Set<Data>()
            let device = existingTemplates.filter {
                TemplateGroups.tagsEqual($0.tag, group.tag) && TemplateGroups.tagsEqual(byKey[Self.key($0)]?.tag, group.tag)
            }
            let candidates = device + incomingTemplates + existingTemplates
            var order = 0
            for candidate in candidates {
                let key = Self.key(candidate)
                guard let value = byKey[key], TemplateGroups.tagsEqual(value.tag, group.tag), seen.insert(key).inserted else { continue }
                byKey[key] = HistoryEntry(id: value.id, kind: value.kind, text: value.text, savedAt: value.savedAt,
                                         lastCollectedAt: value.lastCollectedAt, collectionCount: value.collectionCount,
                                         isTemplate: true, source: value.source, image: value.image, file: value.file,
                                         title: value.title, templateOrder: order, tag: value.tag)
                order += 1
            }
        }
        let incomingKeys = Set(incoming.map { Self.key($0) })
        var writes: [HistoryEntry] = []
        for (key, value) in byKey {
            if let old = existingByKey[key] {
                if value != old { writes.append(value); counts.updated += 1 }
                else if incomingKeys.contains(key) { counts.unchanged += 1 }
            } else { writes.append(value); counts.added += 1 }
        }
        writes.sort { $0.id < $1.id }
        // Apply age and size limits only to history, after merging timestamps.
        let retained = byKey.values.filter {
            guard let retentionCutoff else { return true }
            return $0.isTemplate || $0.lastCollectedAt >= retentionCutoff
        }
        counts.removedByRetention = byKey.count - retained.count
        let ordered = retained.sorted {
            $0.lastCollectedAt == $1.lastCollectedAt
                ? Self.key($0).lexicographicallyPrecedes(Self.key($1)) : $0.lastCollectedAt > $1.lastCollectedAt
        }
        var historyCount = 0
        var survivors = ordered.filter {
            if $0.isTemplate { return true }
            historyCount += 1
            return historyCount <= historyLimit
        }
        var bytes: Int64 = survivors.reduce(0) { $0 + ($1.isTemplate ? 0 : Int64($1.attachmentByteCount)) }
        var removed = Set<Int>()
        for entry in survivors.reversed() where !entry.isTemplate && (entry.kind == .image || entry.kind == .file) && bytes > Int64(imageByteLimit) {
            bytes -= Int64(entry.attachmentByteCount)
            removed.insert(entry.id)
        }
        survivors.removeAll { removed.contains($0.id) }
        counts.removedByLimit = retained.count - survivors.count
        self.writes = writes
        self.survivors = survivors
        self.removedIDs = Set(byKey.values.map(\.id)).subtracting(survivors.map(\.id))
        self.counts = counts
    }

    private static func key(_ entry: HistoryEntry) -> Data {
        // Swift String equality normalizes Unicode; SQLite BINARY equality does not.
        let domain = entry.isTemplate ? "template:" : "history:"
        if let file = entry.file { return Data("\(domain)file:\(file.hash)".utf8) }
        if entry.kind == .image { return Data("\(domain)image:\(entry.image!.hash)".utf8) }
        let text = entry.isTemplate ? TemplateSyncMerge.normalizeLineEndings(entry.text) : entry.text
        return Data((domain + "text:" + text).utf8)
    }
}

enum HistoryRestore {
    // File placement is inside the DB transaction, after SQL succeeds and before COMMIT.
    // Fresh UUID names ensure rollback only removes files created by this operation.
    static func apply(_ backup: ValidatedBackup, database: HistoryPersistence, files: HistoryImageFiles,
                      cancellation: BackupCancellation,
                      retentionCutoff: Date? = nil,
                      move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
                      progress: (BackupProgress) -> Void = { _ in }) throws -> RestoreCounts {
        var placed = Set<String>()
        let hadDirectory = FileManager.default.fileExists(atPath: files.directory.path)
        defer { backup.discard() }
        do {
            try cancellation.check()
            return try database.mergeBackup(backup.entries, retentionCutoff: retentionCutoff) { survivors in
                let needed = Set(survivors.flatMap { $0.attachmentFilenames })
                progress(BackupProgress(completed: 0, total: backup.entries.count))
                for (index, entry) in backup.entries.enumerated() {
                    try cancellation.check()
                    if !entry.attachmentFilenames.isDisjoint(with: needed) {
                        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
                        for filename in entry.attachmentFilenames.sorted() {
                            let destination = files.url(for: filename)
                            guard !FileManager.default.fileExists(atPath: destination.path) else { throw BackupError.unavailable }
                            // Register before moving, so an injected failure after a move is compensated too.
                            placed.insert(filename)
                            try move(backup.directory.appendingPathComponent(filename), destination)
                        }
                    }
                    progress(BackupProgress(completed: index + 1, total: backup.entries.count))
                }
                try cancellation.check()
            }
        } catch {
            try? files.remove(placed)
            if !hadDirectory { try? FileManager.default.removeItem(at: files.directory) }
            throw error
        }
    }
}
