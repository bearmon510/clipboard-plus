import Foundation

enum HistoryFilter: Hashable, CaseIterable {
    case all, pinned, images

    var title: String {
        switch self {
        case .all: return "すべて"
        case .pinned: return "ピン留め"
        case .images: return "画像"
        }
    }

    static func entries(_ entries: [HistoryEntry], filter: HistoryFilter, search: String) -> [HistoryEntry] {
        entries.filter {
            (filter != .pinned || $0.isPinned) && (filter != .images || $0.kind == .image) &&
            (search.isEmpty || ($0.kind != .image && $0.text.range(of: search, options: .caseInsensitive) != nil))
        }
    }
}
