import Foundation
import CryptoKit

public enum WifiStreamMessage: Equatable, Sendable {
    case offer(SyncOffer)
    case resume(id: UUID, offset: Int)
    case chunk(id: UUID, offset: Int, data: Data)
    case ack(id: UUID)
    case done
}

public enum WifiStreamMessageCodec {
    public static func encode(_ message: WifiStreamMessage) throws -> Data {
        var sink = BoundedUtf8Sink(maxBytes: SyncProtocol.maxHeaderBytes, writeBytes: true)
        let body: Data
        try sink.writeByte(0x7B) // {
        switch message {
        case let .offer(offer):
            try offer.validate(maxSize: SyncProtocol.maxWifiItemBytes)
            try sink.writeBytes("\"at\":".utf8)
            try sink.writeInt64(offer.at)
            try sink.writeBytes(",\"from\":".utf8)
            try sink.writeEscapedJsonString(offer.from)
            try sink.writeBytes(",\"id\":".utf8)
            try sink.writeEscapedJsonString(offer.id.uuidString)
            try sink.writeBytes(",\"kind\":".utf8)
            try sink.writeEscapedJsonString(offer.kind)
            try sink.writeBytes(",\"name64\":".utf8)
            try sink.writeEscapedJsonString(offer.name64)
            try sink.writeBytes(",\"sha256\":".utf8)
            try sink.writeEscapedJsonString(offer.sha256)
            try sink.writeBytes(",\"size\":".utf8)
            try sink.writeInt64(Int64(offer.size))
            try sink.writeBytes(",\"t\":\"offer\",\"type\":".utf8)
            try sink.writeEscapedJsonString(offer.type)
            body = Data()

        case let .resume(id, offset):
            try SyncProtocol.require(offset >= 0)
            try SyncProtocol.require(offset <= SyncProtocol.maxWifiItemBytes, .limit)
            try sink.writeBytes("\"id\":".utf8)
            try sink.writeEscapedJsonString(id.uuidString)
            try sink.writeBytes(",\"offset\":".utf8)
            try sink.writeInt64(Int64(offset))
            try sink.writeBytes(",\"t\":\"resume\"".utf8)
            body = Data()

        case let .chunk(id, offset, data):
            try SyncProtocol.require(offset >= 0 && !data.isEmpty)
            try SyncProtocol.require(data.count <= SyncProtocol.maxWifiChunkBytes, .limit)
            try SyncProtocol.require(offset <= SyncProtocol.maxWifiItemBytes - data.count, .limit)
            try sink.writeBytes("\"id\":".utf8)
            try sink.writeEscapedJsonString(id.uuidString)
            try sink.writeBytes(",\"offset\":".utf8)
            try sink.writeInt64(Int64(offset))
            try sink.writeBytes(",\"t\":\"chunk\"".utf8)
            body = data

        case let .ack(id):
            try sink.writeBytes("\"id\":".utf8)
            try sink.writeEscapedJsonString(id.uuidString)
            try sink.writeBytes(",\"t\":\"ack\"".utf8)
            body = Data()

        case .done:
            try sink.writeBytes("\"t\":\"done\"".utf8)
            body = Data()
        }
        try sink.writeByte(0x7D) // }

        let header = sink.data()
        try SyncProtocol.require(header.count <= SyncProtocol.maxHeaderBytes, .limit)
        try SyncProtocol.require(2 + header.count + body.count <= SyncProtocol.maxWifiPlaintextBytes, .limit)
        let lenHi = UInt8((header.count >> 8) & 0xFF)
        let lenLo = UInt8(header.count & 0xFF)
        return Data([lenHi, lenLo]) + header + body
    }

