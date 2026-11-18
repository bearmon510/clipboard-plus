import Foundation

enum WifiProbeSize: Int, CaseIterable, Identifiable, Equatable, Sendable {
    case mb2 = 2
    case mb10 = 10
    case mb50 = 50

    var id: Int { rawValue }
    var title: String { "\(rawValue) MB" }
    var byteCount: Int64 { Int64(rawValue) * 1024 * 1024 }
}

enum WifiProbeQRError: Error, Equatable {
    case pairingQR
    case wrongFormat
    case invalidPayload

    var message: String {
        switch self {
        case .pairingQR:
            return "これは組にする用のQRコードです。PCの「Wi-Fi 転送の試験」に出ているQRコードを読んでください。"
        case .wrongFormat:
            return "Wi-Fi転送の試験用のQRコードではありません。"
        case .invalidPayload:
            return "QRコードの内容が正しくありません。"
        }
    }
}

struct WifiProbeQR: Equatable, Sendable {
    static let prefix = "clipboardplus-wifi-probe:1:"
    static let pairingPrefix = "clipboardplus-pair:"
    private static let maxQRBytes = 1024

    let ssid: String
    let passphrase: String
    let ip: String
    let port: UInt16
    let token: String

    private struct Payload: Codable {
        let ssid: String
        let passphrase: String
        let ip: String
        let port: Int
        let token: String
    }

    init(ssid: String, passphrase: String, ip: String, port: UInt16, token: String) throws {
        guard Self.isValidText(ssid, minBytes: 1, maxBytes: 32),
              Self.isValidText(passphrase, minBytes: 8, maxBytes: 63),
              Self.isValidProbeIPv4(ip),
              port >= 1,
              Self.isValidToken(token) else {
            throw WifiProbeQRError.invalidPayload
        }
        self.ssid = ssid
        self.passphrase = passphrase
        self.ip = ip
        self.port = port
        self.token = token
    }

    func qrString() throws -> String {
        let payload = Payload(ssid: ssid, passphrase: passphrase, ip: ip, port: Int(port), token: token)
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw WifiProbeQRError.invalidPayload
        }
        return Self.prefix + json
    }

    static func parse(_ text: String) throws -> WifiProbeQR {
        guard !text.isEmpty, text.utf8.count <= maxQRBytes else {
            throw WifiProbeQRError.invalidPayload
        }
        if text.hasPrefix(pairingPrefix) {
            throw WifiProbeQRError.pairingQR
        }
        guard text.hasPrefix(prefix) else {
            throw WifiProbeQRError.wrongFormat
        }
        let jsonText = String(text.dropFirst(prefix.count))
        guard let data = jsonText.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Payload.self, from: data),
              (1...65_535).contains(raw.port) else {
            throw WifiProbeQRError.invalidPayload
        }
        return try WifiProbeQR(
            ssid: raw.ssid,
            passphrase: raw.passphrase,
            ip: raw.ip,
            port: UInt16(raw.port),
            token: raw.token
        )
    }

    private static func isValidText(_ value: String, minBytes: Int, maxBytes: Int) -> Bool {
        let count = value.utf8.count
        guard count >= minBytes, count <= maxBytes else { return false }
        return !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    private static func isValidToken(_ value: String) -> Bool {
        let count = value.utf8.count
        guard (16...128).contains(count) else { return false }
        return value.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    static func isValidProbeIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty else { return false }
            if part.count > 1, part.first == "0" { return false }
            guard part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let byte = UInt8(part) else {
                return false
            }
            octets.append(byte)
        }
        if octets == [0, 0, 0, 0] || octets[0] == 127 {
            return false
        }
        return true
    }
}

enum WifiProbeWireError: Error, Equatable {
    case invalidHeader
    case invalidSize
}

enum WifiProbeWire {
    static let magic = Data("CPW1".utf8)
    static let ackOK: UInt8 = 0x00
    static let ackAuthFailed: UInt8 = 0x01
    static let ackInvalidSize: UInt8 = 0x02
    static let maxPayloadBytes: Int64 = 64 * 1024 * 1024

    static func encodeHeader(token: String, payloadBytes: Int64) throws -> Data {
        guard payloadBytes >= 1, payloadBytes <= maxPayloadBytes else {
            throw WifiProbeWireError.invalidSize
        }
        let tokenData = Data(token.utf8)
        guard (1...256).contains(tokenData.count) else {
            throw WifiProbeWireError.invalidHeader
        }
        var data = Data()
        data.reserveCapacity(4 + 2 + tokenData.count + 8)
        data.append(magic)
        var tokenLenBE = UInt16(tokenData.count).bigEndian
        withUnsafeBytes(of: &tokenLenBE) { data.append(contentsOf: $0) }
        data.append(tokenData)
        var sizeBE = UInt64(payloadBytes).bigEndian
        withUnsafeBytes(of: &sizeBE) { data.append(contentsOf: $0) }
        return data
    }

    static func decodeHeader(_ data: Data) throws -> (token: String, payloadBytes: Int64) {
        let base = data.startIndex
        guard data.count >= 4 + 2 + 1 + 8 else { throw WifiProbeWireError.invalidHeader }
        guard data[base..<(base + 4)] == magic else { throw WifiProbeWireError.invalidHeader }

        let tokenLen = (Int(data[base + 4]) << 8) | Int(data[base + 5])
        guard (1...256).contains(tokenLen), data.count == 6 + tokenLen + 8 else {
            throw WifiProbeWireError.invalidHeader
        }
        let tokenRange = (base + 6)..<(base + 6 + tokenLen)
        guard let token = String(data: data[tokenRange], encoding: .utf8) else {
            throw WifiProbeWireError.invalidHeader
        }

        var rawSize: UInt64 = 0
        for byte in data[(base + 6 + tokenLen)..<(base + 6 + tokenLen + 8)] {
            rawSize = (rawSize << 8) | UInt64(byte)
        }
        guard rawSize >= 1, rawSize <= UInt64(maxPayloadBytes) else {
            throw WifiProbeWireError.invalidSize
        }
        return (token, Int64(rawSize))
    }

