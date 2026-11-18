using System.Diagnostics;
using ClipboardPlus.Sync;

namespace ClipboardPlus.Windows.Core;

public interface ISyncPeer
{
    int PacketLimit { get; }
    Task SendPacketAsync(byte[] packet);
    // Retire this connection, including after a protocol/notification failure.
    void Reject();
    void SetHighThroughput(bool enabled) { }
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
        public AttachmentTransfer? ActiveAttachment;
        public readonly HashSet<Guid> ActiveIncomingAttachments = [];
        public readonly Dictionary<Guid, AttachmentReceive> AttachmentReceives = [];
        public bool HighThroughputRequested;
        public DateTimeOffset LastAttachmentActivity = now;
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

    private sealed record PendingChunk(int EndOffset, DateTimeOffset? CompletedAt);
    private sealed class AttachmentTransfer(Guid id, int size, DateTimeOffset startedAt)
    {
        public readonly Guid Id = id;
        public readonly int Size = size;
        public readonly DateTimeOffset StartedAt = startedAt;
        public bool AwaitingInitialResume = true;
        public int NextSendOffset;
        public int AckedOffset;
        public int StartOffset;
        public readonly List<PendingChunk> Chunks = [];
        public bool CanSendChunk => !AwaitingInitialResume && NextSendOffset < Size && Chunks.Count < MaxAttachmentChunksInFlight;
    }
    private sealed record AttachmentReceive(DateTimeOffset StartedAt, int StartOffset);
    private sealed record PendingReply(DateTimeOffset InitialSentAt, DateTimeOffset Deadline, DateTimeOffset BaselineDeadline, ulong? ActiveFrameToken);