    public static func decode(_ input: Data) throws -> WifiStreamMessage {
        let plaintext = Data(input)
        try SyncProtocol.require(plaintext.count <= SyncProtocol.maxWifiPlaintextBytes, .limit)
        try SyncProtocol.require(plaintext.count >= 2)
        let headerLen = (Int(plaintext[0]) << 8) | Int(plaintext[1])
        try SyncProtocol.require(headerLen > 0 && headerLen <= plaintext.count - 2)
        let header = plaintext.subdata(in: 2..<(2 + headerLen))
        try SyncProtocol.require(header.allSatisfy { $0 < 128 })
        let body = plaintext.subdata(in: (2 + headerLen)..<plaintext.count)

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
        case "offer":
            try requireKeys(["at", "from", "id", "kind", "name64", "sha256", "size", "t", "type"])
            try SyncProtocol.require(body.isEmpty)
            let sizeLong = try requireInteger("size")
            try SyncProtocol.require(sizeLong >= 0)
            try SyncProtocol.require(sizeLong <= Int64(SyncProtocol.maxWifiItemBytes), .limit)
            let idStr = try requireString("id")
            let id = try SyncProtocol.parseId(idStr)
            let at = try requireInteger("at")
            let from = try requireString("from")
            let kind = try requireString("kind")
            let sha256 = try requireString("sha256")
            let name64 = try requireString("name64")
            let type = try requireString("type")
            let offer = SyncOffer(
                id: id,
                at: at,
                from: from,
                kind: kind,
                size: Int(sizeLong),
                sha256: sha256,
                name64: name64,
                type: type
            )
            try offer.validate(maxSize: SyncProtocol.maxWifiItemBytes)
            return .offer(offer)

        case "resume":
            try requireKeys(["id", "offset", "t"])
            try SyncProtocol.require(body.isEmpty)
            let idStr = try requireString("id")
            let id = try SyncProtocol.parseId(idStr)
            let offsetLong = try requireInteger("offset")
            try SyncProtocol.require(offsetLong >= 0)
            try SyncProtocol.require(offsetLong <= Int64(SyncProtocol.maxWifiItemBytes), .limit)
            return .resume(id: id, offset: Int(offsetLong))

        case "chunk":
            try requireKeys(["id", "offset", "t"])
            let idStr = try requireString("id")
            let id = try SyncProtocol.parseId(idStr)
            let offsetLong = try requireInteger("offset")
            try SyncProtocol.require(offsetLong >= 0)
            try SyncProtocol.require(!body.isEmpty)
            try SyncProtocol.require(body.count <= SyncProtocol.maxWifiChunkBytes, .limit)
            try SyncProtocol.require(offsetLong <= Int64(SyncProtocol.maxWifiItemBytes - body.count), .limit)
            return .chunk(id: id, offset: Int(offsetLong), data: body)

        case "ack":
            try requireKeys(["id", "t"])
            try SyncProtocol.require(body.isEmpty)
            let idStr = try requireString("id")
            let id = try SyncProtocol.parseId(idStr)
            return .ack(id: id)

        case "done":
            try requireKeys(["t"])
            try SyncProtocol.require(body.isEmpty)
            return .done

        default:
            throw SyncProtocolError.format
        }
    }
}

/// OS-independent async byte stream boundary (backed by NWConnection in Stage D or in-memory pipe in tests).
public protocol WifiByteStream: Sendable {
    /// Reads up to `maxLength` bytes. Returns empty `Data` on clean EOF.
    func read(maxLength: Int) async throws -> Data
    func write(_ data: Data) async throws
}

