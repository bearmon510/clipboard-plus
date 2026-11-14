import Foundation

enum HistoryKind: String, Codable {
    case text, url, image

    static func classify(_ text: String) -> HistoryKind {
        guard !text.isEmpty,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.url != nil else { return .text }
        return .url
    }
}

enum HistorySource: String, Codable {
    case automatic, manual, drag
}

struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: Int
    let kind: HistoryKind
    let text: String
    let savedAt: Date
    let lastCollectedAt: Date
    let collectionCount: Int
    let isPinned: Bool
    let source: HistorySource
    let image: HistoryImage?

    init(id: Int, kind: HistoryKind, text: String, savedAt: Date, lastCollectedAt: Date,
         collectionCount: Int, isPinned: Bool, source: HistorySource, image: HistoryImage? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.savedAt = savedAt
        self.lastCollectedAt = lastCollectedAt
        self.collectionCount = collectionCount
        self.isPinned = isPinned
        self.source = source
        self.image = image
    }

    var characterCount: Int { text.count }
    var domain: String? { kind == .url ? URLComponents(string: text)?.host : nil }
}

struct HistoryExport: Codable {
    let formatVersion: Int
    let exportedAt: Date
    let entries: [HistoryEntry]

    static func data(entries: [HistoryEntry], exportedAt: Date) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return try encoder.encode(HistoryExport(formatVersion: 2, exportedAt: exportedAt, entries: entries))
    }
}

// Only metadata is Codable. Original bytes and thumbnails never enter JSON or the pending queue.
struct HistoryImage: Codable, Equatable {
    let hash: String
    let filename: String
    let thumbnailFilename: String
    let byteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let typeIdentifier: String

    var filenames: Set<String> { [filename, thumbnailFilename] }
}

struct HistoryImageUsage: Equatable {
    var count = 0
    var byteCount = 0
}

