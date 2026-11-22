import CryptoKit
import Foundation
import XCTest
@testable import ClipboardPlus

private enum PipeFaultMode: Sendable {
    case none
    case cutAfterBytes(Int)
    case flipLastByteOnWrite(Int)
    case duplicateWrite(Int)
    case swapConsecutiveWrites(firstIndex: Int)
    case dropWrite(Int)
}

private actor AsyncByteChannel {
    private let fault: PipeFaultMode
    private let recordWrites: Bool
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data, Never>?
    private var closed = false
    private var writeCount = 0
    private var writtenBytes = 0
    private var heldSwapChunk: Data?
    private var recorded: [Data] = []

    init(fault: PipeFaultMode = .none, recordWrites: Bool = false) {
        self.fault = fault
        self.recordWrites = recordWrites
    }

    func capturedWrites() -> [Data] {
        recorded
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let cont = waiter {
            waiter = nil
            cont.resume(returning: Data())
        }
    }

    func enqueue(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        if let cont = waiter {
            waiter = nil
            cont.resume(returning: chunk)
        } else {
            queue.append(chunk)
        }
    }

    func write(_ raw: Data) throws {
        if closed {
            throw SyncProtocolError.packet
        }
        writeCount += 1
        var data = Data(raw)
        if recordWrites {
            recorded.append(data)
        }

        switch fault {
        case .none:
            enqueue(data)

        case let .cutAfterBytes(limit):
            let remaining = limit - writtenBytes
            if remaining <= 0 {
                close()
                throw SyncProtocolError.packet
            }
            if data.count >= remaining {
                let prefix = Data(data.prefix(remaining))
                writtenBytes += prefix.count
                enqueue(prefix)
                close()
                return
            }
            writtenBytes += data.count
            enqueue(data)

        case let .flipLastByteOnWrite(targetIndex):
            if writeCount == targetIndex && !data.isEmpty {
                data[data.count - 1] ^= 0x01
            }
            enqueue(data)

        case let .duplicateWrite(targetIndex):
            if writeCount == targetIndex {
                enqueue(data + data)
            } else {
                enqueue(data)
            }

        case let .swapConsecutiveWrites(firstIndex):
            if writeCount == firstIndex {
                heldSwapChunk = data
            } else if writeCount == firstIndex + 1, let first = heldSwapChunk {
                heldSwapChunk = nil
                enqueue(data)
                enqueue(first)
            } else {
                enqueue(data)
            }

        case let .dropWrite(targetIndex):
            if writeCount != targetIndex {
                enqueue(data)
            }
        }
    }

    func read(maxLength: Int) async -> Data {
        if !queue.isEmpty {
            let head = queue.removeFirst()
            if head.count <= maxLength {
                return head
            }
            let prefix = Data(head.prefix(maxLength))
            let rest = Data(head.dropFirst(maxLength))
            queue.insert(rest, at: 0)
            return prefix
        }
        if closed {
            return Data()
        }
        let received = await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            self.waiter = cont
        }
        if received.count <= maxLength {
            return received
        }
        let prefix = Data(received.prefix(maxLength))
        let rest = Data(received.dropFirst(maxLength))
        queue.insert(rest, at: 0)
        return prefix
    }
}

private struct AsyncPipeEnd: WifiByteStream {
    private let incoming: AsyncByteChannel
    private let outgoing: AsyncByteChannel

    init(incoming: AsyncByteChannel, outgoing: AsyncByteChannel) {
        self.incoming = incoming
        self.outgoing = outgoing
    }

    func read(maxLength: Int) async throws -> Data {
        await incoming.read(maxLength: maxLength)
    }

    func write(_ data: Data) async throws {
        try await outgoing.write(data)
    }

    func closeWrite() async {
        await outgoing.close()
    }
}

private struct InMemoryDuplexPipe: Sendable {
    let padToPc: AsyncByteChannel
    let pcToPad: AsyncByteChannel
    let padEnd: AsyncPipeEnd
    let pcEnd: AsyncPipeEnd

    init(
        padToPcFault: PipeFaultMode = .none,
        pcToPadFault: PipeFaultMode = .none,
        recordPadWrites: Bool = false
    ) {
        let p2c = AsyncByteChannel(fault: padToPcFault, recordWrites: recordPadWrites)
        let c2p = AsyncByteChannel(fault: pcToPadFault, recordWrites: false)
        self.padToPc = p2c
        self.pcToPad = c2p
        self.padEnd = AsyncPipeEnd(incoming: c2p, outgoing: p2c)
        self.pcEnd = AsyncPipeEnd(incoming: p2c, outgoing: c2p)
    }

    func closeAll() async {
        await padToPc.close()
        await pcToPad.close()
    }
}

private struct PatternWifiTransferSource: WifiTransferSource {
    let offer: SyncOffer

    static func fillByte(at offset: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: (offset &* 17) &+ 3)
    }

    static func computePatternSha256(totalBytes: Int) -> String {
        var hasher = SHA256()
        let blockSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: blockSize)
        var offset = 0
        while offset < totalBytes {
            let count = min(blockSize, totalBytes - offset)
            for i in 0..<count {
                buffer[i] = fillByte(at: offset + i)
            }
            hasher.update(data: Data(buffer[0..<count]))
            offset += count
        }
        return WifiControlMessageCodec.lowerHex(Data(hasher.finalize()))
    }

    func readChunk(offset: Int, maxLength: Int) async throws -> Data {
        let count = min(maxLength, offer.size - offset)
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            bytes[i] = Self.fillByte(at: offset + i)
        }
        return Data(bytes)
    }
}

private actor StreamingHashWifiTransferSink: WifiTransferSink {
    private var currentOffer: SyncOffer?
    private var hasher: SHA256?
    private var written = 0
    private(set) var completedCount = 0
    private(set) var completedBytes = 0

    func beginOffer(_ offer: SyncOffer) async throws -> WifiOfferDecision {
        try offer.validate(maxSize: SyncProtocol.maxWifiItemBytes)
        currentOffer = offer
        hasher = SHA256()
        written = 0
        return .resume(offset: 0)
    }

    func appendChunk(id: UUID, offset: Int, data: Data) async throws -> Int {
        guard let offer = currentOffer, offer.id == id, offset == written, var currentHasher = hasher else {
            throw SyncProtocolError.state
        }
        currentHasher.update(data: data)
        hasher = currentHasher
        written += data.count
        return written
    }

    func verifyAndComplete(_ offer: SyncOffer) async throws {
        guard let current = currentOffer, current == offer, let currentHasher = hasher else {
            throw SyncProtocolError.state
        }
        let digestHex = WifiControlMessageCodec.lowerHex(Data(currentHasher.finalize()))
        hasher = nil
        if written != offer.size || digestHex != offer.sha256 {
            currentOffer = nil
            written = 0
            throw SyncProtocolError.authentication
        }
        completedCount += 1
        completedBytes = written
        currentOffer = nil
    }

    func discardPartial(id: UUID) async throws {
        hasher = nil
        currentOffer = nil
        written = 0
    }
}

