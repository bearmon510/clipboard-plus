import Foundation
import CryptoKit

public enum WifiStreamDirection: UInt8, Equatable, Sendable {
    case padToPc = 0x01
    case pcToPad = 0x02
}

public struct WifiTrafficKeys: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let padToPc: Data
    public let pcToPad: Data

    init(padToPc: Data, pcToPad: Data) {
        self.padToPc = Data(padToPc)
        self.pcToPad = Data(pcToPad)
    }

    public var description: String { "WifiTrafficKeys(redacted: true)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["redacted": true], displayStyle: .struct)
    }
}

/// One-time per-transfer Wi-Fi keys derived from the BLE session's Wi-Fi base key,
/// the per-transfer 32-byte random token, and the 16-byte session UUID.
/// BLE traffic keys are never used on TCP.
public struct WifiTransferKeys: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let session: UUID
    public let transferKey: Data
    public let authKey: Data

    private init(session: UUID, transferKey: Data, authKey: Data) {
        self.session = session
        self.transferKey = transferKey
        self.authKey = authKey
    }

    public static func derive(bleKeys: SyncSessionKeys, token: Data, session: UUID) throws -> WifiTransferKeys {
        guard bleKeys.supportsWifiTransfer, let wifiBaseKey = bleKeys.wifiBaseKey else {
            throw SyncProtocolError.state
        }
        return try derive(bleWifiBaseKey: wifiBaseKey, token: token, session: session)
    }

    public static func derive(bleWifiBaseKey: Data, token: Data, session: UUID) throws -> WifiTransferKeys {
        let baseKey = try SyncProtocol.fixed(bleWifiBaseKey, 32)
        let oneTimeToken = try SyncProtocol.fixed(token, 32)
        let sessionBytes = SyncProtocol.idBytes(session)
        let ikm = SymmetricKey(data: baseKey + oneTimeToken)
        let derivedTransfer = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: sessionBytes,
            info: Data("clipboardplus wifi v1 key".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        let derivedAuth = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: derivedTransfer),
            salt: sessionBytes,
            info: Data("clipboardplus wifi v1 auth".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        return WifiTransferKeys(session: session, transferKey: derivedTransfer, authKey: derivedAuth)
    }

    func deriveTrafficKeys(padNonce: Data, pcNonce: Data) throws -> WifiTrafficKeys {
        let nPad = try SyncProtocol.fixed(padNonce, 32)
        let nPc = try SyncProtocol.fixed(pcNonce, 32)
        let salt = nPad + nPc
        let ikm = SymmetricKey(data: transferKey)
        let padToPc = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: Data("clipboardplus wifi v1 pad->pc".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        let pcToPad = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: Data("clipboardplus wifi v1 pc->pad".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        return WifiTrafficKeys(padToPc: padToPc, pcToPad: pcToPad)
    }

    public var description: String { "WifiTransferKeys(redacted: true)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["redacted": true], displayStyle: .struct)
    }
}

/// Tracks already-authenticated Wi-Fi transfer sessions so a session is consumed upon mutual authentication and cannot be replayed.
public actor WifiSessionReplayGuard {
    private let maxTracked: Int
    private var consumed: Set<UUID> = []
    private var order: [UUID] = []

    public init(maxTracked: Int = 256) throws {
        try SyncProtocol.require(maxTracked >= 1, .limit)
        self.maxTracked = maxTracked
    }

    public func isConsumed(_ session: UUID) -> Bool {
        consumed.contains(session)
    }

    public func requireNotConsumed(_ session: UUID) throws {
        try SyncProtocol.require(!consumed.contains(session), .state)
    }

    @discardableResult
    public func tryConsume(_ session: UUID) -> Bool {
        guard consumed.insert(session).inserted else { return false }
        order.append(session)
        while order.count > maxTracked {
            let evicted = order.removeFirst()
            consumed.remove(evicted)
        }
        return true
    }

    public func consumeOrThrow(_ session: UUID) throws {
        let inserted = tryConsume(session)
        try SyncProtocol.require(inserted, .state)
    }
}

enum WifiTcpHandshakeWire {
    static let magic = Data([0x43, 0x50, 0x57, 0x32]) // "CPW2"

    static func randomNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func mac(authKey: Data, label: String, session: UUID, padNonce: Data, pcNonce: Data) -> Data {
        let input = magic + Data([SyncProtocol.wifiTcpVersion]) + Data(label.utf8)
            + SyncProtocol.idBytes(session) + padNonce + pcNonce
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: authKey)))
    }

    static func verify(_ code: Data, authKey: Data, label: String, session: UUID, padNonce: Data, pcNonce: Data) throws {
        let input = magic + Data([SyncProtocol.wifiTcpVersion]) + Data(label.utf8)
            + SyncProtocol.idBytes(session) + padNonce + pcNonce
        let valid = HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: input, using: SymmetricKey(data: authKey))
        try SyncProtocol.require(valid, .authentication)
    }

    static func checkEnvelope(_ frame: Data, expectedLength: Int, expectedType: UInt8) throws {
        try SyncProtocol.require(frame.count == expectedLength)
        try SyncProtocol.require(frame.subdata(in: 0..<4) == magic)
        try SyncProtocol.require(frame[4] == SyncProtocol.wifiTcpVersion, .version)
        try SyncProtocol.require(frame[5] == expectedType)
    }
}

