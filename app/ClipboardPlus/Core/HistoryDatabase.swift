import Foundation
import SQLite3

struct HistoryDeletion: Equatable {
    let id: String
    let expiresAt: Date
    let count: Int
}

enum HistoryDatabaseError: Error {
    case sqlite(Int32)
    case unsupportedVersion(Int)
    case invalidRow
}

final class HistoryDatabase: HistoryPersistence {
    static let schemaVersion = 5
    static let undoInterval: TimeInterval = 5
    private var connection: OpaquePointer?
    private let now: () -> Date
    private let columns = "id, kind, text, saved_at, collected_at, collection_count, pinned, source, image_hash, image_file, thumbnail_file, image_bytes, pixel_width, pixel_height, image_type, file_hash, file_name, original_filename, file_bytes, file_type, title, pin_order, tag"
    private let historyLimit: Int
    private let imageByteLimit: Int
    private var removals: [HistoryEntry] = []

    init(url: URL, now: @escaping () -> Date = Date.init, historyLimit: Int = 1_000,
         imageByteLimit: Int = HistoryImageFiles.maximumTotalByteCount) throws {
        self.now = now
        self.historyLimit = max(0, historyLimit)
        self.imageByteLimit = max(0, imageByteLimit)
        let result = sqlite3_open(url.path, &connection)
        guard result == SQLITE_OK else {
            sqlite3_close(connection)
            connection = nil
            throw HistoryDatabaseError.sqlite(result)
        }
        do {
            try execute("PRAGMA secure_delete = ON")
            let version = try readSchemaVersion()
            guard version <= Self.schemaVersion else { throw HistoryDatabaseError.unsupportedVersion(version) }
            if version == 0 {
                try transaction {
                    try execute("""
                        CREATE TABLE history (
                            id INTEGER PRIMARY KEY AUTOINCREMENT,
                            kind TEXT NOT NULL,
                            text TEXT NOT NULL COLLATE BINARY,
                            saved_at REAL NOT NULL,
                            collected_at REAL NOT NULL,
                            collection_count INTEGER NOT NULL,
                            pinned INTEGER NOT NULL DEFAULT 0,
                            source TEXT NOT NULL,
                            deletion_id TEXT,
                            delete_after REAL
                        )
                        """)
                    try execute("CREATE UNIQUE INDEX history_active_text ON history(text) WHERE deletion_id IS NULL")
                    try execute("CREATE INDEX history_order ON history(collected_at DESC, id DESC)")
                    try execute("PRAGMA user_version = 1")
                }
            }
            if version < 2 {
                try transaction {
                    for column in ["image_hash TEXT", "image_file TEXT", "thumbnail_file TEXT", "image_bytes INTEGER",
                                   "pixel_width INTEGER", "pixel_height INTEGER", "image_type TEXT"] {
                        try execute("ALTER TABLE history ADD COLUMN \(column)")
                    }
                    try execute("DROP INDEX history_active_text")
                    try execute("CREATE UNIQUE INDEX history_active_text ON history(text) WHERE deletion_id IS NULL AND kind != 'image'")
                    try execute("CREATE UNIQUE INDEX history_active_image ON history(image_hash) WHERE deletion_id IS NULL AND kind = 'image'")
                    try execute("PRAGMA user_version = 2")
                }
            }
            if version < 3 {
                try transaction {
                    for column in ["file_hash TEXT", "file_name TEXT", "original_filename TEXT", "file_bytes INTEGER", "file_type TEXT"] {
                        try execute("ALTER TABLE history ADD COLUMN \(column)")
                    }
                    try execute("DROP INDEX history_active_text")
                    try execute("CREATE UNIQUE INDEX history_active_text ON history(text) WHERE deletion_id IS NULL AND kind NOT IN ('image', 'file')")
                    try execute("CREATE UNIQUE INDEX history_active_file ON history(file_hash) WHERE deletion_id IS NULL AND kind = 'file'")
                    try execute("PRAGMA user_version = 3")
                }
            }
            if version < 4 {
                try transaction {
                    try execute("ALTER TABLE history ADD COLUMN title TEXT")
                    try execute("ALTER TABLE history ADD COLUMN pin_order INTEGER")
                    // Include undo-pending pins so undo preserves their previous display order.
                    let legacyTemplates = try rows("SELECT \(columns.replacingOccurrences(of: ", tag", with: ", NULL AS tag")) FROM history WHERE pinned = 1 ORDER BY collected_at DESC, id DESC")
                    for (order, entry) in legacyTemplates.enumerated() {
                        try execute("UPDATE history SET pin_order = ? WHERE id = ?", [.integer(order), .integer(entry.id)])
                    }
                    try execute("PRAGMA user_version = 4")
                }
            }
            if version < 5 {
                try transaction {
                    try execute("ALTER TABLE history ADD COLUMN tag TEXT")
                    // Include pending deletions without changing their undo token or expiry.
                    let templates = try rows("SELECT \(columns) FROM history WHERE pinned = 1 ORDER BY pin_order IS NULL, pin_order, collected_at DESC, id DESC")
                    for (order, entry) in templates.enumerated() {
                        try execute("UPDATE history SET pin_order = ?, tag = NULL WHERE id = ?", [.integer(order), .integer(entry.id)])
                    }
                    for name in ["history_active_text", "history_active_image", "history_active_file"] {
                        try execute("DROP INDEX IF EXISTS \(name)")
                    }
                    // The discriminator separates history and template uniqueness domains.
                    try execute("CREATE UNIQUE INDEX history_active_text ON history(text, pinned) WHERE deletion_id IS NULL AND kind NOT IN ('image', 'file')")
                    try execute("CREATE UNIQUE INDEX history_active_image ON history(image_hash, pinned) WHERE deletion_id IS NULL AND kind = 'image'")
                    try execute("CREATE UNIQUE INDEX history_active_file ON history(file_hash, pinned) WHERE deletion_id IS NULL AND kind = 'file'")
                    try execute("PRAGMA user_version = 5")
                }
            }
            try purgeExpired()
        } catch {
            sqlite3_close(connection)
            connection = nil
            throw error
        }
    }

