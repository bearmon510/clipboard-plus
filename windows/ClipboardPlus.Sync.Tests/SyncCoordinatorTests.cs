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
        bool ISyncPeer.IsRejected => Rejected;
        public bool FailSend { get; set; }
        public Func<byte[], Task>? OnSend;
        public readonly List<byte[]> Packets = [];
        public readonly List<bool> HighThroughputHistory = [];
        public Task SendPacketAsync(byte[] packet)
        {
            Assert.False(Rejected);
            Assert.InRange(packet.Length, 2, PacketLimit);
            if (FailSend) throw new IOException("fake transport error");
            Packets.Add(packet.ToArray());
            return OnSend?.Invoke(packet) ?? Task.CompletedTask;
        }
        public void Reject() => Rejected = true;
        public void SetHighThroughput(bool enabled) => HighThroughputHistory.Add(enabled);
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
        public ClipboardRejectReason? RejectReason;
        public Func<Task>? BeforeWrite;
        public readonly List<string> Writes = [];
        public readonly List<HistoryItem> MediaWrites = [];
        public async Task<uint> WriteItemAsync(HistoryItem item)
        {
            if (BeforeWrite is not null) await BeforeWrite();
            if (item.Kind == "text") return await WriteTextAsync(item.Text!);
            if (RejectReason is { } reason) throw new ClipboardContentRejectedException(reason);
            if (Fail) throw new IOException("busy clipboard");
            MediaWrites.Add(item); return ++Sequence;
        }
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
        public readonly Guid DeviceId = Guid.NewGuid();
        public readonly string Root = Path.Combine(Path.GetTempPath(), "clipboardplus-tests", Guid.NewGuid().ToString("N"));
        public readonly SyncRepository Store;
        public readonly System.Collections.Concurrent.ConcurrentQueue<string> Logs = new();
        public readonly SyncCoordinator Pc;
        public DateTimeOffset Now = DateTimeOffset.UtcNow;
        public SyncStatus State = new(0, 0, null, null);
        public Rig()
        {
            Store = new(Root, Pairing.PcId); Store.Register(DeviceId, "pad", Now);
            Pc = new(Pairing, Clipboard, Logs.Enqueue, Store, () => Now);
            Pc.Changed += s => State = s;
        }

        public async Task<Pad> ConnectAsync(int limit = 20, Guid? deviceId = null)
        {
            var alreadyConnected = State.Connected;
            var peer = new FakePeer { PacketLimit = limit };
            var handshake = new SyncPadHandshake(Pairing, deviceId ?? DeviceId);
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
        public byte[] SealRawPlaintext(byte[] plaintext) => sender.Seal(plaintext);
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
        var handshake = new SyncPadHandshake(r.Pairing, r.DeviceId);
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
        await r.SendFrameAsync(peer, new SyncPadHandshake(r.Pairing, r.DeviceId).CreateHello());
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
            await r.SendFrameAsync(peer, new SyncPadHandshake(r.Pairing, r.DeviceId).CreateHello());
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
        var r = new Rig(); var pad = await r.ConnectAsync(); var healthy = await r.ConnectAsync(deviceId: Guid.NewGuid());
        await r.Pc.ClipboardChangedAsync(new(1, "pending", false)); await r.Pc.WaitForOutgoingAsync();
        pad.Drain(); healthy.Drain();
        var frame = pad.Seal(new SyncPing());
        if (fault == "cipher") frame[^1] ^= 1;
        if (fault == "message")
        {
            // Authenticated but invalid plaintext: obtain a separate connection's keys.
            await r.Pc.DisconnectAsync(pad.Peer);
            var peer = new FakePeer(); await r.Pc.ConnectAsync(peer);
            var h = new SyncPadHandshake(r.Pairing, r.DeviceId);
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
        Assert.Equal(1, r.State.Connected); Assert.Equal(2, r.State.Pending);
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
        var pad = new SyncPadHandshake(r.Pairing, r.DeviceId);
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
        for (uint i = 1; i <= 101; i++) await r.Pc.ClipboardChangedAsync(new(i, $"item {i}", false)); await r.Pc.WaitForOutgoingAsync();
        Assert.Equal(100, r.State.Pending);
        var pad = await r.ConnectAsync(182);
        var sent = pad.Drain().Cast<SyncItem>().ToArray();
        Assert.Equal(100, sent.Length); Assert.Equal("item 2", sent[0].Text);
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

    [Fact]
    public async Task EachDeviceOwnsItsAckAndOfflineQueueAndDeviceKind()
    {
        var r = new Rig(); var phoneId = Guid.NewGuid();
        var pad = await r.ConnectAsync(); var phone = await r.ConnectAsync(deviceId: phoneId);
        await phone.SendAsync(new SyncDevice("phone"));
        await r.Pc.ClipboardChangedAsync(new(1, "both", false)); await r.Pc.WaitForOutgoingAsync();
        var item = Assert.IsType<SyncItem>(Assert.Single(pad.Drain()));
        Assert.Equal(item, Assert.Single(phone.Drain()));
        await pad.SendAsync(new SyncAck([item.Id]));
        Assert.Empty(r.Store.Pending(r.DeviceId)); Assert.Single(r.Store.Pending(phoneId));
        await r.Pc.DisconnectAsync(phone.Peer);
        await r.Pc.ClipboardChangedAsync(new(2, "offline", false)); await r.Pc.WaitForOutgoingAsync();
        Assert.Equal(2, r.Store.Pending(phoneId).Count);
        phone = await r.ConnectAsync(deviceId: phoneId);
        Assert.Equal(2, phone.Drain().Length);
        var state = await r.Pc.GetStatusAsync();
        Assert.Contains(state.Devices!, d => d.Id == phoneId && d.Kind == "phone" && d.Pending == 2 && d.Connected);
    }

    [Fact]
    public async Task SharedClipboardDeduplicatesAcrossDevicesAndNeverRelays()
    {
        var r = new Rig(); var pad = await r.ConnectAsync(); var phone = await r.ConnectAsync(deviceId: Guid.NewGuid());
        await phone.SendAsync(new SyncDevice("phone"));
        await phone.SendAsync(new SyncItem(Guid.NewGuid(), 10, "pad", "shared"));
        phone.Drain(); Assert.Empty(pad.Drain());
        await pad.SendAsync(new SyncItem(Guid.NewGuid(), 11, "pad", "shared"));
        Assert.Single(r.Clipboard.Writes); Assert.IsType<SyncAck>(Assert.Single(pad.Drain()));
        var history = await r.Pc.GetHistoryAsync();
        Assert.Equal("iPhone", Assert.Single(history).Source); Assert.Equal(10, history[0].At);
        await r.Pc.ClipboardChangedAsync(new(1, "PC echo", false)); await r.Pc.WaitForOutgoingAsync();
        phone.Drain(); pad.Drain();
        await pad.SendAsync(new SyncItem(Guid.NewGuid(), 12, "pad", "PC echo"));
        Assert.Single(r.Clipboard.Writes); Assert.IsType<SyncAck>(Assert.Single(pad.Drain()));
    }

    [Fact]
    public async Task FileReceiveResumesAfterReconnectAndOnlyAcksVerifiedCommittedContent()
    {
        var r = new Rig(); var pad = await r.ConnectAsync(512);
        var data = Enumerable.Range(0, SyncProtocol.ChunkBytes + 7).Select(i => (byte)i).ToArray();
        var offer = new SyncOffer(Guid.NewGuid(), 1234567, "pad", "file", data.Length,
            Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(data)), Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("secret.txt")), "public.data");
        await pad.SendAsync(offer);
        Assert.Equal(new SyncResume(offer.Id, 0), Assert.Single(pad.Drain()));
        await pad.SendAsync(new SyncChunk(offer.Id, 0, data[..SyncProtocol.ChunkBytes]));
        Assert.Equal(new SyncResume(offer.Id, SyncProtocol.ChunkBytes), Assert.Single(pad.Drain()));
        Assert.Empty(r.Clipboard.MediaWrites); Assert.Empty(await r.Pc.GetHistoryAsync());
        await r.Pc.DisconnectAsync(pad.Peer); pad = await r.ConnectAsync(512);
        await pad.SendAsync(offer); Assert.Equal(new SyncResume(offer.Id, SyncProtocol.ChunkBytes), Assert.Single(pad.Drain()));
        await pad.SendAsync(new SyncChunk(offer.Id, SyncProtocol.ChunkBytes, data[SyncProtocol.ChunkBytes..]));
        Assert.Equal(offer.Id, Assert.Single(Assert.IsType<SyncAck>(Assert.Single(pad.Drain())).Ids));
        var saved = Assert.Single(await r.Pc.GetHistoryAsync());
        Assert.Equal(data, File.ReadAllBytes(saved.Path!)); Assert.Equal(offer.At, saved.At);
        await pad.SendAsync(offer); Assert.IsType<SyncAck>(Assert.Single(pad.Drain())); Assert.Single(r.Clipboard.MediaWrites);
        Assert.DoesNotContain(r.Logs, l => l.Contains("secret.txt") || l.Contains(offer.Sha256));
    }

    [Fact]
    public async Task BinarySendWaitsForDurableOffsetsAndPrioritizesPong()
    {
        var r = new Rig(); var pad = await r.ConnectAsync(512);
        var data = new byte[SyncProtocol.ChunkBytes * 4 + 1]; data[^1] = 42;
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "a.txt", Data: data)]));
        await r.Pc.WaitForOutgoingAsync(); var offer = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        await pad.SendAsync(new SyncPing()); Assert.IsType<SyncPong>(Assert.Single(pad.Drain()));
        await pad.SendAsync(new SyncResume(offer.Id, 0));
        var window = pad.Drain().Cast<SyncChunk>().ToArray();
        Assert.Equal(4, window.Length);
        Assert.All(window, ch => Assert.Equal(SyncProtocol.ChunkBytes, ch.Data.Length));
        await pad.SendAsync(new SyncResume(offer.Id, SyncProtocol.ChunkBytes));
        var last = Assert.IsType<SyncChunk>(Assert.Single(pad.Drain())); Assert.Equal(new byte[] { 42 }, last.Data);
        await pad.SendAsync(new SyncAck([offer.Id])); Assert.Equal(0, r.State.Pending);
    }

    [Fact]
    public async Task HistoryApiSearchDeleteClearAndCopyDoNotResend()
    {
        var r = new Rig(); var pad = await r.ConnectAsync(); var notifications = 0;
        r.Pc.HistoryChanged += () => notifications++;
        await r.Pc.ClipboardChangedAsync(new(1, "Find Me", false)); await r.Pc.WaitForOutgoingAsync();
        var sent = Assert.IsType<SyncItem>(Assert.Single(pad.Drain())); await pad.SendAsync(new SyncAck([sent.Id]));
        var item = Assert.Single(await r.Pc.GetHistoryAsync("find"));
        await r.Pc.CopyHistoryAsync(item.Id);
        await r.Pc.ClipboardChangedAsync(new(r.Clipboard.Sequence, item.Text, false)); await r.Pc.WaitForOutgoingAsync();
        Assert.Empty(pad.Drain());
        await r.Pc.DeleteHistoryAsync(item.Id); Assert.Empty(await r.Pc.GetHistoryAsync());
        await r.Pc.ClearHistoryAsync(); Assert.Equal(3, notifications);
    }

    [Fact]
    public async Task DeleteHistoryAfterAckKeepsConnectionWhileUnackedInFlightDeletionDrops()
    {
        var r = new Rig();
        await r.Pc.ClipboardChangedAsync(new(1, "first", false));
        await r.Pc.ClipboardChangedAsync(new(2, "second", false));
        var pad = await r.ConnectAsync(512);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pad.Peer.OnSend = packet =>
        {
            if ((packet[0] & 2) != 0 && !entered.Task.IsCompleted)
            { entered.SetResult(); return release.Task; }
            return Task.CompletedTask;
        };
        // Reconnect triggers sending while holding the first item in flight.
        await r.Pc.DisconnectAsync(pad.Peer);
        var peer = new FakePeer { PacketLimit = 512 };
        await r.Pc.ConnectAsync(peer);
        var handshake = new SyncPadHandshake(r.Pairing, r.DeviceId);
        await r.SendFrameAsync(peer, handshake.CreateHello());
        var auth = handshake.AcceptWelcome(Assert.Single(peer.DrainFrames()));
        var pad2 = new Pad(r, peer, auth.Keys);
        peer.OnSend = packet =>
        {
            if ((packet[0] & 2) != 0 && !entered.Task.IsCompleted)
            { entered.SetResult(); return release.Task; }
            return Task.CompletedTask;
        };
        entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        foreach (var packet in SyncPacketizer.Split(auth.Auth, 512))
            Assert.True(await r.Pc.ReceiveAsync(peer, packet));
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var first = Assert.IsType<SyncItem>(Assert.Single(pad2.Drain()));
        try
        {
            foreach (var packet in SyncPacketizer.Split(pad2.Seal(new SyncAck([first.Id])), 512))
                Assert.True(await r.Pc.ReceiveAsync(peer, packet));
            await r.Pc.DeleteHistoryAsync(first.Id);
            Assert.False(peer.Rejected);
        }
        finally { release.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(peer);
        Assert.Equal("second", Assert.IsType<SyncItem>(Assert.Single(pad2.Drain())).Text);

        // Now verify unacked in-flight deletion still drops the connection.
        var thirdEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thirdRelease = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        peer.OnSend = packet =>
        {
            if ((packet[0] & 2) != 0 && !thirdEntered.Task.IsCompleted)
            { thirdEntered.SetResult(); return thirdRelease.Task; }
            return Task.CompletedTask;
        };
        await r.Pc.ClipboardChangedAsync(new(3, "third", false));
        await thirdEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var third = Assert.Single(await r.Pc.GetHistoryAsync("third"));
        try { await r.Pc.DeleteHistoryAsync(third.Id); }
        finally { thirdRelease.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(peer);
        Assert.True(peer.Rejected);
    }

    [Fact]
    public async Task RejectedContentDiscardsPartialLogsFixedReasonAcksAndDoesNotCommit()
    {
        var r = new Rig(); var pad = await r.ConnectAsync(512);
        var data = new byte[] { 1, 2, 3, 4 };
        var sha = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(data));
        var offer = new SyncOffer(Guid.NewGuid(), 100, "pad", "image", data.Length, sha, Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("secret-huge.png")), "public.png");
        r.Clipboard.RejectReason = ClipboardRejectReason.ImageDimensions;

        await pad.SendAsync(offer);
        Assert.Equal(new SyncResume(offer.Id, 0), Assert.Single(pad.Drain()));
        await pad.SendAsync(new SyncChunk(offer.Id, 0, data));

        Assert.False(pad.Peer.Rejected);
        Assert.Equal(offer.Id, Assert.Single(Assert.IsType<SyncAck>(Assert.Single(pad.Drain())).Ids));
        Assert.Empty(await r.Pc.GetHistoryAsync());
        Assert.Empty(r.Clipboard.MediaWrites);
        Assert.Null(r.Store.Incoming(r.DeviceId, offer.Id));
        Assert.False(File.Exists(r.Store.PartialPath(r.DeviceId, offer.Id)));
        Assert.False(File.Exists(Path.Combine(r.Root, "bodies", sha)));
        Assert.Contains(r.Logs, l => l.Contains("reason=image-dimensions"));
        Assert.DoesNotContain(r.Logs, l => l.Contains("secret-huge.png") || l.Contains(sha));

        // If sender re-offers the same rejected ID (e.g., missed ACK), PC immediately ACKs without writing.
        await pad.SendAsync(offer);
        Assert.Equal(offer.Id, Assert.Single(Assert.IsType<SyncAck>(Assert.Single(pad.Drain())).Ids));
        Assert.Empty(await r.Pc.GetHistoryAsync());
    }

    [Fact]
    public async Task TransientFailureDuringFinishDiscardsPartialAndDisconnects()
    {
        var r = new Rig(); var pad = await r.ConnectAsync(512);
        var data = new byte[] { 9, 8, 7, 6 };
        var sha = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(data));
        var offer = new SyncOffer(Guid.NewGuid(), 100, "pad", "image", data.Length, sha, "", "public.png");
        r.Clipboard.Fail = true;

        await pad.SendAsync(offer);
        Assert.Equal(new SyncResume(offer.Id, 0), Assert.Single(pad.Drain()));
        var frame = pad.Seal(new SyncChunk(offer.Id, 0, data));
        bool ok = true;
        foreach (var packet in SyncPacketizer.Split(frame, pad.Peer.PacketLimit))
            ok = await r.Pc.ReceiveAsync(pad.Peer, packet);
        Assert.False(ok);
        Assert.True(pad.Peer.Rejected);
        Assert.Empty(pad.Peer.Packets);
        Assert.Null(r.Store.Incoming(r.DeviceId, offer.Id));
        Assert.False(File.Exists(r.Store.PartialPath(r.DeviceId, offer.Id)));
        Assert.False(File.Exists(Path.Combine(r.Root, "bodies", sha)));

        r.Clipboard.Fail = false;
        pad = await r.ConnectAsync(512);
        await pad.SendAsync(offer);
        Assert.Equal(new SyncResume(offer.Id, 0), Assert.Single(pad.Drain()));
        await pad.SendAsync(new SyncChunk(offer.Id, 0, data));
        Assert.Equal(offer.Id, Assert.Single(Assert.IsType<SyncAck>(Assert.Single(pad.Drain())).Ids));
        Assert.Single(r.Clipboard.MediaWrites);
    }

    [Fact]
    public async Task OnlyOneAttachmentTransfersAtATimePerConnectionWhileAllowingTextAndControl()
    {
        var r = new Rig(); var pad = await r.ConnectAsync(512);
        var data1 = new byte[SyncProtocol.ChunkBytes * 4 + 5]; data1[^1] = 1;
        var data2 = new byte[] { 2, 3, 4 };
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [
            new("file", Filename: "one.bin", Data: data1),
            new("text", Text: "interleaved text"),
            new("file", Filename: "two.bin", Data: data2)
        ]));
        await r.Pc.WaitForOutgoingAsync();

        var batch1 = pad.Drain();
        Assert.Equal(2, batch1.Length);
        var offer1 = Assert.IsType<SyncOffer>(batch1[0]);
        Assert.Equal("one.bin", offer1.Filename);
        var textItem = Assert.IsType<SyncItem>(batch1[1]);
        Assert.Equal("interleaved text", textItem.Text);

        await pad.SendAsync(new SyncPing());
        Assert.IsType<SyncPong>(Assert.Single(pad.Drain()));

        await pad.SendAsync(new SyncResume(offer1.Id, 0));
        var chunks1 = pad.Drain().Cast<SyncChunk>().ToArray();
        Assert.Equal(4, chunks1.Length);
        Assert.All(chunks1, ch => Assert.Equal(offer1.Id, ch.Id));
        await pad.SendAsync(new SyncResume(offer1.Id, SyncProtocol.ChunkBytes));
        var chunk5 = Assert.IsType<SyncChunk>(Assert.Single(pad.Drain()));
        Assert.Equal(offer1.Id, chunk5.Id);
        Assert.Equal(5, chunk5.Data.Length);

        // Wait for final ACK of file 1 before offering file 2.
        await pad.SendAsync(new SyncAck([textItem.Id]));
        Assert.Empty(pad.Drain());

        await pad.SendAsync(new SyncAck([offer1.Id]));
        var offer2 = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        Assert.Equal("two.bin", offer2.Filename);
        await pad.SendAsync(new SyncResume(offer2.Id, 0));
        Assert.IsType<SyncChunk>(Assert.Single(pad.Drain()));
        await pad.SendAsync(new SyncAck([offer2.Id]));
        Assert.Equal(0, r.State.Pending);

        // Zero-byte attachment also blocks next offer until ACKed.
        await r.Pc.ClipboardChangedAsync(new(2, null, false, [
            new("file", Filename: "empty.bin", Data: []),
            new("file", Filename: "after-empty.bin", Data: [9])
        ]));
        await r.Pc.WaitForOutgoingAsync();
        var emptyOffer = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        Assert.Equal("empty.bin", emptyOffer.Filename);
        await pad.SendAsync(new SyncAck([emptyOffer.Id]));
        var afterEmpty = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        Assert.Equal("after-empty.bin", afterEmpty.Filename);
    }

    [Theory]
    [InlineData(10)]
    [InlineData(0)]
    public async Task ResumeAtOrBeyondItemSizeIsRejectedImmediately(int size)
    {
        var r = new Rig(); var pad = await r.ConnectAsync(512);
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "f.bin", Data: new byte[size])]));
        await r.Pc.WaitForOutgoingAsync();
        var offer = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));

        var frame = pad.Seal(new SyncResume(offer.Id, size));
        bool ok = true;
        foreach (var packet in SyncPacketizer.Split(frame, pad.Peer.PacketLimit))
            ok = await r.Pc.ReceiveAsync(pad.Peer, packet);
        Assert.False(ok);
        Assert.True(pad.Peer.Rejected);
    }

    [Fact]
    public async Task FutureHistoryItemsDoNotEvictPendingAttachmentBodyBeforeSend()
    {
        var r = new Rig();
        var future = DateTimeOffset.UtcNow.AddDays(1);
        for (var i = 0; i < SyncProtocol.MaxHistory; i++)
            r.Store.AddHistory(r.Store.Create(new("text", Text: $"future {i}"), future.AddSeconds(i).ToUnixTimeMilliseconds(), "iPad"));

        var pad = await r.ConnectAsync(512);
        var data = new byte[] { 11, 22, 33, 44 };
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "local.bin", Data: data)]));
        await r.Pc.WaitForOutgoingAsync();

        Assert.Equal(1, r.State.Pending);
        var pendingItem = Assert.Single(r.Store.Pending(r.DeviceId));
        Assert.True(File.Exists(pendingItem.Path));

        var offer = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        await pad.SendAsync(new SyncResume(offer.Id, 0));
        var chunk = Assert.IsType<SyncChunk>(Assert.Single(pad.Drain()));
        Assert.Equal(data, chunk.Data);
    }

    [Fact]
    public async Task DuplicateFromOtherDeviceDoesNotBlockOriginalDeviceCopy()
    {
        var r = new Rig();
        var phoneId = Guid.NewGuid();
        var pad = await r.ConnectAsync();
        var phone = await r.ConnectAsync(deviceId: phoneId);
        await phone.SendAsync(new SyncDevice("phone"));

        await phone.SendAsync(new SyncItem(Guid.NewGuid(), 10, "pad", "A"));
        phone.Drain();
        await pad.SendAsync(new SyncItem(Guid.NewGuid(), 11, "pad", "A"));
        pad.Drain();
        Assert.Single(r.Clipboard.Writes);

        await phone.SendAsync(new SyncItem(Guid.NewGuid(), 12, "pad", "A"));
        Assert.Equal(2, r.Clipboard.Writes.Count);
        Assert.IsType<SyncAck>(Assert.Single(phone.Drain()));
    }

    [Fact]
    public async Task LastSentAndLastReceivedUseUtcBasis()
    {
        var r = new Rig(); var pad = await r.ConnectAsync();
        await r.Pc.ClipboardChangedAsync(new(1, "utc out", false));
        await r.Pc.WaitForOutgoingAsync();
        pad.Drain();
        await pad.SendAsync(new SyncItem(Guid.NewGuid(), 100, "pad", "utc in"));
        Assert.NotNull(r.State.LastSent);
        Assert.NotNull(r.State.LastReceived);
        Assert.Equal(TimeSpan.Zero, r.State.LastSent!.Value.Offset);
        Assert.Equal(TimeSpan.Zero, r.State.LastReceived!.Value.Offset);
    }

    [Fact]
    public async Task VersionMismatchTracksOnlyRegisteredDevicesAndClearsAfterV2Auth()
    {
        var r = new Rig();
        byte[] V1Hello(Guid id) => [1, 1, .. id.ToByteArray(bigEndian: true), .. new byte[32]];

        // Unregistered device sending v1 HELLO does not set RequiresPeerUpdate, and receives PC ID in mismatch WELCOME.
        var unknownPeer = new FakePeer { PacketLimit = 512 };
        await r.Pc.ConnectAsync(unknownPeer);
        await r.SendFrameAsync(unknownPeer, V1Hello(Guid.NewGuid()));
        Assert.True(unknownPeer.Rejected);
        var unknownMismatch = Assert.Single(unknownPeer.DrainFrames());
        Assert.Equal(82, unknownMismatch.Length);
        Assert.Equal(2, unknownMismatch[0]);
        Assert.Equal(SyncProtocol.Version, unknownMismatch[1]);
        Assert.Equal(r.Pairing.PcId, new Guid(unknownMismatch.AsSpan(2, 16), bigEndian: true));
        Assert.False(r.State.RequiresPeerUpdate);

        // Registered device sending v1 HELLO sets RequiresPeerUpdate and clears on v2 auth.
        var registeredPeer = new FakePeer { PacketLimit = 512 };
        await r.Pc.ConnectAsync(registeredPeer);
        await r.SendFrameAsync(registeredPeer, V1Hello(r.DeviceId));
        Assert.True(registeredPeer.Rejected);
        var registeredMismatch = Assert.Single(registeredPeer.DrainFrames());
        Assert.Equal(r.Pairing.PcId, new Guid(registeredMismatch.AsSpan(2, 16), bigEndian: true));
        Assert.True(r.State.RequiresPeerUpdate);

        var updated = await r.ConnectAsync();
        Assert.False(r.State.RequiresPeerUpdate);
        await r.Pc.DisconnectAsync(updated.Peer);
    }

    [Fact]
    public async Task DisposeAsyncWaitsForInFlightSenderAndReceiveAndPreventsStateOverwrite()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);
        var sendEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var releaseSend = new ManualResetEventSlim(false);
        pad.Peer.OnSend = _ =>
        {
            sendEntered.TrySetResult();
            releaseSend.Wait(TimeSpan.FromSeconds(5));
            return Task.CompletedTask;
        };

        try
        {
            await r.Pc.ClipboardChangedAsync(new(1, "in-flight send", false));
            await sendEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));

            var writeEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var allowWrite = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            r.Clipboard.BeforeWrite = () =>
            {
                writeEntered.TrySetResult();
                return allowWrite.Task;
            };

            var receivePacket = Assert.Single(SyncPacketizer.Split(pad.Seal(new SyncItem(Guid.NewGuid(), 100, "pad", "in-flight receive")), pad.Peer.PacketLimit));
            var receiveTask = r.Pc.ReceiveAsync(pad.Peer, receivePacket);
            await writeEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));

            // Enqueue a clipboard change behind the gate, then dispose the coordinator.
            var queuedClipboard = r.Pc.ClipboardChangedAsync(new(2, "queued before dispose", false));
            var disposing = r.Pc.DisposeAsync().AsTask();
            await Task.Delay(50);
            Assert.False(disposing.IsCompleted);

            // Release the receive holding the gate; DisposeAsync must still wait for activeOutgoing.
            allowWrite.SetResult();
            Assert.True(await receiveTask.WaitAsync(TimeSpan.FromSeconds(2)));
            await queuedClipboard.WaitAsync(TimeSpan.FromSeconds(2));
            await Task.Delay(50);
            Assert.False(disposing.IsCompleted);

            releaseSend.Set();
            await disposing.WaitAsync(TimeSpan.FromSeconds(2));

            // Replace with a new pairing/repository in the same root directory and verify old coordinator cannot overwrite it.
            var newPairing = SyncPairing.Create("repaired");
            var freshStore = new SyncRepository(r.Root, newPairing.PcId);
            await r.Pc.ClipboardChangedAsync(new(3, "stale after dispose", false));

            var reloaded = new SyncRepository(r.Root, newPairing.PcId);
            Assert.Empty(reloaded.Pending(r.DeviceId));
            Assert.Empty(reloaded.Devices);
            Assert.Empty(freshStore.Pending(r.DeviceId));
        }
        finally { releaseSend.Set(); }
    }

    [Fact]
    public async Task DisposeAsyncSecondCallerAlsoWaitsForInFlightSender()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);
        var sendEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var releaseSend = new ManualResetEventSlim(false);
        pad.Peer.OnSend = _ =>
        {
            sendEntered.TrySetResult();
            releaseSend.Wait(TimeSpan.FromSeconds(5));
            return Task.CompletedTask;
        };

        try
        {
            await r.Pc.ClipboardChangedAsync(new(1, "in-flight", false));
            await sendEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));

            var firstDispose = r.Pc.DisposeAsync().AsTask();
            var secondDispose = r.Pc.DisposeAsync().AsTask();
            await Task.Delay(50);
            Assert.False(firstDispose.IsCompleted);
            Assert.False(secondDispose.IsCompleted);

            releaseSend.Set();
            await Task.WhenAll(firstDispose, secondDispose).WaitAsync(TimeSpan.FromSeconds(2));
        }
        finally { releaseSend.Set(); }
    }

    [Fact]
    public async Task InFlightAttachmentSurvivesSixtySecondTickForOfferAndFinalChunk()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);
        var data1 = new byte[SyncProtocol.ChunkBytes * 4 + 5];
        data1[0] = 11;
        data1[^1] = 22;
        var data2 = new byte[] { 33, 44 };

        var offerEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var offerRelease = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pad.Peer.OnSend = _ => { offerEntered.TrySetResult(); return offerRelease.Task; };

        try
        {
            await r.Pc.ClipboardChangedAsync(new(1, null, false, [
                new("file", Filename: "one.bin", Data: data1),
                new("file", Filename: "two.bin", Data: data2)
            ]));
            await offerEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));

            // 60-second tick while offer 1 is InFlight must not clear ActiveAttachment or start offer 2.
            await r.Pc.TickAsync(DateTimeOffset.UtcNow.AddSeconds(61)).WaitAsync(TimeSpan.FromSeconds(2));
        }
        finally { offerRelease.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(pad.Peer);

        var offer1 = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        Assert.Equal("one.bin", offer1.Filename);

        await pad.SendAsync(new SyncResume(offer1.Id, 0));
        var initialChunks = pad.Drain().Cast<SyncChunk>().ToArray();
        Assert.Equal(4, initialChunks.Length);
        Assert.All(initialChunks, ch => Assert.Equal(SyncProtocol.ChunkBytes, ch.Data.Length));

        var chunkEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var chunkRelease = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pad.Peer.OnSend = _ => { chunkEntered.TrySetResult(); return chunkRelease.Task; };
        try
        {
            foreach (var packet in SyncPacketizer.Split(pad.Seal(new SyncResume(offer1.Id, SyncProtocol.ChunkBytes * 4)), pad.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(pad.Peer, packet));
            await chunkEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));

            await r.Pc.TickAsync(DateTimeOffset.UtcNow.AddSeconds(61)).WaitAsync(TimeSpan.FromSeconds(2));
        }
        finally { chunkRelease.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(pad.Peer);

        var finalChunk = Assert.IsType<SyncChunk>(Assert.Single(pad.Drain()));
        Assert.Equal(data1[(SyncProtocol.ChunkBytes * 4)..], finalChunk.Data);
        Assert.False(pad.Peer.Rejected);

        await pad.SendAsync(new SyncAck([offer1.Id]));
        var offer2 = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        Assert.Equal("two.bin", offer2.Filename);
        Assert.Equal(1, r.State.Pending);
    }

    [Fact]
    public async Task AttachmentSendCompletionUpdatesSentDeadlineAndExpiryDropsConnectionForCleanReconnect()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);
        var data = new byte[SyncProtocol.ChunkBytes * 4 + 3];
        data[^1] = 77;

        var offerEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var offerRelease = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pad.Peer.OnSend = _ => { offerEntered.TrySetResult(); return offerRelease.Task; };

        try
        {
            await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "timed.bin", Data: data)]));
            await offerEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));
            r.Now = r.Now.AddSeconds(2);
        }
        finally { offerRelease.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        var offer = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));

        // >60s after send start, <60s after send completion: Sent timestamp was refreshed on completion.
        await r.Pc.TickAsync(r.Now.AddSeconds(59.9));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        Assert.False(pad.Peer.Rejected);
        Assert.Empty(pad.Drain());

        // >60s after send completion: attachment timeout drops connection instead of re-offering in the same session.
        await r.Pc.TickAsync(r.Now.AddSeconds(61));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        Assert.True(pad.Peer.Rejected);
        Assert.Empty(pad.Drain());
        Assert.Equal(1, r.State.Pending);

        // Fresh connection cleanly restarts from offer and completes without duplicate-resume errors.
        var fresh = await r.ConnectAsync(512);
        var freshOffer = Assert.IsType<SyncOffer>(Assert.Single(fresh.Drain()));
        Assert.Equal(offer.Id, freshOffer.Id);
        await fresh.SendAsync(new SyncResume(freshOffer.Id, 0));
        var firstWindow = fresh.Drain().Cast<SyncChunk>().ToArray();
        Assert.Equal(4, firstWindow.Length);
        await fresh.SendAsync(new SyncResume(freshOffer.Id, SyncProtocol.ChunkBytes));
        var finalChunk = Assert.IsType<SyncChunk>(Assert.Single(fresh.Drain()));
        Assert.Equal(data[(SyncProtocol.ChunkBytes * 4)..], finalChunk.Data);
        await fresh.SendAsync(new SyncAck([freshOffer.Id]));
        Assert.Equal(0, r.State.Pending);

        // Text item ACK arriving while SendLoopAsync is busy after 60s expiry is still accepted.
        await r.Pc.ClipboardChangedAsync(new(2, "late text ack", false));
        await r.Pc.WaitForOutgoingAsync(fresh.Peer);
        var textItem = Assert.IsType<SyncItem>(Assert.Single(fresh.Drain()));
        var pongEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var pongRelease = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fresh.Peer.OnSend = _ => { pongEntered.TrySetResult(); return pongRelease.Task; };
        try
        {
            foreach (var packet in SyncPacketizer.Split(fresh.Seal(new SyncPing()), fresh.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(fresh.Peer, packet));
            await pongEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));

            await r.Pc.TickAsync(r.Now.AddSeconds(61)).WaitAsync(TimeSpan.FromSeconds(2));
            foreach (var packet in SyncPacketizer.Split(fresh.Seal(new SyncAck([textItem.Id])), fresh.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(fresh.Peer, packet));
        }
        finally { pongRelease.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(fresh.Peer);

        Assert.IsType<SyncPong>(Assert.Single(fresh.Drain()));
        Assert.Equal(0, r.State.Pending);
    }

    [Fact]
    public async Task AttachmentDeletionAndExpiryStartNextAttachmentImmediately()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [
            new("file", Filename: "one.bin", Data: [1, 2]),
            new("file", Filename: "two.bin", Data: [3, 4])
        ]));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);

        var offer1 = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        Assert.Equal("one.bin", offer1.Filename);

        // Deleting item 1 while awaiting resume keeps the connection and immediately offers item 2.
        await r.Pc.DeleteHistoryAsync(offer1.Id);
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        Assert.False(pad.Peer.Rejected);
        var offer2 = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        Assert.Equal("two.bin", offer2.Filename);
        await pad.SendAsync(new SyncAck([offer2.Id]));

        // Expiring an awaiting attachment via 24h TickAsync also advances immediately to the next attachment.
        await r.Pc.DisconnectAsync(pad.Peer);
        var now = DateTimeOffset.UtcNow;
        var expiring = r.Store.Create(new("file", Filename: "expiring.bin", Data: [5]), now.AddHours(-23).AddMinutes(-59).ToUnixTimeMilliseconds(), "PC");
        r.Store.AddAndEnqueue(expiring, now);
        var fresh = r.Store.Create(new("file", Filename: "fresh.bin", Data: [6]), now.ToUnixTimeMilliseconds(), "PC");
        r.Store.AddAndEnqueue(fresh, now);

        pad = await r.ConnectAsync(512);
        var first = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        Assert.Equal("expiring.bin", first.Filename);

        await r.Pc.TickAsync(now.AddMinutes(2));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        Assert.False(pad.Peer.Rejected);
        var next = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        Assert.Equal("fresh.bin", next.Filename);
    }

    [Fact]
    public async Task PeerAuthenticationPruneTrimsOtherConnectionsAndStartsNextAttachment()
    {
        var r = new Rig();
        var phoneId = Guid.NewGuid();
        r.Store.Register(phoneId, "phone", DateTimeOffset.UtcNow);
        var pad = await r.ConnectAsync(512);
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [
            new("file", Filename: "missing.bin", Data: [10, 20]),
            new("file", Filename: "next.bin", Data: [30, 40])
        ]));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);

        var offer1 = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        Assert.Equal("missing.bin", offer1.Filename);

        var missingItem = r.Store.Pending(r.DeviceId).First(i => i.Id == offer1.Id);
        File.Delete(missingItem.Path!);

        // Without calling TickAsync, authenticating another device prunes the missing body and trims pad's queue.
        var phone = await r.ConnectAsync(512, deviceId: phoneId);
        await r.Pc.WaitForOutgoingAsync(pad.Peer);

        Assert.False(pad.Peer.Rejected);
        var offer2 = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        Assert.Equal("next.bin", offer2.Filename);
        Assert.Equal("next.bin", Assert.IsType<SyncOffer>(Assert.Single(phone.Drain())).Filename);
    }

    [Fact]
    public async Task IncomingMultiPacketProgressExtendsReplyDeadlineWhileStalledAssemblyStillDrops()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);

        // 1. An already-in-progress multi-packet frame (>64 bytes) when an item is sent extends until that frame completes.
        var largeText = new SyncItem(Guid.NewGuid(), 100, "pad", new string('p', 2000));
        var packets = SyncPacketizer.Split(pad.Seal(largeText), 200);
        Assert.True(packets.Count >= 5);
        Assert.True(await r.Pc.ReceiveAsync(pad.Peer, packets[0]));

        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "out.bin", Data: [1, 2, 3])]));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        var offer = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));

        for (var i = 1; i < packets.Count - 1; i++)
        {
            r.Now = r.Now.AddSeconds(8);
            await r.Pc.TickAsync(r.Now);
            Assert.False(pad.Peer.Rejected);
            Assert.True(await r.Pc.ReceiveAsync(pad.Peer, packets[i]));
        }
        r.Now = r.Now.AddSeconds(8);
        await r.Pc.TickAsync(r.Now);
        Assert.False(pad.Peer.Rejected);
        Assert.True(await r.Pc.ReceiveAsync(pad.Peer, packets[^1]));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        Assert.Equal(largeText.Id, Assert.Single(Assert.IsType<SyncAck>(Assert.Single(pad.Drain())).Ids));

        // A SECOND large frame started later while still awaiting reply ALSO extends until it completes,
        // and drops 60s after the last large frame completes if still unacked.
        var secondFramePackets = SyncPacketizer.Split(pad.Seal(new SyncItem(Guid.NewGuid(), 101, "pad", new string('q', 1000))), 200);
        Assert.True(secondFramePackets.Count >= 5);
        r.Now = r.Now.AddSeconds(20);
        Assert.True(await r.Pc.ReceiveAsync(pad.Peer, secondFramePackets[0]));
        await r.Pc.TickAsync(r.Now);
        Assert.False(pad.Peer.Rejected);
        for (var i = 1; i < secondFramePackets.Count; i++)
        {
            r.Now = r.Now.AddSeconds(8);
            Assert.True(await r.Pc.ReceiveAsync(pad.Peer, secondFramePackets[i]));
            await r.Pc.TickAsync(r.Now);
            Assert.False(pad.Peer.Rejected);
        }
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        pad.Drain();
        // 59s after the second frame completes: still alive; 61s after completion: drops.
        r.Now = r.Now.AddSeconds(59);
        await r.Pc.TickAsync(r.Now);
        Assert.False(pad.Peer.Rejected);
        r.Now = r.Now.AddSeconds(2);
        await r.Pc.TickAsync(r.Now);
        Assert.True(pad.Peer.Rejected);
        Assert.Equal(1, r.State.Pending);

        // Clean up offer1 via fresh connection.
        var ackConn = await r.ConnectAsync(512);
        var reoffered = Assert.IsType<SyncOffer>(Assert.Single(ackConn.Drain()));
        await ackConn.SendAsync(new SyncAck([reoffered.Id]));
        Assert.Equal(0, r.State.Pending);
        await r.Pc.DisconnectAsync(ackConn.Peer);

        // 2. Total extension for a single in-progress frame is capped at +3 minutes beyond the initial 60s deadline (240s total).
        var capped = await r.ConnectAsync(512);
        var longPackets = SyncPacketizer.Split(capped.Seal(new SyncItem(Guid.NewGuid(), 102, "pad", new string('c', 5000))), 200);
        Assert.True(longPackets.Count >= 22);
        Assert.True(await r.Pc.ReceiveAsync(capped.Peer, longPackets[0]));
        await r.Pc.ClipboardChangedAsync(new(2, null, false, [new("file", Filename: "cap.bin", Data: [4, 5])]));
        await r.Pc.WaitForOutgoingAsync(capped.Peer);
        capped.Drain();

        var sentAt = r.Now;
        var nextIndex = 1;
        while ((r.Now - sentAt).TotalSeconds < 225 && nextIndex < longPackets.Count - 1)
        {
            r.Now = r.Now.AddSeconds(15);
            await r.Pc.TickAsync(r.Now);
            Assert.False(capped.Peer.Rejected);
            Assert.True(await r.Pc.ReceiveAsync(capped.Peer, longPackets[nextIndex++]));
        }
        // At +239s (1s before 60s + 180s cap), connection is still alive; at +241s it drops even if packets kept arriving.
        r.Now = sentAt.AddSeconds(239);
        await r.Pc.TickAsync(r.Now);
        Assert.False(capped.Peer.Rejected);
        Assert.True(await r.Pc.ReceiveAsync(capped.Peer, longPackets[nextIndex++]));
        r.Now = sentAt.AddSeconds(241);
        await r.Pc.TickAsync(r.Now);
        Assert.True(capped.Peer.Rejected);

        // 3. A large frame started AFTER the offer was sent ALSO extends the 60s reply deadline.
        var afterSend = await r.ConnectAsync(512);
        var afterOffer = Assert.IsType<SyncOffer>(Assert.Single(afterSend.Drain()));
        var lateItem = new SyncItem(Guid.NewGuid(), 103, "pad", new string('r', 1200));
        var latePackets = SyncPacketizer.Split(afterSend.Seal(lateItem), 200);
        Assert.True(latePackets.Count >= 5);
        r.Now = r.Now.AddSeconds(50);
        Assert.True(await r.Pc.ReceiveAsync(afterSend.Peer, latePackets[0]));
        r.Now = r.Now.AddSeconds(11); // +61s since offer was sent, while latePackets is still arriving.
        await r.Pc.TickAsync(r.Now);
        Assert.False(afterSend.Peer.Rejected);
        for (var i = 1; i < latePackets.Count; i++)
        {
            r.Now = r.Now.AddSeconds(15);
            Assert.True(await r.Pc.ReceiveAsync(afterSend.Peer, latePackets[i]));
            await r.Pc.TickAsync(r.Now);
            Assert.False(afterSend.Peer.Rejected);
        }
        await r.Pc.WaitForOutgoingAsync(afterSend.Peer);
        Assert.Equal(lateItem.Id, Assert.Single(Assert.IsType<SyncAck>(Assert.Single(afterSend.Drain())).Ids));
        await afterSend.SendAsync(new SyncAck([afterOffer.Id]));
        Assert.Equal(0, r.State.Pending);
        await r.Pc.DisconnectAsync(afterSend.Peer);

        // 4. Multi-packet SyncPing at 20-byte packet limit (39-byte frame = 3 packets) already in progress does NOT extend.
        var pingPad = await r.ConnectAsync(20);
        var pingPackets = SyncPacketizer.Split(pingPad.Seal(new SyncPing()), 20);
        Assert.Equal(3, pingPackets.Count);
        Assert.True(await r.Pc.ReceiveAsync(pingPad.Peer, pingPackets[0]));
        Assert.True(await r.Pc.ReceiveAsync(pingPad.Peer, pingPackets[1]));

        await r.Pc.ClipboardChangedAsync(new(3, null, false, [new("file", Filename: "ping.bin", Data: [6, 7])]));
        await r.Pc.WaitForOutgoingAsync(pingPad.Peer);
        pingPad.Drain();

        r.Now = r.Now.AddSeconds(50);
        Assert.True(await r.Pc.ReceiveAsync(pingPad.Peer, pingPackets[2]));
        await r.Pc.WaitForOutgoingAsync(pingPad.Peer);
        Assert.IsType<SyncPong>(Assert.Single(pingPad.Drain()));
        r.Now = r.Now.AddSeconds(15);
        await r.Pc.TickAsync(r.Now);
        Assert.True(pingPad.Peer.Rejected);

        // 5. Stalled partial frame drops at the 20s assembly timeout.
        var stalled = await r.ConnectAsync(512);
        stalled.Drain();
        var stallPackets = SyncPacketizer.Split(stalled.Seal(new SyncItem(Guid.NewGuid(), 104, "pad", new string('s', 1000))), 200);
        Assert.True(await r.Pc.ReceiveAsync(stalled.Peer, stallPackets[0]));
        r.Now = r.Now.AddSeconds(21);
        await r.Pc.TickAsync(r.Now);
        Assert.True(stalled.Peer.Rejected);
    }

    [Fact]
    public async Task DuplicateUnseenOfferInSameConnectionDisconnectsWithoutSecondResume()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);
        var data = new byte[SyncProtocol.ChunkBytes + 5];
        var offer = new SyncOffer(Guid.NewGuid(), 100, "pad", "file", data.Length,
            Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(data)),
            Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("dup.bin")), "public.data");

        await pad.SendAsync(offer);
        Assert.Equal(new SyncResume(offer.Id, 0), Assert.Single(pad.Drain()));

        // Re-sending the same unseen offer on the same connection is rejected as invalid state.
        var duplicateFrame = pad.Seal(offer);
        var ok = true;
        foreach (var packet in SyncPacketizer.Split(duplicateFrame, pad.Peer.PacketLimit))
            ok = await r.Pc.ReceiveAsync(pad.Peer, packet);
        Assert.False(ok);
        Assert.True(pad.Peer.Rejected);
        Assert.Empty(pad.Drain());

        // Reconnecting allows the offer to resume cleanly.
        pad = await r.ConnectAsync(512);
        await pad.SendAsync(offer);
        Assert.Equal(new SyncResume(offer.Id, 0), Assert.Single(pad.Drain()));
    }

    [Fact]
    public async Task CoordinatorBatchesMoreThanSixtyFourAcksAndSplitsAtMaxAckIds()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pad.Peer.OnSend = _ => { entered.TrySetResult(); return release.Task; };

        var itemIds = new List<Guid>();
        try
        {
            await r.Pc.ClipboardChangedAsync(new(1, "block outgoing", false));
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));

            for (var i = 0; i < 80; i++)
            {
                var item = new SyncItem(Guid.NewGuid(), i, "pad", $"msg-{i}");
                itemIds.Add(item.Id);
                foreach (var packet in SyncPacketizer.Split(pad.Seal(item), pad.Peer.PacketLimit))
                    Assert.True(await r.Pc.ReceiveAsync(pad.Peer, packet));
            }
            Assert.False(pad.Peer.Rejected);
        }
        finally { release.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(pad.Peer);

        var messages = pad.Drain();
        Assert.Equal(2, messages.Length);
        var outgoing1 = Assert.IsType<SyncItem>(messages[0]);
        var ack = Assert.IsType<SyncAck>(messages[1]);
        Assert.Equal(itemIds, ack.Ids);
        Assert.Equal(80, r.Clipboard.Writes.Count);
        await pad.SendAsync(new SyncAck([outgoing1.Id]));

        // Verify batching splits at SyncProtocol.MaxAckIds (1024) when 1025 items arrive while busy.
        var entered2 = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release2 = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pad.Peer.OnSend = _ => { entered2.TrySetResult(); return release2.Task; };
        var seenBatchIds = new List<Guid>();
        try
        {
            await r.Pc.ClipboardChangedAsync(new(2, "block outgoing 2", false));
            await entered2.Task.WaitAsync(TimeSpan.FromSeconds(2));
            for (var i = 0; i < SyncProtocol.MaxAckIds + 1; i++)
            {
                var seenId = i < 80 ? itemIds[i] : Guid.NewGuid();
                SyncMessage msg = i < 80
                    ? new SyncItem(seenId, i, "pad", $"msg-{i}")
                    : new SyncItem(seenId, i, "pad", $"extra-{i}");
                seenBatchIds.Add(seenId);
                foreach (var packet in SyncPacketizer.Split(pad.Seal(msg), pad.Peer.PacketLimit))
                    Assert.True(await r.Pc.ReceiveAsync(pad.Peer, packet));
            }
        }
        finally { release2.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(pad.Peer);

        var batchMessages = pad.Drain();
        Assert.Equal(3, batchMessages.Length);
        Assert.IsType<SyncItem>(batchMessages[0]);
        var ack1 = Assert.IsType<SyncAck>(batchMessages[1]);
        var ack2 = Assert.IsType<SyncAck>(batchMessages[2]);
        Assert.Equal(SyncProtocol.MaxAckIds, ack1.Ids.Count);
        Assert.Single(ack2.Ids);
        Assert.Equal(seenBatchIds, ack1.Ids.Concat(ack2.Ids).ToList());
    }

    [Fact]
    public async Task AttachmentAckBeforeFinalChunkCompletesDropsConnectionAndPreservesPending()
    {
        var r = new Rig();
        var data = new byte[SyncProtocol.ChunkBytes * 4 + 9];
        data[^1] = 99;
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "twochunks.bin", Data: data)]));

        // 1. Ack immediately after offer (no resume yet) is accepted for already-seen receiver optimization.
        var seenPad = await r.ConnectAsync(512);
        var seenOffer = Assert.IsType<SyncOffer>(Assert.Single(seenPad.Drain()));
        await seenPad.SendAsync(new SyncAck([seenOffer.Id]));
        Assert.Equal(0, r.State.Pending);
        await r.Pc.DisconnectAsync(seenPad.Peer);

        // 2. Reject ack after resume before first chunk finishes sending.
        await r.Pc.ClipboardChangedAsync(new(2, null, false, [new("file", Filename: "twochunks2.bin", Data: data)]));
        var pad = await r.ConnectAsync(512);
        var offer = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        var chunk1Entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var chunk1Release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pad.Peer.OnSend = _ => { chunk1Entered.TrySetResult(); return chunk1Release.Task; };
        var ok = true;
        try
        {
            foreach (var packet in SyncPacketizer.Split(pad.Seal(new SyncResume(offer.Id, 0)), pad.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(pad.Peer, packet));
            await chunk1Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
            foreach (var packet in SyncPacketizer.Split(pad.Seal(new SyncAck([offer.Id])), pad.Peer.PacketLimit))
                ok = await r.Pc.ReceiveAsync(pad.Peer, packet);
            Assert.False(ok);
            Assert.True(pad.Peer.Rejected);
            Assert.Equal(1, r.State.Pending);
        }
        finally { chunk1Release.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(pad.Peer);

        // 3. Reject ack immediately after initial non-final window completes.
        var padNonFinal = await r.ConnectAsync(512);
        var offerNonFinal = Assert.IsType<SyncOffer>(Assert.Single(padNonFinal.Drain()));
        await padNonFinal.SendAsync(new SyncResume(offerNonFinal.Id, 0));
        var nonFinalChunks = padNonFinal.Drain().Cast<SyncChunk>().ToArray();
        Assert.Equal(4, nonFinalChunks.Length);
        Assert.All(nonFinalChunks, ch => Assert.Equal(SyncProtocol.ChunkBytes, ch.Data.Length));
        ok = true;
        foreach (var packet in SyncPacketizer.Split(padNonFinal.Seal(new SyncAck([offerNonFinal.Id])), padNonFinal.Peer.PacketLimit))
            ok = await r.Pc.ReceiveAsync(padNonFinal.Peer, packet);
        Assert.False(ok);
        Assert.True(padNonFinal.Peer.Rejected);
        Assert.Equal(1, r.State.Pending);

        // 4. Reject ack while final chunk is mid-transmission (before its final packet is handed off).
        var pad3 = await r.ConnectAsync(20);
        var offerAgain = Assert.IsType<SyncOffer>(Assert.Single(pad3.Drain()));
        await pad3.SendAsync(new SyncResume(offerAgain.Id, 0));
        Assert.Equal(4, pad3.Drain().Length);
        var firstPacketSent = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var allowSecondPacket = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var packetCount = 0;
        pad3.Peer.OnSend = _ =>
        {
            if (Interlocked.Increment(ref packetCount) == 1)
            {
                firstPacketSent.SetResult();
                return allowSecondPacket.Task;
            }
            return Task.CompletedTask;
        };
        try
        {
            foreach (var packet in SyncPacketizer.Split(pad3.Seal(new SyncResume(offerAgain.Id, SyncProtocol.ChunkBytes)), pad3.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(pad3.Peer, packet));
            await firstPacketSent.Task.WaitAsync(TimeSpan.FromSeconds(2));
            foreach (var packet in SyncPacketizer.Split(pad3.Seal(new SyncAck([offerAgain.Id])), pad3.Peer.PacketLimit))
                ok = await r.Pc.ReceiveAsync(pad3.Peer, packet);
            Assert.False(ok);
            Assert.True(pad3.Peer.Rejected);
            Assert.Equal(1, r.State.Pending);
        }
        finally { allowSecondPacket.TrySetResult(); }

        // 5. Reconnect, complete final chunk, and ack succeeds.
        var pad4 = await r.ConnectAsync(512);
        Assert.IsType<SyncOffer>(Assert.Single(pad4.Drain()));
        await pad4.SendAsync(new SyncResume(offerAgain.Id, 0));
        Assert.Equal(4, pad4.Drain().Length);
        await pad4.SendAsync(new SyncResume(offerAgain.Id, SyncProtocol.ChunkBytes));
        Assert.IsType<SyncChunk>(Assert.Single(pad4.Drain()));
        await pad4.SendAsync(new SyncAck([offerAgain.Id]));
        Assert.Equal(0, r.State.Pending);
    }

    [Fact]
    public async Task PruneClearsStaleReceiveProgressWhenIncomingPartialExpires()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);
        var data = new byte[100];
        var offer = new SyncOffer(Guid.NewGuid(), r.Now.ToUnixTimeMilliseconds(), "pad", "file", data.Length,
            Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(data)),
            Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("expiring.bin")), "public.data");
        await pad.SendAsync(offer);
        Assert.Equal(new SyncResume(offer.Id, 0), Assert.Single(pad.Drain()));

        var status = await r.Pc.GetStatusAsync();
        Assert.Contains(status.Transfers!, t => t.Direction == "receive" && t.ItemId == offer.Id);

        r.Now = r.Now.AddHours(25);
        await r.Pc.TickAsync(r.Now);
        status = await r.Pc.GetStatusAsync();
        Assert.Empty(status.Transfers!);
    }

    [Fact]
    public async Task SimultaneousSendAfterReconnectExtendsDeadlineUntilLargeIncomingFrameCompletes()
    {
        var r = new Rig();
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "queued.bin", Data: [1, 2, 3, 4])]));

        // Reconnect: PC sends queued offer immediately after AUTH before receiving any packets from pad.
        var pad = await r.ConnectAsync(512);
        var offer = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));

        // Pad sends small SyncDevice (<=64B) followed by a large incoming item taking >60s.
        await pad.SendAsync(new SyncDevice("pad"));
        var incoming = new SyncItem(Guid.NewGuid(), 200, "pad", new string('s', 2000));
        var packets = SyncPacketizer.Split(pad.Seal(incoming), 200);
        Assert.True(packets.Count >= 6);

        for (var i = 0; i < packets.Count; i++)
        {
            r.Now = r.Now.AddSeconds(15);
            Assert.True(await r.Pc.ReceiveAsync(pad.Peer, packets[i]));
            await r.Pc.TickAsync(r.Now);
            Assert.False(pad.Peer.Rejected);
        }
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        Assert.Equal(incoming.Id, Assert.Single(Assert.IsType<SyncAck>(Assert.Single(pad.Drain())).Ids));

        await pad.SendAsync(new SyncAck([offer.Id]));
        Assert.Equal(0, r.State.Pending);
    }

    [Fact]
    public async Task LargeIncomingFrameStartedAfterSendExtendsAndSupportsConsecutiveLargeFrames()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "after.bin", Data: [9, 8])]));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        var offer = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));

        // Wait 40s, receive a single-packet large frame (>64B), verify survival past 60s,
        // then start two consecutive multi-packet large frames before ACKing.
        r.Now = r.Now.AddSeconds(40);
        await pad.SendAsync(new SyncItem(Guid.NewGuid(), 200, "pad", new string('s', 100)));
        r.Now = r.Now.AddSeconds(25); // +65s since offer sent.
        await r.Pc.TickAsync(r.Now);
        Assert.False(pad.Peer.Rejected);

        var item1 = new SyncItem(Guid.NewGuid(), 201, "pad", new string('a', 1200));
        var packets1 = SyncPacketizer.Split(pad.Seal(item1), 200);
        foreach (var packet in packets1)
        {
            r.Now = r.Now.AddSeconds(10);
            Assert.True(await r.Pc.ReceiveAsync(pad.Peer, packet));
            await r.Pc.TickAsync(r.Now);
            Assert.False(pad.Peer.Rejected);
        }
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        pad.Drain();

        var item2 = new SyncItem(Guid.NewGuid(), 202, "pad", new string('b', 1200));
        var packets2 = SyncPacketizer.Split(pad.Seal(item2), 200);
        foreach (var packet in packets2)
        {
            r.Now = r.Now.AddSeconds(10);
            Assert.True(await r.Pc.ReceiveAsync(pad.Peer, packet));
            await r.Pc.TickAsync(r.Now);
            Assert.False(pad.Peer.Rejected);
        }
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        pad.Drain();

        await pad.SendAsync(new SyncAck([offer.Id]));
        Assert.Equal(0, r.State.Pending);
    }

    [Fact]
    public async Task SmallFramesAndPingPongDoNotExtendAndPaddedPingRevertsOnlyOwnExtension()
    {
        var r = new Rig();

        // 1. Small frames (device, ping, pong <=64B) never extend past 60s.
        var pad1 = await r.ConnectAsync(512);
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "ping-only.bin", Data: [1])]));
        await r.Pc.WaitForOutgoingAsync(pad1.Peer);
        pad1.Drain();

        r.Now = r.Now.AddSeconds(20);
        await pad1.SendAsync(new SyncDevice("pad"));
        r.Now = r.Now.AddSeconds(20);
        await pad1.SendAsync(new SyncPing());
        pad1.Drain();
        r.Now = r.Now.AddSeconds(15);
        await pad1.SendAsync(new SyncPong());
        r.Now = r.Now.AddSeconds(6); // +61s since offer sent.
        await r.Pc.TickAsync(r.Now);
        Assert.True(pad1.Peer.Rejected);

        // 2. Padded >64B multi-packet ping reverts ONLY its own provisional extension and preserves an earlier real extension.
        var pad2 = await r.ConnectAsync(512);
        var offer = Assert.IsType<SyncOffer>(Assert.Single(pad2.Drain()));
        var realItem = new SyncItem(Guid.NewGuid(), 203, "pad", new string('x', 1200));
        var realPackets = SyncPacketizer.Split(pad2.Seal(realItem), 200);
        r.Now = r.Now.AddSeconds(20);
        foreach (var packet in realPackets)
        {
            r.Now = r.Now.AddSeconds(5);
            Assert.True(await r.Pc.ReceiveAsync(pad2.Peer, packet));
        }
        await r.Pc.WaitForOutgoingAsync(pad2.Peer);
        pad2.Drain();
        var realCompletedAt = r.Now; // Deadline should now be realCompletedAt + 60s.

        var paddedPingHeader = System.Text.Encoding.ASCII.GetBytes("{\"t\":\"ping\"" + new string(' ', 150) + "}");
        var paddedPingPlaintext = new byte[2 + paddedPingHeader.Length];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt16BigEndian(paddedPingPlaintext, (ushort)paddedPingHeader.Length);
        paddedPingHeader.CopyTo(paddedPingPlaintext, 2);
        var pingPackets = SyncPacketizer.Split(pad2.SealRawPlaintext(paddedPingPlaintext), 100);
        Assert.True(pingPackets.Count >= 2);

        r.Now = realCompletedAt.AddSeconds(20);
        Assert.True(await r.Pc.ReceiveAsync(pad2.Peer, pingPackets[0]));
        r.Now = realCompletedAt.AddSeconds(35);
        foreach (var packet in pingPackets.Skip(1))
            Assert.True(await r.Pc.ReceiveAsync(pad2.Peer, packet));
        await r.Pc.WaitForOutgoingAsync(pad2.Peer);
        Assert.IsType<SyncPong>(Assert.Single(pad2.Drain()));

        // Earlier extension up to realCompletedAt + 60s must remain intact, while padded ping's +35s extension is reverted.
        r.Now = realCompletedAt.AddSeconds(59);
        await r.Pc.TickAsync(r.Now);
        Assert.False(pad2.Peer.Rejected);
        r.Now = realCompletedAt.AddSeconds(61);
        await r.Pc.TickAsync(r.Now);
        Assert.True(pad2.Peer.Rejected);

        // 3. Padded >64B multi-packet ping with no prior extension reverts to initial 60s deadline.
        var pad3 = await r.ConnectAsync(512);
        var offer3 = Assert.IsType<SyncOffer>(Assert.Single(pad3.Drain()));
        var paddedPingHeader3 = System.Text.Encoding.ASCII.GetBytes("{\"t\":\"ping\"" + new string(' ', 150) + "}");
        var paddedPingPlaintext3 = new byte[2 + paddedPingHeader3.Length];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt16BigEndian(paddedPingPlaintext3, (ushort)paddedPingHeader3.Length);
        paddedPingHeader3.CopyTo(paddedPingPlaintext3, 2);
        var pingPackets3 = SyncPacketizer.Split(pad3.SealRawPlaintext(paddedPingPlaintext3), 100);
        r.Now = r.Now.AddSeconds(20);
        Assert.True(await r.Pc.ReceiveAsync(pad3.Peer, pingPackets3[0]));
        r.Now = r.Now.AddSeconds(20);
        foreach (var packet in pingPackets3.Skip(1))
            Assert.True(await r.Pc.ReceiveAsync(pad3.Peer, packet));
        await r.Pc.WaitForOutgoingAsync(pad3.Peer);
        Assert.IsType<SyncPong>(Assert.Single(pad3.Drain()));
        r.Now = r.Now.AddSeconds(21); // +61s since offer3 sent.
        await r.Pc.TickAsync(r.Now);
        Assert.True(pad3.Peer.Rejected);

        var ackPad = await r.ConnectAsync(512);
        var reoffered = Assert.IsType<SyncOffer>(Assert.Single(ackPad.Drain()));
        Assert.Equal(offer3.Id, reoffered.Id);
        await ackPad.SendAsync(new SyncAck([offer3.Id]));
        Assert.Equal(0, r.State.Pending);
        await r.Pc.DisconnectAsync(ackPad.Peer);
    }

    [Fact]
    public async Task ExtensionCapStopsAtThreeMinutesAcrossMultiplePostSendLargeFrames()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "cap-multi.bin", Data: [7])]));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        pad.Drain();
        var sentAt = r.Now;

        r.Now = sentAt.AddSeconds(10);
        var frames = Enumerable.Range(0, 4).Select(i =>
            SyncPacketizer.Split(pad.Seal(new SyncItem(Guid.NewGuid(), 300 + i, "pad", new string((char)('a' + i), 1500))), 200)).ToArray();

        var frameIndex = 0;
        var packetIndex = 0;
        while ((r.Now - sentAt).TotalSeconds < 225)
        {
            Assert.True(await r.Pc.ReceiveAsync(pad.Peer, frames[frameIndex][packetIndex]));
            packetIndex++;
            if (packetIndex == frames[frameIndex].Count)
            {
                await r.Pc.WaitForOutgoingAsync(pad.Peer);
                pad.Drain();
                frameIndex++;
                packetIndex = 0;
            }
            r.Now = r.Now.AddSeconds(12);
            await r.Pc.TickAsync(r.Now);
            Assert.False(pad.Peer.Rejected);
        }

        r.Now = sentAt.AddSeconds(239);
        await r.Pc.TickAsync(r.Now);
        Assert.False(pad.Peer.Rejected);
        Assert.True(await r.Pc.ReceiveAsync(pad.Peer, frames[frameIndex][packetIndex]));
        r.Now = sentAt.AddSeconds(241);
        await r.Pc.TickAsync(r.Now);
        Assert.True(pad.Peer.Rejected);
    }

    [Fact]
    public async Task PipelinedChunksSlideWindowRejectInvalidResumesAndLogThroughputWithoutSecrets()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);
        var data = Enumerable.Range(0, SyncProtocol.ChunkBytes * 6 + 17).Select(i => (byte)(i * 7 + 3)).ToArray();
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "secret-send.bin", Data: data)]));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        var offer = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        Assert.Equal([true], pad.Peer.HighThroughputHistory);

        // Window size = 4 chunks (128 KiB).
        await pad.SendAsync(new SyncResume(offer.Id, 0));
        var firstWindow = pad.Drain().Cast<SyncChunk>().ToArray();
        Assert.Equal(4, firstWindow.Length);
        Assert.Equal(new[] { 0, SyncProtocol.ChunkBytes, SyncProtocol.ChunkBytes * 2, SyncProtocol.ChunkBytes * 3 }, firstWindow.Select(c => c.Offset).ToArray());

        // Sliding by 1 chunk releases chunk 4; coalesced resume releases chunks 5 and 6.
        r.Now = r.Now.AddSeconds(1);
        await pad.SendAsync(new SyncResume(offer.Id, SyncProtocol.ChunkBytes));
        var chunk4 = Assert.IsType<SyncChunk>(Assert.Single(pad.Drain()));
        Assert.Equal(SyncProtocol.ChunkBytes * 4, chunk4.Offset);

        r.Now = r.Now.AddSeconds(1);
        await pad.SendAsync(new SyncResume(offer.Id, SyncProtocol.ChunkBytes * 4));
        var tail = pad.Drain().Cast<SyncChunk>().ToArray();
        Assert.Equal(2, tail.Length);
        Assert.Equal(SyncProtocol.ChunkBytes * 5, tail[0].Offset);
        Assert.Equal(SyncProtocol.ChunkBytes * 6, tail[1].Offset);
        Assert.Equal(17, tail[1].Data.Length);

        r.Now = r.Now.AddSeconds(1);
        await pad.SendAsync(new SyncAck([offer.Id]));
        Assert.Equal(0, r.State.Pending);
        Assert.Contains(r.Logs, l => l.Contains($"attachment sent bytes={data.Length}") && l.Contains("elapsedMs=") && l.Contains("speedKBps="));

        // High throughput disables after 5s idle grace.
        r.Now = r.Now.AddSeconds(6);
        await r.Pc.TickAsync(r.Now);
        Assert.Equal([true, false], pad.Peer.HighThroughputHistory);

        // Pipelined receive without waiting between chunks.
        var rxData = Enumerable.Range(0, SyncProtocol.ChunkBytes * 5 + 11).Select(i => (byte)(i * 11 + 5)).ToArray();
        var rxOffer = new SyncOffer(Guid.NewGuid(), r.Now.ToUnixTimeMilliseconds(), "pad", "file", rxData.Length,
            Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(rxData)),
            Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("secret-recv.bin")), "public.data");
        await pad.SendAsync(rxOffer);
        Assert.Equal(new SyncResume(rxOffer.Id, 0), Assert.Single(pad.Drain()));
        Assert.Equal([true, false, true], pad.Peer.HighThroughputHistory);

        r.Now = r.Now.AddSeconds(2);
        for (var offset = 0; offset < rxData.Length; offset += SyncProtocol.ChunkBytes)
        {
            var count = Math.Min(SyncProtocol.ChunkBytes, rxData.Length - offset);
            foreach (var packet in SyncPacketizer.Split(pad.Seal(new SyncChunk(rxOffer.Id, offset, rxData[offset..(offset + count)])), pad.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(pad.Peer, packet));
        }
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        var rxReplies = pad.Drain();
        Assert.Equal(5, rxReplies.OfType<SyncResume>().Count());
        Assert.Equal(rxOffer.Id, Assert.Single(Assert.IsType<SyncAck>(rxReplies[^1]).Ids));
        var saved = Assert.Single(await r.Pc.GetHistoryAsync("secret-recv"));
        Assert.Equal(rxData, File.ReadAllBytes(saved.Path!));
        Assert.Contains(r.Logs, l => l.Contains($"attachment received bytes={rxData.Length}") && l.Contains("elapsedMs=") && l.Contains("speedKBps="));
        Assert.DoesNotContain(r.Logs, l => l.Contains("secret-send") || l.Contains("secret-recv") || l.Contains(rxOffer.Sha256));

        // Rollback or non-boundary resume in-window is rejected as invalid state.
        await r.Pc.ClipboardChangedAsync(new(2, null, false, [new("file", Filename: "bad-resume.bin", Data: new byte[SyncProtocol.ChunkBytes * 2 + 1])]));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        var badOffer = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        await pad.SendAsync(new SyncResume(badOffer.Id, 0));
        pad.Drain();
        var ok = true;
        foreach (var packet in SyncPacketizer.Split(pad.Seal(new SyncResume(badOffer.Id, 123)), pad.Peer.PacketLimit))
            ok = await r.Pc.ReceiveAsync(pad.Peer, packet);
        Assert.False(ok);
        Assert.True(pad.Peer.Rejected);
    }

    [Fact]
    public async Task CompatibleWithOldStopAndWaitPeerInBothDirections()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);

        // Old stop-and-wait sender -> new receiver gets resume after every chunk.
        var rxData = Enumerable.Range(0, SyncProtocol.ChunkBytes * 2 + 7).Select(i => (byte)i).ToArray();
        var rxOffer = new SyncOffer(Guid.NewGuid(), r.Now.ToUnixTimeMilliseconds(), "pad", "file", rxData.Length,
            Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(rxData)),
            Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("old-sender.bin")), "public.data");
        await pad.SendAsync(rxOffer);
        Assert.Equal(new SyncResume(rxOffer.Id, 0), Assert.Single(pad.Drain()));
        await pad.SendAsync(new SyncChunk(rxOffer.Id, 0, rxData[..SyncProtocol.ChunkBytes]));
        Assert.Equal(new SyncResume(rxOffer.Id, SyncProtocol.ChunkBytes), Assert.Single(pad.Drain()));
        await pad.SendAsync(new SyncChunk(rxOffer.Id, SyncProtocol.ChunkBytes, rxData[SyncProtocol.ChunkBytes..(SyncProtocol.ChunkBytes * 2)]));
        Assert.Equal(new SyncResume(rxOffer.Id, SyncProtocol.ChunkBytes * 2), Assert.Single(pad.Drain()));
        await pad.SendAsync(new SyncChunk(rxOffer.Id, SyncProtocol.ChunkBytes * 2, rxData[(SyncProtocol.ChunkBytes * 2)..]));
        Assert.Equal(rxOffer.Id, Assert.Single(Assert.IsType<SyncAck>(Assert.Single(pad.Drain())).Ids));

        // New sender -> old receiver sending resume for every single chunk completes without error.
        var txData = Enumerable.Range(0, SyncProtocol.ChunkBytes * 5 + 3).Select(i => (byte)(i * 3)).ToArray();
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "to-old.bin", Data: txData)]));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        var txOffer = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));
        var received = new List<byte>();
        await pad.SendAsync(new SyncResume(txOffer.Id, 0));
        while (received.Count < txData.Length)
        {
            var chunks = pad.Drain().Cast<SyncChunk>().ToArray();
            Assert.NotEmpty(chunks);
            foreach (var ch in chunks)
            {
                Assert.Equal(received.Count, ch.Offset);
                received.AddRange(ch.Data);
                if (received.Count < txData.Length)
                    await pad.SendAsync(new SyncResume(txOffer.Id, received.Count));
            }
        }
        Assert.Equal(txData, received.ToArray());
        await pad.SendAsync(new SyncAck([txOffer.Id]));
        Assert.Equal(0, r.State.Pending);
    }

    [Fact]
    public async Task PipelinedResumePreservesConfirmedExtensionAndEnforcesPerChunkCap()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);
        var data = new byte[SyncProtocol.ChunkBytes * 4 + 100];
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "ext-win.bin", Data: data)]));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        var offer = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));

        // Send all 4 initial chunks around t=1s.
        r.Now = r.Now.AddSeconds(1);
        var windowSentAt = r.Now;
        await pad.SendAsync(new SyncResume(offer.Id, 0));
        Assert.Equal(4, pad.Drain().Cast<SyncChunk>().Count());

        // Receive large incoming frame slowly until t=90s -> confirmed deadline extends to 150s.
        var largePackets = SyncPacketizer.Split(pad.Seal(new SyncItem(Guid.NewGuid(), 100, "pad", new string('e', 2000))), 200);
        Assert.True(largePackets.Count >= 6);
        for (var i = 0; i < largePackets.Count; i++)
        {
            r.Now = windowSentAt.AddSeconds((i + 1) * 89.0 / largePackets.Count);
            Assert.True(await r.Pc.ReceiveAsync(pad.Peer, largePackets[i]));
            await r.Pc.TickAsync(r.Now);
            Assert.False(pad.Peer.Rejected);
        }
        r.Now = windowSentAt.AddSeconds(89); // t=90s relative to offer.
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        pad.Drain();

        // At t=91s relative to windowSentAt, resume chunk 0 -> chunk 1 becomes front and keeps extended deadline.
        r.Now = windowSentAt.AddSeconds(90);
        await pad.SendAsync(new SyncResume(offer.Id, SyncProtocol.ChunkBytes));
        Assert.IsType<SyncChunk>(Assert.Single(pad.Drain()));

        r.Now = windowSentAt.AddSeconds(91);
        await r.Pc.TickAsync(r.Now);
        Assert.False(pad.Peer.Rejected);

        r.Now = windowSentAt.AddSeconds(148);
        await r.Pc.TickAsync(r.Now);
        Assert.False(pad.Peer.Rejected);

        r.Now = windowSentAt.AddSeconds(151);
        await r.Pc.TickAsync(r.Now);
        Assert.True(pad.Peer.Rejected);

        // Part 2: New chunk sent after resume gets its own 4-minute cap from its own completion time.
        var pad2 = await r.ConnectAsync(512);
        var reoffer = Assert.IsType<SyncOffer>(Assert.Single(pad2.Drain()));
        r.Now = r.Now.AddSeconds(1);
        var win2Start = r.Now;
        await pad2.SendAsync(new SyncResume(reoffer.Id, 0));
        Assert.Equal(4, pad2.Drain().Cast<SyncChunk>().Count());

        var msgSeq = 200;
        byte[][] NextFramePackets() => SyncPacketizer.Split(
            pad2.Seal(new SyncItem(Guid.NewGuid(), msgSeq++, "pad", new string((char)('a' + (msgSeq % 26)), 1000))), 200).ToArray();
        var curPackets = Array.Empty<byte[]>();
        var pktIdx = 0;
        while ((r.Now - win2Start).TotalSeconds < 160 || pktIdx > 0)
        {
            if (pktIdx == 0) curPackets = NextFramePackets();
            Assert.True(await r.Pc.ReceiveAsync(pad2.Peer, curPackets[pktIdx++]));
            if (pktIdx == curPackets.Length) { await r.Pc.WaitForOutgoingAsync(pad2.Peer); pad2.Drain(); pktIdx = 0; }
            r.Now = r.Now.AddSeconds(10);
            await r.Pc.TickAsync(r.Now);
            Assert.False(pad2.Peer.Rejected);
        }
        Assert.True((r.Now - win2Start).TotalSeconds < 240);

        // Resume all 4 chunks around ~180s; chunk 4 is sent now with its own 240s cap (survives past win2Start + 240s).
        await pad2.SendAsync(new SyncResume(reoffer.Id, SyncProtocol.ChunkBytes * 4));
        Assert.IsType<SyncChunk>(Assert.Single(pad2.Drain()));
        var chunk4SentAt = r.Now;

        pktIdx = 0;
        while ((r.Now - win2Start).TotalSeconds < 250 || pktIdx > 0)
        {
            if (pktIdx == 0) curPackets = NextFramePackets();
            Assert.True(await r.Pc.ReceiveAsync(pad2.Peer, curPackets[pktIdx++]));
            if (pktIdx == curPackets.Length) { await r.Pc.WaitForOutgoingAsync(pad2.Peer); pad2.Drain(); pktIdx = 0; }
            r.Now = r.Now.AddSeconds(10);
            await r.Pc.TickAsync(r.Now);
            Assert.False(pad2.Peer.Rejected);
        }
        Assert.True((r.Now - win2Start).TotalSeconds > 240);
        Assert.True((r.Now - chunk4SentAt).TotalSeconds < 240);

        await pad2.SendAsync(new SyncAck([reoffer.Id]));
        Assert.Equal(0, r.State.Pending);
    }

    [Fact]
    public async Task TickExpiresFrontChunkEvenWhileLaterChunkIsInFlight()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);
        var data = new byte[SyncProtocol.ChunkBytes * 4 + 100];
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "front-expire.bin", Data: data)]));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        var offer = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));

        var t0 = r.Now;
        await pad.SendAsync(new SyncResume(offer.Id, 0));
        Assert.Equal(4, pad.Drain().Cast<SyncChunk>().Count());

        // Block chunk 4 mid-send while chunk 1 is already sent and waiting for resume.
        var chunk4Entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var chunk4Release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pad.Peer.OnSend = _ => { chunk4Entered.TrySetResult(); return chunk4Release.Task; };
        try
        {
            foreach (var packet in SyncPacketizer.Split(pad.Seal(new SyncResume(offer.Id, SyncProtocol.ChunkBytes)), pad.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(pad.Peer, packet));
            await chunk4Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));

            r.Now = t0.AddSeconds(61);
            await r.Pc.TickAsync(r.Now);
            Assert.True(pad.Peer.Rejected);
            Assert.Equal(1, r.State.Pending);
        }
        finally { chunk4Release.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
    }

    [Fact]
    public async Task ResumeRequiresLastPacketHandoffAndAllowsPendingNotifyCompletionOnResumeAndAck()
    {
        var r = new Rig();
        var data = new byte[SyncProtocol.ChunkBytes * 5 + 17];
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "handoff.bin", Data: data)]));

        // 1. Reject resume sent while chunk 0 stopped after its first packet (last packet not handed off).
        var pad1 = await r.ConnectAsync(20);
        var offer = Assert.IsType<SyncOffer>(Assert.Single(pad1.Drain()));
        var firstPkt = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseFirst = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pad1.Peer.OnSend = _ => { firstPkt.TrySetResult(); return releaseFirst.Task; };
        try
        {
            foreach (var packet in SyncPacketizer.Split(pad1.Seal(new SyncResume(offer.Id, 0)), pad1.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(pad1.Peer, packet));
            await firstPkt.Task.WaitAsync(TimeSpan.FromSeconds(2));

            var ok = true;
            foreach (var packet in SyncPacketizer.Split(pad1.Seal(new SyncResume(offer.Id, SyncProtocol.ChunkBytes)), pad1.Peer.PacketLimit))
                ok = await r.Pc.ReceiveAsync(pad1.Peer, packet);
            Assert.False(ok);
            Assert.True(pad1.Peer.Rejected);
            Assert.Equal(1, r.State.Pending);
        }
        finally { releaseFirst.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(pad1.Peer);

        // 2. Accept resume when last packet of chunk 0 IS handed off while NotifyValueAsync is still pending.
        var pad2 = await r.ConnectAsync(512);
        var offer2 = Assert.IsType<SyncOffer>(Assert.Single(pad2.Drain()));
        var chunk0LastEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var chunk0LastRelease = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pad2.Peer.OnSend = packet =>
        {
            if ((packet[0] & 2) != 0 && !chunk0LastEntered.Task.IsCompleted)
            {
                chunk0LastEntered.TrySetResult();
                return chunk0LastRelease.Task;
            }
            return Task.CompletedTask;
        };
        try
        {
            foreach (var packet in SyncPacketizer.Split(pad2.Seal(new SyncResume(offer2.Id, 0)), pad2.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(pad2.Peer, packet));
            await chunk0LastEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));

            foreach (var packet in SyncPacketizer.Split(pad2.Seal(new SyncResume(offer2.Id, SyncProtocol.ChunkBytes)), pad2.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(pad2.Peer, packet));
            Assert.False(pad2.Peer.Rejected);
        }
        finally { chunk0LastRelease.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(pad2.Peer);
        var sentChunks = pad2.Drain().Cast<SyncChunk>().ToArray();
        Assert.Equal(5, sentChunks.Length);

        // 3. Accept ack when final chunk's last packet IS handed off while NotifyValueAsync is still pending.
        var finalLastEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var finalLastRelease = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pad2.Peer.OnSend = packet =>
        {
            if ((packet[0] & 2) != 0 && !finalLastEntered.Task.IsCompleted)
            {
                finalLastEntered.TrySetResult();
                return finalLastRelease.Task;
            }
            return Task.CompletedTask;
        };
        try
        {
            foreach (var packet in SyncPacketizer.Split(pad2.Seal(new SyncResume(offer2.Id, SyncProtocol.ChunkBytes * 2)), pad2.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(pad2.Peer, packet));
            await finalLastEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));

            foreach (var packet in SyncPacketizer.Split(pad2.Seal(new SyncAck([offer2.Id])), pad2.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(pad2.Peer, packet));
            Assert.False(pad2.Peer.Rejected);
            Assert.Equal(0, r.State.Pending);
        }
        finally { finalLastRelease.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(pad2.Peer);
    }

    [Fact]
    public async Task AbandonedIncomingAttachmentReleasesHighThroughputAfterIdleGraceWhileKeepingPartial()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);
        var data = Enumerable.Range(0, SyncProtocol.ChunkBytes * 5 + 25).Select(i => (byte)(i * 5 + 1)).ToArray();
        var offer = new SyncOffer(Guid.NewGuid(), r.Now.ToUnixTimeMilliseconds(), "pad", "file", data.Length,
            Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(data)),
            Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("abandoned.bin")), "public.data");

        await pad.SendAsync(offer);
        Assert.Equal(new SyncResume(offer.Id, 0), Assert.Single(pad.Drain()));
        for (var i = 0; i < 4; i++)
            await pad.SendAsync(new SyncChunk(offer.Id, i * SyncProtocol.ChunkBytes, data[(i * SyncProtocol.ChunkBytes)..((i + 1) * SyncProtocol.ChunkBytes)]));
        pad.Drain();
        Assert.Equal([true], pad.Peer.HighThroughputHistory);

        // Sender drops the item locally and sends nothing more; after 6s idle, high-throughput is released
        // while the partial remains on disk for potential resume.
        r.Now = r.Now.AddSeconds(6);
        await r.Pc.TickAsync(r.Now);
        Assert.False(pad.Peer.Rejected);
        Assert.Equal([true, false], pad.Peer.HighThroughputHistory);
        Assert.NotNull(r.Store.Incoming(r.DeviceId, offer.Id));

        // If sender later resumes sending remaining chunks, high-throughput turns back on and completes cleanly.
        r.Now = r.Now.AddSeconds(1);
        await pad.SendAsync(new SyncChunk(offer.Id, SyncProtocol.ChunkBytes * 4, data[(SyncProtocol.ChunkBytes * 4)..(SyncProtocol.ChunkBytes * 5)]));
        Assert.Equal([true, false, true], pad.Peer.HighThroughputHistory);
        await pad.SendAsync(new SyncChunk(offer.Id, SyncProtocol.ChunkBytes * 5, data[(SyncProtocol.ChunkBytes * 5)..]));
        var replies = pad.Drain();
        Assert.Equal(offer.Id, Assert.Single(Assert.IsType<SyncAck>(replies[^1]).Ids));

        r.Now = r.Now.AddSeconds(6);
        await r.Pc.TickAsync(r.Now);
        Assert.Equal([true, false, true, false], pad.Peer.HighThroughputHistory);
    }

    [Fact]
    public async Task ReceiveAsyncWaitingOnGateDropsWithoutProcessingWhenPeerRejectedWhileWaiting()
    {
        var r = new Rig();
        var otherId = Guid.NewGuid();
        var pad1 = await r.ConnectAsync(512);
        var pad2 = await r.ConnectAsync(512, deviceId: otherId);

        var writeEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseWrite = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        r.Clipboard.BeforeWrite = () =>
        {
            if (r.Clipboard.Writes.Count == 0)
            {
                writeEntered.TrySetResult();
                return releaseWrite.Task;
            }
            return Task.CompletedTask;
        };

        var holderItem = new SyncItem(Guid.NewGuid(), 100, "pad", "holds-gate");
        var holderPacket = Assert.Single(SyncPacketizer.Split(pad2.Seal(holderItem), pad2.Peer.PacketLimit));
        var holderTask = r.Pc.ReceiveAsync(pad2.Peer, holderPacket);
        await writeEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        // pad1's ReceiveAsync now blocks waiting on coordinator gate.
        var rejectedItem = new SyncItem(Guid.NewGuid(), 101, "pad", "must-not-be-written");
        var blockedPacket = Assert.Single(SyncPacketizer.Split(pad1.Seal(rejectedItem), pad1.Peer.PacketLimit));
        var blockedTask = r.Pc.ReceiveAsync(pad1.Peer, blockedPacket);
        await Task.Delay(30);

        // Simulate BleWritePipeline synchronously retiring pad1 due to byte limit while pad1 is waiting on gate.
        pad1.Peer.Reject();
        releaseWrite.SetResult();

        Assert.True(await holderTask.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.False(await blockedTask.WaitAsync(TimeSpan.FromSeconds(5)));

        Assert.Equal(["holds-gate"], r.Clipboard.Writes);
        Assert.Empty(pad1.Drain());
        Assert.Equal(1, r.State.Connected);
    }

    [Fact]
    public async Task LastPacketStopOrFailureBeforeSendPreventsBoundaryResumeAndFinalAck()
    {
        // 1. Pausing before last packet starts OR failing when starting the last packet of chunk 0
        //    prevents boundary resume from passing and preserves pending.
        var r = new Rig();
        var data = Enumerable.Range(0, SyncProtocol.ChunkBytes * 4 + 17).Select(i => (byte)i).ToArray();
        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "boundary.bin", Data: data)]));

        var pad1 = await r.ConnectAsync(512);
        var offer1 = Assert.IsType<SyncOffer>(Assert.Single(pad1.Drain()));
        var chunk0Packets = SyncPacketizer.Split(pad1.Seal(new SyncChunk(offer1.Id, 0, data[..SyncProtocol.ChunkBytes])), 512).Count;

        var sentCount = 0;
        var pausedBeforeLast = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseBeforeLast = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pad1.Peer.OnSend = packet =>
        {
            var n = Interlocked.Increment(ref sentCount);
            if (n == chunk0Packets - 1)
            {
                pausedBeforeLast.TrySetResult();
                return releaseBeforeLast.Task;
            }
            return Task.CompletedTask;
        };

        try
        {
            foreach (var packet in SyncPacketizer.Split(pad1.Seal(new SyncResume(offer1.Id, 0)), pad1.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(pad1.Peer, packet));
            await pausedBeforeLast.Task.WaitAsync(TimeSpan.FromSeconds(5));

            // While stopped just before last packet starts notification, boundary resume is rejected.
            var ok = true;
            foreach (var packet in SyncPacketizer.Split(pad1.Seal(new SyncResume(offer1.Id, SyncProtocol.ChunkBytes)), pad1.Peer.PacketLimit))
                ok = await r.Pc.ReceiveAsync(pad1.Peer, packet);
            Assert.False(ok);
            Assert.True(pad1.Peer.Rejected);
            Assert.Equal(1, r.State.Pending);
        }
        finally { releaseBeforeLast.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(pad1.Peer);

        // 1b. Synchronous failure starting notification on the last packet of chunk 0 does NOT mark handoff.
        var pad1b = await r.ConnectAsync(512);
        var offer1b = Assert.IsType<SyncOffer>(Assert.Single(pad1b.Drain()));
        pad1b.Peer.OnSend = packet =>
        {
            if ((packet[0] & 2) != 0)
                return Task.FromException(new IOException("notify failed to start on last packet"));
            return Task.CompletedTask;
        };
        foreach (var packet in SyncPacketizer.Split(pad1b.Seal(new SyncResume(offer1b.Id, 0)), pad1b.Peer.PacketLimit))
            Assert.True(await r.Pc.ReceiveAsync(pad1b.Peer, packet));
        await r.Pc.WaitForOutgoingAsync(pad1b.Peer);
        Assert.True(pad1b.Peer.Rejected);
        Assert.False(await r.Pc.ReceiveAsync(pad1b.Peer, SyncPacketizer.Split(pad1b.Seal(new SyncResume(offer1b.Id, SyncProtocol.ChunkBytes)), pad1b.Peer.PacketLimit)[0]));
        Assert.Equal(1, r.State.Pending);

        // 2. Failing synchronously when starting the last packet of the final chunk prevents final ACK from passing.
        var pad2 = await r.ConnectAsync(512);
        var offer2 = Assert.IsType<SyncOffer>(Assert.Single(pad2.Drain()));
        await pad2.SendAsync(new SyncResume(offer2.Id, 0));
        var initialWindow = pad2.Drain().Cast<SyncChunk>().ToArray();
        Assert.Equal(4, initialWindow.Length);

        pad2.Peer.OnSend = packet =>
        {
            if ((packet[0] & 2) != 0)
                return Task.FromException(new IOException("notify failed on final packet"));
            return Task.CompletedTask;
        };
        foreach (var packet in SyncPacketizer.Split(pad2.Seal(new SyncResume(offer2.Id, SyncProtocol.ChunkBytes)), pad2.Peer.PacketLimit))
            Assert.True(await r.Pc.ReceiveAsync(pad2.Peer, packet));
        await r.Pc.WaitForOutgoingAsync(pad2.Peer);
        Assert.True(pad2.Peer.Rejected);
        Assert.Equal(1, r.State.Pending);

        // Subsequent ACK on retired connection is rejected and pending item remains intact.
        Assert.False(await r.Pc.ReceiveAsync(pad2.Peer, SyncPacketizer.Split(pad2.Seal(new SyncAck([offer2.Id])), pad2.Peer.PacketLimit)[0]));
        Assert.Equal(1, r.State.Pending);
    }

    [Fact]
    public async Task OfferAckIgnoredBeforeLastPacketHandedOffAndAcceptedAfterHandoff()
    {
        var r = new Rig();
        var data = new byte[] { 10, 20, 30, 40 };
        var pad = await r.ConnectAsync(20);

        var firstPacketPaused = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var allowRemainingPackets = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var packetIndex = 0;
        pad.Peer.OnSend = _ =>
        {
            if (Interlocked.Increment(ref packetIndex) == 1)
            {
                firstPacketPaused.TrySetResult();
                return allowRemainingPackets.Task;
            }
            return Task.CompletedTask;
        };

        try
        {
            await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "mid-offer.bin", Data: data)]));
            await firstPacketPaused.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var offerId = Assert.Single(r.Store.Pending(r.DeviceId)).Id;

            // ACK arriving while offer is mid-packet (before offer's last packet is handed off) is ignored.
            foreach (var packet in SyncPacketizer.Split(pad.Seal(new SyncAck([offerId])), pad.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(pad.Peer, packet));
            Assert.False(pad.Peer.Rejected);
            Assert.Equal(1, r.State.Pending);
        }
        finally { allowRemainingPackets.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        var offer = Assert.IsType<SyncOffer>(Assert.Single(pad.Drain()));

        // ACK after offer's last packet has been handed off succeeds.
        await pad.SendAsync(new SyncAck([offer.Id]));
        Assert.Equal(0, r.State.Pending);

        // Also verify ACK is accepted while single-packet offer notification task is still pending after handoff.
        var pad512 = await r.ConnectAsync(512);
        var offerEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var offerRelease = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pad512.Peer.OnSend = _ => { offerEntered.TrySetResult(); return offerRelease.Task; };
        try
        {
            await r.Pc.ClipboardChangedAsync(new(2, null, false, [new("file", Filename: "empty-offer.bin", Data: [])]));
            await offerEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var emptyId = Assert.Single(r.Store.Pending(r.DeviceId)).Id;
            foreach (var packet in SyncPacketizer.Split(pad512.Seal(new SyncAck([emptyId])), pad512.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(pad512.Peer, packet));
            Assert.False(pad512.Peer.Rejected);
            Assert.Equal(0, r.State.Pending);
        }
        finally { offerRelease.TrySetResult(); }
        await r.Pc.WaitForOutgoingAsync(pad512.Peer);
    }

    [Fact]
    public async Task SlowIncomingChunkOverFiveSecondsKeepsHighThroughputRequestedUntilIdle()
    {
        var r = new Rig();
        var pad = await r.ConnectAsync(512);
        var data = Enumerable.Range(0, SyncProtocol.ChunkBytes * 2 + 9).Select(i => (byte)(i * 3 + 1)).ToArray();
        var offer = new SyncOffer(Guid.NewGuid(), r.Now.ToUnixTimeMilliseconds(), "pad", "file", data.Length,
            Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(data)),
            Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("slow-rx.bin")), "public.data");

        await pad.SendAsync(offer);
        Assert.Equal(new SyncResume(offer.Id, 0), Assert.Single(pad.Drain()));
        Assert.Equal([true], pad.Peer.HighThroughputHistory);

        var chunk0Packets = SyncPacketizer.Split(
            pad.Seal(new SyncChunk(offer.Id, 0, data[..SyncProtocol.ChunkBytes])),
            pad.Peer.PacketLimit);
        Assert.True(chunk0Packets.Count >= 10);

        // Deliver chunk 0 packets slowly across >8 seconds (>5s HighThroughputIdleGrace) with periodic Ticks.
        var batchSize = Math.Max(1, chunk0Packets.Count / 5);
        for (var i = 0; i < chunk0Packets.Count - 1; i++)
        {
            Assert.True(await r.Pc.ReceiveAsync(pad.Peer, chunk0Packets[i]));
            if ((i + 1) % batchSize == 0)
            {
                r.Now = r.Now.AddSeconds(2);
                await r.Pc.TickAsync(r.Now);
                Assert.False(pad.Peer.Rejected);
                Assert.Equal([true], pad.Peer.HighThroughputHistory);
            }
        }
        r.Now = r.Now.AddSeconds(2);
        await r.Pc.TickAsync(r.Now);
        Assert.Equal([true], pad.Peer.HighThroughputHistory);

        // Complete chunk 0, then stall before chunk 1 for 6s -> high throughput releases cleanly.
        Assert.True(await r.Pc.ReceiveAsync(pad.Peer, chunk0Packets[^1]));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        Assert.Equal(new SyncResume(offer.Id, SyncProtocol.ChunkBytes), Assert.Single(pad.Drain()));

        r.Now = r.Now.AddSeconds(6);
        await r.Pc.TickAsync(r.Now);
        Assert.Equal([true, false], pad.Peer.HighThroughputHistory);

        // Deliver chunk 1 -> high throughput re-enables; stall mid-packet for 6s -> releases again.
        await pad.SendAsync(new SyncChunk(offer.Id, SyncProtocol.ChunkBytes, data[SyncProtocol.ChunkBytes..(SyncProtocol.ChunkBytes * 2)]));
        Assert.Equal(new SyncResume(offer.Id, SyncProtocol.ChunkBytes * 2), Assert.Single(pad.Drain()));
        Assert.Equal([true, false, true], pad.Peer.HighThroughputHistory);

        var finalChunkPackets = SyncPacketizer.Split(
            pad.Seal(new SyncChunk(offer.Id, SyncProtocol.ChunkBytes * 2, data[(SyncProtocol.ChunkBytes * 2)..])),
            20);
        Assert.True(finalChunkPackets.Count >= 2);
        Assert.True(await r.Pc.ReceiveAsync(pad.Peer, finalChunkPackets[0]));
        r.Now = r.Now.AddSeconds(6);
        await r.Pc.TickAsync(r.Now);
        Assert.False(pad.Peer.Rejected);
        Assert.Equal([true, false, true, false], pad.Peer.HighThroughputHistory);

        // Complete final chunk -> finishes and commits cleanly.
        for (var i = 1; i < finalChunkPackets.Count; i++)
            Assert.True(await r.Pc.ReceiveAsync(pad.Peer, finalChunkPackets[i]));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        Assert.Equal(offer.Id, Assert.Single(Assert.IsType<SyncAck>(Assert.Single(pad.Drain())).Ids));
    }
}
