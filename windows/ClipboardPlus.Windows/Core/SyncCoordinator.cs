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

public sealed record ClipboardSnapshot(uint Sequence, string? Text, bool Excluded, IReadOnlyList<ClipboardContent>? Contents = null);

public interface IClipboardAccess
{
    Task<uint> WriteTextAsync(string text);
    Task<uint> WriteItemAsync(HistoryItem item) => item.Kind == "text" ? WriteTextAsync(item.Text!) : throw new NotSupportedException();
}

public enum ClipboardRejectReason { ImageFormat, ImageDimensions, ImageCorrupt }

public sealed class ClipboardContentRejectedException(ClipboardRejectReason reason) : Exception(reason.ToString())
{
    public ClipboardRejectReason Reason { get; } = reason;
}

public sealed record SyncStatus(int Connected, int Pending, DateTimeOffset? LastSent, DateTimeOffset? LastReceived, bool Paired = true, IReadOnlyList<DeviceStatus>? Devices = null, IReadOnlyList<TransferProgress>? Transfers = null, bool RequiresPeerUpdate = false);

/// <summary>All protocol state is serialized here, independently of WinRT and the UI.</summary>
public sealed class SyncCoordinator(SyncPairing pairing, IClipboardAccess clipboard, Action<string> log, SyncRepository? repository = null, Func<DateTimeOffset>? clock = null) : IAsyncDisposable
{
    private sealed class Connection(SyncPairing pair, ISyncPeer peer, DateTimeOffset now)
    {
        public readonly ISyncPeer Peer = peer;
        // MTU can increase after subscribing. Validate the current limit at each write
        // without replacing an assembler which may already hold a partial frame.
        public SyncPacketAssembler Assembler = new(512, 50);
        public readonly Queue<byte[]> ControlFrames = new();
        public readonly List<Guid> AckQueue = [];
        public readonly Queue<SyncMessage> Replies = new();
        public readonly CancellationTokenSource Stop = new();
        public Task Outgoing = Task.CompletedTask;
        public bool Sending;
        public bool Retired;
        public Guid? InFlight;
        public Guid DeviceId;
        public readonly Dictionary<Guid, int> Offsets = [];
        public readonly Dictionary<Guid, int> AwaitingOffsets = [];
        public readonly HashSet<Guid> Attempted = [];
        public readonly HashSet<Guid> OfferedThisConnection = [];
        public readonly HashSet<Guid> ResumedAttachments = [];
        public readonly HashSet<Guid> FinalChunkSentAttachments = [];
        public TransferProgress? Progress;
        public bool VersionRejected;
        public readonly SyncPcHandshake Handshake = new(pair);
        public readonly Dictionary<Guid, PendingReply> Sent = [];
        public ulong NextIncomingFrameToken;
        public ulong? CurrentIncomingFrameToken;
        public int IncomingFrameBytes;
        public readonly DateTimeOffset Started = now;
        public DateTimeOffset LastPacket = now;
        public int Stage;
        public SyncFrameSender? Sender;
        public SyncFrameReceiver? Receiver;
    }

    private sealed record PendingReply(DateTimeOffset InitialSentAt, DateTimeOffset Deadline, ulong? AllowedFrameToken);

    private static readonly TimeSpan ReplyTimeout = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan MaxReplyExtension = TimeSpan.FromMinutes(3);
    private const int MinExtendableFrameBytes = 64;

    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Dictionary<ISyncPeer, Connection> connections = new(ReferenceEqualityComparer.Instance);
    private readonly SyncRepository store = repository ?? new SyncRepository(Path.Combine(Path.GetTempPath(), "clipboardplus-tests", Guid.NewGuid().ToString("N")), pairing.PcId);
    private readonly List<Guid> incompatibleDevices = [];
    private readonly HashSet<Guid> attempted = [];
    private readonly HashSet<Task> activeOutgoing = [];
    private bool stopped;
    private uint? ownSequence;
    private uint? lastClipboardSequence;
    private DateTimeOffset? lastSent, lastReceived;
    private DateTimeOffset Now() => clock?.Invoke() ?? DateTimeOffset.UtcNow;
    private bool RequiresPeerUpdate => incompatibleDevices.Count > 0;
    public event Action<SyncStatus>? Changed;

