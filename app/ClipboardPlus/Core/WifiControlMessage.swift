import Foundation

public enum WifiTransferDirection: String, Equatable, Sendable {
    case send
    case receive
    case both
}

public enum WifiUnavailableReason: String, Equatable, Sendable {
    case unsupported
    case busy
    case conflict
    case startFailed = "start_failed"
    case disabled
}

public enum WifiJoinStatus: String, Equatable, Sendable {
    case joined
    case userDenied = "user_denied"
    case notForeground = "not_foreground"
    case joinFailed = "join_failed"
    case timeout
}

public enum WifiCancelReason: String, Equatable, Sendable {
    case userCancelled = "user_cancelled"
    case timeout
    case tcpFailed = "tcp_failed"
    case protocolError = "protocol_error"
    case completed
    case superseded
}

public struct WifiReadyPayload: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let session: UUID
    public let ssid: String
    public let passphrase: String
    public let ip: String
    public let port: Int
    public let token: Data
    public let ttlSeconds: Int

    public init(session: UUID, ssid: String, passphrase: String, ip: String, port: Int, token: Data, ttlSeconds: Int) {
        self.session = session
        self.ssid = ssid
        self.passphrase = passphrase
        self.ip = ip
        self.port = port
        self.token = Data(token)
        self.ttlSeconds = ttlSeconds
    }

    // Never expose SSID, passphrase, IP, session, or one-time token in string formatting/logs.
    public var description: String {
        "WifiReadyPayload(port: \(port), ttlSeconds: \(ttlSeconds), redacted: true)"
    }

    public var debugDescription: String { description }
}

public enum WifiControlMessage: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case request(direction: WifiTransferDirection, ids: [UUID])
    case ready(WifiReadyPayload)
    case unavailable(reason: WifiUnavailableReason)
    case joinResult(session: UUID, status: WifiJoinStatus)
    case cancel(session: UUID, reason: WifiCancelReason)

    public var description: String {
        switch self {
        case let .request(direction, ids):
            return "WifiControlMessage.request(direction: \(direction.rawValue), count: \(ids.count))"
        case let .ready(payload):
            return "WifiControlMessage.ready(\(payload.description))"
        case let .unavailable(reason):
            return "WifiControlMessage.unavailable(reason: \(reason.rawValue))"
        case let .joinResult(_, status):
            return "WifiControlMessage.joinResult(status: \(status.rawValue))"
        case let .cancel(_, reason):
            return "WifiControlMessage.cancel(reason: \(reason.rawValue))"
        }
    }

    public var debugDescription: String { description }
}

public enum WifiControlMessageCodec {
    public static func encode(_ message: WifiControlMessage) throws -> Data {
        var sink = BoundedUtf8Sink(maxBytes: SyncProtocol.maxHeaderBytes, writeBytes: true)
        try sink.writeByte(0x7B) // {
        switch message {
        case let .request(direction, ids):
            try SyncProtocol.require(ids.count <= SyncProtocol.maxPending, .limit)
            var seen = Set<UUID>()
            for id in ids {
                try SyncProtocol.require(seen.insert(id).inserted)
            }
            try sink.writeBytes("\"direction\":".utf8)
            try sink.writeEscapedJsonString(direction.rawValue)
            try sink.writeBytes(",\"ids\":[".utf8)
            for (index, id) in ids.enumerated() {
                if index > 0 { try sink.writeByte(0x2C) }
                try sink.writeEscapedJsonString(id.uuidString)
            }
            try sink.writeBytes("],\"t\":\"wifi_request\"".utf8)

        case let .ready(ready):
            try validateReady(ready)
            let tokenHex = lowerHex(ready.token)
            try sink.writeBytes("\"ip\":".utf8)
            try sink.writeEscapedJsonString(ready.ip)
            try sink.writeBytes(",\"passphrase\":".utf8)
            try sink.writeEscapedJsonString(ready.passphrase)
            try sink.writeBytes(",\"port\":".utf8)
            try sink.writeInt64(Int64(ready.port))
            try sink.writeBytes(",\"session\":".utf8)
            try sink.writeEscapedJsonString(ready.session.uuidString)
            try sink.writeBytes(",\"ssid\":".utf8)
            try sink.writeEscapedJsonString(ready.ssid)
            try sink.writeBytes(",\"t\":\"wifi_ready\",\"token\":".utf8)
            try sink.writeEscapedJsonString(tokenHex)
            try sink.writeBytes(",\"ttl\":".utf8)
            try sink.writeInt64(Int64(ready.ttlSeconds))

        case let .unavailable(reason):
            try sink.writeBytes("\"reason\":".utf8)
            try sink.writeEscapedJsonString(reason.rawValue)
            try sink.writeBytes(",\"t\":\"wifi_unavailable\"".utf8)

        case let .joinResult(session, status):
            try sink.writeBytes("\"session\":".utf8)
            try sink.writeEscapedJsonString(session.uuidString)
            try sink.writeBytes(",\"status\":".utf8)
            try sink.writeEscapedJsonString(status.rawValue)
            try sink.writeBytes(",\"t\":\"wifi_join_result\"".utf8)

        case let .cancel(session, reason):
            try sink.writeBytes("\"reason\":".utf8)
            try sink.writeEscapedJsonString(reason.rawValue)
            try sink.writeBytes(",\"session\":".utf8)
            try sink.writeEscapedJsonString(session.uuidString)
            try sink.writeBytes(",\"t\":\"wifi_cancel\"".utf8)
        }
        try sink.writeByte(0x7D) // }
        return try SyncMessageCodec.framePlaintext(header: sink.data(), body: Data())
    }

