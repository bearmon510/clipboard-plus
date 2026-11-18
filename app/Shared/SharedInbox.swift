import Foundation

/// One text or URL item queued by an extension in the shared container inbox.
struct SharedInboxItem: Codable, Equatable, Identifiable {
    enum Origin: String, Codable, Equatable {
        case keyboard
        case shareExtension
    }

    static let currentVersion = 1

    let formatVersion: Int
    let id: UUID
    let text: String
    let createdAt: Date
    let origin: Origin

    init(id: UUID = UUID(), text: String, createdAt: Date = Date(), origin: Origin) {
        self.formatVersion = Self.currentVersion
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.origin = origin
    }
}

enum SharedInbox {
    static let maxFileBytes = 4_000_000

    struct PendingItem: Equatable {
        let fileURL: URL
        let item: SharedInboxItem
    }

    struct ScanResult: Equatable {
        let items: [PendingItem]
        let corruptFiles: [URL]
    }

    @discardableResult
    static func write(text: String, origin: SharedInboxItem.Origin, id: UUID = UUID(),
                      createdAt: Date = Date(), to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = SharedInboxItem(id: id, text: text, createdAt: createdAt, origin: origin)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(item)
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    static func scan(directory: URL, fileManager: FileManager = .default) -> ScanResult {
        // Avoid file timestamp resource keys so extensions do not need a file-timestamp privacy reason.
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ScanResult(items: [], corruptFiles: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var items: [PendingItem] = []
        var corruptFiles: [URL] = []
        for url in urls where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            if let fileSize = values.fileSize, fileSize > maxFileBytes {
                corruptFiles.append(url)
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let item = try? decoder.decode(SharedInboxItem.self, from: data),
                  item.formatVersion == SharedInboxItem.currentVersion else {
                corruptFiles.append(url)
                continue
            }
            items.append(PendingItem(fileURL: url, item: item))
        }
        items.sort {
            if $0.item.createdAt != $1.item.createdAt {
                return $0.item.createdAt < $1.item.createdAt
            }
            return $0.item.id.uuidString < $1.item.id.uuidString
        }
        return ScanResult(items: items, corruptFiles: corruptFiles)
    }
}
