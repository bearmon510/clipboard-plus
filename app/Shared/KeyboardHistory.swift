import Foundation

/// Snapshot of text/URL history and templates exported for the keyboard extension.
/// Compiled into both the app and extensions with no dependency on SQLite or UIKit.
struct KeyboardHistory: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let formatVersion: Int
    let exportedAt: Date
    let entries: [KeyboardHistoryEntry]
}

struct KeyboardHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
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
    let isFromPC: Bool

    init(id: Int, kind: Kind, text: String, lastCollectedAt: Date, isTemplate: Bool,
         title: String? = nil, tag: String? = nil, templateOrder: Int? = nil, isFromPC: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.lastCollectedAt = lastCollectedAt
        self.isTemplate = isTemplate
        self.title = title
        self.tag = tag
        self.templateOrder = templateOrder
        self.isFromPC = isFromPC
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, lastCollectedAt, isTemplate, title, tag, templateOrder, isFromPC
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(Int.self, forKey: .id),
            kind: try values.decode(Kind.self, forKey: .kind),
            text: try values.decode(String.self, forKey: .text),
            lastCollectedAt: try values.decode(Date.self, forKey: .lastCollectedAt),
            isTemplate: try values.decode(Bool.self, forKey: .isTemplate),
            title: try values.decodeIfPresent(String.self, forKey: .title),
            tag: try values.decodeIfPresent(String.self, forKey: .tag),
            templateOrder: try values.decodeIfPresent(Int.self, forKey: .templateOrder),
            isFromPC: try values.decodeIfPresent(Bool.self, forKey: .isFromPC) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encode(lastCollectedAt, forKey: .lastCollectedAt)
        try container.encode(isTemplate, forKey: .isTemplate)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(tag, forKey: .tag)
        try container.encodeIfPresent(templateOrder, forKey: .templateOrder)
        if isFromPC {
            try container.encode(isFromPC, forKey: .isFromPC)
        }
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
