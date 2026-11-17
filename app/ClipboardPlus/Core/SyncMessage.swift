import Foundation

public enum SyncMessage: Equatable {
    case item(id: UUID, at: Int64, from: String, text: String)
    case ack(ids: [UUID])
    case ping
}

public enum SyncMessageCodec {
    public static func encode(_ message: SyncMessage) throws -> Data {
        let header: String
        let body: Data
        // Only fixed ASCII vocabulary, UUIDs and integers enter the header.
        switch message {
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
            switch object["t"] as? String {
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
