import Foundation

enum ShortcutError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case noText, unreadableImage, missingContent, missingEntry, emptyHistory
    case storageUnavailable, copyFailed, recognitionFailed
    case imageSaveFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noText: return "画像から文字が見つかりませんでした。文字がはっきり写った画像を渡してください。"
        case .unreadableImage: return "画像を読み込めませんでした。スクリーンショットか画像を渡してください。"
        case .missingContent: return "追加する文章か画像を指定してください。"
        case .missingEntry: return "指定した履歴が見つかりません。削除された可能性があります。履歴を選び直してください。"
        case .emptyHistory: return "コピーできる履歴がありません。先に文章か画像を保存してください。"
        case .storageUnavailable: return "履歴を読み込み・保存できませんでした。端末のロックを解除し、空き容量を確認してもう一度実行してください。"
        case .copyFailed: return "クリップボードにコピーできませんでした。少し待ってもう一度実行してください。"
        case .recognitionFailed: return "画像の文字を読み取れませんでした。別の画像でもう一度実行してください。"
        case .imageSaveFailed(let message): return "\(message)"
        }
    }

    var errorDescription: String? { String(localized: localizedStringResource) }
}

/// Pure transformations, also used by the entity query and the intents.
enum ShortcutContent {
    static func lines(_ recognized: [RecognizedLine]) throws -> [String] {
        let lines = TextRecognizer.assemble(recognized)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw ShortcutError.noText }
        return lines
    }

    static func joinedText(_ values: [String]?) -> String? {
        // Preserve indentation and intentional line breaks in nonempty items.
        let text = (values ?? []).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    static func limit(_ value: Int) -> Int { min(50, max(1, value)) }

    static func entries(_ entries: [HistoryEntry], filter: HistoryFilter = .all,
                        search: String = "", limit: Int = 50) -> [HistoryEntry] {
        Array(matchingEntries(entries, filter: filter, search: search).prefix(Self.limit(limit)))
    }

    static func matchingEntries(_ entries: [HistoryEntry], filter: HistoryFilter = .all,
                                search: String) -> [HistoryEntry] {
        let query = HistoryFilter.normalized(search)
        let ordered = entries.sorted {
            if $0.lastCollectedAt != $1.lastCollectedAt { return $0.lastCollectedAt > $1.lastCollectedAt }
            return $0.id > $1.id
        }
        let matches = HistoryFilter.entries(ordered, filter: filter, search: search)
        guard !query.isEmpty else { return matches }
        let exact: (HistoryEntry) -> Bool = { $0.displayTitle?.compare(query, options: .caseInsensitive) == .orderedSame }
        return matches.filter(exact) + matches.filter { !exact($0) }
    }

    static func title(_ entry: HistoryEntry) -> String {
        if let title = entry.displayTitle { return title }
        if let file = entry.file { return file.displayName }
        if entry.kind == .image {
            if let image = entry.image { return "画像 \(image.pixelWidth)×\(image.pixelHeight)" }
            return "画像"
        }
        let firstLine = entry.text.components(separatedBy: .newlines).first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) ?? entry.text
        return String(firstLine.prefix(60)) + (firstLine.count > 60 ? "…" : "")
    }

    static func kindTitle(_ kind: HistoryKind) -> String {
        switch kind {
        case .text: return "文章"
        case .url: return "リンク"
        case .image: return "画像"
        case .file: return "ファイル"
        }
    }
}
