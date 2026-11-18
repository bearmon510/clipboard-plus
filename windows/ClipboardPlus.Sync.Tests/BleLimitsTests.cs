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
                return true;
            },
            _ => { Interlocked.Increment(ref disconnected); return Task.CompletedTask; },
            _ => Interlocked.Increment(ref retiredSync));

        try
        {
            var session = new object();
            pipeline.SetActiveCharacteristic(characteristic);
            var slot = pipeline.BindPeer(characteristic, "pad-1", session, peerObj);

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
            var deadline = DateTime.UtcNow.AddSeconds(10);
            while ((delivered.Count < packets.Count || admission.TotalBytes > 0) && DateTime.UtcNow < deadline)
                await Task.Delay(10);

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

        var pipeline = new BleWritePipeline(
            admission,
            logs.Enqueue,
            () => Task.CompletedTask,
            (peer, offset, bytes) =>
            {
                delivered.Add((peer, bytes));
                return Task.FromResult(true);
            },
            _ => Task.CompletedTask);

        try
        {
            var oldSession = new object();
            var newSession = new object();
            pipeline.SetActiveCharacteristic(characteristic);
            var oldSlot = pipeline.BindPeer(characteristic, "same-device-id", oldSession, oldPeer);

            // First write stalls inside GetRequestAsync in ingest, keeping the 2nd write queued behind it.
            var firstEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var staleCompleted = 0;
            pipeline.EnqueueWrite(characteristic, "same-device-id", oldSession, 64, false,
                async ct => { firstEntered.TrySetResult(); await gateRequest.Task.WaitAsync(ct); return new(0, [1, 2], false, () => { }, _ => { }); },
                () => Interlocked.Increment(ref staleCompleted), () => { });
            await firstEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

            pipeline.EnqueueWrite(characteristic, "same-device-id", oldSession, 64, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, [3, 4], false, () => { }, _ => { })),
                () => Interlocked.Increment(ref staleCompleted), () => { });

            // Disconnect old session and re-subscribe with the SAME device ID before ingest drains.
            pipeline.InvalidateSlot(oldSlot);
            var newSlot = pipeline.BindPeer(characteristic, "same-device-id", newSession, newPeer);
            Assert.NotEqual(oldSlot.Generation, newSlot.Generation);

            gateRequest.SetResult();

            // Send a valid write on the new subscription generation.
            var newDelivered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            pipeline.EnqueueWrite(characteristic, "same-device-id", newSession, 64, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, [5, 6], false, () => { }, _ => { })),
                () => { }, () => { });

            var deadline = DateTime.UtcNow.AddSeconds(5);
            while (delivered.Count == 0 && DateTime.UtcNow < deadline)
                await Task.Delay(10);

            // Wait briefly to ensure stale writes didn't execute afterward.
            await Task.Delay(50);

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

        var pipeline = new BleWritePipeline(
            admission,
            logs.Enqueue,
            () => Task.CompletedTask,
            (peer, offset, bytes) => { delivered.Add(bytes); return Task.FromResult(true); },
            _ => { disconnected.TrySetResult(); return Task.CompletedTask; });

        var session1 = new object();
        var session2 = new object();
        pipeline.SetActiveCharacteristic(characteristic);
        var slot1 = pipeline.BindPeer(characteristic, "peer-err", session1, peerObj);

        // 1. GetRequestAsync throws AND Deferral.Complete throws -> tried once, lease returned, ingest stays alive.
        var failCompleteAttempts = 0;
        pipeline.EnqueueWrite(characteristic, "peer-err", session1, 128, false,
            _ => Task.FromException<BleWriteRequestData?>(new IOException("request failed")),
            () => { Interlocked.Increment(ref failCompleteAttempts); throw new ObjectDisposedException("deferral"); },
            () => { });

        await disconnected.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(1, failCompleteAttempts);
        Assert.True(slot1.Rejected);
        Assert.Equal(0, admission.TotalBytes);

        // 2. Subsequent healthy peer's write where Deferral.Complete throws after payload copy still delivers and cleans up.
        var peer2Obj = new object();
        pipeline.BindPeer(characteristic, "peer-ok", session2, peer2Obj);
        var okCompleteAttempts = 0;
        pipeline.EnqueueWrite(characteristic, "peer-ok", session2, 128, false,
            _ => Task.FromResult<BleWriteRequestData?>(new(0, [9, 8, 7], false, () => { }, _ => { })),
            () => { Interlocked.Increment(ref okCompleteAttempts); throw new InvalidOperationException("complete failed"); },
            () => { });

        var deadline = DateTime.UtcNow.AddSeconds(5);
        while ((delivered.Count == 0 || admission.TotalBytes > 0) && DateTime.UtcNow < deadline)
            await Task.Delay(10);

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

        var pipeline = new BleWritePipeline(
            admission,
            logs.Enqueue,
            () => Task.CompletedTask,
            (peer, _, bytes) => { delivered.Add((peer, bytes)); return Task.FromResult(true); },
            _ => Task.CompletedTask);

        try
        {
            pipeline.SetActiveCharacteristic(inbound, outbound);

            // 1. Old session writes before subscription binds (creates provisional slot with Peer == null).
            var oldCompleted = 0;
            var oldRejected = 0;
            pipeline.EnqueueWrite(inbound, "same-pad", oldSession, 64, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, [1, 2], false, () => { }, _ => { })),
                () => Interlocked.Increment(ref oldCompleted),
                () => Interlocked.Increment(ref oldRejected));

            // New session subscribes for the same device ID -> must NOT inherit old provisional slot.
            var newSlot = pipeline.BindPeer(inbound, "same-pad", newSession, newPeer);
            Assert.Same(newSession, newSlot.Session);

            // Valid write from new session succeeds; old session write is discarded with lease & completion returned.
            pipeline.EnqueueWrite(inbound, "same-pad", newSession, 64, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, [3, 4], false, () => { }, _ => { })),
                () => { }, () => { });

            var deadline = DateTime.UtcNow.AddSeconds(5);
            while ((delivered.Count == 0 || admission.TotalBytes > 0 || Volatile.Read(ref oldCompleted) == 0) && DateTime.UtcNow < deadline)
                await Task.Delay(10);

            await Task.Delay(30);
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
            Assert.Same(sameSessionPeer, bound.Peer);

            deadline = DateTime.UtcNow.AddSeconds(5);
            while ((delivered.Count == 0 || admission.TotalBytes > 0) && DateTime.UtcNow < deadline)
                await Task.Delay(10);

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

        pipeline = new BleWritePipeline(
            admission,
            logs.Enqueue,
            () => Task.CompletedTask,
            (peer, _, bytes) => { delivered.Add((peer, bytes)); return Task.FromResult(true); },
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
                    pipeline!.BindPeer(inbound, c.PeerId, c.Session, peer2, gen);
                }
                return Task.CompletedTask;
            });

        try
        {
            pipeline.SetActiveCharacteristic(inbound, outbound);
            activePeer = peer1;
            var slot1 = pipeline.BindPeer(inbound, "same-pad", session, peer1);

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
                () => Interlocked.Increment(ref staleCompleted), () => { });

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

            var deadline = DateTime.UtcNow.AddSeconds(5);
            while ((delivered.Count == 0 || snapshotEvents.Count < 2 || admission.TotalBytes > 0) && DateTime.UtcNow < deadline)
                await Task.Delay(10);

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
}
