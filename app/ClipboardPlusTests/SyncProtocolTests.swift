import Foundation
import XCTest
@testable import ClipboardPlus

final class SyncProtocolTests: XCTestCase {
    private func vectors() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("protocol/test-vectors.json"))) as? [String: Any])
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
            try XCTUnwrap(UInt8(String(decoding: chars[$0..<($0 + 2)], as: UTF8.self), radix: 16))
        })
    }
    private func bytes(_ source: [String: Any], _ key: String) throws -> Data { try hex(string(source, key)) }
    private func error(_ expected: SyncProtocolError, file: StaticString = #filePath, line: UInt = #line, _ action: () throws -> Void) {
        XCTAssertThrowsError(try action(), file: file, line: line) { XCTAssertEqual($0 as? SyncProtocolError, expected, file: file, line: line) }
    }
    private func pair(_ v: [String: Any]) throws -> SyncPairing { try SyncPairing.parse(string(object(v, "pairing"), "qr")) }
    private func pad(_ v: [String: Any]) throws -> SyncPadHandshake {
        let h = try object(v, "handshake")
        return try SyncPadHandshake(pairing: pair(v), padId: XCTUnwrap(UUID(uuidString: string(h, "padId"))), testNonce: bytes(h, "niHex"))
    }
    private func pc(_ v: [String: Any]) throws -> SyncPcHandshake {
        let h = try object(v, "handshake")
        return try SyncPcHandshake(pairing: pair(v), expectedPadId: XCTUnwrap(UUID(uuidString: string(h, "padId"))), testNonce: bytes(h, "npHex"))
    }

    func testPairingAndBothHandshakeRolesMatchIndependentVectors() throws {
        let v = try vectors(), h = try object(v, "handshake"), p = try object(v, "pairing")
        let parsed = try object(p, "parsed"), pairing = try pair(v)
        XCTAssertEqual(pairing.qrString(), try string(p, "qr"))
        XCTAssertEqual(pairing.name, try string(parsed, "name"))
        XCTAssertEqual(pairing.pcId.uuidString, try string(parsed, "pcId"))
        XCTAssertEqual(pairing.key, try bytes(parsed, "keyHex"))
        let pad = try self.pad(v), pc = try self.pc(v)
        let hello = try pad.createHello()
        XCTAssertEqual(hello, try bytes(h, "helloHex"))
        let welcome = try pc.acceptHello(hello)
        XCTAssertEqual(welcome, try bytes(h, "welcomeHex"))
        XCTAssertEqual(Data(welcome.suffix(32)), try bytes(h, "pcHmacHex"))
        XCTAssertNil(pc.authenticatedPadId)
        let authentication = try pad.acceptWelcome(welcome)
        XCTAssertEqual(authentication.auth, try bytes(h, "authHex"))
        XCTAssertEqual(Data(authentication.auth.suffix(32)), try bytes(h, "padHmacHex"))
        let keys = try pc.acceptAuth(authentication.auth)
        XCTAssertEqual(pc.authenticatedPadId?.uuidString, try string(h, "padId"))
        for result in [keys, authentication.keys] {
            XCTAssertEqual(result.padToPc, try bytes(h, "padToPcKeyHex"))
            XCTAssertEqual(result.pcToPad, try bytes(h, "pcToPadKeyHex"))
        }
        error(.state) { _ = try pad.acceptWelcome(welcome) }
        error(.state) { _ = try pc.acceptAuth(authentication.auth) }
    }

    func testEveryMessageFrameAndFragmentMatchesIndependentVectors() throws {
        let v = try vectors(), h = try object(v, "handshake"), messages = try object(v, "messages")
        for value in messages.values {
            let fixture = try XCTUnwrap(value as? [String: Any])
            let plaintext = try bytes(fixture, "plaintextHex")
            let message = try SyncMessageCodec.decode(plaintext)
            XCTAssertEqual(try SyncMessageCodec.encode(message), plaintext)
            let length = Int(plaintext[0]) << 8 | Int(plaintext[1])
            XCTAssertEqual(String(data: plaintext.subdata(in: 2..<(length + 2)), encoding: .utf8), try string(fixture, "headerJson"))
            if case let .item(_, _, _, text) = message { XCTAssertEqual(text, try string(fixture, "bodyUtf8")) }
            if case let .ack(ids) = message { XCTAssertEqual(ids.count, 2) }
        }
        let frames = try XCTUnwrap(v["frames"] as? [[String: Any]])
        for direction in ["pad->pc", "pc->pad"] {
            let key = try bytes(h, direction == "pad->pc" ? "padToPcKeyHex" : "pcToPadKeyHex")
            let sender = try SyncFrameSender(key: key), receiver = try SyncFrameReceiver(key: key)
            for f in frames where f["direction"] as? String == direction {
                let plaintext = try bytes(object(messages, string(f, "message")), "plaintextHex")
                let expected = try bytes(f, "frameHex")
                XCTAssertEqual(try sender.seal(plaintext), expected)
                XCTAssertEqual(try receiver.open(expected), plaintext)
                XCTAssertEqual(Data(expected.prefix(9)), try bytes(f, "aadHex"))
                XCTAssertEqual(Data(expected.suffix(16)), try bytes(f, "tagHex"))
            }
        }
        for fixture in try XCTUnwrap(v["fragmentation"] as? [[String: Any]]) {
            let limit = try XCTUnwrap(fixture["packetLimit"] as? Int)
            let frame = try bytes(frames[XCTUnwrap(fixture["frameIndex"] as? Int)], "frameHex")
            let packets = try SyncPacketizer.split(frame, packetLimit: limit)
            let expected = try XCTUnwrap(fixture["packetsHex"] as? [String]).map(hex)
            XCTAssertEqual(packets, expected)
            let assembler = try SyncPacketAssembler(packetLimit: limit)
            for (index, packet) in packets.enumerated() {
                let result = try assembler.append(packet)
                if index == packets.count - 1 { XCTAssertEqual(result, frame) } else { XCTAssertNil(result) }
            }
            XCTAssertFalse(assembler.hasPartialFrame)
            XCTAssertEqual(try assembler.append(Data([3, 7])), Data([7]))
            try assembler.finish()
        }
    }

    func testFailureVectorsRejectAndInvalidateState() throws {
        let v = try vectors(), h = try object(v, "handshake"), failures = try object(v, "failures")
        let key = try bytes(h, "padToPcKeyHex")
        let frames = try XCTUnwrap(v["frames"] as? [[String: Any]])
        var receiver = try SyncFrameReceiver(key: key)
        error(.authentication) { _ = try receiver.open(bytes(object(failures, "tamperedTag"), "frameHex")) }
        error(.state) { _ = try receiver.open(bytes(frames[0], "frameHex")) }
        receiver = try SyncFrameReceiver(key: key)
        let rollback = try XCTUnwrap(object(failures, "rollback")["framesHex"] as? [String])
        _ = try receiver.open(hex(rollback[0]))
        error(.sequence) { _ = try receiver.open(hex(rollback[1])) }
        let pad = try self.pad(v); _ = try pad.createHello()
        error(.authentication) { _ = try pad.acceptWelcome(bytes(object(failures, "welcomeHmac"), "frameHex")) }
        error(.state) { _ = try pad.acceptWelcome(bytes(h, "welcomeHex")) }
        let pc = try self.pc(v); _ = try pc.acceptHello(bytes(h, "helloHex"))
        error(.authentication) { _ = try pc.acceptAuth(bytes(object(failures, "authHmac"), "frameHex")) }
        XCTAssertNil(pc.authenticatedPadId)
        error(.state) { _ = try pc.acceptAuth(bytes(h, "authHex")) }
        for name in ["unfinishedStart", "continuationWithoutStart"] {
            let fixture = try object(failures, name), assembler = try SyncPacketAssembler(packetLimit: 20)
            error(.packet) {
                for packet in try XCTUnwrap(fixture["packetsHex"] as? [String]) { _ = try assembler.append(hex(packet)) }
                if fixture["finish"] as? Bool == true { try assembler.finish() }
            }
            error(.state) { _ = try assembler.append(Data([3, 7])) }
        }
        let large = try object(failures, "oversizedFrame")
        let oversized = Data(repeating: UInt8(try XCTUnwrap(large["fillByte"] as? Int)), count: try XCTUnwrap(large["byteLength"] as? Int))
        error(.limit) { _ = try SyncPacketizer.split(oversized, packetLimit: 182) }
        error(.limit) { _ = try SyncFrameReceiver(key: key).open(oversized) }
        let limit = try XCTUnwrap(large["packetLimit"] as? Int), assembler = try SyncPacketAssembler(packetLimit: limit)
        error(.limit) {
            var offset = 0
            while offset < oversized.count {
                let count = min(limit - 1, oversized.count - offset)
                let flags: UInt8 = (offset == 0 ? 1 : 0) | (offset + count == oversized.count ? 2 : 0)
                _ = try assembler.append(Data([flags]) + oversized.subdata(in: offset..<(offset + count)))
                offset += count
            }
        }
    }

    func testStrictPairingIdentityAndHandshakeState() throws {
        let v = try vectors(), pairing = try pair(v), h = try object(v, "handshake")
        let parts = pairing.qrString().components(separatedBy: ":")
        let prefix = parts.prefix(4).joined(separator: ":") + ":"
        for name in ["", "%", "%GG", "%C0%AF", "%ED%A0%80", "%00", "%0A", "raw+name", "raw name", "日本語", String(repeating: "a", count: 256)] {
            error(.format) { _ = try SyncPairing.parse(prefix + name) }
        }
        for qr in ["clipboardplus-pair:2:a:b:c", "clipboardplus-pair:1:a:b:c", pairing.qrString() + "=", pairing.qrString() + ":extra"] {
            error(.format) { _ = try SyncPairing.parse(qr) }
        }
        var noncanonical = parts; noncanonical[2] = String(noncanonical[2].dropLast()) + "x"
        error(.format) { _ = try SyncPairing.parse(noncanonical.joined(separator: ":")) }
        var padded = parts; padded[3] += "="
        error(.format) { _ = try SyncPairing.parse(padded.joined(separator: ":")) }
        XCTAssertEqual(try SyncPairing.parse(prefix + "%41").name, "A")
        XCTAssertEqual(try SyncPairing.parse(prefix + String(repeating: "a", count: 255)).name.utf8.count, 255)
        let pad = try self.pad(v); _ = try pad.createHello()
        var wrongId = try bytes(h, "welcomeHex"); wrongId[2] ^= 1
        error(.identity) { _ = try pad.acceptWelcome(wrongId) }
        var wrongPad = try bytes(h, "helloHex"); wrongPad[2] ^= 1
        error(.identity) { _ = try pc(v).acceptHello(wrongPad) }
        error(.state) { _ = try pc(v).acceptAuth(bytes(h, "authHex")) }
        error(.state) { _ = try self.pad(v).acceptWelcome(bytes(h, "welcomeHex")) }
        let repeated = try self.pad(v); _ = try repeated.createHello()
        error(.state) { _ = try repeated.createHello() }
        let hello = try bytes(h, "helloHex")
        for frame in [Data(hello.dropLast()), hello + Data([0]), Data(repeating: 0, count: 50)] {
            error(.format) { _ = try pc(v).acceptHello(frame) }
        }
    }

    private func plain(_ header: String, body: Data = Data()) -> Data {
        let h = Data(header.utf8)
        return Data([UInt8(h.count >> 8), UInt8(truncatingIfNeeded: h.count)]) + h + body
    }
    func testFlexibleReadingAndMalformedMessages() throws {
        let id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let text = "日本語\n📋"
        let message = try SyncMessageCodec.decode(plain(" { \"t\" : \"item\", \"kind\":\"text\", \"id\":\"\(id)\", \"from\":\"pc\", \"at\": -123 } ", body: Data(text.utf8)))
        XCTAssertEqual(message, .item(id: try XCTUnwrap(UUID(uuidString: id)), at: -123, from: "pc", text: text))
        XCTAssertTrue(String(decoding: try SyncMessageCodec.encode(message), as: UTF8.self).contains(id.uppercased()))
        for header in ["{}", "[]", "{\"t\":\"image\"}", "{\"t\":\"ping\",\"extra\":0}", "{\"t\":\"ping\",\"t\":\"ping\"}",
                       "{\"t\":\"ping\",\"\\u0074\":\"ping\"}", "{\"t\":\"ping\",}", "{\"t\":\"ping\"} trailing",
                       "{\"t\":\"p\\u00E9ng\"}", "{\"t\":\"ping\",\"日本語\":0}", "{\"ids\":[\"bad\"],\"t\":\"ack\"}"] {
            error(.format) { _ = try SyncMessageCodec.decode(plain(header)) }
        }
        for at in ["true", "1.0", "1e3", "\"1\"", "9007199254740992", "-9007199254740992", "null"] {
            error(.format) { _ = try SyncMessageCodec.decode(plain("{\"t\":\"item\",\"kind\":\"text\",\"id\":\"\(id)\",\"from\":\"pad\",\"at\":\(at)}")) }
        }
        for at in [-SyncProtocol.maxTimestamp, 0, SyncProtocol.maxTimestamp] {
            let m = SyncMessage.item(id: UUID(), at: at, from: "pc", text: "")
            XCTAssertEqual(try SyncMessageCodec.decode(SyncMessageCodec.encode(m)), m)
        }
        error(.format) { _ = try SyncMessageCodec.decode(plain("{\"t\":\"ping\"}", body: Data([0]))) }
        error(.format) { _ = try SyncMessageCodec.decode(plain("{\"t\":\"pong\"}", body: Data([0]))) }
        error(.format) { _ = try SyncMessageCodec.decode(plain("{\"t\":\"pong\",\"extra\":0}")) }
        XCTAssertEqual(try SyncMessageCodec.decode(plain("{\"t\":\"pong\"}")), .pong)
        error(.format) { _ = try SyncMessageCodec.decode(plain("{\"t\":\"ack\",\"ids\":[\"\(id)\"]}", body: Data([0]))) }
        error(.format) { _ = try SyncMessageCodec.decode(plain("{\"t\":\"item\",\"kind\":\"text\",\"id\":\"\(id)\",\"from\":\"pad\",\"at\":0}", body: Data([0xC0, 0xAF]))) }
        error(.format) { _ = try SyncMessageCodec.decode(Data([0, 30, 123])) }
        error(.format) { _ = try SyncMessageCodec.decode(Data([0])) }
        error(.limit) { _ = try SyncMessageCodec.encode(.ack(ids: [])) }
        error(.limit) { _ = try SyncMessageCodec.decode(plain("{\"t\":\"ack\",\"ids\":[]}")) }
        error(.limit) { _ = try SyncMessageCodec.encode(.ack(ids: Array(repeating: UUID(), count: 1025))) }
        error(.limit) { _ = try SyncMessageCodec.encode(.item(id: UUID(), at: 0, from: "pad", text: String(repeating: "a", count: SyncProtocol.maxPlaintextBytes))) }
        let maxAck = SyncMessage.ack(ids: Array(repeating: UUID(), count: 1024))
        XCTAssertEqual(try SyncMessageCodec.decode(SyncMessageCodec.encode(maxAck)), maxAck)
    }

    func testPacketBoundariesAndCipherFailures() throws {
        let attributeFrame = Data(repeating: 7, count: 1023)
        let attributePackets = try SyncPacketizer.split(attributeFrame, packetLimit: 512)
        XCTAssertEqual(attributePackets.map(\.count), [512, 512, 2])
        let attributeAssembler = try SyncPacketAssembler(packetLimit: 512)
        var assembledAttribute: Data?
        for packet in attributePackets { assembledAttribute = try attributeAssembler.append(packet) }
        XCTAssertEqual(assembledAttribute, attributeFrame)
        error(.packet) { _ = try SyncPacketAssembler(packetLimit: 512).append(Data([3]) + Data(repeating: 7, count: 512)) }
        let invalidPackets: [[UInt8]] = [[], [1], [4, 0], [0, 1], [2, 1], Array(repeating: 0, count: 21)]
        for packet in invalidPackets {
            error(.packet) { _ = try SyncPacketAssembler(packetLimit: 20).append(Data(packet)) }
        }
        let assembler = try SyncPacketAssembler(packetLimit: 20); _ = try assembler.append(Data([1, 1]))
        error(.packet) { _ = try assembler.append(Data([1, 2])) }
        error(.limit) { _ = try SyncPacketAssembler(packetLimit: 1) }
        error(.limit) { _ = try SyncPacketizer.split(Data([1]), packetLimit: 1) }
        error(.limit) { _ = try SyncPacketizer.split(Data(), packetLimit: 20) }
        XCTAssertEqual(try SyncPacketizer.split(Data([1]), packetLimit: 2), [Data([3, 1])])
        let max = Data(repeating: 0, count: SyncProtocol.maxFrameBytes)
        let boundary = try SyncPacketAssembler(packetLimit: 182)
        var complete: Data?
        for packet in try SyncPacketizer.split(max, packetLimit: 182) { complete = try boundary.append(packet) }
        XCTAssertEqual(complete, max)
        let v = try vectors(), h = try object(v, "handshake"), key = try bytes(h, "padToPcKeyHex")
        let sender = try SyncFrameSender(key: key)
        let maxPlain = Data(repeating: 0, count: SyncProtocol.maxPlaintextBytes)
        let maxFrame = try sender.seal(maxPlain)
        XCTAssertEqual(maxFrame.count, SyncProtocol.maxFrameBytes)
        XCTAssertEqual(try SyncFrameReceiver(key: key).open(maxFrame), maxPlain)
        error(.limit) { _ = try sender.seal(Data(repeating: 0, count: SyncProtocol.maxPlaintextBytes + 1)) }
        let frames = try XCTUnwrap(v["frames"] as? [[String: Any]])
        let frame = try bytes(frames[0], "frameHex"), receiver = try SyncFrameReceiver(key: key)
        _ = try receiver.open(frame)
        error(.sequence) { _ = try receiver.open(frame) }
        error(.authentication) { _ = try SyncFrameReceiver(key: bytes(h, "pcToPadKeyHex")).open(frame) }
        for offset in [8, 10, frame.count - 1] {
            var tampered = frame; tampered[offset] ^= 1
            error(.authentication) { _ = try SyncFrameReceiver(key: key).open(tampered) }
        }
        error(.format) { _ = try SyncFrameReceiver(key: key).open(Data(frame.prefix(20))) }
        var wrongType = frame; wrongType[0] = 0x11
        error(.format) { _ = try SyncFrameReceiver(key: key).open(wrongType) }
        let pad = try SyncPadHandshake(pairing: pair(v), padId: UUID()), pc = try SyncPcHandshake(pairing: pair(v))
        let auth = try pad.acceptWelcome(pc.acceptHello(pad.createHello()))
        let keys = try pc.acceptAuth(auth.auth)
        XCTAssertNotEqual(keys.padToPc, key)
        let fresh = try SyncFrameSender(key: keys.padToPc).seal(SyncMessageCodec.encode(.ping))
        XCTAssertEqual(try SyncMessageCodec.decode(SyncFrameReceiver(key: auth.keys.padToPc).open(fresh)), .ping)
    }

    func testOfferFilenameAllowsFormatControlsAndRejectsControlCharacters() throws {
        let v = try vectors(), messages = try object(v, "messages"), failures = try object(v, "failures")
        guard case .offer(let zwjOffer) = try SyncMessageCodec.decode(try bytes(try object(messages, "zwjOffer"), "plaintextHex")) else {
            return XCTFail("Expected offer")
        }
        XCTAssertEqual(zwjOffer.filename, "家族👨‍👩‍👧‍👦.txt")
        XCTAssertTrue(zwjOffer.filename.contains("\u{200D}"))

        let bad = try object(failures, "controlNameOffer")
        XCTAssertEqual(try string(bad, "error"), "format")
        error(.format) { _ = try SyncMessageCodec.decode(try bytes(bad, "plaintextHex")) }

        let sha = String(repeating: "a", count: 64)
        for allowed in ["a\u{200D}b.txt", "a\u{200E}b.txt", "a\u{202E}b.txt", "a\u{FEFF}b.txt"] {
            let offer = SyncOffer(id: UUID(), at: 0, from: "pc", kind: "file", size: 1, sha256: sha,
                name64: Data(allowed.utf8).base64EncodedString(), type: "public.data")
            let decoded = try SyncMessageCodec.decode(SyncMessageCodec.encode(.offer(offer)))
            XCTAssertEqual(decoded, .offer(offer))
            if case .offer(let roundtrip) = decoded { XCTAssertEqual(roundtrip.filename, allowed) }
        }
        for forbidden in ["\u{0000}", "\u{0007}", "\u{001F}", "\u{007F}", "\u{0080}", "\u{0085}", "\u{009F}"] {
            let offer = SyncOffer(id: UUID(), at: 0, from: "pc", kind: "file", size: 1, sha256: sha,
                name64: Data(("a" + forbidden + "b").utf8).base64EncodedString(), type: "public.data")
            error(.format) { try offer.validate() }
        }
    }
}
