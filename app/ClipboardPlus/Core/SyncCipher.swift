import Foundation
import CryptoKit

/// Reference types prevent accidentally copying/resetting a counter. Call serially.
/// Create exactly one sender/receiver per direction with newly negotiated session keys.
public final class SyncFrameSender {
    private let key: SymmetricKey
    private var next: UInt64 = 0
    private var exhausted = false
    public init(key: Data) throws { self.key = SymmetricKey(data: try SyncProtocol.fixed(key, 32)) }
    public func seal(_ plaintext: Data) throws -> Data {
        try SyncProtocol.require(!exhausted, .sequence)
        try SyncProtocol.require((2...SyncProtocol.maxPlaintextBytes).contains(plaintext.count), .limit)
        let sequence = SyncProtocol.number(next)
        let aad = Data([0x10]) + sequence
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + sequence)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        if next == UInt64.max { exhausted = true } else { next += 1 }
        return aad + box.ciphertext + box.tag
    }
}

public final class SyncFrameReceiver {
    private let key: SymmetricKey
    private var last: UInt64?
    private var failed = false
    public init(key: Data) throws { self.key = SymmetricKey(data: try SyncProtocol.fixed(key, 32)) }
    public func open(_ input: Data) throws -> Data {
        try SyncProtocol.require(!failed, .state)
        do {
            try SyncProtocol.require(input.count <= SyncProtocol.maxFrameBytes, .limit)
            try SyncProtocol.require(input.count >= 27 && input.first == 0x10)
            let frame = Data(input)
            let sequence = frame.subdata(in: 1..<9).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            try SyncProtocol.require(last == nil || sequence > last!, .sequence)
            let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + frame.subdata(in: 1..<9))
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: frame.subdata(in: 9..<(frame.count - 16)), tag: Data(frame.suffix(16)))
            let plaintext: Data
            do { plaintext = try AES.GCM.open(box, using: key, authenticating: frame.prefix(9)) }
            catch { throw SyncProtocolError.authentication }
            last = sequence
            return plaintext
        } catch { failed = true; throw error }
    }
}
