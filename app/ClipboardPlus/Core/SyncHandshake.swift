import Foundation
import CryptoKit

public struct SyncSessionKeys {
    public let padToPc: Data
    public let pcToPad: Data
    init(key: Data, ni: Data, np: Data) {
        func derive(_ direction: String) -> Data {
            let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: ni + np,
                info: Data("clipboardplus v1 \(direction)".utf8), outputByteCount: 32)
            return derived.withUnsafeBytes { Data($0) }
        }
        padToPc = derive("pad->pc"); pcToPad = derive("pc->pad")
    }
}

enum SyncHandshakeWire {
    static func randomNonce() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    static func mac(key: Data, label: String, ni: Data, np: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + ni + np, using: SymmetricKey(data: key)))
    }
    static func verify(_ code: Data, key: Data, label: String, ni: Data, np: Data) throws {
        try SyncProtocol.require(HMAC<SHA256>.isValidAuthenticationCode(code,
            authenticating: Data(label.utf8) + ni + np, using: SymmetricKey(data: key)), .authentication)
    }
    static func check(_ frame: Data, count: Int, type: UInt8) throws {
        try SyncProtocol.require(frame.count == count && frame.first == type)
        if type != 3 { try SyncProtocol.require(frame[1] == 1) }
    }
}

public struct SyncPadAuthentication {
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
    public init(pairing: SyncPairing, padId: UUID, testNonce: Data? = nil) throws {
        key = pairing.key; expectedPcId = pairing.pcId; self.padId = padId
        ni = try SyncProtocol.fixed(testNonce ?? SyncHandshakeWire.randomNonce(), 32)
    }
    public func createHello() throws -> Data {
        let previous = state; state = -1
        try SyncProtocol.require(previous == 0, .state)
        state = 1
        return Data([1, 1]) + SyncProtocol.idBytes(padId) + ni
    }
    /// Send auth before any data frame. Keys are available only after WELCOME authentication.
    public func acceptWelcome(_ input: Data) throws -> SyncPadAuthentication {
        let previous = state; state = -1
        try SyncProtocol.require(previous == 1, .state)
        let frame = Data(input)
        try SyncHandshakeWire.check(frame, count: 82, type: 2)
        try SyncProtocol.require(try SyncProtocol.id(frame.subdata(in: 2..<18)) == expectedPcId, .identity)
        let np = frame.subdata(in: 18..<50)
        try SyncHandshakeWire.verify(frame.subdata(in: 50..<82), key: key, label: "pc", ni: ni, np: np)
        let result = SyncPadAuthentication(auth: Data([3]) + SyncHandshakeWire.mac(key: key, label: "pad", ni: ni, np: np),
            keys: SyncSessionKeys(key: key, ni: ni, np: np))
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
    private var state = 0
    public private(set) var authenticatedPadId: UUID?
    public init(pairing: SyncPairing, expectedPadId: UUID? = nil, testNonce: Data? = nil) throws {
        key = pairing.key; pcId = pairing.pcId; self.expectedPadId = expectedPadId
        np = try SyncProtocol.fixed(testNonce ?? SyncHandshakeWire.randomNonce(), 32)
    }
    public func acceptHello(_ input: Data) throws -> Data {
        let previous = state; state = -1; authenticatedPadId = nil
        try SyncProtocol.require(previous == 0, .state)
        let frame = Data(input)
        try SyncHandshakeWire.check(frame, count: 50, type: 1)
        let peer = try SyncProtocol.id(frame.subdata(in: 2..<18))
        try SyncProtocol.require(expectedPadId == nil || expectedPadId == peer, .identity)
        candidatePadId = peer
        let nonce = frame.subdata(in: 18..<50); ni = nonce
        let result = Data([2, 1]) + SyncProtocol.idBytes(pcId) + np
            + SyncHandshakeWire.mac(key: key, label: "pc", ni: nonce, np: np)
        state = 1
        return result
    }
    public func acceptAuth(_ input: Data) throws -> SyncSessionKeys {
        let previous = state; state = -1; authenticatedPadId = nil
        try SyncProtocol.require(previous == 1, .state)
        let frame = Data(input)
        try SyncHandshakeWire.check(frame, count: 33, type: 3)
        try SyncHandshakeWire.verify(Data(frame.dropFirst()), key: key, label: "pad", ni: ni!, np: np)
        let result = SyncSessionKeys(key: key, ni: ni!, np: np)
        state = 2; authenticatedPadId = candidatePadId
        return result
    }
}
