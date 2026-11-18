using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Text.Json;
using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class TemplateSyncCoordinatorTests : IDisposable
{
    private readonly List<string> tempRoots = [];

    public void Dispose()
    {
        foreach (var root in tempRoots)
        {
            if (Directory.Exists(root))
                Directory.Delete(root, recursive: true);
        }
    }

    private sealed class FakePeer : ISyncPeer
    {
        private readonly object packetsGate = new();
        public int PacketLimit { get; set; } = 512;
        public bool Rejected { get; private set; }
        bool ISyncPeer.IsRejected => Rejected;
        public Func<byte[], Task>? OnSend;
        public readonly List<byte[]> Packets = [];
        public Task SendPacketAsync(byte[] packet)
        {
            Assert.False(Rejected);
            Assert.InRange(packet.Length, 2, PacketLimit);
            lock (packetsGate) Packets.Add(packet.ToArray());
            return OnSend?.Invoke(packet) ?? Task.CompletedTask;
        }
        public void Reject() => Rejected = true;
        public byte[][] DrainFrames()
        {
            byte[][] snapshot;
            lock (packetsGate)
            {
                snapshot = Packets.ToArray();
                Packets.Clear();
            }
            var assembler = new SyncPacketAssembler(ushort.MaxValue);
            var frames = new List<byte[]>();
            foreach (var packet in snapshot)
            {
                var frame = assembler.Append(packet);
                if (frame is not null) frames.Add(frame);
            }
            assembler.Finish();
            return frames.ToArray();
        }
    }

    private sealed class FakeClipboard : IClipboardAccess
    {
        public uint Sequence = 100;
        public readonly List<string> Writes = [];
        public Task<uint> WriteTextAsync(string text)
        {
            Writes.Add(text);
            return Task.FromResult(++Sequence);
        }
    }

    private sealed class Rig
    {
        public readonly SyncPairing Pairing = SyncPairing.Create("test-pc");
        public readonly FakeClipboard Clipboard = new();
        public readonly Guid DeviceId = Guid.NewGuid();
        public readonly string Root;
        public readonly SyncRepository Store;
        public readonly TemplateRepository Templates;
        public readonly ConcurrentQueue<string> Logs = new();
        public readonly SyncCoordinator Pc;
        public DateTimeOffset Now = new(2026, 11, 18, 12, 0, 0, TimeSpan.Zero);
        public SyncStatus State = new(0, 0, null, null);

        public Rig(TemplateSyncCoordinatorTests owner)
        {
            Root = Path.Combine(Path.GetTempPath(), "clipboardplus-tpl-coord-tests", Guid.NewGuid().ToString("N"));
            owner.tempRoots.Add(Root);
            Store = new(Root, Pairing.PcId);
            Store.Register(DeviceId, "pad", Now);
            Templates = new(Root, Logs.Enqueue);
            Pc = new(Pairing, Clipboard, Logs.Enqueue, Store, () => Now, Templates);
            Pc.Changed += s => State = s;
        }

        public async Task<Pad> ConnectAsync(int limit = 512, Guid? deviceId = null, string? kind = null)
        {
            var id = deviceId ?? DeviceId;
            if (kind is not null) Store.Register(id, kind, Now);
            var peer = new FakePeer { PacketLimit = limit };
            var handshake = new SyncPadHandshake(Pairing, id);
            await Pc.ConnectAsync(peer);
            await SendFrameAsync(peer, handshake.CreateHello());
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
        public Task SendTemplateAsync(TemplateSyncMessage message) => rig.SendFrameAsync(Peer, SealTemplate(message));
        public byte[] SealTemplate(TemplateSyncMessage message) => sender.Seal(TemplateSyncMessageCodec.Encode(message));

        public object[] DrainAll()
        {
            var frames = Peer.DrainFrames();
            var result = new object[frames.Length];
            for (var i = 0; i < frames.Length; i++)
            {
                var plain = receiver.Open(frames[i]);
                result[i] = IsTemplatePlaintext(plain)
                    ? TemplateSyncMessageCodec.Decode(plain)
                    : SyncMessageCodec.Decode(plain);
            }
            return result;
        }

        public TemplateSyncMessage[] DrainTemplates() => DrainAll().OfType<TemplateSyncMessage>().ToArray();

        private static bool IsTemplatePlaintext(byte[] plain)
        {
            if (plain.Length < 2) return false;
            var len = BinaryPrimitives.ReadUInt16BigEndian(plain);
            if (len == 0 || len > plain.Length - 2) return false;
            using var doc = JsonDocument.Parse(plain.AsMemory(2, len));
            return doc.RootElement.TryGetProperty("t", out var t) &&
                   t.ValueKind == JsonValueKind.String &&
                   (t.GetString()?.StartsWith("tpl_", StringComparison.Ordinal) ?? false);
        }
    }

    [Fact]
    public async Task IosInitiatedSyncMultiPageMergesSavesAndRepliesOnlyToRequester()
    {
        var r = new Rig(this);
        var phoneId = Guid.NewGuid();
        var pad = await r.ConnectAsync(512);
        var phone = await r.ConnectAsync(512, deviceId: phoneId, kind: "phone");

        var pcItem = (await r.Pc.CreateTemplateAsync("PC側の秘密本文", "秘密タイトル", "仕事")).Item!;
        var changedCount = 0;
        r.Pc.TemplatesChanged += () => changedCount++;

        var op = Guid.NewGuid();
        var remoteItems = Enumerable.Range(0, 6).Select(i => new TemplateSyncItem(
            Guid.NewGuid(),
            TemplateSyncKind.Text,
            $"iPad長文-{i}-" + new string((char)('a' + i), 55_000),
            $"定型{i}",
            "旅行",
            i,
            r.Now.ToUnixTimeMilliseconds() + i)).ToArray();

        var pushMessages = TemplateSyncMessageCodec.SplitPages(
            op,
            new TemplateSyncSnapshot(r.Now.ToUnixTimeMilliseconds(), remoteItems, []),
            isState: false);
        Assert.True(pushMessages.Count >= 2);

        // Send all pages except last: PC must not reply or save yet.
        for (var i = 0; i < pushMessages.Count - 1; i++)
            await pad.SendTemplateAsync(pushMessages[i]);
        Assert.Empty(pad.DrainTemplates());
        Assert.Single(await r.Pc.GetTemplatesAsync());
        Assert.Equal(0, changedCount);

        // Final page triggers merge, save, TemplatesChanged, and tpl_state ONLY to pad.
        await pad.SendTemplateAsync(pushMessages[^1]);
        await r.Pc.WaitForOutgoingAsync();
        Assert.Equal(1, changedCount);
        var padStates = pad.DrainTemplates().Cast<TemplateSyncStateMessage>().ToArray();
        Assert.True(padStates.Length >= 2);
        Assert.Empty(phone.DrainTemplates());

        var assembler = new TemplateSyncPageAssembler(expectedOp: op, expectedIsState: true);
        TemplateSyncSnapshot? reassembled = null;
        foreach (var msg in padStates)
            reassembled = assembler.Append(msg);
        assembler.Finish();
        Assert.NotNull(reassembled);
        Assert.Equal(7, reassembled!.Templates.Count);
        Assert.Contains(reassembled.Templates, t => t.Id == pcItem.Id);
        Assert.All(reassembled.Templates, t => Assert.Null(t.BaseHash));

        await pad.SendTemplateAsync(new TemplateSyncAck(op));
        Assert.False(pad.Peer.Rejected);

        // Reload from disk confirms templates.json was saved atomically.
        var reloaded = new TemplateRepository(r.Root);
        Assert.Equal(7, reloaded.Count);
        Assert.DoesNotContain(r.Logs, l => l.Contains("PC側の秘密本文") || l.Contains("秘密タイトル") || l.Contains("仕事") || l.Contains("iPad長文"));
    }

    [Fact]
    public async Task IosInitiatedSyncRejectsWrongDirectionAndOverLimitWithoutSaving()
    {
        var r = new Rig(this);
        await r.Pc.CreateTemplateAsync("keep-me", null, null);
        var pad = await r.ConnectAsync(512);

        // Wrong direction tpl_pull from pad drops connection.
        var pullFrame = pad.SealTemplate(new TemplateSyncPull(Guid.NewGuid()));
        var ok = true;
        foreach (var pkt in SyncPacketizer.Split(pullFrame, pad.Peer.PacketLimit))
            ok = await r.Pc.ReceiveAsync(pad.Peer, pkt);
        Assert.False(ok);
        Assert.True(pad.Peer.Rejected);

        // Over 300 merged items fails with Limit without overwriting templates.json.
        var pad2 = await r.ConnectAsync(512);
        var maxRemote = Enumerable.Range(0, SyncProtocol.MaxTemplates)
            .Select(i => new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, $"remote-{i}", null, null, i, r.Now.ToUnixTimeMilliseconds()))
            .ToArray();
        var push = Assert.Single(TemplateSyncMessageCodec.SplitPages(
            Guid.NewGuid(),
            new TemplateSyncSnapshot(r.Now.ToUnixTimeMilliseconds(), maxRemote, []),
            isState: false));
        ok = true;
        foreach (var pkt in SyncPacketizer.Split(pad2.SealTemplate(push), pad2.Peer.PacketLimit))
            ok = await r.Pc.ReceiveAsync(pad2.Peer, pkt);
        Assert.False(ok);
        Assert.True(pad2.Peer.Rejected);

        var kept = Assert.Single(await r.Pc.GetTemplatesAsync());
        Assert.Equal("keep-me", kept.Text);
    }

    [Fact]
    public async Task PcInitiatedSyncWithZeroAndOneDeviceHandlesMergeConflictsAndResync()
    {
        var r = new Rig(this);
        Assert.Equal(TemplateSyncRunStatus.NoConnectedDevices, (await r.Pc.SyncTemplatesAsync()).Status);

        var pad = await r.ConnectAsync(512);
        var sharedId = Guid.NewGuid();
        var origHash = TemplateSyncMerge.ContentHash(TemplateSyncKind.Text, "orig", "題", "仕事");
        r.Templates.ApplyMerged([
            new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "PCで編集した文", "題", "仕事", 0, r.Now.AddSeconds(10).ToUnixTimeMilliseconds()),
        ], []);

        var padAddedId = Guid.NewGuid();
        var syncTask = r.Pc.SyncTemplatesAsync();
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        var pull = Assert.IsType<TemplateSyncPull>(Assert.Single(pad.DrainTemplates()));

        // Remote edited the same item earlier -> conflict copy goes to その他, plus remote adds one new item.
        var push = Assert.Single(TemplateSyncMessageCodec.SplitPages(
            pull.Op,
            new TemplateSyncSnapshot(
                r.Now.ToUnixTimeMilliseconds(),
                [
                    new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "iPadで編集した文", "題", "仕事", 0, r.Now.ToUnixTimeMilliseconds(), origHash),
                    new TemplateSyncItem(padAddedId, TemplateSyncKind.Text, "iPad新規", null, null, 0, r.Now.ToUnixTimeMilliseconds()),
                ],
                []),
            isState: false));

        await pad.SendTemplateAsync(push);
        var stateMsg = Assert.IsType<TemplateSyncStateMessage>(Assert.Single(pad.DrainTemplates()));
        Assert.Equal(pull.Op, stateMsg.Op);
        Assert.Equal(3, stateMsg.Page.Templates.Count);
        Assert.False(syncTask.IsCompleted);

        await pad.SendTemplateAsync(new TemplateSyncAck(pull.Op));
        var result = await syncTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(TemplateSyncRunStatus.Completed, result.Status);
        Assert.Equal(1, result.SucceededDevices);
        Assert.Equal(0, result.FailedDevices);
        Assert.True(result.PcSaved);
        Assert.Equal(2, result.PcAdded); // padAdded + conflict copy
        Assert.Equal(1, result.ConflictCopyCount);
        Assert.Null(result.ClockSkewSeconds);

        // Second sync in same state reports 0 changes everywhere.
        r.Now = r.Now.AddSeconds(5);
        var resyncTask = r.Pc.SyncTemplatesAsync();
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        var pull2 = Assert.IsType<TemplateSyncPull>(Assert.Single(pad.DrainTemplates()));
        var syncedItems = stateMsg.Page.Templates
            .Select(t => t with { BaseHash = TemplateSyncMerge.ContentHash(t) })
            .ToArray();
        await pad.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            pull2.Op,
            new TemplateSyncSnapshot(r.Now.ToUnixTimeMilliseconds(), syncedItems, stateMsg.Page.Tombstones),
            isState: false)));
        Assert.IsType<TemplateSyncStateMessage>(Assert.Single(pad.DrainTemplates()));
        await pad.SendTemplateAsync(new TemplateSyncAck(pull2.Op));
        var resyncResult = await resyncTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(TemplateSyncRunStatus.Completed, resyncResult.Status);
        Assert.Equal(0, resyncResult.PcAdded + resyncResult.PcUpdated + resyncResult.PcDeleted);
        Assert.Equal(0, resyncResult.RemoteChangesTotal);
    }

    [Fact]
    public async Task PcInitiatedSyncTwoDevicesCollectsBothBeforeMergingAndDistributesIdenticalState()
    {
        var r = new Rig(this);
        var phoneId = Guid.NewGuid();
        var pad = await r.ConnectAsync(512);
        var phone = await r.ConnectAsync(512, deviceId: phoneId, kind: "phone");

        var pcOnly = (await r.Pc.CreateTemplateAsync("PC項目", null, null)).Item!;
        var padOnlyId = Guid.NewGuid();
        var phoneOnlyId = Guid.NewGuid();

        var syncTask = r.Pc.SyncTemplatesAsync();
        await r.Pc.WaitForOutgoingAsync();

        var padPull = Assert.IsType<TemplateSyncPull>(Assert.Single(pad.DrainTemplates()));
        var phonePull = Assert.IsType<TemplateSyncPull>(Assert.Single(phone.DrainTemplates()));
        Assert.Equal(padPull.Op, phonePull.Op);

        // First device (pad) responds -> PC must wait for phone before merging or sending tpl_state!
        await pad.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            padPull.Op,
            new TemplateSyncSnapshot(
                r.Now.ToUnixTimeMilliseconds(),
                [new TemplateSyncItem(padOnlyId, TemplateSyncKind.Text, "iPad項目", null, "仕事", 0, r.Now.ToUnixTimeMilliseconds())],
                []),
            isState: false)));
        await r.Pc.WaitForOutgoingAsync();
        Assert.Empty(pad.DrainTemplates());
        Assert.Empty(phone.DrainTemplates());
        Assert.Single(await r.Pc.GetTemplatesAsync()); // Only pcOnly on PC so far.

        // Second device (phone) responds -> PC merges all 3 and distributes identical tpl_state to both.
        await phone.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            phonePull.Op,
            new TemplateSyncSnapshot(
                r.Now.ToUnixTimeMilliseconds(),
                [new TemplateSyncItem(phoneOnlyId, TemplateSyncKind.Text, "iPhone項目", null, "個人", 0, r.Now.ToUnixTimeMilliseconds())],
                []),
            isState: false)));
        await r.Pc.WaitForOutgoingAsync();

        var padState = Assert.IsType<TemplateSyncStateMessage>(Assert.Single(pad.DrainTemplates()));
        var phoneState = Assert.IsType<TemplateSyncStateMessage>(Assert.Single(phone.DrainTemplates()));
        Assert.Equal(3, padState.Page.Templates.Count);
        Assert.Equal(padState.Page.Templates, phoneState.Page.Templates);
        Assert.Contains(padState.Page.Templates, t => t.Id == pcOnly.Id);
        Assert.Contains(padState.Page.Templates, t => t.Id == padOnlyId);
        Assert.Contains(padState.Page.Templates, t => t.Id == phoneOnlyId);
        Assert.Equal(3, (await r.Pc.GetTemplatesAsync()).Count);

        // First ack still waits for second ack.
        await pad.SendTemplateAsync(new TemplateSyncAck(padPull.Op));
        Assert.False(syncTask.IsCompleted);
        await phone.SendTemplateAsync(new TemplateSyncAck(phonePull.Op));

        var result = await syncTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(TemplateSyncRunStatus.Completed, result.Status);
        Assert.Equal(2, result.TargetDevices);
        Assert.Equal(2, result.SucceededDevices);
        Assert.Equal(0, result.FailedDevices);
        Assert.Equal(2, result.PcAdded);
    }

    [Fact]
    public async Task PcInitiatedSyncHandlesPartialDisconnectInPhase1AndPhase2AndAllDisconnect()
    {
        // 1. Two devices: phone disconnects in Phase 1 before pushing; pad finishes alone.
        var r1 = new Rig(this);
        var phone1 = await r1.ConnectAsync(512, deviceId: Guid.NewGuid(), kind: "phone");
        var pad1 = await r1.ConnectAsync(512);
        var sync1 = r1.Pc.SyncTemplatesAsync();
        await r1.Pc.WaitForOutgoingAsync();
        var pull1 = Assert.IsType<TemplateSyncPull>(Assert.Single(pad1.DrainTemplates()));
        phone1.DrainTemplates();

        await r1.Pc.DisconnectAsync(phone1.Peer);
        Assert.False(sync1.IsCompleted);

        var padItem1 = new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "pad-survives-p1", null, null, 0, r1.Now.ToUnixTimeMilliseconds());
        await pad1.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            pull1.Op, new TemplateSyncSnapshot(r1.Now.ToUnixTimeMilliseconds(), [padItem1], []), isState: false)));
        await r1.Pc.WaitForOutgoingAsync();
        Assert.IsType<TemplateSyncStateMessage>(Assert.Single(pad1.DrainTemplates()));
        await pad1.SendTemplateAsync(new TemplateSyncAck(pull1.Op));

        var res1 = await sync1.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(TemplateSyncRunStatus.Completed, res1.Status);
        Assert.Equal(1, res1.SucceededDevices);
        Assert.Equal(1, res1.FailedDevices);
        Assert.True(res1.PcSaved);
        Assert.Single(await r1.Pc.GetTemplatesAsync());

        // 2. Two devices: both respond in Phase 1, phone disconnects in Phase 2 before tpl_ack.
        var r2 = new Rig(this);
        var pad2 = await r2.ConnectAsync(512);
        var phone2 = await r2.ConnectAsync(512, deviceId: Guid.NewGuid(), kind: "phone");
        var sync2 = r2.Pc.SyncTemplatesAsync();
        await r2.Pc.WaitForOutgoingAsync();
        var pull2 = Assert.IsType<TemplateSyncPull>(Assert.Single(pad2.DrainTemplates()));
        phone2.DrainTemplates();

        await pad2.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            pull2.Op,
            new TemplateSyncSnapshot(r2.Now.ToUnixTimeMilliseconds(),
                [new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "pad-2", null, null, 0, r2.Now.ToUnixTimeMilliseconds())], []),
            isState: false)));
        await phone2.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            pull2.Op,
            new TemplateSyncSnapshot(r2.Now.ToUnixTimeMilliseconds(),
                [new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "phone-2", null, null, 0, r2.Now.ToUnixTimeMilliseconds())], []),
            isState: false)));
        await r2.Pc.WaitForOutgoingAsync();
        Assert.IsType<TemplateSyncStateMessage>(Assert.Single(pad2.DrainTemplates()));
        Assert.IsType<TemplateSyncStateMessage>(Assert.Single(phone2.DrainTemplates()));

        await r2.Pc.DisconnectAsync(phone2.Peer);
        await pad2.SendTemplateAsync(new TemplateSyncAck(pull2.Op));
        var res2 = await sync2.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(TemplateSyncRunStatus.Completed, res2.Status);
        Assert.Equal(1, res2.SucceededDevices);
        Assert.Equal(1, res2.FailedDevices);
        Assert.True(res2.PcSaved);
        Assert.Equal(2, (await r2.Pc.GetTemplatesAsync()).Count);

        // 3. Single device disconnects in Phase 1 -> nothing saved, Disconnected result.
        var r3 = new Rig(this);
        await r3.Pc.CreateTemplateAsync("unchanged", null, null);
        var pad3 = await r3.ConnectAsync(512);
        var sync3 = r3.Pc.SyncTemplatesAsync();
        await r3.Pc.WaitForOutgoingAsync();
        pad3.DrainTemplates();
        await r3.Pc.DisconnectAsync(pad3.Peer);
        var res3 = await sync3.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(TemplateSyncRunStatus.Disconnected, res3.Status);
        Assert.False(res3.PcSaved);
        Assert.Single(await r3.Pc.GetTemplatesAsync());
    }

    [Fact]
    public async Task PcInitiatedSyncTimeoutsAt30SecondsAndLargeIncomingFrameExtendsDeadline()
    {
        // 1. Partial timeout: silent phone times out at >30s, pad finishes.
        var r = new Rig(this);
        var pad = await r.ConnectAsync(512);
        var silentPhone = await r.ConnectAsync(512, deviceId: Guid.NewGuid(), kind: "phone");

        var syncTask = r.Pc.SyncTemplatesAsync();
        await r.Pc.WaitForOutgoingAsync();
        var pull = Assert.IsType<TemplateSyncPull>(Assert.Single(pad.DrainTemplates()));
        silentPhone.DrainTemplates();

        var padItem = new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "pad-ok", null, null, 0, r.Now.ToUnixTimeMilliseconds());
        await pad.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            pull.Op, new TemplateSyncSnapshot(r.Now.ToUnixTimeMilliseconds(), [padItem], []), isState: false)));

        // At +29s still waiting on silentPhone.
        r.Now = r.Now.AddSeconds(29);
        await r.Pc.TickAsync(r.Now);
        await r.Pc.WaitForOutgoingAsync();
        Assert.False(syncTask.IsCompleted);
        Assert.Empty(pad.DrainTemplates());

        // At +31s silentPhone times out, PC merges pad's push and sends tpl_state to pad!
        r.Now = r.Now.AddSeconds(2);
        await r.Pc.TickAsync(r.Now);
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        Assert.False(silentPhone.Peer.Rejected); // Does not break healthy BLE link.
        Assert.IsType<TemplateSyncStateMessage>(Assert.Single(pad.DrainTemplates()));
        await pad.SendTemplateAsync(new TemplateSyncAck(pull.Op));
        var partialResult = await syncTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(TemplateSyncRunStatus.Completed, partialResult.Status);
        Assert.Equal(1, partialResult.SucceededDevices);
        Assert.Equal(1, partialResult.FailedDevices);

        // 2. Large multi-packet tpl_push frame arriving slowly past 30s extends deadline instead of timing out!
        r.Now = r.Now.AddSeconds(5);
        var largeSyncTask = r.Pc.SyncTemplatesAsync();
        await r.Pc.WaitForOutgoingAsync();
        var largePull = Assert.IsType<TemplateSyncPull>(Assert.Single(pad.DrainTemplates()));
        silentPhone.DrainTemplates();

        // Timeout silentPhone cleanly on this check or disconnect silentPhone to isolate extension test.
        await r.Pc.DisconnectAsync(silentPhone.Peer);
        var largeItem = new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, new string('L', 3000), null, null, 0, r.Now.ToUnixTimeMilliseconds());
        var largePush = Assert.Single(TemplateSyncMessageCodec.SplitPages(
            largePull.Op, new TemplateSyncSnapshot(r.Now.ToUnixTimeMilliseconds(), [padItem, largeItem], []), isState: false));
        var packets = SyncPacketizer.Split(pad.SealTemplate(largePush), 200);
        Assert.True(packets.Count >= 6);

        for (var i = 0; i < packets.Count - 1; i++)
        {
            r.Now = r.Now.AddSeconds(10);
            Assert.True(await r.Pc.ReceiveAsync(pad.Peer, packets[i]));
            await r.Pc.TickAsync(r.Now);
            Assert.False(largeSyncTask.IsCompleted);
        }
        // Even though >50s elapsed since tpl_pull, large frame packets extended deadline.
        r.Now = r.Now.AddSeconds(10);
        Assert.True(await r.Pc.ReceiveAsync(pad.Peer, packets[^1]));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        Assert.IsType<TemplateSyncStateMessage>(Assert.Single(pad.DrainTemplates()));
        await pad.SendTemplateAsync(new TemplateSyncAck(largePull.Op));
        var largeRes = await largeSyncTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(TemplateSyncRunStatus.Completed, largeRes.Status);
        Assert.Equal(2, (await r.Pc.GetTemplatesAsync()).Count);
    }

    [Fact]
    public async Task Version2PeerReceivesMismatchRequiresUpdateAndDoesNotDisruptTemplateSync()
    {
        var r = new Rig(this);
        byte[] V2Hello(Guid id) => [1, 2, .. id.ToByteArray(bigEndian: true), .. new byte[32]];

        var v2Peer = new FakePeer { PacketLimit = 512 };
        await r.Pc.ConnectAsync(v2Peer);
        await r.SendFrameAsync(v2Peer, V2Hello(r.DeviceId));
        Assert.True(v2Peer.Rejected);
        var mismatch = Assert.Single(v2Peer.DrainFrames());
        Assert.Equal(SyncProtocol.Version, mismatch[1]);
        Assert.True(r.State.RequiresPeerUpdate);

        // With 0 v3 devices connected, SyncTemplatesAsync reports PeerUpdateRequired.
        var updateResult = await r.Pc.SyncTemplatesAsync();
        Assert.Equal(TemplateSyncRunStatus.PeerUpdateRequired, updateResult.Status);

        // A connected v3 device still syncs templates normally.
        var v3Phone = await r.ConnectAsync(512, deviceId: Guid.NewGuid(), kind: "phone");
        var syncTask = r.Pc.SyncTemplatesAsync();
        await r.Pc.WaitForOutgoingAsync(v3Phone.Peer);
        var pull = Assert.IsType<TemplateSyncPull>(Assert.Single(v3Phone.DrainTemplates()));
        await v3Phone.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            pull.Op,
            new TemplateSyncSnapshot(r.Now.ToUnixTimeMilliseconds(),
                [new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "from-v3", null, null, 0, r.Now.ToUnixTimeMilliseconds())], []),
            isState: false)));
        Assert.IsType<TemplateSyncStateMessage>(Assert.Single(v3Phone.DrainTemplates()));
        await v3Phone.SendTemplateAsync(new TemplateSyncAck(pull.Op));
        Assert.Equal(TemplateSyncRunStatus.Completed, (await syncTask).Status);

        // Once the v2 device upgrades and connects with v3 handshake, RequiresPeerUpdate clears.
        var upgradedPad = await r.ConnectAsync(512, deviceId: r.DeviceId);
        Assert.False(r.State.RequiresPeerUpdate);
        var sync2 = r.Pc.SyncTemplatesAsync();
        await r.Pc.WaitForOutgoingAsync();
        var pullPad = Assert.IsType<TemplateSyncPull>(Assert.Single(upgradedPad.DrainTemplates()));
        var pullPhone = Assert.IsType<TemplateSyncPull>(Assert.Single(v3Phone.DrainTemplates()));
        await upgradedPad.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            pullPad.Op, new TemplateSyncSnapshot(r.Now.ToUnixTimeMilliseconds(), [], []), isState: false)));
        await v3Phone.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            pullPhone.Op,
            new TemplateSyncSnapshot(r.Now.ToUnixTimeMilliseconds(),
                [new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "from-v3", null, null, 0, r.Now.ToUnixTimeMilliseconds())], []),
            isState: false)));
        await r.Pc.WaitForOutgoingAsync();
        Assert.Single(upgradedPad.DrainTemplates().OfType<TemplateSyncStateMessage>());
        Assert.Single(v3Phone.DrainTemplates().OfType<TemplateSyncStateMessage>());
        await upgradedPad.SendTemplateAsync(new TemplateSyncAck(pullPad.Op));
        await v3Phone.SendTemplateAsync(new TemplateSyncAck(pullPhone.Op));
        Assert.Equal(2, (await sync2).SucceededDevices);
    }

    [Fact]
    public async Task TemplateSyncPreemptsQueuedAttachmentAndDoesNotAlterTransferState()
    {
        var r = new Rig(this);
        var pad = await r.ConnectAsync(512);
        var data = new byte[SyncProtocol.ChunkBytes * 5 + 13];
        data[^1] = 77;

        await r.Pc.ClipboardChangedAsync(new(1, null, false, [new("file", Filename: "big.bin", Data: data)]));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        var offer = Assert.IsType<SyncOffer>(Assert.Single(pad.DrainAll()));
        Assert.Null(r.State.LastReceived);

        // Start attachment window and pause mid-send on chunk 0.
        var chunk0Entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var chunk0Release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        pad.Peer.OnSend = _ => { chunk0Entered.TrySetResult(); return chunk0Release.Task; };
        Task<TemplateSyncRunResult> syncTask;
        object[] batch;
        try
        {
            foreach (var pkt in SyncPacketizer.Split(pad.Seal(new SyncResume(offer.Id, 0)), pad.Peer.PacketLimit))
                Assert.True(await r.Pc.ReceiveAsync(pad.Peer, pkt));
            await chunk0Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));

            // Queue a pending text item behind the attachment AND trigger template sync while chunk 0 is sending.
            await r.Pc.ClipboardChangedAsync(new(2, "queued-behind-attachment", false));
            syncTask = r.Pc.SyncTemplatesAsync();
        }
        finally
        {
            pad.Peer.OnSend = null;
            chunk0Release.TrySetResult();
        }
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        batch = pad.DrainAll();

        var pull = Assert.Single(batch.OfType<TemplateSyncPull>());
        var textSent = Assert.Single(batch.OfType<SyncItem>());
        var firstWindow = batch.OfType<SyncChunk>().ToArray();
        Assert.Equal(4, firstWindow.Length);
        Assert.Equal("queued-behind-attachment", textSent.Text);
        // tpl_pull preempts BOTH the remaining chunks (chunks 1..3) AND the queued text item!
        Assert.True(Array.IndexOf(batch, pull) < Array.IndexOf(batch, firstWindow[1]));
        Assert.True(Array.IndexOf(batch, pull) < Array.IndexOf(batch, textSent));

        await pad.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            pull.Op,
            new TemplateSyncSnapshot(r.Now.ToUnixTimeMilliseconds(),
                [new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "urgent-tpl", null, null, 0, r.Now.ToUnixTimeMilliseconds())], []),
            isState: false)));
        Assert.IsType<TemplateSyncStateMessage>(Assert.Single(pad.DrainAll()));
        await pad.SendTemplateAsync(new TemplateSyncAck(pull.Op));
        Assert.Equal(TemplateSyncRunStatus.Completed, (await syncTask).Status);

        // Attachment state remained completely intact and finishes cleanly.
        Assert.Null(r.State.LastReceived);
        await pad.SendAsync(new SyncResume(offer.Id, SyncProtocol.ChunkBytes * 4));
        var remaining = pad.DrainAll().Cast<SyncChunk>().ToArray();
        Assert.Equal(2, remaining.Length);
        await pad.SendAsync(new SyncAck([offer.Id, textSent.Id]));
        Assert.Equal(0, r.State.Pending);
    }

    [Fact]
    public async Task CopyTemplateSuppressesEchoAndMoveHistoryToTemplatesValidatesKindsAndDuplicates()
    {
        var r = new Rig(this);
        var pad = await r.ConnectAsync(512);

        var tpl = (await r.Pc.CreateTemplateAsync("定型文コピーテスト", "定型", "仕事")).Item!;
        await r.Pc.CopyTemplateAsync(tpl.Id);
        Assert.Equal(["定型文コピーテスト"], r.Clipboard.Writes);

        // Clipboard event with ownSequence is ignored (neither added to history nor sent to peer).
        await r.Pc.ClipboardChangedAsync(new(r.Clipboard.Sequence, tpl.Text, false));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        Assert.Empty(await r.Pc.GetHistoryAsync());
        Assert.Empty(pad.DrainAll());

        // External copy of another text adds to history and syncs.
        await r.Pc.ClipboardChangedAsync(new(r.Clipboard.Sequence + 1, "普通の履歴", false));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        var histItem = Assert.Single(await r.Pc.GetHistoryAsync());
        var sentItem = Assert.IsType<SyncItem>(Assert.Single(pad.DrainAll()));
        await pad.SendAsync(new SyncAck([sentItem.Id]));

        // Duplicate move refuses without deleting history.
        await r.Pc.ClipboardChangedAsync(new(r.Clipboard.Sequence + 2, tpl.Text, false));
        await r.Pc.WaitForOutgoingAsync(pad.Peer);
        var dupHist = (await r.Pc.GetHistoryAsync()).First(i => i.Text == tpl.Text);
        var dupMove = await r.Pc.MoveHistoryToTemplatesAsync(dupHist.Id);
        Assert.Equal(TemplateEditError.Duplicate, dupMove.Error);
        Assert.Contains(await r.Pc.GetHistoryAsync(), i => i.Id == dupHist.Id);

        // Image history cannot be moved to templates.
        await r.Pc.AddLocalContentsAsync([new("image", Data: [137, 80, 78, 71], Type: "public.png")]);
        var imgHist = (await r.Pc.GetHistoryAsync()).First(i => i.Kind == "image");
        var imgMove = await r.Pc.MoveHistoryToTemplatesAsync(imgHist.Id);
        Assert.Equal(TemplateEditError.UnsupportedKind, imgMove.Error);

        // Valid text history moves to templates ("その他") and leaves history.
        var moved = await r.Pc.MoveHistoryToTemplatesAsync(histItem.Id);
        Assert.True(moved.Succeeded);
        Assert.Null(moved.Item!.Tag);
        Assert.DoesNotContain(await r.Pc.GetHistoryAsync(), i => i.Id == histItem.Id);
        Assert.Contains(await r.Pc.GetTemplatesAsync(), t => t.Text == "普通の履歴");
        Assert.DoesNotContain(r.Logs, l => l.Contains("定型文コピーテスト") || l.Contains("普通の履歴") || l.Contains(r.Pairing.ToQrString()));
    }

    [Fact]
    public async Task PcInitiatedSyncTwoDevicesPreservesBothEditsAndLoserTextWhenSecondDeviceOverwrites()
    {
        // 1. Two devices edit the same template differently while PC keeps original -> neither edit is lost.
        {
            var r = new Rig(this);
            var pad = await r.ConnectAsync(512);
            var phone = await r.ConnectAsync(512, deviceId: Guid.NewGuid(), kind: "phone");

            var sharedId = Guid.NewGuid();
            var origHash = TemplateSyncMerge.ContentHash(TemplateSyncKind.Text, "元の本文", "共有", "仕事");
            var t0 = r.Now.ToUnixTimeMilliseconds();
            r.Templates.ApplyMerged([
                new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "元の本文", "共有", "仕事", 0, t0),
            ], []);

            var syncTask = r.Pc.SyncTemplatesAsync();
            await r.Pc.WaitForOutgoingAsync();
            var pull = Assert.IsType<TemplateSyncPull>(Assert.Single(pad.DrainTemplates()));
            phone.DrainTemplates();

            await pad.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
                pull.Op,
                new TemplateSyncSnapshot(
                    t0,
                    [new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "iPadで書き直した本文", "共有", "仕事", 0, t0 + 10_000, origHash)],
                    []),
                isState: false)));
            await phone.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
                pull.Op,
                new TemplateSyncSnapshot(
                    t0,
                    [new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "iPhoneで書き直した本文", "共有", "仕事", 0, t0 + 20_000, origHash)],
                    []),
                isState: false)));
            await r.Pc.WaitForOutgoingAsync();

            var padState = Assert.IsType<TemplateSyncStateMessage>(Assert.Single(pad.DrainTemplates()));
            var phoneState = Assert.IsType<TemplateSyncStateMessage>(Assert.Single(phone.DrainTemplates()));
            Assert.Equal(padState.Page.Templates, phoneState.Page.Templates);
            Assert.Equal(2, padState.Page.Templates.Count);
            Assert.Contains(padState.Page.Templates, t => t.Id == sharedId && t.Text == "iPhoneで書き直した本文" && t.Tag == "仕事");
            Assert.Contains(padState.Page.Templates, t => t.Text == "iPadで書き直した本文" && t.Tag is null && t.Title == "共有（別の端末の編集）");

            await pad.SendTemplateAsync(new TemplateSyncAck(pull.Op));
            await phone.SendTemplateAsync(new TemplateSyncAck(pull.Op));
            var result = await syncTask.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Equal(TemplateSyncRunStatus.Completed, result.Status);
            Assert.Equal(1, result.ConflictCopyCount);
            Assert.Equal(2, (await r.Pc.GetTemplatesAsync()).Count);
        }

        // 2. Multi-device MergeAll preserves loser text even when another device overwrites the item holding that text,
        //    independently of DeviceId ordering.
        IReadOnlyList<TemplateSyncItem>? firstOrderTemplates = null;
        foreach (var padIdFirst in new[] { true, false })
        {
            var r = new Rig(this);
            var idSmall = Guid.Parse("11111111-1111-4111-8111-111111111111");
            var idLarge = Guid.Parse("22222222-2222-4222-8222-222222222222");
            var pad = await r.ConnectAsync(512, deviceId: padIdFirst ? idSmall : idLarge, kind: "pad");
            var phone = await r.ConnectAsync(512, deviceId: padIdFirst ? idLarge : idSmall, kind: "phone");

            var tplId1 = Guid.Parse("44444444-5555-4666-8777-888888888881");
            var tplId2 = Guid.Parse("44444444-5555-4666-8777-888888888882");
            var hOrig1 = TemplateSyncMerge.ContentHash(TemplateSyncKind.Text, "orig1", null, null);
            var hTextA = TemplateSyncMerge.ContentHash(TemplateSyncKind.Text, "textA", null, null);
            var nowMs = r.Now.ToUnixTimeMilliseconds();

            r.Templates.ApplyMerged([
                new TemplateSyncItem(tplId1, TemplateSyncKind.Text, "textPC", null, null, 0, nowMs - 20_000),
                new TemplateSyncItem(tplId2, TemplateSyncKind.Text, "textA", null, null, 1, nowMs - 100_000),
            ], []);

            var syncTask = r.Pc.SyncTemplatesAsync();
            await r.Pc.WaitForOutgoingAsync();
            var pull = Assert.IsType<TemplateSyncPull>(Assert.Single(pad.DrainTemplates()));
            phone.DrainTemplates();

            await pad.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
                pull.Op,
                new TemplateSyncSnapshot(
                    nowMs,
                    [new TemplateSyncItem(tplId1, TemplateSyncKind.Text, "textA", null, null, 0, nowMs - 30_000, hOrig1)],
                    []),
                isState: false)));
            await phone.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
                pull.Op,
                new TemplateSyncSnapshot(
                    nowMs,
                    [
                        new TemplateSyncItem(tplId1, TemplateSyncKind.Text, "orig1", null, null, 0, nowMs - 100_000, hOrig1),
                        new TemplateSyncItem(tplId2, TemplateSyncKind.Text, "textB", null, null, 1, nowMs - 10_000, hTextA),
                    ],
                    []),
                isState: false)));
            await r.Pc.WaitForOutgoingAsync();

            var padState = Assert.IsType<TemplateSyncStateMessage>(Assert.Single(pad.DrainTemplates()));
            var phoneState = Assert.IsType<TemplateSyncStateMessage>(Assert.Single(phone.DrainTemplates()));
            Assert.Equal(padState.Page.Templates, phoneState.Page.Templates);
            Assert.Equal(3, padState.Page.Templates.Count);
            Assert.Contains(padState.Page.Templates, t => t.Id == tplId1 && t.Text == "textPC");
            Assert.Contains(padState.Page.Templates, t => t.Id == tplId2 && t.Text == "textB");
            Assert.Contains(padState.Page.Templates, t => t.Text == "textA" && t.Title == "別の端末の編集");

            await pad.SendTemplateAsync(new TemplateSyncAck(pull.Op));
            await phone.SendTemplateAsync(new TemplateSyncAck(pull.Op));
            var result = await syncTask.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Equal(TemplateSyncRunStatus.Completed, result.Status);
            Assert.Equal(1, result.ConflictCopyCount);

            if (firstOrderTemplates is null)
                firstOrderTemplates = padState.Page.Templates;
            else
                Assert.Equal(firstOrderTemplates, padState.Page.Templates);
        }
    }

    [Fact]
    public async Task TemplateSyncUsesSentAtForTombstoneClockConversionInBothPcAndPeerInitiatedSync()
    {
        var r = new Rig(this);
        var pad = await r.ConnectAsync(512);
        var nowMs = r.Now.ToUnixTimeMilliseconds();
        var dayMs = 24L * 60 * 60 * 1000;

        // 1. Peer-initiated (iOS) sync: 181-day slow clock tombstone is converted using sentAt,
        //    while an already-known PC tombstone keeps PC's deletedAt.
        var itemA = new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "delete-via-slow-clock", null, null, 0, nowMs - 400 * dayMs);
        var existingTomb = new TemplateSyncTombstone(Guid.NewGuid(), nowMs - 10 * dayMs, TemplateSyncMerge.ContentHash(TemplateSyncKind.Text, "old-deleted", null, null));
        r.Templates.ApplyMerged([itemA], [existingTomb]);

        var peerSentAt = nowMs - 181 * dayMs;
        var peerOp = Guid.NewGuid();
        await pad.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            peerOp,
            new TemplateSyncSnapshot(
                peerSentAt,
                [],
                [
                    new TemplateSyncTombstone(itemA.Id, peerSentAt - 5_000, TemplateSyncMerge.ContentHash(itemA)),
                    new TemplateSyncTombstone(existingTomb.Id, nowMs - 10 * dayMs, existingTomb.BaseHash),
                ]),
            isState: false)));
        await r.Pc.WaitForOutgoingAsync();

        var peerState = Assert.IsType<TemplateSyncStateMessage>(Assert.Single(pad.DrainTemplates()));
        Assert.Empty(peerState.Page.Templates);
        var returnedItemATomb = Assert.Single(peerState.Page.Tombstones, t => t.Id == itemA.Id);
        Assert.Equal(nowMs - 5_000, returnedItemATomb.DeletedAt);
        var returnedExisting = Assert.Single(peerState.Page.Tombstones, t => t.Id == existingTomb.Id);
        Assert.Equal(existingTomb.DeletedAt, returnedExisting.DeletedAt);
        Assert.Empty(await r.Pc.GetTemplatesAsync());
        Assert.Contains(r.Logs, l => l.Contains("template sync clock-skew seconds="));
        await pad.SendTemplateAsync(new TemplateSyncAck(peerOp));

        // 2. PC-initiated sync: slow-clock phone deletes itemB using sentAt conversion while pad still holds unedited itemB.
        var phone = await r.ConnectAsync(512, deviceId: Guid.NewGuid(), kind: "phone");
        var itemB = new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "pc-initiated-slow-delete", null, null, 0, nowMs - 400 * dayMs);
        var hashB = TemplateSyncMerge.ContentHash(itemB);
        r.Templates.ApplyMerged([itemB], []);

        var syncTask = r.Pc.SyncTemplatesAsync();
        await r.Pc.WaitForOutgoingAsync();
        var pull = Assert.IsType<TemplateSyncPull>(Assert.Single(pad.DrainTemplates()));
        phone.DrainTemplates();

        await pad.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            pull.Op,
            new TemplateSyncSnapshot(nowMs, [itemB with { BaseHash = hashB }], []),
            isState: false)));
        await phone.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            pull.Op,
            new TemplateSyncSnapshot(peerSentAt, [], [new TemplateSyncTombstone(itemB.Id, peerSentAt - 4_000, hashB)]),
            isState: false)));
        await r.Pc.WaitForOutgoingAsync();

        var padState2 = Assert.IsType<TemplateSyncStateMessage>(Assert.Single(pad.DrainTemplates()));
        var phoneState2 = Assert.IsType<TemplateSyncStateMessage>(Assert.Single(phone.DrainTemplates()));
        Assert.Empty(padState2.Page.Templates);
        Assert.Empty(phoneState2.Page.Templates);
        Assert.Contains(padState2.Page.Tombstones, t => t.Id == itemB.Id && t.DeletedAt == nowMs - 4_000);

        await pad.SendTemplateAsync(new TemplateSyncAck(pull.Op));
        await phone.SendTemplateAsync(new TemplateSyncAck(pull.Op));
        var res = await syncTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(TemplateSyncRunStatus.Completed, res.Status);
        Assert.Equal(1, res.PcDeleted);
        Assert.True(res.ClockSkewSeconds >= 180 * 24 * 60 * 60);
    }

    [Fact]
    public async Task PcOverflowTemplatesAreExcludedFromSyncSnapshotPreservedLocallyAndReported()
    {
        var r = new Rig(this);
        var pad = await r.ConnectAsync(512);
        var nowMs = r.Now.ToUnixTimeMilliseconds();

        // Single item whose escaped JSON exceeds 256 KiB page body (64 KiB of control characters)
        // plus one normal syncable item.
        var unSyncable = new TemplateSyncItem(
            Guid.NewGuid(),
            TemplateSyncKind.Text,
            new string('\u0001', SyncProtocol.MaxTemplateTextBytes),
            "制御のみ",
            "特殊",
            0,
            nowMs);
        var syncable = new TemplateSyncItem(
            Guid.NewGuid(),
            TemplateSyncKind.Text,
            "通常の定型文",
            "挨拶",
            "仕事",
            0,
            nowMs + 1);
        r.Templates.ApplyMerged([unSyncable, syncable], []);

        // 1. PC-initiated sync excludes unSyncable from wire snapshot, preserves both locally, and reports ExcludedTemplateCount=1.
        var syncTask = r.Pc.SyncTemplatesAsync();
        await r.Pc.WaitForOutgoingAsync();
        var pull = Assert.IsType<TemplateSyncPull>(Assert.Single(pad.DrainTemplates()));

        var remoteAdded = new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "iPad新規", null, "仕事", 0, nowMs + 2);
        await pad.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            pull.Op,
            new TemplateSyncSnapshot(nowMs, [syncable with { BaseHash = TemplateSyncMerge.ContentHash(syncable) }, remoteAdded], []),
            isState: false)));
        await r.Pc.WaitForOutgoingAsync();

        var padState = Assert.IsType<TemplateSyncStateMessage>(Assert.Single(pad.DrainTemplates()));
        Assert.Equal(2, padState.Page.Templates.Count);
        Assert.DoesNotContain(padState.Page.Templates, t => t.Id == unSyncable.Id);

        await pad.SendTemplateAsync(new TemplateSyncAck(pull.Op));
        var result = await syncTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(TemplateSyncRunStatus.Completed, result.Status);
        Assert.Equal(1, result.ExcludedTemplateCount);
        Assert.Equal(1, result.PcAdded);
        Assert.Equal(0, result.PcDeleted);

        var notice = TemplateWindowLogic.FormatSyncNotice(result);
        Assert.NotNull(notice);
        Assert.True(notice!.Value.IsWarning);
        Assert.Contains("対象外", notice.Value.Message);

        var localAfter = await r.Pc.GetTemplatesAsync();
        Assert.Equal(3, localAfter.Count);
        Assert.Contains(localAfter, t => t.Id == unSyncable.Id);
        Assert.Contains(localAfter, t => t.Id == syncable.Id);
        Assert.Contains(localAfter, t => t.Id == remoteAdded.Id);

        // 2. Peer-initiated sync also preserves unSyncable locally without failing or deleting it.
        var peerOp = Guid.NewGuid();
        await pad.SendTemplateAsync(Assert.Single(TemplateSyncMessageCodec.SplitPages(
            peerOp,
            new TemplateSyncSnapshot(
                nowMs + 5,
                padState.Page.Templates.Select(t => t with { BaseHash = TemplateSyncMerge.ContentHash(t) }).ToArray(),
                []),
            isState: false)));
        await r.Pc.WaitForOutgoingAsync();
        var peerReply = Assert.IsType<TemplateSyncStateMessage>(Assert.Single(pad.DrainTemplates()));
        Assert.Equal(2, peerReply.Page.Templates.Count);
        await pad.SendTemplateAsync(new TemplateSyncAck(peerOp));
        Assert.Equal(3, (await r.Pc.GetTemplatesAsync()).Count);
        Assert.Contains(await r.Pc.GetTemplatesAsync(), t => t.Id == unSyncable.Id);

        // 3. Combined merge exceeding 80-page / 20 MiB budget aborts with LimitExceeded without overwriting local state.
        var pc150 = Enumerable.Range(0, 150)
            .Select(i => new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, $"pc-{i:D3}-" + new string('a', SyncProtocol.MaxTemplateTextBytes - 7), null, null, i, nowMs))
            .ToArray();
        var remote150 = Enumerable.Range(0, 150)
            .Select(i => new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, $"rm-{i:D3}-" + new string('b', SyncProtocol.MaxTemplateTextBytes - 7), null, null, i, nowMs))
            .ToArray();
        r.Templates.ApplyMerged(pc150, []);

        var limitSync = r.Pc.SyncTemplatesAsync();
        await r.Pc.WaitForOutgoingAsync();
        var limitPull = Assert.IsType<TemplateSyncPull>(Assert.Single(pad.DrainTemplates()));
        var limitPages = TemplateSyncMessageCodec.SplitPages(
            limitPull.Op,
            new TemplateSyncSnapshot(nowMs, remote150, []),
            isState: false);
        foreach (var page in limitPages)
            await pad.SendTemplateAsync(page);

        var limitResult = await limitSync.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(TemplateSyncRunStatus.LimitExceeded, limitResult.Status);
        Assert.False(limitResult.PcSaved);
        Assert.Equal(150, (await r.Pc.GetTemplatesAsync()).Count);
    }
}