public struct WifiTcpPadAuthentication: Sendable, CustomReflectable {
    public let auth: Data
    public let keys: WifiTrafficKeys

    public var customMirror: Mirror {
        Mirror(self, children: ["keys": keys, "redacted": true], displayStyle: .struct)
    }
}

/// Single-use per TCP connection (iOS / client side). Nonce injection is internal and ONLY for test vectors.
public final class WifiTcpPadHandshake: CustomReflectable {
    private let transferKeys: WifiTransferKeys
    private let padNonce: Data
    private var state = 0

    public convenience init(transferKeys: WifiTransferKeys) throws {
        try self.init(transferKeys: transferKeys, testNonce: nil)
    }

    init(transferKeys: WifiTransferKeys, testNonce: Data?) throws {
        self.transferKeys = transferKeys
        let rawNonce = testNonce ?? WifiTcpHandshakeWire.randomNonce()
        self.padNonce = try SyncProtocol.fixed(rawNonce, 32)
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["state": state, "redacted": true], displayStyle: .class)
    }

    public func createHello() throws -> Data {
        let previous = state; state = -1
        try SyncProtocol.require(previous == 0, .state)
        state = 1
        return WifiTcpHandshakeWire.magic
            + Data([SyncProtocol.wifiTcpVersion, 1])
            + SyncProtocol.idBytes(transferKeys.session)
            + padNonce
    }

    public func acceptWelcome(_ input: Data) throws -> WifiTcpPadAuthentication {
        let previous = state; state = -1
        try SyncProtocol.require(previous == 1, .state)
        let frame = Data(input)
        try WifiTcpHandshakeWire.checkEnvelope(frame, expectedLength: SyncProtocol.wifiTcpWelcomeBytes, expectedType: 2)
        let peerSession = try SyncProtocol.id(frame.subdata(in: 6..<22))
        try SyncProtocol.require(peerSession == transferKeys.session, .identity)
        let pcNonce = frame.subdata(in: 22..<54)
        let pcHmac = frame.subdata(in: 54..<86)
        try WifiTcpHandshakeWire.verify(
            pcHmac,
            authKey: transferKeys.authKey,
            label: "pc",
            session: transferKeys.session,
            padNonce: padNonce,
            pcNonce: pcNonce
        )
        let padHmac = WifiTcpHandshakeWire.mac(
            authKey: transferKeys.authKey,
            label: "pad",
            session: transferKeys.session,
            padNonce: padNonce,
            pcNonce: pcNonce
        )
        let auth = WifiTcpHandshakeWire.magic + Data([SyncProtocol.wifiTcpVersion, 3]) + padHmac
        let trafficKeys = try transferKeys.deriveTrafficKeys(padNonce: padNonce, pcNonce: pcNonce)
        state = 2
        return WifiTcpPadAuthentication(auth: auth, keys: trafficKeys)
    }
}

/// Single-use per TCP connection (PC / server side). Nonce injection is internal and ONLY for test vectors.
public final class WifiTcpPcHandshake: CustomReflectable {
    private let transferKeys: WifiTransferKeys
    private let pcNonce: Data
    private var padNonce: Data?
    private var state = 0

    public var isAuthenticated: Bool { state == 2 }