    public static func decode(_ input: Data) throws -> WifiControlMessage {
        let (header, body) = try SyncMessageCodec.splitPlaintext(input)
        try SyncProtocol.require(body.isEmpty)
        let parsed = try TemplateStrictJson.parse(header, asciiOnly: true, maxDepth: 8)
        guard case let .object(root) = parsed else {
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
        case "wifi_request":
            try requireKeys(["direction", "ids", "t"])
            let dirRaw = try requireString("direction")
            guard let direction = WifiTransferDirection(rawValue: dirRaw) else {
                throw SyncProtocolError.format
            }
            guard case let .array(idValues)? = root["ids"] else {
                throw SyncProtocolError.format
            }
            try SyncProtocol.require(idValues.count <= SyncProtocol.maxPending, .limit)
            var ids: [UUID] = []
            ids.reserveCapacity(idValues.count)
            var seen = Set<UUID>()
            for value in idValues {
                guard case let .string(idText) = value else { throw SyncProtocolError.format }
                let parsedId = try SyncProtocol.parseId(idText)
                try SyncProtocol.require(seen.insert(parsedId).inserted)
                ids.append(parsedId)
            }
            return .request(direction: direction, ids: ids)

        case "wifi_ready":
            try requireKeys(["ip", "passphrase", "port", "session", "ssid", "t", "token", "ttl"])
            let sessionStr = try requireString("session")
            let session = try SyncProtocol.parseId(sessionStr)
            let ssid = try requireString("ssid")
            let passphrase = try requireString("passphrase")
            let ip = try requireString("ip")
            let portLong = try requireInteger("port")
            try SyncProtocol.require(portLong >= 1 && portLong <= Int64(UInt16.max))
            let tokenHex = try requireString("token")
            try SyncProtocol.require(SyncProtocol.isLowerHex64(tokenHex))
            let token = try decodeLowerHex32(tokenHex)
            let ttlLong = try requireInteger("ttl")
            try SyncProtocol.require(ttlLong >= 1 && ttlLong <= Int64(SyncProtocol.wifiMaxTtlSeconds))
            let payload = WifiReadyPayload(
                session: session,
                ssid: ssid,
                passphrase: passphrase,
                ip: ip,
                port: Int(portLong),
                token: token,
                ttlSeconds: Int(ttlLong)
            )
            try validateReady(payload)
            return .ready(payload)

        case "wifi_unavailable":
            try requireKeys(["reason", "t"])
            let reasonRaw = try requireString("reason")
            guard let reason = WifiUnavailableReason(rawValue: reasonRaw) else {
                throw SyncProtocolError.format
            }
            return .unavailable(reason: reason)

        case "wifi_join_result":
            try requireKeys(["session", "status", "t"])
            let sessionStr = try requireString("session")
            let session = try SyncProtocol.parseId(sessionStr)
            let statusRaw = try requireString("status")
            guard let status = WifiJoinStatus(rawValue: statusRaw) else {
                throw SyncProtocolError.format
            }
            return .joinResult(session: session, status: status)

        case "wifi_cancel":
            try requireKeys(["reason", "session", "t"])
            let sessionStr = try requireString("session")
            let session = try SyncProtocol.parseId(sessionStr)
            let reasonRaw = try requireString("reason")
            guard let reason = WifiCancelReason(rawValue: reasonRaw) else {
                throw SyncProtocolError.format
            }
            return .cancel(session: session, reason: reason)

        default:
            throw SyncProtocolError.format
        }
    }

