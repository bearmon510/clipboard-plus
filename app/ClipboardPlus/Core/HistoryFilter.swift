import Foundation

enum HistoryFilter: Hashable, CaseIterable {
    case all, pinned, texts, links, images, files

    var title: String {
        switch self {
        case .all: return "すべて"
        case .pinned: return "ピン留め"
        case .texts: return "文章"
        case .links: return "リンク"
        case .images: return "画像"
        case .files: return "ファイル"
        }
    }

    var symbolName: String? {
        switch self {
        case .all: return nil
        case .pinned: return "pin"
        case .texts: return "text.alignleft"
        case .links: return "link"
        case .images: return "photo"
        case .files: return "doc"
        }
    }

    private func includes(_ entry: HistoryEntry) -> Bool {
        switch self {
        case .all: return true
        case .pinned: return entry.isPinned
        case .texts: return entry.kind == .text
        case .links: return entry.kind == .url
        case .images: return entry.kind == .image
        case .files: return entry.kind == .file
        }
    }

    /// A search term typed with a stray space before or after it still means the same term.
    static func normalized(_ search: String) -> String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func entries(_ entries: [HistoryEntry], filter: HistoryFilter, search: String) -> [HistoryEntry] {
        let query = normalized(search)
        let matches = entries.filter {
            filter.includes($0) &&
            (query.isEmpty || $0.displayTitle?.range(of: query, options: .caseInsensitive) != nil ||
             ($0.kind != .image && ($0.file?.originalFilename ?? $0.text).range(of: query, options: .caseInsensitive) != nil))
        }
        return filter == .pinned ? HistoryEntry.orderedPins(matches) : matches
    }
}