    public convenience init(transferKeys: WifiTransferKeys) throws {
        try self.init(transferKeys: transferKeys, testNonce: nil)
    }

    init(transferKeys: WifiTransferKeys, testNonce: Data?) throws {
        self.transferKeys = transferKeys
        let rawNonce = testNonce ?? WifiTcpHandshakeWire.randomNonce()
        self.pcNonce = try SyncProtocol.fixed(rawNonce, 32)
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["state": state, "redacted": true], displayStyle: .class)
    }

    public func acceptHello(_ input: Data) throws -> Data {
        let previous = state; state = -1
        try SyncProtocol.require(previous == 0, .state)
        let frame = Data(input)
        try WifiTcpHandshakeWire.checkEnvelope(frame, expectedLength: SyncProtocol.wifiTcpHelloBytes, expectedType: 1)
        let peerSession = try SyncProtocol.id(frame.subdata(in: 6..<22))
        try SyncProtocol.require(peerSession == transferKeys.session, .identity)
        let clientNonce = frame.subdata(in: 22..<54)
        padNonce = clientNonce
        let pcHmac = WifiTcpHandshakeWire.mac(
            authKey: transferKeys.authKey,
            label: "pc",
            session: transferKeys.session,
            padNonce: clientNonce,
            pcNonce: pcNonce
        )
        let welcome = WifiTcpHandshakeWire.magic
            + Data([SyncProtocol.wifiTcpVersion, 2])
            + SyncProtocol.idBytes(transferKeys.session)
            + pcNonce
            + pcHmac
        state = 1
        return welcome
    }

    public func acceptAuth(_ input: Data) throws -> WifiTrafficKeys {
        let previous = state; state = -1
        try SyncProtocol.require(previous == 1, .state)
        let frame = Data(input)
        try WifiTcpHandshakeWire.checkEnvelope(frame, expectedLength: SyncProtocol.wifiTcpAuthBytes, expectedType: 3)
        guard let clientNonce = padNonce else { throw SyncProtocolError.state }
        let padHmac = frame.subdata(in: 6..<38)
        try WifiTcpHandshakeWire.verify(
            padHmac,
            authKey: transferKeys.authKey,
            label: "pad",
            session: transferKeys.session,
            padNonce: clientNonce,
            pcNonce: pcNonce
        )
        let trafficKeys = try transferKeys.deriveTrafficKeys(padNonce: clientNonce, pcNonce: pcNonce)
        state = 2
        return trafficKeys
    }
}

/// Continuous AES-256-GCM frame sealer for Wi-Fi TCP streams.
/// Wire layout (<= 256 KiB total): type(1)=0x20 | dir(1) | payloadLen(4 BE) | seq(8 BE) | ciphertext(N) | tag(16).
/// Nonce: dir(1) | 0x00, 0x00, 0x00 | seq(8 BE). AAD: first 14 bytes.
public final class WifiStreamFrameSender {
    private let key: SymmetricKey
    private let direction: UInt8
    private var next: UInt64 = 0
    private var exhausted = false

    public init(key: Data, direction: WifiStreamDirection) throws {
        let fixedKey = try SyncProtocol.fixed(key, 32)
        self.key = SymmetricKey(data: fixedKey)
        self.direction = direction.rawValue
    }

    public func seal(_ plaintext: Data) throws -> Data {
        try SyncProtocol.require(!exhausted, .sequence)
        try SyncProtocol.require(plaintext.count >= 2 && plaintext.count <= SyncProtocol.maxWifiPlaintextBytes, .limit)

        let payloadLen = UInt32(plaintext.count)
        let lenBytes = Data([
            UInt8((payloadLen >> 24) & 0xFF),
            UInt8((payloadLen >> 16) & 0xFF),
            UInt8((payloadLen >> 8) & 0xFF),
            UInt8(payloadLen & 0xFF),
        ])
        let seqBytes = SyncProtocol.number(next)
        let aad = Data([SyncProtocol.wifiFrameType, direction]) + lenBytes + seqBytes
        let nonceBytes = Data([direction, 0, 0, 0]) + seqBytes
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)

        if next == UInt64.max {
            exhausted = true
        } else {
            next += 1
        }
        return aad + box.ciphertext + box.tag
    }
}

