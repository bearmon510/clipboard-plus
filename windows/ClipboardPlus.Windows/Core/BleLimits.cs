using System.Threading.Channels;

namespace ClipboardPlus.Windows.Core;

internal static class BleLimits
{
    public static int NotificationBytes(int maxPduSize) => Math.Clamp(maxPduSize - 3, 20, 512);
}

// Counts queued AND executing write bytes. Admission happens before retaining event args.
internal sealed class WriteAdmission(
    int globalByteLimit = WriteAdmission.DefaultGlobalBytes,
    int peerByteLimit = WriteAdmission.DefaultPeerBytes)
{
    public const int DefaultGlobalBytes = 4 * 1024 * 1024;
    public const int DefaultPeerBytes = 1024 * 1024;

    private readonly int globalByteLimit = globalByteLimit;
    private readonly int peerByteLimit = peerByteLimit;
    private readonly object gate = new();
    private readonly Dictionary<string, long> bytesByPeer = [];
    private long totalBytes;

    internal long TotalBytes { get { lock (gate) return totalBytes; } }
    internal long PeerBytes(string peer) { lock (gate) return bytesByPeer.GetValueOrDefault(peer); }

    public void Dispatch(ChannelWriter<Func<Task>> writer, string peer,
        Func<Task> process, Action reject, Action complete, bool accepting = true, int bytes = 1)
    {
        var lease = accepting ? TryEnter(peer, bytes) : null;
        if (lease is not null && writer.TryWrite(async () =>
        {
            try { await process(); }
            finally { try { complete(); } finally { lease.Dispose(); } }
        })) return;
        try { reject(); }
        finally { try { complete(); } finally { lease?.Dispose(); } }
    }

    public WriteLease? TryEnter(string peer, int bytes = 1)
    {
        var charge = Math.Max(1, bytes);
        lock (gate)
        {
            var current = bytesByPeer.GetValueOrDefault(peer);
            if (totalBytes + charge > globalByteLimit || current + charge > peerByteLimit) return null;
            bytesByPeer[peer] = current + charge;
            totalBytes += charge;
            return new WriteLease(this, peer, charge);
        }
    }

    internal sealed class WriteLease : IDisposable
    {
        private readonly WriteAdmission owner;
        private readonly string peer;
        private int charged;
        private bool disposed;

        internal WriteLease(WriteAdmission owner, string peer, int charged)
        {
            this.owner = owner;
            this.peer = peer;
            this.charged = charged;
        }

        public bool TryAdjust(long actualBytes)
        {
            var next = Math.Max(1L, actualBytes);
            lock (owner.gate)
            {
                if (disposed) return false;
                if (next > owner.globalByteLimit || next > owner.peerByteLimit) return false;
                var nextInt = (int)next;
                var delta = nextInt - charged;
                if (delta == 0) return true;
                if (delta > 0)
                {
                    var current = owner.bytesByPeer.GetValueOrDefault(peer);
                    if (owner.totalBytes + delta > owner.globalByteLimit || current + delta > owner.peerByteLimit)
                        return false;
                }
                charged = nextInt;
                owner.bytesByPeer[peer] = owner.bytesByPeer.GetValueOrDefault(peer) + delta;
                owner.totalBytes += delta;
                return true;
            }
        }

        public void Dispose()
        {
            lock (owner.gate)
            {
                if (disposed) return;
                disposed = true;
                var remaining = owner.bytesByPeer.GetValueOrDefault(peer) - charged;
                if (remaining <= 0) owner.bytesByPeer.Remove(peer);
                else owner.bytesByPeer[peer] = remaining;
                owner.totalBytes -= charged;
            }
        }
    }
}

internal sealed record BleWriteRequestData(
    uint Offset,
    long PayloadLength,
    Func<byte[]> CopyBytes,
    bool IsWithResponse,
    Action RespondSuccess,
    Action<byte> RespondError)
{
    public BleWriteRequestData(
        uint offset,
        byte[] bytes,
        bool isWithResponse,
        Action respondSuccess,
        Action<byte> respondError)
        : this(offset, bytes.Length, () => bytes, isWithResponse, respondSuccess, respondError)
    {
    }
}

internal sealed record BleSubscribedClient(string PeerId, object Session, object Client, long SubscriptionGeneration = 0);

internal sealed class BleSubscriptionSlot(
    object characteristic,
    string peerId,
    object session,
    long generation,
    long subscriptionGeneration)
{
    private volatile bool rejected;
    private volatile bool invalidated;
    public object Characteristic { get; } = characteristic;
    public string PeerId { get; } = peerId;
    public object Session { get; } = session;
    public long Generation { get; } = generation;
    public long SubscriptionGeneration { get; } = subscriptionGeneration;
    public object? Peer { get; set; }
    public bool Rejected { get => rejected; set => rejected = value; }
    public bool Invalidated { get => invalidated; set => invalidated = value; }
    internal bool SawHello { get; set; }
    internal bool CollectingHello { get; set; }
    internal int PendingHelloPayloadBytes { get; set; }
    internal List<byte[]>? PendingHelloPackets { get; set; }
}

internal sealed class BlePeerRegistry<TPeer> where TPeer : class
{
    private readonly object gate = new();
    private readonly Dictionary<string, TPeer> peers = [];
    private int count;
    private bool closed;

    public int Count => Volatile.Read(ref count);
    public bool IsClosed { get { lock (gate) return closed; } }

    public TPeer? GetValueOrDefault(string id)
    {
        lock (gate) return peers.GetValueOrDefault(id);
    }