public actor WifiEncryptedStream {
    private let stream: any WifiByteStream
    private let sender: WifiStreamFrameSender
    private let receiver: WifiStreamFrameReceiver
    private var readBuffer = Data()

    public init(
        stream: any WifiByteStream,
        sendKey: Data,
        sendDirection: WifiStreamDirection,
        receiveKey: Data,
        receiveDirection: WifiStreamDirection
    ) throws {
        self.stream = stream
        self.sender = try WifiStreamFrameSender(key: sendKey, direction: sendDirection)
        self.receiver = try WifiStreamFrameReceiver(key: receiveKey, direction: receiveDirection)
    }

    public static func connectAsPad(
        stream: any WifiByteStream,
        keys: WifiTransferKeys
    ) async throws -> WifiEncryptedStream {
        try await connectAsPad(stream: stream, keys: keys, testNonce: nil)
    }

    static func connectAsPad(
        stream: any WifiByteStream,
        keys: WifiTransferKeys,
        testNonce: Data?
    ) async throws -> WifiEncryptedStream {
        let handshake = try WifiTcpPadHandshake(transferKeys: keys, testNonce: testNonce)
        let hello = try handshake.createHello()
        try await stream.write(hello)

        var scratch = Data()
        let welcome = try await readExact(from: stream, buffer: &scratch, count: SyncProtocol.wifiTcpWelcomeBytes)
        let auth = try handshake.acceptWelcome(welcome)
        try await stream.write(auth.auth)

        let channel = try WifiEncryptedStream(
            stream: stream,
            sendKey: auth.keys.padToPc,
            sendDirection: .padToPc,
            receiveKey: auth.keys.pcToPad,
            receiveDirection: .pcToPad
        )
        await channel.seedReadBuffer(scratch)
        return channel
    }

    public static func acceptAsPc(
        stream: any WifiByteStream,
        keys: WifiTransferKeys,
        replayGuard: WifiSessionReplayGuard
    ) async throws -> WifiEncryptedStream {
        try await acceptAsPc(stream: stream, keys: keys, replayGuard: replayGuard, testNonce: nil)
    }

    static func acceptAsPc(
        stream: any WifiByteStream,
        keys: WifiTransferKeys,
        replayGuard: WifiSessionReplayGuard,
        testNonce: Data?
    ) async throws -> WifiEncryptedStream {
        try await replayGuard.requireNotConsumed(keys.session)
        let handshake = try WifiTcpPcHandshake(transferKeys: keys, testNonce: testNonce)
        var scratch = Data()
        let hello = try await readExact(from: stream, buffer: &scratch, count: SyncProtocol.wifiTcpHelloBytes)
        let welcome = try handshake.acceptHello(hello)
        try await stream.write(welcome)

        let auth = try await readExact(from: stream, buffer: &scratch, count: SyncProtocol.wifiTcpAuthBytes)
        let trafficKeys = try handshake.acceptAuth(auth)
        try await replayGuard.consumeOrThrow(keys.session)

        let channel = try WifiEncryptedStream(
            stream: stream,
            sendKey: trafficKeys.pcToPad,
            sendDirection: .pcToPad,
            receiveKey: trafficKeys.padToPc,
            receiveDirection: .padToPc
        )
        await channel.seedReadBuffer(scratch)
        return channel
    }

    private func seedReadBuffer(_ leftover: Data) {
        if !leftover.isEmpty {
            readBuffer.append(leftover)
        }
    }

    public func sendMessage(_ message: WifiStreamMessage) async throws {
        let plaintext = try WifiStreamMessageCodec.encode(message)
        let frame = try sender.seal(plaintext)
        try await stream.write(frame)
    }

    public func receiveMessage() async throws -> WifiStreamMessage {
        let header = try await readExactLocal(count: SyncProtocol.wifiFrameHeaderBytes)
        let parsed = try receiver.parseHeader(header)
        let bodyAndTag = try await readExactLocal(count: parsed.payloadLength + SyncProtocol.wifiFrameTagBytes)
        let plaintext = try receiver.open(header: header, bodyAndTag: bodyAndTag)
        return try WifiStreamMessageCodec.decode(plaintext)
    }

    private func readExactLocal(count: Int) async throws -> Data {
        while readBuffer.count < count {
            let needed = count - readBuffer.count
            let chunk = try await stream.read(maxLength: max(needed, 4096))
            if chunk.isEmpty {
                throw SyncProtocolError.packet
            }
            readBuffer.append(chunk)
        }
        let result = Data(readBuffer.prefix(count))
        readBuffer = Data(readBuffer.dropFirst(count))
        return result
    }

    private static func readExact(from stream: any WifiByteStream, buffer: inout Data, count: Int) async throws -> Data {
        while buffer.count < count {
            let needed = count - buffer.count
            let chunk = try await stream.read(maxLength: max(needed, 4096))
            if chunk.isEmpty {
                throw SyncProtocolError.packet
            }
            buffer.append(chunk)
        }
        let result = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return result
    }
}

