import Foundation
import CryptoKit

public struct SyncSessionKeys: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let protocolVersion: UInt8
    public let padToPc: Data
    public let pcToPad: Data
    public let wifiBaseKey: Data?
    public var supportsWifiTransfer: Bool {
        protocolVersion >= SyncProtocol.wifiTransferMinVersion && wifiBaseKey != nil
    }

    init(key: Data, ni: Data, np: Data, version: UInt8) {
        self.protocolVersion = version
        let salt = ni + np
        let ikm = SymmetricKey(data: key)
        func derive(_ label: String) -> Data {
            let derived = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: ikm,
                salt: salt,
                info: Data("clipboardplus v\(version) \(label)".utf8),
                outputByteCount: 32
            )
            return derived.withUnsafeBytes { Data($0) }
        }
        padToPc = derive("pad->pc")
        pcToPad = derive("pc->pad")
        if version >= SyncProtocol.wifiTransferMinVersion {
            wifiBaseKey = derive("wifi-base")
        } else {
            wifiBaseKey = nil
        }
    }

    public var description: String {
        "SyncSessionKeys(protocolVersion: \(protocolVersion), supportsWifiTransfer: \(supportsWifiTransfer))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "protocolVersion": protocolVersion,
                "supportsWifiTransfer": supportsWifiTransfer,
                "redacted": true,
            ],
            displayStyle: .struct
        )
    }
}

enum SyncHandshakeWire {
    static func randomNonce() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    static func mac(key: Data, version: UInt8, label: String, ni: Data, np: Data, pcId: UUID, padId: UUID) -> Data {
        let input = Data([version]) + Data(label.utf8) + SyncProtocol.idBytes(pcId) + SyncProtocol.idBytes(padId) + ni + np
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: key)))
    }

    static func verify(_ code: Data, key: Data, version: UInt8, label: String, ni: Data, np: Data, pcId: UUID, padId: UUID) throws {
        let input = Data([version]) + Data(label.utf8) + SyncProtocol.idBytes(pcId) + SyncProtocol.idBytes(padId) + ni + np
        let valid = HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: input, using: SymmetricKey(data: key))
        try SyncProtocol.require(valid, .authentication)
    }

    static func isAllZero(_ data: Data) -> Bool {
        var acc: UInt8 = 0
        for byte in data {
            acc |= byte
        }
        return acc == 0
    }
}

public struct SyncPadAuthentication: Sendable {
    public let auth: Data
    public let keys: SyncSessionKeys
}

/// Single-use per connection; call serially. testNonce must never be supplied in production.
public final class SyncPadHandshake {
    private let key: Data
    private let ni: Data
    private let padId: UUID
    private let expectedPcId: UUID
    private var state = 0
    public let requestedVersion: UInt8
    /// Set when the paired PC replies to a newer HELLO with a supported legacy version mismatch frame
    /// (for example a v3 PC replying to a v4 HELLO). Callers may reconnect once using this version over BLE.
    public private(set) var suggestedFallbackVersion: UInt8?

    public init(pairing: SyncPairing, padId: UUID, testNonce: Data? = nil, protocolVersion: UInt8 = SyncProtocol.version) throws {
        try SyncProtocol.require(SyncProtocol.isSupportedVersion(protocolVersion), .version)
        self.requestedVersion = protocolVersion
        self.key = pairing.key
        self.expectedPcId = pairing.pcId
        self.padId = padId
        let rawNonce = testNonce ?? SyncHandshakeWire.randomNonce()
        self.ni = try SyncProtocol.fixed(rawNonce, 32)
    }

    public func createHello() throws -> Data {
        let previous = state; state = -1
        try SyncProtocol.require(previous == 0, .state)
        state = 1
        return Data([1, requestedVersion]) + SyncProtocol.idBytes(padId) + ni
    }

