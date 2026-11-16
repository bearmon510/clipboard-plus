import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension UTType {
    static let clipboardPlusBackup = UTType(exportedAs: "example.clipboardplus.backup", conformingTo: .data)
}

enum BackupError: Error, LocalizedError {
    case cancelled, identifier, version, manifest, truncated, image, file, trailingData, unavailable

    var errorDescription: String? {
        switch self {
        case .cancelled: return "取り消しました。"
        case .identifier: return "clipboard+のバックアップではありません。"
        case .version: return "このバックアップの版には対応していません。"
        case .manifest: return "履歴の情報が壊れているか、対応していない内容です。"
        case .truncated: return "ファイルが途中で切れているか、画像のバイト数が一致しません。"
        case .image: return "画像の形式・大きさ・寸法・ハッシュが正しくありません。"
        case .file: return "ファイルの形式・大きさ・ハッシュが正しくありません。"
        case .trailingData: return "ファイルの末尾に予期しないデータがあります。"
        case .unavailable: return "バックアップの保存先または履歴を利用できません。"
        }
    }

    // Never expose NSError paths, JSON values or provider filenames in the log/UI.
    static func message(_ error: Error) -> String {
        if let error = error as? BackupError { return error.errorDescription! }
        if error is DecodingError { return BackupError.manifest.errorDescription! }
        if error is HistoryDatabaseError { return "履歴の更新に失敗しました。変更は反映していません。" }
        return "ファイルの読み書きに失敗しました。空き容量とアクセス権を確認してください。"
    }
}

final class BackupCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationHandler: (() -> Void)?
    func cancel() {
        lock.lock()
        cancelled = true
        let handler = cancellationHandler
        lock.unlock()
        handler?()
    }
    func setCancellationHandler(_ handler: (() -> Void)?) {
        lock.lock()
        cancellationHandler = handler
        let invoke = cancelled
        lock.unlock()
        if invoke { handler?() }
    }
    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw BackupError.cancelled }
    }
}

struct BackupProgress {
    let completed: Int
    let total: Int
}

struct BackupManifest: Codable {
    let formatVersion: Int
    let createdAt: Date
    let itemCount: Int
    let entries: [HistoryEntry]

    func validate() throws {
        guard (1...2).contains(formatVersion), createdAt.timeIntervalSince1970.isFinite,
              itemCount == entries.count else { throw BackupError.manifest }
        var texts = Set<Data>()
        var hashes = Set<String>()
        var fileHashes = Set<String>()
        for entry in entries {
            guard entry.savedAt.timeIntervalSince1970.isFinite,
                  entry.lastCollectedAt.timeIntervalSince1970.isFinite,
                  entry.savedAt <= entry.lastCollectedAt, entry.collectionCount > 0,
                  entry.collectionCount <= HistoryCollectionCount.maximum else { throw BackupError.manifest }
            if entry.kind == .image {
                guard let image = entry.image, entry.file == nil, entry.text.isEmpty,
                      image.byteCount > 0, image.byteCount <= HistoryImageFiles.maximumByteCount,
                      image.pixelWidth > 0, image.pixelHeight > 0,
                      UTType(image.typeIdentifier)?.conforms(to: .image) == true,
                      image.hash.utf8.count == 64,
                      image.hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      hashes.insert(image.hash).inserted else { throw BackupError.image }
            } else if entry.kind == .file {
                guard formatVersion >= 2, let file = entry.file, entry.image == nil, entry.text.isEmpty,
                      file.byteCount >= 0, file.byteCount <= HistoryFileFiles.maximumByteCount,
                      HistoryFileTypes.isStorable(file.typeIdentifier),
                      HistoryFileTypes.filename(file.originalFilename, typeIdentifier: file.typeIdentifier) == file.originalFilename,
                      file.hash.utf8.count == 64,
                      file.hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      fileHashes.insert(file.hash).inserted else { throw BackupError.file }
            } else {
                guard entry.image == nil, entry.file == nil, HistoryKind.classify(entry.text) == entry.kind,
                      texts.insert(Data(entry.text.utf8)).inserted else { throw BackupError.manifest }
            }
        }
    }
}

struct BackupExport {
    let url: URL
    let manifestDigest: String
    let count: Int
}

// Owned by the workflow until confirmation/cancellation; all paths are locally generated.
final class ValidatedBackup {
    let directory: URL
    let entries: [HistoryEntry]
    private let temporaryFiles: BackupTemporaryFiles
    private let lock = NSLock()
    private var discarded = false

