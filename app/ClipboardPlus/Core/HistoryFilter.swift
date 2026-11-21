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
    var tagKey: Data? { TemplateGroups.tagKey(tag) }
    var title: String { tag ?? "その他" }

    static func == (lhs: TemplateGroup, rhs: TemplateGroup) -> Bool {
        TemplateGroups.tagsEqual(lhs.tag, rhs.tag) && lhs.entries == rhs.entries
    }
}

enum TemplateGroups {
    static func tagKey(_ tag: String?) -> Data? {
        tag.map { Data($0.utf8) }
    }

    static func tagsEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        tagKey(lhs) == tagKey(rhs)
    }

    static func make(_ entries: [HistoryEntry], search: String) -> [TemplateGroup] {
        let query = HistoryFilter.normalized(search)
        let matches = entries.filter { $0.isTemplate && HistoryFilter.matches($0, query: query, includesTag: true) }
        let grouped = Dictionary(grouping: matches, by: { tagKey($0.tag) })
        let keys: [String?] = tags(matches).map { Optional($0) } + [nil]
        return keys.compactMap { tag in
            guard let values = grouped[tagKey(tag)], !values.isEmpty else { return nil }
            return TemplateGroup(tag: tag, entries: HistoryEntry.orderedTemplates(values))
        }
    }

    static func tags(_ entries: [HistoryEntry]) -> [String] {
        var uniqueByUTF8: [Data: String] = [:]
        for tag in entries.filter(\.isTemplate).compactMap(\.tag) {
            let key = Data(tag.utf8)
            if uniqueByUTF8[key] == nil {
                uniqueByUTF8[key] = tag
            }
        }
        return uniqueByUTF8.values.sorted {
            let result = $0.localizedStandardCompare($1)
            return result == .orderedSame ? $0.utf8.lexicographicallyPrecedes($1.utf8) : result == .orderedAscending
        }
    }
}
