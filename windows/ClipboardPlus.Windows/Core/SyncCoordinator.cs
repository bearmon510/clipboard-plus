using System.Diagnostics;
using ClipboardPlus.Sync;

namespace ClipboardPlus.Windows.Core;

public interface ISyncPeer
{
    int PacketLimit { get; }
    Task SendPacketAsync(byte[] packet);
    // Retire this connection, including after a protocol/notification failure.
    void Reject();
}

public sealed record ClipboardSnapshot(uint Sequence, string? Text, bool Excluded);

public interface IClipboardAccess
{
    Task<uint> WriteTextAsync(string text);
}

public sealed record SyncStatus(int Connected, int Pending, DateTimeOffset? LastSent, DateTimeOffset? LastReceived);

/// <summary>All protocol state is serialized here, independently of WinRT and the UI.</summary>
public sealed class SyncCoordinator(SyncPairing pairing, IClipboardAccess clipboard, Action<string> log)
{
    private sealed class Connection(SyncPairing pair, ISyncPeer peer, DateTimeOffset now)
    {
        public readonly ISyncPeer Peer = peer;
        // MTU can increase after subscribing. Validate the current limit at each write
        // without replacing an assembler which may already hold a partial frame.
        public readonly SyncPacketAssembler Assembler = new(ushort.MaxValue);
        public readonly SyncPcHandshake Handshake = new(pair);
        public readonly Dictionary<Guid, DateTimeOffset> Sent = [];
        public readonly DateTimeOffset Started = now;
        public DateTimeOffset LastPacket = now;
        public int Stage;
        public SyncFrameSender? Sender;
        public SyncFrameReceiver? Receiver;
    }

    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Dictionary<ISyncPeer, Connection> connections = new(ReferenceEqualityComparer.Instance);
    private readonly List<SyncItem> pending = [];
    private readonly HashSet<Guid> seen = [];
    private readonly Queue<Guid> seenOrder = [];
    private uint? ownSequence;
    private uint? lastClipboardSequence;
    private DateTimeOffset? lastSent, lastReceived;
    public event Action<SyncStatus>? Changed;

    private void Publish() => Changed?.Invoke(new(connections.Values.Count(c => c.Stage == 2), pending.Count, lastSent, lastReceived));

    public async Task ConnectAsync(ISyncPeer peer)
    {
        await gate.WaitAsync();
        try
        {
            if (connections.ContainsKey(peer)) return;
            if (connections.Count >= 8) { peer.Reject(); return; }
            connections.Add(peer, new(pairing, peer, DateTimeOffset.UtcNow));
            log($"connected packetLimit={peer.PacketLimit}");
            Publish();
        }
        finally { gate.Release(); }
    }

    public async Task<bool> ReceiveAsync(ISyncPeer peer, byte[] packet)
    {
        await gate.WaitAsync();
        try
        {
            if (!connections.TryGetValue(peer, out var c)) return false;
            try
            {
                c.LastPacket = DateTimeOffset.UtcNow;
                if (packet.Length > peer.PacketLimit) throw new SyncProtocolException(SyncError.Packet);
                var frame = c.Assembler.Append(packet);
                if (frame is null) return true;
                if (c.Stage == 0)
                {
                    await SendFrameAsync(c, c.Handshake.AcceptHello(frame));
                    c.Stage = 1;
                    log("handshake welcome");
                }
                else if (c.Stage == 1)
                {
                    var keys = c.Handshake.AcceptAuth(frame);
                    c.Sender = new(keys.PcToPad);
                    c.Receiver = new(keys.PadToPc);
                    c.Stage = 2;
                    log($"handshake authenticated elapsedMs={(DateTimeOffset.UtcNow - c.Started).TotalMilliseconds:F0}");
                    await FlushAsync(c, retransmission: true);
                }
                else
                {
                    var message = SyncMessageCodec.Decode(c.Receiver!.Open(frame));
                    switch (message)
                    {
                        case SyncItem item:
                            if (item.From != "pad") throw new SyncProtocolException(SyncError.Format);
                            if (!seen.Contains(item.Id))
                            {
                                ownSequence = await clipboard.WriteTextAsync(item.Text);
                                seen.Add(item.Id); seenOrder.Enqueue(item.Id);
                                if (seenOrder.Count > 500) seen.Remove(seenOrder.Dequeue());
                                lastReceived = DateTimeOffset.Now;
                                log($"received items=1 bytes={frame.Length}");
                            }
                            else log("duplicate items=1");
                            await SendMessageAsync(c, new SyncAck([item.Id]));
                            break;
                        case SyncAck ack:
                            var removed = pending.RemoveAll(i => ack.Ids.Contains(i.Id) && c.Sent.ContainsKey(i.Id));
                            foreach (var connection in connections.Values)
                                foreach (var id in connection.Sent.Keys.Where(id => !pending.Any(i => i.Id == id)).ToArray())
                                    connection.Sent.Remove(id);
                            log($"ack removed={removed} pending={pending.Count}");
                            break;
                        case SyncPing: log("ping received"); break;
                    }
                }
                Publish();
                return true;
            }
            catch (Exception e)
            {
                Drop(c, Failure(e));
                return false;
            }
        }
        finally { gate.Release(); }
    }

