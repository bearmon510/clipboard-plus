import AppIntents
import UIKit

enum ShortcutImageReader {
    static func lines(in file: IntentFile) async throws -> [String] {
        let lines = try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                guard let image = UIImage(data: file.data),
                      let pixels = CaptureSource(image: image).image.cgImage else {
                    throw ShortcutError.unreadableImage
                }
                do { return try ShortcutContent.lines(TextRecognizer.lines(in: pixels)) }
                catch let error as ShortcutError { throw error }
                catch { throw ShortcutError.recognitionFailed }
            }
        }.value
        try Task.checkCancellation()
        return lines
    }

    static func png(in file: IntentFile) async throws -> Data {
        let data = try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                guard let image = UIImage(data: file.data),
                      let png = CaptureSource(image: image).image.pngData() else {
                    throw ShortcutError.unreadableImage
                }
                return png
            }
        }.value
        try Task.checkCancellation()
        return data
    }
}

struct ReadTextIntent: AppIntent {
    static let title: LocalizedStringResource = "画像の文字を読み取る"
    static let description: IntentDescription? = IntentDescription("画像の文字をまとめて返します。コピーして履歴に保存することもできます。")
    static let openAppWhenRun = false

    @Parameter(title: "画像", supportedTypeIdentifiers: ["public.image"])
    var picture: IntentFile
    @Parameter(title: "コピーして履歴に保存", default: false)
    var copyAndSave: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$picture)の文字を読み取る") { \.$copyAndSave }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let monitor = ClipboardMonitor.shared
        let text = try await monitor.performShortcut("ReadTextIntent", needsHistory: copyAndSave) {
            let text = try await ShortcutImageReader.lines(in: picture).joined(separator: "\n")
            if copyAndSave { try await monitor.saveFromShortcut(text: text, pngData: nil, copyToClipboard: true) }
            return text
        }
        return .result(value: text)
    }
}

struct ReadTextLinesIntent: AppIntent {
    static let title: LocalizedStringResource = "画像の文字を行ごとに取り出す"
    static let description: IntentDescription? = IntentDescription("画像の文字を行のリストで返します。「リストから選択」に渡せます。")
    static let openAppWhenRun = false

    @Parameter(title: "画像", supportedTypeIdentifiers: ["public.image"])
    var picture: IntentFile
    @Parameter(title: "コピーして履歴に保存", default: false)
    var copyAndSave: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$picture)の文字を行ごとに取り出す") { \.$copyAndSave }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let monitor = ClipboardMonitor.shared
        let lines = try await monitor.performShortcut("ReadTextLinesIntent", needsHistory: copyAndSave) {
            let lines = try await ShortcutImageReader.lines(in: picture)
            if copyAndSave {
                try await monitor.saveFromShortcut(text: lines.joined(separator: "\n"), pngData: nil, copyToClipboard: true)
            }
            return lines
        }
        return .result(value: lines)
    }
}

struct AddToHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "clipboard+に追加"
    static let description: IntentDescription? = IntentDescription("複数の文章は改行でつなぎ1件として保存します。文章と画像を両方指定すると各1件を保存し、コピーする場合は画像をコピーします。")
    static let openAppWhenRun = false

    @Parameter(title: "文章") var texts: [String]?
    @Parameter(title: "画像", supportedTypeIdentifiers: ["public.image"])
    var picture: IntentFile?
    @Parameter(title: "クリップボードにもコピー", default: true)
    var copyToClipboard: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("clipboard+に\(\.$texts)を追加") {
            \.$picture
            \.$copyToClipboard
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let monitor = ClipboardMonitor.shared
        try await monitor.performShortcut("AddToHistoryIntent") {
            let text = ShortcutContent.joinedText(texts)
            guard text != nil || picture != nil else { throw ShortcutError.missingContent }
            var png: Data?
            if let picture { png = try await ShortcutImageReader.png(in: picture) }
            try await monitor.saveFromShortcut(text: text, pngData: png, copyToClipboard: copyToClipboard)
        }
        return .result()
    }
}

struct GetHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "履歴を取り出す"
    static let description: IntentDescription? = IntentDescription("新しい順に履歴を取り出します。文章や画像のプロパティを次の操作へ渡せます。")
    static let openAppWhenRun = false

    @Parameter(title: "件数", default: 1, inclusiveRange: (1, 50)) var count: Int
    @Parameter(title: "種類", default: .all) var kind: HistoryFilterOption

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$kind)の履歴を\(\.$count)件取り出す")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[HistoryEntryEntity]> {
        let monitor = ClipboardMonitor.shared
        let entities = try await monitor.performShortcut("GetHistoryIntent") {
            HistoryEntryEntity.make(ShortcutContent.entries(monitor.entries, filter: kind.filter, limit: count), monitor: monitor)
        }
        return .result(value: entities)
    }
}