    private SyncStatus Snapshot() => new(connections.Values.Count(c => c.Stage == 2), store.PendingCount, lastSent, lastReceived, true,
        store.Devices.Select(d => new DeviceStatus(d.Id, d.Kind, connections.Values.Any(c => c.Stage == 2 && c.DeviceId == d.Id), d.LastConnected, store.Pending(d.Id).Count)).ToArray(),
        connections.Values.Select(c => c.Progress).OfType<TransferProgress>().ToArray(), RequiresPeerUpdate);
    private void Publish() { if (!stopped) Changed?.Invoke(Snapshot()); }
    public event Action? HistoryChanged;
    public async Task<SyncStatus> GetStatusAsync() { await gate.WaitAsync(); try { return Snapshot(); } finally { gate.Release(); } }
    public async Task<IReadOnlyList<HistoryItem>> GetHistoryAsync(string? search = null) { await gate.WaitAsync(); try { return store.List(search); } finally { gate.Release(); } }
    public async Task DeleteHistoryAsync(Guid id)
    {
        await gate.WaitAsync();
        try
        {
            if (stopped) return;
            store.Delete(id); TrimConnectionQueues();
            foreach (var c in connections.Values.Where(x => x.Stage == 2).ToArray()) StartSending(c);
            HistoryChanged?.Invoke(); Publish();
        }
        finally { gate.Release(); }
    }
    public async Task ClearHistoryAsync()
    {
        await gate.WaitAsync();
        try { if (stopped) return; store.ClearHistory(); TrimConnectionQueues(); HistoryChanged?.Invoke(); Publish(); }
        finally { gate.Release(); }
    }
    private void TrimConnectionQueues()
    {
        foreach (var c in connections.Values.Where(c => c.Stage == 2).ToArray())
        {
            var ids = store.Pending(c.DeviceId).Select(i => i.Id).ToHashSet();
            if (c.InFlight is Guid current && !ids.Contains(current)) { Drop(c, "pending item removed"); continue; }
            foreach (var id in c.Sent.Keys.Where(id => !ids.Contains(id)).ToArray()) c.Sent.Remove(id);
            foreach (var id in c.Offsets.Keys.Where(id => !ids.Contains(id)).ToArray()) c.Offsets.Remove(id);
            foreach (var id in c.AwaitingOffsets.Keys.Where(id => !ids.Contains(id)).ToArray()) c.AwaitingOffsets.Remove(id);
            c.Attempted.RemoveWhere(id => !ids.Contains(id));
            c.ResumedAttachments.RemoveWhere(id => !ids.Contains(id));
            c.FinalChunkSentAttachments.RemoveWhere(id => !ids.Contains(id));
            if (c.Progress is { Direction: "send" } s && !ids.Contains(s.ItemId)) c.Progress = null;
            if (c.Progress is { Direction: "receive" } r && store.Incoming(c.DeviceId, r.ItemId) is null) c.Progress = null;
        }
    }
    public async Task CopyHistoryAsync(Guid id) {
        await gate.WaitAsync(); try {
            if (stopped) return;
            var item = store.List().FirstOrDefault(i => i.Id == id) ?? throw new KeyNotFoundException();
            ownSequence = await clipboard.WriteItemAsync(item);
        } finally { gate.Release(); }
    }
    // These events carry immutable snapshots; WPF consumers post them with Dispatcher.BeginInvoke.
    private static string RejectReasonText(ClipboardRejectReason reason) => reason switch
    {
        ClipboardRejectReason.ImageFormat => "image-format",
        ClipboardRejectReason.ImageDimensions => "image-dimensions",
        ClipboardRejectReason.ImageCorrupt => "image-corrupt",
        _ => "content"
    };
    private async Task CommitAsync(Connection c, HistoryItem item) {
        var now = Now();
        var duplicate = store.Duplicate(item, c.DeviceId, now);
        c.Progress = new(c.DeviceId, "receive", item.Id, 1, 1, item.Size, item.Size); Publish();
        if (!duplicate)
        {
            try { ownSequence = await clipboard.WriteItemAsync(item); }
            catch (ClipboardContentRejectedException ex)
            {
                store.CommitRejected(c.DeviceId, item.Id);
                log($"received rejected reason={RejectReasonText(ex.Reason)}");
                QueueAck(c, item.Id); c.Progress = null;
                return;
            }
        }
        store.CommitReceived(item, c.DeviceId, now, duplicate);
        lastReceived = now;
        if (!duplicate) HistoryChanged?.Invoke();
        log(duplicate ? "duplicate content items=1" : $"received items=1 bytes={item.Size}");
        QueueAck(c, item.Id); c.Progress = null;
    }
    private string Source(Connection c) => store.Devices.First(d => d.Id == c.DeviceId).Kind == "phone" ? "iPhone" : "iPad";
    private async Task FinishIncomingAsync(Connection c, SyncOffer offer) {
        try
        {
            var item = store.Complete(c.DeviceId, offer, Source(c));
            await CommitAsync(c, item);
            store.DiscardPartial(c.DeviceId, offer.Id);
        }
        catch
        {
            c.Progress = null;
            try { store.DiscardPartial(c.DeviceId, offer.Id); }
            catch { /* Best effort cleanup before dropping connection. */ }
            throw;
        }
    }