    public async Task ClipboardChangedAsync(ClipboardSnapshot snapshot)
    {
        await gate.WaitAsync();
        try
        {
            if (snapshot.Sequence == lastClipboardSequence) return;
            lastClipboardSequence = snapshot.Sequence;
            if (snapshot.Sequence == ownSequence || snapshot.Excluded || snapshot.Text is null) return;
            var item = new SyncItem(Guid.NewGuid(), DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), "pc", snapshot.Text);
            // Validate the complete encoded size before retaining or touching a live sender.
            try { SyncMessageCodec.Encode(item); }
            catch (SyncProtocolException e) { log($"clipboard skipped error={e.Code}"); return; }
            if (pending.Count == 50)
            {
                var oldest = pending[0].Id;
                pending.RemoveAt(0);
                foreach (var c in connections.Values) c.Sent.Remove(oldest);
                log("pending overflow discarded=1");
            }
            pending.Add(item);
            log($"queued items=1 pending={pending.Count}");
            foreach (var c in connections.Values.ToArray())
            {
                if (c.Stage != 2) continue;
                try { await FlushAsync(c, retransmission: false); }
                catch (Exception e) { Drop(c, Failure(e)); }
            }
            Publish();
        }
        finally { gate.Release(); }
    }

    public async Task DisconnectAsync(ISyncPeer peer)
    {
        await gate.WaitAsync();
        try { if (connections.TryGetValue(peer, out var c)) Drop(c, "disconnected"); }
        finally { gate.Release(); }
    }

    public async Task TickAsync(DateTimeOffset now)
    {
        await gate.WaitAsync();
        try
        {
            foreach (var c in connections.Values.ToArray())
            {
                if ((c.Stage < 2 && now - c.Started > TimeSpan.FromSeconds(20)) ||
                    (c.Assembler.HasPartialFrame && now - c.LastPacket > TimeSpan.FromSeconds(20)))
                    Drop(c, "receive timeout");
                else if (c.Stage == 2)
                {
                    // A missing ACK must not strand an item on an otherwise healthy
                    // link (for example, a temporary history-save failure on iPad).
                    foreach (var id in c.Sent.Where(p => now - p.Value > TimeSpan.FromSeconds(60)).Select(p => p.Key).ToArray())
                        c.Sent.Remove(id);
                    try { await FlushAsync(c, retransmission: true); }
                    catch (Exception e) { Drop(c, Failure(e)); }
                }
            }
            Publish();
        }
        finally { gate.Release(); }
    }

    public async Task ResetConnectionsAsync()
    {
        await gate.WaitAsync();
        try { foreach (var c in connections.Values.ToArray()) Drop(c, "stopped"); }
        finally { gate.Release(); }
    }

    private async Task FlushAsync(Connection c, bool retransmission)
    {
        foreach (var item in pending.Where(i => !c.Sent.ContainsKey(i.Id)))
        {
            await SendMessageAsync(c, item);
            c.Sent.Add(item.Id, DateTimeOffset.UtcNow);
            lastSent = DateTimeOffset.Now;
            log($"sent items=1 resend={retransmission} pending={pending.Count}");
        }
    }

    private Task SendMessageAsync(Connection c, SyncMessage message) =>
        SendFrameAsync(c, c.Sender!.Seal(SyncMessageCodec.Encode(message)));

    private async Task SendFrameAsync(Connection c, byte[] frame)
    {
        var watch = Stopwatch.StartNew();
        var packets = SyncPacketizer.Split(frame, c.Peer.PacketLimit);
        foreach (var packet in packets)
            await c.Peer.SendPacketAsync(packet).WaitAsync(TimeSpan.FromSeconds(10));
        log($"notify packets={packets.Count} bytes={frame.Length} elapsedMs={watch.ElapsedMilliseconds} packetLimit={c.Peer.PacketLimit}");
    }

    private void Drop(Connection c, string reason)
    {
        connections.Remove(c.Peer);
        try { c.Assembler.Finish(); }
        catch (SyncProtocolException e) { log($"assembly ended error={e.Code}"); }
        c.Peer.Reject();
        log($"connection retired reason={reason}");
        Publish();
    }

    // Exception messages can contain paths or external input. Log only a fixed code/type.
    private static string Failure(Exception e) => e is SyncProtocolException p ? p.Code.ToString() : e.GetType().Name;
}