public enum WifiOfferDecision: Equatable, Sendable {
    case alreadyCompleted
    case resume(offset: Int)
}

public protocol WifiTransferSource: Sendable {
    var offer: SyncOffer { get }
    func readChunk(offset: Int, maxLength: Int) async throws -> Data
}

public protocol WifiTransferSink: Sendable {
    func beginOffer(_ offer: SyncOffer) async throws -> WifiOfferDecision
    func appendChunk(id: UUID, offset: Int, data: Data) async throws -> Int
    func verifyAndComplete(_ offer: SyncOffer) async throws
    func discardPartial(id: UUID) async throws
}

public struct WifiSentItemResult: Equatable, Sendable {
    public let id: UUID
    public let totalBytes: Int
    public let transferredBytes: Int
    public let alreadyCompleted: Bool
}

public struct WifiReceivedItemResult: Equatable, Sendable {
    public let offer: SyncOffer
    public let transferredBytes: Int
    public let alreadyCompleted: Bool
}

public struct WifiSessionResult: Equatable, Sendable {
    public let sent: [WifiSentItemResult]
    public let received: [WifiReceivedItemResult]
}

public enum WifiTransferEngine {
    public static func sendItems(
        _ items: [any WifiTransferSource],
        over channel: WifiEncryptedStream,
        chunkSize: Int = SyncProtocol.maxWifiChunkBytes,
        onProgress: (@Sendable (UUID, Int, Int) -> Void)? = nil
    ) async throws -> [WifiSentItemResult] {
        try SyncProtocol.require(chunkSize >= 1 && chunkSize <= SyncProtocol.maxWifiChunkBytes, .limit)
        var results: [WifiSentItemResult] = []
        results.reserveCapacity(items.count)

        for item in items {
            let offer = item.offer
            try offer.validate(maxSize: SyncProtocol.maxWifiItemBytes)
            try await channel.sendMessage(.offer(offer))

            let reply = try await channel.receiveMessage()
            switch reply {
            case let .ack(ackId):
                try SyncProtocol.require(ackId == offer.id, .state)
                onProgress?(offer.id, offer.size, offer.size)
                results.append(WifiSentItemResult(id: offer.id, totalBytes: offer.size, transferredBytes: 0, alreadyCompleted: true))

            case let .resume(resumeId, startOffset):
                try SyncProtocol.require(resumeId == offer.id, .state)
                try SyncProtocol.require(startOffset >= 0 && startOffset < offer.size, .state)
                var cursor = startOffset
                var transferred = 0
                while cursor < offer.size {
                    let want = min(chunkSize, offer.size - cursor)
                    let chunkData = try await item.readChunk(offset: cursor, maxLength: want)
                    try SyncProtocol.require(!chunkData.isEmpty && chunkData.count <= want, .state)
                    try await channel.sendMessage(.chunk(id: offer.id, offset: cursor, data: chunkData))
                    cursor += chunkData.count
                    transferred += chunkData.count
                    onProgress?(offer.id, cursor, offer.size)
                }
                let finalReply = try await channel.receiveMessage()
                guard case let .ack(finalAckId) = finalReply, finalAckId == offer.id else {
                    throw SyncProtocolError.state
                }
                results.append(WifiSentItemResult(id: offer.id, totalBytes: offer.size, transferredBytes: transferred, alreadyCompleted: false))

            default:
                throw SyncProtocolError.state
            }
        }

        try await channel.sendMessage(.done)
        return results
    }

