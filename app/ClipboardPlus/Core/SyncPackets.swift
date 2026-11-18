import Foundation

public enum SyncPacketizer {
    /// The limit includes the flags byte: pass the GATT value limit, not ATT MTU.
    public static func split(_ frame: Data, packetLimit: Int) throws -> [Data] {
        try SyncProtocol.require(packetLimit >= 2, .limit)
        try SyncProtocol.require((1...SyncProtocol.maxFrameBytes).contains(frame.count), .limit)
        let payloadLimit = packetLimit - 1
        var result: [Data] = []
        result.reserveCapacity((frame.count + payloadLimit - 1) / payloadLimit)
        var offset = frame.startIndex
        while offset < frame.endIndex {
            let count = min(payloadLimit, frame.endIndex - offset)
            let flags: UInt8 = (offset == frame.startIndex ? 1 : 0) | (offset + count == frame.endIndex ? 2 : 0)
            var packet = Data(capacity: count + 1)
            packet.append(flags)
            packet.append(frame[offset..<(offset + count)])
            result.append(packet)
            offset += count
        }
        return result
    }
}

/// One instance per direction/connection, called serially. Errors permanently invalidate it.
public final class SyncPacketAssembler {
    private let packetLimit: Int
    private var buffer = Data()
    private var active = false
    private var failed = false
    public var hasPartialFrame: Bool { active }
    private let frameLimit: Int
    public init(packetLimit: Int, frameLimit: Int = SyncProtocol.maxFrameBytes) throws {
        try SyncProtocol.require(packetLimit >= 2 && frameLimit > 0 && frameLimit <= SyncProtocol.maxFrameBytes, .limit)
        self.packetLimit = packetLimit
        self.frameLimit = frameLimit
    }
    public func append(_ packet: Data) throws -> Data? {
        try SyncProtocol.require(!failed, .state)
        do {
            try SyncProtocol.require(packet.count >= 2 && packet.count <= packetLimit, .packet)
            let flags = packet.first!
            try SyncProtocol.require(flags & 0xFC == 0, .packet)
            let start = flags & 1 != 0
            try SyncProtocol.require(start != active, .packet)
            try SyncProtocol.require(packet.count - 1 <= frameLimit - buffer.count, .limit)
            active = true
            buffer.append(contentsOf: packet.dropFirst())
            if flags & 2 == 0 { return nil }
            let frame = buffer
            buffer = Data(); active = false
            return frame
        } catch {
            failed = true; active = false; buffer = Data()
            throw error
        }
    }
    /// Call on disconnect or assembly timeout to detect a start with no end.
    public func finish() throws {
        try SyncProtocol.require(!failed, .state)
        failed = true
        let incomplete = active
        buffer = Data(); active = false
        try SyncProtocol.require(!incomplete, .packet)
    }
}