    public TPeer[] Snapshot()
    {
        lock (gate) return peers.Values.ToArray();
    }

    public bool TryAdd(string id, TPeer peer)
    {
        lock (gate)
        {
            if (closed) return false;
            peers[id] = peer;
            Volatile.Write(ref count, peers.Count);
            return true;
        }
    }

    public bool Remove(string id, TPeer peer)
    {
        lock (gate)
        {
            if (!peers.TryGetValue(id, out var current) || !ReferenceEquals(current, peer))
                return false;
            peers.Remove(id);
            Volatile.Write(ref count, peers.Count);
            return true;
        }
    }

    public TPeer[] Drain(bool close)
    {
        lock (gate)
        {
            if (close) closed = true;
            var snapshot = peers.Values.ToArray();
            peers.Clear();
            Volatile.Write(ref count, 0);
            return snapshot;
        }
    }

    public void Close()
    {
        lock (gate) closed = true;
    }
}

internal static class ConnectionTuningRequest
{
    public static TRequest? Acquire<TRequest>(
        Func<TRequest?> requestFactory,
        Func<TRequest, bool> isSuccess,
        Func<TRequest, string> getStatusLabel,
        Func<TRequest, bool> tryTakeOwnership,
        Action<string> log,
        out bool unavailable)
        where TRequest : class, IDisposable
    {
        unavailable = false;
        TRequest? request = null;
        var owned = false;
        try
        {
            request = requestFactory();
            if (request is not null && isSuccess(request))
            {
                if (tryTakeOwnership(request))
                {
                    owned = true;
                    log("conn params throughput status=Success");
                    return request;
                }
                return null;
            }
            var statusLabel = request is null ? "Unsupported" : getStatusLabel(request);
            unavailable = true;
            log($"conn params throughput status={statusLabel}");
            return null;
        }
        finally
        {
            if (!owned && request is not null)
            {
                try { request.Dispose(); }
                catch (Exception) { }
            }
        }
    }
}

internal static class BleEndpointCleanup
{
    public static async Task StopEndpointBeforePeersAsync(
        Action stopEndpoint,
        IReadOnlyList<Func<Task>> disposePeers,
        TimeSpan peerDisposeTimeout,
        Action<string> log)
    {
        stopEndpoint();
        if (disposePeers.Count == 0) return;
        var peerTask = Task.WhenAll(disposePeers.Select(async dispose =>
        {
            try { await dispose(); }
            catch (Exception e) { log($"peer remove error={e.GetType().Name}"); }
        }));
        if (peerDisposeTimeout == Timeout.InfiniteTimeSpan)
        {
            await peerTask;
            return;
        }
        try { await peerTask.WaitAsync(peerDisposeTimeout); }
        catch (TimeoutException) { log("peer dispose shutdown timeout"); }
    }
}

internal sealed class BleWritePipeline
{
    private sealed class CompletionOnce(Action complete, Action<Exception> onError)
    {
        private int done;
        public void Complete()
        {
            if (Interlocked.Exchange(ref done, 1) != 0) return;
            try { complete(); }
            catch (Exception e) { onError(e); }
        }
    }

    private readonly record struct WorkItem(Func<Task> Run, Action? Discard = null);

    private sealed record SubscriptionSnapshot(
        long Generation,
        BleSubscribedClient[] Clients,
        IReadOnlyDictionary<string, long> MaxGenerationsAtCapture);

    private sealed record PendingWrite(
        object Characteristic,
        BleSubscriptionSlot Slot,
        long Generation,
        Func<CancellationToken, Task<BleWriteRequestData?>> GetRequestAsync,
        CompletionOnce Completion,
        WriteAdmission.WriteLease Lease,
        Action RejectSync);

    private readonly WriteAdmission admission;
    private readonly Action<string> log;
    private readonly Func<Task> refreshSubscriptionsAsync;
    private readonly Func<BleSubscribedClient[], long, Task>? applySubscriptionsAsync;
    private readonly Func<object, BleSubscriptionSlot, Task<object?>>? rehandshakePeerAsync;
    private readonly Func<object, uint, byte[], Task<bool>> deliverPacketAsync;
    private readonly Func<object, Task> disconnectPeerAsync;
    private readonly Action<object>? rejectPeerSync;
    private readonly TimeSpan requestTimeout;
    private readonly TimeSpan shutdownTimeout;
    private readonly int minPacketCharge;
    private readonly Channel<WorkItem> work = Channel.CreateUnbounded<WorkItem>(new UnboundedChannelOptions { SingleReader = true });
    private readonly Channel<PendingWrite> ingest = Channel.CreateUnbounded<PendingWrite>(new UnboundedChannelOptions { SingleReader = true });
    private readonly CancellationTokenSource stop = new();
    private readonly object subscriptionReadGate = new();
    private readonly object slotGate = new();
    private readonly Dictionary<string, BleSubscriptionSlot> slotsByPeer = [];
    private readonly Dictionary<string, List<BleSubscriptionSlot>> liveSlotsByPeer = [];
    private readonly Dictionary<string, (object Session, long SubscriptionGeneration)> knownSubscribedSessions = [];
    private readonly Dictionary<string, long> nextSubscriptionGenerationByPeer = [];
    private readonly Queue<SubscriptionSnapshot> pendingSubscriptionSnapshots = new();
    private SubscriptionSnapshot? activeSubscriptionSnapshot;
    private object? activeCharacteristic;
    private object? activeOutbound;
    private long nextGeneration;
    private long nextSubscriptionGeneration;
    private volatile bool stopping;
    private readonly Task worker;
    private readonly Task ingestWorker;
    private readonly TaskCompletionSource workerStopped = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public bool IsStopped => worker.IsCompleted && ingestWorker.IsCompleted;

