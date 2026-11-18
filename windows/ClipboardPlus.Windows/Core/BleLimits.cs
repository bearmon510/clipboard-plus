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

        public void Adjust(int actualBytes)
        {
            var next = Math.Max(1, actualBytes);
            lock (owner.gate)
            {
                if (disposed) return;
                var delta = next - charged;
                if (delta == 0) return;
                charged = next;
                owner.bytesByPeer[peer] = owner.bytesByPeer.GetValueOrDefault(peer) + delta;
                owner.totalBytes += delta;
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
    byte[] Bytes,
    bool IsWithResponse,
    Action RespondSuccess,
    Action<byte> RespondError);

internal sealed class BleSubscriptionSlot(object characteristic, string peerId, long generation)
{
    public object Characteristic { get; } = characteristic;
    public string PeerId { get; } = peerId;
    public long Generation { get; } = generation;
    public object? Peer { get; set; }
    public bool Rejected { get; set; }
    public bool Invalidated { get; set; }
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

    private sealed record PendingWrite(
        object Characteristic,
        BleSubscriptionSlot Slot,
        long Generation,
        Func<CancellationToken, Task<BleWriteRequestData?>> GetRequestAsync,
        CompletionOnce Completion,
        WriteAdmission.WriteLease Lease);

    private readonly WriteAdmission admission;
    private readonly Action<string> log;
    private readonly Func<Task> refreshSubscriptionsAsync;
    private readonly Func<object, uint, byte[], Task<bool>> deliverPacketAsync;
    private readonly Func<object, Task> disconnectPeerAsync;
    private readonly Action<object>? rejectPeerSync;
    private readonly TimeSpan requestTimeout;
    private readonly int minPacketCharge;
    private readonly Channel<Func<Task>> work = Channel.CreateUnbounded<Func<Task>>(new UnboundedChannelOptions { SingleReader = true });
    private readonly Channel<PendingWrite> ingest = Channel.CreateUnbounded<PendingWrite>(new UnboundedChannelOptions { SingleReader = true });
    private readonly CancellationTokenSource stop = new();
    private readonly object slotGate = new();
    private readonly Dictionary<string, BleSubscriptionSlot> slotsByPeer = [];
    private object? activeCharacteristic;
    private long nextGeneration;
    private volatile bool stopping;
    private readonly Task worker;
    private readonly Task ingestWorker;
    private readonly TaskCompletionSource workerStopped = new(TaskCreationOptions.RunContinuationsAsynchronously);

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
        Func<Task>? onIngestStart = null)
    {
        this.admission = admission;
        this.log = log;
        this.refreshSubscriptionsAsync = refreshSubscriptionsAsync;
        this.deliverPacketAsync = deliverPacketAsync;
        this.disconnectPeerAsync = disconnectPeerAsync;
        this.rejectPeerSync = rejectPeerSync;
        this.requestTimeout = requestTimeout ?? TimeSpan.FromSeconds(10);
        this.minPacketCharge = Math.Max(1, minPacketCharge);
        worker = Task.Run(async () =>
        {
            try
            {
                if (onWorkerStart is not null) await onWorkerStart();
                await foreach (var action in work.Reader.ReadAllAsync())
                {
                    try { await action(); }
                    catch (Exception e) { log($"bluetooth operation error={e.GetType().Name}"); }
                }
            }
            finally { workerStopped.TrySetResult(); }
        });
        ingestWorker = Task.Run(async () =>
        {
            if (onIngestStart is not null) await onIngestStart();
            await IngestLoopAsync();
        });
    }

    public Task QueueWork(Func<Task> action)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (worker.IsCompleted || !work.Writer.TryWrite(async () =>
        {
            try { await action(); }
            catch (Exception e) { log($"bluetooth operation error={e.GetType().Name}"); }
            finally { done.TrySetResult(); }
        }))
        {
            done.TrySetResult();
            return done.Task;
        }
        return done.Task.IsCompleted ? done.Task : Task.WhenAny(done.Task, workerStopped.Task);
    }

    public void SetActiveCharacteristic(object? characteristic)
    {
        lock (slotGate)
        {
            activeCharacteristic = characteristic;
            if (characteristic is null)
            {
                foreach (var slot in slotsByPeer.Values) slot.Invalidated = true;
                slotsByPeer.Clear();
                return;
            }
            foreach (var key in slotsByPeer.Keys.ToArray())
            {
                var slot = slotsByPeer[key];
                if (!ReferenceEquals(slot.Characteristic, characteristic))
                {
                    slot.Invalidated = true;
                    slotsByPeer.Remove(key);
                }
            }
        }
    }

    public BleSubscriptionSlot BindPeer(object characteristic, string peerId, object peer)
    {
        lock (slotGate)
        {
            if (slotsByPeer.TryGetValue(peerId, out var existing))
            {
                if (!existing.Invalidated && ReferenceEquals(existing.Characteristic, characteristic) && existing.Peer is null)
                {
                    existing.Peer = peer;
                    return existing;
                }
                existing.Invalidated = true;
            }
            var created = new BleSubscriptionSlot(characteristic, peerId, ++nextGeneration) { Peer = peer };
            slotsByPeer[peerId] = created;
            return created;
        }
    }

    public void InvalidateSlot(BleSubscriptionSlot slot)
    {
        lock (slotGate)
        {
            slot.Invalidated = true;
            if (slotsByPeer.TryGetValue(slot.PeerId, out var current) && ReferenceEquals(current, slot))
                slotsByPeer.Remove(slot.PeerId);
        }
    }

    public void RetireSlot(BleSubscriptionSlot slot)
    {
        lock (slotGate) slot.Rejected = true;
    }

    public void EnqueueWrite(
        object characteristic,
        string peerId,
        int estimatedBytes,
        bool sessionClosed,
        Func<CancellationToken, Task<BleWriteRequestData?>> getRequestAsync,
        Action completeDeferral,
        Action rejectSync)
    {
        var completion = new CompletionOnce(completeDeferral, e => log($"write deferral error={e.GetType().Name}"));
        var slot = !stopping && !sessionClosed ? CaptureWriteSlot(characteristic, peerId) : null;
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
        if (!ingest.Writer.TryWrite(new(characteristic, slot, slot.Generation, getRequestAsync, completion, lease)))
        {
            try { rejectSync(); }
            finally { try { completion.Complete(); } finally { lease.Dispose(); } }
        }
    }

    public async Task ShutdownAsync(Func<Task> stopProviderAsync)
    {
        stopping = true;
        stop.Cancel();
        ingest.Writer.TryComplete();
        try { await ingestWorker; }
        catch (Exception e) { log($"ingest worker error={e.GetType().Name}"); }

        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var ranStop = 0;
        if (!worker.IsCompleted && work.Writer.TryWrite(async () =>
        {
            if (Interlocked.Exchange(ref ranStop, 1) == 0)
            {
                try { await stopProviderAsync(); }
                catch (Exception e) { log($"stop provider error={e.GetType().Name}"); }
            }
            stopped.TrySetResult();
        }))
        {
            await Task.WhenAny(stopped.Task, workerStopped.Task);
        }
        if (Interlocked.Exchange(ref ranStop, 1) == 0)
        {
            try { await stopProviderAsync(); }
            catch (Exception e) { log($"stop provider error={e.GetType().Name}"); }
        }

        work.Writer.TryComplete();
        try { await worker; }
        catch (Exception e) { log($"worker error={e.GetType().Name}"); }
        stop.Dispose();
    }

    private BleSubscriptionSlot? CaptureWriteSlot(object characteristic, string peerId)
    {
        lock (slotGate)
        {
            if (stopping || !ReferenceEquals(activeCharacteristic, characteristic)) return null;
            if (slotsByPeer.TryGetValue(peerId, out var existing) && !existing.Invalidated)
            {
                if (existing.Rejected || !ReferenceEquals(existing.Characteristic, characteristic)) return null;
                return existing;
            }
            var created = new BleSubscriptionSlot(characteristic, peerId, ++nextGeneration);
            slotsByPeer[peerId] = created;
            return created;
        }
    }

    private bool IsValidForProcessing(BleSubscriptionSlot slot, object characteristic, long generation)
    {
        if (stopping) return false;
        lock (slotGate)
        {
            return !stopping
                && ReferenceEquals(activeCharacteristic, characteristic)
                && ReferenceEquals(slot.Characteristic, characteristic)
                && slot.Generation == generation
                && !slot.Invalidated
                && !slot.Rejected
                && slotsByPeer.TryGetValue(slot.PeerId, out var current)
                && ReferenceEquals(current, slot);
        }
    }

    private bool IsSlotBoundAndAlive(BleSubscriptionSlot slot, object characteristic, long generation)
    {
        if (stopping) return false;
        lock (slotGate)
        {
            return !stopping
                && ReferenceEquals(activeCharacteristic, characteristic)
                && ReferenceEquals(slot.Characteristic, characteristic)
                && slot.Generation == generation
                && !slot.Invalidated;
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
        log(logMessage);
        if (peer is not null) rejectPeerSync?.Invoke(peer);
        _ = work.Writer.TryWrite(async () =>
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
        });
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
                item.Lease.Adjust(Math.Max(minPacketCharge, request.Bytes.Length));
                if (!request.IsWithResponse)
                {
                    // Release the WinRT deferral immediately after copying the payload so
                    // downstream disk I/O or gate contention never stalls BLE packet reception.
                    item.Completion.Complete();
                    handedOff = work.Writer.TryWrite(() =>
                        ProcessItemAsync(item.Slot, item.Characteristic, item.Generation, request.Offset, request.Bytes, null, null, item.Lease));
                }
                else
                {
                    handedOff = work.Writer.TryWrite(() =>
                        ProcessItemAsync(item.Slot, item.Characteristic, item.Generation, request.Offset, request.Bytes, request, item.Completion, item.Lease));
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
                    ok = await deliverPacketAsync(peer, offset, bytes);
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

    private static void TryRespondError(BleWriteRequestData request, byte error)
    {
        try { request.RespondError(error); }
        catch (Exception) { }
    }
}