    init(directory: URL, entries: [HistoryEntry], temporaryFiles: BackupTemporaryFiles = .shared) {
        self.directory = directory
        self.entries = entries
        self.temporaryFiles = temporaryFiles
    }

    func discard() {
        lock.lock()
        defer { lock.unlock() }
        guard !discarded else { return }
        discarded = true
        // Capture only the URL in the cleanup job, never self (also called by deinit).
        temporaryFiles.remove(directory)
    }
    deinit { discard() }
}

enum HistoryBackup {
    static let magic = Data("CLIPPLUS".utf8)
    static let version: UInt64 = 2
    static let chunkSize = 64 * 1024
    // Only JSON metadata is buffered. Bound untrusted length before allocating it.
    static let maximumManifestBytes = 64 * 1024 * 1024

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func write(entries: [HistoryEntry], files: HistoryImageFiles, to url: URL,
                      cancellation: BackupCancellation, createdAt: Date = Date(),
                      temporaryFiles: BackupTemporaryFiles = .shared,
                      progress: (BackupProgress) -> Void = { _ in }) throws -> BackupExport {
        var succeeded = false
        defer { if !succeeded { temporaryFiles.remove(url) } }
        try cancellation.check()
        let outputVersion = entries.contains { $0.kind == .file } ? 2 : 1
        let manifest = BackupManifest(formatVersion: outputVersion, createdAt: createdAt, itemCount: entries.count, entries: entries)
        try manifest.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(manifest)
        guard json.count <= maximumManifestBytes else { throw BackupError.manifest }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw BackupError.unavailable }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try output.write(contentsOf: magic)
        try writeNumber(UInt64(outputVersion), to: output)
        try writeNumber(UInt64(json.count), to: output)
        try output.write(contentsOf: json)
        progress(BackupProgress(completed: 0, total: entries.count))
        for (index, entry) in entries.enumerated() {
            try cancellation.check()
            if let image = entry.image {
                let input = try FileHandle(forReadingFrom: files.url(for: image.filename))
                defer { try? input.close() }
                try writeNumber(UInt64(image.byteCount), to: output)
                let hash = try transfer(from: input, to: output, count: image.byteCount, cancellation: cancellation)
                guard hash == image.hash, try input.read(upToCount: 1)?.isEmpty != false else { throw BackupError.image }
            }
            if let file = entry.file {
                let input = try FileHandle(forReadingFrom: files.url(for: file.filename))
                defer { try? input.close() }
                try writeNumber(UInt64(file.byteCount), to: output)
                let hash = try transfer(from: input, to: output, count: file.byteCount, cancellation: cancellation)
                guard hash == file.hash, try input.read(upToCount: 1)?.isEmpty != false else { throw BackupError.file }
            }
            progress(BackupProgress(completed: index + 1, total: entries.count))
        }
        try cancellation.check()
        try output.synchronize()
        try output.close()
        succeeded = true
        return BackupExport(url: url, manifestDigest: digest(json), count: entries.count)
    }

    static func validate(at url: URL, temporaryRoot: URL? = nil,
                         cancellation: BackupCancellation,
                         temporaryFiles: BackupTemporaryFiles = .shared,
                         progress: (BackupProgress) -> Void = { _ in }) throws -> ValidatedBackup {
        let directory = (temporaryRoot ?? temporaryFiles.processDirectory)
            .appendingPathComponent("clipboardplus-restore-\(UUID().uuidString)", isDirectory: true)
        var succeeded = false
        defer { if !succeeded { temporaryFiles.remove(directory) } }
        try cancellation.check()
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        guard try readExact(8, from: input) == magic else { throw BackupError.identifier }
        let inputVersion = try readNumber(from: input)
        guard (1...version).contains(inputVersion) else { throw BackupError.version }
        let length = try readNumber(from: input)
        guard length > 0, length <= UInt64(maximumManifestBytes) else { throw BackupError.manifest }
        let json = try readExact(Int(length), from: input, cancellation: cancellation)
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: json)
        guard manifest.formatVersion == Int(inputVersion) else { throw BackupError.manifest }
        try manifest.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries: [HistoryEntry] = []
        progress(BackupProgress(completed: 0, total: manifest.itemCount))
        for (index, entry) in manifest.entries.enumerated() {
            try cancellation.check()
            var restored = entry
            if let image = entry.image {
                guard try readNumber(from: input) == UInt64(image.byteCount) else { throw BackupError.image }
                // Never use filenames from the archive, even after basename sanitization.
                let token = UUID().uuidString
                let suffix = UTType(image.typeIdentifier)?.preferredFilenameExtension ?? "image"
                let local = HistoryImage(hash: image.hash, filename: "\(token).\(suffix)",
                                         thumbnailFilename: "\(token)-thumbnail.jpg", byteCount: image.byteCount,
                                         pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight,
                                         typeIdentifier: image.typeIdentifier)
                let original = directory.appendingPathComponent(local.filename)
                guard FileManager.default.createFile(atPath: original.path, contents: nil) else { throw BackupError.unavailable }
                let output = try FileHandle(forWritingTo: original)
                do {
                    let hash = try transfer(from: input, to: output, count: image.byteCount, cancellation: cancellation)
                    try output.close()
                    guard hash == image.hash else { throw BackupError.image }
                } catch { try? output.close(); throw error }
                try autoreleasepool { try prepareThumbnail(local, in: directory) }
                restored = entry.with(image: local)
            }
            if let file = entry.file {
                guard try readNumber(from: input) == UInt64(file.byteCount) else { throw BackupError.file }
                let suffix = UTType(file.typeIdentifier)?.preferredFilenameExtension ?? "data"
                let local = HistoryFile(hash: file.hash, filename: "\(file.hash)-\(UUID().uuidString).\(suffix)",
                                        originalFilename: file.originalFilename, byteCount: file.byteCount,
                                        typeIdentifier: file.typeIdentifier)
                let original = directory.appendingPathComponent(local.filename)
                guard FileManager.default.createFile(atPath: original.path, contents: nil) else { throw BackupError.unavailable }
                let output = try FileHandle(forWritingTo: original)
                do {
                    let hash = try transfer(from: input, to: output, count: file.byteCount, cancellation: cancellation)
                    try output.close()
                    guard hash == file.hash else { throw BackupError.file }
                } catch { try? output.close(); throw error }
                restored = entry.with(file: local)
            }
            entries.append(restored)
            progress(BackupProgress(completed: index + 1, total: manifest.itemCount))
        }
        guard try input.read(upToCount: 1)?.isEmpty != false else { throw BackupError.trailingData }
        try cancellation.check()
        succeeded = true
        return ValidatedBackup(directory: directory, entries: entries, temporaryFiles: temporaryFiles)
    }

    private static func prepareThumbnail(_ image: HistoryImage, in directory: URL) throws {
        guard let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(image.filename) as CFURL,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary),
              let actualType = CGImageSourceGetType(source),
              let actual = UTType(actualType as String), let declared = UTType(image.typeIdentifier),
              actual.conforms(to: declared),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == image.pixelWidth,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == image.pixelHeight,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw BackupError.image }
        guard let destination = CGImageDestinationCreateWithURL(
            directory.appendingPathComponent(image.thumbnailFilename) as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw BackupError.unavailable }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BackupError.unavailable }
    }

    // UInt64 big endian, decoded bytewise (no alignment-dependent pointer loads).
    static func writeNumber(_ number: UInt64, to handle: FileHandle) throws {
        let bytes = (0..<8).reversed().map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) }
        try handle.write(contentsOf: Data(bytes))
    }

    static func readNumber(from handle: FileHandle) throws -> UInt64 {
        try readExact(8, from: handle).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func readExact(_ count: Int, from handle: FileHandle,
                                  cancellation: BackupCancellation? = nil) throws -> Data {
        var result = Data()
        while result.count < count {
            try cancellation?.check()
            guard let part = try handle.read(upToCount: min(chunkSize, count - result.count)), !part.isEmpty else {
                throw BackupError.truncated
            }
            result.append(part)
        }
        return result
    }

    private static func transfer(from input: FileHandle, to output: FileHandle, count: Int,
                                 cancellation: BackupCancellation) throws -> String {
        var remaining = count
        var hash = SHA256()
        while remaining > 0 {
            try autoreleasepool {
                try cancellation.check()
                guard let part = try input.read(upToCount: min(chunkSize, remaining)), !part.isEmpty else {
                    throw BackupError.truncated
                }
                hash.update(data: part)
                try output.write(contentsOf: part)
                remaining -= part.count
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension HistoryEntry {
    func with(file: HistoryFile) -> HistoryEntry {
        HistoryEntry(id: id, kind: kind, text: text, savedAt: savedAt, lastCollectedAt: lastCollectedAt,
                     collectionCount: collectionCount, isPinned: isPinned, source: source, image: image, file: file)
    }

    func with(image: HistoryImage) -> HistoryEntry {
        HistoryEntry(id: id, kind: kind, text: text, savedAt: savedAt, lastCollectedAt: lastCollectedAt,
                     collectionCount: collectionCount, isPinned: isPinned, source: source, image: image, file: file)
    }
}