    public async Task ConnectAsync(ISyncPeer peer)
    {
        await gate.WaitAsync();
        try
        {
            if (stopped) { peer.Reject(); return; }
            if (connections.ContainsKey(peer)) return;
            if (connections.Count >= 8) { peer.Reject(); return; }
            connections.Add(peer, new(pairing, peer, Now()));
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
            if (stopped || !connections.TryGetValue(peer, out var c)) return false;
            if (c.VersionRejected) return true;
            try
            {
                var wasPartial = c.Assembler.HasPartialFrame;
                c.LastPacket = Now();
                if (packet.Length > Math.Min(512, peer.PacketLimit)) throw new SyncProtocolException(SyncError.Packet);
                var frame = c.Assembler.Append(packet);
                ulong? frameToken = null;
                var payloadCount = Math.Max(0, packet.Length - 1);
                var frameBytes = payloadCount;
                if (!wasPartial)
                {
                    if (c.Assembler.HasPartialFrame)
                    {
                        c.NextIncomingFrameToken++;
                        c.CurrentIncomingFrameToken = c.NextIncomingFrameToken;
                        c.IncomingFrameBytes = payloadCount;
                        frameToken = c.CurrentIncomingFrameToken;
                        frameBytes = c.IncomingFrameBytes;
                    }
                }
                else if (c.Assembler.HasPartialFrame)
                {
                    c.IncomingFrameBytes += payloadCount;
                    frameToken = c.CurrentIncomingFrameToken;
                    frameBytes = c.IncomingFrameBytes;
                }
                else
                {
                    c.IncomingFrameBytes += payloadCount;
                    frameToken = c.CurrentIncomingFrameToken;
                    frameBytes = c.IncomingFrameBytes;
                    c.CurrentIncomingFrameToken = null;
                    c.IncomingFrameBytes = 0;
                }
                if (c.Stage == 2 && frame is null && frameToken is not null && frameBytes > MinExtendableFrameBytes)
                    ExtendReplyDeadlines(c, frameToken.Value, c.LastPacket);
                if (frame is null) return true;
                if (c.Stage == 0)
                {
                    if (frame.Length == 50 && frame[0] == 1 && frame[1] != SyncProtocol.Version) {
                        var candidateId = new Guid(frame.AsSpan(2, 16), bigEndian: true);
                        if (store.Devices.Any(d => d.Id == candidateId))
                        {
                            incompatibleDevices.Remove(candidateId);
                            if (incompatibleDevices.Count >= SyncProtocol.MaxPending) incompatibleDevices.RemoveAt(0);
                            incompatibleDevices.Add(candidateId);
                        }
                        c.VersionRejected = true;
                        // A full WELCOME-shaped version response with PC ID is readable by v1 peers too.
                        var mismatch = c.Handshake.CreateVersionMismatch();
                        c.ControlFrames.Enqueue(mismatch); StartSending(c); Publish(); return true;
                    }
                    c.ControlFrames.Enqueue(c.Handshake.AcceptHello(frame));
                    c.Assembler = new(512, 33);
                    c.Stage = 1;
                    log("handshake welcome");
                    StartSending(c);
                }
                else if (c.Stage == 1)
                {
                    var keys = c.Handshake.AcceptAuth(frame);
                    c.Sender = new(keys.PcToPad);
                    c.Receiver = new(keys.PadToPc);
                    c.Stage = 2;
                    c.DeviceId = c.Handshake.AuthenticatedPadId!.Value;
                    incompatibleDevices.Remove(c.DeviceId);
                    foreach (var old in connections.Values.Where(x => x != c && x.Stage == 2 && x.DeviceId == c.DeviceId).ToArray()) Drop(old, "replaced session");
                    var now = Now();
                    store.Register(c.DeviceId, null, now);
                    store.Prune(now);
                    TrimConnectionQueues();
                    c.Assembler = new(512);
                    log($"handshake authenticated elapsedMs={(now - c.Started).TotalMilliseconds:F0}");
                    foreach (var active in connections.Values.Where(x => x.Stage == 2).ToArray()) StartSending(active);
                }
                else
                {
                    var message = SyncMessageCodec.Decode(c.Receiver!.Open(frame));
                    if (frameToken is not null)
                    {
                        if (message is SyncPing or SyncPong)
                            RevertReplyExtension(c, frameToken.Value);
                        else
                        {
                            if (frameBytes > MinExtendableFrameBytes)
                                ExtendReplyDeadlines(c, frameToken.Value, c.LastPacket);
                            ClearAllowedFrameToken(c, frameToken.Value);
                        }
                    }
                    switch (message)
                    {
                        case SyncDevice device:
                            store.Register(c.DeviceId, device.Kind, Now()); break;
                        case SyncItem item:
                            if (item.From != "pad") throw new SyncProtocolException(SyncError.Format);
                            if (store.Seen(c.DeviceId, item.Id)) QueueAck(c, item.Id);
                            else await CommitAsync(c, store.Create(new("text", Text: item.Text), item.At, Source(c), item.Id));
                            break;
                        case SyncOffer offer:
                            if (offer.From != "pad") throw new SyncProtocolException(SyncError.Format);
                            if (store.Seen(c.DeviceId, offer.Id)) { QueueAck(c, offer.Id); break; }
                            if (!c.OfferedThisConnection.Add(offer.Id)) throw new SyncProtocolException(SyncError.State);
                            var offset = store.Begin(c.DeviceId, offer, Now());
                            c.Progress = new(c.DeviceId, "receive", offer.Id, 1, 1, offset, offer.Size);
                            if (offset == offer.Size) await FinishIncomingAsync(c, offer);
                            else QueueReply(c, new SyncResume(offer.Id, offset));
                            break;
                        case SyncChunk chunk:
                            if (store.Seen(c.DeviceId, chunk.Id)) { QueueAck(c, chunk.Id); break; }
                            var incoming = store.Incoming(c.DeviceId, chunk.Id) ?? throw new SyncProtocolException(SyncError.State);
                            var saved = store.Append(c.DeviceId, chunk);
                            c.Progress = new(c.DeviceId, "receive", chunk.Id, 1, 1, saved, incoming.Size);
                            if (saved == incoming.Size) await FinishIncomingAsync(c, incoming);
                            else QueueReply(c, new SyncResume(chunk.Id, saved));
                            break;
                        case SyncResume resume:
                            var queued = store.Pending(c.DeviceId).FirstOrDefault(i => i.Id == resume.Id);
                            if (queued is null) break; // Deleted or expired during transfer.
                            if (queued.Kind == "text" || resume.Offset >= queued.Size ||
                                !c.AwaitingOffsets.TryGetValue(resume.Id, out var expected) || (expected >= 0 && expected != resume.Offset))
                                throw new SyncProtocolException(SyncError.State);
                            c.AwaitingOffsets.Remove(resume.Id); c.Offsets[resume.Id] = resume.Offset;
                            c.Sent.Remove(resume.Id);
                            c.ResumedAttachments.Add(resume.Id); c.FinalChunkSentAttachments.Remove(resume.Id);
                            StartSending(c); break;
                        case SyncAck ack:
                            foreach (var id in ack.Ids)
                                if (c.ResumedAttachments.Contains(id) && !c.FinalChunkSentAttachments.Contains(id))
                                    throw new SyncProtocolException(SyncError.State);
                            var ids = ack.Ids.Where(id => c.Sent.ContainsKey(id) || c.InFlight == id || c.Offsets.ContainsKey(id) || c.AwaitingOffsets.ContainsKey(id) || c.Attempted.Contains(id)).ToHashSet();
                            store.Ack(c.DeviceId, ids);
                            foreach (var id in ids)
                            {
                                c.Sent.Remove(id); c.Offsets.Remove(id); c.AwaitingOffsets.Remove(id); c.Attempted.Remove(id);
                                c.ResumedAttachments.Remove(id); c.FinalChunkSentAttachments.Remove(id);
                            }
                            if (c.InFlight is Guid current && ids.Contains(current)) c.InFlight = null;
                            if (c.Progress is { Direction: "send" } p && ids.Contains(p.ItemId)) c.Progress = null;
                            log($"ack removed={ids.Count} pending={store.PendingCount}"); StartSending(c); break;
                        case SyncPing: QueueReply(c, new SyncPong()); break;
                        case SyncPong: break;
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
            if (stopped || snapshot.Sequence == lastClipboardSequence) return;
            lastClipboardSequence = snapshot.Sequence;
            if (snapshot.Sequence == ownSequence || snapshot.Excluded) return;
            var contents = snapshot.Contents ?? (snapshot.Text is null ? [] : new ClipboardContent[] { new("text", Text: snapshot.Text) });
            var skipped = 0;
            var now = Now();
            foreach (var content in contents) {
                try {
                    var item = store.Create(content, now.ToUnixTimeMilliseconds(), "PC");
                    if (item.Kind == "text") SyncMessageCodec.Encode(new SyncItem(item.Id, item.At, "pc", item.Text!));
                    else SyncMessageCodec.ValidateOffer(item.Offer);
                    store.AddAndEnqueue(item, now); HistoryChanged?.Invoke();
                } catch (SyncProtocolException) { skipped++; }
            }
            if (skipped > 0) log($"clipboard skipped items={skipped} reason=size-or-format");
            TrimConnectionQueues();
            log($"queued pending={store.PendingCount}");
            foreach (var c in connections.Values.ToArray())
            {
                if (c.Stage != 2) continue;
                try { StartSending(c); }
                catch (Exception e) { Drop(c, Failure(e)); }
            }
            Publish();
        }
        finally { gate.Release(); }
    }

    public async Task DisconnectAsync(ISyncPeer peer)
    {
        await gate.WaitAsync();
        try { if (!stopped && connections.TryGetValue(peer, out var c)) Drop(c, "disconnected"); }
        finally { gate.Release(); }
    }

    public async Task TickAsync(DateTimeOffset now)
    {
        await gate.WaitAsync();
        try
        {
            if (stopped) return;
            store.Prune(now);
            TrimConnectionQueues();
            foreach (var c in connections.Values.ToArray())
            {
                if ((c.Stage < 2 && now - c.Started > TimeSpan.FromSeconds(20)) ||
                    (c.Assembler.HasPartialFrame && now - c.LastPacket > TimeSpan.FromSeconds(20)))
                    Drop(c, "receive timeout");
                else if (c.Stage == 2)
                {
                    // An attachment whose 60-second reply deadline expires drops the connection so the
                    // next session restarts cleanly from offer; text items may resend on the same link.
                    var expired = c.Sent.Where(p => p.Key != c.InFlight && now > p.Value.Deadline).Select(p => p.Key).ToArray();
                    if (expired.Any(id => c.AwaitingOffsets.ContainsKey(id) || c.Offsets.ContainsKey(id) ||
                        store.Pending(c.DeviceId).FirstOrDefault(i => i.Id == id)?.Kind is "image" or "file"))
                    {
                        Drop(c, "attachment timeout");
                        continue;
                    }
                    foreach (var id in expired) c.Sent.Remove(id);
                    try { StartSending(c); }
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
        try { if (!stopped) foreach (var c in connections.Values.ToArray()) Drop(c, "stopped"); }
        finally { gate.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        await gate.WaitAsync();
        try
        {
            if (!stopped)
            {
                stopped = true;
                foreach (var c in connections.Values.ToArray()) Drop(c, "stopped");
            }
        }
        finally { gate.Release(); }
        while (true)
        {
            Task[] tasks;
            lock (activeOutgoing) tasks = activeOutgoing.ToArray();
            if (tasks.Length == 0) break;
            await Task.WhenAll(tasks);
        }
    }

    // Only selection/sealing uses gate; notification I/O never holds it.
    private void StartSending(Connection c)
    {
        if (c.Sending || c.Retired || stopped) return;
        c.Sending = true;
        lock (activeOutgoing)
        {
            Task? task = null;
            task = Task.Run(async () =>
            {
                try { await SendLoopAsync(c); }
                finally { lock (activeOutgoing) activeOutgoing.Remove(task!); }
            });
            c.Outgoing = task;
            activeOutgoing.Add(task);
        }
    }

    private void QueueAck(Connection c, Guid id)
    {
        if (c.AckQueue.Contains(id)) return;
        if (c.AckQueue.Count >= SyncProtocol.MaxAckIds * 4) throw new SyncProtocolException(SyncError.Limit);
        c.AckQueue.Add(id);
        StartSending(c);
    }

    private void QueueReply(Connection c, SyncMessage message)
    {
        if (c.Replies.Count >= 64) throw new SyncProtocolException(SyncError.Limit);
        c.Replies.Enqueue(message);
        StartSending(c);
    }

    // Test synchronization only. Production must not wait for the sender to become idle.
    internal async Task WaitForOutgoingAsync(ISyncPeer? peer = null)
    {
        Task[] tasks;
        await gate.WaitAsync();
        try { tasks = connections.Values.Where(c => peer is null || c.Peer == peer).Select(c => c.Outgoing).ToArray(); }
        finally { gate.Release(); }
        await Task.WhenAll(tasks).WaitAsync(TimeSpan.FromSeconds(5));
    }

    private async Task SendLoopAsync(Connection c)
    {
        try
        {
            while (true)
            {
                byte[] frame;
                HistoryItem? item = null;
                var finishesItem = false;
                var retransmission = false;
                await gate.WaitAsync();
                try
                {
                    if (c.Retired) return;
                    var attachmentBusy = c.AwaitingOffsets.Count > 0 || c.Offsets.Count > 0;
                    if (c.ControlFrames.TryDequeue(out var control)) frame = control;
                    else if (c.Stage == 2 && c.AckQueue.Count > 0)
                    {
                        var count = Math.Min(c.AckQueue.Count, SyncProtocol.MaxAckIds);
                        var ids = c.AckQueue.GetRange(0, count);
                        c.AckQueue.RemoveRange(0, count);
                        frame = c.Sender!.Seal(SyncMessageCodec.Encode(new SyncAck(ids)));
                    }
                    else if (c.Stage == 2 && c.Replies.TryDequeue(out var reply))
                        frame = c.Sender!.Seal(SyncMessageCodec.Encode(reply));
                    else if (c.Stage == 2 && (item = store.Pending(c.DeviceId).FirstOrDefault(i =>
                        !c.Sent.ContainsKey(i.Id) &&
                        (i.Kind == "text" || !attachmentBusy || c.Offsets.ContainsKey(i.Id)))) is not null)
                    {
                        SyncMessage message;
                        if (item.Kind == "text") {
                            message = new SyncItem(item.Id, item.At, "pc", item.Text!); finishesItem = true;
                            c.Progress = new(c.DeviceId, "send", item.Id, store.Pending(c.DeviceId).IndexOf(item) + 1, store.Pending(c.DeviceId).Count, item.Size, item.Size);
                        }
                        else if (c.Offsets.Remove(item.Id, out var offset)) {
                            if (offset >= item.Size) throw new SyncProtocolException(SyncError.State);
                            using var file = File.OpenRead(item.Path!); file.Position = offset;
                            var data = new byte[Math.Min(SyncProtocol.ChunkBytes, item.Size - offset)]; file.ReadExactly(data);
                            message = new SyncChunk(item.Id, offset, data);
                            c.AwaitingOffsets[item.Id] = offset + data.Length; finishesItem = offset + data.Length == item.Size;
                            c.Progress = new(c.DeviceId, "send", item.Id, store.Pending(c.DeviceId).IndexOf(item) + 1, store.Pending(c.DeviceId).Count, offset + data.Length, item.Size);
                        } else { message = item.Offer; c.AwaitingOffsets[item.Id] = -1; finishesItem = item.Size == 0; }
                        // Mark before I/O: resume/ack may arrive before notification completion.
                        var sentNow = Now();
                        c.Sent[item.Id] = new(sentNow, sentNow + ReplyTimeout, c.CurrentIncomingFrameToken);
                        c.Attempted.Add(item.Id);
                        store.MarkSent(item, sentNow);
                        frame = c.Sender!.Seal(SyncMessageCodec.Encode(message));
                        retransmission = !attempted.Add(item.Id);
                        c.InFlight = item.Id;
                    }
                    else { c.Sending = false; return; }
                }
                finally { gate.Release(); }

                var watch = Stopwatch.StartNew();
                var packets = SyncPacketizer.Split(frame, Math.Min(512, c.Peer.PacketLimit));
                for (var packetIndex = 0; packetIndex < packets.Count; packetIndex++)
                {
                    c.Stop.Token.ThrowIfCancellationRequested();
                    if (packetIndex == packets.Count - 1 && item is not null && finishesItem && item.Kind != "text")
                    {
                        await gate.WaitAsync();
                        try
                        {
                            if (c.Retired) return;
                            if (c.ResumedAttachments.Contains(item.Id)) c.FinalChunkSentAttachments.Add(item.Id);
                        }
                        finally { gate.Release(); }
                    }
                    await c.Peer.SendPacketAsync(packets[packetIndex]).WaitAsync(TimeSpan.FromSeconds(10), c.Stop.Token);
                }
                await gate.WaitAsync();
                try
                {
                    if (c.Retired) return;
                    // An ACK may arrive before NotifyValueAsync completes.
                    if (item is not null)
                    {
                        if ((item.Kind == "text" || c.AwaitingOffsets.ContainsKey(item.Id)) && store.Pending(c.DeviceId).Any(i => i.Id == item.Id))
                        {
                            var completedNow = Now();
                            c.Sent[item.Id] = new(completedNow, completedNow + ReplyTimeout, c.CurrentIncomingFrameToken);
                        }
                        c.InFlight = null;
                        if (finishesItem) lastSent = Now();
                        log($"sent items=1 resend={retransmission} pending={store.PendingCount}");
                    }
                    log($"notify packets={packets.Count} bytes={frame.Length} elapsedMs={watch.ElapsedMilliseconds}");
                    if (c.VersionRejected) { Drop(c, "version mismatch; update peer"); return; }
                    Publish();
                }
                finally { gate.Release(); }
            }
        }
        catch (Exception e)
        {
            await gate.WaitAsync();
            try { if (!c.Retired) Drop(c, Failure(e)); }
            finally { gate.Release(); }
        }
    }

    private void Drop(Connection c, string reason)
    {
        c.Retired = true;
        c.Stop.Cancel();
        c.ControlFrames.Clear(); c.AckQueue.Clear(); c.Replies.Clear(); c.Sent.Clear();
        c.Offsets.Clear(); c.AwaitingOffsets.Clear(); c.OfferedThisConnection.Clear();
        c.ResumedAttachments.Clear(); c.FinalChunkSentAttachments.Clear(); c.Progress = null;
        connections.Remove(c.Peer);
        attempted.RemoveWhere(id => !store.Devices.Any(d => store.Pending(d.Id).Any(i => i.Id == id)));
        try { c.Assembler.Finish(); }
        catch (SyncProtocolException e) { log($"assembly ended error={e.Code}"); }
        c.Peer.Reject();
        log($"connection retired reason={reason}");
        Publish();
    }

    private static void ExtendReplyDeadlines(Connection c, ulong frameToken, DateTimeOffset now)
    {
        var candidate = now + ReplyTimeout;
        foreach (var id in c.Sent.Keys.ToArray())
        {
            var entry = c.Sent[id];
            if (entry.AllowedFrameToken != frameToken) continue;
            var maxDeadline = entry.InitialSentAt + ReplyTimeout + MaxReplyExtension;
            var updated = candidate > maxDeadline ? maxDeadline : candidate;
            if (updated > entry.Deadline)
                c.Sent[id] = entry with { Deadline = updated };
        }
    }

    private static void RevertReplyExtension(Connection c, ulong frameToken)
    {
        foreach (var id in c.Sent.Keys.ToArray())
        {
            var entry = c.Sent[id];
            if (entry.AllowedFrameToken == frameToken)
                c.Sent[id] = entry with { Deadline = entry.InitialSentAt + ReplyTimeout, AllowedFrameToken = null };
        }
    }

    private static void ClearAllowedFrameToken(Connection c, ulong frameToken)
    {
        foreach (var id in c.Sent.Keys.ToArray())
        {
            var entry = c.Sent[id];
            if (entry.AllowedFrameToken == frameToken)
                c.Sent[id] = entry with { AllowedFrameToken = null };
        }
    }

    // Exception messages can contain paths or external input. Log only a fixed code/type.
    private static string Failure(Exception e) => e is SyncProtocolException p ? p.Code.ToString() : e.GetType().Name;
}
