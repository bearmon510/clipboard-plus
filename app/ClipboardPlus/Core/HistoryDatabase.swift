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

struct TemplateSyncRowState: Equatable {
    let id: Int
    let syncId: UUID?
    let updatedAt: Int64?
    let baseHash: String?
    let dirty: Bool
}

struct LocalTemplateSyncSnapshot: Equatable {
    let snapshot: TemplateSyncSnapshot
    let dirtyIDs: Set<UUID>
    let dirtyTombstoneIDs: Set<UUID>
    let skippedOversizedIDs: Set<UUID>
    let skippedOverflowIDs: Set<UUID>
    let skippedOversizedCount: Int
    let skippedOverflowCount: Int

    var excludedIDs: Set<UUID> {
        skippedOversizedIDs.union(skippedOverflowIDs)
    }

    var allTombstoneIDs: Set<UUID> {
        Set(snapshot.tombstones.map(\.id))
    }
}

struct TemplateSyncOutcome: Equatable {
    let added: Int
    let updated: Int
    let deleted: Int
    let pushedToPCCount: Int
    let conflictCopyCount: Int
    let skippedOversizedCount: Int
    let skippedOverflowCount: Int
    let clockSkewSeconds: Int64?

    var hasLocalChanges: Bool { added > 0 || updated > 0 || deleted > 0 }

    func toastMessage(for device: DeviceKind) -> String {
        let base: String
        if hasLocalChanges {
            var parts: [String] = []
            if added > 0 { parts.append("追加 \(added)件") }
            if updated > 0 { parts.append("更新 \(updated)件") }
            if deleted > 0 { parts.append("削除 \(deleted)件") }
            base = "テンプレートを同期しました（\(parts.joined(separator: "・"))）"
        } else if pushedToPCCount > 0 {
            base = "PCへ反映しました（\(pushedToPCCount)件）"
        } else {
            base = "テンプレートは同じ状態です"
        }
        var extras: [String] = []
        if conflictCopyCount > 0 {
            extras.append("別端末の編集 \(conflictCopyCount)件を「その他」に残しました")
        }
        if skippedOversizedCount > 0 {
            extras.append("64KB超 \(skippedOversizedCount)件は対象外")
        }
        if skippedOverflowCount > 0 {
            extras.append("同期上限により \(skippedOverflowCount)件は対象外")
        }
        if clockSkewSeconds != nil {
            extras.append("\(device.name)の時計がずれています")
        }
        guard !extras.isEmpty else { return base }
        return base + "。" + extras.joined(separator: "・")
    }
}

final class HistoryDatabase: HistoryPersistence {
    static let schemaVersion = 6
    static let undoInterval: TimeInterval = 5
    private var connection: OpaquePointer?
    private let now: () -> Date
    private let columns = "id, kind, text, saved_at, collected_at, collection_count, pinned, source, image_hash, image_file, thumbnail_file, image_bytes, pixel_width, pixel_height, image_type, file_hash, file_name, original_filename, file_bytes, file_type, title, pin_order, tag"
    private let syncColumns = "id, kind, text, saved_at, collected_at, collection_count, pinned, source, image_hash, image_file, thumbnail_file, image_bytes, pixel_width, pixel_height, image_type, file_hash, file_name, original_filename, file_bytes, file_type, title, pin_order, tag, template_sync_id, template_updated_at, template_base_hash, template_dirty"
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
            if version < 6 {
                try transaction {
                    try execute("ALTER TABLE history ADD COLUMN template_sync_id TEXT")
                    try execute("ALTER TABLE history ADD COLUMN template_updated_at INTEGER")
                    try execute("ALTER TABLE history ADD COLUMN template_base_hash TEXT")
                    try execute("ALTER TABLE history ADD COLUMN template_dirty INTEGER NOT NULL DEFAULT 0")
                    try execute("""
                        CREATE TABLE template_tombstones (
                            sync_id TEXT PRIMARY KEY,
                            deleted_at INTEGER NOT NULL,
                            base_hash TEXT,
                            synced INTEGER NOT NULL DEFAULT 0
                        )
                        """)
                    // Include undo-pending templates so undo restores a valid sync_id and updated_at.
                    let statement = try prepare("SELECT id, collected_at FROM history WHERE pinned = 1")
                    var legacy: [(id: Int, collectedAt: Double)] = []
                    do {
                        while try step(statement) == SQLITE_ROW {
                            legacy.append((Int(sqlite3_column_int64(statement, 0)), sqlite3_column_double(statement, 1)))
                        }
                        sqlite3_finalize(statement)
                    } catch {
                        sqlite3_finalize(statement)
                        throw error
                    }
                    for row in legacy {
                        let updatedAt = Self.millis(from: row.collectedAt)
                        try execute(
                            "UPDATE history SET template_sync_id = ?, template_updated_at = ?, template_base_hash = NULL, template_dirty = 0 WHERE id = ?",
                            [.text(UUID().uuidString), .int64(updatedAt), .integer(row.id)]
                        )
                    }
                    try execute("CREATE UNIQUE INDEX history_template_sync_id ON history(template_sync_id) WHERE deletion_id IS NULL AND template_sync_id IS NOT NULL")
                    try execute("PRAGMA user_version = 6")
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
            let isTextTemplate = entry.kind == .text || entry.kind == .url
            let normalizedText = isTextTemplate ? TemplateSyncMerge.normalizeLineEndings(entry.text) : entry.text
            if isTextTemplate {
                if try activeTemplateText(normalizedText) != nil ||
                    (!normalizedText.utf8.elementsEqual(entry.text.utf8) && try activeTemplateText(entry.text) != nil) {
                    throw HistoryEditError.duplicate
                }
            } else if try equalTemplate(to: entry) != nil {
                throw HistoryEditError.duplicate
            }
            let syncRow = try templateSyncMetadata(id: id)
            let syncId = syncRow?.syncId?.uuidString ?? UUID().uuidString
            let updatedAt = TemplateSyncMerge.nextUpdatedAt(nowMillis: nowMillis(), existingUpdatedAt: syncRow?.updatedAt)
            if isTextTemplate {
                try execute("""
                    UPDATE history SET kind = ?, text = ?, pinned = 1, tag = NULL, pin_order = ?,
                        template_sync_id = ?, template_updated_at = ?, template_base_hash = NULL, template_dirty = 1
                    WHERE id = ?
                    """, [.text(HistoryKind.classify(normalizedText).rawValue), .text(normalizedText),
                          .integer(try nextTemplateOrder(tag: nil)), .text(syncId), .int64(updatedAt), .integer(id)])
            } else {
                try execute("""
                    UPDATE history SET pinned = 1, tag = NULL, pin_order = ?,
                        template_sync_id = ?, template_updated_at = ?, template_base_hash = NULL, template_dirty = 1
                    WHERE id = ?
                    """, [.integer(try nextTemplateOrder(tag: nil)), .text(syncId), .int64(updatedAt), .integer(id)])
            }
            return try activeEntry(id)
        }
    }

