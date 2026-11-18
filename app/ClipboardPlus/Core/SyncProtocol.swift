import Foundation

public enum SyncProtocolError: Error, Equatable {
    case format, limit, packet, state, authentication, identity, sequence, version
}

enum SyncContentRejectReason: String, Equatable {
    case imageFormat = "画像形式不一致"
    case imageDimensions = "画像画素数超過"
    case imageCorrupt = "壊れた画像"
}

struct SyncContentRejectedError: Error, Equatable {
    let reason: SyncContentRejectReason
}

public enum SyncProtocol {
    public static let version: UInt8 = 3
    public static let maxItemBytes = 10 * 1024 * 1024
    public static let chunkBytes = 32 * 1024
    public static let maxPending = 100
    public static let maxImagePixels: Int64 = 40_000_000
    public static let pendingLifetime: TimeInterval = 24 * 60 * 60
    public static let maxTemplates = 300
    public static let maxTemplateTombstones = 1000
    public static let templateTombstoneLifetime: TimeInterval = 180 * 24 * 60 * 60
    public static let templateTombstoneLifetimeMillis: Int64 = 180 * 24 * 60 * 60 * 1000
    public static let maxTemplateTextBytes = 64 * 1024
    public static let maxTemplateTitleCharacters = 100
    public static let maxTemplateTitleBytes = 400
    public static let maxTemplateTagCharacters = 30
    public static let maxTemplateTagBytes = 120
    public static let maxTemplatePageBodyBytes = 256 * 1024
    public static let maxTemplatePages = 80
    public static let maxTemplateTotalBytes = 20 * 1024 * 1024
    public static let templateClockSkewWarningMillis: Int64 = 5 * 60 * 1000
    public static let templateFutureTimestampCapMillis: Int64 = 365 * 24 * 60 * 60 * 1000
    public static let maxFrameBytes = 4 * 1024 * 1024
    public static let maxPlaintextBytes = maxFrameBytes - 9 - 16
    public static let maxHeaderBytes = 65_535
    public static let maxAckIds = 1024
    public static let maxTimestamp: Int64 = 9_007_199_254_740_991

    static func isControlCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
    }

    static func isControlOrNewline(_ scalar: Unicode.Scalar) -> Bool {
        isControlCharacter(scalar) || scalar.value == 0x2028 || scalar.value == 0x2029
    }

    static func isLowerHex64(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func require(_ condition: Bool, _ error: SyncProtocolError = .format) throws {
        if !condition { throw error }
    }
    static func fixed(_ data: Data, _ count: Int) throws -> Data {
        try require(data.count == count)
        return Data(data)
    }
    // RFC 4122 / text order, never Windows Guid's historical mixed-endian layout.
    static func idBytes(_ id: UUID) -> Data {
        var value = id.uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    static func id(_ data: Data) throws -> UUID {
        let b = [UInt8](data)
        try require(b.count == 16)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
    static func parseId(_ value: String) throws -> UUID {
        guard value.utf8.count == 36, let result = UUID(uuidString: value),
              result.uuidString.lowercased() == value.lowercased() else { throw SyncProtocolError.format }
        return result
    }
    static func number(_ value: UInt64) -> Data {
        Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
}
