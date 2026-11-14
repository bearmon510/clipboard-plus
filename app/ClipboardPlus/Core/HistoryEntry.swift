import Foundation

enum HistoryKind: String, Codable {
    case text, url

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
        return try encoder.encode(HistoryExport(formatVersion: 1, exportedAt: exportedAt, entries: entries))
    }
}

