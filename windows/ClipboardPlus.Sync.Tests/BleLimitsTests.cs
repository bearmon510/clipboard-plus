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
        var admission = new WriteAdmission(globalLimit: 2, peerLimit: 1);
        var channel = System.Threading.Channels.Channel.CreateBounded<Func<Task>>(2);
        var completions = new int[6];
        var rejections = new List<int>();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Dispatch(int id, string peer, Func<Task> action) => admission.Dispatch(channel.Writer, peer,
            action, () => rejections.Add(id), () => completions[id]++);
        Dispatch(0, "a", async () => { started.SetResult(); await release.Task; });
        var active = (await channel.Reader.ReadAsync())();
        await started.Task;
        Dispatch(1, "a", () => throw new Exception("must not run")); // Executing counts too.
        Dispatch(2, "b", () => Task.FromException(new IOException()));
        Dispatch(3, "c", () => throw new Exception("must not run")); // Global limit.
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
        using var recovered = admission.TryEnter("a"); Assert.NotNull(recovered);
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
    public void FloodCannotExceedPerPeerOrGlobalLimitAndReleasedSlotsAreReusable()
    {
        var admission = new WriteAdmission();
        var leases = new List<IDisposable>();
        for (var peer = 0; peer < 4; peer++)
        {
            for (var i = 0; i < 16; i++) leases.Add(Assert.IsAssignableFrom<IDisposable>(admission.TryEnter(peer.ToString())));
            for (var i = 0; i < 10_000; i++) Assert.Null(admission.TryEnter(peer.ToString()));
        }
        for (var i = 0; i < 10_000; i++) Assert.Null(admission.TryEnter("new peer " + i));
        foreach (var lease in leases) { lease.Dispose(); lease.Dispose(); }
        using var recovered = admission.TryEnter("new peer"); Assert.NotNull(recovered);
    }

    [Fact]
    public async Task ConcurrentAdmissionIsBounded()
    {
        var admission = new WriteAdmission();
        var leases = new System.Collections.Concurrent.ConcurrentBag<IDisposable>();
        await Task.WhenAll(Enumerable.Range(0, 1000).Select(i => Task.Run(() =>
        {
            var lease = admission.TryEnter((i % 4).ToString());
            if (lease is not null) leases.Add(lease);
        })));
        Assert.Equal(64, leases.Count);
        foreach (var lease in leases) lease.Dispose();
    }

    [Fact]
    public void CustomAdmissionLimitsSupportPipelinedBurstAndRejectExcess()
    {
        var admission = new WriteAdmission(globalLimit: 512, peerLimit: 256);
        var peerA = new List<IDisposable>();
        for (var i = 0; i < 256; i++)
            peerA.Add(Assert.IsAssignableFrom<IDisposable>(admission.TryEnter("a")));
        Assert.Null(admission.TryEnter("a"));

        var peerB = new List<IDisposable>();
        for (var i = 0; i < 256; i++)
            peerB.Add(Assert.IsAssignableFrom<IDisposable>(admission.TryEnter("b")));
        Assert.Null(admission.TryEnter("c"));

        foreach (var lease in peerA) lease.Dispose();
        foreach (var lease in peerB) lease.Dispose();
        using var reused = admission.TryEnter("a");
        Assert.NotNull(reused);
    }
}
