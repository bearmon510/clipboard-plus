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
    let isTemplate: Bool
    let source: HistorySource
    let image: HistoryImage?
    let file: HistoryFile?
    let title: String?
    let templateOrder: Int?
    let tag: String?

    init(id: Int, kind: HistoryKind, text: String, savedAt: Date, lastCollectedAt: Date,
         collectionCount: Int, isTemplate: Bool, source: HistorySource, image: HistoryImage? = nil, file: HistoryFile? = nil,
         title: String? = nil, templateOrder: Int? = nil, tag: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.savedAt = savedAt
        self.lastCollectedAt = lastCollectedAt
        self.collectionCount = collectionCount
        self.isTemplate = isTemplate
        self.source = source
        self.image = image
        self.file = file
        self.title = title
        self.templateOrder = templateOrder
        self.tag = Self.normalizedTag(tag)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, savedAt, lastCollectedAt, collectionCount, isTemplate, source, image, file, title, templateOrder, tag
    }
    private enum LegacyKeys: String, CodingKey { case isPinned, pinOrder }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        self.init(id: try values.decode(Int.self, forKey: .id),
                  kind: try values.decode(HistoryKind.self, forKey: .kind),
                  text: try values.decode(String.self, forKey: .text),
                  savedAt: try values.decode(Date.self, forKey: .savedAt),
                  lastCollectedAt: try values.decode(Date.self, forKey: .lastCollectedAt),
                  collectionCount: try values.decode(Int.self, forKey: .collectionCount),
                  isTemplate: try values.decodeIfPresent(Bool.self, forKey: .isTemplate)
                    ?? legacy.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false,
                  source: try values.decode(HistorySource.self, forKey: .source),
                  image: try values.decodeIfPresent(HistoryImage.self, forKey: .image),
                  file: try values.decodeIfPresent(HistoryFile.self, forKey: .file),
                  title: try values.decodeIfPresent(String.self, forKey: .title),
                  templateOrder: try values.decodeIfPresent(Int.self, forKey: .templateOrder)
                    ?? legacy.decodeIfPresent(Int.self, forKey: .pinOrder),
                  tag: try values.decodeIfPresent(String.self, forKey: .tag))
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
        case .duplicate: return "同じ内容のテンプレートがすでにあります"
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

    static func normalizedTag(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(trimmed.prefix(30)).trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? nil : capped
    }

    /// A stable ID tie-breaker orders legacy templates without an explicit order.
    static func orderedTemplates(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        entries.sorted { lhs, rhs in
            switch (lhs.templateOrder, rhs.templateOrder) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.id < rhs.id
            }
        }
    }
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
        let version = 5
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