    deinit { sqlite3_close(connection) }

    func readSchemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { throw HistoryDatabaseError.invalidRow }
        return Int(sqlite3_column_int(statement, 0))
    }

    func fetchAll() throws -> [HistoryEntry] {
        try rows("SELECT \(columns) FROM history WHERE deletion_id IS NULL ORDER BY collected_at DESC, id DESC")
    }

    @discardableResult
    func collect(_ text: String, source: HistorySource, at date: Date? = nil) throws -> HistoryEntry {
        let timestamp = date ?? now()
        return try transaction {
            try purgeExpired()
            let existing = try rows("SELECT \(columns) FROM history WHERE kind NOT IN ('image', 'file') AND text = ? AND pinned = 0 AND deletion_id IS NULL", [.text(text)]).first
            let id: Int
            if let existing {
                id = existing.id
                try execute("UPDATE history SET collected_at = ?, collection_count = MIN(collection_count, \(HistoryCollectionCount.maximum - 1)) + 1, source = ? WHERE id = ?",
                            [.real(max(existing.lastCollectedAt, timestamp).timeIntervalSince1970),
                             .text(timestamp >= existing.lastCollectedAt ? source.rawValue : existing.source.rawValue), .integer(id)])
            } else {
                try execute("INSERT INTO history(kind, text, saved_at, collected_at, collection_count, source) VALUES (?, ?, ?, ?, 1, ?)",
                            [.text(HistoryKind.classify(text).rawValue), .text(text), .real(timestamp.timeIntervalSince1970),
                             .real(timestamp.timeIntervalSince1970), .text(source.rawValue)])
                id = Int(sqlite3_last_insert_rowid(connection))
            }
            let entry = try rows("SELECT \(columns) FROM history WHERE id = ?", [.integer(id)]).first
            try enforceLimit()
            guard let entry else { throw HistoryDatabaseError.invalidRow }
            return entry
        }
    }

    @discardableResult
    func collectImage(_ image: HistoryImage, source: HistorySource, at date: Date?) throws -> HistoryEntry {
        let timestamp = date ?? now()
        return try transaction {
            try purgeExpired()
            let existing = try rows("SELECT \(columns) FROM history WHERE kind = 'image' AND image_hash = ? AND pinned = 0 AND deletion_id IS NULL",
                                    [.text(image.hash)]).first
            let id: Int
            if let existing {
                id = existing.id
                try execute("UPDATE history SET collected_at = ?, collection_count = MIN(collection_count, \(HistoryCollectionCount.maximum - 1)) + 1, source = ? WHERE id = ?",
                            [.real(max(existing.lastCollectedAt, timestamp).timeIntervalSince1970),
                             .text(timestamp >= existing.lastCollectedAt ? source.rawValue : existing.source.rawValue), .integer(id)])
            } else {
                try execute("""
                    INSERT INTO history(kind, text, saved_at, collected_at, collection_count, source,
                        image_hash, image_file, thumbnail_file, image_bytes, pixel_width, pixel_height, image_type)
                    VALUES ('image', '', ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.real(timestamp.timeIntervalSince1970), .real(timestamp.timeIntervalSince1970), .text(source.rawValue),
                          .text(image.hash), .text(image.filename), .text(image.thumbnailFilename), .integer(image.byteCount),
                          .integer(image.pixelWidth), .integer(image.pixelHeight), .text(image.typeIdentifier)])
                id = Int(sqlite3_last_insert_rowid(connection))
            }
            guard let entry = try rows("SELECT \(columns) FROM history WHERE id = ?", [.integer(id)]).first else {
                throw HistoryDatabaseError.invalidRow
            }
            try enforceLimit()
            return entry
        }
    }

    @discardableResult
    func collectFile(_ file: HistoryFile, source: HistorySource, at date: Date?) throws -> HistoryEntry {
        let timestamp = date ?? now()
        return try transaction {
            try purgeExpired()
            let existing = try rows("SELECT \(columns) FROM history WHERE kind = 'file' AND file_hash = ? AND pinned = 0 AND deletion_id IS NULL",
                                    [.text(file.hash)]).first
            let id: Int
            if let existing {
                id = existing.id
                try execute("UPDATE history SET collected_at = ?, collection_count = MIN(collection_count, \(HistoryCollectionCount.maximum - 1)) + 1, source = ? WHERE id = ?",
                            [.real(max(existing.lastCollectedAt, timestamp).timeIntervalSince1970),
                             .text(timestamp >= existing.lastCollectedAt ? source.rawValue : existing.source.rawValue), .integer(id)])
            } else {
                try execute("""
                    INSERT INTO history(kind, text, saved_at, collected_at, collection_count, source,
                        file_hash, file_name, original_filename, file_bytes, file_type)
                    VALUES ('file', '', ?, ?, 1, ?, ?, ?, ?, ?, ?)
                    """, [.real(timestamp.timeIntervalSince1970), .real(timestamp.timeIntervalSince1970), .text(source.rawValue),
                          .text(file.hash), .text(file.filename), .text(file.originalFilename), .integer(file.byteCount),
                          .text(file.typeIdentifier)])
                id = Int(sqlite3_last_insert_rowid(connection))
            }
            guard let entry = try rows("SELECT \(columns) FROM history WHERE id = ?", [.integer(id)]).first else {
                throw HistoryDatabaseError.invalidRow
            }
            try enforceLimit()
            return entry
        }
    }

    @discardableResult
    func moveToTemplates(id: Int) throws -> HistoryEntry {
        try transaction {
            let entry = try activeEntry(id)
            if try equalTemplate(to: entry) != nil { throw HistoryEditError.duplicate }
            try execute("UPDATE history SET pinned = 1, tag = NULL, pin_order = ? WHERE id = ?",
                        [.integer(try nextTemplateOrder(tag: nil)), .integer(id)])
            return try activeEntry(id)
        }
    }

    func createTemplate(text: String, title: String?, tag: String? = nil) throws -> HistoryEntry {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HistoryEditError.empty }
        return try transaction {
            if try activeTemplateText(text) != nil { throw HistoryEditError.duplicate }
            let tag = HistoryEntry.normalizedTag(tag)
            let date = now().timeIntervalSince1970
            try execute("""
                INSERT INTO history(kind, text, saved_at, collected_at, collection_count, pinned, source, title, pin_order, tag)
                VALUES (?, ?, ?, ?, 1, 1, 'written', ?, ?, ?)
                """, [.text(HistoryKind.classify(text).rawValue), .text(text), .real(date), .real(date),
                      titleValue(title), .integer(try nextTemplateOrder(tag: tag)), tagValue(tag)])
            return try activeEntry(Int(sqlite3_last_insert_rowid(connection)))
        }
    }

    func updateTemplate(id: Int, text: String?, title: String?, tag: String?) throws -> HistoryEntry {
        try transaction {
            let entry = try activeEntry(id)
            guard entry.isTemplate else { throw HistoryEditError.unsupportedKind }
            if let text {
                guard entry.kind == .text || entry.kind == .url else { throw HistoryEditError.unsupportedKind }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HistoryEditError.empty }
                if let duplicate = try activeTemplateText(text), duplicate.id != id { throw HistoryEditError.duplicate }
            }
            let tag = HistoryEntry.normalizedTag(tag)
            let order: Int?
            if tag == entry.tag { order = entry.templateOrder }
            else { order = try nextTemplateOrder(tag: tag) }
            try execute("UPDATE history SET text = ?, kind = ?, title = ?, tag = ?, pin_order = ? WHERE id = ?",
                        [.text(text ?? entry.text), .text(text.map { HistoryKind.classify($0).rawValue } ?? entry.kind.rawValue),
                         titleValue(title), tagValue(tag), order.map { .integer($0) } ?? .null, .integer(id)])
            return try activeEntry(id)
        }
    }

    func reorderTemplates(_ orderedIDs: [Int]) throws {
        try transaction {
            let templates = try fetchAll().filter(\.isTemplate)
            let byID = Dictionary(uniqueKeysWithValues: templates.map { ($0.id, $0) })
            var seen = Set<Int>()
            let selected = orderedIDs.compactMap { byID[$0] }.filter { seen.insert($0.id).inserted }
            guard let first = selected.first, selected.allSatisfy({ $0.tag == first.tag }) else { return }
            // The supplied rows trade places among themselves; rows the caller left out, such as
            // ones hidden by a search, stay where they are. The group is then numbered from 0.
            var reordered = selected.makeIterator()
            let group = HistoryEntry.orderedTemplates(templates.filter { $0.tag == first.tag })
            let arranged = group.map { entry in (seen.contains(entry.id) ? reordered.next() : nil) ?? entry }
            for (offset, entry) in arranged.enumerated() where entry.templateOrder != offset {
                try execute("UPDATE history SET pin_order = ? WHERE id = ?", [.integer(offset), .integer(entry.id)])
            }
        }
    }

    func renameTag(_ tag: String?, to newTag: String?) throws {
        try transaction {
            let oldTag = HistoryEntry.normalizedTag(tag)
            let newTag = HistoryEntry.normalizedTag(newTag)
            guard oldTag != newTag else { return }
            let moved = HistoryEntry.orderedTemplates(try fetchAll().filter { $0.isTemplate && $0.tag == oldTag })
            for entry in moved {
                let order = try nextTemplateOrder(tag: newTag)
                try execute("UPDATE history SET tag = ?, pin_order = ? WHERE id = ?",
                            [tagValue(newTag), .integer(order), .integer(entry.id)])
            }
        }
    }

    private func activeEntry(_ id: Int) throws -> HistoryEntry {
        guard let entry = try rows("SELECT \(columns) FROM history WHERE id = ? AND deletion_id IS NULL", [.integer(id)]).first else {
            throw HistoryEditError.failed
        }
        return entry
    }

    private func activeTemplateText(_ text: String) throws -> HistoryEntry? {
        try rows("SELECT \(columns) FROM history WHERE kind IN ('text', 'url') AND text = ? AND pinned = 1 AND deletion_id IS NULL", [.text(text)]).first
    }

    private func equalTemplate(to entry: HistoryEntry) throws -> HistoryEntry? {
        let predicate = entry.kind == .image ? "kind = 'image' AND image_hash = ?"
            : entry.kind == .file ? "kind = 'file' AND file_hash = ?" : "kind IN ('text', 'url') AND text = ?"
        return try rows("SELECT \(columns) FROM history WHERE \(predicate) AND pinned = 1 AND deletion_id IS NULL",
                        [.text(entry.image?.hash ?? entry.file?.hash ?? entry.text)]).first
    }

    private func titleValue(_ title: String?) -> Value {
        HistoryEntry.normalizedTitle(title).map { .text($0) } ?? .null
    }

    private func tagValue(_ tag: String?) -> Value {
        HistoryEntry.normalizedTag(tag).map { .text($0) } ?? .null
    }

    private func nextTemplateOrder(tag: String?) throws -> Int {
        let templates = HistoryEntry.orderedTemplates(try fetchAll().filter { $0.isTemplate && $0.tag == tag })
        guard !templates.isEmpty else { return 0 }
        if templates.allSatisfy({ $0.templateOrder != nil }),
           let maximum = templates.compactMap(\.templateOrder).max(), maximum < Int.max {
            return maximum + 1
        }
        // Normalize missing/overflowing orders before appending, so the new row is last.
        for (offset, entry) in templates.enumerated() {
            try execute("UPDATE history SET pin_order = ? WHERE id = ?", [.integer(offset), .integer(entry.id)])
        }
        return templates.count
    }

    func delete(id: Int) throws -> HistoryDeletion? {
        try markDeleted(predicate: "id = ?", bindings: [.integer(id)])
    }

    func deleteAll() throws -> HistoryDeletion? {
        try markDeleted(predicate: "pinned = 0", bindings: [])
    }

    @discardableResult
    func undo(_ deletion: HistoryDeletion) throws -> Bool {
        try transaction {
            try purgeExpired()
            let deleted = try rows("SELECT \(columns) FROM history WHERE deletion_id = ?", [.text(deletion.id)])
            guard !deleted.isEmpty else { return false }
            for old in deleted {
                let predicate = old.kind == .image ? "kind = 'image' AND image_hash = ?"
                    : old.kind == .file ? "kind = 'file' AND file_hash = ?" : "kind NOT IN ('image', 'file') AND text = ?"
                let key = old.image?.hash ?? old.file?.hash ?? old.text
                let active = try rows("SELECT \(columns) FROM history WHERE \(predicate) AND pinned = ? AND deletion_id IS NULL", [.text(key), .integer(old.isTemplate ? 1 : 0)]).first
                if let active {
                    // A fresh collection during the undo window must survive restoration.
                    let latest = active.lastCollectedAt >= old.lastCollectedAt ? active : old
                    try execute("""
                        UPDATE history SET saved_at = ?, collected_at = ?, collection_count = ?, pinned = ?, source = ?, title = ?, pin_order = ?, tag = ? WHERE id = ?
                        """, [.real(min(old.savedAt, active.savedAt).timeIntervalSince1970),
                              .real(latest.lastCollectedAt.timeIntervalSince1970),
                              .integer(HistoryCollectionCount.adding(old.collectionCount, active.collectionCount)),
                              .integer(old.isTemplate ? 1 : 0), .text(latest.source.rawValue),
                              titleValue(old.title ?? active.title),
                              old.templateOrder.map { .integer($0) } ?? .null, tagValue(old.tag ?? active.tag), .integer(old.id)])
                    try removeRows(predicate: "id = ?", bindings: [.integer(active.id)])
                }
                try execute("UPDATE history SET deletion_id = NULL, delete_after = NULL WHERE id = ?", [.integer(old.id)])
            }
            try enforceLimit()
            return true
        }
    }

    @discardableResult
    func purgeExpired() throws -> Bool {
        try removeRows(predicate: "delete_after <= ?", bindings: [.real(now().timeIntervalSince1970)])
    }

    @discardableResult
    func purgeHistory(olderThan retention: HistoryRetention) throws -> Int {
        guard let cutoff = retention.cutoff(relativeTo: now()) else { return 0 }
        return try transaction {
            let previousCount = removals.count
            try removeRows(predicate: "deletion_id IS NULL AND pinned = 0 AND collected_at < ?",
                           bindings: [.real(cutoff.timeIntervalSince1970)])
            return removals.count - previousCount
        }
    }

    // Drain only after a successful transaction. Rollbacks also roll back this journal.
    func takeRemovals() -> [HistoryEntry] {
        defer { removals.removeAll() }
        return removals
    }

    func referencedImageFiles() throws -> Set<String>? {
        Set(try rows("SELECT \(columns) FROM history WHERE kind IN ('image', 'file')").flatMap { $0.attachmentFilenames })
    }

    func imageUsage() throws -> HistoryImageUsage {
        // Undo-pending originals still occupy space until purge.
        let statement = try prepare("SELECT COUNT(*), COALESCE(SUM(image_bytes), 0) FROM history WHERE kind = 'image'")
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { throw HistoryDatabaseError.invalidRow }
        return HistoryImageUsage(count: Int(sqlite3_column_int64(statement, 0)), byteCount: Int(sqlite3_column_int64(statement, 1)))
    }

    func fileUsage() throws -> HistoryFileUsage {
        // Undo-pending originals still occupy space until purge.
        let statement = try prepare("SELECT COUNT(*), COALESCE(SUM(file_bytes), 0) FROM history WHERE kind = 'file'")
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { throw HistoryDatabaseError.invalidRow }
        return HistoryFileUsage(count: Int(sqlite3_column_int64(statement, 0)), byteCount: Int(sqlite3_column_int64(statement, 1)))
    }

    func latestDeletion() throws -> HistoryDeletion? {
        let statement = try prepare("""
            SELECT deletion_id, delete_after, COUNT(*) FROM history
            WHERE deletion_id IS NOT NULL AND delete_after > ?
            GROUP BY deletion_id, delete_after ORDER BY delete_after DESC, MAX(id) DESC LIMIT 1
            """, [.real(now().timeIntervalSince1970)])
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { return nil }
        return HistoryDeletion(id: string(statement, 0), expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                               count: Int(sqlite3_column_int64(statement, 2)))
    }

    func estimateBackup(_ entries: [HistoryEntry], retentionCutoff: Date? = nil) throws -> RestoreCounts {
        try backupPlan(entries, retentionCutoff: retentionCutoff).counts
    }

    func mergeBackup(_ entries: [HistoryEntry], retentionCutoff: Date? = nil,
                     beforeCommit: ([HistoryEntry]) throws -> Void) throws -> RestoreCounts {
        try transaction {
            let plan = try backupPlan(entries, retentionCutoff: retentionCutoff)
            let existingIDs = Set(try fetchAll().map(\.id))
            for entry in plan.writes {
                if existingIDs.contains(entry.id) {
                    try execute("""
                        UPDATE history SET saved_at = ?, collected_at = ?, collection_count = ?, pinned = ?, source = ?, title = ?, pin_order = ?, tag = ? WHERE id = ?
                        """, [.real(entry.savedAt.timeIntervalSince1970), .real(entry.lastCollectedAt.timeIntervalSince1970),
                              .integer(entry.collectionCount), .integer(entry.isTemplate ? 1 : 0),
                              .text(entry.source.rawValue), titleValue(entry.title), entry.templateOrder.map { .integer($0) } ?? .null, tagValue(entry.tag), .integer(entry.id)])
                } else {
                    try execute("""
                        INSERT INTO history(id, kind, text, saved_at, collected_at, collection_count, pinned, source, title, pin_order, tag)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [.integer(entry.id), .text(entry.kind.rawValue), .text(entry.text),
                              .real(entry.savedAt.timeIntervalSince1970), .real(entry.lastCollectedAt.timeIntervalSince1970),
                              .integer(entry.collectionCount), .integer(entry.isTemplate ? 1 : 0), .text(entry.source.rawValue),
                              titleValue(entry.title), entry.templateOrder.map { .integer($0) } ?? .null, tagValue(entry.tag)])
                    if let file = entry.file {
                        try execute("""
                            UPDATE history SET file_hash = ?, file_name = ?, original_filename = ?, file_bytes = ?, file_type = ? WHERE id = ?
                            """, [.text(file.hash), .text(file.filename), .text(file.originalFilename),
                                  .integer(file.byteCount), .text(file.typeIdentifier), .integer(entry.id)])
                    }
                    if let image = entry.image {
                        try execute("""
                            UPDATE history SET image_hash = ?, image_file = ?, thumbnail_file = ?, image_bytes = ?,
                                pixel_width = ?, pixel_height = ?, image_type = ? WHERE id = ?
                            """, [.text(image.hash), .text(image.filename), .text(image.thumbnailFilename),
                                  .integer(image.byteCount), .integer(image.pixelWidth), .integer(image.pixelHeight),
                                  .text(image.typeIdentifier), .integer(entry.id)])
                    }
                }
            }
            // Use the same removal journal/file cleanup as normal limits. A stable tie
            // order is needed only for restore; collect/collectImage keep their behavior.
            for id in plan.removedIDs.sorted() {
                try removeRows(predicate: "id = ?", bindings: [.integer(id)])
            }
            try enforceLimit()
            try beforeCommit(plan.survivors)
            return plan.counts
        }
    }

    private func backupPlan(_ entries: [HistoryEntry], retentionCutoff: Date?) throws -> HistoryRestorePlan {
        // sqlite_sequence also includes previously deleted rows. Read it without changing the DB.
        let statement = try prepare("SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'history'), 0)")
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { throw HistoryDatabaseError.invalidRow }
        return try HistoryRestorePlan(existing: fetchAll(), incoming: entries,
                                      lastID: Int(sqlite3_column_int64(statement, 0)),
                                      historyLimit: historyLimit, imageByteLimit: imageByteLimit,
                                      retentionCutoff: retentionCutoff)
    }

    private func markDeleted(predicate: String, bindings: [Value]) throws -> HistoryDeletion? {
        try transaction {
            try purgeExpired()
            let id = UUID().uuidString
            let expiry = now().addingTimeInterval(Self.undoInterval)
            try execute("UPDATE history SET deletion_id = ?, delete_after = ? WHERE deletion_id IS NULL AND (\(predicate))",
                        [.text(id), .real(expiry.timeIntervalSince1970)] + bindings)
            let count = Int(sqlite3_changes(connection))
            return count == 0 ? nil : HistoryDeletion(id: id, expiresAt: expiry, count: count)
        }
    }

    private func enforceLimit() throws {
        try removeRows(predicate: """
            id IN (
                SELECT id FROM history WHERE deletion_id IS NULL AND pinned = 0
                ORDER BY collected_at DESC, id DESC LIMIT -1 OFFSET ?
            )
            """, bindings: [.integer(historyLimit)])
        let images = try rows("SELECT \(columns) FROM history WHERE deletion_id IS NULL AND pinned = 0 AND kind IN ('image', 'file') ORDER BY collected_at ASC, id ASC")
        var total = images.reduce(0) { $0 + $1.attachmentByteCount }
        for entry in images where total > imageByteLimit {
            try removeRows(predicate: "id = ?", bindings: [.integer(entry.id)])
            total -= entry.attachmentByteCount
        }
    }

    @discardableResult
    private func removeRows(predicate: String, bindings: [Value]) throws -> Bool {
        let removed = try rows("SELECT \(columns) FROM history WHERE \(predicate)", bindings)
        try execute("DELETE FROM history WHERE \(predicate)", bindings)
        removals.append(contentsOf: removed)
        return !removed.isEmpty
    }

    private enum Value {
        case text(String), integer(Int), real(Double), null
    }

    private func prepare(_ sql: String, _ values: [Value] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw HistoryDatabaseError.sqlite(result)
        }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case .null: result = sqlite3_bind_null(statement, index)
                case .text(let text):
                    guard let byteCount = Int32(exactly: text.utf8.count) else { throw HistoryDatabaseError.sqlite(SQLITE_TOOBIG) }
                    // SQLite must copy Swift's temporary buffer, including embedded NUL bytes.
                    result = text.withCString {
                        sqlite3_bind_text(statement, index, $0, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                case .integer(let number): result = sqlite3_bind_int64(statement, index, Int64(number))
                case .real(let number): result = sqlite3_bind_double(statement, index, number)
                }
                guard result == SQLITE_OK else { throw HistoryDatabaseError.sqlite(result) }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func step(_ statement: OpaquePointer) throws -> Int32 {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw HistoryDatabaseError.sqlite(result) }
        return result
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        while try step(statement) == SQLITE_ROW {}
    }

    private func rows(_ sql: String, _ values: [Value] = []) throws -> [HistoryEntry] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [HistoryEntry] = []
        while try step(statement) == SQLITE_ROW {
            guard let kind = HistoryKind(rawValue: string(statement, 1)),
                  let source = HistorySource(rawValue: string(statement, 7)) else { throw HistoryDatabaseError.invalidRow }
            result.append(HistoryEntry(
                id: Int(sqlite3_column_int64(statement, 0)), kind: kind, text: string(statement, 2),
                savedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                lastCollectedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                collectionCount: Int(sqlite3_column_int64(statement, 5)), isTemplate: sqlite3_column_int(statement, 6) != 0, source: source,
                image: kind == .image ? HistoryImage(
                    hash: string(statement, 8), filename: string(statement, 9), thumbnailFilename: string(statement, 10),
                    byteCount: Int(sqlite3_column_int64(statement, 11)), pixelWidth: Int(sqlite3_column_int64(statement, 12)),
                    pixelHeight: Int(sqlite3_column_int64(statement, 13)), typeIdentifier: string(statement, 14)
                ) : nil,
                file: kind == .file ? HistoryFile(
                    hash: string(statement, 15), filename: string(statement, 16), originalFilename: string(statement, 17),
                    byteCount: Int(sqlite3_column_int64(statement, 18)), typeIdentifier: string(statement, 19)
                ) : nil,
                title: sqlite3_column_type(statement, 20) == SQLITE_NULL ? nil : string(statement, 20),
                templateOrder: sqlite3_column_type(statement, 21) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 21)),
                tag: sqlite3_column_type(statement, 22) == SQLITE_NULL ? nil : string(statement, 22)
            ))
        }
        return result
    }

    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        let previousRemovals = removals.count
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            removals.removeLast(removals.count - previousRemovals)
            throw error
        }
    }
}
