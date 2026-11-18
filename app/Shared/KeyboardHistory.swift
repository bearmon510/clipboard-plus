import Foundation

/// Snapshot of text/URL history and templates exported for the keyboard extension.
/// Compiled into both the app and extensions with no dependency on SQLite or UIKit.
struct KeyboardHistory: Codable, Equatable {
    static let currentVersion = 1

    let formatVersion: Int
    let exportedAt: Date
    let entries: [KeyboardHistoryEntry]
}

struct KeyboardHistoryEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, Equatable {
        case text, url
    }

    let id: Int
    let kind: Kind
    let text: String
    let lastCollectedAt: Date
    let isTemplate: Bool
    let title: String?
    let tag: String?
    let templateOrder: Int?

    init(id: Int, kind: Kind, text: String, lastCollectedAt: Date, isTemplate: Bool,
         title: String? = nil, tag: String? = nil, templateOrder: Int? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.lastCollectedAt = lastCollectedAt
        self.isTemplate = isTemplate
        self.title = title
        self.tag = tag
        self.templateOrder = templateOrder
    }
}

enum KeyboardHistoryFile {
    static let filename = SharedAppGroup.keyboardHistoryFilename

    static func defaultURL() -> URL? {
        SharedAppGroup.keyboardHistoryURL()
    }

    // Call only from the containing app's serial history queue.
    static func write(_ history: KeyboardHistory, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(history)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Apply file protection to the atomic replacement itself rather than afterwards.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read(from url: URL?) -> KeyboardHistory? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let history = try? decoder.decode(KeyboardHistory.self, from: data),
              history.formatVersion == KeyboardHistory.currentVersion,
              Set(history.entries.map(\.id)).count == history.entries.count else { return nil }
        return history
    }

    static func readEntries(from url: URL?) -> [KeyboardHistoryEntry] {
        read(from: url)?.entries ?? []
    }
}
