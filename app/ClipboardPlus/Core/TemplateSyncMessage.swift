import Foundation

public enum TemplateSyncKind: String, Codable, Equatable {
    case text
    case url
}

public struct TemplateSyncItem: Codable, Equatable {
    public let id: UUID
    public let kind: TemplateSyncKind
    public let text: String
    public let title: String?
    public let tag: String?
    public let order: Int
    public let updatedAt: Int64
    public let baseHash: String?

    public init(id: UUID, kind: TemplateSyncKind, text: String, title: String? = nil, tag: String? = nil,
                order: Int, updatedAt: Int64, baseHash: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.title = title
        self.tag = tag
        self.order = order
        self.updatedAt = updatedAt
        self.baseHash = baseHash
    }
}

public struct TemplateSyncTombstone: Codable, Equatable {
    public let id: UUID
    public let deletedAt: Int64
    public let baseHash: String?

    public init(id: UUID, deletedAt: Int64, baseHash: String? = nil) {
        self.id = id
        self.deletedAt = deletedAt
        self.baseHash = baseHash
    }
}

public struct TemplateSyncPage: Equatable {
    public let version: Int?
    public let sentAt: Int64?
    public let templates: [TemplateSyncItem]
    public let tombstones: [TemplateSyncTombstone]

    public init(version: Int? = nil, sentAt: Int64? = nil,
                templates: [TemplateSyncItem], tombstones: [TemplateSyncTombstone]) {
        self.version = version
        self.sentAt = sentAt
        self.templates = templates
        self.tombstones = tombstones
    }
}

public struct TemplateSyncSnapshot: Equatable {
    public let sentAt: Int64
    public let templates: [TemplateSyncItem]
    public let tombstones: [TemplateSyncTombstone]

    public init(sentAt: Int64, templates: [TemplateSyncItem], tombstones: [TemplateSyncTombstone]) {
        self.sentAt = sentAt
        self.templates = templates
        self.tombstones = tombstones
    }
}

public enum TemplateSyncMessage: Equatable {
    case pull(op: UUID)
    case push(op: UUID, part: Int, total: Int, page: TemplateSyncPage)
    case state(op: UUID, part: Int, total: Int, page: TemplateSyncPage)
    case ack(op: UUID)
}

