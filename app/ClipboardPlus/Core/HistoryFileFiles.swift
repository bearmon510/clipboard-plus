import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct HistoryFile: Codable, Equatable {
    let hash: String
    let filename: String
    let originalFilename: String
    let byteCount: Int
    let typeIdentifier: String

    var filenames: Set<String> { [filename] }
    var displayName: String { originalFilename }
    var typeDescription: String { UTType(typeIdentifier)?.localizedDescription ?? "ファイル" }
    var sizeDescription: String { ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }
    var symbolName: String {
        guard let type = UTType(typeIdentifier) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .compositeContent) { return "doc.text" }
        return "doc"
    }
}

struct HistoryFileUsage: Equatable {
    var count = 0
    var byteCount = 0
}

enum HistoryFileError: Error {
    case tooLarge, unsupportedType, unavailable, fileWrite

    var message: String {
        switch self {
        case .tooLarge: return "ファイルが50MBを超えるため保存しませんでした"
        case .unsupportedType: return "この種類のファイルは保存できません"
        case .unavailable: return "ファイルを読み込めませんでした"
        case .fileWrite: return "ファイルを保存できませんでした。空き容量を確認してください。"
        }
    }
}

enum HistoryFileTypes {
    static func isFile(_ identifier: String) -> Bool {
        guard !identifier.hasPrefix("dyn."),
              !["com.apple.uikit.", "com.apple.pasteboard.", "com.apple.private.",
                "com.apple.notes.", "com.apple.flat-rtfd", "com.apple.rtfd",
                "example.clipboardplus."].contains(where: { identifier.hasPrefix($0) }),
              let type = UTType(identifier),
              type.conforms(to: .data) || type.conforms(to: .content),
              !type.conforms(to: .text), !type.conforms(to: .url), !type.conforms(to: .image),
              !type.conforms(to: .directory) else { return false }
        return true
    }

    /// A text/URL representation vetoes files even if loading the text fails.
    /// RTFD is composite content on some OS versions, so explicitly treat it as rich text.
    static func hasTextOrURL(_ types: [String]) -> Bool {
        types.contains {
            // Files may offer a locator alongside real PDF/ZIP/movie bytes. Never follow the
            // locator, but do not let it hide an independently readable file representation.
            if UTType($0)?.conforms(to: .fileURL) == true { return false }
            return $0 == "com.apple.flat-rtfd" || $0 == "com.apple.rtfd" ||
                UTType($0)?.conforms(to: .text) == true || UTType($0)?.conforms(to: .url) == true
        }
    }

    static func preferred(in types: [String]) -> String? {
        guard !ClipboardPrivacy.hasPrivateMarker(in: types), !hasTextOrURL(types),
              HistoryImageFiles.imageTypes(in: types).isEmpty else { return nil }
        return types.first(where: isFile)
    }

    static func rejectionReason(_ types: [String]) -> String {
        if ClipboardPrivacy.hasPrivateMarker(in: types) { return "秘密の印" }
        if hasTextOrURL(types) { return "文章・URLの表現を優先" }
        if !HistoryImageFiles.imageTypes(in: types).isEmpty { return "画像を優先" }
        return "対象の型なし（動的型・内部型・未登録型・ディレクトリを除外）"
    }

    static func filename(_ suggested: String?, typeIdentifier: String) -> String {
        // A provider name is a label, never a path. Strip control characters too.
        let name = (suggested ?? "").replacingOccurrences(of: "\\", with: "/")
            .components(separatedBy: "/").last ?? ""
        let clean = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        if !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, clean != ".", clean != ".." {
            return String(clean.prefix(240))
        }
        return "ファイル" + (UTType(typeIdentifier)?.preferredFilenameExtension.map { "." + $0 } ?? "")
    }
}

/// Owns a temporary original. Provider URLs cease to be valid when their callback returns.
/// Also used as a lifetime lease for outbound providers, independent of history deletion.
final class HistoryFileInput {
    let url: URL
    let file: HistoryFile
    private let directory: URL
    init(url: URL, file: HistoryFile, directory: URL) {
        self.url = url
        self.file = file
        self.directory = directory
    }
    deinit { BackupTemporaryFiles.shared.remove(directory) }
}

final class HistoryFileFiles {
    static let maximumByteCount = 50_000_000 // Decimal MB, as for images.
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func url(for file: HistoryFile) -> URL {
        directory.appendingPathComponent((file.filename as NSString).lastPathComponent)
    }

    /// Run off the main thread, inside loadFileRepresentation's callback. Memory is bounded
    /// to one 64 KiB chunk; actual bytes are checked even if the provider reports a false size.
    static func stage(_ source: URL, typeIdentifier: String, suggestedName: String?) throws -> HistoryFileInput {
        guard HistoryFileTypes.isFile(typeIdentifier) else { throw HistoryFileError.unsupportedType }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw HistoryFileError.unavailable }
        guard (values.fileSize ?? 0) <= maximumByteCount else { throw HistoryFileError.tooLarge }
        let directory = BackupTemporaryFiles.shared.processDirectory.appendingPathComponent("file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { BackupTemporaryFiles.shared.remove(directory) } }
        let name = HistoryFileTypes.filename(suggestedName, typeIdentifier: typeIdentifier)
        // Use a fixed local basename: user-facing names can exceed a filesystem's byte limit.
        let destination = directory.appendingPathComponent("original")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw HistoryFileError.fileWrite }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hash = SHA256()
        var count = 0
        while true {
            let read = try autoreleasepool { () throws -> Int in
                guard let part = try input.read(upToCount: 64 * 1024), !part.isEmpty else { return 0 }
                count += part.count
                guard count <= maximumByteCount else { throw HistoryFileError.tooLarge }
                hash.update(data: part)
                try output.write(contentsOf: part)
                return part.count
            }
            if read == 0 { break }
        }
        try output.close()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let suffix = UTType(typeIdentifier)?.preferredFilenameExtension ?? "data"
        let file = HistoryFile(hash: digest, filename: "\(digest)-\(UUID().uuidString).\(suffix)",
                               originalFilename: name, byteCount: count, typeIdentifier: typeIdentifier)
        succeeded = true
        return HistoryFileInput(url: destination, file: file, directory: directory)
    }

    func prepare(_ input: HistoryFileInput) throws -> HistoryFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: input.url, to: url(for: input.file))
        return input.file
    }
}