final class WifiTransferTests: XCTestCase {
    private func vectors() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let raw = try Data(contentsOf: root.appendingPathComponent("protocol/test-vectors.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    }

    private func object(_ source: [String: Any], _ key: String) throws -> [String: Any] {
        try XCTUnwrap(source[key] as? [String: Any])
    }

    private func string(_ source: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(source[key] as? String)
    }

    private func hex(_ text: String) throws -> Data {
        let chars = Array(text.utf8)
        XCTAssertEqual(chars.count % 2, 0)
        return Data(try stride(from: 0, to: chars.count, by: 2).map {
            let slice = String(decoding: chars[$0..<($0 + 2)], as: UTF8.self)
            return try XCTUnwrap(UInt8(slice, radix: 16))
        })
    }

    private func bytes(_ source: [String: Any], _ key: String) throws -> Data {
        let text = try string(source, key)
        return try hex(text)
    }

    private func expectError(
        _ expected: SyncProtocolError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ action: () throws -> Void
    ) {
        XCTAssertThrowsError(try action(), file: file, line: line) { err in
            XCTAssertEqual(err as? SyncProtocolError, expected, file: file, line: line)
        }
    }

    private func expectAsyncError(
        _ expected: SyncProtocolError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ action: () async throws -> Void
    ) async {
        do {
            try await action()
            XCTFail("Expected SyncProtocolError.\(expected)", file: file, line: line)
        } catch let err as SyncProtocolError {
            XCTAssertEqual(err, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    private func assertRedactedReflection<T>(
        _ value: T,
        secrets: [String],
        expectedLabels: [String]? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var dumped = ""
        _ = dump(value, to: &dumped)
        for secret in secrets where !secret.isEmpty {
            XCTAssertFalse(dumped.contains(secret), file: file, line: line)
        }
        let labels = Mirror(reflecting: value).children.compactMap { $0.label }
        if let expectedLabels {
            XCTAssertEqual(labels, expectedLabels, file: file, line: line)
        }
        for forbidden in ["transferKey", "authKey", "padToPc", "pcToPad", "wifiBaseKey", "ssid", "passphrase", "ip", "token", "session", "key", "pcId", "padNonce", "pcNonce", "auth"] {
            XCTAssertFalse(labels.contains(forbidden), file: file, line: line)
        }
    }

    private func makeOffer(
        id: UUID = UUID(),
        from: String,
        data: Data,
        name: String = "sample.bin",
        kind: String = "file",
        type: String = "public.data"
    ) -> SyncOffer {
        let hashHex = WifiControlMessageCodec.lowerHex(Data(SHA256.hash(data: data)))
        return SyncOffer(
            id: id,
            at: 1_794_873_600_123,
            from: from,
            kind: kind,
            size: data.count,
            sha256: hashHex,
            name64: Data(name.utf8).base64EncodedString(),
            type: type
        )
    }

    private func makeDeterministicData(length: Int, seed: UInt8 = 0x5A) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        for i in 0..<length {
            bytes[i] = UInt8(truncatingIfNeeded: (i &* 31) &+ Int(seed))
        }
        return Data(bytes)
    }

    private func makeSessionKeys(session: UUID = UUID()) throws -> WifiTransferKeys {
        let pairing = try SyncPairing.create(name: "test-pc")
        let pad = try SyncPadHandshake(pairing: pairing, padId: UUID())
        let pc = try SyncPcHandshake(pairing: pairing)
        let hello = try pad.createHello()
        let welcome = try pc.acceptHello(hello)
        let auth = try pad.acceptWelcome(welcome)
        let pcKeys = try pc.acceptAuth(auth.auth)
        XCTAssertTrue(auth.keys.supportsWifiTransfer)
        XCTAssertTrue(pcKeys.supportsWifiTransfer)
        XCTAssertEqual(auth.keys.wifiBaseKey, pcKeys.wifiBaseKey)
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return try WifiTransferKeys.derive(bleKeys: auth.keys, token: token, session: session)
    }

    func testLimitsAndLegacyV3CompatibilityMatchIndependentVectors() throws {
        let v = try vectors()
        let h = try object(v, "handshake")
        let limits = try object(v, "limits")
        let pairingQR = try string(try object(v, "pairing"), "qr")
        let pairing = try SyncPairing.parse(pairingQR)

        XCTAssertEqual(v["version"] as? Int, Int(SyncProtocol.version))
        XCTAssertEqual(v["minSupportedVersion"] as? Int, Int(SyncProtocol.minSupportedVersion))
        XCTAssertEqual(v["wifiTransferMinVersion"] as? Int, Int(SyncProtocol.wifiTransferMinVersion))
        XCTAssertEqual(limits["maxWifiItemBytes"] as? Int, SyncProtocol.maxWifiItemBytes)
        XCTAssertEqual(limits["defaultWifiThresholdBytes"] as? Int, SyncProtocol.defaultWifiThresholdBytes)
        XCTAssertEqual(limits["maxWifiFrameBytes"] as? Int, SyncProtocol.maxWifiFrameBytes)
        XCTAssertEqual(limits["maxWifiPlaintextBytes"] as? Int, SyncProtocol.maxWifiPlaintextBytes)
        XCTAssertEqual(limits["maxWifiChunkBytes"] as? Int, SyncProtocol.maxWifiChunkBytes)
        XCTAssertEqual(limits["wifiDefaultTtlSeconds"] as? Int, SyncProtocol.wifiDefaultTtlSeconds)
        XCTAssertEqual(limits["wifiMaxTtlSeconds"] as? Int, SyncProtocol.wifiMaxTtlSeconds)
        XCTAssertEqual(limits["wifiMinPassphraseBytes"] as? Int, SyncProtocol.wifiMinPassphraseBytes)
        XCTAssertEqual(limits["wifiMaxPassphraseBytes"] as? Int, SyncProtocol.wifiMaxPassphraseBytes)
        XCTAssertEqual(limits["wifiMaxSsidBytes"] as? Int, SyncProtocol.wifiMaxSsidBytes)
        XCTAssertEqual(limits["wifiTcpVersion"] as? Int, Int(SyncProtocol.wifiTcpVersion))

        let padId = try XCTUnwrap(UUID(uuidString: try string(h, "padId")))
        let ni = try bytes(h, "niHex")
        let np = try bytes(h, "npHex")
        let expectedWifiBase = try bytes(h, "wifiBaseKeyHex")

        // v4 handshake derives wifiBaseKey and supports Wi-Fi.
        let padV4 = try SyncPadHandshake(pairing: pairing, padId: padId, testNonce: ni)
        let pcV4 = try SyncPcHandshake(pairing: pairing, expectedPadId: padId, testNonce: np)
        let helloV4 = try padV4.createHello()
        let welcomeV4 = try pcV4.acceptHello(helloV4)
        let authV4 = try padV4.acceptWelcome(welcomeV4)
        let pcKeysV4 = try pcV4.acceptAuth(authV4.auth)
        XCTAssertEqual(pcV4.negotiatedVersion, 4)
        XCTAssertEqual(authV4.keys.wifiBaseKey, expectedWifiBase)
        XCTAssertEqual(pcKeysV4.wifiBaseKey, expectedWifiBase)
        XCTAssertTrue(authV4.keys.supportsWifiTransfer)
        XCTAssertTrue(pcKeysV4.supportsWifiTransfer)
        assertRedactedReflection(
            pairing,
            secrets: [pairing.pcId.uuidString, WifiControlMessageCodec.lowerHex(pairing.key)],
            expectedLabels: ["name", "redacted"]
        )
        assertRedactedReflection(
            authV4.keys,
            secrets: [
                WifiControlMessageCodec.lowerHex(authV4.keys.padToPc),
                WifiControlMessageCodec.lowerHex(authV4.keys.pcToPad),
                WifiControlMessageCodec.lowerHex(expectedWifiBase),
            ],
            expectedLabels: ["protocolVersion", "supportsWifiTransfer", "redacted"]
        )

        // Old v3 Pad talking to v4 PC negotiates v3 cleanly without Wi-Fi.
        let legacy = try object(v, "legacyV3Handshake")
        let padV3 = try SyncPadHandshake(pairing: pairing, padId: padId, testNonce: ni, protocolVersion: 3)
        let pcAcceptV3 = try SyncPcHandshake(pairing: pairing, expectedPadId: padId, testNonce: np)
        let v3Hello = try padV3.createHello()
        let expectedV3Hello = try bytes(legacy, "helloHex")
        XCTAssertEqual(v3Hello, expectedV3Hello)
        let v3Welcome = try pcAcceptV3.acceptHello(v3Hello)
        let expectedV3Welcome = try bytes(legacy, "welcomeHex")
        XCTAssertEqual(v3Welcome, expectedV3Welcome)
        let v3Auth = try padV3.acceptWelcome(v3Welcome)
        let expectedV3Auth = try bytes(legacy, "authHex")
        XCTAssertEqual(v3Auth.auth, expectedV3Auth)
        let pcV3Keys = try pcAcceptV3.acceptAuth(v3Auth.auth)
        XCTAssertEqual(pcAcceptV3.negotiatedVersion, 3)

        let expectedV3PadToPc = try bytes(legacy, "padToPcKeyHex")
        let expectedV3PcToPad = try bytes(legacy, "pcToPadKeyHex")
        for keys in [v3Auth.keys, pcV3Keys] {
            XCTAssertEqual(keys.protocolVersion, 3)
            XCTAssertFalse(keys.supportsWifiTransfer)
            XCTAssertNil(keys.wifiBaseKey)
            XCTAssertEqual(keys.padToPc, expectedV3PadToPc)
            XCTAssertEqual(keys.pcToPad, expectedV3PcToPad)
            expectError(.state) {
                _ = try WifiTransferKeys.derive(bleKeys: keys, token: Data(repeating: 1, count: 32), session: UUID())
            }
        }

        // v4 Pad talking to an unmodified v3 PC detects suggestedFallbackVersion == 3.
        let probePad = try SyncPadHandshake(pairing: pairing, padId: padId, testNonce: ni)
        _ = try probePad.createHello()
        let v3Mismatch = try bytes(legacy, "v3PcMismatchForV4HelloHex")
        expectError(.version) { _ = try probePad.acceptWelcome(v3Mismatch) }
        XCTAssertEqual(probePad.suggestedFallbackVersion, 3)

        // Unsupported v2 mismatch from same PC must NOT suggest a fallback version.
        let failures = try object(v, "failures")
        let v2Mismatch = try bytes(try object(failures, "versionMismatchSamePc"), "frameHex")
        let v2Pad = try SyncPadHandshake(pairing: pairing, padId: padId, testNonce: ni)
        _ = try v2Pad.createHello()
        expectError(.version) { _ = try v2Pad.acceptWelcome(v2Mismatch) }
        XCTAssertNil(v2Pad.suggestedFallbackVersion)
    }

    func testWifiControlMessagesFramesAndFailuresMatchIndependentVectors() throws {
        let v = try vectors()
        let h = try object(v, "handshake")
        let controlMessages = try object(v, "wifiControlMessages")

        for raw in controlMessages.values {
            let fixture = try XCTUnwrap(raw as? [String: Any])
            let plaintext = try bytes(fixture, "plaintextHex")
            let decoded = try WifiControlMessageCodec.decode(plaintext)
            let reencoded = try WifiControlMessageCodec.encode(decoded)
            XCTAssertEqual(reencoded, plaintext)
            let headerLen = (Int(plaintext[0]) << 8) | Int(plaintext[1])
            let headerStr = String(data: plaintext.subdata(in: 2..<(2 + headerLen)), encoding: .utf8)
            let expectedHeader = try string(fixture, "headerJson")
            XCTAssertEqual(headerStr, expectedHeader)

            if case let .ready(ready) = decoded {
                let desc = ready.description
                XCTAssertFalse(desc.contains(ready.ssid))
                XCTAssertFalse(desc.contains(ready.passphrase))
                XCTAssertFalse(desc.contains(ready.ip))
                XCTAssertFalse(desc.contains(WifiControlMessageCodec.lowerHex(ready.token)))
                XCTAssertFalse(desc.contains(ready.session.uuidString))
                let secrets = [
                    ready.ssid,
                    ready.passphrase,
                    ready.ip,
                    WifiControlMessageCodec.lowerHex(ready.token),
                    ready.session.uuidString,
                ]
                assertRedactedReflection(ready, secrets: secrets, expectedLabels: ["port", "ttlSeconds", "redacted"])
                assertRedactedReflection(decoded, secrets: secrets, expectedLabels: ["ready"])
            } else if case let .joinResult(joinSession, _) = decoded {
                assertRedactedReflection(decoded, secrets: [joinSession.uuidString], expectedLabels: ["status"])
            } else if case let .cancel(cancelSession, _) = decoded {
                assertRedactedReflection(decoded, secrets: [cancelSession.uuidString], expectedLabels: ["reason"])
            }
        }

        let controlFrames = try XCTUnwrap(v["wifiControlFrames"] as? [[String: Any]])
        for direction in ["pad->pc", "pc->pad"] {
            let key = try bytes(h, direction == "pad->pc" ? "padToPcKeyHex" : "pcToPadKeyHex")
            let sender = try SyncFrameSender(key: key)
            let receiver = try SyncFrameReceiver(key: key)
            for f in controlFrames where f["direction"] as? String == direction {
                let msgName = try string(f, "message")
                let plaintext = try bytes(try object(controlMessages, msgName), "plaintextHex")
                let expected = try bytes(f, "frameHex")
                let sealed = try sender.seal(plaintext)
                let opened = try receiver.open(expected)
                XCTAssertEqual(sealed, expected)
                XCTAssertEqual(opened, plaintext)
            }
        }

        let controlFailures = try object(v, "wifiControlFailures")
        for raw in controlFailures.values {
            let fixture = try XCTUnwrap(raw as? [String: Any])
            let errText = try string(fixture, "error")
            let expected: SyncProtocolError = errText == "limit" ? .limit : .format
            let data = try bytes(fixture, "plaintextHex")
            expectError(expected) { _ = try WifiControlMessageCodec.decode(data) }
        }

        for ip in ["192.168.137.1", "10.0.0.1", "172.16.0.1", "172.31.255.254", "169.254.1.1", "169.254.254.254"] {
            XCTAssertTrue(WifiControlMessageCodec.isValidLocalIPv4(ip))
        }
        for badIp in ["", "0.0.0.0", "127.0.0.1", "8.8.8.8", "172.15.0.1", "172.32.0.1", "169.254.0.1", "169.254.255.1", "192.168.0.0", "192.168.255.255", "192.168.01.1", "255.255.255.255"] {
            XCTAssertFalse(WifiControlMessageCodec.isValidLocalIPv4(badIp))
        }

        let tooManyIds = (0..<(SyncProtocol.maxPending + 1)).map { _ in UUID() }
        expectError(.limit) { _ = try WifiControlMessageCodec.encode(.request(direction: .send, ids: tooManyIds)) }
    }

    func testWifiKeyDerivationTcpHandshakeStreamMessagesFramesAndFailuresMatchVectors() throws {
        let v = try vectors()
        let h = try object(v, "handshake")
        let w = try object(v, "wifiTransfer")

        let session = try XCTUnwrap(UUID(uuidString: try string(w, "session")))
        let bleBase = try bytes(w, "bleWifiBaseKeyHex")
        let token = try bytes(w, "tokenHex")
        let transferKeys = try WifiTransferKeys.derive(bleWifiBaseKey: bleBase, token: token, session: session)

        let expectedTransferKey = try bytes(w, "transferKeyHex")
        let expectedAuthKey = try bytes(w, "authKeyHex")
        let blePadToPcKey = try bytes(h, "padToPcKeyHex")
        let blePcToPadKey = try bytes(h, "pcToPadKeyHex")
        XCTAssertEqual(transferKeys.transferKey, expectedTransferKey)
        XCTAssertEqual(transferKeys.authKey, expectedAuthKey)
        XCTAssertNotEqual(transferKeys.transferKey, blePadToPcKey)
        XCTAssertNotEqual(transferKeys.transferKey, blePcToPadKey)
        XCTAssertNotEqual(transferKeys.transferKey, bleBase)
        XCTAssertNotEqual(transferKeys.transferKey, transferKeys.authKey)
        XCTAssertFalse(transferKeys.description.contains(WifiControlMessageCodec.lowerHex(transferKeys.transferKey)))
        XCTAssertFalse(transferKeys.description.contains(WifiControlMessageCodec.lowerHex(transferKeys.authKey)))
        assertRedactedReflection(
            transferKeys,
            secrets: [
                session.uuidString,
                WifiControlMessageCodec.lowerHex(transferKeys.transferKey),
                WifiControlMessageCodec.lowerHex(transferKeys.authKey),
            ],
            expectedLabels: ["redacted"]
        )

        let padNonce = try bytes(w, "padNonceHex")
        let pcNonce = try bytes(w, "pcNonceHex")
        let padHs = try WifiTcpPadHandshake(transferKeys: transferKeys, testNonce: padNonce)
        let pcHs = try WifiTcpPcHandshake(transferKeys: transferKeys, testNonce: pcNonce)
        assertRedactedReflection(padHs, secrets: [session.uuidString], expectedLabels: ["state", "redacted"])
        assertRedactedReflection(pcHs, secrets: [session.uuidString], expectedLabels: ["state", "redacted"])

        let tcpHello = try padHs.createHello()
        let expectedTcpHello = try bytes(w, "tcpHelloHex")
        XCTAssertEqual(tcpHello, expectedTcpHello)
        let tcpWelcome = try pcHs.acceptHello(tcpHello)
        let expectedTcpWelcome = try bytes(w, "tcpWelcomeHex")
        let expectedPcHmac = try bytes(w, "pcHmacHex")
        XCTAssertEqual(tcpWelcome, expectedTcpWelcome)
        XCTAssertEqual(Data(tcpWelcome.suffix(32)), expectedPcHmac)
        let padAuth = try padHs.acceptWelcome(tcpWelcome)
        let expectedTcpAuth = try bytes(w, "tcpAuthHex")
        let expectedPadHmac = try bytes(w, "padHmacHex")
        XCTAssertEqual(padAuth.auth, expectedTcpAuth)
        XCTAssertEqual(Data(padAuth.auth.suffix(32)), expectedPadHmac)
        let pcTraffic = try pcHs.acceptAuth(padAuth.auth)
        XCTAssertTrue(pcHs.isAuthenticated)
        assertRedactedReflection(
            padAuth,
            secrets: [
                WifiControlMessageCodec.lowerHex(padAuth.keys.padToPc),
                WifiControlMessageCodec.lowerHex(padAuth.keys.pcToPad),
            ],
            expectedLabels: ["keys", "redacted"]
        )

        let expectedPadToPc = try bytes(w, "padToPcKeyHex")
        let expectedPcToPad = try bytes(w, "pcToPadKeyHex")
        for tk in [padAuth.keys, pcTraffic] {
            XCTAssertEqual(tk.padToPc, expectedPadToPc)
            XCTAssertEqual(tk.pcToPad, expectedPcToPad)
            XCTAssertNotEqual(tk.padToPc, tk.pcToPad)
            XCTAssertFalse(tk.description.contains(WifiControlMessageCodec.lowerHex(tk.padToPc)))
            assertRedactedReflection(
                tk,
                secrets: [
                    WifiControlMessageCodec.lowerHex(tk.padToPc),
                    WifiControlMessageCodec.lowerHex(tk.pcToPad),
                ],
                expectedLabels: ["redacted"]
            )
        }

        expectError(.state) { _ = try padHs.createHello() }
        expectError(.state) { _ = try padHs.acceptWelcome(tcpWelcome) }
        expectError(.state) { _ = try pcHs.acceptAuth(padAuth.auth) }

        let streamMessages = try object(w, "streamMessages")
        for raw in streamMessages.values {
            let fixture = try XCTUnwrap(raw as? [String: Any])
            let plaintext = try bytes(fixture, "plaintextHex")
            let decoded = try WifiStreamMessageCodec.decode(plaintext)
            let reencoded = try WifiStreamMessageCodec.encode(decoded)
            XCTAssertEqual(reencoded, plaintext)
            let headerLen = (Int(plaintext[0]) << 8) | Int(plaintext[1])
            let headerStr = String(data: plaintext.subdata(in: 2..<(2 + headerLen)), encoding: .utf8)
            let expectedHeader = try string(fixture, "headerJson")
            XCTAssertEqual(headerStr, expectedHeader)
        }

        let streamFrames = try XCTUnwrap(w["streamFrames"] as? [[String: Any]])
        for direction in ["pad->pc", "pc->pad"] {
            let dirEnum: WifiStreamDirection = direction == "pad->pc" ? .padToPc : .pcToPad
            let key = direction == "pad->pc" ? expectedPadToPc : expectedPcToPad
            let sender = try WifiStreamFrameSender(key: key, direction: dirEnum)
            let receiver = try WifiStreamFrameReceiver(key: key, direction: dirEnum)
            for f in streamFrames where f["direction"] as? String == direction {
                let msgName = try string(f, "message")
                let plaintext = try bytes(try object(streamMessages, msgName), "plaintextHex")
                let expected = try bytes(f, "frameHex")
                let expectedAad = try bytes(f, "aadHex")
                let expectedTag = try bytes(f, "tagHex")
                let sealed = try sender.seal(plaintext)
                let opened = try receiver.open(expected)
                XCTAssertEqual(sealed, expected)
                XCTAssertEqual(opened, plaintext)
                XCTAssertEqual(Data(expected.prefix(14)), expectedAad)
                XCTAssertEqual(Data(expected.suffix(16)), expectedTag)
            }
        }

        let failures = try object(w, "failures")
        let rxTampered = try WifiStreamFrameReceiver(key: expectedPadToPc, direction: .padToPc)
        let tamperedTag = try bytes(try object(failures, "tamperedTag"), "frameHex")
        let validFrame0 = try bytes(streamFrames[0], "frameHex")
        expectError(.authentication) { _ = try rxTampered.open(tamperedTag) }
        expectError(.state) { _ = try rxTampered.open(validFrame0) }

        let tamperedCt = try bytes(try object(failures, "tamperedCiphertext"), "frameHex")
        expectError(.authentication) { _ = try WifiStreamFrameReceiver(key: expectedPadToPc, direction: .padToPc).open(tamperedCt) }
        let wrongDir = try bytes(try object(failures, "wrongDirection"), "frameHex")
        expectError(.authentication) { _ = try WifiStreamFrameReceiver(key: expectedPadToPc, direction: .padToPc).open(wrongDir) }
        let truncated = try bytes(try object(failures, "truncatedFrame"), "frameHex")
        expectError(.packet) { _ = try WifiStreamFrameReceiver(key: expectedPadToPc, direction: .padToPc).open(truncated) }

        let reorderedHex = try XCTUnwrap((try object(failures, "reordered"))["framesHex"] as? [String])
        let rxReorder = try WifiStreamFrameReceiver(key: expectedPadToPc, direction: .padToPc)
        _ = try rxReorder.open(try hex(reorderedHex[0]))
        let reorderFrame2 = try hex(reorderedHex[1])
        expectError(.sequence) { _ = try rxReorder.open(reorderFrame2) }

        let dupHex = try XCTUnwrap((try object(failures, "duplicate"))["framesHex"] as? [String])
        let rxDup = try WifiStreamFrameReceiver(key: expectedPadToPc, direction: .padToPc)
        _ = try rxDup.open(try hex(dupHex[0]))
        let dupFrame = try hex(dupHex[1])
        expectError(.sequence) { _ = try rxDup.open(dupFrame) }

        let badWelcome = try bytes(try object(failures, "wrongTcpWelcomeHmac"), "frameHex")
        let badWelcomePad = try WifiTcpPadHandshake(transferKeys: transferKeys, testNonce: padNonce)
        _ = try badWelcomePad.createHello()
        expectError(.authentication) { _ = try badWelcomePad.acceptWelcome(badWelcome) }

        let badAuth = try bytes(try object(failures, "wrongTcpAuthHmac"), "frameHex")
        let badAuthPc = try WifiTcpPcHandshake(transferKeys: transferKeys, testNonce: pcNonce)
        _ = try badAuthPc.acceptHello(tcpHello)
        expectError(.authentication) { _ = try badAuthPc.acceptAuth(badAuth) }

        let wrongSession = try bytes(try object(failures, "wrongTcpSession"), "frameHex")
        expectError(.identity) { _ = try WifiTcpPcHandshake(transferKeys: transferKeys, testNonce: pcNonce).acceptHello(wrongSession) }

        let wrongVer = try bytes(try object(failures, "wrongTcpVersion"), "frameHex")
        expectError(.version) { _ = try WifiTcpPcHandshake(transferKeys: transferKeys, testNonce: pcNonce).acceptHello(wrongVer) }

        let overOfferPlain = try bytes(try object(failures, "oversizedWifiOffer"), "plaintextHex")
        expectError(.limit) { _ = try WifiStreamMessageCodec.decode(overOfferPlain) }

        let overChunkBytes = try XCTUnwrap((try object(failures, "oversizedWifiChunk"))["chunkBytes"] as? Int)
        expectError(.limit) { _ = try WifiStreamMessageCodec.encode(.chunk(id: UUID(), offset: 0, data: Data(count: overChunkBytes))) }

        expectError(.limit) {
            _ = try WifiStreamFrameSender(key: expectedPadToPc, direction: .padToPc)
                .seal(Data(count: SyncProtocol.maxWifiPlaintextBytes + 1))
        }
        expectError(.limit) {
            _ = try WifiStreamFrameReceiver(key: expectedPadToPc, direction: .padToPc)
                .open(Data(count: SyncProtocol.maxWifiFrameBytes + 1))
        }
    }

    func testInMemoryPipeNormalBidirectionalMultiItemAndEmptyTransfer() async throws {
        let keys = try makeSessionKeys()
        let replayGuard = try WifiSessionReplayGuard()
        let pipe = InMemoryDuplexPipe()

        let padFile1 = makeDeterministicData(length: 700_000, seed: 1)
        let padFile2 = Data()
        let pcFile1 = makeDeterministicData(length: 600_000, seed: 2)

        let padOffer1 = makeOffer(from: "pad", data: padFile1, name: "photo.png", kind: "image", type: "public.png")
        let padOffer2 = makeOffer(from: "pad", data: padFile2, name: "empty.txt", kind: "file", type: "public.data")
        let pcOffer1 = makeOffer(from: "pc", data: pcFile1, name: "report.pdf", kind: "file", type: "com.adobe.pdf")

        let pcSink = InMemoryWifiTransferSink()
        let padSink = InMemoryWifiTransferSink()

        let padOutgoing: [any WifiTransferSource] = [
            InMemoryWifiTransferSource(offer: padOffer1, payload: padFile1),
            InMemoryWifiTransferSource(offer: padOffer2, payload: padFile2),
        ]
        let pcOutgoing: [any WifiTransferSource] = [
            InMemoryWifiTransferSource(offer: pcOffer1, payload: pcFile1),
        ]

        async let padRun = WifiTransferEngine.runPadSession(stream: pipe.padEnd, keys: keys, outgoing: padOutgoing, sink: padSink)
        async let pcRun = WifiTransferEngine.runPcSession(stream: pipe.pcEnd, keys: keys, outgoing: pcOutgoing, sink: pcSink, replayGuard: replayGuard)
        let (padResult, pcResult) = try await (padRun, pcRun)

        XCTAssertEqual(padResult.sent.count, 2)
        XCTAssertEqual(padResult.sent[0].transferredBytes, padFile1.count)
        XCTAssertEqual(padResult.sent[1].transferredBytes, 0)
        XCTAssertEqual(padResult.received.count, 1)
        let padReceivedData = await padSink.completedData(for: pcOffer1.id)
        XCTAssertEqual(padReceivedData, pcFile1)

        XCTAssertEqual(pcResult.received.count, 2)
        let pcReceived1 = await pcSink.completedData(for: padOffer1.id)
        let pcReceived2 = await pcSink.completedData(for: padOffer2.id)
        XCTAssertEqual(pcReceived1, padFile1)
        XCTAssertEqual(pcReceived2, padFile2)
        XCTAssertEqual(pcResult.sent.count, 1)
        let consumed = await replayGuard.isConsumed(keys.session)
        XCTAssertTrue(consumed)
    }

    func testInMemoryPipeDisconnectMidTransferResumesFromSavedOffset() async throws {
        let payload = makeDeterministicData(length: 800_000, seed: 9)
        let offer = makeOffer(from: "pad", data: payload, name: "big.bin")
        let pcSink = InMemoryWifiTransferSink()
        let padSink = InMemoryWifiTransferSink()

        // Session 1: cut mid-transfer after 300 KB.
        let replayGuard = try WifiSessionReplayGuard()
        let keys1 = try makeSessionKeys()
        let brokenPipe = InMemoryDuplexPipe(padToPcFault: .cutAfterBytes(300_000))
        let padTask1 = Task {
            try await WifiTransferEngine.runPadSession(
                stream: brokenPipe.padEnd,
                keys: keys1,
                outgoing: [InMemoryWifiTransferSource(offer: offer, payload: payload)],
                sink: padSink,
                chunkSize: 128 * 1024
            )
        }
        let pcTask1 = Task {
            try await WifiTransferEngine.runPcSession(
                stream: brokenPipe.pcEnd,
                keys: keys1,
                outgoing: [],
                sink: pcSink,
                replayGuard: replayGuard
            )
        }

        await expectAsyncError(.packet) { _ = try await pcTask1.value }
        await brokenPipe.closeAll()
        do { _ = try await padTask1.value } catch {}

        // Mutual auth succeeded before truncation, so keys1.session is consumed and must be re-negotiated via wifi_ready.
        let consumedAfterCut = await replayGuard.isConsumed(keys1.session)
        XCTAssertTrue(consumedAfterCut)
        let replayCutPipe = InMemoryDuplexPipe()
        let replayCutPad = Task {
            try await WifiTransferEngine.runPadSession(
                stream: replayCutPipe.padEnd,
                keys: keys1,
                outgoing: [InMemoryWifiTransferSource(offer: offer, payload: payload)],
                sink: padSink
            )
        }
        let replayCutPc = Task {
            try await WifiTransferEngine.runPcSession(
                stream: replayCutPipe.pcEnd,
                keys: keys1,
                outgoing: [],
                sink: pcSink,
                replayGuard: replayGuard
            )
        }
        await expectAsyncError(.state) { _ = try await replayCutPc.value }
        await replayCutPipe.closeAll()
        do { _ = try await replayCutPad.value } catch {}

        let hasPartial = await pcSink.hasPartial(for: offer.id)
        let savedOffset = await pcSink.partialLength(for: offer.id)
        XCTAssertTrue(hasPartial)
        XCTAssertGreaterThanOrEqual(savedOffset, 128 * 1024)
        XCTAssertLessThan(savedOffset, payload.count)
        let completedBefore = await pcSink.completedData(for: offer.id)
        XCTAssertNil(completedBefore)

        // Session 2: fresh keys, same offer -> resumes from savedOffset.
        let keys2 = try makeSessionKeys()
        let resumePipe = InMemoryDuplexPipe()
        async let padRun2 = WifiTransferEngine.runPadSession(
            stream: resumePipe.padEnd,
            keys: keys2,
            outgoing: [InMemoryWifiTransferSource(offer: offer, payload: payload)],
            sink: padSink,
            chunkSize: 128 * 1024
        )
        async let pcRun2 = WifiTransferEngine.runPcSession(
            stream: resumePipe.pcEnd,
            keys: keys2,
            outgoing: [],
            sink: pcSink,
            replayGuard: replayGuard
        )
        let (padResult2, _) = try await (padRun2, pcRun2)
        XCTAssertEqual(padResult2.sent.count, 1)
        XCTAssertEqual(padResult2.sent[0].transferredBytes, payload.count - savedOffset)
        let hasPartialAfter = await pcSink.hasPartial(for: offer.id)
        XCTAssertFalse(hasPartialAfter)
        let completedAfter = await pcSink.completedData(for: offer.id)
        XCTAssertEqual(completedAfter, payload)
    }

    func testInMemoryPipeFullPartialResumesWithImmediateAck() async throws {
        let payload = makeDeterministicData(length: 60_000, seed: 11)
        let offer = makeOffer(from: "pad", data: payload, name: "resume-full.bin")
        let pcSink = InMemoryWifiTransferSink()
        _ = try await pcSink.beginOffer(offer)
        _ = try await pcSink.appendChunk(id: offer.id, offset: 0, data: payload)

        let keys = try makeSessionKeys()
        let replayGuard = try WifiSessionReplayGuard()
        let pipe = InMemoryDuplexPipe()
        async let padRun = WifiTransferEngine.runPadSession(
            stream: pipe.padEnd,
            keys: keys,
            outgoing: [InMemoryWifiTransferSource(offer: offer, payload: payload)],
            sink: InMemoryWifiTransferSink()
        )
        async let pcRun = WifiTransferEngine.runPcSession(
            stream: pipe.pcEnd,
            keys: keys,
            outgoing: [],
            sink: pcSink,
            replayGuard: replayGuard
        )
        let (padResult, _) = try await (padRun, pcRun)
        XCTAssertEqual(padResult.sent.count, 1)
        XCTAssertEqual(padResult.sent[0].transferredBytes, 0)
        let completedData = await pcSink.completedData(for: offer.id)
        XCTAssertEqual(completedData, payload)
        let hasPartial = await pcSink.hasPartial(for: offer.id)
        XCTAssertFalse(hasPartial)
    }

    func testInMemoryPipeTamperingOnWireRejectedWithAuthentication() async throws {
        let keys = try makeSessionKeys()
        let replayGuard = try WifiSessionReplayGuard()
        let payload = makeDeterministicData(length: 10_000, seed: 3)
        let offer = makeOffer(from: "pad", data: payload, name: "tamper.bin")
        // Write #1 = TCP_HELLO, #2 = TCP_AUTH, #3 = offer encrypted frame.
        let pipe = InMemoryDuplexPipe(padToPcFault: .flipLastByteOnWrite(3))
        let pcSink = InMemoryWifiTransferSink()
        let padSink = InMemoryWifiTransferSink()

        let padTask = Task {
            try await WifiTransferEngine.runPadSession(
                stream: pipe.padEnd,
                keys: keys,
                outgoing: [InMemoryWifiTransferSource(offer: offer, payload: payload)],
                sink: padSink
            )
        }
        let pcTask = Task {
            try await WifiTransferEngine.runPcSession(stream: pipe.pcEnd, keys: keys, outgoing: [], sink: pcSink, replayGuard: replayGuard)
        }

        await expectAsyncError(.authentication) { _ = try await pcTask.value }
        await pipe.closeAll()
        do { _ = try await padTask.value } catch {}
        let count = await pcSink.completedCount()
        XCTAssertEqual(count, 0)
    }

    func testInMemoryPipeReplayReorderingAndMissingRejected() async throws {
        // 1. Replaying recorded TCP_HELLO + TCP_AUTH against a fresh PC handshake fails.
        let keys = try makeSessionKeys()
        let guard1 = try WifiSessionReplayGuard()
        let pipe1 = InMemoryDuplexPipe(recordPadWrites: true)
        async let pad1 = WifiTransferEngine.runPadSession(stream: pipe1.padEnd, keys: keys, outgoing: [], sink: InMemoryWifiTransferSink())
        async let pc1 = WifiTransferEngine.runPcSession(stream: pipe1.pcEnd, keys: keys, outgoing: [], sink: InMemoryWifiTransferSink(), replayGuard: guard1)
        _ = try await (pad1, pc1)

        let captured = await pipe1.padToPc.capturedWrites()
        XCTAssertGreaterThanOrEqual(captured.count, 2)
        let freshPc = try WifiTcpPcHandshake(transferKeys: keys)
        _ = try freshPc.acceptHello(captured[0])
        expectError(.authentication) { _ = try freshPc.acceptAuth(captured[1]) }

        // 2. Replaying an already-consumed session UUID against replayGuard fails with .state.
        let pipe2 = InMemoryDuplexPipe()
        let padTask2 = Task {
            try await WifiTransferEngine.runPadSession(stream: pipe2.padEnd, keys: keys, outgoing: [], sink: InMemoryWifiTransferSink())
        }
        let pcTask2 = Task {
            try await WifiTransferEngine.runPcSession(stream: pipe2.pcEnd, keys: keys, outgoing: [], sink: InMemoryWifiTransferSink(), replayGuard: guard1)
        }
        await expectAsyncError(.state) { _ = try await pcTask2.value }
        await pipe2.closeAll()
        do { _ = try await padTask2.value } catch {}

        // 3. Duplicating an encrypted stream frame on the wire fails with .sequence.
        let keys3 = try makeSessionKeys()
        let payload = makeDeterministicData(length: 1000)
        let offer = makeOffer(from: "pad", data: payload)
        let pipe3 = InMemoryDuplexPipe(padToPcFault: .duplicateWrite(3))
        let padTask3 = Task {
            try await WifiTransferEngine.runPadSession(
                stream: pipe3.padEnd,
                keys: keys3,
                outgoing: [InMemoryWifiTransferSource(offer: offer, payload: payload)],
                sink: InMemoryWifiTransferSink()
            )
        }
        let pcTask3 = Task {
            try await WifiTransferEngine.runPcSession(stream: pipe3.pcEnd, keys: keys3, outgoing: [], sink: InMemoryWifiTransferSink(), replayGuard: guard1)
        }
        await expectAsyncError(.sequence) { _ = try await pcTask3.value }
        await pipe3.closeAll()
        do { _ = try await padTask3.value } catch {}

        // 4. Reordering two encrypted chunks (#4 and #5) fails with .sequence.
        let keys4 = try makeSessionKeys()
        let bigPayload = makeDeterministicData(length: 20_000)
        let bigOffer = makeOffer(from: "pad", data: bigPayload)
        let pipe4 = InMemoryDuplexPipe(padToPcFault: .swapConsecutiveWrites(firstIndex: 4))
        let padTask4 = Task {
            try await WifiTransferEngine.runPadSession(
                stream: pipe4.padEnd,
                keys: keys4,
                outgoing: [InMemoryWifiTransferSource(offer: bigOffer, payload: bigPayload)],
                sink: InMemoryWifiTransferSink(),
                chunkSize: 4096
            )
        }
        let pcTask4 = Task {
            try await WifiTransferEngine.runPcSession(stream: pipe4.pcEnd, keys: keys4, outgoing: [], sink: InMemoryWifiTransferSink(), replayGuard: guard1)
        }
        await expectAsyncError(.sequence) { _ = try await pcTask4.value }
        await pipe4.closeAll()
        do { _ = try await padTask4.value } catch {}

        // 5. Dropping encrypted chunk #4 causes chunk #5 to arrive out of sequence -> .sequence.
        let keys5 = try makeSessionKeys()
        let pipe5 = InMemoryDuplexPipe(padToPcFault: .dropWrite(4))
        let padTask5 = Task {
            try await WifiTransferEngine.runPadSession(
                stream: pipe5.padEnd,
                keys: keys5,
                outgoing: [InMemoryWifiTransferSource(offer: bigOffer, payload: bigPayload)],
                sink: InMemoryWifiTransferSink(),
                chunkSize: 4096
            )
        }
        let pcTask5 = Task {
            try await WifiTransferEngine.runPcSession(stream: pipe5.pcEnd, keys: keys5, outgoing: [], sink: InMemoryWifiTransferSink(), replayGuard: guard1)
        }
        await expectAsyncError(.sequence) { _ = try await pcTask5.value }
        await pipe5.closeAll()
        do { _ = try await padTask5.value } catch {}
    }

    func testInMemoryPipeOversizedWireFrameHeaderRejectedWithLimit() async throws {
        let keys = try makeSessionKeys()
        let replayGuard = try WifiSessionReplayGuard()
        let pipe = InMemoryDuplexPipe()
        async let padConnect = WifiEncryptedStream.connectAsPad(stream: pipe.padEnd, keys: keys)
        async let pcAccept = WifiEncryptedStream.acceptAsPc(stream: pipe.pcEnd, keys: keys, replayGuard: replayGuard)
        _ = try await padConnect
        let pcChannel = try await pcAccept

        let overLen = UInt32(SyncProtocol.maxWifiPlaintextBytes + 1)
        let bogusHeader = Data([
            SyncProtocol.wifiFrameType,
            SyncProtocol.wifiDirectionPadToPc,
            UInt8((overLen >> 24) & 0xFF),
            UInt8((overLen >> 16) & 0xFF),
            UInt8((overLen >> 8) & 0xFF),
            UInt8(overLen & 0xFF),
            0, 0, 0, 0, 0, 0, 0, 0,
        ])
        try await pipe.padEnd.write(bogusHeader)
        await expectAsyncError(.limit) { _ = try await pcChannel.receiveMessage() }
    }

    func testInMemoryPipeSha256MismatchDiscardsPartialAndRejectsWithoutAck() async throws {
        let keys = try makeSessionKeys()
        let replayGuard = try WifiSessionReplayGuard()
        let payload = makeDeterministicData(length: 20_000, seed: 7)
        let badOffer = SyncOffer(
            id: UUID(),
            at: 1_794_873_600_123,
            from: "pad",
            kind: "file",
            size: payload.count,
            sha256: String(repeating: "0", count: 64),
            name64: Data("corrupt.bin".utf8).base64EncodedString(),
            type: "public.data"
        )
        let pipe = InMemoryDuplexPipe()
        let pcSink = InMemoryWifiTransferSink()
        let padSink = InMemoryWifiTransferSink()

        let padTask = Task {
            try await WifiTransferEngine.runPadSession(
                stream: pipe.padEnd,
                keys: keys,
                outgoing: [InMemoryWifiTransferSource(offer: badOffer, payload: payload)],
                sink: padSink
            )
        }
        let pcTask = Task {
            try await WifiTransferEngine.runPcSession(stream: pipe.pcEnd, keys: keys, outgoing: [], sink: pcSink, replayGuard: replayGuard)
        }

        await expectAsyncError(.authentication) { _ = try await pcTask.value }
        await pipe.closeAll()
        do { _ = try await padTask.value } catch {}

        let hasPartial = await pcSink.hasPartial(for: badOffer.id)
        let count = await pcSink.completedCount()
        XCTAssertFalse(hasPartial)
        XCTAssertEqual(count, 0)
    }

    func testInMemoryPipeExact50MiBTransferSucceedsAndOver50MiBRejectedWithLimit() async throws {
        let over50 = SyncOffer(
            id: UUID(),
            at: 1_794_873_600_123,
            from: "pad",
            kind: "file",
            size: SyncProtocol.maxWifiItemBytes + 1,
            sha256: String(repeating: "a", count: 64),
            name64: Data("huge.bin".utf8).base64EncodedString(),
            type: "public.data"
        )
        expectError(.limit) { _ = try WifiStreamMessageCodec.encode(.offer(over50)) }

        let keysOver = try makeSessionKeys()
        let replayGuardOver = try WifiSessionReplayGuard()
        let pipeOver = InMemoryDuplexPipe()
        let pcTaskOver = Task {
            try await WifiTransferEngine.runPcSession(stream: pipeOver.pcEnd, keys: keysOver, outgoing: [], sink: InMemoryWifiTransferSink(), replayGuard: replayGuardOver)
        }
        let padTaskOver = Task {
            try await WifiTransferEngine.runPadSession(
                stream: pipeOver.padEnd,
                keys: keysOver,
                outgoing: [PatternWifiTransferSource(offer: over50)],
                sink: InMemoryWifiTransferSink()
            )
        }
        await expectAsyncError(.limit) { _ = try await padTaskOver.value }
        await pipeOver.padEnd.closeWrite()
        await expectAsyncError(.packet) { _ = try await pcTaskOver.value }

        // Exact 50 MiB streaming transfer succeeds with SHA-256 verification.
        let exact50Bytes = SyncProtocol.maxWifiItemBytes
        let exact50Hash = PatternWifiTransferSource.computePatternSha256(totalBytes: exact50Bytes)
        let exact50Offer = SyncOffer(
            id: UUID(),
            at: 1_794_873_600_123,
            from: "pad",
            kind: "file",
            size: exact50Bytes,
            sha256: exact50Hash,
            name64: Data("exact50m.bin".utf8).base64EncodedString(),
            type: "public.data"
        )
        let keys50 = try makeSessionKeys()
        let replayGuard50 = try WifiSessionReplayGuard()
        let pipe50 = InMemoryDuplexPipe()
        let streamingSink = StreamingHashWifiTransferSink()

        async let pad50 = WifiTransferEngine.runPadSession(
            stream: pipe50.padEnd,
            keys: keys50,
            outgoing: [PatternWifiTransferSource(offer: exact50Offer)],
            sink: InMemoryWifiTransferSink()
        )
        async let pc50 = WifiTransferEngine.runPcSession(
            stream: pipe50.pcEnd,
            keys: keys50,
            outgoing: [],
            sink: streamingSink,
            replayGuard: replayGuard50
        )
        let (padResult50, _) = try await (pad50, pc50)
        XCTAssertEqual(padResult50.sent.count, 1)
        XCTAssertEqual(padResult50.sent[0].transferredBytes, exact50Bytes)
        let completedCount = await streamingSink.completedCount
        let completedBytes = await streamingSink.completedBytes
        XCTAssertEqual(completedCount, 1)
        XCTAssertEqual(completedBytes, exact50Bytes)
    }

    func testInMemoryPipeCleanEofBeforeDoneDetectedAsTruncation() async throws {
        let keys = try makeSessionKeys()
        let replayGuard = try WifiSessionReplayGuard()
        let pipe = InMemoryDuplexPipe()
        async let padConnect = WifiEncryptedStream.connectAsPad(stream: pipe.padEnd, keys: keys)
        async let pcAccept = WifiEncryptedStream.acceptAsPc(stream: pipe.pcEnd, keys: keys, replayGuard: replayGuard)
        _ = try await padConnect
        let pcChannel = try await pcAccept

        await pipe.padEnd.closeWrite()
        await expectAsyncError(.packet) {
            _ = try await WifiTransferEngine.receiveItems(using: InMemoryWifiTransferSink(), over: pcChannel, expectedFrom: "pad")
        }
    }
}