enum TemplateCanonicalJson {
    static func serializeString(_ value: String) -> String {
        var result = "\""
        result.reserveCapacity(value.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result.append("\\\"")
            case 0x5C: result.append("\\\\")
            case 0x08: result.append("\\b")
            case 0x0C: result.append("\\f")
            case 0x0A: result.append("\\n")
            case 0x0D: result.append("\\r")
            case 0x09: result.append("\\t")
            case 0x00...0x1F:
                result.append(String(format: "\\u%04x", scalar.value))
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result.append("\"")
        return result
    }

    static func serializeItem(_ item: TemplateSyncItem, includeBaseHash: Bool) -> String {
        var parts: [String] = []
        if includeBaseHash, let baseHash = item.baseHash {
            parts.append("\"baseHash\":" + serializeString(baseHash))
        }
        parts.append("\"id\":" + serializeString(item.id.uuidString))
        parts.append("\"kind\":\"" + item.kind.rawValue + "\"")
        parts.append("\"order\":" + String(item.order))
        if let tag = item.tag {
            parts.append("\"tag\":" + serializeString(tag))
        }
        parts.append("\"text\":" + serializeString(item.text))
        if let title = item.title {
            parts.append("\"title\":" + serializeString(title))
        }
        parts.append("\"updatedAt\":" + String(item.updatedAt))
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func serializeTombstone(_ tomb: TemplateSyncTombstone) -> String {
        var parts: [String] = []
        if let baseHash = tomb.baseHash {
            parts.append("\"baseHash\":" + serializeString(baseHash))
        }
        parts.append("\"deletedAt\":" + String(tomb.deletedAt))
        parts.append("\"id\":" + serializeString(tomb.id.uuidString))
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func serializePage(_ page: TemplateSyncPage, isFirstPage: Bool, includeItemBaseHash: Bool) -> String {
        var result = "{"
        if isFirstPage {
            result += "\"sentAt\":" + String(page.sentAt ?? 0) + ","
        }
        result += "\"templates\":[" + page.templates.map { serializeItem($0, includeBaseHash: includeItemBaseHash) }.joined(separator: ",") + "]"
        result += ",\"tombstones\":[" + page.tombstones.map { serializeTombstone($0) }.joined(separator: ",") + "]"
        if isFirstPage {
            result += ",\"v\":" + String(page.version ?? 1)
        }
        result += "}"
        return result
    }
}

enum TemplateStrictJson {
    enum Value {
        case object([String: Value])
        case array([Value])
        case string(String)
        case integer(Int64)
        case otherNumber
        case bool(Bool)
        case null
    }

    static func parse(_ data: Data, asciiOnly: Bool = false, maxDepth: Int = 8) throws -> Value {
        guard String(data: data, encoding: .utf8) != nil else { throw SyncProtocolError.format }
        if asciiOnly { try SyncProtocol.require(data.allSatisfy { $0 < 128 }) }
        var parser = Parser(bytes: [UInt8](data), asciiOnly: asciiOnly, maxDepth: maxDepth)
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        try SyncProtocol.require(parser.isAtEnd)
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        let asciiOnly: Bool
        let maxDepth: Int
        var pos = 0

        var isAtEnd: Bool { pos >= bytes.count }

        mutating func skipWhitespace() {
            while pos < bytes.count {
                let b = bytes[pos]
                if b == 32 || b == 9 || b == 10 || b == 13 { pos += 1 }
                else { break }
            }
        }

        mutating func parseValue(depth: Int) throws -> Value {
            skipWhitespace()
            guard pos < bytes.count else { throw SyncProtocolError.format }
            switch bytes[pos] {
            case 123: return try parseObject(depth: depth + 1)
            case 91: return try parseArray(depth: depth + 1)
            case 34: return .string(try parseString())
            case 116:
                try expectKeyword([116, 114, 117, 101])
                return .bool(true)
            case 102:
                try expectKeyword([102, 97, 108, 115, 101])
                return .bool(false)
            case 110:
                try expectKeyword([110, 117, 108, 108])
                return .null
            case 45, 48...57:
                return try parseNumber()
            default:
                throw SyncProtocolError.format
            }
        }

        mutating func expectKeyword(_ expected: [UInt8]) throws {
            guard pos + expected.count <= bytes.count else { throw SyncProtocolError.format }
            for i in 0..<expected.count {
                guard bytes[pos + i] == expected[i] else { throw SyncProtocolError.format }
            }
            pos += expected.count
        }

        mutating func parseObject(depth: Int) throws -> Value {
            try SyncProtocol.require(depth <= maxDepth)
            pos += 1
            skipWhitespace()
            var dict: [String: Value] = [:]
            if pos < bytes.count && bytes[pos] == 125 {
                pos += 1
                return .object(dict)
            }
            while true {
                skipWhitespace()
                guard pos < bytes.count && bytes[pos] == 34 else { throw SyncProtocolError.format }
                let key = try parseString()
                try SyncProtocol.require(dict[key] == nil)
                skipWhitespace()
                guard pos < bytes.count && bytes[pos] == 58 else { throw SyncProtocolError.format }
                pos += 1
                dict[key] = try parseValue(depth: depth)
                skipWhitespace()
                guard pos < bytes.count else { throw SyncProtocolError.format }
                if bytes[pos] == 125 {
                    pos += 1
                    return .object(dict)
                }
                guard bytes[pos] == 44 else { throw SyncProtocolError.format }
                pos += 1
            }
        }

        mutating func parseArray(depth: Int) throws -> Value {
            try SyncProtocol.require(depth <= maxDepth)
            pos += 1
            skipWhitespace()
            var list: [Value] = []
            if pos < bytes.count && bytes[pos] == 93 {
                pos += 1
                return .array(list)
            }
            while true {
                list.append(try parseValue(depth: depth))
                skipWhitespace()
                guard pos < bytes.count else { throw SyncProtocolError.format }
                if bytes[pos] == 93 {
                    pos += 1
                    return .array(list)
                }
                guard bytes[pos] == 44 else { throw SyncProtocolError.format }
                pos += 1
            }
        }

        mutating func parseString() throws -> String {
            pos += 1
            var out: [UInt8] = []
            while pos < bytes.count {
                let b = bytes[pos]
                if b == 34 {
                    pos += 1
                    guard let result = String(bytes: out, encoding: .utf8) else { throw SyncProtocolError.format }
                    if asciiOnly { try SyncProtocol.require(result.utf8.allSatisfy { $0 < 128 }) }
                    return result
                }
                if b < 32 { throw SyncProtocolError.format }
                if b != 92 {
                    out.append(b)
                    pos += 1
                    continue
                }
                pos += 1
                guard pos < bytes.count else { throw SyncProtocolError.format }
                switch bytes[pos] {
                case 34: out.append(34); pos += 1
                case 92: out.append(92); pos += 1
                case 47: out.append(47); pos += 1
                case 98: out.append(8); pos += 1
                case 102: out.append(12); pos += 1
                case 110: out.append(10); pos += 1
                case 114: out.append(13); pos += 1
                case 116: out.append(9); pos += 1
                case 117:
                    pos += 1
                    let unit = try parseHex4()
                    if (0xD800...0xDBFF).contains(unit) {
                        guard pos + 1 < bytes.count && bytes[pos] == 92 && bytes[pos + 1] == 117 else {
                            throw SyncProtocolError.format
                        }
                        pos += 2
                        let low = try parseHex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw SyncProtocolError.format }
                        let cp = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                        guard let scalar = Unicode.Scalar(cp) else { throw SyncProtocolError.format }
                        out.append(contentsOf: String(scalar).utf8)
                    } else if (0xDC00...0xDFFF).contains(unit) {
                        throw SyncProtocolError.format
                    } else {
                        guard let scalar = Unicode.Scalar(unit) else { throw SyncProtocolError.format }
                        out.append(contentsOf: String(scalar).utf8)
                    }
                default:
                    throw SyncProtocolError.format
                }
            }
            throw SyncProtocolError.format
        }

        mutating func parseHex4() throws -> UInt32 {
            guard pos + 4 <= bytes.count else { throw SyncProtocolError.format }
            var value: UInt32 = 0
            for i in 0..<4 {
                let b = bytes[pos + i]
                let nibble: UInt32
                if (48...57).contains(b) { nibble = UInt32(b - 48) }
                else if (65...70).contains(b) { nibble = UInt32(b - 55) }
                else if (97...102).contains(b) { nibble = UInt32(b - 87) }
                else { throw SyncProtocolError.format }
                value = (value << 4) | nibble
            }
            pos += 4
            return value
        }

        mutating func parseNumber() throws -> Value {
            let start = pos
            if bytes[pos] == 45 { pos += 1 }
            guard pos < bytes.count else { throw SyncProtocolError.format }
            if bytes[pos] == 48 {
                pos += 1
            } else if (49...57).contains(bytes[pos]) {
                while pos < bytes.count && (48...57).contains(bytes[pos]) { pos += 1 }
            } else {
                throw SyncProtocolError.format
            }
            var isPlainInt = true
            if pos < bytes.count && bytes[pos] == 46 {
                isPlainInt = false
                pos += 1
                guard pos < bytes.count && (48...57).contains(bytes[pos]) else { throw SyncProtocolError.format }
                while pos < bytes.count && (48...57).contains(bytes[pos]) { pos += 1 }
            }
            if pos < bytes.count && (bytes[pos] == 101 || bytes[pos] == 69) {
                isPlainInt = false
                pos += 1
                if pos < bytes.count && (bytes[pos] == 43 || bytes[pos] == 45) { pos += 1 }
                guard pos < bytes.count && (48...57).contains(bytes[pos]) else { throw SyncProtocolError.format }
                while pos < bytes.count && (48...57).contains(bytes[pos]) { pos += 1 }
            }
            if isPlainInt {
                let raw = String(decoding: bytes[start..<pos], as: UTF8.self)
                if let intVal = Int64(raw) { return .integer(intVal) }
            }
            return .otherNumber
        }
    }
}

public enum TemplateSyncMessageCodec {
    static func validateTextString(_ text: String, maxBytes: Int) throws {
        try SyncProtocol.require(text.utf8.count <= maxBytes, .limit)
    }

    static func validateLabelString(_ value: String, maxChars: Int, maxBytes: Int) throws {
        try SyncProtocol.require(!value.unicodeScalars.contains(where: SyncProtocol.isControlOrNewline))
        try SyncProtocol.require(value.utf8.count <= maxBytes, .limit)
        try SyncProtocol.require(value.count <= maxChars, .limit)
    }

    public static func validateItem(_ item: TemplateSyncItem, allowBaseHash: Bool) throws {
        try validateTextString(item.text, maxBytes: SyncProtocol.maxTemplateTextBytes)
        if let title = item.title {
            try validateLabelString(title, maxChars: SyncProtocol.maxTemplateTitleCharacters, maxBytes: SyncProtocol.maxTemplateTitleBytes)
        }
        if let tag = item.tag {
            try validateLabelString(tag, maxChars: SyncProtocol.maxTemplateTagCharacters, maxBytes: SyncProtocol.maxTemplateTagBytes)
        }
        try SyncProtocol.require(item.order >= 0)
        try SyncProtocol.require(item.updatedAt >= -SyncProtocol.maxTimestamp && item.updatedAt <= SyncProtocol.maxTimestamp)
        if !allowBaseHash {
            try SyncProtocol.require(item.baseHash == nil)
        } else if let baseHash = item.baseHash {
            try SyncProtocol.require(SyncProtocol.isLowerHex64(baseHash))
        }
    }

    public static func validateTombstone(_ tomb: TemplateSyncTombstone) throws {
        try SyncProtocol.require(tomb.deletedAt >= -SyncProtocol.maxTimestamp && tomb.deletedAt <= SyncProtocol.maxTimestamp)
        if let baseHash = tomb.baseHash {
            try SyncProtocol.require(SyncProtocol.isLowerHex64(baseHash))
        }
    }

    static func validatePage(_ page: TemplateSyncPage, part: Int, total: Int, isState: Bool) throws {
        try SyncProtocol.require(total >= 1)
        try SyncProtocol.require(total <= SyncProtocol.maxTemplatePages, .limit)
        try SyncProtocol.require(part >= 0 && part < total)
        if part == 0 {
            try SyncProtocol.require(page.version == 1)
            guard let sentAt = page.sentAt,
                  sentAt >= -SyncProtocol.maxTimestamp && sentAt <= SyncProtocol.maxTimestamp else {
                throw SyncProtocolError.format
            }
        } else {
            try SyncProtocol.require(page.version == nil && page.sentAt == nil)
        }
        try SyncProtocol.require(page.templates.count <= SyncProtocol.maxTemplates, .limit)
        try SyncProtocol.require(page.tombstones.count <= SyncProtocol.maxTemplateTombstones, .limit)

        var seenIds = Set<UUID>()
        for item in page.templates {
            try validateItem(item, allowBaseHash: !isState)
            try SyncProtocol.require(seenIds.insert(item.id).inserted)
        }
        for tomb in page.tombstones {
            try validateTombstone(tomb)
            try SyncProtocol.require(seenIds.insert(tomb.id).inserted)
        }
    }

    public static func encode(_ message: TemplateSyncMessage) throws -> Data {
        let header: String
        let body: Data
        switch message {
        case .pull(let op):
            header = "{\"op\":\"\(op.uuidString)\",\"t\":\"tpl_pull\"}"
            body = Data()
        case .ack(let op):
            header = "{\"op\":\"\(op.uuidString)\",\"t\":\"tpl_ack\"}"
            body = Data()
        case let .push(op, part, total, page):
            try validatePage(page, part: part, total: total, isState: false)
            header = "{\"op\":\"\(op.uuidString)\",\"part\":\(part),\"t\":\"tpl_push\",\"total\":\(total)}"
            body = Data(TemplateCanonicalJson.serializePage(page, isFirstPage: part == 0, includeItemBaseHash: true).utf8)
            try SyncProtocol.require(body.count <= SyncProtocol.maxTemplatePageBodyBytes, .limit)
        case let .state(op, part, total, page):
            try validatePage(page, part: part, total: total, isState: true)
            header = "{\"op\":\"\(op.uuidString)\",\"part\":\(part),\"t\":\"tpl_state\",\"total\":\(total)}"
            body = Data(TemplateCanonicalJson.serializePage(page, isFirstPage: part == 0, includeItemBaseHash: false).utf8)
            try SyncProtocol.require(body.count <= SyncProtocol.maxTemplatePageBodyBytes, .limit)
        }
        return try SyncMessageCodec.framePlaintext(header: Data(header.utf8), body: body)
    }

    public static func decode(_ input: Data) throws -> TemplateSyncMessage {
        let (header, body) = try SyncMessageCodec.splitPlaintext(input)
        guard case let .object(root) = try TemplateStrictJson.parse(header, asciiOnly: true, maxDepth: 8) else {
            throw SyncProtocolError.format
        }
        func requireKeys(_ expected: [String]) throws {
            try SyncProtocol.require(Set(root.keys) == Set(expected))
        }
        func requireString(_ key: String) throws -> String {
            guard case let .string(value)? = root[key] else { throw SyncProtocolError.format }
            return value
        }
        func requireInteger(_ key: String) throws -> Int64 {
            guard case let .integer(value)? = root[key] else { throw SyncProtocolError.format }
            return value
        }

        let messageType = try requireString("t")
        switch messageType {
        case "tpl_pull":
            try requireKeys(["op", "t"])
            try SyncProtocol.require(body.isEmpty)
            return .pull(op: try SyncProtocol.parseId(requireString("op")))
        case "tpl_ack":
            try requireKeys(["op", "t"])
            try SyncProtocol.require(body.isEmpty)
            return .ack(op: try SyncProtocol.parseId(requireString("op")))
        case "tpl_push", "tpl_state":
            try requireKeys(["op", "part", "t", "total"])
            let op = try SyncProtocol.parseId(requireString("op"))
            let totalLong = try requireInteger("total")
            try SyncProtocol.require(totalLong >= 1)
            try SyncProtocol.require(totalLong <= Int64(SyncProtocol.maxTemplatePages), .limit)
            let partLong = try requireInteger("part")
            try SyncProtocol.require(partLong >= 0 && partLong < totalLong)
            let part = Int(partLong)
            let total = Int(totalLong)
            let isState = messageType == "tpl_state"

            try SyncProtocol.require(!body.isEmpty)
            try SyncProtocol.require(body.count <= SyncProtocol.maxTemplatePageBodyBytes, .limit)

            let page = try decodePage(body, part: part, isState: isState)
            try validatePage(page, part: part, total: total, isState: isState)
            return isState ? .state(op: op, part: part, total: total, page: page)
                           : .push(op: op, part: part, total: total, page: page)
        default:
            throw SyncProtocolError.format
        }
    }

    private static func decodePage(_ body: Data, part: Int, isState: Bool) throws -> TemplateSyncPage {
        guard case let .object(root) = try TemplateStrictJson.parse(body, asciiOnly: false, maxDepth: 8) else {
            throw SyncProtocolError.format
        }
        let expectedKeys = part == 0 ? ["sentAt", "templates", "tombstones", "v"] : ["templates", "tombstones"]
        try SyncProtocol.require(Set(root.keys) == Set(expectedKeys))

        var version: Int?
        var sentAt: Int64?
        if part == 0 {
            guard case let .integer(v)? = root["v"], v == 1,
                  case let .integer(s)? = root["sentAt"],
                  s >= -SyncProtocol.maxTimestamp && s <= SyncProtocol.maxTimestamp else {
                throw SyncProtocolError.format
            }
            version = 1
            sentAt = s
        }

        guard case let .array(templateValues)? = root["templates"],
              case let .array(tombstoneValues)? = root["tombstones"] else {
            throw SyncProtocolError.format
        }
        try SyncProtocol.require(templateValues.count <= SyncProtocol.maxTemplates, .limit)
        try SyncProtocol.require(tombstoneValues.count <= SyncProtocol.maxTemplateTombstones, .limit)

        let templates = try templateValues.map { try decodeItem($0, allowBaseHash: !isState) }
        let tombstones = try tombstoneValues.map { try decodeTombstone($0) }
        return TemplateSyncPage(version: version, sentAt: sentAt, templates: templates, tombstones: tombstones)
    }

    private static func decodeItem(_ value: TemplateStrictJson.Value, allowBaseHash: Bool) throws -> TemplateSyncItem {
        guard case let .object(obj) = value else { throw SyncProtocolError.format }
        let allowed: Set<String> = allowBaseHash
            ? ["id", "kind", "text", "order", "updatedAt", "title", "tag", "baseHash"]
            : ["id", "kind", "text", "order", "updatedAt", "title", "tag"]
        for key in obj.keys {
            try SyncProtocol.require(allowed.contains(key))
        }
        guard case let .string(idStr)? = obj["id"],
              case let .string(kindStr)? = obj["kind"],
              let kind = TemplateSyncKind(rawValue: kindStr),
              case let .string(text)? = obj["text"],
              case let .integer(orderLong)? = obj["order"],
              orderLong >= 0 && orderLong <= Int64(Int.max),
              case let .integer(updatedAt)? = obj["updatedAt"] else {
            throw SyncProtocolError.format
        }

        var title: String?
        if let titleVal = obj["title"] {
            guard case let .string(s) = titleVal else { throw SyncProtocolError.format }
            title = s
        }
        var tag: String?
        if let tagVal = obj["tag"] {
            guard case let .string(s) = tagVal else { throw SyncProtocolError.format }
            tag = s
        }
        var baseHash: String?
        if let bhVal = obj["baseHash"] {
            guard allowBaseHash, case let .string(s) = bhVal else { throw SyncProtocolError.format }
            baseHash = s
        }

        return TemplateSyncItem(
            id: try SyncProtocol.parseId(idStr),
            kind: kind,
            text: text,
            title: title,
            tag: tag,
            order: Int(orderLong),
            updatedAt: updatedAt,
            baseHash: baseHash
        )
    }

    private static func decodeTombstone(_ value: TemplateStrictJson.Value) throws -> TemplateSyncTombstone {
        guard case let .object(obj) = value else { throw SyncProtocolError.format }
        let allowed: Set<String> = ["id", "deletedAt", "baseHash"]
        for key in obj.keys {
            try SyncProtocol.require(allowed.contains(key))
        }
        guard case let .string(idStr)? = obj["id"],
              case let .integer(deletedAt)? = obj["deletedAt"] else {
            throw SyncProtocolError.format
        }
        var baseHash: String?
        if let bhVal = obj["baseHash"] {
            guard case let .string(s) = bhVal else { throw SyncProtocolError.format }
            baseHash = s
        }
        return TemplateSyncTombstone(id: try SyncProtocol.parseId(idStr), deletedAt: deletedAt, baseHash: baseHash)
    }

    public static func splitPages(op: UUID, snapshot: TemplateSyncSnapshot, isState: Bool) throws -> [TemplateSyncMessage] {
        try SyncProtocol.require(snapshot.sentAt >= -SyncProtocol.maxTimestamp && snapshot.sentAt <= SyncProtocol.maxTimestamp)
        try SyncProtocol.require(snapshot.templates.count <= SyncProtocol.maxTemplates, .limit)
        try SyncProtocol.require(snapshot.tombstones.count <= SyncProtocol.maxTemplateTombstones, .limit)

        var seenIds = Set<UUID>()
        for item in snapshot.templates {
            try validateItem(item, allowBaseHash: !isState)
            try SyncProtocol.require(seenIds.insert(item.id).inserted)
        }
        for tomb in snapshot.tombstones {
            try validateTombstone(tomb)
            try SyncProtocol.require(seenIds.insert(tomb.id).inserted)
        }

        let continuationOverhead = 28 // {"templates":[],"tombstones":[]}
        let firstHeaderBytes = "{\"sentAt\":\(snapshot.sentAt),\"templates\":[],\"tombstones\":[],\"v\":1}".utf8.count

        var pages: [TemplateSyncPage] = []
        var currentTemplates: [TemplateSyncItem] = []
        var currentTombstones: [TemplateSyncTombstone] = []
        var currentBytes = firstHeaderBytes
        var totalBodyBytes = 0

        func flushPage() throws {
            let isFirst = pages.isEmpty
            try SyncProtocol.require(pages.count < SyncProtocol.maxTemplatePages, .limit)
            totalBodyBytes += currentBytes
            try SyncProtocol.require(totalBodyBytes <= SyncProtocol.maxTemplateTotalBytes, .limit)
            pages.append(TemplateSyncPage(
                version: isFirst ? 1 : nil,
                sentAt: isFirst ? snapshot.sentAt : nil,
                templates: currentTemplates,
                tombstones: currentTombstones
            ))
            currentTemplates = []
            currentTombstones = []
            currentBytes = continuationOverhead
        }

        for item in snapshot.templates {
            let itemBytes = TemplateCanonicalJson.serializeItem(item, includeBaseHash: !isState).utf8.count
            var commaBytes = currentTemplates.isEmpty ? 0 : 1
            if currentBytes + commaBytes + itemBytes > SyncProtocol.maxTemplatePageBodyBytes {
                try SyncProtocol.require(!currentTemplates.isEmpty || !currentTombstones.isEmpty, .limit)
                try flushPage()
                commaBytes = 0
                try SyncProtocol.require(currentBytes + itemBytes <= SyncProtocol.maxTemplatePageBodyBytes, .limit)
            }
            currentTemplates.append(item)
            currentBytes += commaBytes + itemBytes
        }

        for tomb in snapshot.tombstones {
            let tombBytes = TemplateCanonicalJson.serializeTombstone(tomb).utf8.count
            var commaBytes = currentTombstones.isEmpty ? 0 : 1
            if currentBytes + commaBytes + tombBytes > SyncProtocol.maxTemplatePageBodyBytes {
                try SyncProtocol.require(!currentTemplates.isEmpty || !currentTombstones.isEmpty, .limit)
                try flushPage()
                commaBytes = 0
                try SyncProtocol.require(currentBytes + tombBytes <= SyncProtocol.maxTemplatePageBodyBytes, .limit)
            }
            currentTombstones.append(tomb)
            currentBytes += commaBytes + tombBytes
        }

        if pages.isEmpty || !currentTemplates.isEmpty || !currentTombstones.isEmpty {
            try flushPage()
        }

        let total = pages.count
        return pages.enumerated().map { index, page -> TemplateSyncMessage in
            if isState {
                return .state(op: op, part: index, total: total, page: page)
            } else {
                return .push(op: op, part: index, total: total, page: page)
            }
        }
    }
}

public final class TemplateSyncPageAssembler {
    private let expectedOp: UUID?
    private let expectedIsState: Bool?
    private var op: UUID?
    private var isState: Bool?
    private var total: Int?
    private var nextPart = 0
    private var sentAt: Int64 = 0
    private var templates: [TemplateSyncItem] = []
    private var tombstones: [TemplateSyncTombstone] = []
    private var seenIds = Set<UUID>()
    private var totalBodyBytes = 0
    private var completed = false
    private var failed = false

    public var hasPartialSnapshot: Bool { nextPart > 0 && !completed && !failed }

    public init(expectedOp: UUID? = nil, expectedIsState: Bool? = nil) {
        self.expectedOp = expectedOp
        self.expectedIsState = expectedIsState
    }

    public func append(_ message: TemplateSyncMessage) throws -> TemplateSyncSnapshot? {
        try SyncProtocol.require(!failed && !completed, .state)
        do {
            let msgOp: UUID
            let part: Int
            let msgTotal: Int
            let page: TemplateSyncPage
            let msgIsState: Bool
            switch message {
            case let .push(o, p, t, pg):
                msgOp = o; part = p; msgTotal = t; page = pg; msgIsState = false
            case let .state(o, p, t, pg):
                msgOp = o; part = p; msgTotal = t; page = pg; msgIsState = true
            case .pull, .ack:
                throw SyncProtocolError.state
            }

            try TemplateSyncMessageCodec.validatePage(page, part: part, total: msgTotal, isState: msgIsState)

            if nextPart == 0 {
                try SyncProtocol.require(part == 0, .state)
                try SyncProtocol.require(expectedOp == nil || msgOp == expectedOp!, .state)
                try SyncProtocol.require(expectedIsState == nil || msgIsState == expectedIsState!, .state)
                op = msgOp
                isState = msgIsState
                total = msgTotal
                sentAt = page.sentAt!
            } else {
                try SyncProtocol.require(msgOp == op! && msgIsState == isState! && msgTotal == total! && part == nextPart, .state)
            }

            let pageBytes = TemplateCanonicalJson.serializePage(page, isFirstPage: part == 0, includeItemBaseHash: !msgIsState).utf8.count
            try SyncProtocol.require(pageBytes <= SyncProtocol.maxTemplatePageBodyBytes, .limit)
            totalBodyBytes += pageBytes
            try SyncProtocol.require(totalBodyBytes <= SyncProtocol.maxTemplateTotalBytes, .limit)
            try SyncProtocol.require(templates.count + page.templates.count <= SyncProtocol.maxTemplates, .limit)
            try SyncProtocol.require(tombstones.count + page.tombstones.count <= SyncProtocol.maxTemplateTombstones, .limit)

            for item in page.templates {
                try SyncProtocol.require(seenIds.insert(item.id).inserted)
                templates.append(item)
            }
            for tomb in page.tombstones {
                try SyncProtocol.require(seenIds.insert(tomb.id).inserted)
                tombstones.append(tomb)
            }

            nextPart += 1
            if nextPart < total! { return nil }

            completed = true
            return TemplateSyncSnapshot(sentAt: sentAt, templates: templates, tombstones: tombstones)
        } catch {
            failed = true
            templates.removeAll()
            tombstones.removeAll()
            seenIds.removeAll()
            throw error
        }
    }

    public func finish() throws {
        try SyncProtocol.require(!failed, .state)
        failed = true
        let incomplete = nextPart > 0 && !completed
        templates.removeAll()
        tombstones.removeAll()
        seenIds.removeAll()
        try SyncProtocol.require(!incomplete, .state)
    }
}
