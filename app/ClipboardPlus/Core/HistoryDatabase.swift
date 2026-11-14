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
    static let schemaVersion = 1
    static let undoInterval: TimeInterval = 5
    private var connection: OpaquePointer?
    private let now: () -> Date
    private let columns = "id, kind, text, saved_at, collected_at, collection_count, pinned, source"

    init(url: URL, now: @escaping () -> Date = Date.init) throws {
        self.now = now
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
            let existing = try rows("SELECT \(columns) FROM history WHERE text = ? AND deletion_id IS NULL", [.text(text)]).first
            let id: Int
            if let existing {
                id = existing.id
                try execute("UPDATE history SET collected_at = ?, collection_count = collection_count + 1, source = ? WHERE id = ?",
                            [.real(timestamp.timeIntervalSince1970), .text(source.rawValue), .integer(id)])
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
    func togglePin(id: Int) throws -> HistoryEntry? {
        try transaction {
            try execute("UPDATE history SET pinned = 1 - pinned WHERE id = ? AND deletion_id IS NULL", [.integer(id)])
            try enforceLimit()
            return try rows("SELECT \(columns) FROM history WHERE id = ? AND deletion_id IS NULL", [.integer(id)]).first
        }
    }

    func delete(id: Int) throws -> HistoryDeletion? {
        try markDeleted(predicate: "id = ?", bindings: [.integer(id)])
    }

    func deleteAll(includePinned: Bool) throws -> HistoryDeletion? {
        try markDeleted(predicate: includePinned ? "1 = 1" : "pinned = 0", bindings: [])
    }

    @discardableResult
    func undo(_ deletion: HistoryDeletion) throws -> Bool {
        try transaction {
            try purgeExpired()
            let deleted = try rows("SELECT \(columns) FROM history WHERE deletion_id = ?", [.text(deletion.id)])
            guard !deleted.isEmpty else { return false }
            for old in deleted {
                let active = try rows("SELECT \(columns) FROM history WHERE text = ? AND deletion_id IS NULL", [.text(old.text)]).first
                if let active {
                    // A fresh collection during the undo window must survive restoration.
                    let latest = active.lastCollectedAt >= old.lastCollectedAt ? active : old
                    try execute("""
                        UPDATE history SET saved_at = ?, collected_at = ?, collection_count = ?, pinned = ?, source = ? WHERE id = ?
                        """, [.real(min(old.savedAt, active.savedAt).timeIntervalSince1970),
                              .real(latest.lastCollectedAt.timeIntervalSince1970), .integer(old.collectionCount + active.collectionCount),
                              .integer(old.isPinned || active.isPinned ? 1 : 0), .text(latest.source.rawValue), .integer(old.id)])
                    try execute("DELETE FROM history WHERE id = ?", [.integer(active.id)])
                }
                try execute("UPDATE history SET deletion_id = NULL, delete_after = NULL WHERE id = ?", [.integer(old.id)])
            }
            try enforceLimit()
            return true
        }
    }

    @discardableResult
    func purgeExpired() throws -> Bool {
        try execute("DELETE FROM history WHERE delete_after <= ?", [.real(now().timeIntervalSince1970)])
        return sqlite3_changes(connection) > 0
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
        try execute("""
            DELETE FROM history WHERE id IN (
                SELECT id FROM history WHERE deletion_id IS NULL AND pinned = 0
                ORDER BY collected_at DESC, id DESC LIMIT -1 OFFSET 1000
            )
            """)
    }

    private enum Value {
        case text(String), integer(Int), real(Double)
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
                collectionCount: Int(sqlite3_column_int64(statement, 5)), isPinned: sqlite3_column_int(statement, 6) != 0, source: source
            ))
        }
        return result
    }

    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