    public static func receiveItems(
        using sink: any WifiTransferSink,
        over channel: WifiEncryptedStream,
        expectedFrom: String,
        onProgress: (@Sendable (UUID, Int, Int) -> Void)? = nil
    ) async throws -> [WifiReceivedItemResult] {
        try SyncProtocol.require(expectedFrom == "pc" || expectedFrom == "pad")
        var results: [WifiReceivedItemResult] = []

        while true {
            let message = try await channel.receiveMessage()
            switch message {
            case .done:
                return results

            case let .offer(offer):
                try SyncProtocol.require(offer.from == expectedFrom, .format)
                try offer.validate(maxSize: SyncProtocol.maxWifiItemBytes)

                let decision = try await sink.beginOffer(offer)
                switch decision {
                case .alreadyCompleted:
                    try await channel.sendMessage(.ack(id: offer.id))
                    onProgress?(offer.id, offer.size, offer.size)
                    results.append(WifiReceivedItemResult(offer: offer, transferredBytes: 0, alreadyCompleted: true))

                case let .resume(startOffset):
                    try SyncProtocol.require(startOffset >= 0 && startOffset <= offer.size, .state)
                    if startOffset == offer.size {
                        try await sink.verifyAndComplete(offer)
                        try await channel.sendMessage(.ack(id: offer.id))
                        onProgress?(offer.id, offer.size, offer.size)
                        results.append(WifiReceivedItemResult(offer: offer, transferredBytes: 0, alreadyCompleted: false))
                        continue
                    }

                    try await channel.sendMessage(.resume(id: offer.id, offset: startOffset))
                    var cursor = startOffset
                    var transferred = 0
                    while cursor < offer.size {
                        let nextMessage = try await channel.receiveMessage()
                        guard case let .chunk(chunkId, chunkOffset, chunkData) = nextMessage else {
                            throw SyncProtocolError.state
                        }
                        try SyncProtocol.require(chunkId == offer.id, .state)
                        try SyncProtocol.require(chunkOffset == cursor, .format)
                        try SyncProtocol.require(chunkData.count <= offer.size - cursor, .format)

                        let saved = try await sink.appendChunk(id: offer.id, offset: chunkOffset, data: chunkData)
                        try SyncProtocol.require(saved == cursor + chunkData.count, .state)
                        cursor = saved
                        transferred += chunkData.count
                        onProgress?(offer.id, cursor, offer.size)
                    }

                    try await sink.verifyAndComplete(offer)
                    try await channel.sendMessage(.ack(id: offer.id))
                    results.append(WifiReceivedItemResult(offer: offer, transferredBytes: transferred, alreadyCompleted: false))
                }

            default:
                throw SyncProtocolError.state
            }
        }
    }

    public static func runPadSession(
        stream: any WifiByteStream,
        keys: WifiTransferKeys,
        outgoing: [any WifiTransferSource],
        sink: any WifiTransferSink,
        chunkSize: Int = SyncProtocol.maxWifiChunkBytes
    ) async throws -> WifiSessionResult {
        try await runPadSession(
            stream: stream,
            keys: keys,
            outgoing: outgoing,
            sink: sink,
            chunkSize: chunkSize,
            testNonce: nil
        )
    }

    static func runPadSession(
        stream: any WifiByteStream,
        keys: WifiTransferKeys,
        outgoing: [any WifiTransferSource],
        sink: any WifiTransferSink,
        chunkSize: Int = SyncProtocol.maxWifiChunkBytes,
        testNonce: Data?
    ) async throws -> WifiSessionResult {
        let channel = try await WifiEncryptedStream.connectAsPad(stream: stream, keys: keys, testNonce: testNonce)
        let sent = try await sendItems(outgoing, over: channel, chunkSize: chunkSize)
        let received = try await receiveItems(using: sink, over: channel, expectedFrom: "pc")
        return WifiSessionResult(sent: sent, received: received)
    }

