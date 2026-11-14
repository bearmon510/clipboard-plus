import Foundation

enum HistoryFilter: Hashable, CaseIterable {
    case all, pinned, texts, links, images

    var title: String {
        switch self {
        case .all: return "すべて"
        case .pinned: return "ピン留め"
        case .texts: return "文章"
        case .links: return "リンク"
        case .images: return "画像"
        }
    }

    var symbolName: String? {
        switch self {
        case .all: return nil
        case .pinned: return "pin"
        case .texts: return "text.alignleft"
        case .links: return "link"
        case .images: return "photo"
        }
    }

    private func includes(_ entry: HistoryEntry) -> Bool {
        switch self {
        case .all: return true
        case .pinned: return entry.isPinned
        case .texts: return entry.kind == .text
        case .links: return entry.kind == .url
        case .images: return entry.kind == .image
        }
    }

    static func entries(_ entries: [HistoryEntry], filter: HistoryFilter, search: String) -> [HistoryEntry] {
        entries.filter {
            filter.includes($0) &&
            (search.isEmpty || ($0.kind != .image && $0.text.range(of: search, options: .caseInsensitive) != nil))
        }
    }
}