struct SearchHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "履歴を検索"
    static let description: IntentDescription? = IntentDescription("文章とリンクを、大文字と小文字を区別せず部分一致で検索します。空の語句ではすべての種類を返します。")
    static let openAppWhenRun = false

    @Parameter(title: "語句") var query: String
    @Parameter(title: "件数", default: 1, inclusiveRange: (1, 50)) var count: Int

    static var parameterSummary: some ParameterSummary {
        Summary("履歴から\(\.$query)を検索して\(\.$count)件取り出す")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[HistoryEntryEntity]> {
        let monitor = ClipboardMonitor.shared
        let entities = try await monitor.performShortcut("SearchHistoryIntent") {
            HistoryEntryEntity.make(ShortcutContent.entries(monitor.entries, search: query, limit: count), monitor: monitor)
        }
        return .result(value: entities)
    }
}

struct CopyHistoryEntryIntent: AppIntent {
    static let title: LocalizedStringResource = "履歴をコピー"
    static let description: IntentDescription? = IntentDescription("選んだ履歴の文章か画像をクリップボードにコピーします。")
    static let openAppWhenRun = false

    @Parameter(title: "履歴") var entry: HistoryEntryEntity

    static var parameterSummary: some ParameterSummary { Summary("\(\.$entry)をコピー") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let monitor = ClipboardMonitor.shared
        try await monitor.performShortcut("CopyHistoryEntryIntent") {
            guard let current = monitor.entries.first(where: { $0.id == entry.id }) else { throw ShortcutError.missingEntry }
            try await monitor.copyForShortcut(current)
        }
        return .result()
    }
}

struct CopyTemplateIntent: AppIntent {
    static let title: LocalizedStringResource = "テンプレートをコピー"
    static let description: IntentDescription? = IntentDescription("名前で選んだテンプレートをクリップボードにコピーします。")
    static let openAppWhenRun = false

    @Parameter(title: "テンプレート") var entry: TemplateEntryEntity

    static var parameterSummary: some ParameterSummary { Summary("\(\.$entry)をコピー") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let monitor = ClipboardMonitor.shared
        try await monitor.performShortcut("CopyTemplateIntent") {
            guard let current = monitor.entries.first(where: { $0.id == entry.id && $0.isTemplate }) else {
                throw ShortcutError.missingEntry
            }
            try await monitor.copyForShortcut(current)
        }
        return .result()
    }
}

/// A parameterless action for the built-in shortcut; no history picker is needed.
struct CopyLatestHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "最新の履歴をコピー"
    static let description: IntentDescription? = IntentDescription("いちばん新しい履歴の文章か画像をコピーします。")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let monitor = ClipboardMonitor.shared
        try await monitor.performShortcut("CopyLatestHistoryIntent") {
            guard let entry = ShortcutContent.entries(monitor.entries, filter: .all, limit: 1).first else { throw ShortcutError.emptyHistory }
            try await monitor.copyForShortcut(entry)
        }
        return .result()
    }
}

struct ClipboardPlusShortcuts: AppShortcutsProvider {
    // Taking the screen directly (StartCaptureIntent) is hidden behind the developer settings
    // since 0.11.0, so it is not offered here. Cutting out starts from the user's own shortcut:
    // "スクリーンショットを撮る" followed by CaptureRegionIntent.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CopyTemplateIntent(),
                    phrases: ["\(.applicationName)でテンプレートをコピー"],
                    shortTitle: "テンプレートをコピー", systemImageName: "square.stack")
        AppShortcut(intent: CopyLatestHistoryIntent(),
                    phrases: ["\(.applicationName)で最新の履歴をコピー"],
                    shortTitle: "最新の履歴をコピー", systemImageName: "doc.on.clipboard")
        // Free-form String parameters cannot be phrase placeholders. Siri/Shortcuts asks
        // for this required query after the phrase starts the intent (WWDC24, 10210).
        AppShortcut(intent: SearchHistoryIntent(),
                    phrases: ["\(.applicationName)で履歴を検索"],
                    shortTitle: "履歴を検索", systemImageName: "magnifyingglass")
    }
}
