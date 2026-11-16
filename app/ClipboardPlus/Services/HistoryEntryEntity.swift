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
    @Property(title: "ピン留め") var isPinned: Bool
    @Property(title: "画像") var picture: IntentFile?

    @Property(title: "ファイル") var file: IntentFile?

    let fileSizeDescription: String?
    let displayTitle: String

    var displaySubtitle: String {
        (fileSizeDescription.map { $0 + "・" } ?? "") + "\(kind)・\(savedAt.formatted(date: .abbreviated, time: .shortened))" + (isPinned ? "・ピン留め" : "")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayTitle)", subtitle: "\(displaySubtitle)")
    }

    init(entry: HistoryEntry, picture: IntentFile? = nil, file: IntentFile? = nil) {
        id = entry.id
        displayTitle = ShortcutContent.title(entry)
        self.text = entry.text
        self.kind = ShortcutContent.kindTitle(entry.kind)
        self.savedAt = entry.savedAt
        self.isPinned = entry.isPinned
        self.picture = picture
        self.file = file
        fileSizeDescription = entry.file?.sizeDescription
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
        let monitor = ClipboardMonitor.shared
        return try await monitor.performShortcut("HistoryEntryQuery.entities(matching:)") {
            HistoryEntryEntity.make(ShortcutContent.matchingEntries(monitor.entries, search: string), monitor: monitor)
        }
    }
}

enum HistoryFilterOption: String, AppEnum {
    case all, pinned, texts, links, images, files

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "履歴の種類"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .all: "すべて", .pinned: "ピン留め", .texts: "文章", .links: "リンク", .images: "画像", .files: "ファイル"
    ]

    var filter: HistoryFilter {
        switch self {
        case .all: return .all
        case .pinned: return .pinned
        case .texts: return .texts
        case .links: return .links
        case .images: return .images
        case .files: return .files
        }
    }
}