    func createTemplate(text: String, title: String?, tag: String? = nil) throws -> HistoryEntry {
        let normalizedText = TemplateSyncMerge.normalizeLineEndings(text)
        guard !normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HistoryEditError.empty }
        return try transaction {
            if try activeTemplateText(normalizedText) != nil { throw HistoryEditError.duplicate }
            let tag = HistoryEntry.normalizedTag(tag)
            let date = now().timeIntervalSince1970
            let updatedAt = Self.millis(from: date)
            try execute("""
                INSERT INTO history(kind, text, saved_at, collected_at, collection_count, pinned, source, title, pin_order, tag,
                    template_sync_id, template_updated_at, template_base_hash, template_dirty)
                VALUES (?, ?, ?, ?, 1, 1, 'written', ?, ?, ?, ?, ?, NULL, 1)
                """, [.text(HistoryKind.classify(normalizedText).rawValue), .text(normalizedText), .real(date), .real(date),
                      titleValue(title), .integer(try nextTemplateOrder(tag: tag)), tagValue(tag),
                      .text(UUID().uuidString), .int64(updatedAt)])
            return try activeEntry(Int(sqlite3_last_insert_rowid(connection)))
        }
    }

    func updateTemplate(id: Int, text: String?, title: String?, tag: String?) throws -> HistoryEntry {
        try transaction {
            let entry = try activeEntry(id)
            guard entry.isTemplate else { throw HistoryEditError.unsupportedKind }
            let normalizedInputText = text.map { TemplateSyncMerge.normalizeLineEndings($0) }
            if let normalizedInputText {
                guard entry.kind == .text || entry.kind == .url else { throw HistoryEditError.unsupportedKind }
                guard !normalizedInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HistoryEditError.empty }
                if let duplicate = try activeTemplateText(normalizedInputText), duplicate.id != id { throw HistoryEditError.duplicate }
            }
            let newText = normalizedInputText ?? entry.text
            let newKind = normalizedInputText.map { HistoryKind.classify($0) } ?? entry.kind
            let normTitle = HistoryEntry.normalizedTitle(title)
            let newTag = HistoryEntry.normalizedTag(tag)
            let order: Int?
            if Self.utf8Key(newTag) == Self.utf8Key(entry.tag) { order = entry.templateOrder }
            else { order = try nextTemplateOrder(tag: newTag) }
            let changed = !newText.utf8.elementsEqual(entry.text.utf8) || newKind != entry.kind ||
                Self.utf8Key(normTitle) != Self.utf8Key(entry.title) ||
                Self.utf8Key(newTag) != Self.utf8Key(entry.tag) || order != entry.templateOrder
            guard changed else { return entry }
            let syncRow = try templateSyncMetadata(id: id)
            let syncId = syncRow?.syncId?.uuidString ?? UUID().uuidString
            let updatedAt = TemplateSyncMerge.nextUpdatedAt(nowMillis: nowMillis(), existingUpdatedAt: syncRow?.updatedAt)
            try execute("""
                UPDATE history SET text = ?, kind = ?, title = ?, tag = ?, pin_order = ?,
                    template_sync_id = ?, template_updated_at = ?, template_dirty = 1
                WHERE id = ?
                """, [.text(newText), .text(newKind.rawValue),
                      titleValue(title), tagValue(newTag), order.map { .integer($0) } ?? .null,
                      .text(syncId), .int64(updatedAt), .integer(id)])
            return try activeEntry(id)
        }
    }

    func reorderTemplates(_ orderedIDs: [Int]) throws {
        try transaction {
            let templates = try fetchAll().filter(\.isTemplate)
            let byID = Dictionary(uniqueKeysWithValues: templates.map { ($0.id, $0) })
            var seen = Set<Int>()
            let selected = orderedIDs.compactMap { byID[$0] }.filter { seen.insert($0.id).inserted }
            guard let first = selected.first, selected.allSatisfy({ Self.utf8Key($0.tag) == Self.utf8Key(first.tag) }) else { return }
            // The supplied rows trade places among themselves; rows the caller left out, such as
            // ones hidden by a search, stay where they are. The group is then numbered from 0.
            var reordered = selected.makeIterator()
            let group = HistoryEntry.orderedTemplates(templates.filter { Self.utf8Key($0.tag) == Self.utf8Key(first.tag) })
            let arranged = group.map { entry in (seen.contains(entry.id) ? reordered.next() : nil) ?? entry }
            let currentMillis = nowMillis()
            for (offset, entry) in arranged.enumerated() where entry.templateOrder != offset {
                let syncRow = try templateSyncMetadata(id: entry.id)
                let updatedAt = TemplateSyncMerge.nextUpdatedAt(nowMillis: currentMillis, existingUpdatedAt: syncRow?.updatedAt)
                try execute("UPDATE history SET pin_order = ?, template_updated_at = ?, template_dirty = 1 WHERE id = ?",
                            [.integer(offset), .int64(updatedAt), .integer(entry.id)])
            }
        }
    }

    func renameTag(_ tag: String?, to newTag: String?) throws {
        try transaction {
            let oldTag = HistoryEntry.normalizedTag(tag)
            let newTag = HistoryEntry.normalizedTag(newTag)
            guard Self.utf8Key(oldTag) != Self.utf8Key(newTag) else { return }
            let moved = HistoryEntry.orderedTemplates(try fetchAll().filter { $0.isTemplate && Self.utf8Key($0.tag) == Self.utf8Key(oldTag) })
            let currentMillis = nowMillis()
            for entry in moved {
                let order = try nextTemplateOrder(tag: newTag)
                let syncRow = try templateSyncMetadata(id: entry.id)
                let updatedAt = TemplateSyncMerge.nextUpdatedAt(nowMillis: currentMillis, existingUpdatedAt: syncRow?.updatedAt)
                try execute("UPDATE history SET tag = ?, pin_order = ?, template_updated_at = ?, template_dirty = 1 WHERE id = ?",
                            [tagValue(newTag), .integer(order), .int64(updatedAt), .integer(entry.id)])
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
        let templates = HistoryEntry.orderedTemplates(try fetchAll().filter { $0.isTemplate && Self.utf8Key($0.tag) == Self.utf8Key(tag) })
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
            let currentMillis = nowMillis()
            for old in deleted {
                let oldSync = old.isTemplate ? try templateSyncMetadata(id: old.id) : nil
                let predicate = old.kind == .image ? "kind = 'image' AND image_hash = ?"
                    : old.kind == .file ? "kind = 'file' AND file_hash = ?" : "kind NOT IN ('image', 'file') AND text = ?"
                let key = old.image?.hash ?? old.file?.hash ?? old.text
                let active = try rows("SELECT \(columns) FROM history WHERE \(predicate) AND pinned = ? AND deletion_id IS NULL", [.text(key), .integer(old.isTemplate ? 1 : 0)]).first
                if let active {
                    if old.isTemplate, let activeSync = try templateSyncMetadata(id: active.id),
                       let activeSyncId = activeSync.syncId, activeSyncId != oldSync?.syncId,
                       let activeBaseHash = activeSync.baseHash {
                        try execute("""
                            INSERT INTO template_tombstones(sync_id, deleted_at, base_hash, synced)
                            VALUES (?, ?, ?, 0)
                            ON CONFLICT(sync_id) DO UPDATE SET
                                deleted_at = excluded.deleted_at,
                                base_hash = excluded.base_hash,
                                synced = 0
                            """, [.text(activeSyncId.uuidString), .int64(currentMillis), .text(activeBaseHash)])
                    }
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
                if old.isTemplate {
                    let previousSyncId = oldSync?.syncId
                    var syncId = previousSyncId ?? UUID()
                    var clearsBaseHash = false
                    let tombstoneWasSynced: Bool
                    if let previousSyncId {
                        tombstoneWasSynced = try isTombstoneSynced(forSyncID: previousSyncId)
                    } else {
                        tombstoneWasSynced = false
                    }
                    if tombstoneWasSynced {
                        syncId = UUID()
                        clearsBaseHash = true
                    } else if let existingId = try activeID(forSyncID: syncId), existingId != old.id {
                        syncId = UUID()
                        clearsBaseHash = true
                    }
                    if !tombstoneWasSynced {
                        try execute("DELETE FROM template_tombstones WHERE sync_id = ?", [.text(syncId.uuidString)])
                    }
                    let updatedAt = TemplateSyncMerge.nextUpdatedAt(nowMillis: currentMillis, existingUpdatedAt: oldSync?.updatedAt)
                    if clearsBaseHash {
                        try execute("""
                            UPDATE history SET deletion_id = NULL, delete_after = NULL,
                                template_sync_id = ?, template_updated_at = ?, template_base_hash = NULL, template_dirty = 1
                            WHERE id = ?
                            """, [.text(syncId.uuidString), .int64(updatedAt), .integer(old.id)])
                    } else {
                        try execute("""
                            UPDATE history SET deletion_id = NULL, delete_after = NULL,
                                template_sync_id = ?, template_updated_at = ?, template_dirty = 1
                            WHERE id = ?
                            """, [.text(syncId.uuidString), .int64(updatedAt), .integer(old.id)])
                    }
                } else {
                    try execute("UPDATE history SET deletion_id = NULL, delete_after = NULL WHERE id = ?", [.integer(old.id)])
                }
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
            let currentMillis = nowMillis()
            for entry in plan.writes {
                if existingIDs.contains(entry.id) {
                    if entry.isTemplate {
                        let syncRow = try templateSyncMetadata(id: entry.id)
                        let syncId = syncRow?.syncId?.uuidString ?? UUID().uuidString
                        let updatedAt = TemplateSyncMerge.nextUpdatedAt(nowMillis: currentMillis, existingUpdatedAt: syncRow?.updatedAt)
                        try execute("""
                            UPDATE history SET saved_at = ?, collected_at = ?, collection_count = ?, pinned = ?, source = ?, title = ?, pin_order = ?, tag = ?,
                                template_sync_id = ?, template_updated_at = ?, template_dirty = 1
                            WHERE id = ?
                            """, [.real(entry.savedAt.timeIntervalSince1970), .real(entry.lastCollectedAt.timeIntervalSince1970),
                                  .integer(entry.collectionCount), .integer(1),
                                  .text(entry.source.rawValue), titleValue(entry.title), entry.templateOrder.map { .integer($0) } ?? .null, tagValue(entry.tag),
                                  .text(syncId), .int64(updatedAt), .integer(entry.id)])
                    } else {
                        try execute("""
                            UPDATE history SET saved_at = ?, collected_at = ?, collection_count = ?, pinned = ?, source = ?, title = ?, pin_order = ?, tag = ? WHERE id = ?
                            """, [.real(entry.savedAt.timeIntervalSince1970), .real(entry.lastCollectedAt.timeIntervalSince1970),
                                  .integer(entry.collectionCount), .integer(0),
                                  .text(entry.source.rawValue), titleValue(entry.title), entry.templateOrder.map { .integer($0) } ?? .null, tagValue(entry.tag), .integer(entry.id)])
                    }
                } else {
                    let syncIdValue: Value = entry.isTemplate ? .text(UUID().uuidString) : .null
                    let updatedAtValue: Value = entry.isTemplate ? .int64(Self.millis(from: entry.lastCollectedAt.timeIntervalSince1970)) : .null
                    let dirtyValue: Value = .integer(entry.isTemplate ? 1 : 0)
                    try execute("""
                        INSERT INTO history(id, kind, text, saved_at, collected_at, collection_count, pinned, source, title, pin_order, tag,
                            template_sync_id, template_updated_at, template_base_hash, template_dirty)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
                        """, [.integer(entry.id), .text(entry.kind.rawValue), .text(entry.text),
                              .real(entry.savedAt.timeIntervalSince1970), .real(entry.lastCollectedAt.timeIntervalSince1970),
                              .integer(entry.collectionCount), .integer(entry.isTemplate ? 1 : 0), .text(entry.source.rawValue),
                              titleValue(entry.title), entry.templateOrder.map { .integer($0) } ?? .null, tagValue(entry.tag),
                              syncIdValue, updatedAtValue, dirtyValue])
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
            let currentMillis = nowMillis()
            let doomedTemplates = try templateSyncRows("SELECT \(syncColumns) FROM history WHERE deletion_id IS NULL AND pinned = 1 AND (\(predicate))", bindings)
            for row in doomedTemplates {
                if let syncId = row.syncId, let baseHash = row.baseHash {
                    try execute("""
                        INSERT INTO template_tombstones(sync_id, deleted_at, base_hash, synced)
                        VALUES (?, ?, ?, 0)
                        ON CONFLICT(sync_id) DO UPDATE SET
                            deleted_at = excluded.deleted_at,
                            base_hash = excluded.base_hash,
                            synced = 0
                        """, [.text(syncId.uuidString), .int64(currentMillis), .text(baseHash)])
                }
            }
            let id = UUID().uuidString
            let expiry = now().addingTimeInterval(Self.undoInterval)
            try execute("UPDATE history SET deletion_id = ?, delete_after = ? WHERE deletion_id IS NULL AND (\(predicate))",
                        [.text(id), .real(expiry.timeIntervalSince1970)] + bindings)
            let count = Int(sqlite3_changes(connection))
            return count == 0 ? nil : HistoryDeletion(id: id, expiresAt: expiry, count: count)
        }
    }

    // MARK: Template sync

    func templateSyncMetadata(id: Int) throws -> TemplateSyncRowState? {
        let statement = try prepare(
            "SELECT id, template_sync_id, template_updated_at, template_base_hash, template_dirty FROM history WHERE id = ?",
            [.integer(id)]
        )
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { return nil }
        let syncId = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : UUID(uuidString: string(statement, 1))
        let updatedAt: Int64? = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 2)
        let baseHash = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : string(statement, 3)
        let dirty = sqlite3_column_int(statement, 4) != 0
        return TemplateSyncRowState(id: Int(sqlite3_column_int64(statement, 0)), syncId: syncId, updatedAt: updatedAt, baseHash: baseHash, dirty: dirty)
    }

    func templateTombstones() throws -> [TemplateSyncTombstone] {
        try fetchTombstoneRows().map { TemplateSyncTombstone(id: $0.id, deletedAt: $0.deletedAt, baseHash: $0.baseHash) }
    }

    func resetTemplateSyncState() throws {
        try transaction {
            try execute("DELETE FROM template_tombstones")
            try execute("UPDATE history SET template_base_hash = NULL, template_dirty = 0")
        }
    }

    func readTemplateSyncSnapshot() throws -> LocalTemplateSyncSnapshot {
        try transaction {
            try purgeExpired()
            let currentMillis = nowMillis()
            try pruneTombstones(nowMillis: currentMillis)

            var activeRows = try fetchActiveTemplateSyncRows()
            for index in activeRows.indices where activeRows[index].entry.kind == .text || activeRows[index].entry.kind == .url {
                var row = activeRows[index]
                var repaired = false
                let syncId: UUID
                if let existingId = row.syncId {
                    syncId = existingId
                } else {
                    syncId = UUID()
                    repaired = true
                }
                let updatedAt: Int64
                if let existingUpdated = row.updatedAt {
                    updatedAt = existingUpdated
                } else {
                    updatedAt = Self.millis(from: row.entry.lastCollectedAt.timeIntervalSince1970)
                    repaired = true
                }
                if repaired {
                    try execute("UPDATE history SET template_sync_id = ?, template_updated_at = ? WHERE id = ?",
                                [.text(syncId.uuidString), .int64(updatedAt), .integer(row.entry.id)])
                    row = SyncTemplateRow(entry: row.entry, syncId: syncId, updatedAt: updatedAt, baseHash: row.baseHash, dirty: row.dirty)
                    activeRows[index] = row
                }
            }

            let textRows = activeRows.filter { $0.entry.kind == .text || $0.entry.kind == .url }
            let rowByID = Dictionary(uniqueKeysWithValues: textRows.map { ($0.entry.id, $0) })
            let groups = TemplateGroups.make(textRows.map(\.entry), search: "")

            var items: [TemplateSyncItem] = []
            var dirtyIDs = Set<UUID>()
            var skippedOversizedIDs = Set<UUID>()
            var orderByTag: [Data?: Int] = [:]

            for group in groups {
                for entry in group.entries {
                    guard let row = rowByID[entry.id], let syncId = row.syncId, let rowUpdatedAt = row.updatedAt else { continue }
                    let normalizedText = TemplateSyncMerge.normalizeLineEndings(entry.text)
                    if normalizedText.utf8.count > SyncProtocol.maxTemplateTextBytes {
                        skippedOversizedIDs.insert(syncId)
                        continue
                    }
                    let title = Self.sanitizedTitleForSync(entry.title)
                    let tag = Self.sanitizedTagForSync(entry.tag)
                    let tagKey = Self.utf8Key(tag)
                    let order = orderByTag[tagKey, default: 0]
                    orderByTag[tagKey] = order + 1
                    let updatedAt = Self.clampedTimestamp(rowUpdatedAt)
                    let validBaseHash = row.baseHash.flatMap { SyncProtocol.isLowerHex64($0) ? $0 : nil }
                    let item = TemplateSyncItem(
                        id: syncId,
                        kind: entry.kind == .url ? .url : .text,
                        text: normalizedText,
                        title: title,
                        tag: tag,
                        order: order,
                        updatedAt: updatedAt,
                        baseHash: validBaseHash
                    )
                    if validBaseHash == nil || row.dirty || validBaseHash != TemplateSyncMerge.contentHash(item) {
                        dirtyIDs.insert(syncId)
                    }
                    items.append(item)
                }
            }

            let candidateIDs = Set(items.map(\.id))
            let activeSyncIDs = candidateIDs.union(skippedOversizedIDs)
            let tombRows = try fetchTombstoneRows()
            var tombstones: [TemplateSyncTombstone] = []
            var dirtyTombstoneIDs = Set<UUID>()
            for row in tombRows where !activeSyncIDs.contains(row.id) {
                tombstones.append(TemplateSyncTombstone(id: row.id, deletedAt: row.deletedAt, baseHash: row.baseHash))
                if !row.synced {
                    dirtyTombstoneIDs.insert(row.id)
                }
            }

            let prepared = try TemplateSyncMerge.prepareSyncState(
                templates: items, tombstones: tombstones, nowMillis: currentMillis, sentAtMillis: currentMillis
            )
            let selectedIDs = Set(prepared.state.templates.map(\.id))
            return LocalTemplateSyncSnapshot(
                snapshot: TemplateSyncSnapshot(sentAt: currentMillis, templates: prepared.state.templates, tombstones: prepared.state.tombstones),
                dirtyIDs: dirtyIDs.intersection(selectedIDs),
                dirtyTombstoneIDs: dirtyTombstoneIDs.intersection(prepared.state.tombstones.map(\.id)),
                skippedOversizedIDs: skippedOversizedIDs,
                skippedOverflowIDs: candidateIDs.subtracting(selectedIDs),
                skippedOversizedCount: skippedOversizedIDs.count,
                skippedOverflowCount: prepared.excludedTemplateCount
            )
        }
    }

    func applySyncedTemplates(_ snapshot: TemplateSyncSnapshot, pushed: LocalTemplateSyncSnapshot? = nil) throws -> TemplateSyncOutcome {
        try transaction {
            try purgeExpired()
            let currentDate = now()
            let currentMillis = Self.millis(from: currentDate.timeIntervalSince1970)
            let clockSkewSeconds = try? TemplateSyncMerge.clockSkewSeconds(remoteSentAtMillis: snapshot.sentAt, nowMillis: currentMillis)

            let activeRows = try fetchActiveTemplateSyncRows()
            let activeSyncIDs = Set(activeRows.compactMap(\.syncId))
            let existingTombstones = try fetchTombstoneRows()
            let pushedByID: [UUID: TemplateSyncItem] = Dictionary(
                (pushed?.snapshot.templates ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let pushedHashByID: [UUID: String] = pushedByID.mapValues { TemplateSyncMerge.contentHash($0) }
            let pushedIDs = Set(pushedByID.keys)
            let pushedTombIDs = pushed?.allTombstoneIDs ?? []
            let excludedIDs = pushed?.excludedIDs ?? []
            let midSyncLocalTombByID: [UUID: TombstoneRow] = pushed == nil ? [:] : Dictionary(
                existingTombstones.filter { !$0.synced && !pushedTombIDs.contains($0.id) }.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let snapshotTombstoneByID: [UUID: TemplateSyncTombstone] = Dictionary(
                snapshot.tombstones.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            var preservedLocal: [SyncTemplateRow] = []
            var syncManaged: [SyncTemplateRow] = []
            var protectedIDs = Set<UUID>()
            var protectedTexts = Set<Data>()
            var oversizedCount = 0
            for row in activeRows {
                if row.entry.kind == .image || row.entry.kind == .file {
                    preservedLocal.append(row)
                    continue
                }
                let normRowText = TemplateSyncMerge.normalizeLineEndings(row.entry.text)
                let oversized = normRowText.utf8.count > SyncProtocol.maxTemplateTextBytes
                if oversized { oversizedCount += 1 }
                if oversized || row.syncId.map(excludedIDs.contains) == true {
                    preservedLocal.append(row)
                    if let id = row.syncId { protectedIDs.insert(id) }
                    protectedTexts.insert(Data(normRowText.utf8))
                } else if pushed != nil && row.baseHash == nil && row.syncId.map(pushedIDs.contains) != true {
                    preservedLocal.append(row)
                } else {
                    syncManaged.append(row)
                }
            }

            struct IncomingTemplate {
                let item: TemplateSyncItem
                let normTitle: String?
                let normTag: String?
                let hash: String
                let normalizedOrder: Int
            }
            // A peer may still have an older version of a locally excluded template,
            // or a template the user deleted locally while sync was in flight.
            var suppressedMidSyncDeletes: [UUID: TombstoneRow] = [:]
            var seenIncomingTexts = Set<Data>()
            let rawIncoming: [(item: TemplateSyncItem, normTitle: String?, normTag: String?, hash: String)] = snapshot.templates.compactMap { raw in
                let normText = TemplateSyncMerge.normalizeLineEndings(raw.text)
                let normTextBytes = Data(normText.utf8)
                guard !protectedIDs.contains(raw.id), !protectedTexts.contains(normTextBytes) else { return nil }
                let normTitle = TemplateSyncMerge.normalizedTitle(raw.title)
                let normTag = TemplateSyncMerge.normalizedTag(raw.tag)
                let normalized = TemplateSyncItem(
                    id: raw.id,
                    kind: raw.kind,
                    text: normText,
                    title: normTitle,
                    tag: normTag,
                    order: raw.order,
                    updatedAt: Self.clampedTimestamp(raw.updatedAt),
                    baseHash: nil
                )
                let hash = TemplateSyncMerge.contentHash(normalized)
                if pushed != nil && !activeSyncIDs.contains(raw.id) {
                    if let tomb = midSyncLocalTombByID[raw.id],
                       tomb.baseHash == hash || pushedHashByID[raw.id] == hash {
                        suppressedMidSyncDeletes[raw.id] = TombstoneRow(
                            id: raw.id, deletedAt: tomb.deletedAt, baseHash: hash, synced: false
                        )
                        return nil
                    }
                    if let pushedHash = pushedHashByID[raw.id], pushedHash == hash {
                        suppressedMidSyncDeletes[raw.id] = TombstoneRow(
                            id: raw.id, deletedAt: currentMillis, baseHash: hash, synced: false
                        )
                        return nil
                    }
                }
                guard seenIncomingTexts.insert(normTextBytes).inserted else { return nil }
                return (normalized, normTitle, normTag, hash)
            }
            var incomingOrderByTag: [Data?: Int] = [:]
            var incoming: [IncomingTemplate] = []
            incoming.reserveCapacity(rawIncoming.count)
            // Group incoming orders densely per tag so SQLite pin_order stays contiguous from 0.
            let groupedIndices = Dictionary(grouping: rawIncoming.indices, by: { Self.utf8Key(rawIncoming[$0].normTag) })
            var assignedOrder = Array(repeating: 0, count: rawIncoming.count)
            for indices in groupedIndices.values {
                let sorted = indices.sorted { lhs, rhs in
                    if rawIncoming[lhs].item.order != rawIncoming[rhs].item.order {
                        return rawIncoming[lhs].item.order < rawIncoming[rhs].item.order
                    }
                    return lhs < rhs
                }
                for (offset, idx) in sorted.enumerated() {
                    assignedOrder[idx] = offset
                }
            }
            for index in rawIncoming.indices {
                let raw = rawIncoming[index]
                let ord = assignedOrder[index]
                let tagKey = Self.utf8Key(raw.normTag)
                incomingOrderByTag[tagKey] = max(incomingOrderByTag[tagKey, default: 0], ord + 1)
                let itemWithOrder = TemplateSyncItem(
                    id: raw.item.id, kind: raw.item.kind, text: raw.item.text,
                    title: raw.normTitle, tag: raw.normTag, order: ord, updatedAt: raw.item.updatedAt, baseHash: nil
                )
                incoming.append(IncomingTemplate(item: itemWithOrder, normTitle: raw.normTitle, normTag: raw.normTag, hash: raw.hash, normalizedOrder: ord))
            }

            // Build comparable pre-sync items for sync-managed rows.
            struct BeforeInfo {
                let item: TemplateSyncItem
                let wasDirty: Bool
            }
            var beforeByRowID: [Int: BeforeInfo] = [:]
            let syncManagedByID = Dictionary(uniqueKeysWithValues: syncManaged.map { ($0.entry.id, $0) })
            var beforeOrderByTag: [Data?: Int] = [:]
            for group in TemplateGroups.make(syncManaged.map(\.entry), search: "") {
                for entry in group.entries {
                    guard let row = syncManagedByID[entry.id] else { continue }
                    let title = Self.sanitizedTitleForSync(entry.title)
                    let tag = Self.sanitizedTagForSync(entry.tag)
                    let tagKey = Self.utf8Key(tag)
                    let order = beforeOrderByTag[tagKey, default: 0]
                    beforeOrderByTag[tagKey] = order + 1
                    let item = TemplateSyncItem(
                        id: row.syncId ?? UUID(),
                        kind: entry.kind == .url ? .url : .text,
                        text: entry.text,
                        title: title,
                        tag: tag,
                        order: order,
                        updatedAt: row.updatedAt ?? 0,
                        baseHash: row.baseHash
                    )
                    let hash = TemplateSyncMerge.contentHash(item)
                    let validBaseHash = row.baseHash.flatMap { SyncProtocol.isLowerHex64($0) ? $0 : nil }
                    let wasDirty = validBaseHash == nil || row.dirty || validBaseHash != hash
                    beforeByRowID[entry.id] = BeforeInfo(item: item, wasDirty: wasDirty)
                }
            }

            // Match incoming items against active text/url rows (not oversized).
            let matchCandidates = (syncManaged + preservedLocal).filter {
                ($0.entry.kind == .text || $0.entry.kind == .url) &&
                    TemplateSyncMerge.normalizeLineEndings($0.entry.text).utf8.count <= SyncProtocol.maxTemplateTextBytes
            }
            var claimedRowIDs = Set<Int>()
            var matchedForIncoming = Array<SyncTemplateRow?>(repeating: nil, count: incoming.count)

            var candidateBySyncID: [UUID: SyncTemplateRow] = [:]
            for row in matchCandidates {
                if let sid = row.syncId, candidateBySyncID[sid] == nil {
                    candidateBySyncID[sid] = row
                }
            }
            for index in incoming.indices {
                if let row = candidateBySyncID[incoming[index].item.id], claimedRowIDs.insert(row.entry.id).inserted {
                    matchedForIncoming[index] = row
                }
            }
            var candidateByTextBytes: [Data: SyncTemplateRow] = [:]
            for row in matchCandidates where !claimedRowIDs.contains(row.entry.id) {
                let bytes = Data(row.entry.text.utf8)
                if candidateByTextBytes[bytes] == nil {
                    candidateByTextBytes[bytes] = row
                }
            }
            for index in incoming.indices where matchedForIncoming[index] == nil {
                let bytes = Data(incoming[index].item.text.utf8)
                if let row = candidateByTextBytes[bytes], claimedRowIDs.insert(row.entry.id).inserted {
                    matchedForIncoming[index] = row
                }
            }
            // Fallback match for legacy CRLF/CR rows so existing integer IDs survive LF normalization.
            var candidateByNormTextBytes: [Data: SyncTemplateRow] = [:]
            for row in matchCandidates where !claimedRowIDs.contains(row.entry.id) {
                let bytes = Data(TemplateSyncMerge.normalizeLineEndings(row.entry.text).utf8)
                if candidateByNormTextBytes[bytes] == nil {
                    candidateByNormTextBytes[bytes] = row
                }
            }
            for index in incoming.indices where matchedForIncoming[index] == nil {
                let bytes = Data(incoming[index].item.text.utf8)
                if let row = candidateByNormTextBytes[bytes], claimedRowIDs.insert(row.entry.id).inserted {
                    matchedForIncoming[index] = row
                }
            }

            struct MatchedUpdate {
                let row: SyncTemplateRow
                let incoming: IncomingTemplate
                let keptMidSyncLocalEdit: Bool
                let keptBaseHash: String?
            }
            var matchedUpdates: [MatchedUpdate] = []
            var additions: [IncomingTemplate] = []

            for index in incoming.indices {
                let inc = incoming[index]
                guard let row = matchedForIncoming[index] else {
                    additions.append(inc)
                    continue
                }
                let canKeepLocalEdit: Bool
                let keptBaseHash: String?
                let pushedItem = pushedByID[inc.item.id] ?? row.syncId.flatMap { pushedByID[$0] }
                if let pushedItem,
                   let rowUpdatedAt = row.updatedAt,
                   rowUpdatedAt > pushedItem.updatedAt,
                   row.dirty {
                    let rowTextBytes = Data(TemplateSyncMerge.normalizeLineEndings(row.entry.text).utf8)
                    let collidesWithOtherIncoming = incoming.indices.contains { otherIdx in
                        otherIdx != index && Data(incoming[otherIdx].item.text.utf8) == rowTextBytes
                    }
                    if !collidesWithOtherIncoming {
                        canKeepLocalEdit = true
                        let pushedHash = pushedHashByID[pushedItem.id]
                        if pushedHash == inc.hash {
                            keptBaseHash = inc.hash
                        } else {
                            // PC also modified this item concurrently; keep the pre-sync baseHash
                            // so the next sync detects a 3-way conflict instead of discarding PC's edit.
                            keptBaseHash = row.syncId == inc.item.id ? pushedItem.baseHash : nil
                        }
                    } else {
                        canKeepLocalEdit = false
                        keptBaseHash = nil
                    }
                } else {
                    canKeepLocalEdit = false
                    keptBaseHash = nil
                }
                matchedUpdates.append(MatchedUpdate(row: row, incoming: inc, keptMidSyncLocalEdit: canKeepLocalEdit, keptBaseHash: keptBaseHash))
            }

            var writtenIncomingTextSet = Set<Data>()
            for inc in additions {
                writtenIncomingTextSet.insert(Data(inc.item.text.utf8))
            }
            for update in matchedUpdates where !update.keptMidSyncLocalEdit {
                writtenIncomingTextSet.insert(Data(update.incoming.item.text.utf8))
            }

            struct PreservedMidSyncRow {
                let row: SyncTemplateRow
                let finalSyncId: UUID
            }
            var preservedMidSyncEdits: [PreservedMidSyncRow] = []
            if pushed != nil {
                for row in syncManaged where !claimedRowIDs.contains(row.entry.id) && row.dirty {
                    let rawTextBytes = Data(row.entry.text.utf8)
                    let normTextBytes = Data(TemplateSyncMerge.normalizeLineEndings(row.entry.text).utf8)
                    guard !writtenIncomingTextSet.contains(rawTextBytes),
                          !writtenIncomingTextSet.contains(normTextBytes) else { continue }
                    if let sid = row.syncId, let pushedItem = pushedByID[sid],
                       let rowUpdatedAt = row.updatedAt, rowUpdatedAt > pushedItem.updatedAt {
                        // Edited mid-sync while PC deleted it; preserve locally instead of dropping the edit.
                        let pcTombHasNilHash = snapshotTombstoneByID[sid] != nil && snapshotTombstoneByID[sid]?.baseHash == nil
                        let finalSyncId = pcTombHasNilHash ? UUID() : sid
                        preservedMidSyncEdits.append(PreservedMidSyncRow(row: row, finalSyncId: finalSyncId))
                    } else if let sid = row.syncId, pushedTombIDs.contains(sid) {
                        // Restored via undo mid-sync after its deletion tombstone was already pushed;
                        // assign a fresh UUID so the synced tombstone on PC will not re-delete it.
                        preservedMidSyncEdits.append(PreservedMidSyncRow(row: row, finalSyncId: UUID()))
                    } else if row.syncId.map(pushedIDs.contains) != true {
                        let finalSyncId = row.syncId ?? UUID()
                        preservedMidSyncEdits.append(PreservedMidSyncRow(row: row, finalSyncId: finalSyncId))
                    }
                }
            }
            let preservedMidSyncRowIDs = Set(preservedMidSyncEdits.map { $0.row.entry.id })

            let addedCount = additions.count
            let deletedCount = syncManaged.filter {
                !claimedRowIDs.contains($0.entry.id) && !preservedMidSyncRowIDs.contains($0.entry.id)
            }.count
            var updatedCount = 0
            for update in matchedUpdates where !update.keptMidSyncLocalEdit {
                let inc = update.incoming
                let row = update.row
                if let before = beforeByRowID[row.entry.id] {
                    if before.item.kind != inc.item.kind ||
                        !before.item.text.utf8.elementsEqual(inc.item.text.utf8) ||
                        Self.utf8Key(before.item.title) != Self.utf8Key(inc.normTitle) ||
                        Self.utf8Key(before.item.tag) != Self.utf8Key(inc.normTag) ||
                        before.item.order != inc.normalizedOrder {
                        updatedCount += 1
                    }
                } else {
                    let kind = row.entry.kind == .url ? TemplateSyncKind.url : .text
                    if kind != inc.item.kind ||
                        !row.entry.text.utf8.elementsEqual(inc.item.text.utf8) ||
                        Self.utf8Key(Self.sanitizedTitleForSync(row.entry.title)) != Self.utf8Key(inc.normTitle) ||
                        Self.utf8Key(Self.sanitizedTagForSync(row.entry.tag)) != Self.utf8Key(inc.normTag) ||
                        row.entry.templateOrder != inc.normalizedOrder {
                        updatedCount += 1
                    }
                }
            }

            let incomingActiveIDs = Set(incoming.map(\.item.id))
            let keptActiveSyncIDs = incomingActiveIDs.union(preservedMidSyncEdits.map(\.finalSyncId))
            var keptMidSyncTombByID = suppressedMidSyncDeletes
            if pushed != nil {
                for tomb in existingTombstones where !tomb.synced && !pushedTombIDs.contains(tomb.id) && !keptActiveSyncIDs.contains(tomb.id) {
                    if keptMidSyncTombByID[tomb.id] == nil {
                        keptMidSyncTombByID[tomb.id] = tomb
                    }
                }
            }
            let keptMidSyncTombIDs = Set(keptMidSyncTombByID.keys)

            var pushedToPCCount = 0
            if addedCount == 0 && updatedCount == 0 && deletedCount == 0 {
                pushedToPCCount = beforeByRowID.values.filter(\.wasDirty).count
                    + existingTombstones.filter { !$0.synced && !keptMidSyncTombIDs.contains($0.id) && !keptActiveSyncIDs.contains($0.id) }.count
            }

            let hadSharedDirtyItem = matchedUpdates.contains { beforeByRowID[$0.row.entry.id]?.wasDirty == true }
            let conflictCopyCount: Int
            if hadSharedDirtyItem {
                conflictCopyCount = additions.filter { inc in
                    inc.normTag == nil && (inc.normTitle == "別の端末の編集" || inc.normTitle?.hasSuffix("（別の端末の編集）") == true)
                }.count
            } else {
                conflictCopyCount = 0
            }

            // 1. Reassign sync_id on any undo-pending rows whose sync_id becomes active.
            for undoRow in try fetchUndoPendingTemplateSyncRows() where undoRow.syncId.map({ keptActiveSyncIDs.contains($0) }) == true {
                try execute("UPDATE history SET template_sync_id = ?, template_base_hash = NULL WHERE id = ?",
                            [.text(UUID().uuidString), .integer(undoRow.id)])
            }

            // 2. Delete removed sync-managed rows and any unclaimed non-oversized local rows colliding by text.
            for row in syncManaged where !claimedRowIDs.contains(row.entry.id) && !preservedMidSyncRowIDs.contains(row.entry.id) {
                try execute("DELETE FROM history WHERE id = ?", [.integer(row.entry.id)])
            }
            for row in preservedLocal where !claimedRowIDs.contains(row.entry.id) &&
                (row.entry.kind == .text || row.entry.kind == .url) &&
                TemplateSyncMerge.normalizeLineEndings(row.entry.text).utf8.count <= SyncProtocol.maxTemplateTextBytes {
                let rawTextBytes = Data(row.entry.text.utf8)
                let normTextBytes = Data(TemplateSyncMerge.normalizeLineEndings(row.entry.text).utf8)
                if writtenIncomingTextSet.contains(rawTextBytes) || writtenIncomingTextSet.contains(normTextBytes) {
                    try execute("DELETE FROM history WHERE id = ?", [.integer(row.entry.id)])
                }
            }

            // 3. Clear colliding text / sync_id temporarily so swaps never trigger unique constraints.
            for update in matchedUpdates where !update.keptMidSyncLocalEdit {
                let inc = update.incoming
                let row = update.row
                let textChanged = !row.entry.text.utf8.elementsEqual(inc.item.text.utf8)
                let idChanged = row.syncId != inc.item.id
                if textChanged || idChanged {
                    try execute("UPDATE history SET text = ?, template_sync_id = NULL WHERE id = ?",
                                [.text("\0__tplsync__\(row.entry.id)_\(UUID().uuidString)"), .integer(row.entry.id)])
                }
            }

            // 4. Write updated rows, preserve mid-sync edits/undos, and insert newly added rows.
            for update in matchedUpdates {
                let inc = update.incoming
                let row = update.row
                if update.keptMidSyncLocalEdit {
                    try execute("UPDATE history SET template_sync_id = ?, template_base_hash = ?, template_dirty = 1 WHERE id = ?",
                                [.text(inc.item.id.uuidString), update.keptBaseHash.map { .text($0) } ?? .null, .integer(row.entry.id)])
                } else {
                    try execute("""
                        UPDATE history SET kind = ?, text = ?, title = ?, tag = ?, pin_order = ?,
                            template_sync_id = ?, template_updated_at = ?, template_base_hash = ?, template_dirty = 0
                        WHERE id = ?
                        """, [.text(inc.item.kind.rawValue), .text(inc.item.text),
                              inc.normTitle.map { .text($0) } ?? .null, inc.normTag.map { .text($0) } ?? .null,
                              .integer(inc.normalizedOrder), .text(inc.item.id.uuidString),
                              .int64(inc.item.updatedAt), .text(inc.hash), .integer(row.entry.id)])
                }
            }
            for preserved in preservedMidSyncEdits {
                try execute("UPDATE history SET template_sync_id = ?, template_base_hash = NULL, template_dirty = 1 WHERE id = ?",
                            [.text(preserved.finalSyncId.uuidString), .integer(preserved.row.entry.id)])
            }

            let dateReal = currentDate.timeIntervalSince1970
            for inc in additions {
                try execute("""
                    INSERT INTO history(kind, text, saved_at, collected_at, collection_count, pinned, source,
                        title, pin_order, tag, template_sync_id, template_updated_at, template_base_hash, template_dirty)
                    VALUES (?, ?, ?, ?, 1, 1, 'written', ?, ?, ?, ?, ?, ?, 0)
                    """, [.text(inc.item.kind.rawValue), .text(inc.item.text), .real(dateReal), .real(dateReal),
                          inc.normTitle.map { .text($0) } ?? .null, .integer(inc.normalizedOrder),
                          inc.normTag.map { .text($0) } ?? .null, .text(inc.item.id.uuidString),
                          .int64(inc.item.updatedAt), .text(inc.hash)])
            }

            // 5. Place remaining preserved local-only templates cleanly after synced items in each tag.
            let remainingPreserved = preservedLocal.filter { row in
                guard !claimedRowIDs.contains(row.entry.id) else { return false }
                if (row.entry.kind == .text || row.entry.kind == .url) &&
                    TemplateSyncMerge.normalizeLineEndings(row.entry.text).utf8.count <= SyncProtocol.maxTemplateTextBytes {
                    let rawTextBytes = Data(row.entry.text.utf8)
                    let normTextBytes = Data(TemplateSyncMerge.normalizeLineEndings(row.entry.text).utf8)
                    if writtenIncomingTextSet.contains(rawTextBytes) || writtenIncomingTextSet.contains(normTextBytes) {
                        return false
                    }
                }
                return true
            } + preservedMidSyncEdits.map(\.row)
            if !remainingPreserved.isEmpty {
                var nextOrderByTag = incomingOrderByTag
                for group in TemplateGroups.make(remainingPreserved.map(\.entry), search: "") {
                    for entry in group.entries {
                        let tagKey = Self.utf8Key(entry.tag)
                        let nextOrder = nextOrderByTag[tagKey, default: 0]
                        nextOrderByTag[tagKey] = nextOrder + 1
                        if entry.templateOrder != nextOrder {
                            try execute("UPDATE history SET pin_order = ? WHERE id = ?",
                                        [.integer(nextOrder), .integer(entry.id)])
                        }
                    }
                }
            }

            // 6. Replace tombstones, keeping any local tombstone created after tpl_push was built.
            let syncedDeletedAtByID = Dictionary(uniqueKeysWithValues: existingTombstones.filter(\.synced).map { ($0.id, $0.deletedAt) })
            let clockOffset = currentMillis - Self.clampedTimestamp(snapshot.sentAt)
            try execute("DELETE FROM template_tombstones")
            for tomb in snapshot.tombstones where !keptActiveSyncIDs.contains(tomb.id) && !keptMidSyncTombIDs.contains(tomb.id) {
                let validHash = tomb.baseHash.flatMap { SyncProtocol.isLowerHex64($0) ? $0 : nil }
                // Store PC tombstones in the same clock as locally created tombstones and sentAt.
                let adjusted = min(currentMillis, Self.clampedTimestamp(Self.clampedTimestamp(tomb.deletedAt) + clockOffset))
                let deletedAt = min(adjusted, syncedDeletedAtByID[tomb.id] ?? adjusted)
                try execute("""
                    INSERT INTO template_tombstones(sync_id, deleted_at, base_hash, synced)
                    VALUES (?, ?, ?, 1)
                    """, [.text(tomb.id.uuidString), .int64(deletedAt),
                          validHash.map { .text($0) } ?? .null])
            }
            for tomb in keptMidSyncTombByID.values {
                try execute("""
                    INSERT INTO template_tombstones(sync_id, deleted_at, base_hash, synced)
                    VALUES (?, ?, ?, 0)
                    """, [.text(tomb.id.uuidString), .int64(tomb.deletedAt),
                          tomb.baseHash.map { .text($0) } ?? .null])
            }
            try pruneTombstones(nowMillis: currentMillis)

            return TemplateSyncOutcome(
                added: addedCount,
                updated: updatedCount,
                deleted: deletedCount,
                pushedToPCCount: pushedToPCCount,
                conflictCopyCount: conflictCopyCount,
                skippedOversizedCount: pushed?.skippedOversizedCount ?? oversizedCount,
                skippedOverflowCount: pushed?.skippedOverflowCount ?? 0,
                clockSkewSeconds: clockSkewSeconds
            )
        }
    }

    private struct TombstoneRow {
        let id: UUID
        let deletedAt: Int64
        let baseHash: String?
        let synced: Bool
    }

    private struct SyncTemplateRow {
        let entry: HistoryEntry
        let syncId: UUID?
        let updatedAt: Int64?
        let baseHash: String?
        let dirty: Bool
    }

    private func fetchActiveTemplateSyncRows() throws -> [SyncTemplateRow] {
        try templateSyncRows("SELECT \(syncColumns) FROM history WHERE pinned = 1 AND deletion_id IS NULL ORDER BY collected_at DESC, id DESC", [])
    }

    private func fetchUndoPendingTemplateSyncRows() throws -> [(id: Int, syncId: UUID?)] {
        let statement = try prepare("SELECT id, template_sync_id FROM history WHERE pinned = 1 AND deletion_id IS NOT NULL")
        defer { sqlite3_finalize(statement) }
        var result: [(id: Int, syncId: UUID?)] = []
        while try step(statement) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(statement, 0))
            let syncId = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : UUID(uuidString: string(statement, 1))
            result.append((id, syncId))
        }
        return result
    }

    private func activeID(forSyncID syncId: UUID) throws -> Int? {
        let statement = try prepare("SELECT id FROM history WHERE template_sync_id = ? AND deletion_id IS NULL LIMIT 1", [.text(syncId.uuidString)])
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func isTombstoneSynced(forSyncID syncId: UUID) throws -> Bool {
        let statement = try prepare("SELECT synced FROM template_tombstones WHERE sync_id = ? LIMIT 1", [.text(syncId.uuidString)])
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int(statement, 0) != 0
    }

    private func templateSyncRows(_ sql: String, _ values: [Value]) throws -> [SyncTemplateRow] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [SyncTemplateRow] = []
        while try step(statement) == SQLITE_ROW {
            let entry = try decodeEntry(statement)
            let syncId = sqlite3_column_type(statement, 23) == SQLITE_NULL ? nil : UUID(uuidString: string(statement, 23))
            let updatedAt: Int64? = sqlite3_column_type(statement, 24) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 24)
            let baseHash = sqlite3_column_type(statement, 25) == SQLITE_NULL ? nil : string(statement, 25)
            let dirty = sqlite3_column_int(statement, 26) != 0
            result.append(SyncTemplateRow(entry: entry, syncId: syncId, updatedAt: updatedAt, baseHash: baseHash, dirty: dirty))
        }
        return result
    }

    private func fetchTombstoneRows() throws -> [TombstoneRow] {
        let statement = try prepare("SELECT sync_id, deleted_at, base_hash, synced FROM template_tombstones ORDER BY deleted_at ASC, sync_id ASC")
        defer { sqlite3_finalize(statement) }
        var result: [TombstoneRow] = []
        while try step(statement) == SQLITE_ROW {
            guard let id = try? SyncProtocol.parseId(string(statement, 0)) else { continue }
            let deletedAt = Self.clampedTimestamp(sqlite3_column_int64(statement, 1))
            let rawHash = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : string(statement, 2)
            let validHash = rawHash.flatMap { SyncProtocol.isLowerHex64($0) ? $0 : nil }
            let synced = sqlite3_column_int(statement, 3) != 0
            result.append(TombstoneRow(id: id, deletedAt: deletedAt, baseHash: validHash, synced: synced))
        }
        return result
    }

    private func pruneTombstones(nowMillis: Int64) throws {
        try execute("DELETE FROM template_tombstones WHERE (? - deleted_at) > ?",
                    [.int64(nowMillis), .int64(SyncProtocol.templateTombstoneLifetimeMillis)])
        try execute("""
            DELETE FROM template_tombstones WHERE sync_id IN (
                SELECT sync_id FROM template_tombstones ORDER BY deleted_at DESC, sync_id DESC LIMIT -1 OFFSET ?
            )
            """, [.integer(SyncProtocol.maxTemplateTombstones)])
    }

    private func nowMillis() -> Int64 {
        Self.millis(from: now().timeIntervalSince1970)
    }

    private static func millis(from seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        let raw = seconds * 1000.0
        if raw >= Double(SyncProtocol.maxTimestamp) { return SyncProtocol.maxTimestamp }
        if raw <= Double(-SyncProtocol.maxTimestamp) { return -SyncProtocol.maxTimestamp }
        return Int64(raw.rounded())
    }

    private static func clampedTimestamp(_ value: Int64) -> Int64 {
        min(SyncProtocol.maxTimestamp, max(-SyncProtocol.maxTimestamp, value))
    }

    private static func utf8Key(_ value: String?) -> Data? {
        value.map { Data($0.utf8) }
    }

    private static func sanitizedTitleForSync(_ title: String?) -> String? {
        TemplateSyncMerge.normalizedTitle(stripControlAndNewlines(title))
    }

    private static func sanitizedTagForSync(_ tag: String?) -> String? {
        TemplateSyncMerge.normalizedTag(stripControlAndNewlines(tag))
    }

    private static func stripControlAndNewlines(_ value: String?) -> String? {
        guard let value else { return nil }
        var cleaned = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D || scalar.value == 0x2028 || scalar.value == 0x2029 {
                cleaned.append(" ")
            } else if !SyncProtocol.isControlCharacter(scalar) {
                cleaned.append(scalar)
            }
        }
        return String(cleaned)
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
        case text(String), integer(Int), int64(Int64), real(Double), null
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
                case .int64(let number): result = sqlite3_bind_int64(statement, index, number)
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
            result.append(try decodeEntry(statement))
        }
        return result
    }

    private func decodeEntry(_ statement: OpaquePointer) throws -> HistoryEntry {
        guard let kind = HistoryKind(rawValue: string(statement, 1)),
              let source = HistorySource(rawValue: string(statement, 7)) else { throw HistoryDatabaseError.invalidRow }
        return HistoryEntry(
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
        )
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