    /// Send auth before any data frame. Keys are available only after WELCOME authentication.
    public func acceptWelcome(_ input: Data) throws -> SyncPadAuthentication {
        let previous = state; state = -1
        suggestedFallbackVersion = nil
        try SyncProtocol.require(previous == 1, .state)
        let frame = Data(input)
        try SyncProtocol.require(frame.count == 82 && frame.first == 2)
        let peerPcIdBytes = frame.subdata(in: 2..<18)
        try SyncProtocol.require(peerPcIdBytes != Data(repeating: 0, count: 16), .identity)
        let peerPcId = try SyncProtocol.id(peerPcIdBytes)
        try SyncProtocol.require(peerPcId == expectedPcId, .identity)
        let peerVersion = frame[1]
        if peerVersion != requestedVersion {
            let tail = frame.subdata(in: 18..<82)
            if SyncProtocol.isSupportedVersion(peerVersion) && peerVersion < requestedVersion && SyncHandshakeWire.isAllZero(tail) {
                suggestedFallbackVersion = peerVersion
            }
            throw SyncProtocolError.version
        }
        let np = frame.subdata(in: 18..<50)
        try SyncHandshakeWire.verify(
            frame.subdata(in: 50..<82),
            key: key,
            version: requestedVersion,
            label: "pc",
            ni: ni,
            np: np,
            pcId: expectedPcId,
            padId: padId
        )
        let padMac = SyncHandshakeWire.mac(
            key: key,
            version: requestedVersion,
            label: "pad",
            ni: ni,
            np: np,
            pcId: expectedPcId,
            padId: padId
        )
        let result = SyncPadAuthentication(
            auth: Data([3]) + padMac,
            keys: SyncSessionKeys(key: key, ni: ni, np: np, version: requestedVersion)
        )
        state = 2
        return result
    }
}

public final class SyncPcHandshake {
    private let key: Data
    private let np: Data
    private let pcId: UUID
    private let expectedPadId: UUID?
    private var ni: Data?
    private var candidatePadId: UUID?
    private var candidateVersion: UInt8?
    private var state = 0
    public private(set) var authenticatedPadId: UUID?
    public private(set) var negotiatedVersion: UInt8?

    public init(pairing: SyncPairing, expectedPadId: UUID? = nil, testNonce: Data? = nil) throws {
        self.key = pairing.key
        self.pcId = pairing.pcId
        self.expectedPadId = expectedPadId
        let rawNonce = testNonce ?? SyncHandshakeWire.randomNonce()
        self.np = try SyncProtocol.fixed(rawNonce, 32)
    }

    public func createVersionMismatch() -> Data {
        Data([2, SyncProtocol.version]) + SyncProtocol.idBytes(pcId) + Data(repeating: 0, count: 64)
    }

    public func acceptHello(_ input: Data) throws -> Data {
        let previous = state; state = -1; authenticatedPadId = nil; negotiatedVersion = nil
        try SyncProtocol.require(previous == 0, .state)
        let frame = Data(input)
        try SyncProtocol.require(frame.count == 50 && frame.first == 1)
        let peerVersion = frame[1]
        try SyncProtocol.require(SyncProtocol.isSupportedVersion(peerVersion), .version)
        let peer = try SyncProtocol.id(frame.subdata(in: 2..<18))
        try SyncProtocol.require(expectedPadId == nil || expectedPadId == peer, .identity)
        candidatePadId = peer
        candidateVersion = peerVersion
        let nonce = frame.subdata(in: 18..<50)
        ni = nonce
        let pcMac = SyncHandshakeWire.mac(
            key: key,
            version: peerVersion,
            label: "pc",
            ni: nonce,
            np: np,
            pcId: pcId,
            padId: peer
        )
        let result = Data([2, peerVersion]) + SyncProtocol.idBytes(pcId) + np + pcMac
        state = 1
        return result
    }

    public func acceptAuth(_ input: Data) throws -> SyncSessionKeys {
        let previous = state; state = -1; authenticatedPadId = nil; negotiatedVersion = nil
        try SyncProtocol.require(previous == 1, .state)
        let frame = Data(input)
        try SyncProtocol.require(frame.count == 33 && frame.first == 3)
        guard let nonce = ni, let peer = candidatePadId, let version = candidateVersion else {
            throw SyncProtocolError.state
        }
        try SyncHandshakeWire.verify(
            Data(frame.dropFirst()),
            key: key,
            version: version,
            label: "pad",
            ni: nonce,
            np: np,
            pcId: pcId,
            padId: peer
        )
        let result = SyncSessionKeys(key: key, ni: nonce, np: np, version: version)
        state = 2
        authenticatedPadId = peer
        negotiatedVersion = version
        return result
    }
}