/// Continuous AES-256-GCM frame receiver for Wi-Fi TCP streams.
/// Enforces exact consecutive sequence numbers (0, 1, 2, ...), detecting reordering, missing frames,
/// duplicates/replays, wrong direction, oversize (> 256 KiB), truncation, and tampering.
/// Any error permanently invalidates the receiver.
public final class WifiStreamFrameReceiver {
    private let key: SymmetricKey
    private let direction: UInt8
    private var expectedNext: UInt64 = 0
    private var exhausted = false
    private var failed = false

    public init(key: Data, direction: WifiStreamDirection) throws {
        let fixedKey = try SyncProtocol.fixed(key, 32)
        self.key = SymmetricKey(data: fixedKey)
        self.direction = direction.rawValue
    }

    public func parseHeader(_ input: Data) throws -> (payloadLength: Int, sequence: UInt64) {
        try SyncProtocol.require(!failed, .state)
        do {
            try SyncProtocol.require(!exhausted, .sequence)
            let header = Data(input)
            try SyncProtocol.require(header.count == SyncProtocol.wifiFrameHeaderBytes)
            try SyncProtocol.require(header[0] == SyncProtocol.wifiFrameType)
            try SyncProtocol.require(header[1] == direction, .authentication)
            let payloadLenU32: UInt32 = (UInt32(header[2]) << 24)
                | (UInt32(header[3]) << 16)
                | (UInt32(header[4]) << 8)
                | UInt32(header[5])
            try SyncProtocol.require(payloadLenU32 <= UInt32(SyncProtocol.maxWifiPlaintextBytes), .limit)
            try SyncProtocol.require(payloadLenU32 >= 2)
            var sequence: UInt64 = 0
            for idx in 6..<14 {
                sequence = (sequence << 8) | UInt64(header[idx])
            }
            try SyncProtocol.require(sequence == expectedNext, .sequence)
            return (Int(payloadLenU32), sequence)
        } catch {
            failed = true
            throw error
        }
    }

    public func open(_ input: Data) throws -> Data {
        try SyncProtocol.require(!failed, .state)
        do {
            let frame = Data(input)
            try SyncProtocol.require(frame.count <= SyncProtocol.maxWifiFrameBytes, .limit)
            try SyncProtocol.require(frame.count >= SyncProtocol.wifiFrameHeaderBytes, .packet)
            let header = frame.subdata(in: 0..<SyncProtocol.wifiFrameHeaderBytes)
            let parsed = try parseHeader(header)
            let expectedFrameLen = SyncProtocol.wifiFrameHeaderBytes + parsed.payloadLength + SyncProtocol.wifiFrameTagBytes
            try SyncProtocol.require(frame.count == expectedFrameLen, .packet)
            let bodyAndTag = frame.subdata(in: SyncProtocol.wifiFrameHeaderBytes..<frame.count)
            return try decryptVerifiedHeader(header: header, bodyAndTag: bodyAndTag, payloadLength: parsed.payloadLength)
        } catch {
            failed = true
            throw error
        }
    }

    public func open(header inputHeader: Data, bodyAndTag inputBodyAndTag: Data) throws -> Data {
        try SyncProtocol.require(!failed, .state)
        do {
            let header = Data(inputHeader)
            let bodyAndTag = Data(inputBodyAndTag)
            let parsed = try parseHeader(header)
            try SyncProtocol.require(bodyAndTag.count == parsed.payloadLength + SyncProtocol.wifiFrameTagBytes, .packet)
            return try decryptVerifiedHeader(header: header, bodyAndTag: bodyAndTag, payloadLength: parsed.payloadLength)
        } catch {
            failed = true
            throw error
        }
    }

    private func decryptVerifiedHeader(header: Data, bodyAndTag: Data, payloadLength: Int) throws -> Data {
        let seqBytes = header.subdata(in: 6..<14)
        let nonce = try AES.GCM.Nonce(data: Data([direction, 0, 0, 0]) + seqBytes)
        let ciphertext = bodyAndTag.subdata(in: 0..<payloadLength)
        let tag = bodyAndTag.subdata(in: payloadLength..<(payloadLength + SyncProtocol.wifiFrameTagBytes))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw SyncProtocolError.authentication
        }
        if expectedNext == UInt64.max {
            exhausted = true
        } else {
            expectedNext += 1
        }
        return plaintext
    }
}
