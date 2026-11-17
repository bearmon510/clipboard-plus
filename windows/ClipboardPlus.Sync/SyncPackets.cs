namespace ClipboardPlus.Sync;

public static class SyncPacketizer
{
    // packetLimit includes the one-byte flags, and is the actual GATT value limit (not ATT MTU).
    public static IReadOnlyList<byte[]> Split(ReadOnlySpan<byte> frame, int packetLimit)
    {
        SyncProtocol.Require(packetLimit >= 2, SyncError.Limit);
        SyncProtocol.Require(frame.Length is > 0 and <= SyncProtocol.MaxFrameBytes, SyncError.Limit);
        var packets = new List<byte[]>();
        for (var offset = 0; offset < frame.Length;)
        {
            var count = Math.Min(packetLimit - 1, frame.Length - offset);
            var packet = new byte[count + 1];
            packet[0] = (byte)((offset == 0 ? 1 : 0) | (offset + count == frame.Length ? 2 : 0));
            frame.Slice(offset, count).CopyTo(packet.AsSpan(1));
            packets.Add(packet); offset += count;
        }
        return packets;
    }
}

// One instance per connection/direction. Call serially; discard after any error.
public sealed class SyncPacketAssembler
{
    private readonly int packetLimit;
    private readonly MemoryStream buffer = new();
    private bool active, failed;
    public bool HasPartialFrame => active;
    private readonly int frameLimit;
    public SyncPacketAssembler(int packetLimit, int frameLimit = SyncProtocol.MaxFrameBytes)
    {
        SyncProtocol.Require(packetLimit >= 2, SyncError.Limit);
        this.packetLimit = packetLimit;
        SyncProtocol.Require(frameLimit is > 0 and <= SyncProtocol.MaxFrameBytes, SyncError.Limit);
        this.frameLimit = frameLimit;
    }
    public byte[]? Append(ReadOnlySpan<byte> packet)
    {
        SyncProtocol.Require(!failed, SyncError.State);
        try
        {
            SyncProtocol.Require(packet.Length >= 2 && packet.Length <= packetLimit, SyncError.Packet);
            var flags = packet[0];
            SyncProtocol.Require((flags & ~3) == 0, SyncError.Packet);
            var start = (flags & 1) != 0;
            SyncProtocol.Require(start != active, SyncError.Packet);
            SyncProtocol.Require(buffer.Length + packet.Length - 1 <= frameLimit, SyncError.Limit);
            active = true;
            buffer.Write(packet[1..]);
            if ((flags & 2) == 0) return null;
            var frame = buffer.ToArray();
            buffer.SetLength(0); active = false;
            return frame;
        }
        catch { failed = true; active = false; buffer.SetLength(0); throw; }
    }
    // Call on disconnect or assembly timeout. A new start is not an implicit reset.
    public void Finish()
    {
        SyncProtocol.Require(!failed, SyncError.State);
        failed = true;
        var incomplete = active;
        buffer.SetLength(0); active = false;
        SyncProtocol.Require(!incomplete, SyncError.Packet);
    }
}