    public BleWritePipeline(
        WriteAdmission admission,
        Action<string> log,
        Func<Task> refreshSubscriptionsAsync,
        Func<object, uint, byte[], Task<bool>> deliverPacketAsync,
        Func<object, Task> disconnectPeerAsync,
        Action<object>? rejectPeerSync = null,
        TimeSpan? requestTimeout = null,
        int minPacketCharge = 20,
        Func<Task>? onWorkerStart = null,
        Func<Task>? onIngestStart = null,
        Func<BleSubscribedClient[], long, Task>? applySubscriptionsAsync = null,
        TimeSpan? shutdownTimeout = null,
        Func<object, BleSubscriptionSlot, Task<object?>>? rehandshakePeerAsync = null)
    {
        this.admission = admission;
        this.log = log;
        this.refreshSubscriptionsAsync = refreshSubscriptionsAsync;
        this.applySubscriptionsAsync = applySubscriptionsAsync;
        this.rehandshakePeerAsync = rehandshakePeerAsync;
        this.deliverPacketAsync = deliverPacketAsync;
        this.disconnectPeerAsync = disconnectPeerAsync;
        this.rejectPeerSync = rejectPeerSync;
        this.requestTimeout = requestTimeout ?? TimeSpan.FromSeconds(10);
        this.shutdownTimeout = shutdownTimeout ?? TimeSpan.FromSeconds(5);
        this.minPacketCharge = Math.Max(1, minPacketCharge);
        worker = Task.Run(async () =>
        {
            try
            {
                if (onWorkerStart is not null) await onWorkerStart();
                await foreach (var action in work.Reader.ReadAllAsync())
                {
                    try { await action.Run(); }
                    catch (Exception e) { log($"bluetooth operation error={e.GetType().Name}"); }
                }
            }
            catch (Exception e)
            {
                log($"worker error={e.GetType().Name}");
            }
            finally
            {
                work.Writer.TryComplete();
                while (work.Reader.TryRead(out var remaining))
                {
                    try { remaining.Discard?.Invoke(); }
                    catch (Exception e) { log($"worker cleanup error={e.GetType().Name}"); }
                }
                workerStopped.TrySetResult();
            }
        });
        ingestWorker = Task.Run(async () =>
        {
            try
            {
                if (onIngestStart is not null) await onIngestStart();
                await IngestLoopAsync();
            }
            catch (Exception e)
            {
                log($"ingest worker error={e.GetType().Name}");
            }
            finally
            {
                ingest.Writer.TryComplete();
                while (ingest.Reader.TryRead(out var remaining))
                {
                    try { remaining.RejectSync(); }
                    catch (Exception) { }
                    try { remaining.Completion.Complete(); }
                    finally { remaining.Lease.Dispose(); }
                }
            }
        });
    }