    static func rejectionMessage(status: UInt8) -> String {
        switch status {
        case ackAuthFailed:
            return "合言葉が一致しませんでした。PCに表示中のQRコードを読み直してください。"
        case ackInvalidSize:
            return "試験データの形式または大きさがPC側で受け付けられませんでした。"
        default:
            return "PC側から接続が断られました（状態コード: \(status)）。"
        }
    }
}

enum WifiProbeMetrics {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    static func speedMBPerSecond(bytes: Int64, duration: TimeInterval) -> Double? {
        guard bytes > 0, duration.isFinite, duration > 0 else { return nil }
        return Double(bytes) / (1024.0 * 1024.0) / duration
    }

    static func formatSpeed(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.2f MB/秒", locale: posixLocale, value)
    }

    static func formatDuration(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "-" }
        return String(format: "%.2f 秒", locale: posixLocale, value)
    }

    static func formatTimestamp(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "-" }
        let formatter = DateFormatter()
        formatter.locale = posixLocale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        }
        if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", locale: posixLocale, Double(bytes) / 1024.0)
        }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if bytes % (1024 * 1024) == 0 {
            return "\(bytes / (1024 * 1024)) MB"
        }
        return String(format: "%.1f MB", locale: posixLocale, mb)
    }
}

struct WifiProbeTimeline: Equatable {
    struct StageRow: Identifiable, Equatable {
        let id: String
        let label: String
        let timeText: String
        let detailText: String?
    }

    var payloadBytes: Int64 = 0
    var joinPromptedAt: Date?
    var joinedAt: Date?
    var connectedAt: Date?
    var uploadStartedAt: Date?
    var sentAt: Date?
    var receivedAt: Date?
    var restoreStartedAt: Date?
    var restoredAt: Date?

    var joinDuration: TimeInterval? { delta(from: joinPromptedAt, to: joinedAt) }
    var connectDuration: TimeInterval? { delta(from: joinedAt, to: connectedAt) }
    var uploadDuration: TimeInterval? { delta(from: uploadStartedAt ?? connectedAt, to: sentAt) }
    var downloadDuration: TimeInterval? { delta(from: sentAt, to: receivedAt) }
    var restoreDuration: TimeInterval? { delta(from: restoreStartedAt, to: restoredAt) }
    var totalDuration: TimeInterval? { delta(from: joinPromptedAt, to: restoredAt ?? receivedAt) }

    var uploadSpeedMBps: Double? {
        guard let uploadDuration else { return nil }
        return WifiProbeMetrics.speedMBPerSecond(bytes: payloadBytes, duration: uploadDuration)
    }

    var downloadSpeedMBps: Double? {
        guard let downloadDuration else { return nil }
        return WifiProbeMetrics.speedMBPerSecond(bytes: payloadBytes, duration: downloadDuration)
    }

    func rows(restoreNote: String? = nil, timeZone: TimeZone = .current) -> [StageRow] {
        let uploadDetail = uploadDuration.map {
            "\(WifiProbeMetrics.formatDuration($0)) · \(WifiProbeMetrics.formatSpeed(uploadSpeedMBps))"
        }
        let downloadDetail = downloadDuration.map {
            "\(WifiProbeMetrics.formatDuration($0)) · \(WifiProbeMetrics.formatSpeed(downloadSpeedMBps))"
        }
        let restoreDetail: String?
        if restoredAt != nil {
            let parts = [
                restoreDuration.map { "復帰 \(WifiProbeMetrics.formatDuration($0))" },
                totalDuration.map { "合計 \(WifiProbeMetrics.formatDuration($0))" },
                restoreNote
            ].compactMap { $0 }
            restoreDetail = parts.isEmpty ? nil : parts.joined(separator: " · ")
        } else {
            restoreDetail = restoreNote
        }

        return [
            StageRow(
                id: "prompt",
                label: "参加の確認を出した",
                timeText: WifiProbeMetrics.formatTimestamp(joinPromptedAt, timeZone: timeZone),
                detailText: nil
            ),
            StageRow(
                id: "joined",
                label: "参加できた",
                timeText: WifiProbeMetrics.formatTimestamp(joinedAt, timeZone: timeZone),
                detailText: joinDuration.map { "所要 \(WifiProbeMetrics.formatDuration($0))" }
            ),
            StageRow(
                id: "connected",
                label: "つながった",
                timeText: WifiProbeMetrics.formatTimestamp(connectedAt, timeZone: timeZone),
                detailText: connectDuration.map { "参加後 \(WifiProbeMetrics.formatDuration($0))" }
            ),
            StageRow(
                id: "sent",
                label: "送り終えた",
                timeText: WifiProbeMetrics.formatTimestamp(sentAt, timeZone: timeZone),
                detailText: uploadDetail
            ),
            StageRow(
                id: "received",
                label: "受け取り終えた",
                timeText: WifiProbeMetrics.formatTimestamp(receivedAt, timeZone: timeZone),
                detailText: downloadDetail
            ),
            StageRow(
                id: "restored",
                label: "元の Wi-Fi に戻った",
                timeText: WifiProbeMetrics.formatTimestamp(restoredAt, timeZone: timeZone),
                detailText: restoreDetail?.isEmpty == true ? nil : restoreDetail
            ),
        ]
    }

    private func delta(from start: Date?, to end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        let seconds = end.timeIntervalSince(start)
        return seconds >= 0 ? seconds : nil
    }
}
