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
        leases[0].Adjust(256);
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
            pipeline.SetActiveCharacteristic(characteristic);
            var slot = pipeline.BindPeer(characteristic, "pad-1", peerObj);

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
            pipeline.SetActiveCharacteristic(characteristic);
            var slot = pipeline.BindPeer(characteristic, "secret-device-id", peerObj);
            var payload = new byte[512];

            // First 2 writes fill the 1024-byte peer limit while work is paused.
            for (var i = 0; i < 2; i++)
            {
                pipeline.EnqueueWrite(characteristic, "secret-device-id", 512, false,
                    _ => Task.FromResult<BleWriteRequestData?>(new(0, payload, false, () => { }, _ => { })),
                    () => { }, () => Interlocked.Increment(ref rejectedSyncCount));
            }
            await workEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

            // 3rd write exceeds 1024 bytes -> rejected synchronously, slot & peer retired immediately.
            pipeline.EnqueueWrite(characteristic, "secret-device-id", 512, false,
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
            pipeline.SetActiveCharacteristic(characteristic);
            var oldSlot = pipeline.BindPeer(characteristic, "same-device-id", oldPeer);

            // First write stalls inside GetRequestAsync in ingest, keeping the 2nd write queued behind it.
            var firstEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var staleCompleted = 0;
            pipeline.EnqueueWrite(characteristic, "same-device-id", 64, false,
                async ct => { firstEntered.TrySetResult(); await gateRequest.Task.WaitAsync(ct); return new(0, [1, 2], false, () => { }, _ => { }); },
                () => Interlocked.Increment(ref staleCompleted), () => { });
            await firstEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

            pipeline.EnqueueWrite(characteristic, "same-device-id", 64, false,
                _ => Task.FromResult<BleWriteRequestData?>(new(0, [3, 4], false, () => { }, _ => { })),
                () => Interlocked.Increment(ref staleCompleted), () => { });

            // Disconnect old session and re-subscribe with the SAME device ID before ingest drains.
            pipeline.InvalidateSlot(oldSlot);
            var newSlot = pipeline.BindPeer(characteristic, "same-device-id", newPeer);
            Assert.NotEqual(oldSlot.Generation, newSlot.Generation);

            gateRequest.SetResult();

            // Send a valid write on the new subscription generation.
            var newDelivered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            pipeline.EnqueueWrite(characteristic, "same-device-id", 64, false,
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

        pipeline.SetActiveCharacteristic(characteristic);
        var slot1 = pipeline.BindPeer(characteristic, "peer-err", peerObj);

        // 1. GetRequestAsync throws AND Deferral.Complete throws -> tried once, lease returned, ingest stays alive.
        var failCompleteAttempts = 0;
        pipeline.EnqueueWrite(characteristic, "peer-err", 128, false,
            _ => Task.FromException<BleWriteRequestData?>(new IOException("request failed")),
            () => { Interlocked.Increment(ref failCompleteAttempts); throw new ObjectDisposedException("deferral"); },
            () => { });

        await disconnected.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(1, failCompleteAttempts);
        Assert.True(slot1.Rejected);
        Assert.Equal(0, admission.TotalBytes);

        // 2. Subsequent healthy peer's write where Deferral.Complete throws after payload copy still delivers and cleans up.
        var peer2Obj = new object();
        pipeline.BindPeer(characteristic, "peer-ok", peer2Obj);
        var okCompleteAttempts = 0;
        pipeline.EnqueueWrite(characteristic, "peer-ok", 128, false,
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
}