    private const int MaxAttachmentChunksInFlight = 4;
    private static readonly TimeSpan HighThroughputIdleGrace = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan ReplyTimeout = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan MaxReplyExtension = TimeSpan.FromMinutes(3);
    private static readonly TimeSpan PruneInterval = TimeSpan.FromMinutes(1);
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
    private DateTimeOffset lastPrune = DateTimeOffset.MinValue;
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
            if (c.ActiveAttachment is { } att && !ids.Contains(att.Id)) c.ActiveAttachment = null;
            c.ActiveIncomingAttachments.RemoveWhere(id => store.Incoming(c.DeviceId, id) is null);
            foreach (var id in c.AttachmentReceives.Keys.Where(id => store.Incoming(c.DeviceId, id) is null).ToArray()) c.AttachmentReceives.Remove(id);
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
        AttachmentReceive? rx = null;
        if (item.Kind != "text")
        {
            c.ActiveIncomingAttachments.Remove(item.Id);
            c.AttachmentReceives.Remove(item.Id, out rx);
            c.LastAttachmentActivity = now;
        }
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
        if (item.Kind != "text")
        {
            var elapsedMs = rx is null ? 0 : Math.Max(0, (now - rx.StartedAt).TotalMilliseconds);
            var transferred = rx is null ? item.Size : Math.Max(0, item.Size - rx.StartOffset);
            var kbps = elapsedMs > 0 ? (transferred / 1024.0) / (elapsedMs / 1000.0) : 0.0;
            log($"attachment received bytes={item.Size} elapsedMs={elapsedMs:F0} speedKBps={kbps:F1}");
        }
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
            c.ActiveIncomingAttachments.Remove(offer.Id);
            c.AttachmentReceives.Remove(offer.Id);
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
                ulong frameToken;
                var payloadCount = Math.Max(0, packet.Length - 1);
                int frameBytes;
                if (!wasPartial)
                {
                    c.NextIncomingFrameToken++;
                    frameToken = c.NextIncomingFrameToken;
                    frameBytes = payloadCount;
                    if (c.Assembler.HasPartialFrame)
                    {
                        c.CurrentIncomingFrameToken = frameToken;
                        c.IncomingFrameBytes = payloadCount;
                    }
                }
                else if (c.Assembler.HasPartialFrame)
                {
                    c.IncomingFrameBytes += payloadCount;
                    frameToken = c.CurrentIncomingFrameToken ?? c.NextIncomingFrameToken;
                    frameBytes = c.IncomingFrameBytes;
                }
                else
                {
                    c.IncomingFrameBytes += payloadCount;
                    frameToken = c.CurrentIncomingFrameToken ?? c.NextIncomingFrameToken;
                    frameBytes = c.IncomingFrameBytes;
                    c.CurrentIncomingFrameToken = null;
                    c.IncomingFrameBytes = 0;
                }
                if (c.Stage == 2 && frame is null && frameBytes > MinExtendableFrameBytes)
                    ExtendReplyDeadlines(c, frameToken, c.LastPacket);
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
                    lastPrune = now;
                    TrimConnectionQueues();
                    c.Assembler = new(512);
                    log($"handshake authenticated elapsedMs={(now - c.Started).TotalMilliseconds:F0}");
                    foreach (var active in connections.Values.Where(x => x.Stage == 2).ToArray()) StartSending(active);
                }
                else
                {
                    var message = SyncMessageCodec.Decode(c.Receiver!.Open(frame));
                    if (message is SyncPing or SyncPong)
                        RevertReplyExtension(c, frameToken);
                    else
                    {
                        if (frameBytes > MinExtendableFrameBytes)
                            ExtendReplyDeadlines(c, frameToken, c.LastPacket);
                        ConfirmReplyExtension(c, frameToken);
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
                            var offerNow = Now();
                            var offset = store.Begin(c.DeviceId, offer, offerNow);
                            c.Progress = new(c.DeviceId, "receive", offer.Id, 1, 1, offset, offer.Size);
                            c.AttachmentReceives[offer.Id] = new(offerNow, offset);
                            if (offset == offer.Size) await FinishIncomingAsync(c, offer);
                            else
                            {
                                c.ActiveIncomingAttachments.Add(offer.Id);
                                EnableHighThroughput(c, offerNow);
                                QueueReply(c, new SyncResume(offer.Id, offset));
                            }
                            break;
                        case SyncChunk chunk:
                            if (store.Seen(c.DeviceId, chunk.Id)) { QueueAck(c, chunk.Id); break; }
                            var incoming = store.Incoming(c.DeviceId, chunk.Id) ?? throw new SyncProtocolException(SyncError.State);
                            var saved = store.Append(c.DeviceId, chunk);
                            c.LastAttachmentActivity = c.LastPacket;
                            c.Progress = new(c.DeviceId, "receive", chunk.Id, 1, 1, saved, incoming.Size);
                            if (saved == incoming.Size) await FinishIncomingAsync(c, incoming);
                            else QueueReply(c, new SyncResume(chunk.Id, saved));
                            break;
                        case SyncResume resume:
                            var queued = store.Pending(c.DeviceId).FirstOrDefault(i => i.Id == resume.Id);
                            if (queued is null) break; // Deleted or expired during transfer.
                            if (queued.Kind == "text" || resume.Offset >= queued.Size || c.ActiveAttachment?.Id != resume.Id)
                                throw new SyncProtocolException(SyncError.State);
                            var att = c.ActiveAttachment;
                            if (att.AwaitingInitialResume)
                            {
                                att.AwaitingInitialResume = false;
                                att.AckedOffset = resume.Offset;
                                att.NextSendOffset = resume.Offset;
                                att.StartOffset = resume.Offset;
                                c.Sent.Remove(resume.Id);
                                c.FinalChunkSentAttachments.Remove(resume.Id);
                            }
                            else
                            {
                                var idx = att.Chunks.FindIndex(ch => ch.EndOffset == resume.Offset);
                                if (idx < 0) throw new SyncProtocolException(SyncError.State);
                                att.Chunks.RemoveRange(0, idx + 1);
                                att.AckedOffset = resume.Offset;
                                if (att.Chunks.Count > 0 && att.Chunks[0].CompletedAt is DateTimeOffset frontAt)
                                {
                                    var baseDeadline = frontAt + ReplyTimeout;
                                    var maxDeadline = frontAt + ReplyTimeout + MaxReplyExtension;
                                    var deadline = c.Sent.TryGetValue(resume.Id, out var prev) && prev.ActiveFrameToken is not null && prev.Deadline > baseDeadline
                                        ? (prev.Deadline > maxDeadline ? maxDeadline : prev.Deadline)
                                        : baseDeadline;
                                    c.Sent[resume.Id] = new(frontAt, deadline, baseDeadline, prev?.ActiveFrameToken);
                                }
                                else c.Sent.Remove(resume.Id);
                            }
                            c.ResumedAttachments.Add(resume.Id);
                            c.LastAttachmentActivity = Now();
                            StartSending(c); break;
                        case SyncAck ack:
                            foreach (var id in ack.Ids)
                                if (c.ResumedAttachments.Contains(id) && !c.FinalChunkSentAttachments.Contains(id))
                                    throw new SyncProtocolException(SyncError.State);
                            var ids = ack.Ids.Where(id => c.Sent.ContainsKey(id) || c.InFlight == id || c.ActiveAttachment?.Id == id || c.Attempted.Contains(id)).ToHashSet();
                            store.Ack(c.DeviceId, ids);
                            if (c.ActiveAttachment is { } activeAtt && ids.Contains(activeAtt.Id))
                            {
                                var ackNow = Now();
                                var elapsedMs = Math.Max(0, (ackNow - activeAtt.StartedAt).TotalMilliseconds);
                                var transferred = c.ResumedAttachments.Contains(activeAtt.Id)
                                    ? Math.Max(0, activeAtt.Size - activeAtt.StartOffset)
                                    : 0;
                                var kbps = elapsedMs > 0 ? (transferred / 1024.0) / (elapsedMs / 1000.0) : 0.0;
                                log($"attachment sent bytes={activeAtt.Size} elapsedMs={elapsedMs:F0} speedKBps={kbps:F1}");
                                c.ActiveAttachment = null;
                                c.LastAttachmentActivity = ackNow;
                            }
                            foreach (var id in ids)
                            {
                                c.Sent.Remove(id); c.Attempted.Remove(id);
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
            var cutoff = now.Subtract(SyncProtocol.PendingLifetime).ToUnixTimeMilliseconds();
            var hasExpiredPending = store.Devices.Any(d => store.Pending(d.Id).Any(i => i.At < cutoff));
            if (hasExpiredPending || lastPrune == DateTimeOffset.MinValue || now < lastPrune || now - lastPrune >= PruneInterval)
            {
                store.Prune(now);
                lastPrune = now;
                TrimConnectionQueues();
            }
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
                    if (expired.Any(id => c.ActiveAttachment?.Id == id ||
                        store.Pending(c.DeviceId).FirstOrDefault(i => i.Id == id)?.Kind is "image" or "file"))
                    {
                        Drop(c, "attachment timeout");
                        continue;
                    }
                    foreach (var id in expired) c.Sent.Remove(id);
                    if (c.HighThroughputRequested && c.ActiveAttachment is null && c.ActiveIncomingAttachments.Count == 0 &&
                        now - c.LastAttachmentActivity >= HighThroughputIdleGrace)
                    {
                        c.HighThroughputRequested = false;
                        c.Peer.SetHighThroughput(false);
                    }
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
                var isChunk = false;
                int? chunkEndOffset = null;
                await gate.WaitAsync();
                try
                {
                    if (c.Retired) return;
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
                    else
                    {
                        var pendingList = store.Pending(c.DeviceId);
                        if (c.Stage == 2 && (item = pendingList.FirstOrDefault(i =>
                            i.Kind == "text"
                                ? !c.Sent.ContainsKey(i.Id)
                                : (c.ActiveAttachment is null ? !c.Sent.ContainsKey(i.Id) : c.ActiveAttachment.Id == i.Id && c.ActiveAttachment.CanSendChunk))) is not null)
                        {
                            SyncMessage message;
                            var sentNow = Now();
                            var itemIndex = pendingList.IndexOf(item) + 1;
                            var itemCount = pendingList.Count;
                            if (item.Kind == "text")
                            {
                                message = new SyncItem(item.Id, item.At, "pc", item.Text!);
                                finishesItem = true;
                                c.Progress = new(c.DeviceId, "send", item.Id, itemIndex, itemCount, item.Size, item.Size);
                                var initialDeadline = sentNow + ReplyTimeout;
                                c.Sent[item.Id] = new(sentNow, initialDeadline, initialDeadline, null);
                                store.MarkSent(item, sentNow);
                            }
                            else if (c.ActiveAttachment is { } att)
                            {
                                isChunk = true;
                                var offset = att.NextSendOffset;
                                if (offset >= item.Size) throw new SyncProtocolException(SyncError.State);
                                byte[] data;
                                using (var file = File.OpenRead(item.Path!))
                                {
                                    file.Position = offset;
                                    data = new byte[Math.Min(SyncProtocol.ChunkBytes, item.Size - offset)];
                                    file.ReadExactly(data);
                                }
                                message = new SyncChunk(item.Id, offset, data);
                                var end = offset + data.Length;
                                att.NextSendOffset = end;
                                att.Chunks.Add(new(end, null));
                                chunkEndOffset = end;
                                finishesItem = end == item.Size;
                                c.Progress = new(c.DeviceId, "send", item.Id, itemIndex, itemCount, end, item.Size);
                                c.LastAttachmentActivity = sentNow;
                                if (!c.Sent.ContainsKey(item.Id))
                                {
                                    var initialDeadline = sentNow + ReplyTimeout;
                                    c.Sent[item.Id] = new(sentNow, initialDeadline, initialDeadline, null);
                                }
                            }
                            else
                            {
                                message = item.Offer;
                                c.ActiveAttachment = new(item.Id, item.Size, sentNow);
                                finishesItem = item.Size == 0;
                                var initialDeadline = sentNow + ReplyTimeout;
                                c.Sent[item.Id] = new(sentNow, initialDeadline, initialDeadline, null);
                                store.MarkSent(item, sentNow);
                                if (item.Size > 0) EnableHighThroughput(c, sentNow);
                            }
                            c.Attempted.Add(item.Id);
                            frame = c.Sender!.Seal(SyncMessageCodec.Encode(message));
                            retransmission = !attempted.Add(item.Id);
                            c.InFlight = item.Id;
                        }
                        else { c.Sending = false; return; }
                    }
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
                    var sendTask = c.Peer.SendPacketAsync(packets[packetIndex]);
                    if (!sendTask.IsCompleted)
                        await sendTask.WaitAsync(TimeSpan.FromSeconds(10), c.Stop.Token);
                    else
                        await sendTask;
                }
                await gate.WaitAsync();
                try
                {
                    if (c.Retired) return;
                    // An ACK may arrive before NotifyValueAsync completes.
                    if (item is not null)
                    {
                        var stillPending = store.Pending(c.DeviceId).Any(i => i.Id == item.Id);
                        if (item.Kind == "text")
                        {
                            if (stillPending && c.Sent.ContainsKey(item.Id))
                            {
                                var completedNow = Now();
                                var completedDeadline = completedNow + ReplyTimeout;
                                c.Sent[item.Id] = new(completedNow, completedDeadline, completedDeadline, null);
                            }
                            c.InFlight = null;
                            lastSent = Now();
                            log($"sent items=1 resend={retransmission} pending={store.PendingCount}");
                        }
                        else if (isChunk)
                        {
                            if (stillPending && c.ActiveAttachment is { } att && att.Id == item.Id && chunkEndOffset is int end)
                            {
                                var idx = att.Chunks.FindIndex(ch => ch.EndOffset == end);
                                if (idx >= 0)
                                {
                                    var completedNow = Now();
                                    att.Chunks[idx] = att.Chunks[idx] with { CompletedAt = completedNow };
                                    if (idx == 0)
                                    {
                                        var completedDeadline = completedNow + ReplyTimeout;
                                        c.Sent[item.Id] = new(completedNow, completedDeadline, completedDeadline, null);
                                    }
                                }
                            }
                            c.InFlight = null;
                            if (finishesItem) lastSent = Now();
                        }
                        else
                        {
                            if (stillPending && c.ActiveAttachment is { } att && att.Id == item.Id && (att.AwaitingInitialResume || item.Size == 0))
                            {
                                var completedNow = Now();
                                var completedDeadline = completedNow + ReplyTimeout;
                                c.Sent[item.Id] = new(completedNow, completedDeadline, completedDeadline, null);
                            }
                            c.InFlight = null;
                            if (finishesItem) lastSent = Now();
                            log($"sent items=1 resend={retransmission} pending={store.PendingCount}");
                        }
                    }
                    if (!isChunk)
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

    private static void EnableHighThroughput(Connection c, DateTimeOffset now)
    {
        c.LastAttachmentActivity = now;
        if (c.HighThroughputRequested) return;
        c.HighThroughputRequested = true;
        c.Peer.SetHighThroughput(true);
    }

    private void Drop(Connection c, string reason)
    {
        c.Retired = true;
        c.Stop.Cancel();
        c.ControlFrames.Clear(); c.AckQueue.Clear(); c.Replies.Clear(); c.Sent.Clear();
        c.ActiveAttachment = null; c.ActiveIncomingAttachments.Clear(); c.AttachmentReceives.Clear();
        c.OfferedThisConnection.Clear(); c.ResumedAttachments.Clear(); c.FinalChunkSentAttachments.Clear(); c.Progress = null;
        if (c.HighThroughputRequested) { c.HighThroughputRequested = false; c.Peer.SetHighThroughput(false); }
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
            if (entry.ActiveFrameToken != frameToken)
                entry = entry with { BaselineDeadline = entry.Deadline, ActiveFrameToken = frameToken };
            var maxDeadline = entry.InitialSentAt + ReplyTimeout + MaxReplyExtension;
            var updated = candidate > maxDeadline ? maxDeadline : candidate;
            if (updated > entry.Deadline)
                entry = entry with { Deadline = updated };
            c.Sent[id] = entry;
        }
    }

    private static void RevertReplyExtension(Connection c, ulong frameToken)
    {
        foreach (var id in c.Sent.Keys.ToArray())
        {
            var entry = c.Sent[id];
            if (entry.ActiveFrameToken == frameToken)
                c.Sent[id] = entry with { Deadline = entry.BaselineDeadline, ActiveFrameToken = null };
        }
    }

    private static void ConfirmReplyExtension(Connection c, ulong frameToken)
    {
        foreach (var id in c.Sent.Keys.ToArray())
        {
            var entry = c.Sent[id];
            if (entry.ActiveFrameToken == frameToken)
                c.Sent[id] = entry with { BaselineDeadline = entry.Deadline, ActiveFrameToken = null };
        }
    }

    // Exception messages can contain paths or external input. Log only a fixed code/type.
    private static string Failure(Exception e) => e is SyncProtocolException p ? p.Code.ToString() : e.GetType().Name;
}
