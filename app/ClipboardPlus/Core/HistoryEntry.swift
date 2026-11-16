import Foundation

enum HistoryKind: String, Codable {
    case text, url, image, file

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
    case automatic, manual, drag, written
    /// Made inside the app from a picture: a cut-out part, or text read from it.
    case capture
}

enum HistoryCollectionCount {
    static let maximum = 1_000_000_000

    static func clamped(_ value: Int) -> Int { min(maximum, max(1, value)) }

    static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        // Clamp operands before adding, including values written by older versions.
        min(maximum, clamped(lhs) + clamped(rhs))
    }
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
    let file: HistoryFile?
    let title: String?
    let pinOrder: Int?

    init(id: Int, kind: HistoryKind, text: String, savedAt: Date, lastCollectedAt: Date,
         collectionCount: Int, isPinned: Bool, source: HistorySource, image: HistoryImage? = nil, file: HistoryFile? = nil,
         title: String? = nil, pinOrder: Int? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.savedAt = savedAt
        self.lastCollectedAt = lastCollectedAt
        self.collectionCount = collectionCount
        self.isPinned = isPinned
        self.source = source
        self.image = image
        self.file = file
        self.title = title
        self.pinOrder = pinOrder
    }

    var attachmentFilenames: Set<String> { (image?.filenames ?? []).union(file?.filenames ?? []) }
    var attachmentByteCount: Int { image?.byteCount ?? file?.byteCount ?? 0 }

    var characterCount: Int { text.count }
    var domain: String? { kind == .url ? URLComponents(string: text)?.host : nil }
}

enum HistoryEditError: Error, Equatable {
    case empty, duplicate, unsupportedKind, failed

    var message: String {
        switch self {
        case .empty: return "本文を入力してください"
        case .duplicate: return "同じ内容の項目がすでにあります"
        case .unsupportedKind: return "文章とリンクだけを書き直せます"
        case .failed: return "履歴の変更を保存できませんでした"
        }
    }
}

extension HistoryEntry {
    var displayTitle: String? {
        guard let value = title?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Preserve input order for equal or absent pin orders, including legacy JSON.
    static func orderedPins(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        entries.enumerated().sorted { lhs, rhs in
            switch (lhs.element.pinOrder, rhs.element.pinOrder) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    var needsTemplateBackupFormat: Bool { title != nil || pinOrder != nil || source == .written }
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
        let version = entries.contains { $0.needsTemplateBackupFormat } ? 4 : (entries.contains { $0.kind == .file } ? 3 : 2)
        return try encoder.encode(HistoryExport(formatVersion: version, exportedAt: exportedAt, entries: entries))
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