    public Task QueueWork(Func<Task> action)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (worker.IsCompleted || !work.Writer.TryWrite(new WorkItem(
            async () =>
            {
                try { await action(); }
                catch (Exception e) { log($"bluetooth operation error={e.GetType().Name}"); }
                finally { done.TrySetResult(); }
            },
            () => done.TrySetResult())))
        {
            done.TrySetResult();
            return done.Task;
        }
        return done.Task.IsCompleted ? done.Task : Task.WhenAny(done.Task, workerStopped.Task);
    }

    public void SetActiveCharacteristic(object? characteristic, object? outbound = null)
    {
        lock (slotGate)
        {
            activeCharacteristic = characteristic;
            activeOutbound = characteristic is null ? null : outbound ?? characteristic;
            if (characteristic is null)
            {
                foreach (var list in liveSlotsByPeer.Values)
                    foreach (var slot in list)
                    {
                        slot.Invalidated = true;
                        AdvancePeerGenerationLocked(slot.PeerId, slot.SubscriptionGeneration + 1);
                    }
                liveSlotsByPeer.Clear();
                slotsByPeer.Clear();
                foreach (var (peerId, known) in knownSubscribedSessions)
                    AdvancePeerGenerationLocked(peerId, known.SubscriptionGeneration + 1);
                knownSubscribedSessions.Clear();
                pendingSubscriptionSnapshots.Clear();
                activeSubscriptionSnapshot = null;
                return;
            }
            foreach (var key in slotsByPeer.Keys.ToArray())
            {
                var slot = slotsByPeer[key];
                if (!Equals(slot.Characteristic, characteristic))
                {
                    InvalidateSlotOnlyLocked(slot);
                    AdvancePeerGenerationLocked(slot.PeerId, slot.SubscriptionGeneration + 1);
                }
            }
        }
    }

    public void CaptureSubscriptionsChanged(object outboundCharacteristic, Func<BleSubscribedClient[]> readClients, bool enqueueDrain = true)
    {
        if (stopping) return;
        lock (subscriptionReadGate)
        {
            if (stopping) return;
            lock (slotGate)
            {
                if (stopping || !Equals(activeOutbound, outboundCharacteristic) || activeCharacteristic is null)
                    return;
            }
            var clients = readClients();
            lock (slotGate)
            {
                if (stopping || !Equals(activeOutbound, outboundCharacteristic) || activeCharacteristic is null)
                    return;
                var snapshotSeq = ++nextSubscriptionGeneration;
                var currentByPeer = new Dictionary<string, object>(StringComparer.Ordinal);
                foreach (var client in clients)
                    currentByPeer.TryAdd(client.PeerId, client.Session);

                foreach (var peerId in knownSubscribedSessions.Keys.ToArray())
                {
                    var known = knownSubscribedSessions[peerId];
                    if (!currentByPeer.TryGetValue(peerId, out var currentSession) || !Equals(currentSession, known.Session))
                    {
                        knownSubscribedSessions.Remove(peerId);
                        AdvancePeerGenerationLocked(peerId, known.SubscriptionGeneration + 1);
                    }
                }

                foreach (var key in slotsByPeer.Keys.ToArray())
                {
                    var slot = slotsByPeer[key];
                    var stillSubscribed = currentByPeer.TryGetValue(slot.PeerId, out var currentSession)
                        && Equals(currentSession, slot.Session);
                    if (!stillSubscribed || !Equals(slot.Characteristic, activeCharacteristic))
                    {
                        InvalidateSlotOnlyLocked(slot);
                        AdvancePeerGenerationLocked(slot.PeerId, slot.SubscriptionGeneration + 1);
                    }
                }

                var stampedClients = new BleSubscribedClient[clients.Length];
                for (var i = 0; i < clients.Length; i++)
                {
                    var client = clients[i];
                    long peerSubGen;
                    if (knownSubscribedSessions.TryGetValue(client.PeerId, out var active) && Equals(active.Session, client.Session))
                    {
                        peerSubGen = active.SubscriptionGeneration;
                    }
                    else
                    {
                        peerSubGen = nextSubscriptionGenerationByPeer.GetValueOrDefault(client.PeerId, 1);
                        nextSubscriptionGenerationByPeer[client.PeerId] = peerSubGen;
                        knownSubscribedSessions[client.PeerId] = (client.Session, peerSubGen);
                    }
                    stampedClients[i] = client with { SubscriptionGeneration = peerSubGen };
                }

                var maxGenerations = new Dictionary<string, long>(StringComparer.Ordinal);
                foreach (var (peerId, nextGen) in nextSubscriptionGenerationByPeer)
                {
                    maxGenerations[peerId] = knownSubscribedSessions.TryGetValue(peerId, out var active)
                        ? active.SubscriptionGeneration
                        : nextGen - 1;
                }

                pendingSubscriptionSnapshots.Enqueue(new(snapshotSeq, stampedClients, maxGenerations));
            }
            if (enqueueDrain && !worker.IsCompleted)
                _ = work.Writer.TryWrite(new WorkItem(DrainPendingSubscriptionsAsync));
        }
    }

    public async Task DrainPendingSubscriptionsAsync()
    {
        while (!stopping)
        {
            SubscriptionSnapshot? next;
            lock (slotGate)
            {
                if (stopping || !pendingSubscriptionSnapshots.TryDequeue(out next))
                    return;
                activeSubscriptionSnapshot = next;
            }
            try
            {
                if (applySubscriptionsAsync is not null)
                    await applySubscriptionsAsync(next.Clients, next.Generation);
            }
            finally
            {
                lock (slotGate)
                {
                    if (ReferenceEquals(activeSubscriptionSnapshot, next))
                        activeSubscriptionSnapshot = null;
                }
            }
        }
    }

    public bool IsCurrentSubscription(string peerId, object session, long subscriptionGeneration)
    {
        lock (slotGate)
        {
            return !stopping
                && knownSubscribedSessions.TryGetValue(peerId, out var known)
                && Equals(known.Session, session)
                && known.SubscriptionGeneration == subscriptionGeneration;
        }
    }

    public bool ShouldKeepPeerForSnapshot(string peerId, BleSubscriptionSlot? slot, long snapshotGeneration)
    {
        if (slot is null) return false;
        lock (slotGate)
        {
            return activeSubscriptionSnapshot is { } active
                && active.Generation == snapshotGeneration
                && active.MaxGenerationsAtCapture.TryGetValue(peerId, out var maxGen)
                && slot.SubscriptionGeneration > maxGen;
        }
    }

    public BleSubscriptionSlot? BindPeer(
        object characteristic,
        string peerId,
        object session,
        object peer,
        long? subscriptionGeneration = null)
    {
        BleSubscriptionSlot? result = null;
        var shouldRejectPeer = false;
        lock (slotGate)
        {
            if (stopping || !Equals(activeCharacteristic, characteristic))
                return null;
            if (subscriptionGeneration is { } explicitSubGen)
            {
                if (!knownSubscribedSessions.TryGetValue(peerId, out var known)
                    || !Equals(known.Session, session)
                    || known.SubscriptionGeneration != explicitSubGen)
                {
                    return null;
                }
            }
            var targetSubGen = subscriptionGeneration
                ?? (knownSubscribedSessions.TryGetValue(peerId, out var activeKnown) && Equals(activeKnown.Session, session)
                    ? activeKnown.SubscriptionGeneration
                    : nextSubscriptionGenerationByPeer.GetValueOrDefault(peerId, 1));
            if (slotsByPeer.TryGetValue(peerId, out var existing))
            {
                if (!existing.Invalidated
                    && Equals(existing.Characteristic, characteristic)
                    && Equals(existing.Session, session)
                    && existing.SubscriptionGeneration == targetSubGen
                    && existing.Peer is null)
                {
                    existing.Peer = peer;
                    result = existing;
                    shouldRejectPeer = existing.Rejected;
                }
                else
                {
                    InvalidateSlotOnlyLocked(existing);
                }
            }
            if (result is null)
            {
                var created = new BleSubscriptionSlot(
                    characteristic,
                    peerId,
                    session,
                    ++nextGeneration,
                    targetSubGen)
                {
                    Peer = peer
                };
                slotsByPeer[peerId] = created;
                TrackLiveSlotLocked(created);
                nextSubscriptionGenerationByPeer.TryAdd(peerId, targetSubGen);
                result = created;
            }
        }
        if (shouldRejectPeer) rejectPeerSync?.Invoke(peer);
        return result;
    }

    public bool TryAttachPeerToSlot(BleSubscriptionSlot slot, object peer)
    {
        var shouldRejectPeer = false;
        lock (slotGate)
        {
            if (stopping
                || slot.Invalidated
                || !Equals(activeCharacteristic, slot.Characteristic)
                || !slotsByPeer.TryGetValue(slot.PeerId, out var current)
                || !ReferenceEquals(current, slot)
                || slot.Peer is not null)
            {
                return false;
            }
            slot.Peer = peer;
            shouldRejectPeer = slot.Rejected;
        }
        if (shouldRejectPeer) rejectPeerSync?.Invoke(peer);
        return true;
    }

    public void InvalidateSlot(BleSubscriptionSlot slot)
    {
        lock (slotGate)
        {
            InvalidateSlotOnlyLocked(slot);
            if (knownSubscribedSessions.TryGetValue(slot.PeerId, out var known)
                && Equals(known.Session, slot.Session)
                && known.SubscriptionGeneration == slot.SubscriptionGeneration)
            {
                knownSubscribedSessions.Remove(slot.PeerId);
                AdvancePeerGenerationLocked(slot.PeerId, slot.SubscriptionGeneration + 1);
            }
        }
    }

    public void RetireSlot(BleSubscriptionSlot slot)
    {
        lock (slotGate) slot.Rejected = true;
    }

    public void EnqueueWrite(
        object characteristic,
        string peerId,
        object session,
        int estimatedBytes,
        bool sessionClosed,
        Func<CancellationToken, Task<BleWriteRequestData?>> getRequestAsync,
        Action completeDeferral,
        Action rejectSync)
    {
        var completion = new CompletionOnce(completeDeferral, e => log($"write deferral error={e.GetType().Name}"));
        var slot = !stopping && !sessionClosed ? CaptureWriteSlot(characteristic, peerId, session) : null;
        if (slot is null)
        {
            try { rejectSync(); }
            finally { completion.Complete(); }
            return;
        }
        var lease = admission.TryEnter(peerId, estimatedBytes);
        if (lease is null)
        {
            RetireSlotAndScheduleDisconnect(slot, "write limit exceeded; retiring connection count=1");
            try { rejectSync(); }
            finally { completion.Complete(); }
            return;
        }
        if (ingestWorker.IsCompleted || !ingest.Writer.TryWrite(new(characteristic, slot, slot.Generation, getRequestAsync, completion, lease, rejectSync)))
        {
            try { rejectSync(); }
            finally { try { completion.Complete(); } finally { lease.Dispose(); } }
        }
    }

    public async Task ShutdownAsync(Func<Task> stopProviderAsync, Action? stopImmediate = null)
    {
        stopping = true;
        stop.Cancel();
        SetActiveCharacteristic(null);
        try { stopImmediate?.Invoke(); }
        catch (Exception e) { log($"stop provider error={e.GetType().Name}"); }

        ingest.Writer.TryComplete();
        try { await ingestWorker.WaitAsync(shutdownTimeout); }
        catch (TimeoutException) { log("ingest worker shutdown timeout"); }
        catch (Exception e) { log($"ingest worker error={e.GetType().Name}"); }

        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var ranStop = 0;
        if (!worker.IsCompleted && work.Writer.TryWrite(new WorkItem(
            async () =>
            {
                if (Interlocked.Exchange(ref ranStop, 1) == 0)
                {
                    try { await stopProviderAsync(); }
                    catch (Exception e) { log($"stop provider error={e.GetType().Name}"); }
                }
                stopped.TrySetResult();
            },
            () => stopped.TrySetResult())))
        {
            try { await Task.WhenAny(stopped.Task, workerStopped.Task).WaitAsync(shutdownTimeout); }
            catch (TimeoutException) { log("worker stop provider timeout"); }
        }
        if (Interlocked.Exchange(ref ranStop, 1) == 0)
        {
            try { await stopProviderAsync().WaitAsync(shutdownTimeout); }
            catch (TimeoutException) { log("stop provider timeout"); }
            catch (Exception e) { log($"stop provider error={e.GetType().Name}"); }
        }

        work.Writer.TryComplete();
        try { await worker.WaitAsync(shutdownTimeout); }
        catch (TimeoutException) { log("worker shutdown timeout"); }
        catch (Exception e) { log($"worker error={e.GetType().Name}"); }
        if (ingestWorker.IsCompleted && worker.IsCompleted) stop.Dispose();
    }

    private void TrackLiveSlotLocked(BleSubscriptionSlot slot)
    {
        if (!liveSlotsByPeer.TryGetValue(slot.PeerId, out var list))
        {
            list = [];
            liveSlotsByPeer[slot.PeerId] = list;
        }
        list.Add(slot);
    }

    private void InvalidateSlotOnlyLocked(BleSubscriptionSlot slot)
    {
        slot.Invalidated = true;
        if (liveSlotsByPeer.TryGetValue(slot.PeerId, out var list))
        {
            list.Remove(slot);
            if (list.Count == 0) liveSlotsByPeer.Remove(slot.PeerId);
        }
        if (slotsByPeer.TryGetValue(slot.PeerId, out var current)
            && ReferenceEquals(current, slot)
            && current.SubscriptionGeneration == slot.SubscriptionGeneration)
        {
            slotsByPeer.Remove(slot.PeerId);
        }
    }

    private void InvalidateEarlierSlotsForPeerLocked(string peerId, long minActiveGeneration)
    {
        if (!liveSlotsByPeer.TryGetValue(peerId, out var list)) return;
        foreach (var candidate in list.ToArray())
        {
            if (candidate.SubscriptionGeneration < minActiveGeneration)
                InvalidateSlotOnlyLocked(candidate);
        }
    }

    private void AdvancePeerGenerationLocked(string peerId, long minNextGeneration)
    {
        var current = nextSubscriptionGenerationByPeer.GetValueOrDefault(peerId, 1);
        if (minNextGeneration > current)
            nextSubscriptionGenerationByPeer[peerId] = minNextGeneration;
    }

    private BleSubscriptionSlot? CaptureWriteSlot(object characteristic, string peerId, object session)
    {
        lock (slotGate)
        {
            if (stopping || !Equals(activeCharacteristic, characteristic)) return null;
            if (slotsByPeer.TryGetValue(peerId, out var existing) && !existing.Invalidated)
            {
                if (Equals(existing.Characteristic, characteristic) && Equals(existing.Session, session))
                {
                    if (existing.Rejected) return null;
                    return existing;
                }
                if (existing.Peer is not null) return null;
                if (knownSubscribedSessions.TryGetValue(peerId, out var known) && Equals(known.Session, existing.Session))
                    return null;
                InvalidateSlotOnlyLocked(existing);
                AdvancePeerGenerationLocked(peerId, existing.SubscriptionGeneration + 1);
            }
            else if (knownSubscribedSessions.TryGetValue(peerId, out var activeKnown) && !Equals(activeKnown.Session, session))
            {
                return null;
            }
            var subGen = knownSubscribedSessions.TryGetValue(peerId, out var currentKnown)
                ? currentKnown.SubscriptionGeneration
                : nextSubscriptionGenerationByPeer.GetValueOrDefault(peerId, 1);
            nextSubscriptionGenerationByPeer.TryAdd(peerId, subGen);
            var created = new BleSubscriptionSlot(characteristic, peerId, session, ++nextGeneration, subGen);
            slotsByPeer[peerId] = created;
            TrackLiveSlotLocked(created);
            return created;
        }
    }

    private bool IsValidForProcessing(BleSubscriptionSlot slot, object characteristic, long generation)
    {
        if (stopping) return false;
        lock (slotGate)
        {
            return IsValidForProcessingLocked(slot, characteristic, generation);
        }
    }

    private bool IsValidForProcessingLocked(BleSubscriptionSlot slot, object characteristic, long generation) =>
        !stopping
        && Equals(activeCharacteristic, characteristic)
        && Equals(slot.Characteristic, characteristic)
        && slot.Generation == generation
        && !slot.Invalidated
        && !slot.Rejected
        && slotsByPeer.TryGetValue(slot.PeerId, out var current)
        && ReferenceEquals(current, slot);

    private bool IsSlotBoundAndAlive(BleSubscriptionSlot slot, object characteristic, long generation)
    {
        if (stopping) return false;
        lock (slotGate)
        {
            return !stopping
                && Equals(activeCharacteristic, characteristic)
                && Equals(slot.Characteristic, characteristic)
                && slot.Generation == generation
                && !slot.Invalidated
                && slotsByPeer.TryGetValue(slot.PeerId, out var current)
                && ReferenceEquals(current, slot);
        }
    }

    private void RetireSlotAndScheduleDisconnect(BleSubscriptionSlot slot, string logMessage)
    {
        object? peer;
        var newlyRetired = false;
        lock (slotGate)
        {
            if (!slot.Invalidated && !slot.Rejected)
            {
                slot.Rejected = true;
                newlyRetired = true;
            }
            peer = slot.Peer;
        }
        if (!newlyRetired) return;
        // Mark both the slot and the peer before logging so waiters on the coordinator gate
        // observe the retirement immediately.
        if (peer is not null) rejectPeerSync?.Invoke(peer);
        log(logMessage);
        if (!worker.IsCompleted)
        {
            _ = work.Writer.TryWrite(new WorkItem(async () =>
            {
                if (stopping) return;
                object? currentPeer;
                lock (slotGate) currentPeer = slot.Peer;
                if (currentPeer is null)
                {
                    await refreshSubscriptionsAsync();
                    lock (slotGate) currentPeer = slot.Peer;
                    if (currentPeer is null)
                    {
                        InvalidateSlot(slot);
                        return;
                    }
                }
                bool invalidated;
                lock (slotGate) invalidated = slot.Invalidated;
                if (!invalidated)
                {
                    rejectPeerSync?.Invoke(currentPeer);
                    await disconnectPeerAsync(currentPeer);
                }
            }));
        }
    }

    private async Task IngestLoopAsync()
    {
        await foreach (var item in ingest.Reader.ReadAllAsync())
        {
            BleWriteRequestData? request = null;
            var handedOff = false;
            try
            {
                if (!IsValidForProcessing(item.Slot, item.Characteristic, item.Generation))
                    continue;
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                timeout.CancelAfter(requestTimeout);
                request = await item.GetRequestAsync(timeout.Token);
                if (request is null || !IsValidForProcessing(item.Slot, item.Characteristic, item.Generation))
                {
                    if (request is { IsWithResponse: true }) TryRespondError(request, 0x0E);
                    if (request is null && IsValidForProcessing(item.Slot, item.Characteristic, item.Generation))
                        RetireSlotAndScheduleDisconnect(item.Slot, "write request missing; retiring connection count=1");
                    continue;
                }
                if (!item.Lease.TryAdjust(Math.Max((long)minPacketCharge, request.PayloadLength)))
                {
                    if (request.IsWithResponse) TryRespondError(request, 0x11);
                    if (IsValidForProcessing(item.Slot, item.Characteristic, item.Generation))
                        RetireSlotAndScheduleDisconnect(item.Slot, "write limit exceeded; retiring connection count=1");
                    continue;
                }
                var bytes = request.CopyBytes();
                if (bytes.Length != request.PayloadLength && !item.Lease.TryAdjust(Math.Max((long)minPacketCharge, bytes.Length)))
                {
                    if (request.IsWithResponse) TryRespondError(request, 0x11);
                    if (IsValidForProcessing(item.Slot, item.Characteristic, item.Generation))
                        RetireSlotAndScheduleDisconnect(item.Slot, "write limit exceeded; retiring connection count=1");
                    continue;
                }
                if (!request.IsWithResponse)
                {
                    // Release the WinRT deferral immediately after copying the payload so
                    // downstream disk I/O or gate contention never stalls BLE packet reception.
                    item.Completion.Complete();
                    handedOff = !worker.IsCompleted && work.Writer.TryWrite(new WorkItem(
                        () => ProcessItemAsync(item.Slot, item.Characteristic, item.Generation, request.Offset, bytes, null, null, item.Lease),
                        () => item.Lease.Dispose()));
                }
                else
                {
                    handedOff = !worker.IsCompleted && work.Writer.TryWrite(new WorkItem(
                        () => ProcessItemAsync(item.Slot, item.Characteristic, item.Generation, request.Offset, bytes, request, item.Completion, item.Lease),
                        () =>
                        {
                            TryRespondError(request, 0x0E);
                            try { item.Completion.Complete(); }
                            finally { item.Lease.Dispose(); }
                        }));
                }
                if (!handedOff)
                {
                    if (request.IsWithResponse) TryRespondError(request, 0x11);
                    if (IsValidForProcessing(item.Slot, item.Characteristic, item.Generation))
                        RetireSlotAndScheduleDisconnect(item.Slot, "write handoff failed; retiring connection count=1");
                }
            }
            catch (Exception e)
            {
                log($"write request error={e.GetType().Name}");
                if (request is { IsWithResponse: true }) TryRespondError(request, 0x0E);
                if (IsValidForProcessing(item.Slot, item.Characteristic, item.Generation))
                    RetireSlotAndScheduleDisconnect(item.Slot, "write request failed; retiring connection count=1");
            }
            finally
            {
                if (!handedOff)
                {
                    try { item.Completion.Complete(); }
                    finally { item.Lease.Dispose(); }
                }
            }
        }
    }

    private async Task ProcessItemAsync(
        BleSubscriptionSlot slot,
        object characteristic,
        long generation,
        uint offset,
        byte[] bytes,
        BleWriteRequestData? request,
        CompletionOnce? completion,
        WriteAdmission.WriteLease lease)
    {
        try
        {
            var ok = false;
            if (IsValidForProcessing(slot, characteristic, generation))
            {
                object? peer;
                lock (slotGate) peer = slot.Peer;
                if (peer is null)
                {
                    await refreshSubscriptionsAsync();
                    if (!IsSlotBoundAndAlive(slot, characteristic, generation))
                    {
                        peer = null;
                    }
                    else
                    {
                        lock (slotGate) peer = slot.Peer;
                        if (peer is null) InvalidateSlot(slot);
                    }
                }
                if (peer is not null && IsValidForProcessing(slot, characteristic, generation))
                    ok = await DeliverWithHelloTrackingAsync(slot, characteristic, generation, peer, offset, bytes);
            }
            if (request is not null)
            {
                if (ok) request.RespondSuccess();
                else TryRespondError(request, 0x0E);
            }
        }
        catch (Exception e)
        {
            log($"write request error={e.GetType().Name}");
            object? peer;
            lock (slotGate) peer = slot.Peer;
            if (peer is not null && IsValidForProcessing(slot, characteristic, generation))
                await disconnectPeerAsync(peer);
            if (request is not null) TryRespondError(request, 0x0E);
        }
        finally
        {
            try { completion?.Complete(); }
            finally { lease.Dispose(); }
        }
    }

    private async Task<bool> DeliverWithHelloTrackingAsync(
        BleSubscriptionSlot slot,
        object characteristic,
        long generation,
        object peer,
        uint offset,
        byte[] bytes)
    {
        if (!slot.SawHello)
        {
            if (slot.CollectingHello
                && rehandshakePeerAsync is not null
                && offset == 0
                && bytes.Length >= 2
                && (bytes[0] & 1) != 0
                && bytes[1] == 1)
            {
                ResetPendingHello(slot);
                slot.SawHello = true;
            }
            else
            {
                if (offset == 0 && bytes.Length >= 2 && (bytes[0] & 1) != 0 && bytes[1] == 1)
                    lock (slotGate) InvalidateEarlierSlotsForPeerLocked(slot.PeerId, slot.SubscriptionGeneration);
                if (TrackInitialHelloCompleted(slot, offset, bytes))
                {
                    slot.SawHello = true;
                    lock (slotGate) InvalidateEarlierSlotsForPeerLocked(slot.PeerId, slot.SubscriptionGeneration);
                }
                return await deliverPacketAsync(peer, offset, bytes);
            }
        }

        if (rehandshakePeerAsync is null)
            return await deliverPacketAsync(peer, offset, bytes);

        if (!slot.CollectingHello)
        {
            if (offset != 0 || bytes.Length < 2 || (bytes[0] & 1) == 0 || bytes[1] != 1)
                return await deliverPacketAsync(peer, offset, bytes);
            if ((bytes[0] & 2) != 0)
            {
                if (bytes.Length == 51)
                    return await ExecuteRehandshakeAsync(slot, characteristic, generation, peer, [bytes]);
                return await deliverPacketAsync(peer, offset, bytes);
            }
            if (bytes.Length - 1 > 50)
                return await deliverPacketAsync(peer, offset, bytes);
            slot.CollectingHello = true;
            slot.PendingHelloPayloadBytes = bytes.Length - 1;
            slot.PendingHelloPackets = [bytes];
            return true;
        }

        var buffered = slot.PendingHelloPackets!;
        if (offset == 0 && bytes.Length >= 2 && (bytes[0] & 1) == 0)
        {
            var nextPayloadBytes = slot.PendingHelloPayloadBytes + (bytes.Length - 1);
            if (nextPayloadBytes <= 50)
            {
                if ((bytes[0] & 2) != 0)
                {
                    if (nextPayloadBytes == 50)
                    {
                        buffered.Add(bytes);
                        ResetPendingHello(slot);
                        return await ExecuteRehandshakeAsync(slot, characteristic, generation, peer, buffered);
                    }
                }
                else
                {
                    slot.PendingHelloPayloadBytes = nextPayloadBytes;
                    buffered.Add(bytes);
                    return true;
                }
            }
        }

        ResetPendingHello(slot);
        foreach (var pkt in buffered)
        {
            if (!await deliverPacketAsync(peer, 0, pkt))
                return false;
        }
        return await deliverPacketAsync(peer, offset, bytes);
    }

    private static bool TrackInitialHelloCompleted(BleSubscriptionSlot slot, uint offset, byte[] bytes)
    {
        if (offset != 0 || bytes.Length < 2)
        {
            ResetPendingHello(slot);
            return false;
        }
        if (!slot.CollectingHello)
        {
            if ((bytes[0] & 1) == 0 || bytes[1] != 1) return false;
            if ((bytes[0] & 2) != 0) return bytes.Length == 51;
            if (bytes.Length - 1 > 50) return false;
            slot.CollectingHello = true;
            slot.PendingHelloPayloadBytes = bytes.Length - 1;
            return false;
        }
        if ((bytes[0] & 1) != 0)
        {
            ResetPendingHello(slot);
            return false;
        }
        slot.PendingHelloPayloadBytes += bytes.Length - 1;
        if (slot.PendingHelloPayloadBytes > 50)
        {
            ResetPendingHello(slot);
            return false;
        }
        if ((bytes[0] & 2) == 0) return false;
        var completed = slot.PendingHelloPayloadBytes == 50;
        ResetPendingHello(slot);
        return completed;
    }

    private static void ResetPendingHello(BleSubscriptionSlot slot)
    {
        slot.CollectingHello = false;
        slot.PendingHelloPayloadBytes = 0;
        slot.PendingHelloPackets = null;
    }

    private async Task<bool> ExecuteRehandshakeAsync(
        BleSubscriptionSlot oldSlot,
        object characteristic,
        long generation,
        object oldPeer,
        IReadOnlyList<byte[]> helloPackets)
    {
        BleSubscriptionSlot? newSlot = null;
        lock (slotGate)
        {
            if (IsValidForProcessingLocked(oldSlot, characteristic, generation))
            {
                InvalidateSlotOnlyLocked(oldSlot);
                InvalidateEarlierSlotsForPeerLocked(oldSlot.PeerId, oldSlot.SubscriptionGeneration + 1);
                var nextSubGen = Math.Max(
                    nextSubscriptionGenerationByPeer.GetValueOrDefault(oldSlot.PeerId, 1),
                    oldSlot.SubscriptionGeneration + 1);
                nextSubscriptionGenerationByPeer[oldSlot.PeerId] = nextSubGen;
                knownSubscribedSessions[oldSlot.PeerId] = (oldSlot.Session, nextSubGen);
                newSlot = new BleSubscriptionSlot(characteristic, oldSlot.PeerId, oldSlot.Session, ++nextGeneration, nextSubGen)
                {
                    SawHello = true
                };
                slotsByPeer[oldSlot.PeerId] = newSlot;
                TrackLiveSlotLocked(newSlot);
            }
        }
        if (newSlot is null) return false;
        var newPeer = await rehandshakePeerAsync!(oldPeer, newSlot);
        if (newPeer is null) return false;
        foreach (var pkt in helloPackets)
        {
            if (!IsValidForProcessing(newSlot, characteristic, newSlot.Generation))
                return false;
            if (!await deliverPacketAsync(newPeer, 0, pkt))
                return false;
        }
        return true;
    }

    private static void TryRespondError(BleWriteRequestData request, byte error)
    {
        try { request.RespondError(error); }
        catch (Exception) { }
    }
}
