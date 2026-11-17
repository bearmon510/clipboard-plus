import Foundation

public enum SyncMessage: Equatable {
    case item(id: UUID, at: Int64, from: String, text: String)
    case ack(ids: [UUID])
    case ping
    case pong
    case device(kind: String)
    case offer(SyncOffer)
    case chunk(id: UUID, offset: Int, data: Data)
    case resume(id: UUID, offset: Int)
}

public struct SyncOffer: Codable, Equatable {
    public let id: UUID
    public let at: Int64
    public let from: String
    public let kind: String
    public let size: Int
    public let sha256: String
    public let name64: String
    public let type: String
    public var filename: String { String(data: Data(base64Encoded: name64) ?? Data(), encoding: .utf8) ?? "" }
    func validate() throws {
        try SyncProtocol.require(at >= -SyncProtocol.maxTimestamp && at <= SyncProtocol.maxTimestamp && ["pc", "pad"].contains(from))
        try SyncProtocol.require(["image", "file"].contains(kind) && (0...SyncProtocol.maxItemBytes).contains(size))
        try SyncProtocol.require(sha256.utf8.count == 64 && sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        try SyncProtocol.require((1...255).contains(type.utf8.count) && type.utf8.allSatisfy { (32..<127).contains($0) })
        try SyncProtocol.require(kind != "image" || ["public.png", "public.jpeg"].contains(type))
        guard let name = Data(base64Encoded: name64), name.count <= 1024, name.base64EncodedString() == name64,
              let decoded = String(data: name, encoding: .utf8),
              // Reject Unicode Cc (U+0000..U+001F, U+007F..U+009F) while permitting Cf (e.g. U+200D ZWJ).
              !decoded.unicodeScalars.contains(where: SyncProtocol.isControlCharacter),
              kind != "file" || !decoded.isEmpty else { throw SyncProtocolError.format }
    }
}

public enum SyncMessageCodec {
    public static func encode(_ message: SyncMessage) throws -> Data {
        let header: String
        let body: Data
        // Only fixed ASCII vocabulary, UUIDs and integers enter the header.
        switch message {
        case .device(let kind):
            try SyncProtocol.require(["phone", "pad"].contains(kind))
            header = "{\"kind\":\"\(kind)\",\"t\":\"device\"}"; body = Data()
        case .offer(let offer):
            try offer.validate()
            let object: [String: Any] = ["at": offer.at, "from": offer.from, "id": offer.id.uuidString,
                "kind": offer.kind, "name64": offer.name64, "sha256": offer.sha256, "size": offer.size, "t": "offer", "type": offer.type]
            header = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            body = Data()
        case let .resume(id, offset):
            try SyncProtocol.require((0...SyncProtocol.maxItemBytes).contains(offset))
            header = "{\"id\":\"\(id.uuidString)\",\"offset\":\(offset),\"t\":\"resume\"}"; body = Data()
        case let .chunk(id, offset, data):
            try SyncProtocol.require(offset >= 0 && (1...SyncProtocol.chunkBytes).contains(data.count) && offset <= SyncProtocol.maxItemBytes - data.count)
            header = "{\"id\":\"\(id.uuidString)\",\"offset\":\(offset),\"t\":\"chunk\"}"; body = data
        case let .item(id, at, from, text):
            try SyncProtocol.require(at >= -SyncProtocol.maxTimestamp && at <= SyncProtocol.maxTimestamp && (from == "pad" || from == "pc"))
            try SyncProtocol.require(text.utf8.count <= SyncProtocol.maxPlaintextBytes, .limit)
            header = "{\"at\":\(at),\"from\":\"\(from)\",\"id\":\"\(id.uuidString)\",\"kind\":\"text\",\"t\":\"item\"}"
            body = Data(text.utf8)
        case let .ack(ids):
            try SyncProtocol.require((1...SyncProtocol.maxAckIds).contains(ids.count), .limit)
            header = "{\"ids\":[" + ids.map { "\"\($0.uuidString)\"" }.joined(separator: ",") + "],\"t\":\"ack\"}"
            body = Data()
        case .ping:
            header = "{\"t\":\"ping\"}"
            body = Data()
        case .pong:
            header = "{\"t\":\"pong\"}"
            body = Data()
        }
        let bytes = Data(header.utf8)
        try SyncProtocol.require(bytes.count <= SyncProtocol.maxHeaderBytes && 2 + bytes.count + body.count <= SyncProtocol.maxPlaintextBytes, .limit)
        return Data([UInt8(bytes.count >> 8), UInt8(truncatingIfNeeded: bytes.count)]) + bytes + body
    }

