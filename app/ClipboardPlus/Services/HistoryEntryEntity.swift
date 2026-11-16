import AppIntents
import Foundation
import UniformTypeIdentifiers

struct HistoryEntryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "クリップボードの履歴"
    static let defaultQuery = HistoryEntryQuery()

    let id: Int
    @Property(title: "文章") var text: String
    @Property(title: "種類") var kind: String
    @Property(title: "保存日時") var savedAt: Date
    /// Named isPinned from the time of pins. Saved shortcuts refer to the property by this name,
    /// so it keeps the name now that it tells templates apart.
    @Property(title: "テンプレート") var isPinned: Bool
    @Property(title: "画像") var picture: IntentFile?

    @Property(title: "ファイル") var file: IntentFile?

    let fileSizeDescription: String?
    let displayTitle: String

    var displaySubtitle: String {
        (fileSizeDescription.map { $0 + "・" } ?? "") + "\(kind)・\(savedAt.formatted(date: .abbreviated, time: .shortened))" + (isPinned ? "・テンプレート" : "")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayTitle)", subtitle: "\(displaySubtitle)")
    }

    init(entry: HistoryEntry, picture: IntentFile? = nil, file: IntentFile? = nil) {
        // Plain stored values first: assigning a @Property goes through self, which needs
        // every stored property to be set already.
        id = entry.id
        displayTitle = ShortcutContent.title(entry)
        fileSizeDescription = entry.file?.sizeDescription
        self.text = entry.text
        self.kind = ShortcutContent.kindTitle(entry.kind)
        self.savedAt = entry.savedAt
        self.isPinned = entry.isTemplate
        self.picture = picture
        self.file = file
    }

    @MainActor
    static func make(_ entries: [HistoryEntry], monitor: ClipboardMonitor) -> [HistoryEntryEntity] {
        entries.map { entry in
            // URL-backed files avoid loading all full-size images into memory at once.
            // Do not set removedOnCompletion: the original belongs to the history store.
            let picture = entry.image.map { image in
                IntentFile(fileURL: monitor.imageURL(image, thumbnail: false),
                           filename: "clipboardplus-\(entry.id).\(UTType(image.typeIdentifier)?.preferredFilenameExtension ?? "image")",
                           type: UTType(image.typeIdentifier))
            }
            let file = entry.file.map {
                IntentFile(fileURL: monitor.fileURL($0), filename: $0.originalFilename, type: UTType($0.typeIdentifier))
            }
            return HistoryEntryEntity(entry: entry, picture: picture, file: file)
        }
    }
}

struct HistoryEntryQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [Int]) async throws -> [HistoryEntryEntity] {
        let monitor = ClipboardMonitor.shared
        return try await monitor.performShortcut("HistoryEntryQuery.entities(for:)") {
            let entries = Dictionary(uniqueKeysWithValues: monitor.entries.map { ($0.id, $0) })
            // Missing/deleted IDs are omitted; never substitute a different history item.
            return HistoryEntryEntity.make(identifiers.compactMap { entries[$0] }, monitor: monitor)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [HistoryEntryEntity] {
        let monitor = ClipboardMonitor.shared
        return try await monitor.performShortcut("HistoryEntryQuery.suggestedEntities") {
            HistoryEntryEntity.make(ShortcutContent.entries(monitor.entries, limit: 20), monitor: monitor)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [HistoryEntryEntity] {
        try await entities(matching: string, monitor: .shared)
    }

    @MainActor
    func entities(matching string: String, monitor: ClipboardMonitor) async throws -> [HistoryEntryEntity] {
        return try await monitor.performShortcut("HistoryEntryQuery.entities(matching:)") {
            HistoryEntryEntity.make(ShortcutContent.matchingEntries(monitor.entries, search: string), monitor: monitor)
        }
    }
}

enum HistoryFilterOption: String, AppEnum {
    case all, texts, links, images, files
    case templates = "pinned"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "履歴の種類"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .all: "すべて", .templates: "テンプレート", .texts: "文章", .links: "リンク", .images: "画像", .files: "ファイル"
    ]

    var filter: ShortcutHistoryFilter {
        switch self {
        case .all: return .all
        case .templates: return .templates
        case .texts: return .texts
        case .links: return .links
        case .images: return .images
        case .files: return .files
        }
    }
}

struct TemplateEntryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "テンプレート"
    static let defaultQuery = TemplateEntryQuery()
    let id: Int
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    init(entry: HistoryEntry) {
        id = entry.id
        title = ShortcutContent.title(entry)
    }
}

struct TemplateEntryQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [Int]) async throws -> [TemplateEntryEntity] {
        let monitor = ClipboardMonitor.shared
        return try await monitor.performShortcut("TemplateEntryQuery.entities(for:)") {
            let byID = Dictionary(uniqueKeysWithValues: monitor.entries.filter(\.isTemplate).map { ($0.id, $0) })
            return identifiers.compactMap { byID[$0] }.map { TemplateEntryEntity(entry: $0) }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [TemplateEntryEntity] {
        try await entities(matching: "")
    }

    @MainActor
    func entities(matching string: String) async throws -> [TemplateEntryEntity] {
        try await entities(matching: string, monitor: .shared)
    }

    @MainActor
    func entities(matching string: String, monitor: ClipboardMonitor) async throws -> [TemplateEntryEntity] {
        try await monitor.performShortcut("TemplateEntryQuery.entities(matching:)") {
            ShortcutContent.matchingEntries(monitor.entries, filter: .templates, search: string).map {
                TemplateEntryEntity(entry: $0)
            }
        }
    }
}
