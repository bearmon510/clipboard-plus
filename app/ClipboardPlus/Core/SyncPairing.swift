import Foundation
import CryptoKit

public struct SyncPairing: Equatable, CustomReflectable {
    public let pcId: UUID
    public let key: Data
    public let name: String

    public init(pcId: UUID, key: Data, name: String) throws {
        self.pcId = pcId
        self.key = try SyncProtocol.fixed(key, 32)
        try SyncProtocol.require((1...255).contains(name.utf8.count) && !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 })
        self.name = name
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["name": name, "redacted": true], displayStyle: .struct)
    }
    public static func create(name: String) throws -> SyncPairing {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return try SyncPairing(pcId: UUID(), key: key, name: name)
    }
    private static func unreserved(_ b: UInt8) -> Bool {
        (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) || [45, 46, 95, 126].contains(b)
    }
    private static func base64url(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    public func qrString() -> String {
        let encodedName = name.utf8.map { Self.unreserved($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
        return "clipboardplus-pair:1:\(Self.base64url(SyncProtocol.idBytes(pcId))):\(Self.base64url(key)):\(encodedName)"
    }
    public static func parse(_ text: String) throws -> SyncPairing {
        try SyncProtocol.require(text.utf8.count <= 853)
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        try SyncProtocol.require(parts.count == 5 && parts[0] == "clipboardplus-pair" && parts[1] == "1")
        func decode(_ s: String, count: Int) throws -> Data {
            try SyncProtocol.require(s.utf8.count == (count * 8 + 5) / 6 && s.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
            })
            let padded = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                + String(repeating: "=", count: (4 - s.utf8.count % 4) % 4)
            guard let b = Data(base64Encoded: padded), b.count == count, Self.base64url(b) == s else { throw SyncProtocolError.format }
            return b
        }
        let id = try SyncProtocol.id(decode(parts[2], count: 16))
        let key = try decode(parts[3], count: 32)
        let encoded = Array(parts[4].utf8)
        var bytes = Data(), i = 0
        while i < encoded.count {
            if unreserved(encoded[i]) { bytes.append(encoded[i]); i += 1 }
            else {
                try SyncProtocol.require(encoded[i] == 37 && i + 2 < encoded.count)
                let pair = String(decoding: encoded[(i + 1)...(i + 2)], as: UTF8.self)
                guard pair.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let b = UInt8(pair, radix: 16) else { throw SyncProtocolError.format }
                bytes.append(b); i += 3
            }
        }
        guard let name = String(data: bytes, encoding: .utf8) else { throw SyncProtocolError.format }
        return try SyncPairing(pcId: id, key: key, name: name)
    }
}
