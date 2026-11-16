import Foundation

/// How an entry is shown. Derived from the stored text at display time; nothing is persisted.
enum EntryFlavor: Equatable {
    case text
    case link
    case email
    case phone
    case color(red: Double, green: Double, blue: Double)
    case image
    case file

    static func detect(_ entry: HistoryEntry) -> EntryFlavor {
        switch entry.kind {
        case .file: return .file
        case .image: return .image
        case .url: return .link
        case .text: return detect(text: entry.text)
        }
    }

    static func detect(text: String) -> EntryFlavor {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 64 else { return .text }
        if let color = hexColor(value) { return color }
        if value.range(of: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil {
            return .email
        }
        if isPhoneNumber(value) { return .phone }
        return .text
    }

    var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .email: return "envelope"
        case .phone: return "phone"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    private static func hexColor(_ value: String) -> EntryFlavor? {
        guard value.hasPrefix("#") else { return nil }
        var digits = String(value.dropFirst())
        guard digits.range(of: "^[0-9A-Fa-f]+$", options: .regularExpression) != nil else { return nil }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8,
              let number = UInt64(String(digits.prefix(6)), radix: 16) else { return nil }
        return .color(red: Double((number >> 16) & 0xFF) / 255,
                      green: Double((number >> 8) & 0xFF) / 255,
                      blue: Double(number & 0xFF) / 255)
    }

    private static func isPhoneNumber(_ value: String) -> Bool {
        // A leading + or 0 keeps dates and plain numbers from looking like phone numbers.
        guard value.range(of: #"^[+0][0-9 ()-]{8,18}$"#, options: .regularExpression) != nil else { return false }
        let digits = value.filter { $0.isNumber }.count
        return (10...15).contains(digits)
    }
}

struct EntryLink: Equatable {
    let host: String
    /// Path, query and fragment. Nil when the link is just the site.
    let remainder: String?
}

enum EntryLinks {
    static func parts(_ text: String) -> EntryLink? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, !host.isEmpty else { return nil }
        var remainder = components.path
        if let query = components.query, !query.isEmpty { remainder += "?" + query }
        if let fragment = components.fragment, !fragment.isEmpty { remainder += "#" + fragment }
        return EntryLink(host: host, remainder: remainder.isEmpty || remainder == "/" ? nil : remainder)
    }
}

enum EntryTime {
    /// Short label for a list row. `includesDay` is false inside a "today" or "yesterday" section.
    static func label(for date: Date, now: Date, includesDay: Bool, calendar: Calendar = .current) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 10 { return "たった今" }
        if elapsed < 60 { return "\(Int(elapsed))秒前" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60))分前" }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = parts.minute ?? 0
        let time = "\(parts.hour ?? 0):" + (minute < 10 ? "0\(minute)" : "\(minute)")
        guard includesDay else { return time }
        let day = "\(parts.month ?? 0)/\(parts.day ?? 0)"
        if parts.year != calendar.component(.year, from: now) { return "\(parts.year ?? 0)/\(day)" }
        return "\(day) \(time)"
    }
}

enum EntrySectionKind: Hashable {
    case pinned, today, yesterday, thisWeek, earlier

    var title: String {
        switch self {
        case .pinned: return "ピン留め"
        case .today: return "今日"
        case .yesterday: return "昨日"
        case .thisWeek: return "過去7日間"
        case .earlier: return "それ以前"
        }
    }
}

struct EntrySection: Identifiable, Equatable {
    let kind: EntrySectionKind
    let entries: [HistoryEntry]
    var id: EntrySectionKind { kind }
}

enum EntrySections {
    /// Groups entries, which arrive newest first, by day. Order inside a section is kept.
    static func make(_ entries: [HistoryEntry], separatesPinned: Bool, now: Date,
                     calendar: Calendar = .current) -> [EntrySection] {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)
            ?? startOfToday.addingTimeInterval(-86_400)
        let startOfWeek = calendar.date(byAdding: .day, value: -6, to: startOfToday)
            ?? startOfToday.addingTimeInterval(-6 * 86_400)
        var buckets: [EntrySectionKind: [HistoryEntry]] = [:]
        for entry in entries {
            let kind: EntrySectionKind
            if separatesPinned && entry.isPinned {
                kind = .pinned
            } else if entry.lastCollectedAt >= startOfToday {
                kind = .today
            } else if entry.lastCollectedAt >= startOfYesterday {
                kind = .yesterday
            } else if entry.lastCollectedAt >= startOfWeek {
                kind = .thisWeek
            } else {
                kind = .earlier
            }
            buckets[kind, default: []].append(entry)
        }
        let order: [EntrySectionKind] = [.pinned, .today, .yesterday, .thisWeek, .earlier]
        return order.compactMap { kind in
            buckets[kind].map { EntrySection(kind: kind, entries: $0) }
        }
    }
}

enum EntryColumns {
    /// How many columns of cards fit. A card needs about 300 points to read comfortably.
    static func count(forWidth width: Double, minimumCardWidth: Double = 300, spacing: Double = 10,
                      horizontalPadding: Double = 24) -> Int {
        max(1, Int((width - horizontalPadding + spacing) / (minimumCardWidth + spacing)))
    }

    /// Deals entries across the columns in turn, so reading order runs left to right.
    /// Always returns `count` columns, which keeps column widths equal in a short section.
    static func split(_ entries: [HistoryEntry], into count: Int) -> [[HistoryEntry]] {
        let count = max(1, count)
        var columns = [[HistoryEntry]](repeating: [], count: count)
        for (offset, entry) in entries.enumerated() {
            columns[offset % count].append(entry)
        }
        return columns
    }
}

struct EntrySnippet: Equatable {
    let text: String
    /// Ranges of the search term inside `text`.
    let matches: [Range<String.Index>]
}

enum EntryPreview {
    static let limit = 280

    /// The part of a text shown in a row. While searching, it starts shortly before the
    /// first match so that the match is visible even deep inside a long text.
    static func snippet(_ text: String, query: String, limit: Int = EntryPreview.limit, lead: Int = 24) -> EntrySnippet {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let first = trimmed.range(of: needle, options: .caseInsensitive) else {
            return EntrySnippet(text: String(trimmed.prefix(limit)), matches: [])
        }
        let start = trimmed.index(first.lowerBound, offsetBy: -lead, limitedBy: trimmed.startIndex) ?? trimmed.startIndex
        let body = String(trimmed[start...].prefix(limit))
        let snippet = (start == trimmed.startIndex ? "" : "…") + body
        var matches: [Range<String.Index>] = []
        var cursor = snippet.startIndex
        while cursor < snippet.endIndex,
              let range = snippet.range(of: needle, options: .caseInsensitive, range: cursor..<snippet.endIndex),
              !range.isEmpty {
            matches.append(range)
            cursor = range.upperBound
        }
        return EntrySnippet(text: snippet, matches: matches)
    }
}
