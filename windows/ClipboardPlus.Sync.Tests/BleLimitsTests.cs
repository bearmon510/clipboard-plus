using System.Threading.Channels;
using ClipboardPlus.Windows.Core;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class BleLimitsTests
{
    [Fact]
    public void AttributeBoundaryRoundTrips512AndRejects513()
    {
        var frame = new byte[1023];
        var packets = ClipboardPlus.Sync.SyncPacketizer.Split(frame, 512);
        Assert.Equal(new[] { 512, 512, 2 }, packets.Select(p => p.Length));
        var assembler = new ClipboardPlus.Sync.SyncPacketAssembler(512);
        byte[]? complete = null;
        foreach (var packet in packets) complete = assembler.Append(packet);
        Assert.Equal(frame, complete);
        var oversized = new byte[513]; oversized[0] = 3;
        Assert.Equal(ClipboardPlus.Sync.SyncError.Packet,
            Assert.Throws<ClipboardPlus.Sync.SyncProtocolException>(() => assembler.Append(oversized)).Code);
    }

    [Fact]
    public async Task QueuedExecutingRejectedFailedAndClosedRequestsCompleteExactlyOnce()
    {
        var admission = new WriteAdmission(globalByteLimit: 20, peerByteLimit: 10);
        var channel = Channel.CreateBounded<Func<Task>>(2);
        var completions = new int[6];
        var rejections = new List<int>();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Dispatch(int id, string peer, Func<Task> action, int bytes = 10) => admission.Dispatch(channel.Writer, peer,
            action, () => rejections.Add(id), () => completions[id]++, bytes: bytes);
        Dispatch(0, "a", async () => { started.SetResult(); await release.Task; });
        var active = (await channel.Reader.ReadAsync())();
        await started.Task;
        Dispatch(1, "a", () => throw new Exception("must not run")); // Executing bytes count too.
        Dispatch(2, "b", () => Task.FromException(new IOException()));
        Dispatch(3, "c", () => throw new Exception("must not run")); // Global byte limit.
        release.SetResult(); await active;
        await Assert.ThrowsAsync<IOException>((await channel.Reader.ReadAsync()));
        // A full channel can be caused by other BLE events, even with available admission.
        Assert.True(channel.Writer.TryWrite(() => Task.CompletedTask));
        Assert.True(channel.Writer.TryWrite(() => Task.CompletedTask));
        Dispatch(4, "a", () => throw new Exception("must not run"));
        channel.Writer.Complete();
        Dispatch(5, "a", () => throw new Exception("must not run"));
        Assert.Equal(new[] { 1, 3, 4, 5 }, rejections);
        Assert.All(completions, count => Assert.Equal(1, count));
        Assert.Equal(0, admission.TotalBytes);
        using var recovered = admission.TryEnter("a", 10); Assert.NotNull(recovered);
    }

    [Theory]
    [InlineData(0, 20)]
    [InlineData(23, 20)]
    [InlineData(185, 182)]
    [InlineData(514, 511)]
    [InlineData(515, 512)]
    [InlineData(517, 512)]
    [InlineData(65535, 512)]
    public void NotificationSizeIncludesAttAndAttributeLimits(int pdu, int expected) =>
        Assert.Equal(expected, BleLimits.NotificationBytes(pdu));

    [Fact]
    public void FloodCannotExceedPerPeerOrGlobalByteLimitAndReleasedBytesAreReusable()
    {
        var admission = new WriteAdmission();
        var leases = new List<WriteAdmission.WriteLease>();
        for (var peer = 0; peer < 4; peer++)
        {
            for (var i = 0; i < 2048; i++)
                leases.Add(Assert.IsAssignableFrom<WriteAdmission.WriteLease>(admission.TryEnter(peer.ToString(), 512)));
            Assert.Equal(WriteAdmission.DefaultPeerBytes, admission.PeerBytes(peer.ToString()));
            for (var i = 0; i < 1000; i++) Assert.Null(admission.TryEnter(peer.ToString(), 1));
        }
        Assert.Equal(WriteAdmission.DefaultGlobalBytes, admission.TotalBytes);
        for (var i = 0; i < 1000; i++) Assert.Null(admission.TryEnter("new peer " + i, 1));
        Assert.True(leases[0].TryAdjust(256));
        Assert.Equal(WriteAdmission.DefaultPeerBytes - 256, admission.PeerBytes("0"));
        foreach (var lease in leases) { lease.Dispose(); lease.Dispose(); }
        Assert.Equal(0, admission.TotalBytes);
        using var recovered = admission.TryEnter("new peer", WriteAdmission.DefaultPeerBytes);
        Assert.NotNull(recovered);
    }

    [Fact]
    public async Task ConcurrentByteAdmissionIsBounded()
    {
        var admission = new WriteAdmission(globalByteLimit: 64 * 512, peerByteLimit: 16 * 512);
        var leases = new System.Collections.Concurrent.ConcurrentBag<WriteAdmission.WriteLease>();
        await Task.WhenAll(Enumerable.Range(0, 1000).Select(i => Task.Run(() =>
        {
            var lease = admission.TryEnter((i % 4).ToString(), 512);
            if (lease is not null) leases.Add(lease);
        })));
        Assert.Equal(64, leases.Count);
        Assert.Equal(64 * 512, admission.TotalBytes);
        foreach (var lease in leases) lease.Dispose();
        Assert.Equal(0, admission.TotalBytes);
    }

    [Theory]
    [InlineData(512)]
    [InlineData(182)]
    [InlineData(20)]
    public async Task PausedReceivePipelineAcceptsFourChunkWindowWithoutDropping(int packetLimit)
    {
        var admission = new WriteAdmission();
        var logs = new System.Collections.Concurrent.ConcurrentQueue<string>();
        var delivered = new List<byte[]>();
        var firstEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var allowWork = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var allDelivered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var expectedDelivered = 0;
        var characteristic = new object();
        var peerObj = new object();
        var retiredSync = 0;
        var disconnected = 0;

        var pipeline = new BleWritePipeline(
            admission,
            logs.Enqueue,
            () => Task.CompletedTask,
            async (peer, offset, bytes) =>
            {
                if (delivered.Count == 0)
                {
                    firstEntered.TrySetResult();
                    await allowWork.Task;
                }
                delivered.Add(bytes);
                if (delivered.Count == expectedDelivered)
                    allDelivered.TrySetResult();
                return true;
            },
            _ => { Interlocked.Increment(ref disconnected); return Task.CompletedTask; },
            _ => Interlocked.Increment(ref retiredSync));

        try
        {
            var session = new object();
            pipeline.SetActiveCharacteristic(characteristic);
            var slot = pipeline.BindPeer(characteristic, "pad-1", session, peerObj);
            Assert.NotNull(slot);

            // Build 4 pipelined chunks (32 KiB each + header/GCM overhead), split at packetLimit.
            var packets = new List<byte[]>();
            var key = new byte[32];
            var sender = new SyncFrameSender(key);
            var chunkData = Enumerable.Range(0, SyncProtocol.ChunkBytes).Select(i => (byte)i).ToArray();
            for (var c = 0; c < 4; c++)
            {
                var frame = sender.Seal(SyncMessageCodec.Encode(new SyncChunk(Guid.NewGuid(), c * SyncProtocol.ChunkBytes, chunkData)));
                packets.AddRange(SyncPacketizer.Split(frame, packetLimit));
            }
            expectedDelivered = packets.Count;

            // Enqueue packet 0 and pause work inside deliverPacketAsync before sending the remaining packets.
            var completions = new int[packets.Count];
            var rejections = 0;
            void SendPacket(int i)
            {
                var pkt = packets[i];
                pipeline.EnqueueWrite(
                    characteristic,
                    "pad-1",
                    session,
                    packetLimit,
                    sessionClosed: false,
                    _ => Task.FromResult<BleWriteRequestData?>(new(0, pkt, false, () => { }, _ => { })),
                    () => Interlocked.Increment(ref completions[i]),
                    () => Interlocked.Increment(ref rejections));
            }

            SendPacket(0);
            await firstEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            for (var i = 1; i < packets.Count; i++) SendPacket(i);

            Assert.Equal(0, rejections);
            Assert.Equal(0, retiredSync);
            Assert.Equal(0, disconnected);
            Assert.InRange(admission.TotalBytes, 1, WriteAdmission.DefaultPeerBytes);

            allowWork.SetResult();
            await allDelivered.Task.WaitAsync(TimeSpan.FromSeconds(10));
            await pipeline.QueueWork(() => Task.CompletedTask);

            Assert.Equal(packets.Count, delivered.Count);
            Assert.All(completions, count => Assert.Equal(1, count));
            Assert.Equal(0, admission.TotalBytes);
            Assert.Equal(0, disconnected);
            Assert.False(slot.Rejected);
        }
        finally
        {
            allowWork.TrySetResult();
            await pipeline.ShutdownAsync(() => Task.CompletedTask);
        }
    }

    [Fact]
    public async Task OverByteLimitRetiresConnectionAndLogsOnlyCounts()
    {
        var admission = new WriteAdmission(globalByteLimit: 2048, peerByteLimit: 1024);
        var logs = new System.Collections.Concurrent.ConcurrentQueue<string>();
        var pauseWork = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var workEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var characteristic = new object();
        var peerObj = new object();
        var rejectedSyncCount = 0;
        var retiredPeer = 0;
        var disconnectedPeer = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var pipeline = new BleWritePipeline(
            admission,
            logs.Enqueue,
            () => Task.CompletedTask,
            async (peer, offset, bytes) =>
            {
                workEntered.TrySetResult();
                await pauseWork.Task;
                return true;
            },
            _ => { disconnectedPeer.TrySetResult(); return Task.CompletedTask; },
            _ => Interlocked.Increment(ref retiredPeer));

        try
        {
            var session = new object();
            pipeline.SetActiveCharacteristic(characteristic);
            var slot = pipeline.BindPeer(characteristic, "secret-device-id", session, peerObj);
            Assert.NotNull(slot);
            var payload = new byte[512];

            // First 2 writes fill the 1024-byte peer limit while work is paused.
            for (var i = 0; i < 2; i++)
            {
                pipeline.EnqueueWrite(characteristic, "secret-device-id", session, 512, false,
                    _ => Task.FromResult<BleWriteRequestData?>(new(0, payload, false, () => { }, _ => { })),
                    () => { }, () => Interlocked.Increment(ref rejectedSyncCount));
            }
            await workEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

            // 3rd write exceeds 1024 bytes -> rejected synchronously, slot & peer retired immediately.
            pipeline.EnqueueWrite(characteristic, "secret-device-id", session, 512, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, payload, false, () => { }, _ => { })),
                () => { }, () => Interlocked.Increment(ref rejectedSyncCount));

            Assert.Equal(1, rejectedSyncCount);
            Assert.Equal(1, retiredPeer);
            Assert.True(slot.Rejected);
            Assert.DoesNotContain(logs, l => l.Contains("secret-device-id"));
            Assert.Contains(logs, l => l.Contains("count=1"));

            pauseWork.SetResult();
            await disconnectedPeer.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Equal(0, admission.TotalBytes);
        }
        finally
        {
            pauseWork.TrySetResult();
            await pipeline.ShutdownAsync(() => Task.CompletedTask);
        }
    }

    [Fact]
    public async Task ReconnectOnSameDeviceIdDiscardsStaleQueuedWritesAndReleasesBytes()
    {
        var admission = new WriteAdmission();
        var logs = new System.Collections.Concurrent.ConcurrentQueue<string>();
        var delivered = new List<(object peer, byte[] bytes)>();
        var gateRequest = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var characteristic = new object();
        var oldPeer = new object();
        var newPeer = new object();
        var allStaleCompleted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var newDelivered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var pipeline = new BleWritePipeline(
            admission,
            logs.Enqueue,
            () => Task.CompletedTask,
            (peer, offset, bytes) =>
            {
                delivered.Add((peer, bytes));
                newDelivered.TrySetResult();
                return Task.FromResult(true);
            },
            _ => Task.CompletedTask);

        try
        {
            var oldSession = new object();
            var newSession = new object();
            pipeline.SetActiveCharacteristic(characteristic);
            var oldSlot = pipeline.BindPeer(characteristic, "same-device-id", oldSession, oldPeer);
            Assert.NotNull(oldSlot);

            // First write stalls inside GetRequestAsync in ingest, keeping the 2nd write queued behind it.
            var firstEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var staleCompleted = 0;
            pipeline.EnqueueWrite(characteristic, "same-device-id", oldSession, 64, false,
                async ct => { firstEntered.TrySetResult(); await gateRequest.Task.WaitAsync(ct); return new(0, [1, 2], false, () => { }, _ => { }); },
                () => { if (Interlocked.Increment(ref staleCompleted) == 2) allStaleCompleted.TrySetResult(); }, () => { });
            await firstEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

            pipeline.EnqueueWrite(characteristic, "same-device-id", oldSession, 64, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, [3, 4], false, () => { }, _ => { })),
                () => { if (Interlocked.Increment(ref staleCompleted) == 2) allStaleCompleted.TrySetResult(); }, () => { });

            // Disconnect old session and re-subscribe with the SAME device ID before ingest drains.
            pipeline.InvalidateSlot(oldSlot);
            var newSlot = pipeline.BindPeer(characteristic, "same-device-id", newSession, newPeer);
            Assert.NotNull(newSlot);
            Assert.NotEqual(oldSlot.Generation, newSlot.Generation);

            gateRequest.SetResult();

            // Send a valid write on the new subscription generation.
            pipeline.EnqueueWrite(characteristic, "same-device-id", newSession, 64, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, [5, 6], false, () => { }, _ => { })),
                () => { }, () => { });

            await Task.WhenAll(allStaleCompleted.Task, newDelivered.Task).WaitAsync(TimeSpan.FromSeconds(5));
            await pipeline.QueueWork(() => Task.CompletedTask);

            var single = Assert.Single(delivered);
            Assert.Same(newPeer, single.peer);
            Assert.Equal(new byte[] { 5, 6 }, single.bytes);
            Assert.Equal(2, staleCompleted);
            Assert.Equal(0, admission.TotalBytes);
        }
        finally
        {
            gateRequest.TrySetResult();
            await pipeline.ShutdownAsync(() => Task.CompletedTask);
        }
    }

    [Fact]
    public async Task DeferralExceptionIsContainedAndTriedOnceWithLeaseReturnedAndShutdownCompletes()
    {
        var admission = new WriteAdmission();
        var logs = new System.Collections.Concurrent.ConcurrentQueue<string>();
        var delivered = new List<byte[]>();
        var characteristic = new object();
        var peerObj = new object();
        var disconnected = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var failCompleteCalled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var failDeferralErrorLogged = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var peer2Delivered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var okCompleteCalled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var okDeferralErrorLogged = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var pipeline = new BleWritePipeline(
            admission,
            msg =>
            {
                logs.Enqueue(msg);
                if (msg == "write deferral error=ObjectDisposedException")
                    failDeferralErrorLogged.TrySetResult();
                else if (msg == "write deferral error=InvalidOperationException")
                    okDeferralErrorLogged.TrySetResult();
            },
            () => Task.CompletedTask,
            (peer, offset, bytes) => { delivered.Add(bytes); peer2Delivered.TrySetResult(); return Task.FromResult(true); },
            _ => { disconnected.TrySetResult(); return Task.CompletedTask; });

        var session1 = new object();
        var session2 = new object();
        pipeline.SetActiveCharacteristic(characteristic);
        var slot1 = pipeline.BindPeer(characteristic, "peer-err", session1, peerObj);
        Assert.NotNull(slot1);

        // 1. GetRequestAsync throws AND Deferral.Complete throws -> tried once, lease returned, ingest stays alive.
        var failCompleteAttempts = 0;
        pipeline.EnqueueWrite(characteristic, "peer-err", session1, 128, false,
            _ => Task.FromException<BleWriteRequestData?>(new IOException("request failed")),
            () =>
            {
                Interlocked.Increment(ref failCompleteAttempts);
                failCompleteCalled.TrySetResult();
                throw new ObjectDisposedException("deferral");
            },
            () => { });

        await Task.WhenAll(disconnected.Task, failCompleteCalled.Task, failDeferralErrorLogged.Task).WaitAsync(TimeSpan.FromSeconds(5));
        using var leaseTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (admission.TotalBytes > 0 && !leaseTimeout.IsCancellationRequested)
            await Task.Yield();
        Assert.Equal(1, failCompleteAttempts);
        Assert.True(slot1.Rejected);
        Assert.Equal(0, admission.TotalBytes);

        // 2. Subsequent healthy peer's write where Deferral.Complete throws after payload copy still delivers and cleans up.
        var peer2Obj = new object();
        pipeline.BindPeer(characteristic, "peer-ok", session2, peer2Obj);
        var okCompleteAttempts = 0;
        pipeline.EnqueueWrite(characteristic, "peer-ok", session2, 128, false,
            _ => Task.FromResult<BleWriteRequestData?>(new(0, [9, 8, 7], false, () => { }, _ => { })),
            () =>
            {
                Interlocked.Increment(ref okCompleteAttempts);
                okCompleteCalled.TrySetResult();
                throw new InvalidOperationException("complete failed");
            },
            () => { });

        await Task.WhenAll(peer2Delivered.Task, okCompleteCalled.Task, okDeferralErrorLogged.Task).WaitAsync(TimeSpan.FromSeconds(5));
        await pipeline.QueueWork(() => Task.CompletedTask);

        Assert.Equal(1, okCompleteAttempts);
        Assert.Equal(new byte[] { 9, 8, 7 }, Assert.Single(delivered));
        Assert.Equal(0, admission.TotalBytes);

        var stopRan = 0;
        await pipeline.ShutdownAsync(() => { Interlocked.Increment(ref stopRan); return Task.CompletedTask; });
        Assert.Equal(1, stopRan);
    }

    [Fact]
    public async Task ShutdownProceedsToStopProviderEvenWhenWorkersFail()
    {
        var admission = new WriteAdmission();
        var logs = new System.Collections.Concurrent.ConcurrentQueue<string>();
        var pipeline = new BleWritePipeline(
            admission,
            logs.Enqueue,
            () => Task.CompletedTask,
            (_, _, _) => Task.FromResult(true),
            _ => Task.CompletedTask,
            onWorkerStart: () => Task.FromException(new InvalidOperationException("worker boom")),
            onIngestStart: () => Task.FromException(new InvalidOperationException("ingest boom")));

        var stopCount = 0;
        await pipeline.ShutdownAsync(() => { Interlocked.Increment(ref stopCount); return Task.CompletedTask; });
        Assert.Equal(1, stopCount);
    }

    private sealed class FakeDisposableRequest(bool throwsOnStatus = false, bool isSuccess = false, string statusLabel = "Busy") : IDisposable
    {
        public int DisposeCount;
        public bool IsSuccess => throwsOnStatus ? throw new InvalidOperationException("status boom") : isSuccess;
        public string StatusLabel => throwsOnStatus ? throw new InvalidOperationException("label boom") : statusLabel;
        public void Dispose() => Interlocked.Increment(ref DisposeCount);
    }

    [Fact]
    public async Task ProvisionalSlotBindsOnlyToSameSessionAndReleasesStaleLeases()
    {
        var admission = new WriteAdmission();
        var logs = new System.Collections.Concurrent.ConcurrentQueue<string>();
        var delivered = new List<(object peer, byte[] bytes)>();
        var inbound = new object();
        var outbound = new object();
        var oldSession = new object();
        var newSession = new object();
        var sameSessionPeer = new object();
        var newPeer = new object();
        var oldDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var firstDelivered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var secondDelivered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var pipeline = new BleWritePipeline(
            admission,
            logs.Enqueue,
            () => Task.CompletedTask,
            (peer, _, bytes) =>
            {
                delivered.Add((peer, bytes));
                if (ReferenceEquals(peer, newPeer))
                    firstDelivered.TrySetResult();
                else if (ReferenceEquals(peer, sameSessionPeer))
                    secondDelivered.TrySetResult();
                return Task.FromResult(true);
            },
            _ => Task.CompletedTask);

        try
        {
            pipeline.SetActiveCharacteristic(inbound, outbound);

            // 1. Old session writes before subscription binds (creates provisional slot with Peer == null).
            var oldCompleted = 0;
            var oldRejected = 0;
            pipeline.EnqueueWrite(inbound, "same-pad", oldSession, 64, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, [1, 2], false, () => { }, _ => { })),
                () => { Interlocked.Increment(ref oldCompleted); oldDone.TrySetResult(); },
                () => Interlocked.Increment(ref oldRejected));

            // New session subscribes for the same device ID -> must NOT inherit old provisional slot.
            var newSlot = pipeline.BindPeer(inbound, "same-pad", newSession, newPeer);
            Assert.NotNull(newSlot);
            Assert.Same(newSession, newSlot.Session);

            // Valid write from new session succeeds; old session write is discarded with lease & completion returned.
            pipeline.EnqueueWrite(inbound, "same-pad", newSession, 64, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, [3, 4], false, () => { }, _ => { })),
                () => { }, () => { });

            await Task.WhenAll(oldDone.Task, firstDelivered.Task).WaitAsync(TimeSpan.FromSeconds(5));
            await pipeline.QueueWork(() => Task.CompletedTask);

            var item = Assert.Single(delivered);
            Assert.Same(newPeer, item.peer);
            Assert.Equal(new byte[] { 3, 4 }, item.bytes);
            Assert.Equal(1, oldCompleted);
            Assert.Equal(0, admission.TotalBytes);

            // 2. Positive case: early write before BindPeer on the SAME session IS inherited by that session's peer.
            delivered.Clear();
            var sameEarlySession = new object();
            pipeline.EnqueueWrite(inbound, "other-pad", sameEarlySession, 64, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, [7, 8], false, () => { }, _ => { })),
                () => { }, () => { });
            var bound = pipeline.BindPeer(inbound, "other-pad", sameEarlySession, sameSessionPeer);
            Assert.NotNull(bound);
            Assert.Same(sameSessionPeer, bound.Peer);

            await secondDelivered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await pipeline.QueueWork(() => Task.CompletedTask);

            var sameItem = Assert.Single(delivered);
            Assert.Same(sameSessionPeer, sameItem.peer);
            Assert.Equal(new byte[] { 7, 8 }, sameItem.bytes);
            Assert.Equal(0, admission.TotalBytes);
        }
        finally
        {
            await pipeline.ShutdownAsync(() => Task.CompletedTask);
        }
    }

    [Fact]
    public async Task UnsubscribeAndResubscribeSnapshotCapturesIntermediateRemovalEvenWithSameDeviceId()
    {
        var admission = new WriteAdmission();
        var logs = new System.Collections.Concurrent.ConcurrentQueue<string>();
        var delivered = new List<(object peer, byte[] bytes)>();
        var snapshotEvents = new List<string>();
        var inbound = new object();
        var outbound = new object();
        var session = new object();
        var peer1 = new object();
        var peer2 = new object();
        object? activePeer = null;
        BleWritePipeline? pipeline = null;

        var blockWork = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var workBlocked = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var staleDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var addSnapshotDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var validDelivered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        pipeline = new BleWritePipeline(
            admission,
            logs.Enqueue,
            () => Task.CompletedTask,
            (peer, _, bytes) => { delivered.Add((peer, bytes)); validDelivered.TrySetResult(); return Task.FromResult(true); },
            _ => Task.CompletedTask,
            applySubscriptionsAsync: (clients, gen) =>
            {
                if (clients.Length == 0)
                {
                    snapshotEvents.Add($"remove:{gen}");
                    if (activePeer is not null) activePeer = null;
                }
                else
                {
                    snapshotEvents.Add($"add:{gen}");
                    var c = clients[0];
                    activePeer = peer2;
                    pipeline!.BindPeer(inbound, c.PeerId, c.Session, peer2, c.SubscriptionGeneration);
                    addSnapshotDone.TrySetResult();
                }
                return Task.CompletedTask;
            });

        try
        {
            pipeline.SetActiveCharacteristic(inbound, outbound);
            activePeer = peer1;
            var slot1 = pipeline.BindPeer(inbound, "same-pad", session, peer1);
            Assert.NotNull(slot1);

            // Pause the work channel so both unsubscribe ([]) and resubscribe ([same-pad]) occur before work drains.
            var blockerTask = pipeline.QueueWork(async () =>
            {
                workBlocked.SetResult();
                await blockWork.Task;
            });
            await workBlocked.Task.WaitAsync(TimeSpan.FromSeconds(5));

            // Stale write captured under old subscription before unsubscribe.
            var staleCompleted = 0;
            pipeline.EnqueueWrite(inbound, "same-pad", session, 64, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, [9, 9], false, () => { }, _ => { })),
                () => { Interlocked.Increment(ref staleCompleted); staleDone.TrySetResult(); }, () => { });

            // Event 1: unsubscribe (empty client list). Event 2: resubscribe (same device ID & even same session!).
            pipeline.CaptureSubscriptionsChanged(outbound, () => []);
            pipeline.CaptureSubscriptionsChanged(outbound, () => [new("same-pad", session, new object())]);

            // Old slot was synchronously invalidated at unsubscribe event entry.
            Assert.True(slot1.Invalidated);

            blockWork.SetResult();
            await blockerTask.WaitAsync(TimeSpan.FromSeconds(5));

            // Wait for queued snapshots + new write to settle.
            pipeline.EnqueueWrite(inbound, "same-pad", session, 64, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, [1, 1], false, () => { }, _ => { })),
                () => { }, () => { });

            await Task.WhenAll(staleDone.Task, addSnapshotDone.Task, validDelivered.Task).WaitAsync(TimeSpan.FromSeconds(5));
            await pipeline.QueueWork(() => Task.CompletedTask);

            Assert.Equal(2, snapshotEvents.Count);
            Assert.StartsWith("remove:", snapshotEvents[0]);
            Assert.StartsWith("add:", snapshotEvents[1]);
            Assert.Same(peer2, activePeer);
            var single = Assert.Single(delivered);
            Assert.Same(peer2, single.peer);
            Assert.Equal(new byte[] { 1, 1 }, single.bytes);
            Assert.Equal(1, staleCompleted);
            Assert.Equal(0, admission.TotalBytes);
        }
        finally
        {
            blockWork.TrySetResult();
            await pipeline.ShutdownAsync(() => Task.CompletedTask);
        }
    }

    [Fact]
    public async Task ActualLengthExceedingEstimateRevalidatesBeforeCopyAndRetiresConnection()
    {
        var boundaryAdmission = new WriteAdmission(globalByteLimit: 200, peerByteLimit: 100);
        using (var lease = Assert.IsAssignableFrom<WriteAdmission.WriteLease>(boundaryAdmission.TryEnter("p", 80)))
        {
            Assert.False(lease.TryAdjust(101));
            Assert.Equal(80, boundaryAdmission.PeerBytes("p"));
            Assert.True(lease.TryAdjust(100));
            Assert.Equal(100, boundaryAdmission.PeerBytes("p"));
        }
        Assert.Equal(0, boundaryAdmission.TotalBytes);

        var admission = new WriteAdmission(globalByteLimit: 200, peerByteLimit: 100);
        var logs = new System.Collections.Concurrent.ConcurrentQueue<string>();
        var characteristic = new object();
        var session = new object();
        var peerObj = new object();
        var copyCalls = 0;
        var deliveredCalls = 0;
        var respondErrors = new List<byte>();
        var completionCount = 0;
        var disconnected = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var pipeline = new BleWritePipeline(
            admission,
            logs.Enqueue,
            () => Task.CompletedTask,
            (_, _, _) => { Interlocked.Increment(ref deliveredCalls); return Task.FromResult(true); },
            _ => { disconnected.TrySetResult(); return Task.CompletedTask; });

        try
        {
            pipeline.SetActiveCharacteristic(characteristic);
            var slot = pipeline.BindPeer(characteristic, "tight-peer", session, peerObj);
            Assert.NotNull(slot);

            // Estimated 20 bytes fits under 100-byte peer limit, but actual payload length is 150 bytes.
            pipeline.EnqueueWrite(
                characteristic,
                "tight-peer",
                session,
                estimatedBytes: 20,
                sessionClosed: false,
                _ => Task.FromResult<BleWriteRequestData?>(new(
                    0,
                    PayloadLength: 150,
                    CopyBytes: () => { Interlocked.Increment(ref copyCalls); return new byte[150]; },
                    IsWithResponse: true,
                    RespondSuccess: () => { },
                    RespondError: err => respondErrors.Add(err))),
                () => Interlocked.Increment(ref completionCount),
                () => { });

            await disconnected.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var deadline = DateTime.UtcNow.AddSeconds(5);
            while ((Volatile.Read(ref completionCount) == 0 || admission.TotalBytes > 0) && DateTime.UtcNow < deadline)
                await Task.Delay(10);

            Assert.Equal(0, copyCalls);
            Assert.Equal(0, deliveredCalls);
            Assert.Equal([0x11], respondErrors);
            Assert.Equal(1, completionCount);
            Assert.True(slot.Rejected);
            Assert.Equal(0, admission.TotalBytes);
        }
        finally
        {
            await pipeline.ShutdownAsync(() => Task.CompletedTask);
        }
    }

    [Fact]
    public void ConnectionTuningRequestDisposesRequestOnStatusExceptionOrRejectedOwnership()
    {
        var logs = new List<string>();

        // 1. Status throws -> request MUST still be disposed.
        var throwingReq = new FakeDisposableRequest(throwsOnStatus: true);
        Assert.Throws<InvalidOperationException>(() =>
            ConnectionTuningRequest.Acquire(
                () => throwingReq,
                r => r.IsSuccess,
                r => r.StatusLabel,
                _ => true,
                logs.Add,
                out _));
        Assert.Equal(1, throwingReq.DisposeCount);

        // 2. Non-success status -> request disposed and unavailable=true.
        var failedReq = new FakeDisposableRequest(isSuccess: false, statusLabel: "Rejected");
        var res2 = ConnectionTuningRequest.Acquire(
            () => failedReq,
            r => r.IsSuccess,
            r => r.StatusLabel,
            _ => true,
            logs.Add,
            out var unavailable2);
        Assert.Null(res2);
        Assert.True(unavailable2);
        Assert.Equal(1, failedReq.DisposeCount);

        // 3. Ownership rejected after Status==Success -> request disposed.
        var unownedReq = new FakeDisposableRequest(isSuccess: true);
        var res3 = ConnectionTuningRequest.Acquire(
            () => unownedReq,
            r => r.IsSuccess,
            r => r.StatusLabel,
            _ => false,
            logs.Add,
            out var unavailable3);
        Assert.Null(res3);
        Assert.False(unavailable3);
        Assert.Equal(1, unownedReq.DisposeCount);

        // 4. Ownership accepted -> request returned without disposing.
        var ownedReq = new FakeDisposableRequest(isSuccess: true);
        var res4 = ConnectionTuningRequest.Acquire(
            () => ownedReq,
            r => r.IsSuccess,
            r => r.StatusLabel,
            _ => true,
            logs.Add,
            out var unavailable4);
        Assert.Same(ownedReq, res4);
        Assert.False(unavailable4);
        Assert.Equal(0, ownedReq.DisposeCount);
        ownedReq.Dispose();
    }

    [Fact]
    public async Task AbnormalWorkerTerminationDrainsQueuedWritesReleasesLeasesAndCompletesDeferrals()
    {
        // Case A: ingestWorker fails abnormally while writes are queued in ingest.
        {
            var admission = new WriteAdmission();
            var logs = new System.Collections.Concurrent.ConcurrentQueue<string>();
            var characteristic = new object();
            var session = new object();
            var ingestStartGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var completions = new int[3];
            var syncRejects = new int[3];

            var pipeline = new BleWritePipeline(
                admission,
                logs.Enqueue,
                () => Task.CompletedTask,
                (_, _, _) => Task.FromResult(true),
                _ => Task.CompletedTask,
                onIngestStart: () => ingestStartGate.Task);

            pipeline.SetActiveCharacteristic(characteristic);
            pipeline.BindPeer(characteristic, "p1", session, new object());

            for (var i = 0; i < 2; i++)
            {
                var idx = i;
                pipeline.EnqueueWrite(characteristic, "p1", session, 128, false,
                    _ => Task.FromResult<BleWriteRequestData?>(new(0, [1, 2], idx == 1, () => { }, _ => { })),
                    () => Interlocked.Increment(ref completions[idx]),
                    () => Interlocked.Increment(ref syncRejects[idx]));
            }
            Assert.Equal(256, admission.TotalBytes);

            ingestStartGate.SetException(new InvalidOperationException("ingest crash"));
            var deadline = DateTime.UtcNow.AddSeconds(5);
            while ((admission.TotalBytes > 0 || Volatile.Read(ref completions[0]) == 0 || Volatile.Read(ref completions[1]) == 0) && DateTime.UtcNow < deadline)
                await Task.Delay(10);

            Assert.Equal(0, admission.TotalBytes);
            Assert.Equal(1, completions[0]);
            Assert.Equal(1, completions[1]);
            Assert.Equal(1, syncRejects[0]);
            Assert.Equal(1, syncRejects[1]);

            // Enqueueing after abnormal ingest exit also cleans up immediately.
            pipeline.EnqueueWrite(characteristic, "p1", session, 128, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, [3], false, () => { }, _ => { })),
                () => Interlocked.Increment(ref completions[2]),
                () => Interlocked.Increment(ref syncRejects[2]));
            Assert.Equal(0, admission.TotalBytes);
            Assert.Equal(1, completions[2]);
            Assert.Equal(1, syncRejects[2]);

            await pipeline.ShutdownAsync(() => Task.CompletedTask);
        }

        // Case B: work worker fails abnormally while copied writes (with & without response) are queued in work.
        {
            var admission = new WriteAdmission();
            var logs = new System.Collections.Concurrent.ConcurrentQueue<string>();
            var characteristic = new object();
            var session = new object();
            var workerStartGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var completions = new int[2];
            var errors = new List<byte>();

            var pipeline = new BleWritePipeline(
                admission,
                logs.Enqueue,
                () => Task.CompletedTask,
                (_, _, _) => Task.FromResult(true),
                _ => Task.CompletedTask,
                onWorkerStart: () => workerStartGate.Task);

            pipeline.SetActiveCharacteristic(characteristic);
            pipeline.BindPeer(characteristic, "p2", session, new object());

            var payload = new byte[100];
            pipeline.EnqueueWrite(characteristic, "p2", session, 64, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, payload, false, () => { }, _ => { })),
                () => Interlocked.Increment(ref completions[0]),
                () => { });
            pipeline.EnqueueWrite(characteristic, "p2", session, 64, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, payload, true, () => { }, err => errors.Add(err))),
                () => Interlocked.Increment(ref completions[1]),
                () => { });

            // Wait until ingest hands off both items to work (admission adjusted to 200 bytes; WriteWithoutResponse deferral completed, WriteWithResponse deferral still held).
            var deadline = DateTime.UtcNow.AddSeconds(5);
            while ((admission.TotalBytes != 200 || Volatile.Read(ref completions[0]) == 0) && DateTime.UtcNow < deadline)
                await Task.Delay(10);
            Assert.Equal(200, admission.TotalBytes);
            Assert.Equal(1, completions[0]);
            Assert.Equal(0, completions[1]);

            workerStartGate.SetException(new InvalidOperationException("worker crash"));
            deadline = DateTime.UtcNow.AddSeconds(5);
            while ((admission.TotalBytes > 0 || Volatile.Read(ref completions[1]) == 0) && DateTime.UtcNow < deadline)
                await Task.Delay(10);

            Assert.Equal(0, admission.TotalBytes);
            Assert.Equal(1, completions[0]);
            Assert.Equal(1, completions[1]);
            Assert.Equal([0x0E], errors);

            var stopped = 0;
            await pipeline.ShutdownAsync(() => { Interlocked.Increment(ref stopped); return Task.CompletedTask; });
            Assert.Equal(1, stopped);
        }
    }

    [Fact]
    public async Task ShutdownStopsAdvertisingBeforePeerDisposalAndCompletesWhenWinRtHangs()
    {
        // 1. StopEndpointBeforePeersAsync always runs stopEndpoint BEFORE awaiting peer disposal,
        //    and returns cleanly even if peer disposal hangs forever.
        var order = new List<string>();
        var hungPeerDispose = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await BleEndpointCleanup.StopEndpointBeforePeersAsync(
            () => order.Add("stop-advertising-and-unsubscribe"),
            [
                () =>
                {
                    order.Add("begin-peer-dispose");
                    return hungPeerDispose.Task;
                }
            ],
            TimeSpan.FromMilliseconds(50),
            _ => { });
        Assert.Equal(["stop-advertising-and-unsubscribe", "begin-peer-dispose"], order);

        // 2. BleWritePipeline.ShutdownAsync stops advertising immediately and reaches stopProviderAsync
        //    even when both ingest and work are blocked on non-returning WinRT operations.
        var admission = new WriteAdmission();
        var logs = new System.Collections.Concurrent.ConcurrentQueue<string>();
        var characteristic = new object();
        var session = new object();
        var neverReturnsWork = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var neverReturnsIngest = new TaskCompletionSource<BleWriteRequestData?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var workEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var ingestEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var pipeline = new BleWritePipeline(
            admission,
            logs.Enqueue,
            () => Task.CompletedTask,
            (_, _, _) => Task.FromResult(true),
            _ => Task.CompletedTask,
            shutdownTimeout: TimeSpan.FromMilliseconds(60));

        pipeline.SetActiveCharacteristic(characteristic);
        pipeline.BindPeer(characteristic, "hung-peer", session, new object());
        _ = pipeline.QueueWork(async () =>
        {
            workEntered.SetResult();
            await neverReturnsWork.Task;
        });
        await workEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        pipeline.EnqueueWrite(characteristic, "hung-peer", session, 64, false,
            _ => { ingestEntered.TrySetResult(); return neverReturnsIngest.Task; },
            () => { }, () => { });
        await ingestEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        var shutdownOrder = new List<string>();
        await pipeline.ShutdownAsync(
            () => { shutdownOrder.Add("stop-provider"); return Task.CompletedTask; },
            () => shutdownOrder.Add("stop-advertising-immediate")).WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(["stop-advertising-immediate", "stop-provider"], shutdownOrder);
    }

    private sealed class TestSubscriptionPeer(string id, object session, BleSubscriptionSlot slot)
    {
        public string Id { get; } = id;
        public object Session { get; } = session;
        public BleSubscriptionSlot Slot { get; } = slot;
        public bool Rejected { get; private set; }
        public bool Disposed { get; private set; }
        public void Reject() => Rejected = true;
        public void Dispose() => Disposed = true;
    }

    private sealed class FakeCoordinatorPeer(string id, BleSubscriptionSlot slot, List<byte[]> sentPackets) : ISyncPeer
    {
        private volatile bool rejected;
        public string Id { get; } = id;
        public BleSubscriptionSlot Slot { get; } = slot;
        public int PacketLimit => 20;
        public bool Rejected => rejected || Slot.Rejected || Slot.Invalidated;
        public bool IsRejected => Rejected;
        public Task SendPacketAsync(byte[] packet)
        {
            if (Rejected) throw new InvalidOperationException("Retired");
            sentPackets.Add(packet.ToArray());
            return Task.CompletedTask;
        }
        public void Reject()
        {
            rejected = true;
            Slot.Rejected = true;
        }
    }

    [Fact]
    public async Task SubscribeUnsubscribeResubscribeSameSessionWhileWorkerPausedPreservesHelloInProvisionalSlot()
    {
        var admission = new WriteAdmission();
        var logs = new System.Collections.Concurrent.ConcurrentQueue<string>();
        var delivered = new List<(object peer, byte[] bytes)>();
        var registry = new BlePeerRegistry<TestSubscriptionPeer>();
        var inbound = new object();
        var outbound = new object();
        var sessionA = new object();
        var sessionB = new object();
        var bindHistory = new List<string>();
        BleWritePipeline? pipeline = null;

        var blockWork = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var workBlocked = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var helloDelivered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        pipeline = new BleWritePipeline(
            admission,
            logs.Enqueue,
            () => Task.CompletedTask,
            (peer, _, bytes) => { delivered.Add((peer, bytes)); helloDelivered.TrySetResult(); return Task.FromResult(true); },
            _ => Task.CompletedTask,
            applySubscriptionsAsync: (clients, snapshotGen) =>
            {
                foreach (var old in registry.Snapshot())
                {
                    if (pipeline!.ShouldKeepPeerForSnapshot(old.Id, old.Slot, snapshotGen))
                        continue;
                    var stillSubscribed = clients.Any(c =>
                        c.PeerId == old.Id
                        && Equals(c.Session, old.Session)
                        && c.SubscriptionGeneration == old.Slot.SubscriptionGeneration);
                    if (!stillSubscribed)
                    {
                        registry.Remove(old.Id, old);
                        pipeline.InvalidateSlot(old.Slot);
                    }
                }
                foreach (var c in clients)
                {
                    if (!pipeline!.IsCurrentSubscription(c.PeerId, c.Session, c.SubscriptionGeneration))
                    {
                        bindHistory.Add($"skip:{c.PeerId}:{c.SubscriptionGeneration}");
                        continue;
                    }
                    var tempPeer = new object();
                    var boundSlot = pipeline.BindPeer(inbound, c.PeerId, c.Session, tempPeer, c.SubscriptionGeneration);
                    if (boundSlot is null)
                    {
                        bindHistory.Add($"null:{c.PeerId}:{c.SubscriptionGeneration}");
                        continue;
                    }
                    var wrapped = new TestSubscriptionPeer(c.PeerId, c.Session, boundSlot);
                    boundSlot.Peer = wrapped;
                    registry.TryAdd(c.PeerId, wrapped);
                    bindHistory.Add($"bound:{c.PeerId}:{c.SubscriptionGeneration}");
                }
                return Task.CompletedTask;
            });

        try
        {
            pipeline.SetActiveCharacteristic(inbound, outbound);

            // Pause work so subscribe -> unsubscribe -> resubscribe (same session!) all happen before drain.
            var blockerTask = pipeline.QueueWork(async () =>
            {
                workBlocked.SetResult();
                await blockWork.Task;
            });
            await workBlocked.Task.WaitAsync(TimeSpan.FromSeconds(5));

            // 1. pad-b subscribes (ensuring pad-a's per-peer generation stays independent of pad-b).
            pipeline.CaptureSubscriptionsChanged(outbound, () => [new("pad-b", sessionB, new object())]);
            // 2. pad-a subscribes (gen 1), unsubscribes, then resubscribes on the SAME session (gen 2).
            pipeline.CaptureSubscriptionsChanged(outbound, () => [new("pad-b", sessionB, new object()), new("pad-a", sessionA, new object())]);
            pipeline.CaptureSubscriptionsChanged(outbound, () => [new("pad-b", sessionB, new object())]);
            pipeline.CaptureSubscriptionsChanged(outbound, () => [new("pad-b", sessionB, new object()), new("pad-a", sessionA, new object())]);

            // 3. New HELLO for pad-a arrives into a provisional slot BEFORE work unblocks.
            var hello = new SyncPadHandshake(SyncPairing.Create("pc"), Guid.NewGuid()).CreateHello();
            var helloPacket = Assert.Single(SyncPacketizer.Split(hello, 512));
            var helloCompleted = 0;
            var helloRejected = 0;
            pipeline.EnqueueWrite(
                inbound,
                "pad-a",
                sessionA,
                helloPacket.Length,
                sessionClosed: false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, helloPacket, false, () => { }, _ => { })),
                () => Interlocked.Increment(ref helloCompleted),
                () => Interlocked.Increment(ref helloRejected));

            Assert.Equal(0, helloRejected);

            blockWork.SetResult();
            await blockerTask.WaitAsync(TimeSpan.FromSeconds(5));

            await helloDelivered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await pipeline.QueueWork(() => Task.CompletedTask);

            var activePadA = registry.GetValueOrDefault("pad-a");
            Assert.NotNull(activePadA);
            Assert.Equal(2, activePadA.Slot.SubscriptionGeneration);
            Assert.False(activePadA.Slot.Invalidated);
            Assert.Contains("skip:pad-a:1", bindHistory);
            Assert.Contains("bound:pad-a:2", bindHistory);

            var deliveredHello = Assert.Single(delivered);
            Assert.Same(activePadA, deliveredHello.peer);
            Assert.Equal(helloPacket, deliveredHello.bytes);
            Assert.Equal(1, helloCompleted);
            Assert.Equal(0, admission.TotalBytes);
        }
        finally
        {
            blockWork.TrySetResult();
            await pipeline.ShutdownAsync(() => Task.CompletedTask);
        }
    }

    [Fact]
    public async Task RehandshakeHelloOnSameSessionReplacesOldSlotAndInvalidatesEarlierGenerations()
    {
        var admission = new WriteAdmission();
        var logs = new System.Collections.Concurrent.ConcurrentQueue<string>();
        var pairing = SyncPairing.Create("pc");
        var padId = Guid.NewGuid();
        var root = Path.Combine(Path.GetTempPath(), "clipboardplus-tests", Guid.NewGuid().ToString("N"));
        var store = new SyncRepository(root, pairing.PcId);
        var clipboardWrites = new List<string>();
        var coordinator = new SyncCoordinator(pairing, new InlineClipboard(clipboardWrites), logs.Enqueue, store);
        var registry = new BlePeerRegistry<FakeCoordinatorPeer>();
        var inbound = new object();
        var outbound = new object();
        var session = new object();
        var sentPacketsByPeer = new List<byte[]>();
        BleWritePipeline? pipeline = null;

        pipeline = new BleWritePipeline(
            admission,
            logs.Enqueue,
            () => Task.CompletedTask,
            (peerObj, offset, bytes) => offset == 0 && bytes.Length <= 512
                ? coordinator.ReceiveAsync((ISyncPeer)peerObj, bytes)
                : Task.FromResult(false),
            async peerObj =>
            {
                var p = (FakeCoordinatorPeer)peerObj;
                p.Reject();
                await coordinator.DisconnectAsync(p);
            },
            peerObj => ((FakeCoordinatorPeer)peerObj).Reject(),
            applySubscriptionsAsync: async (clients, snapshotGen) =>
            {
                foreach (var old in registry.Snapshot())
                {
                    if (pipeline!.ShouldKeepPeerForSnapshot(old.Id, old.Slot, snapshotGen))
                        continue;
                    if (!clients.Any(c => c.PeerId == old.Id && Equals(c.Session, session) && c.SubscriptionGeneration == old.Slot.SubscriptionGeneration))
                    {
                        registry.Remove(old.Id, old);
                        pipeline.InvalidateSlot(old.Slot);
                        old.Reject();
                        await coordinator.DisconnectAsync(old);
                    }
                }
                foreach (var c in clients)
                {
                    if (!pipeline!.IsCurrentSubscription(c.PeerId, c.Session, c.SubscriptionGeneration)) continue;
                    var existing = registry.GetValueOrDefault(c.PeerId);
                    if (existing is not null && Equals(c.Session, session) && existing.Slot.SubscriptionGeneration == c.SubscriptionGeneration && !existing.Slot.Invalidated)
                        continue;
                    var tempPeer = new object();
                    var slot = pipeline.BindPeer(inbound, c.PeerId, c.Session, tempPeer, c.SubscriptionGeneration);
                    if (slot is null) continue;
                    var coordPeer = new FakeCoordinatorPeer(c.PeerId, slot, sentPacketsByPeer);
                    slot.Peer = coordPeer;
                    registry.TryAdd(c.PeerId, coordPeer);
                    await coordinator.ConnectAsync(coordPeer);
                }
            },
            rehandshakePeerAsync: async (oldPeerObj, newSlot) =>
            {
                var oldPeer = (FakeCoordinatorPeer)oldPeerObj;
                registry.Remove(newSlot.PeerId, oldPeer);
                oldPeer.Reject();
                await coordinator.DisconnectAsync(oldPeer);
                var newPeer = new FakeCoordinatorPeer(newSlot.PeerId, newSlot, sentPacketsByPeer);
                Assert.True(pipeline!.TryAttachPeerToSlot(newSlot, newPeer));
                registry.TryAdd(newSlot.PeerId, newPeer);
                await coordinator.ConnectAsync(newPeer);
                return newPeer;
            });

        try
        {
            pipeline.SetActiveCharacteristic(inbound, outbound);
            pipeline.CaptureSubscriptionsChanged(outbound, () => [new("pad-1", session, new object())]);
            await pipeline.DrainPendingSubscriptionsAsync();

            var firstPeer = registry.GetValueOrDefault("pad-1");
            Assert.NotNull(firstPeer);
            Assert.Equal(1, firstPeer.Slot.SubscriptionGeneration);

            // 1. Complete first handshake + AUTH on session.
            var hs1 = new SyncPadHandshake(pairing, padId);
            await SendFrameToPipelineAsync(pipeline, inbound, "pad-1", session, hs1.CreateHello(), 20);
            await coordinator.WaitForOutgoingAsync(firstPeer);
            var welcome1 = DrainSingleFrame(sentPacketsByPeer);
            var auth1 = hs1.AcceptWelcome(welcome1);
            await SendFrameToPipelineAsync(pipeline, inbound, "pad-1", session, auth1.Auth, 20);
            await coordinator.WaitForOutgoingAsync(firstPeer);
            Assert.Equal(1, (await coordinator.GetStatusAsync()).Connected);

            // 2. WinRT misses intermediate unsubscribe on same session and sees same client list again.
            pipeline.CaptureSubscriptionsChanged(outbound, () => [new("pad-1", session, new object())]);
            await pipeline.DrainPendingSubscriptionsAsync();

            // 3. Resubscribed client sends a fresh 3-packet HELLO on the SAME session -> re-handshake replaces old slot & peer.
            var hs2 = new SyncPadHandshake(pairing, padId);
            await SendFrameToPipelineAsync(pipeline, inbound, "pad-1", session, hs2.CreateHello(), 20);
            var secondPeer = registry.GetValueOrDefault("pad-1");
            Assert.NotNull(secondPeer);
            Assert.NotSame(firstPeer, secondPeer);
            Assert.True(firstPeer.Slot.Invalidated);
            Assert.Equal(2, secondPeer.Slot.SubscriptionGeneration);
            Assert.True(firstPeer.Rejected);
            await coordinator.WaitForOutgoingAsync(secondPeer);
            var welcome2 = DrainSingleFrame(sentPacketsByPeer);
            var auth2 = hs2.AcceptWelcome(welcome2);
            await SendFrameToPipelineAsync(pipeline, inbound, "pad-1", session, auth2.Auth, 20);
            await coordinator.WaitForOutgoingAsync(secondPeer);

            var sender2 = new SyncFrameSender(auth2.Keys.PadToPc);
            var item = new SyncItem(Guid.NewGuid(), 100, "pad", "rehandshake-ok");
            await SendFrameToPipelineAsync(pipeline, inbound, "pad-1", session, sender2.Seal(SyncMessageCodec.Encode(item)), 20);
            await coordinator.WaitForOutgoingAsync(secondPeer);
            Assert.Equal(["rehandshake-ok"], clipboardWrites);

            // 4. A previously Rejected subscription cannot recover by re-sending HELLO without unsubscribing.
            secondPeer.Reject();
            var rejectedSync = 0;
            var hs3 = new SyncPadHandshake(pairing, padId);
            var pkt3 = SyncPacketizer.Split(hs3.CreateHello(), 512)[0];
            pipeline.EnqueueWrite(inbound, "pad-1", session, pkt3.Length, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, pkt3, false, () => { }, _ => { })),
                () => { }, () => Interlocked.Increment(ref rejectedSync));
            Assert.Equal(1, rejectedSync);
        }
        finally
        {
            await pipeline.ShutdownAsync(() => Task.CompletedTask);
            await coordinator.DisposeAsync();
        }
    }

    private sealed class InlineClipboard(List<string> writes) : IClipboardAccess
    {
        private uint seq;
        public Task<uint> WriteTextAsync(string text) { writes.Add(text); return Task.FromResult(++seq); }
    }

    private static async Task SendFrameToPipelineAsync(BleWritePipeline pipeline, object characteristic, string peerId, object session, byte[] frame, int packetLimit)
    {
        var packets = SyncPacketizer.Split(frame, packetLimit);
        var done = 0;
        var allDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        foreach (var pkt in packets)
        {
            pipeline.EnqueueWrite(characteristic, peerId, session, pkt.Length, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, pkt, false, () => { }, _ => { })),
                () =>
                {
                    if (Interlocked.Increment(ref done) == packets.Count)
                        allDone.TrySetResult();
                },
                () => throw new InvalidOperationException("Unexpected sync rejection"));
        }
        await allDone.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(packets.Count, done);
        // Ensure queued work items on work channel have also drained.
        await pipeline.QueueWork(() => Task.CompletedTask);
    }

    private static byte[] DrainSingleFrame(List<byte[]> packets)
    {
        var assembler = new SyncPacketAssembler(512);
        byte[]? result = null;
        foreach (var pkt in packets)
            result = assembler.Append(pkt) ?? result;
        assembler.Finish();
        packets.Clear();
        return Assert.IsType<byte[]>(result);
    }

    [Fact]
    public async Task OverLimitRetiresSlotAndPeerBeforeLoggingAndMarksProvisionalSlotOnBind()
    {
        // 1. Bound peer: both slot and peer are marked rejected BEFORE log() runs.
        {
            var admission = new WriteAdmission(globalByteLimit: 100, peerByteLimit: 100);
            var characteristic = new object();
            var session = new object();
            var peer = new TestSubscriptionPeer("p1", session, null!);
            var peerRejectedAtLog = false;
            var slotRejectedAtLog = false;
            BleSubscriptionSlot? slot = null;
            var pipeline = new BleWritePipeline(
                admission,
                msg =>
                {
                    if (msg.Contains("write limit exceeded"))
                    {
                        slotRejectedAtLog = slot?.Rejected ?? false;
                        peerRejectedAtLog = peer.Rejected;
                    }
                },
                () => Task.CompletedTask,
                (_, _, _) => Task.FromResult(true),
                _ => Task.CompletedTask,
                peerObj => ((TestSubscriptionPeer)peerObj).Reject());

            try
            {
                pipeline.SetActiveCharacteristic(characteristic);
                slot = pipeline.BindPeer(characteristic, "p1", session, peer);
                Assert.NotNull(slot);

                var rejectedSync = 0;
                pipeline.EnqueueWrite(characteristic, "p1", session, 101, false,
                    _ => Task.FromResult<BleWriteRequestData?>(new(0, new byte[101], false, () => { }, _ => { })),
                    () => { }, () => Interlocked.Increment(ref rejectedSync));

                Assert.Equal(1, rejectedSync);
                Assert.True(slotRejectedAtLog);
                Assert.True(peerRejectedAtLog);
            }
            finally
            {
                await pipeline.ShutdownAsync(() => Task.CompletedTask);
            }
        }

        // 2. Provisional slot exceeding actual length marks slot rejected before logging, and BindPeer rejects peer immediately.
        {
            var admission = new WriteAdmission(globalByteLimit: 100, peerByteLimit: 100);
            var characteristic = new object();
            var session = new object();
            var disconnected = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var logCalled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var refreshEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var allowRefresh = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var peerRejectedSync = 0;
            var pipeline = new BleWritePipeline(
                admission,
                msg => { if (msg.Contains("write limit exceeded")) logCalled.TrySetResult(); },
                async () =>
                {
                    refreshEntered.TrySetResult();
                    await allowRefresh.Task;
                },
                (_, _, _) => Task.FromResult(true),
                _ => { disconnected.TrySetResult(); return Task.CompletedTask; },
                _ => Interlocked.Increment(ref peerRejectedSync));

            try
            {
                pipeline.SetActiveCharacteristic(characteristic);
                pipeline.EnqueueWrite(characteristic, "prov", session, 20, false,
                    _ => Task.FromResult<BleWriteRequestData?>(new(0, 150, () => new byte[150], false, () => { }, _ => { })),
                    () => { }, () => { });

                await logCalled.Task.WaitAsync(TimeSpan.FromSeconds(5));
                await refreshEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
                var slot = pipeline.BindPeer(characteristic, "prov", session, new object());
                Assert.NotNull(slot);
                Assert.True(slot.Rejected);
                Assert.True(Volatile.Read(ref peerRejectedSync) >= 1);
                allowRefresh.TrySetResult();
                await disconnected.Task.WaitAsync(TimeSpan.FromSeconds(5));
            }
            finally
            {
                allowRefresh.TrySetResult();
                await pipeline.ShutdownAsync(() => Task.CompletedTask);
            }
        }
    }

    private sealed class FakeEventSession
    {
        public int AttachedHandlers;
    }

    private sealed class FakeRegisteredPeer(FakeEventSession session, BleSubscriptionSlot slot)
    {
        public FakeEventSession Session { get; } = session;
        public BleSubscriptionSlot Slot { get; } = slot;
        public bool Rejected { get; private set; }
        public bool Disposed { get; private set; }
        public void AttachHandler() => Interlocked.Increment(ref Session.AttachedHandlers);
        public void DetachHandler() => Interlocked.Decrement(ref Session.AttachedHandlers);
        public void Reject() => Rejected = true;
        public void Dispose() => Disposed = true;
    }

    [Fact]
    public async Task BlockedEventRegistrationAfterShutdownDrainDisposesPeerWithoutLeaking()
    {
        var admission = new WriteAdmission();
        var logs = new System.Collections.Concurrent.ConcurrentQueue<string>();
        var registry = new BlePeerRegistry<FakeRegisteredPeer>();
        var inbound = new object();
        var outbound = new object();
        var session = new FakeEventSession();
        var enteredRegistration = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var allowRegistrationFinish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cleanupDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        FakeRegisteredPeer? createdPeer = null;
        BleWritePipeline? pipeline = null;

        pipeline = new BleWritePipeline(
            admission,
            logs.Enqueue,
            () => Task.CompletedTask,
            (_, _, _) => Task.FromResult(true),
            _ => Task.CompletedTask,
            applySubscriptionsAsync: async (clients, _) =>
            {
                foreach (var c in clients)
                {
                    if (registry.IsClosed) return;
                    var placeholder = new object();
                    var slot = pipeline!.BindPeer(inbound, c.PeerId, c.Session, placeholder, c.SubscriptionGeneration);
                    if (slot is null) continue;
                    var peer = new FakeRegisteredPeer((FakeEventSession)c.Session, slot);
                    createdPeer = peer;
                    peer.AttachHandler();
                    enteredRegistration.TrySetResult();
                    await allowRegistrationFinish.Task;
                    if (!registry.TryAdd(c.PeerId, peer))
                    {
                        pipeline.InvalidateSlot(slot);
                        peer.DetachHandler();
                        peer.Reject();
                        peer.Dispose();
                        cleanupDone.TrySetResult();
                        return;
                    }
                }
            },
            shutdownTimeout: TimeSpan.FromMilliseconds(50));

        try
        {
            pipeline.SetActiveCharacteristic(inbound, outbound);
            pipeline.CaptureSubscriptionsChanged(outbound, () => [new("late-peer", session, new object())]);
            await enteredRegistration.Task.WaitAsync(TimeSpan.FromSeconds(5));

            // Shutdown times out waiting for the blocked registration and drains/closes the registry.
            await pipeline.ShutdownAsync(() =>
            {
                registry.Drain(close: true);
                return Task.CompletedTask;
            });
            Assert.True(registry.IsClosed);
            Assert.Equal(0, registry.Count);

            // Unblock registration: TryAdd fails under the lock and disposes/unsubscribes immediately.
            allowRegistrationFinish.SetResult();
            await cleanupDone.Task.WaitAsync(TimeSpan.FromSeconds(5));

            Assert.Equal(0, registry.Count);
            Assert.Empty(registry.Snapshot());
            Assert.NotNull(createdPeer);
            Assert.True(createdPeer.Disposed);
            Assert.True(createdPeer.Rejected);
            Assert.True(createdPeer.Slot.Invalidated);
            Assert.Equal(0, session.AttachedHandlers);
        }
        finally
        {
            allowRegistrationFinish.TrySetResult();
        }
    }
}