    public static func runPcSession(
        stream: any WifiByteStream,
        keys: WifiTransferKeys,
        outgoing: [any WifiTransferSource],
        sink: any WifiTransferSink,
        replayGuard: WifiSessionReplayGuard,
        chunkSize: Int = SyncProtocol.maxWifiChunkBytes
    ) async throws -> WifiSessionResult {
        try await runPcSession(
            stream: stream,
            keys: keys,
            outgoing: outgoing,
            sink: sink,
            replayGuard: replayGuard,
            chunkSize: chunkSize,
            testNonce: nil
        )
    }

    static func runPcSession(
        stream: any WifiByteStream,
        keys: WifiTransferKeys,
        outgoing: [any WifiTransferSource],
        sink: any WifiTransferSink,
        replayGuard: WifiSessionReplayGuard,
        chunkSize: Int = SyncProtocol.maxWifiChunkBytes,
        testNonce: Data?
    ) async throws -> WifiSessionResult {
        let channel = try await WifiEncryptedStream.acceptAsPc(
            stream: stream,
            keys: keys,
            replayGuard: replayGuard,
            testNonce: testNonce
        )
        let received = try await receiveItems(using: sink, over: channel, expectedFrom: "pad")
        let sent = try await sendItems(outgoing, over: channel, chunkSize: chunkSize)
        return WifiSessionResult(sent: sent, received: received)
    }
}

public struct InMemoryWifiTransferSource: WifiTransferSource {
    public let offer: SyncOffer
    private let payload: Data

    public init(offer: SyncOffer, payload: Data) {
        self.offer = offer
        self.payload = Data(payload)
    }

    public func readChunk(offset: Int, maxLength: Int) async throws -> Data {
        try SyncProtocol.require(offset >= 0 && offset <= payload.count, .state)
        let count = min(maxLength, payload.count - offset)
        return payload.subdata(in: offset..<(offset + count))
    }
}

public actor InMemoryWifiTransferSink: WifiTransferSink {
    private struct PartialEntry {
        let offer: SyncOffer
        var data: Data
    }

    private var partials: [UUID: PartialEntry] = [:]
    private var completedItems: [UUID: (offer: SyncOffer, data: Data)] = [:]

    public init() {}

    public func completedData(for id: UUID) -> Data? {
        completedItems[id]?.data
    }

    public func completedCount() -> Int {
        completedItems.count
    }

    public func hasPartial(for id: UUID) -> Bool {
        partials[id] != nil
    }

    public func partialLength(for id: UUID) -> Int {
        partials[id]?.data.count ?? 0
    }

    public func beginOffer(_ offer: SyncOffer) async throws -> WifiOfferDecision {
        try offer.validate(maxSize: SyncProtocol.maxWifiItemBytes)
        if completedItems[offer.id] != nil {
            return .alreadyCompleted
        }
        if let existing = partials[offer.id] {
            try SyncProtocol.require(existing.offer == offer, .format)
            try SyncProtocol.require(existing.data.count <= offer.size, .limit)
            return .resume(offset: existing.data.count)
        }
        partials[offer.id] = PartialEntry(offer: offer, data: Data())
        return .resume(offset: 0)
    }

    public func appendChunk(id: UUID, offset: Int, data: Data) async throws -> Int {
        guard var entry = partials[id] else {
            throw SyncProtocolError.state
        }
        let current = entry.data.count
        try SyncProtocol.require(offset == current && data.count <= entry.offer.size - current, .format)
        entry.data.append(data)
        partials[id] = entry
        return entry.data.count
    }

    public func verifyAndComplete(_ offer: SyncOffer) async throws {
        guard let entry = partials[offer.id], entry.offer == offer else {
            throw SyncProtocolError.state
        }
        let digest = SHA256.hash(data: entry.data)
        let hashHex = WifiControlMessageCodec.lowerHex(Data(digest))
        if entry.data.count != offer.size || hashHex != offer.sha256 {
            partials.removeValue(forKey: offer.id)
            throw SyncProtocolError.authentication
        }
        partials.removeValue(forKey: offer.id)
        completedItems[offer.id] = (offer: offer, data: entry.data)
    }

    public func discardPartial(id: UUID) async throws {
        partials.removeValue(forKey: id)
    }
}
