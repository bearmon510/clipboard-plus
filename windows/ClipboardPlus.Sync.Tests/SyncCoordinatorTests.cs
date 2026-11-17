using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class SyncCoordinatorTests
{
    private sealed class FakePeer : ISyncPeer
    {
        public int PacketLimit { get; set; } = 20;
        public bool Rejected { get; private set; }
        public bool FailSend { get; set; }
        public Func<byte[], Task>? OnSend;
        public readonly List<byte[]> Packets = [];
        public Task SendPacketAsync(byte[] packet)
        {
            Assert.False(Rejected);
            Assert.InRange(packet.Length, 2, PacketLimit);
            if (FailSend) throw new IOException("fake transport error");
            Packets.Add(packet.ToArray());
            return OnSend?.Invoke(packet) ?? Task.CompletedTask;
        }
        public void Reject() => Rejected = true;
        public byte[][] DrainFrames()
        {
            var assembler = new SyncPacketAssembler(ushort.MaxValue);
            var frames = new List<byte[]>();
            foreach (var packet in Packets)
            {
                var frame = assembler.Append(packet);
                if (frame is not null) frames.Add(frame);
            }
            assembler.Finish(); Packets.Clear();
            return frames.ToArray();
        }
    }

    private sealed class FakeClipboard : IClipboardAccess
    {
        public uint Sequence = 100;
        public bool Fail;
        public readonly List<string> Writes = [];
        public Task<uint> WriteTextAsync(string text)
        {
            if (Fail) throw new IOException("busy clipboard");
            Writes.Add(text); return Task.FromResult(++Sequence);
        }
    }

    private sealed class Rig
    {
        public readonly SyncPairing Pairing = SyncPairing.Create("test-pc");
        public readonly FakeClipboard Clipboard = new();
        public readonly System.Collections.Concurrent.ConcurrentQueue<string> Logs = new();
        public readonly SyncCoordinator Pc;
        public SyncStatus State = new(0, 0, null, null);
        public Rig()
        {
            Pc = new(Pairing, Clipboard, Logs.Enqueue);
            Pc.Changed += s => State = s;
        }

        public async Task<Pad> ConnectAsync(int limit = 20)
        {
            var alreadyConnected = State.Connected;
            var peer = new FakePeer { PacketLimit = limit };
            var handshake = new SyncPadHandshake(Pairing, Guid.NewGuid());
            await Pc.ConnectAsync(peer);
            await SendFrameAsync(peer, handshake.CreateHello());
            Assert.Equal(alreadyConnected, State.Connected);
            var auth = handshake.AcceptWelcome(Assert.Single(peer.DrainFrames()));
            await SendFrameAsync(peer, auth.Auth);
            return new(this, peer, auth.Keys);
        }

        public async Task SendFrameAsync(FakePeer peer, byte[] frame)
        {
            foreach (var packet in SyncPacketizer.Split(frame, peer.PacketLimit))
                Assert.True(await Pc.ReceiveAsync(peer, packet));
            await Pc.WaitForOutgoingAsync(peer);
        }
    }

    private sealed class Pad(Rig rig, FakePeer peer, SyncSessionKeys keys)
    {
        public readonly FakePeer Peer = peer;
        private readonly SyncFrameSender sender = new(keys.PadToPc);
        private readonly SyncFrameReceiver receiver = new(keys.PcToPad);
        public Task SendAsync(SyncMessage message) => rig.SendFrameAsync(Peer, Seal(message));
        public byte[] Seal(SyncMessage message) => sender.Seal(SyncMessageCodec.Encode(message));
        public SyncMessage[] Drain() => Peer.DrainFrames().Select(f => SyncMessageCodec.Decode(receiver.Open(f))).ToArray();
    }

    [Fact]
    public async Task SlowReconnectSenderDoesNotBlockReceiveAckTimersOrDisconnectAndPrioritizesReplies()
    {
        var r = new Rig();
        await r.Pc.ClipboardChangedAsync(new(1, new string('a', 100_000), false));
        await r.Pc.ClipboardChangedAsync(new(2, new string('b', 100_000), false));
        var peer = new FakePeer { PacketLimit = 512 };
        await r.Pc.ConnectAsync(peer);
        var handshake = new SyncPadHandshake(r.Pairing, Guid.NewGuid());
        await r.SendFrameAsync(peer, handshake.CreateHello());
        var auth = handshake.AcceptWelcome(Assert.Single(peer.DrainFrames()));
        var pad = new Pad(r, peer, auth.Keys);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        peer.OnSend = packet =>
        {
            // Hold completion of the first whole item, as if NotifyValueAsync were slow.
            if ((packet[0] & 2) != 0 && !entered.Task.IsCompleted)
            { entered.SetResult(); return release.Task; }
            return Task.CompletedTask;
        };
        foreach (var packet in SyncPacketizer.Split(auth.Auth, 512))
            Assert.True(await r.Pc.ReceiveAsync(peer, packet).WaitAsync(TimeSpan.FromSeconds(2)));
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var first = Assert.IsType<SyncItem>(Assert.Single(pad.Drain()));
        var received = new SyncItem(Guid.NewGuid(), 0, "pad", "while PC is sending");
        async Task Receive(SyncMessage message)
        {
            foreach (var packet in SyncPacketizer.Split(pad.Seal(message), 512))
                Assert.True(await r.Pc.ReceiveAsync(peer, packet).WaitAsync(TimeSpan.FromSeconds(2)));
        }
        try
        {
            await Receive(received);
            await Receive(new SyncAck([first.Id]));
            await Receive(new SyncPing());
            Assert.Single(r.Clipboard.Writes); Assert.Equal(1, r.State.Pending);
            // Simulate more than the iPad's 60-second ACK deadline without sleeping.
            await r.Pc.TickAsync(DateTimeOffset.UtcNow.AddSeconds(61)).WaitAsync(TimeSpan.FromSeconds(2));
            var other = new FakePeer(); await r.Pc.ConnectAsync(other);
            await r.Pc.DisconnectAsync(other).WaitAsync(TimeSpan.FromSeconds(2));
            Assert.True(other.Rejected);
        }
        finally { release.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(peer);
        var messages = pad.Drain();
        Assert.Equal(received.Id, Assert.Single(Assert.IsType<SyncAck>(messages[0]).Ids));
        Assert.IsType<SyncPong>(messages[1]);
        Assert.Equal(new string('b', 100_000), Assert.IsType<SyncItem>(messages[2]).Text);
        Assert.Equal(3, messages.Length); // First ACK was not resurrected after send completion.
        await r.Pc.DisconnectAsync(peer);
    }

    [Fact]
    public async Task DisconnectCancelsBlockedSenderAndFreshConnectionCanResend()
    {
        var r = new Rig(); var pad = await r.ConnectAsync();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pad.Peer.OnSend = _ => { entered.TrySetResult(); return release.Task; };
        await r.Pc.ClipboardChangedAsync(new(1, new string('x', 1000), false));
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var idle = r.Pc.WaitForOutgoingAsync(pad.Peer);
        await r.Pc.DisconnectAsync(pad.Peer).WaitAsync(TimeSpan.FromSeconds(2));
        await idle.WaitAsync(TimeSpan.FromSeconds(2));
        release.SetResult();
        Assert.True(pad.Peer.Rejected); Assert.Equal(0, r.State.Connected);
        Assert.Equal(1, r.State.Pending);
        var fresh = await r.ConnectAsync(); Assert.Single(fresh.Drain());
    }

    [Fact]
    public async Task FailedFirstNotificationRetiresProtocolStateAndPongDoesNotLoop()
    {
        var r = new Rig(); var peer = new FakePeer { FailSend = true };
        await r.Pc.ConnectAsync(peer);
        await r.SendFrameAsync(peer, new SyncPadHandshake(r.Pairing, Guid.NewGuid()).CreateHello());
        Assert.True(peer.Rejected); Assert.Equal(0, r.State.Connected);
        Assert.False(await r.Pc.ReceiveAsync(peer, [3, 1]));
        // Retired peers do not consume the eight protocol connection slots.
        for (var i = 0; i < 9; i++)
        {
            var fresh = await r.ConnectAsync();
            await fresh.SendAsync(new SyncPing());
            Assert.IsType<SyncPong>(Assert.Single(fresh.Drain()));
            await fresh.SendAsync(new SyncPong()); Assert.Empty(fresh.Drain());
            await r.Pc.DisconnectAsync(fresh.Peer);
        }
    }

    [Theory]
    [InlineData(false, 50)]
    [InlineData(true, 33)]
    public async Task PreAuthenticationAssemblyRejectsOneByteBeyondHandshake(bool afterHello, int limit)
    {
        var r = new Rig(); var peer = new FakePeer { PacketLimit = 512 };
        await r.Pc.ConnectAsync(peer);
        if (afterHello)
            await r.SendFrameAsync(peer, new SyncPadHandshake(r.Pairing, Guid.NewGuid()).CreateHello());
        var packet = new byte[limit + 1]; packet[0] = 1;
        Assert.True(await r.Pc.ReceiveAsync(peer, packet));
        Assert.False(await r.Pc.ReceiveAsync(peer, [0, 0]));
        Assert.True(peer.Rejected); Assert.Empty(r.Clipboard.Writes);
    }

    [Theory]
    [InlineData(20)]
    [InlineData(182)]
    [InlineData(512)]
    public async Task HandshakeAndBidirectionalItemsAndAcknowledgements(int limit)
    {
        var r = new Rig(); var pad = await r.ConnectAsync(limit);
        Assert.Equal(1, r.State.Connected);
        var text = "日本語・改行\n📋" + new string('x', 1000);
        await r.Pc.ClipboardChangedAsync(new(1, text, false)); await r.Pc.WaitForOutgoingAsync();
        var sent = Assert.IsType<SyncItem>(Assert.Single(pad.Drain()));
        Assert.Equal(text, sent.Text); Assert.Equal("pc", sent.From);
        Assert.Equal(1, r.State.Pending); Assert.NotNull(r.State.LastSent);
        await pad.SendAsync(new SyncAck([sent.Id]));
        Assert.Equal(0, r.State.Pending);
        var item = new SyncItem(Guid.NewGuid(), 1234, "pad", "iPadから");
        await pad.SendAsync(item);
        Assert.Equal(new[] { item.Text }, r.Clipboard.Writes);
        Assert.Equal(item.Id, Assert.Single(Assert.IsType<SyncAck>(Assert.Single(pad.Drain())).Ids));
        Assert.NotNull(r.State.LastReceived);
        Assert.DoesNotContain(r.Logs, l => l.Contains(text) || l.Contains(item.Text) || l.Contains(r.Pairing.ToQrString()));
    }

    [Fact]
    public async Task UnacknowledgedItemsAreResentWithStableIdsAndFreshSessionKeys()
    {
        var r = new Rig();
        await r.Pc.ClipboardChangedAsync(new(1, "offline", false)); await r.Pc.WaitForOutgoingAsync();
        var first = await r.ConnectAsync();
        var original = Assert.IsType<SyncItem>(Assert.Single(first.Drain()));
        await r.Pc.DisconnectAsync(first.Peer);
        Assert.True(first.Peer.Rejected); Assert.Equal(1, r.State.Pending);
        await r.Pc.ClipboardChangedAsync(new(2, "offline two", false)); await r.Pc.WaitForOutgoingAsync();
        var second = await r.ConnectAsync(182);
        var retry = second.Drain().Cast<SyncItem>().ToArray();
        Assert.Equal(2, retry.Length); Assert.Equal(original, retry[0]);
        await second.SendAsync(new SyncAck(retry.Select(i => i.Id).ToArray()));
        Assert.Equal(0, r.State.Pending);
        await r.Pc.DisconnectAsync(second.Peer);
        var third = await r.ConnectAsync(); Assert.Empty(third.Drain());
        Assert.Contains(r.Logs, l => l.Contains("resend=True"));
    }

    [Fact]
    public async Task DuplicateIdsAreAcknowledgedWithoutWritingAgainEvenAcrossReconnect()
    {
        var r = new Rig(); var pad = await r.ConnectAsync();
        var item = new SyncItem(Guid.NewGuid(), 0, "pad", "once");
        await pad.SendAsync(item); await pad.SendAsync(item);
        Assert.Single(r.Clipboard.Writes);
        Assert.Equal(2, pad.Drain().Length);
        await r.Pc.DisconnectAsync(pad.Peer);
        pad = await r.ConnectAsync(); await pad.SendAsync(item);
        Assert.Single(r.Clipboard.Writes);
        Assert.Equal(item.Id, Assert.Single(Assert.IsType<SyncAck>(Assert.Single(pad.Drain())).Ids));
    }

    [Fact]
    public async Task OwnClipboardWriteExcludedAndNonTextChangesDoNotEcho()
    {
        var r = new Rig(); var pad = await r.ConnectAsync();
        await pad.SendAsync(new SyncItem(Guid.NewGuid(), 0, "pad", "remote"));
        pad.Drain();
        await r.Pc.ClipboardChangedAsync(new(r.Clipboard.Sequence, "remote", false)); await r.Pc.WaitForOutgoingAsync();
        await r.Pc.ClipboardChangedAsync(new(102, "password", true)); await r.Pc.WaitForOutgoingAsync();
        await r.Pc.ClipboardChangedAsync(new(103, null, false)); await r.Pc.WaitForOutgoingAsync();
        Assert.Empty(pad.Drain()); Assert.Equal(0, r.State.Pending);
        // The same text copied by the user at a new sequence must still be sent.
        await r.Pc.ClipboardChangedAsync(new(104, "remote", false)); await r.Pc.WaitForOutgoingAsync();
        await r.Pc.ClipboardChangedAsync(new(104, "remote", false)); await r.Pc.WaitForOutgoingAsync();
        Assert.Single(pad.Drain()); Assert.Equal(1, r.State.Pending);
    }

    [Theory]
    [InlineData("packet")]
    [InlineData("cipher")]
    [InlineData("message")]
    [InlineData("replay")]
    [InlineData("direction")]
    public async Task BadDataRetiresOnlyItsConnectionAndLeavesPendingForReconnect(string fault)
    {
        var r = new Rig(); var pad = await r.ConnectAsync(); var healthy = await r.ConnectAsync();
        await r.Pc.ClipboardChangedAsync(new(1, "pending", false)); await r.Pc.WaitForOutgoingAsync();
        pad.Drain(); healthy.Drain();
        var frame = pad.Seal(new SyncPing());
        if (fault == "cipher") frame[^1] ^= 1;
        if (fault == "message")
        {
            // Authenticated but invalid plaintext: obtain a separate connection's keys.
            await r.Pc.DisconnectAsync(pad.Peer);
            var peer = new FakePeer(); await r.Pc.ConnectAsync(peer);
            var h = new SyncPadHandshake(r.Pairing, Guid.NewGuid());
            await r.SendFrameAsync(peer, h.CreateHello());
            var auth = h.AcceptWelcome(Assert.Single(peer.DrainFrames()));
            await r.SendFrameAsync(peer, auth.Auth); peer.DrainFrames();
            frame = new SyncFrameSender(auth.Keys.PadToPc).Seal([0, 1, (byte)'{']);
            pad = new Pad(r, peer, auth.Keys);
        }
        if (fault == "direction") frame = pad.Seal(new SyncItem(Guid.NewGuid(), 0, "pc", "wrong direction"));
        if (fault == "replay") await r.SendFrameAsync(pad.Peer, frame);
        bool accepted = true;
        foreach (var packet in fault == "packet" ? new byte[][] { [4, 0] } : SyncPacketizer.Split(frame, pad.Peer.PacketLimit))
            accepted = await r.Pc.ReceiveAsync(pad.Peer, packet);
        Assert.False(accepted); Assert.True(pad.Peer.Rejected);
        Assert.Equal(1, r.State.Connected); Assert.Equal(1, r.State.Pending);
        Assert.False(await r.Pc.ReceiveAsync(pad.Peer, [3, 1]));
        await healthy.SendAsync(new SyncPing()); Assert.False(healthy.Peer.Rejected);
        var replacement = await r.ConnectAsync();
        Assert.Single(replacement.Drain());
    }

    [Fact]
    public async Task InvalidAuthAndDataBeforeAuthCannotWriteClipboard()
    {
        var r = new Rig(); var peer = new FakePeer();
        await r.Pc.ConnectAsync(peer);
        Assert.False(await r.Pc.ReceiveAsync(peer, [3, 0x10, 0]));
        Assert.True(peer.Rejected); Assert.Empty(r.Clipboard.Writes);
        peer = new FakePeer(); await r.Pc.ConnectAsync(peer);
        var pad = new SyncPadHandshake(r.Pairing, Guid.NewGuid());
        await r.SendFrameAsync(peer, pad.CreateHello());
        var auth = pad.AcceptWelcome(Assert.Single(peer.DrainFrames())).Auth;
        auth[^1] ^= 1;
        var packets = SyncPacketizer.Split(auth, peer.PacketLimit);
        foreach (var packet in packets.Take(packets.Count - 1)) Assert.True(await r.Pc.ReceiveAsync(peer, packet));
        Assert.False(await r.Pc.ReceiveAsync(peer, packets[^1]));
        Assert.True(peer.Rejected); Assert.Equal(0, r.State.Connected);
    }

    [Fact]
    public async Task PendingAndDuplicateCachesHaveTheirSpecifiedBounds()
    {
        var r = new Rig();
        for (uint i = 1; i <= 51; i++) await r.Pc.ClipboardChangedAsync(new(i, $"item {i}", false)); await r.Pc.WaitForOutgoingAsync();
        Assert.Equal(50, r.State.Pending);
        var pad = await r.ConnectAsync(182);
        var sent = pad.Drain().Cast<SyncItem>().ToArray();
        Assert.Equal(50, sent.Length); Assert.Equal("item 2", sent[0].Text);
        await pad.SendAsync(new SyncAck(sent.Select(i => i.Id).ToArray()));
        var oldest = new SyncItem(Guid.NewGuid(), 0, "pad", "oldest");
        await pad.SendAsync(oldest);
        var others = Enumerable.Range(0, 500).Select(i => new SyncItem(Guid.NewGuid(), i, "pad", "next")).ToArray();
        foreach (var item in others) await pad.SendAsync(item);
        pad.Drain();
        await pad.SendAsync(others[^1]); Assert.Equal(501, r.Clipboard.Writes.Count);
        await pad.SendAsync(oldest); Assert.Equal(502, r.Clipboard.Writes.Count);
    }

    [Fact]
    public async Task SendFailureAndClipboardFailureDoNotLoseUnconfirmedWork()
    {
        var r = new Rig(); var pad = await r.ConnectAsync();
        pad.Peer.FailSend = true;
        await r.Pc.ClipboardChangedAsync(new(1, "retry", false)); await r.Pc.WaitForOutgoingAsync();
        Assert.True(pad.Peer.Rejected); Assert.Equal(1, r.State.Pending);
        pad = await r.ConnectAsync(); Assert.Single(pad.Drain());
        var item = new SyncItem(Guid.NewGuid(), 0, "pad", "retry receive");
        r.Clipboard.Fail = true;
        var frame = pad.Seal(item); bool result = true;
        foreach (var packet in SyncPacketizer.Split(frame, 20)) result = await r.Pc.ReceiveAsync(pad.Peer, packet);
        Assert.False(result); Assert.Empty(r.Clipboard.Writes); Assert.Empty(pad.Peer.Packets);
        r.Clipboard.Fail = false;
        pad = await r.ConnectAsync(); pad.Drain(); await pad.SendAsync(item);
        Assert.Single(r.Clipboard.Writes); Assert.Single(pad.Drain());
    }

    [Fact]
    public async Task HandshakeAndPartialFrameTimeoutRetireState()
    {
        var r = new Rig(); var peer = new FakePeer(); await r.Pc.ConnectAsync(peer);
        await r.Pc.TickAsync(DateTimeOffset.UtcNow.AddSeconds(21)); await r.Pc.WaitForOutgoingAsync(); Assert.True(peer.Rejected);
        var pad = await r.ConnectAsync();
        Assert.True(await r.Pc.ReceiveAsync(pad.Peer, [1, 0x10]));
        await r.Pc.TickAsync(DateTimeOffset.UtcNow.AddSeconds(21)); await r.Pc.WaitForOutgoingAsync();
        Assert.True(pad.Peer.Rejected); Assert.Contains(r.Logs, l => l.Contains("assembly ended"));
    }

    [Fact]
    public async Task IncreasedMtuAfterSubscriptionDoesNotResetTheAssembler()
    {
        var r = new Rig(); var pad = await r.ConnectAsync();
        pad.Peer.PacketLimit = 182;
        await pad.SendAsync(new SyncItem(Guid.NewGuid(), 0, "pad", new string('x', 1000)));
        Assert.Single(r.Clipboard.Writes); Assert.Single(pad.Drain());
        await r.Pc.ClipboardChangedAsync(new(1, new string('y', 1000), false)); await r.Pc.WaitForOutgoingAsync();
        Assert.Single(pad.Drain());
    }

    [Fact]
    public async Task MissingAckRetriesOnTheSameLinkWithoutReusingFrameSequence()
    {
        var r = new Rig(); var pad = await r.ConnectAsync();
        await r.Pc.ClipboardChangedAsync(new(1, "retry on a live link", false)); await r.Pc.WaitForOutgoingAsync();
        var original = Assert.IsType<SyncItem>(Assert.Single(pad.Drain()));
        await r.Pc.TickAsync(DateTimeOffset.UtcNow.AddSeconds(59)); await r.Pc.WaitForOutgoingAsync();
        Assert.Empty(pad.Drain());
        await r.Pc.TickAsync(DateTimeOffset.UtcNow.AddSeconds(61)); await r.Pc.WaitForOutgoingAsync();
        // The same receiver accepts this, proving its sequence was advanced.
        Assert.Equal(original, Assert.Single(pad.Drain()));
        await pad.SendAsync(new SyncAck([original.Id]));
        await r.Pc.TickAsync(DateTimeOffset.UtcNow.AddMinutes(2)); await r.Pc.WaitForOutgoingAsync();
        Assert.Empty(pad.Drain()); Assert.Equal(0, r.State.Pending);
    }
}
