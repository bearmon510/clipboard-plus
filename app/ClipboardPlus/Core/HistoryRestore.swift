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
         unpinnedLimit: Int, imageByteLimit: Int, retentionCutoff: Date? = nil) throws {
        var counts = RestoreCounts()
        var byKey = Dictionary(uniqueKeysWithValues: existing.map { (Self.key($0), $0) })
        var writes: [HistoryEntry] = []
        var nextID = lastID
        for entry in incoming {
            let key = Self.key(entry)
            if let old = byKey[key] {
                // Equal timestamps retain the current source, making repeated restores stable.
                let merged = HistoryEntry(
                    id: old.id, kind: old.kind, text: old.text, savedAt: min(old.savedAt, entry.savedAt),
                    lastCollectedAt: max(old.lastCollectedAt, entry.lastCollectedAt),
                    collectionCount: max(old.collectionCount, entry.collectionCount),
                    isPinned: old.isPinned || entry.isPinned,
                    source: entry.lastCollectedAt > old.lastCollectedAt ? entry.source : old.source, image: old.image)
                if merged == old { counts.unchanged += 1 } else { counts.updated += 1; writes.append(merged) }
                byKey[key] = merged
            } else {
                guard nextID < Int.max else { throw BackupError.unavailable }
                nextID += 1
                let added = HistoryEntry(id: nextID, kind: entry.kind, text: entry.text, savedAt: entry.savedAt,
                                         lastCollectedAt: entry.lastCollectedAt, collectionCount: entry.collectionCount,
                                         isPinned: entry.isPinned, source: entry.source, image: entry.image)
                byKey[key] = added
                writes.append(added)
                counts.added += 1
            }
        }
        // Age is evaluated after merging (newer collection dates and pins win),
        // before either cap. Each removed row belongs to exactly one category.
        let retained = byKey.values.filter {
            guard let retentionCutoff else { return true }
            return $0.isPinned || $0.lastCollectedAt >= retentionCutoff
        }
        counts.removedByRetention = byKey.count - retained.count
        let ordered = retained.sorted {
            $0.lastCollectedAt == $1.lastCollectedAt
                ? Self.key($0).lexicographicallyPrecedes(Self.key($1)) : $0.lastCollectedAt > $1.lastCollectedAt
        }
        var unpinned = 0
        var survivors = ordered.filter {
            if $0.isPinned { return true }
            unpinned += 1
            return unpinned <= unpinnedLimit
        }
        var bytes: Int64 = survivors.reduce(0) { $0 + ($1.isPinned ? 0 : Int64($1.image?.byteCount ?? 0)) }
        var removed = Set<Int>()
        for entry in survivors.reversed() where !entry.isPinned && entry.kind == .image && bytes > Int64(imageByteLimit) {
            bytes -= Int64(entry.image?.byteCount ?? 0)
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
        Data((entry.kind == .image ? "image:\(entry.image!.hash)" : "text:\(entry.text)").utf8)
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
                let needed = Set(survivors.compactMap { $0.image?.filename })
                progress(BackupProgress(completed: 0, total: backup.entries.count))
                for (index, entry) in backup.entries.enumerated() {
                    try cancellation.check()
                    if let image = entry.image, needed.contains(image.filename) {
                        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
                        for filename in [image.filename, image.thumbnailFilename] {
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
