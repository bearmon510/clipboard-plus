using System.Buffers.Binary;
using System.Diagnostics;
using System.Text.Json;
using ClipboardPlus.Sync;

namespace ClipboardPlus.Windows.Core;

public interface ISyncPeer
{
    int PacketLimit { get; }
    bool IsRejected => false;
    Task SendPacketAsync(byte[] packet);
    // Retire this connection, including after a protocol/notification failure.
    void Reject();
    void SetHighThroughput(bool enabled) { }
}

public sealed record ClipboardSnapshot(uint Sequence, string? Text, bool Excluded, IReadOnlyList<ClipboardContent>? Contents = null);

public readonly record struct LocalAddResult(int Added, int Skipped);

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
public sealed class SyncCoordinator(SyncPairing pairing, IClipboardAccess clipboard, Action<string> log, SyncRepository? repository = null, Func<DateTimeOffset>? clock = null, TemplateRepository? templateRepository = null) : IAsyncDisposable
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
        public readonly Queue<TemplateSyncMessage> TemplateMessages = new();
        public TemplateSyncPageAssembler? IncomingTemplatePush;
        public readonly Dictionary<Guid, DateTimeOffset> AwaitingPeerTemplateAcks = [];
        public bool SendingTemplateMessage;
        public readonly CancellationTokenSource Stop = new();
        public readonly SemaphoreSlim HandoffGate = new(1, 1);
        public readonly object HandoffStateGate = new();
        public Task Outgoing = Task.CompletedTask;
        public bool Sending;
        public volatile bool Retired;
        public Guid? InFlight;
        public Guid DeviceId;
        public AttachmentTransfer? ActiveAttachment;
        public readonly Dictionary<Guid, DateTimeOffset> ActiveIncomingAttachments = [];
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

    private sealed record PendingChunk(int EndOffset, bool HandedOffLastPacket, PendingReply? Reply);
    private sealed class AttachmentTransfer(Guid id, int size, DateTimeOffset startedAt)
    {
        public readonly Guid Id = id;
        public readonly int Size = size;
        public readonly DateTimeOffset StartedAt = startedAt;
        public DateTimeOffset LastActivity = startedAt;
        public bool AwaitingInitialResume = true;
        public bool HandedOffOfferLastPacket;
        public int NextSendOffset;
        public int AckedOffset;
        public int StartOffset;
        public readonly List<PendingChunk> Chunks = [];
        public bool CanSendChunk => !AwaitingInitialResume && NextSendOffset < Size && Chunks.Count < MaxAttachmentChunksInFlight;
    }
    private sealed record AttachmentReceive(DateTimeOffset StartedAt, int StartOffset);
    private sealed record PendingReply(DateTimeOffset InitialSentAt, DateTimeOffset Deadline, DateTimeOffset BaselineDeadline, ulong? ActiveFrameToken);

    private enum TemplateSyncPhase { Collecting, Distributing }
    private enum ParticipantState { AwaitingPush, PushReceived, AwaitingAck, AckReceived, Dropped, TimedOut }

    private sealed class ParticipantProgress(Connection connection, DateTimeOffset startedAt, DateTimeOffset deadline)
    {
        public readonly Connection Connection = connection;
        public readonly Guid DeviceId = connection.DeviceId;
        public ParticipantState State = ParticipantState.AwaitingPush;
        public TemplateSyncSnapshot? PushSnapshot;
        public DateTimeOffset InitialSentAt = startedAt;
        public DateTimeOffset Deadline = deadline;
        public DateTimeOffset BaselineDeadline = deadline;
        public ulong? ActiveFrameToken;
    }

    private sealed class TemplateSyncSession(Guid op, DateTimeOffset startedAt, List<ParticipantProgress> participants)
    {
        public readonly Guid Op = op;
        public readonly DateTimeOffset StartedAt = startedAt;
        public TemplateSyncPhase Phase = TemplateSyncPhase.Collecting;
        public readonly List<ParticipantProgress> Participants = participants;
        public readonly TaskCompletionSource<TemplateSyncRunResult> Completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TemplateSyncSideChanges? PcChanges;
        public int RemoteChangesTotal;
        public int ConflictCopyCount;
        public long? ClockSkewSeconds;
        public bool PcSaved;
    }

    private const int MaxAttachmentChunksInFlight = 4;
    private const int MaxQueuedTemplateMessages = SyncProtocol.MaxTemplatePages * 4;
    private static readonly TimeSpan HighThroughputIdleGrace = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan ReplyTimeout = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan TemplateSyncTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan MaxReplyExtension = TimeSpan.FromMinutes(3);
    private static readonly TimeSpan PruneInterval = TimeSpan.FromMinutes(1);
    private const int MinExtendableFrameBytes = 64;

    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Dictionary<ISyncPeer, Connection> connections = new(ReferenceEqualityComparer.Instance);
    private readonly SyncRepository store = repository ?? new SyncRepository(Path.Combine(Path.GetTempPath(), "clipboardplus-tests", Guid.NewGuid().ToString("N")), pairing.PcId);
    private readonly TemplateRepository templateStore = templateRepository ?? new TemplateRepository(Path.Combine(Path.GetTempPath(), "clipboardplus-tests", Guid.NewGuid().ToString("N")), log);
    private readonly List<Guid> incompatibleDevices = [];
    private readonly HashSet<Guid> attempted = [];
    private readonly HashSet<Task> activeOutgoing = [];
    private TemplateSyncSession? activeTemplateSync;
    private bool stopped;
    private uint? ownSequence;
    private uint? lastClipboardSequence;
    private DateTimeOffset? lastSent, lastReceived;
    private DateTimeOffset lastPrune = DateTimeOffset.MinValue;
    private DateTimeOffset Now() => clock?.Invoke() ?? DateTimeOffset.UtcNow;
    private bool RequiresPeerUpdate => incompatibleDevices.Count > 0;
    public event Action<SyncStatus>? Changed;
    public event Action? TemplatesChanged;

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
            lock (c.HandoffStateGate)
            {
                if (c.ActiveAttachment is { } att && !ids.Contains(att.Id)) c.ActiveAttachment = null;
                c.Attempted.RemoveWhere(id => !ids.Contains(id));
                c.ResumedAttachments.RemoveWhere(id => !ids.Contains(id));
                c.FinalChunkSentAttachments.RemoveWhere(id => !ids.Contains(id));
            }
            foreach (var id in c.ActiveIncomingAttachments.Keys.Where(id => store.Incoming(c.DeviceId, id) is null).ToArray()) c.ActiveIncomingAttachments.Remove(id);
            foreach (var id in c.AttachmentReceives.Keys.Where(id => store.Incoming(c.DeviceId, id) is null).ToArray()) c.AttachmentReceives.Remove(id);
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

    public async Task<IReadOnlyList<TemplateSyncItem>> GetTemplatesAsync(string? search = null)
    {
        await gate.WaitAsync();
        try { return templateStore.List(search); }
        finally { gate.Release(); }
    }

    public async Task<IReadOnlyList<TemplateGroupView>> GetTemplateGroupsAsync(string? search = null)
    {
        await gate.WaitAsync();
        try { return templateStore.GetGroups(search); }
        finally { gate.Release(); }
    }

    public async Task<IReadOnlyList<string>> GetTemplateTagsAsync()
    {
        await gate.WaitAsync();
        try { return templateStore.Tags(); }
        finally { gate.Release(); }
    }

    public async Task<TemplateEditResult> CreateTemplateAsync(string text, string? title, string? tag)
    {
        await gate.WaitAsync();
        try
        {
            if (stopped) return new(false, TemplateEditError.Stopped);
            var result = templateStore.Create(text, title, tag, Now().ToUnixTimeMilliseconds());
            if (result.Succeeded)
            {
                log($"template created count={templateStore.Count}");
                TemplatesChanged?.Invoke();
            }
            return result;
        }
        finally { gate.Release(); }
    }

    public async Task<TemplateEditResult> UpdateTemplateAsync(Guid id, string text, string? title, string? tag)
    {
        await gate.WaitAsync();
        try
        {
            if (stopped) return new(false, TemplateEditError.Stopped);
            var result = templateStore.Update(id, text, title, tag, Now().ToUnixTimeMilliseconds());
            if (result.Succeeded)
            {
                log($"template updated count={templateStore.Count}");
                TemplatesChanged?.Invoke();
            }
            return result;
        }
        finally { gate.Release(); }
    }

    public async Task<TemplateDeleteResult> DeleteTemplateAsync(Guid id)
    {
        await gate.WaitAsync();
        try
        {
            if (stopped) return new(false);
            var result = templateStore.Delete(id, Now().ToUnixTimeMilliseconds());
            if (result.Succeeded)
            {
                log($"template deleted count={templateStore.Count} tombs={templateStore.TombstoneCount}");
                TemplatesChanged?.Invoke();
            }
            return result;
        }
        finally { gate.Release(); }
    }

    public async Task<TemplateEditResult> RestoreDeletedTemplateAsync(TemplateSyncItem deletedItem)
    {
        ArgumentNullException.ThrowIfNull(deletedItem);
        await gate.WaitAsync();
        try
        {
            if (stopped) return new(false, TemplateEditError.Stopped);
            var result = templateStore.Restore(deletedItem, Now().ToUnixTimeMilliseconds());
            if (result.Succeeded)
            {
                log($"template restored count={templateStore.Count} tombs={templateStore.TombstoneCount}");
                TemplatesChanged?.Invoke();
            }
            return result;
        }
        finally { gate.Release(); }
    }

    public async Task<bool> MoveTemplateInGroupAsync(Guid id, int delta)
    {
        await gate.WaitAsync();
        try
        {
            if (stopped) return false;
            var moved = templateStore.MoveInGroup(id, delta, Now().ToUnixTimeMilliseconds());
            if (moved)
            {
                log("template reordered");
                TemplatesChanged?.Invoke();
            }
            return moved;
        }
        finally { gate.Release(); }
    }

    public async Task<int> RenameTemplateTagAsync(string? oldTag, string? newTag)
    {
        await gate.WaitAsync();
        try
        {
            if (stopped) return 0;
            var moved = templateStore.RenameTag(oldTag, newTag, Now().ToUnixTimeMilliseconds());
            if (moved > 0)
            {
                log($"template tag renamed items={moved}");
                TemplatesChanged?.Invoke();
            }
            return moved;
        }
        finally { gate.Release(); }
    }

    public async Task<TemplateEditResult> MoveHistoryToTemplatesAsync(Guid historyId)
    {
        await gate.WaitAsync();
        try
        {
            if (stopped) return new(false, TemplateEditError.Stopped);
            var historyItem = store.List().FirstOrDefault(i => i.Id == historyId);
            if (historyItem is null) return new(false, TemplateEditError.NotFound);
            if (historyItem.Kind != "text") return new(false, TemplateEditError.UnsupportedKind);

            var created = templateStore.Create(historyItem.Text ?? "", title: null, tag: null, Now().ToUnixTimeMilliseconds());
            if (!created.Succeeded) return created;

            store.Delete(historyId);
            TrimConnectionQueues();
            foreach (var c in connections.Values.Where(x => x.Stage == 2).ToArray()) StartSending(c);
            log($"template moved from history count={templateStore.Count}");
            HistoryChanged?.Invoke();
            TemplatesChanged?.Invoke();
            Publish();
            return created;
        }
        finally { gate.Release(); }
    }

    public async Task CopyTemplateAsync(Guid id)
    {
        await gate.WaitAsync();
        try
        {
            if (stopped) return;
            var item = templateStore.Get(id) ?? throw new KeyNotFoundException();
            ownSequence = await clipboard.WriteTextAsync(item.Text);
        }
        finally { gate.Release(); }
    }

    public async Task ClearTemplateTombstonesAsync()
    {
        await gate.WaitAsync();
        try
        {
            if (stopped) return;
            templateStore.ClearTombstones();
        }
        finally { gate.Release(); }
    }

    public async Task<TemplateSyncRunResult> SyncTemplatesAsync(CancellationToken cancellationToken = default)
    {
        Task<TemplateSyncRunResult> completion;
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (stopped) return TemplateSyncRunResult.StoppedResult();
            if (activeTemplateSync is not null) return TemplateSyncRunResult.AlreadyInProgressResult();

            var stage2 = connections.Values.Where(c => c.Stage == 2 && !c.Retired).ToList();
            if (stage2.Count == 0)
            {
                return RequiresPeerUpdate
                    ? TemplateSyncRunResult.PeerUpdateRequiredResult()
                    : TemplateSyncRunResult.NoConnectedDevicesResult();
            }

            var now = Now();
            var op = Guid.NewGuid();
            var deadline = now + TemplateSyncTimeout;
            var participants = stage2.Select(c => new ParticipantProgress(c, now, deadline)).ToList();
            activeTemplateSync = new TemplateSyncSession(op, now, participants);

            var pull = new TemplateSyncPull(op);
            foreach (var c in stage2)
            {
                EnqueueTemplateMessage(c, pull);
                StartSending(c);
            }
            log($"template sync started devices={stage2.Count}");
            completion = activeTemplateSync.Completion.Task;
        }
        finally { gate.Release(); }

        return cancellationToken.CanBeCanceled
            ? await completion.WaitAsync(cancellationToken)
            : await completion;
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
            if (stopped || peer.IsRejected) { peer.Reject(); return; }
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
        Connection? c;
        await gate.WaitAsync();
        try
        {
            if (stopped || !connections.TryGetValue(peer, out c) || c.Retired) return false;
            if (peer.IsRejected)
            {
                Drop(c, "peer retired");
                return false;
            }
        }
        finally { gate.Release(); }

        await c.HandoffGate.WaitAsync();
        try
        {
            await gate.WaitAsync();
            try
            {
                if (stopped || !connections.TryGetValue(peer, out var tracked) || !ReferenceEquals(tracked, c) || c.Retired)
                    return false;
                if (peer.IsRejected)
                {
                    Drop(c, "peer retired");
                    return false;
                }
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
                {
                    ExtendReplyDeadlines(c, frameToken, c.LastPacket);
                    ExtendTemplateSyncDeadline(c, frameToken, c.LastPacket);
                }
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
                    var decoded = DecodeStage2Message(c.Receiver!.Open(frame));
                    if (decoded is SyncPing or SyncPong)
                    {
                        RevertReplyExtension(c, frameToken);
                        RevertTemplateSyncExtension(c, frameToken);
                    }
                    else
                    {
                        if (frameBytes > MinExtendableFrameBytes)
                        {
                            ExtendReplyDeadlines(c, frameToken, c.LastPacket);
                            ExtendTemplateSyncDeadline(c, frameToken, c.LastPacket);
                        }
                        ConfirmReplyExtension(c, frameToken);
                        ConfirmTemplateSyncExtension(c, frameToken, resetForNextTemplatePage: decoded is TemplateSyncPush);
                    }
                    if (decoded is TemplateSyncMessage templateMessage)
                    {
                        switch (templateMessage)
                        {
                            case TemplateSyncPush push:
                                HandleTemplatePush(c, push);
                                break;
                            case TemplateSyncAck ack:
                                HandleTemplateAck(c, ack);
                                break;
                            default:
                                throw new SyncProtocolException(SyncError.Format);
                        }
                    }
                    else
                    {
                    var message = (SyncMessage)decoded;
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
                                c.ActiveIncomingAttachments[offer.Id] = offerNow;
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
                            else
                            {
                                c.ActiveIncomingAttachments[chunk.Id] = c.LastPacket;
                                EnableHighThroughput(c, c.LastPacket);
                                QueueReply(c, new SyncResume(chunk.Id, saved));
                            }
                            break;
                        case SyncResume resume:
                            var queued = store.Pending(c.DeviceId).FirstOrDefault(i => i.Id == resume.Id);
                            if (queued is null) break; // Deleted or expired during transfer.
                            if (queued.Kind == "text" || resume.Offset >= queued.Size || c.ActiveAttachment?.Id != resume.Id)
                                throw new SyncProtocolException(SyncError.State);
                            var att = c.ActiveAttachment;
                            var resumeNow = Now();
                            if (att.AwaitingInitialResume)
                            {
                                if (!att.HandedOffOfferLastPacket) break;
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
                                if (idx < 0 || !att.Chunks[idx].HandedOffLastPacket) throw new SyncProtocolException(SyncError.State);
                                att.Chunks.RemoveRange(0, idx + 1);
                                att.AckedOffset = resume.Offset;
                            }
                            att.LastActivity = resumeNow;
                            c.ResumedAttachments.Add(resume.Id);
                            EnableHighThroughput(c, resumeNow);
                            StartSending(c); break;
                        case SyncAck ack:
                            foreach (var id in ack.Ids)
                                if (c.ResumedAttachments.Contains(id) && !c.FinalChunkSentAttachments.Contains(id))
                                    throw new SyncProtocolException(SyncError.State);
                            var ids = ack.Ids.Where(id =>
                            {
                                if (c.ActiveAttachment is { } att && att.Id == id)
                                    return c.ResumedAttachments.Contains(id)
                                        ? c.FinalChunkSentAttachments.Contains(id)
                                        : att.HandedOffOfferLastPacket;
                                return c.Sent.ContainsKey(id) || c.InFlight == id || c.Attempted.Contains(id);
                            }).ToHashSet();
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
        finally { c.HandoffGate.Release(); }
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
            AddLocalContentsLocked(contents);
        }
        finally { gate.Release(); }
    }

    public async Task<LocalAddResult> AddLocalContentsAsync(IReadOnlyList<ClipboardContent> contents)
    {
        ArgumentNullException.ThrowIfNull(contents);
        await gate.WaitAsync();
        try
        {
            if (stopped || contents.Count == 0) return new(0, 0);
            return AddLocalContentsLocked(contents);
        }
        finally { gate.Release(); }
    }

    private LocalAddResult AddLocalContentsLocked(IReadOnlyList<ClipboardContent> contents)
    {
        var added = 0;
        var skipped = 0;
        var now = Now();
        foreach (var content in contents)
        {
            try
            {
                var item = store.Create(content, now.ToUnixTimeMilliseconds(), "PC");
                if (item.Kind == "text") SyncMessageCodec.Encode(new SyncItem(item.Id, item.At, "pc", item.Text!));
                else SyncMessageCodec.ValidateOffer(item.Offer);
                store.AddAndEnqueue(item, now);
                HistoryChanged?.Invoke();
                added++;
            }
            catch (SyncProtocolException) { skipped++; }
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
        return new(added, skipped);
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
                templateStore.PruneTombstones(ClampTimestamp(now.ToUnixTimeMilliseconds()));
                lastPrune = now;
                TrimConnectionQueues();
            }
            foreach (var c in connections.Values.ToArray())
            {
                if (c.Peer.IsRejected)
                {
                    Drop(c, "peer retired");
                    continue;
                }
                if ((c.Stage < 2 && now - c.Started > TimeSpan.FromSeconds(20)) ||
                    (c.Assembler.HasPartialFrame && now - c.LastPacket > TimeSpan.FromSeconds(20)))
                    Drop(c, "receive timeout");
                else if (c.Stage == 2)
                {
                    // An attachment whose 60-second reply deadline expires drops the connection so the
                    // next session restarts cleanly from offer; text items may resend on the same link.
                    var expired = c.Sent.Where(p => p.Key != c.InFlight && now > p.Value.Deadline).Select(p => p.Key).ToArray();
                    bool attachmentExpired;
                    Guid? activeAttachmentId;
                    bool outgoingAttachmentActive;
                    lock (c.HandoffStateGate)
                    {
                        attachmentExpired = c.ActiveAttachment?.Chunks.Any(ch => ch.Reply is { } reply && now > reply.Deadline) ?? false;
                        activeAttachmentId = c.ActiveAttachment?.Id;
                        outgoingAttachmentActive = c.ActiveAttachment is { } activeAtt &&
                            (c.InFlight == activeAtt.Id || now - activeAtt.LastActivity < HighThroughputIdleGrace);
                    }
                    if (attachmentExpired || expired.Any(id => activeAttachmentId == id ||
                        store.Pending(c.DeviceId).FirstOrDefault(i => i.Id == id)?.Kind is "image" or "file"))
                    {
                        Drop(c, "attachment timeout");
                        continue;
                    }
                    foreach (var id in expired) c.Sent.Remove(id);
                    foreach (var expiredAck in c.AwaitingPeerTemplateAcks.Where(p => now > p.Value).Select(p => p.Key).ToArray())
                        c.AwaitingPeerTemplateAcks.Remove(expiredAck);
                    var incomingPacketActive = c.ActiveIncomingAttachments.Count > 0 &&
                        c.Assembler.HasPartialFrame &&
                        now - c.LastPacket < HighThroughputIdleGrace;
                    if (!incomingPacketActive)
                    {
                        foreach (var staleId in c.ActiveIncomingAttachments.Where(p => now - p.Value >= HighThroughputIdleGrace).Select(p => p.Key).ToArray())
                            c.ActiveIncomingAttachments.Remove(staleId);
                    }
                    var incomingAttachmentActive = incomingPacketActive || c.ActiveIncomingAttachments.Count > 0;
                    if (c.HighThroughputRequested && !outgoingAttachmentActive && !incomingAttachmentActive &&
                        now - c.LastAttachmentActivity >= HighThroughputIdleGrace)
                    {
                        c.HighThroughputRequested = false;
                        c.Peer.SetHighThroughput(false);
                    }
                    try { StartSending(c); }
                    catch (Exception e) { Drop(c, Failure(e)); }
                }
            }
            TickTemplateSyncSession(now);
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
                if (activeTemplateSync is { } dangling)
                {
                    activeTemplateSync = null;
                    dangling.Completion.TrySetResult(TemplateSyncRunResult.StoppedResult());
                }
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

    // Selection/sealing uses gate; last-packet notification start uses per-connection HandoffGate.
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
                TemplateSyncStateMessage? sendingTemplateState = null;
                var sendingTemplate = false;
                var finishesItem = false;
                var retransmission = false;
                var isChunk = false;
                int? chunkEndOffset = null;
                await gate.WaitAsync();
                try
                {
                    if (c.Retired) return;
                    if (c.Peer.IsRejected) { Drop(c, "peer retired"); return; }
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
                    else if (c.Stage == 2 && c.TemplateMessages.TryDequeue(out var templateMsg))
                    {
                        sendingTemplate = true;
                        sendingTemplateState = templateMsg as TemplateSyncStateMessage;
                        c.SendingTemplateMessage = true;
                        frame = c.Sender!.Seal(TemplateSyncMessageCodec.Encode(templateMsg));
                    }
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
                                att.Chunks.Add(new(end, false, null));
                                chunkEndOffset = end;
                                finishesItem = end == item.Size;
                                c.Progress = new(c.DeviceId, "send", item.Id, itemIndex, itemCount, end, item.Size);
                                att.LastActivity = sentNow;
                                EnableHighThroughput(c, sentNow);
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
                            retransmission = !isChunk && !attempted.Add(item.Id);
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
                    Task sendTask = Task.CompletedTask;
                    if (packetIndex == packets.Count - 1 && item is not null && item.Kind != "text")
                    {
                        string? dropReason = null;
                        await c.HandoffGate.WaitAsync();
                        try
                        {
                            if (c.Retired || c.Stop.IsCancellationRequested) return;
                            if (c.Peer.IsRejected)
                            {
                                dropReason = "peer retired";
                            }
                            else
                            {
                                try
                                {
                                    sendTask = c.Peer.SendPacketAsync(packets[packetIndex]);
                                    if (sendTask.IsCompleted) sendTask.GetAwaiter().GetResult();
                                    lock (c.HandoffStateGate)
                                    {
                                        if (!c.Retired && !c.Stop.IsCancellationRequested)
                                        {
                                            if (isChunk && chunkEndOffset is int end && c.ActiveAttachment is { } active && active.Id == item.Id)
                                            {
                                                var idx = active.Chunks.FindIndex(ch => ch.EndOffset == end);
                                                if (idx >= 0) active.Chunks[idx] = active.Chunks[idx] with { HandedOffLastPacket = true };
                                            }
                                            else if (!isChunk && c.ActiveAttachment is { } activeOffer && activeOffer.Id == item.Id)
                                            {
                                                activeOffer.HandedOffOfferLastPacket = true;
                                            }
                                            if (finishesItem && c.ResumedAttachments.Contains(item.Id))
                                                c.FinalChunkSentAttachments.Add(item.Id);
                                        }
                                    }
                                }
                                catch (Exception e)
                                {
                                    dropReason = Failure(e);
                                }
                            }
                        }
                        finally { c.HandoffGate.Release(); }
                        if (dropReason is not null)
                        {
                            await gate.WaitAsync();
                            try { if (!c.Retired) Drop(c, dropReason); }
                            finally { gate.Release(); }
                            return;
                        }
                    }
                    else
                    {
                        c.Stop.Token.ThrowIfCancellationRequested();
                        sendTask = c.Peer.SendPacketAsync(packets[packetIndex]);
                    }
                    if (!sendTask.IsCompleted)
                        await sendTask.WaitAsync(TimeSpan.FromSeconds(10), c.Stop.Token);
                    else
                        await sendTask;
                }
                await gate.WaitAsync();
                try
                {
                    if (sendingTemplate) c.SendingTemplateMessage = false;
                    if (c.Retired) return;
                    if (c.Peer.IsRejected) { Drop(c, "peer retired"); return; }
                    if (sendingTemplateState is { } sentState)
                        OnTemplateStateFrameSent(c, sentState);
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
                                    var completedDeadline = completedNow + ReplyTimeout;
                                    att.Chunks[idx] = att.Chunks[idx] with
                                    {
                                        Reply = new(completedNow, completedDeadline, completedDeadline, null)
                                    };
                                    att.LastActivity = completedNow;
                                    c.LastAttachmentActivity = completedNow;
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
                                att.LastActivity = completedNow;
                                if (item.Size > 0) c.LastAttachmentActivity = completedNow;
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
        lock (c.HandoffStateGate)
        {
            c.Retired = true;
            c.Stop.Cancel();
            c.ActiveAttachment = null;
            c.ResumedAttachments.Clear();
            c.FinalChunkSentAttachments.Clear();
        }
        c.ControlFrames.Clear(); c.AckQueue.Clear(); c.Replies.Clear(); c.Sent.Clear();
        c.TemplateMessages.Clear(); c.AwaitingPeerTemplateAcks.Clear(); c.SendingTemplateMessage = false;
        if (c.IncomingTemplatePush is { } pushAssembler)
        {
            c.IncomingTemplatePush = null;
            try { pushAssembler.Finish(); }
            catch (SyncProtocolException e) { log($"template push ended error={e.Code}"); }
        }
        c.ActiveIncomingAttachments.Clear(); c.AttachmentReceives.Clear();
        c.OfferedThisConnection.Clear(); c.Progress = null;
        if (c.HighThroughputRequested) { c.HighThroughputRequested = false; c.Peer.SetHighThroughput(false); }
        connections.Remove(c.Peer);
        attempted.RemoveWhere(id => !store.Devices.Any(d => store.Pending(d.Id).Any(i => i.Id == id)));
        try { c.Assembler.Finish(); }
        catch (SyncProtocolException e) { log($"assembly ended error={e.Code}"); }
        c.Peer.Reject();
        OnTemplateParticipantDropped(c);
        log($"connection retired reason={reason}");
        Publish();
    }

    private static object DecodeStage2Message(byte[] plaintext)
    {
        // Peek "t" only to dispatch to the right strict codec; both codecs perform full validation.
        if (plaintext.Length >= 2)
        {
            var headerLen = BinaryPrimitives.ReadUInt16BigEndian(plaintext);
            if (headerLen > 0 && headerLen <= plaintext.Length - 2)
            {
                var headerSpan = plaintext.AsSpan(2, headerLen);
                if (headerSpan.IndexOf("tpl_"u8) >= 0 || headerSpan.IndexOf("\\u"u8) >= 0)
                {
                    try
                    {
                        using var doc = JsonDocument.Parse(plaintext.AsMemory(2, headerLen), new JsonDocumentOptions { MaxDepth = 8 });
                        if (doc.RootElement.ValueKind == JsonValueKind.Object &&
                            doc.RootElement.TryGetProperty("t", out var tProp) &&
                            tProp.ValueKind == JsonValueKind.String &&
                            tProp.GetString() is string t &&
                            t.StartsWith("tpl_", StringComparison.Ordinal))
                        {
                            return TemplateSyncMessageCodec.Decode(plaintext);
                        }
                    }
                    catch (JsonException) { /* Fall through to SyncMessageCodec.Decode which throws SyncError.Format. */ }
                }
            }
        }
        return SyncMessageCodec.Decode(plaintext);
    }

    private void EnqueueTemplateMessage(Connection c, TemplateSyncMessage message)
    {
        if (c.TemplateMessages.Count >= MaxQueuedTemplateMessages)
            throw new SyncProtocolException(SyncError.Limit);
        c.TemplateMessages.Enqueue(message);
    }

    private void HandleTemplatePush(Connection c, TemplateSyncPush push)
    {
        c.IncomingTemplatePush ??= new TemplateSyncPageAssembler(expectedOp: push.Op, expectedIsState: false);
        TemplateSyncSnapshot? snapshot;
        try
        {
            snapshot = c.IncomingTemplatePush.Append(push);
        }
        catch
        {
            c.IncomingTemplatePush = null;
            throw;
        }
        if (snapshot is null)
            return;

        c.IncomingTemplatePush.Finish();
        c.IncomingTemplatePush = null;

        if (activeTemplateSync is { } active && push.Op == active.Op)
        {
            var participant = active.Participants.FirstOrDefault(x => ReferenceEquals(x.Connection, c));
            if (active.Phase == TemplateSyncPhase.Collecting && participant is { State: ParticipantState.AwaitingPush })
            {
                participant.PushSnapshot = snapshot;
                participant.State = ParticipantState.PushReceived;
                participant.ActiveFrameToken = null;
                TryAdvanceTemplateSyncSession();
                return;
            }
            if (participant is { State: ParticipantState.PushReceived or ParticipantState.AwaitingAck or ParticipantState.AckReceived })
                throw new SyncProtocolException(SyncError.State);

            log("template sync late push ignored");
            return;
        }

        HandlePeerInitiatedTemplateSync(c, push.Op, snapshot);
    }

    private void HandlePeerInitiatedTemplateSync(Connection c, Guid op, TemplateSyncSnapshot remoteSnapshot)
    {
        var now = Now();
        var nowMillis = ClampTimestamp(now.ToUnixTimeMilliseconds());
        var pcBefore = templateStore.GetState();
        var merged = TemplateSyncMerge.Merge(
            pcBefore,
            new TemplateSyncState(remoteSnapshot.Templates, remoteSnapshot.Tombstones),
            nowMillis,
            remoteSnapshot.SentAt);
        var stateMessages = TemplateSyncMessageCodec.SplitPages(
            op,
            new TemplateSyncSnapshot(nowMillis, merged.Templates, merged.Tombstones),
            isState: true);

        templateStore.ApplyMerged(merged.Templates, merged.Tombstones);

        if (merged.ClockSkewSeconds is long skew)
            log($"template sync clock-skew seconds={skew}");
        if (merged.PcChanges.Total > 0)
            TemplatesChanged?.Invoke();

        foreach (var msg in stateMessages)
            EnqueueTemplateMessage(c, msg);
        c.AwaitingPeerTemplateAcks[op] = now + TemplateSyncTimeout;
        StartSending(c);

        log($"template sync peer-initiated items={merged.Templates.Count} tombs={merged.Tombstones.Count} pcAdded={merged.PcChanges.Added} pcUpdated={merged.PcChanges.Updated} pcDeleted={merged.PcChanges.Deleted} remoteAdded={merged.RemoteChanges.Added} remoteUpdated={merged.RemoteChanges.Updated} remoteDeleted={merged.RemoteChanges.Deleted} conflicts={merged.ConflictCopyCount}");
    }

    private void HandleTemplateAck(Connection c, TemplateSyncAck ack)
    {
        if (activeTemplateSync is { } active &&
            active.Phase == TemplateSyncPhase.Distributing &&
            ack.Op == active.Op &&
            active.Participants.FirstOrDefault(x => ReferenceEquals(x.Connection, c)) is { State: ParticipantState.AwaitingAck } participant)
        {
            participant.State = ParticipantState.AckReceived;
            participant.ActiveFrameToken = null;
            log("template sync ack pc-initiated");
            if (!active.Participants.Any(p => p.State == ParticipantState.AwaitingAck))
                FinishTemplateSyncSession();
            return;
        }

        if (c.AwaitingPeerTemplateAcks.Remove(ack.Op))
            log("template sync ack peer-initiated");
        else
            log("template sync ack ignored");
    }

    private void OnTemplateStateFrameSent(Connection c, TemplateSyncStateMessage sentState)
    {
        var now = Now();
        if (sentState.Part < sentState.Total - 1)
        {
            if (activeTemplateSync is { } activePage &&
                activePage.Phase == TemplateSyncPhase.Distributing &&
                sentState.Op == activePage.Op &&
                activePage.Participants.FirstOrDefault(x => ReferenceEquals(x.Connection, c)) is { State: ParticipantState.AwaitingAck } pPage)
            {
                var maxDeadline = pPage.InitialSentAt + TemplateSyncTimeout + MaxReplyExtension;
                var candidate = now + TemplateSyncTimeout;
                pPage.Deadline = candidate > maxDeadline ? maxDeadline : candidate;
                pPage.BaselineDeadline = pPage.Deadline;
            }
            return;
        }

        if (activeTemplateSync is { } active &&
            active.Phase == TemplateSyncPhase.Distributing &&
            sentState.Op == active.Op &&
            active.Participants.FirstOrDefault(x => ReferenceEquals(x.Connection, c)) is { State: ParticipantState.AwaitingAck } p)
        {
            p.InitialSentAt = now;
            p.Deadline = now + TemplateSyncTimeout;
            p.BaselineDeadline = p.Deadline;
            p.ActiveFrameToken = null;
        }
        if (c.AwaitingPeerTemplateAcks.ContainsKey(sentState.Op))
            c.AwaitingPeerTemplateAcks[sentState.Op] = now + TemplateSyncTimeout;
    }

    private void OnTemplateParticipantDropped(Connection c)
    {
        if (activeTemplateSync is not { } session) return;
        var participant = session.Participants.FirstOrDefault(x => ReferenceEquals(x.Connection, c));
        if (participant is null) return;

        if (session.Phase == TemplateSyncPhase.Collecting && participant.State == ParticipantState.AwaitingPush)
        {
            participant.State = ParticipantState.Dropped;
            TryAdvanceTemplateSyncSession();
        }
        else if (session.Phase == TemplateSyncPhase.Distributing && participant.State == ParticipantState.AwaitingAck)
        {
            participant.State = ParticipantState.Dropped;
            if (!session.Participants.Any(p => p.State == ParticipantState.AwaitingAck))
                FinishTemplateSyncSession();
        }
    }

    private void TickTemplateSyncSession(DateTimeOffset now)
    {
        if (activeTemplateSync is not { } session) return;

        if (session.Phase == TemplateSyncPhase.Collecting)
        {
            var changed = false;
            foreach (var p in session.Participants)
            {
                if (p.State == ParticipantState.AwaitingPush && now > p.Deadline)
                {
                    p.State = ParticipantState.TimedOut;
                    changed = true;
                }
            }
            if (changed) TryAdvanceTemplateSyncSession();
        }
        else
        {
            var changed = false;
            foreach (var p in session.Participants)
            {
                if (p.State == ParticipantState.AwaitingAck &&
                    p.Connection.TemplateMessages.Count == 0 &&
                    !p.Connection.SendingTemplateMessage &&
                    now > p.Deadline)
                {
                    p.State = ParticipantState.TimedOut;
                    changed = true;
                }
            }
            if (changed && !session.Participants.Any(p => p.State == ParticipantState.AwaitingAck))
                FinishTemplateSyncSession();
        }
    }

    private void TryAdvanceTemplateSyncSession()
    {
        if (activeTemplateSync is not { } session || session.Phase != TemplateSyncPhase.Collecting)
            return;
        if (session.Participants.Any(p => p.State == ParticipantState.AwaitingPush))
            return;

        var responded = session.Participants.Where(p => p.State == ParticipantState.PushReceived).ToList();
        if (responded.Count == 0)
        {
            var timedOut = session.Participants.Any(p => p.State == ParticipantState.TimedOut);
            var status = timedOut ? TemplateSyncRunStatus.TimedOut : TemplateSyncRunStatus.Disconnected;
            activeTemplateSync = null;
            log($"template sync failed reason={status}");
            session.Completion.TrySetResult(new TemplateSyncRunResult(
                status,
                TargetDevices: session.Participants.Count,
                SucceededDevices: 0,
                FailedDevices: session.Participants.Count));
            return;
        }

        var now = Now();
        var nowMillis = ClampTimestamp(now.ToUnixTimeMilliseconds());
        var pcBefore = templateStore.GetState();
        var current = pcBefore;
        var totalConflicts = 0;
        long? maxSkew = null;
        IReadOnlyList<TemplateSyncMessage> stateMessages;

        try
        {
            foreach (var p in responded.OrderBy(x => x.DeviceId))
            {
                var snap = p.PushSnapshot!;
                var step = TemplateSyncMerge.Merge(
                    current,
                    new TemplateSyncState(snap.Templates, snap.Tombstones),
                    nowMillis,
                    snap.SentAt);
                current = new TemplateSyncState(step.Templates, step.Tombstones);
                totalConflicts += step.ConflictCopyCount;
                if (step.ClockSkewSeconds is long skew && (maxSkew is null || skew > maxSkew.Value))
                    maxSkew = skew;
            }

            stateMessages = TemplateSyncMessageCodec.SplitPages(
                session.Op,
                new TemplateSyncSnapshot(nowMillis, current.Templates, current.Tombstones),
                isState: true);
            templateStore.ApplyMerged(current.Templates, current.Tombstones);
        }
        catch (SyncProtocolException ex)
        {
            activeTemplateSync = null;
            log($"template sync aborted error={ex.Code}");
            session.Completion.TrySetResult(ex.Code == SyncError.Limit
                ? TemplateSyncRunResult.LimitExceededResult()
                : new TemplateSyncRunResult(TemplateSyncRunStatus.Stopped));
            return;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            activeTemplateSync = null;
            log($"template sync save error={ex.GetType().Name}");
            session.Completion.TrySetResult(TemplateSyncRunResult.StoppedResult());
            return;
        }

        var pcChanges = ComputeTemplateChanges(pcBefore.Templates, current.Templates);
        var remoteChangesTotal = 0;
        foreach (var p in responded)
            remoteChangesTotal += ComputeTemplateChanges(p.PushSnapshot!.Templates, current.Templates).Total;

        session.PcSaved = true;
        session.PcChanges = pcChanges;
        session.RemoteChangesTotal = remoteChangesTotal;
        session.ConflictCopyCount = totalConflicts;
        session.ClockSkewSeconds = maxSkew;

        if (maxSkew is long loggedSkew)
            log($"template sync clock-skew seconds={loggedSkew}");
        if (pcChanges.Total > 0)
            TemplatesChanged?.Invoke();

        session.Phase = TemplateSyncPhase.Distributing;
        var distributing = 0;
        foreach (var p in responded)
        {
            if (p.Connection.Retired || !connections.ContainsValue(p.Connection))
            {
                p.State = ParticipantState.Dropped;
                continue;
            }
            p.State = ParticipantState.AwaitingAck;
            p.InitialSentAt = now;
            p.Deadline = now + TemplateSyncTimeout;
            p.BaselineDeadline = p.Deadline;
            p.ActiveFrameToken = null;
            foreach (var msg in stateMessages)
                EnqueueTemplateMessage(p.Connection, msg);
            StartSending(p.Connection);
            distributing++;
        }

        log($"template sync merged devices={responded.Count} items={current.Templates.Count} tombs={current.Tombstones.Count} pcAdded={pcChanges.Added} pcUpdated={pcChanges.Updated} pcDeleted={pcChanges.Deleted} remoteChanges={remoteChangesTotal} conflicts={totalConflicts}");

        if (distributing == 0)
            FinishTemplateSyncSession();
    }

    private void FinishTemplateSyncSession()
    {
        if (activeTemplateSync is not { } session) return;
        activeTemplateSync = null;

        var succeeded = session.Participants.Count(p => p.State == ParticipantState.AckReceived);
        var failed = session.Participants.Count - succeeded;
        var pcChanges = session.PcChanges ?? new TemplateSyncSideChanges(0, 0, 0);

        TemplateSyncRunStatus status;
        if (succeeded > 0)
        {
            status = TemplateSyncRunStatus.Completed;
        }
        else if (session.Participants.Any(p => p.State == ParticipantState.TimedOut))
        {
            status = TemplateSyncRunStatus.TimedOut;
        }
        else
        {
            status = TemplateSyncRunStatus.Disconnected;
        }

        log($"template sync finished status={status} succeeded={succeeded} failed={failed}");
        session.Completion.TrySetResult(new TemplateSyncRunResult(
            status,
            TargetDevices: session.Participants.Count,
            SucceededDevices: succeeded,
            FailedDevices: failed,
            PcSaved: session.PcSaved,
            PcAdded: pcChanges.Added,
            PcUpdated: pcChanges.Updated,
            PcDeleted: pcChanges.Deleted,
            RemoteChangesTotal: session.RemoteChangesTotal,
            ConflictCopyCount: session.ConflictCopyCount,
            ClockSkewSeconds: session.ClockSkewSeconds));
    }

    private void ExtendTemplateSyncDeadline(Connection c, ulong frameToken, DateTimeOffset now)
    {
        if (activeTemplateSync is not { Phase: TemplateSyncPhase.Collecting } session) return;
        var p = session.Participants.FirstOrDefault(x => ReferenceEquals(x.Connection, c));
        if (p is null || p.State != ParticipantState.AwaitingPush) return;

        if (p.ActiveFrameToken != frameToken)
        {
            p.BaselineDeadline = p.Deadline;
            p.ActiveFrameToken = frameToken;
        }
        var maxDeadline = p.InitialSentAt + TemplateSyncTimeout + MaxReplyExtension;
        var candidate = now + TemplateSyncTimeout;
        var updated = candidate > maxDeadline ? maxDeadline : candidate;
        if (updated > p.Deadline)
            p.Deadline = updated;
    }

    private void RevertTemplateSyncExtension(Connection c, ulong frameToken)
    {
        if (activeTemplateSync is not { Phase: TemplateSyncPhase.Collecting } session) return;
        var p = session.Participants.FirstOrDefault(x => ReferenceEquals(x.Connection, c));
        if (p is null || p.State != ParticipantState.AwaitingPush) return;
        if (p.ActiveFrameToken == frameToken)
        {
            p.Deadline = p.BaselineDeadline;
            p.ActiveFrameToken = null;
        }
    }

    private void ConfirmTemplateSyncExtension(Connection c, ulong frameToken, bool resetForNextTemplatePage)
    {
        if (activeTemplateSync is not { Phase: TemplateSyncPhase.Collecting } session) return;
        var p = session.Participants.FirstOrDefault(x => ReferenceEquals(x.Connection, c));
        if (p is null || p.State != ParticipantState.AwaitingPush) return;

        if (p.ActiveFrameToken == frameToken)
        {
            p.BaselineDeadline = p.Deadline;
            p.ActiveFrameToken = null;
        }
        if (resetForNextTemplatePage)
        {
            var maxDeadline = p.InitialSentAt + TemplateSyncTimeout + MaxReplyExtension;
            var candidate = c.LastPacket + TemplateSyncTimeout;
            var updated = candidate > maxDeadline ? maxDeadline : candidate;
            if (updated > p.Deadline)
                p.Deadline = updated;
            p.BaselineDeadline = p.Deadline;
            p.ActiveFrameToken = null;
        }
    }

    private static TemplateSyncSideChanges ComputeTemplateChanges(
        IReadOnlyList<TemplateSyncItem> before,
        IReadOnlyList<TemplateSyncItem> after)
    {
        var beforeById = before.ToDictionary(i => i.Id);
        var afterById = after.ToDictionary(i => i.Id);
        var added = 0;
        var updated = 0;
        var deleted = 0;

        foreach (var (id, afterItem) in afterById)
        {
            if (!beforeById.TryGetValue(id, out var beforeItem))
            {
                added++;
            }
            else if (beforeItem.Kind != afterItem.Kind ||
                     !string.Equals(beforeItem.Text, afterItem.Text, StringComparison.Ordinal) ||
                     !string.Equals(beforeItem.Title, afterItem.Title, StringComparison.Ordinal) ||
                     !string.Equals(beforeItem.Tag, afterItem.Tag, StringComparison.Ordinal) ||
                     beforeItem.Order != afterItem.Order)
            {
                updated++;
            }
        }
        foreach (var id in beforeById.Keys)
        {
            if (!afterById.ContainsKey(id)) deleted++;
        }
        return new TemplateSyncSideChanges(added, updated, deleted);
    }

    private static long ClampTimestamp(long value) =>
        Math.Clamp(value, -SyncProtocol.MaxTimestamp, SyncProtocol.MaxTimestamp);

    private static PendingReply ExtendReply(PendingReply entry, ulong frameToken, DateTimeOffset candidate)
    {
        if (entry.ActiveFrameToken != frameToken)
            entry = entry with { BaselineDeadline = entry.Deadline, ActiveFrameToken = frameToken };
        var maxDeadline = entry.InitialSentAt + ReplyTimeout + MaxReplyExtension;
        var updated = candidate > maxDeadline ? maxDeadline : candidate;
        return updated > entry.Deadline ? entry with { Deadline = updated } : entry;
    }

    private static PendingReply RevertReply(PendingReply entry, ulong frameToken) =>
        entry.ActiveFrameToken == frameToken
            ? entry with { Deadline = entry.BaselineDeadline, ActiveFrameToken = null }
            : entry;

    private static PendingReply ConfirmReply(PendingReply entry, ulong frameToken) =>
        entry.ActiveFrameToken == frameToken
            ? entry with { BaselineDeadline = entry.Deadline, ActiveFrameToken = null }
            : entry;

    private static void TransformReplies(Connection c, Func<PendingReply, PendingReply> transform)
    {
        foreach (var id in c.Sent.Keys.ToArray())
            c.Sent[id] = transform(c.Sent[id]);
        if (c.ActiveAttachment is { } att)
        {
            for (var i = 0; i < att.Chunks.Count; i++)
            {
                if (att.Chunks[i].Reply is { } reply)
                    att.Chunks[i] = att.Chunks[i] with { Reply = transform(reply) };
            }
        }
    }

    private static void ExtendReplyDeadlines(Connection c, ulong frameToken, DateTimeOffset now)
    {
        var candidate = now + ReplyTimeout;
        TransformReplies(c, entry => ExtendReply(entry, frameToken, candidate));
    }

    private static void RevertReplyExtension(Connection c, ulong frameToken) =>
        TransformReplies(c, entry => RevertReply(entry, frameToken));

    private static void ConfirmReplyExtension(Connection c, ulong frameToken) =>
        TransformReplies(c, entry => ConfirmReply(entry, frameToken));

    // Exception messages can contain paths or external input. Log only a fixed code/type.
    private static string Failure(Exception e) => e is SyncProtocolException p ? p.Code.ToString() : e.GetType().Name;
}