    public static func validateReady(_ ready: WifiReadyPayload) throws {
        let ssidBytes = Array(ready.ssid.utf8)
        try SyncProtocol.require((1...SyncProtocol.wifiMaxSsidBytes).contains(ssidBytes.count))
        try SyncProtocol.require(ssidBytes.allSatisfy { (0x20...0x7E).contains($0) })
        try SyncProtocol.require(!ready.ssid.trimmingCharacters(in: .whitespaces).isEmpty)

        let passBytes = Array(ready.passphrase.utf8)
        try SyncProtocol.require((SyncProtocol.wifiMinPassphraseBytes...SyncProtocol.wifiMaxPassphraseBytes).contains(passBytes.count))
        try SyncProtocol.require(passBytes.allSatisfy { (0x21...0x7E).contains($0) })

        try SyncProtocol.require(isValidLocalIPv4(ready.ip))
        try SyncProtocol.require((1...Int(UInt16.max)).contains(ready.port))
        try SyncProtocol.require(ready.token.count == 32)
        try SyncProtocol.require((1...SyncProtocol.wifiMaxTtlSeconds).contains(ready.ttlSeconds))
    }

    /// Accepts canonical dotted-quad RFC 1918 private IPv4 and RFC 3927 link-local IPv4 addresses only.
    public static func isValidLocalIPv4(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var o: [UInt8] = []
        o.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty else { return false }
            if part.count > 1 && part.first == "0" { return false }
            guard part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let octet = UInt8(part) else {
                return false
            }
            o.append(octet)
        }
        if o[0] == 10 {
            let isNetwork = o[1] == 0 && o[2] == 0 && o[3] == 0
            let isBroadcast = o[1] == 255 && o[2] == 255 && o[3] == 255
            return !isNetwork && !isBroadcast
        }
        if o[0] == 172 && (16...31).contains(o[1]) {
            let isNetwork = o[1] == 16 && o[2] == 0 && o[3] == 0
            let isBroadcast = o[1] == 31 && o[2] == 255 && o[3] == 255
            return !isNetwork && !isBroadcast
        }
        if o[0] == 192 && o[1] == 168 {
            let isNetwork = o[2] == 0 && o[3] == 0
            let isBroadcast = o[2] == 255 && o[3] == 255
            return !isNetwork && !isBroadcast
        }
        // RFC 3927 Section 2.1: 169.254.0.0/24 and 169.254.255.0/24 are reserved.
        if o[0] == 169 && o[1] == 254 && (1...254).contains(o[2]) {
            return true
        }
        return false
    }

    static func lowerHex(_ data: Data) -> String {
        let digits: [UInt8] = [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 97, 98, 99, 100, 101, 102]
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func decodeLowerHex32(_ hex: String) throws -> Data {
        let bytes = Array(hex.utf8)
        try SyncProtocol.require(bytes.count == 64)
        var out = Data(capacity: 32)
        var i = 0
        while i < 64 {
            let hi = try hexNibble(bytes[i])
            let lo = try hexNibble(bytes[i + 1])
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }

    private static func hexNibble(_ b: UInt8) throws -> UInt8 {
        if (48...57).contains(b) { return b - 48 }
        if (97...102).contains(b) { return b - 87 }
        throw SyncProtocolError.format
    }
}
