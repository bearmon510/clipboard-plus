import Foundation

enum KeyboardHistoryBuilder {
    static let historyLimit = 300
    static let templateLimit = 300
    static let textByteLimit = 2_000_000

    // fetchAll() already excludes undo-pending rows; pendingDeletionIDs lets callers
    // filter an in-memory snapshot without database access.
    static func build(
        entries: [HistoryEntry],
        pendingDeletionIDs: Set<Int> = [],
        exportedAt: Date,
        historyLimit: Int = KeyboardHistoryBuilder.historyLimit,
        templateLimit: Int = KeyboardHistoryBuilder.templateLimit,
        textByteLimit: Int = KeyboardHistoryBuilder.textByteLimit
    ) -> KeyboardHistory {
        let eligible = entries.filter {
            ($0.kind == .text || $0.kind == .url)
                && !pendingDeletionIDs.contains($0.id)
                && byteCount(of: $0) <= textByteLimit
        }

        let orderedTemplates = TemplateGroups.make(eligible, search: "").flatMap(\.entries)
        var selectedTemplates = Array(orderedTemplates.prefix(max(0, templateLimit)))

        let orderedHistory = eligible
            .filter { !$0.isTemplate }
            .sorted {
                $0.lastCollectedAt == $1.lastCollectedAt
                    ? $0.id > $1.id
                    : $0.lastCollectedAt > $1.lastCollectedAt
            }
        var selectedHistory = Array(orderedHistory.prefix(max(0, historyLimit)))

        var totalBytes = (selectedTemplates + selectedHistory).reduce(0) { $0 + byteCount(of: $1) }
        // Drop the oldest history suffix first so the newest entries remain contiguous.
        while totalBytes > textByteLimit, let oldest = selectedHistory.popLast() {
            totalBytes -= byteCount(of: oldest)
        }
        while totalBytes > textByteLimit, let trailingTemplate = selectedTemplates.popLast() {
            totalBytes -= byteCount(of: trailingTemplate)
        }

        let exportedEntries = (selectedHistory + selectedTemplates).map {
            KeyboardHistoryEntry(
                id: $0.id,
                kind: $0.kind == .url ? .url : .text,
                text: $0.text,
                lastCollectedAt: $0.lastCollectedAt,
                isTemplate: $0.isTemplate,
                title: $0.displayTitle,
                tag: $0.tag,
                templateOrder: $0.templateOrder,
                isFromPC: $0.source == .pc
            )
        }
        return KeyboardHistory(
            formatVersion: KeyboardHistory.currentVersion,
            exportedAt: exportedAt,
            entries: exportedEntries
        )
    }

    private static func byteCount(of entry: HistoryEntry) -> Int {
        entry.text.utf8.count
            + (entry.displayTitle?.utf8.count ?? 0)
            + (entry.tag?.utf8.count ?? 0)
    }
}
