import Foundation

enum HistoryFilter {
    static func normalized(_ search: String) -> String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func history(_ entries: [HistoryEntry], search: String) -> [HistoryEntry] {
        let query = normalized(search)
        return entries.filter { !$0.isTemplate && matches($0, query: query) }
    }

    static func matches(_ entry: HistoryEntry, query: String, includesTag: Bool = false) -> Bool {
        query.isEmpty || entry.displayTitle?.range(of: query, options: .caseInsensitive) != nil ||
            (includesTag && entry.tag?.range(of: query, options: .caseInsensitive) != nil) ||
            (entry.kind != .image && (entry.file?.originalFilename ?? entry.text).range(of: query, options: .caseInsensitive) != nil)
    }
}

struct TemplateGroup: Identifiable, Equatable {
    let tag: String?
    let entries: [HistoryEntry]
    var id: String { tag ?? "" }
    var title: String { tag ?? "その他" }
}

enum TemplateGroups {
    static func make(_ entries: [HistoryEntry], search: String) -> [TemplateGroup] {
        let query = HistoryFilter.normalized(search)
        let matches = entries.filter { $0.isTemplate && HistoryFilter.matches($0, query: query, includesTag: true) }
        let grouped = Dictionary(grouping: matches, by: { $0.tag })
        let keys: [String?] = tags(matches).map { Optional($0) } + [nil]
        return keys.compactMap { tag in
            guard let values = grouped[tag], !values.isEmpty else { return nil }
            return TemplateGroup(tag: tag, entries: HistoryEntry.orderedTemplates(values))
        }
    }

    static func tags(_ entries: [HistoryEntry]) -> [String] {
        Set(entries.filter(\.isTemplate).compactMap(\.tag)).sorted {
            let result = $0.localizedStandardCompare($1)
            return result == .orderedSame ? $0 < $1 : result == .orderedAscending
        }
    }
}