    public static func decode(_ input: Data) throws -> SyncMessage {
        try SyncProtocol.require(input.count <= SyncProtocol.maxPlaintextBytes, .limit)
        try SyncProtocol.require(input.count >= 2)
        let plaintext = Data(input)
        let length = Int(plaintext[0]) << 8 | Int(plaintext[1])
        try SyncProtocol.require(length > 0 && length <= plaintext.count - 2)
        let header = plaintext.subdata(in: 2..<(2 + length))
        try SyncProtocol.require(header.allSatisfy { $0 < 128 })
        let body = plaintext.subdata(in: (2 + length)..<plaintext.count)
        do {
            // Scan only member boundaries, preserving the lexical integer and detecting duplicates.
            // Foundation remains responsible for the actual JSON grammar and string decoding.
            let raw = try members(header)
            guard let object = try JSONSerialization.jsonObject(with: header) as? [String: Any] else { throw SyncProtocolError.format }
            try ascii(object)
            func keys(_ expected: [String]) throws {
                try SyncProtocol.require(Set(object.keys) == Set(expected))
            }
            func integer(_ key: String) throws -> Int64 {
                guard let bytes = raw[key], let text = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      text.range(of: "^-?(0|[1-9][0-9]*)$", options: .regularExpression) != nil,
                      let value = Int64(text) else { throw SyncProtocolError.format }
                return value
            }
            func string(_ key: String) throws -> String {
                guard let value = object[key] as? String else { throw SyncProtocolError.format }; return value
            }
            switch object["t"] as? String {
            case "device":
                try keys(["kind", "t"])
                let kind = try string("kind")
                try SyncProtocol.require(body.isEmpty && ["phone", "pad"].contains(kind))
                return .device(kind: kind)
            case "offer":
                try keys(["at", "from", "id", "kind", "name64", "sha256", "size", "t", "type"])
                try SyncProtocol.require(body.isEmpty)
                let size = try integer("size")
                try SyncProtocol.require(size >= 0 && size <= Int64(SyncProtocol.maxItemBytes))
                let offer = try SyncOffer(id: SyncProtocol.parseId(string("id")), at: integer("at"), from: string("from"),
                    kind: string("kind"), size: Int(size), sha256: string("sha256"), name64: string("name64"), type: string("type"))
                try offer.validate(); return .offer(offer)
            case "chunk", "resume":
                try keys(["id", "offset", "t"])
                let offset = try integer("offset"), id = try SyncProtocol.parseId(string("id"))
                try SyncProtocol.require(offset >= 0 && offset <= Int64(SyncProtocol.maxItemBytes))
                if object["t"] as? String == "resume" {
                    try SyncProtocol.require(body.isEmpty); return .resume(id: id, offset: Int(offset))
                }
                try SyncProtocol.require((1...SyncProtocol.chunkBytes).contains(body.count) && offset + Int64(body.count) <= Int64(SyncProtocol.maxItemBytes))
                return .chunk(id: id, offset: Int(offset), data: body)
            case "item":
                try keys(["at", "from", "id", "kind", "t"])
                guard object["kind"] as? String == "text", let from = object["from"] as? String,
                      from == "pad" || from == "pc", let id = object["id"] as? String,
                      let atBytes = raw["at"], let atText = String(data: atBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      atText.range(of: "^-?(0|[1-9][0-9]*)$", options: .regularExpression) != nil,
                      let at = Int64(atText), at >= -SyncProtocol.maxTimestamp, at <= SyncProtocol.maxTimestamp,
                      let text = String(data: body, encoding: .utf8) else { throw SyncProtocolError.format }
                return .item(id: try SyncProtocol.parseId(id), at: at, from: from, text: text)
            case "ack":
                try keys(["ids", "t"])
                guard body.isEmpty, let ids = object["ids"] as? [String] else { throw SyncProtocolError.format }
                try SyncProtocol.require((1...SyncProtocol.maxAckIds).contains(ids.count), .limit)
                return .ack(ids: try ids.map(SyncProtocol.parseId))
            case "ping":
                try keys(["t"])
                try SyncProtocol.require(body.isEmpty)
                return .ping
            case "pong":
                try keys(["t"])
                try SyncProtocol.require(body.isEmpty)
                return .pong
            default: throw SyncProtocolError.format
            }
        } catch let error as SyncProtocolError { throw error }
        catch { throw SyncProtocolError.format }
    }

    private static func ascii(_ value: Any) throws {
        if let text = value as? String { try SyncProtocol.require(text.utf8.allSatisfy { $0 < 128 }) }
        else if let array = value as? [Any] { for child in array { try ascii(child) } }
        else if let object = value as? [String: Any] {
            for (key, child) in object { try ascii(key); try ascii(child) }
        }
    }

    private static func members(_ data: Data) throws -> [String: Data] {
        let bytes = Array(data)
        var depth = 0, quoted = false, escaped = false, start = 0
        var colon: Int?
        var result: [String: Data] = [:]
        func add(_ end: Int) throws {
            guard let colon = colon, colon >= start else { return }
            let keyData = Data(bytes[start..<colon])
            guard let key = try JSONSerialization.jsonObject(with: keyData, options: .fragmentsAllowed) as? String,
                  result[key] == nil else { throw SyncProtocolError.format }
            result[key] = Data(bytes[(colon + 1)..<end])
        }
        for (i, b) in bytes.enumerated() {
            if quoted {
                try SyncProtocol.require(b >= 32)
                if escaped { escaped = false }
                else if b == 92 { escaped = true }
                else if b == 34 { quoted = false }
                continue
            }
            if b == 34 { quoted = true; continue }
            // Foundation can be permissive about trailing commas on some platforms.
            if b == 44 {
                let next = bytes.dropFirst(i + 1).first { ![9, 10, 13, 32].contains($0) }
                try SyncProtocol.require(next != 125 && next != 93)
            }
            if b == 123 || b == 91 {
                depth += 1
                try SyncProtocol.require(depth <= 8)
                if depth == 1 { start = i + 1 }
            } else if b == 125 || b == 93 {
                if depth == 1 { try add(i) }
                depth -= 1
            } else if depth == 1 && b == 58 { colon = i }
            else if depth == 1 && b == 44 { try add(i); start = i + 1; colon = nil }
        }
        return result
    }
}
