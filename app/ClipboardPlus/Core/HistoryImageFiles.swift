import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum HistoryImageError: Error {
    case tooLarge(Int)
    case invalidImage
    case fileWrite
    case unavailable

    var message: String {
        switch self {
        case .tooLarge: return "画像が大きすぎるため保存しませんでした"
        case .invalidImage: return "画像を読み込めないため保存しませんでした"
        case .fileWrite: return "画像ファイルを保存できませんでした。空き容量を確認してください。"
        case .unavailable: return "画像ファイルを読み込めませんでした"
        }
    }
}

final class HistoryImageFiles {
    // Decimal MB, shared by admission, UI documentation and tests.
    static let maximumByteCount = 20_000_000
    static let maximumTotalByteCount = 500_000_000
    static let preferredTypes = ["public.png", "public.jpeg", "public.heic", "public.heif",
                                 "com.compuserve.gif", "public.tiff", "com.microsoft.bmp", "org.webmproject.webp"]
    let directory: URL

    init(directory: URL) { self.directory = directory }

    /// Image types among the pasteboard's type names, preferred types first.
    static func imageTypes(in types: [String]) -> [String] {
        let preferred = preferredTypes.filter { types.contains($0) }
        let others = types.filter { !preferred.contains($0) && UTType($0)?.conforms(to: .image) == true }
        return preferred + others
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HistoryImages", isDirectory: true)
    }

    func url(for filename: String) -> URL {
        // DB filenames are local basenames, never paths supplied by a provider.
        directory.appendingPathComponent((filename as NSString).lastPathComponent)
    }

    static func hash(_ data: Data) throws -> String {
        guard data.count <= maximumByteCount else { throw HistoryImageError.tooLarge(data.count) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Call only off the main thread. ImageIO downsamples without decoding the original at full size.
    func prepare(_ data: Data, typeIdentifier: String, hash: String) throws -> HistoryImage {
        guard data.count <= Self.maximumByteCount else { throw HistoryImageError.tooLarge(data.count) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let actualType = CGImageSourceGetType(source),
              UTType(actualType as String)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw HistoryImageError.invalidImage }
        let token = UUID().uuidString
        let suffix = UTType(typeIdentifier)?.preferredFilenameExtension ?? "image"
        let metadata = HistoryImage(hash: hash, filename: "\(token).\(suffix)",
                                    thumbnailFilename: "\(token)-thumbnail.jpg", byteCount: data.count,
                                    pixelWidth: width.intValue, pixelHeight: height.intValue,
                                    typeIdentifier: typeIdentifier)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(for: metadata.filename), options: .atomic)
            guard let destination = CGImageDestinationCreateWithURL(
                url(for: metadata.thumbnailFilename) as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            ) else { throw HistoryImageError.fileWrite }
            CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw HistoryImageError.fileWrite }
            return metadata
        } catch {
            try? remove(metadata.filenames)
            throw HistoryImageError.fileWrite
        }
    }

    func read(_ image: HistoryImage) throws -> Data { try Data(contentsOf: url(for: image.filename)) }

    func remove(_ filenames: Set<String>) throws {
        for filename in filenames {
            let file = url(for: filename)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    func cleanUnreferenced(keeping filenames: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        for file in files where !filenames.contains(file.lastPathComponent) {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
