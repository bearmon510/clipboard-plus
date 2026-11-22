using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Channels;
using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class WifiCoordinatorTests : IDisposable
{
    private readonly List<string> tempRoots = [];

    public void Dispose()
    {
        foreach (var root in tempRoots)
        {
            try { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
            catch { }
        }
    }

    private string NewRoot()
    {
        var path = Path.Combine(Path.GetTempPath(), "clipboardplus-wifi-tests", Guid.NewGuid().ToString("N"));
        tempRoots.Add(path);
        return path;
    }

    private static byte[] MakeBytes(int length, byte seed = 0x3D)
    {
        var data = new byte[length];
        for (var i = 0; i < length; i++)
            data[i] = (byte)((i * 29 + seed) & 0xFF);
        return data;
    }

    private static SyncOffer MakeOffer(Guid id, string from, byte[] data, string filename = "photo.bin", string kind = "file", string type = "public.data", string? overrideSha256 = null) =>
        new(
            id,
            1_795_000_000_000L,
            from,
            kind,
            data.Length,
            overrideSha256 ?? Convert.ToHexStringLower(SHA256.HashData(data)),
            Convert.ToBase64String(Encoding.UTF8.GetBytes(filename)),
            type);

    private sealed class FakePeer : ISyncPeer
    {
        private readonly object gate = new();
        private readonly List<byte[]> packets = [];
        private TaskCompletionSource packetArrived = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public int PacketLimit { get; set; } = 512;
        public bool Rejected { get; private set; }
        bool ISyncPeer.IsRejected => Rejected;

        public Task SendPacketAsync(byte[] packet)
        {
            Assert.False(Rejected);
            lock (gate)
            {
                packets.Add(packet.ToArray());
                packetArrived.TrySetResult();
            }
            return Task.CompletedTask;
        }

        public void Reject() => Rejected = true;

        public byte[][] DrainFrames()
        {
            byte[][] snapshot;
            lock (gate)
            {
                snapshot = packets.ToArray();
                packets.Clear();
                packetArrived = new(TaskCreationOptions.RunContinuationsAsynchronously);
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

        public async Task WaitForPacketAsync(TimeSpan timeout)
        {
            Task wait;
            lock (gate)
            {
                if (packets.Count > 0) return;
                wait = packetArrived.Task;
            }
            await wait.WaitAsync(timeout);
        }
    }

    private sealed class FakeClipboard : IClipboardAccess
    {
        public uint Sequence = 100;
        public readonly List<string> TextWrites = [];
        public readonly List<HistoryItem> MediaWrites = [];

        public Task<uint> WriteItemAsync(HistoryItem item)
        {
            if (item.Kind == "text") return WriteTextAsync(item.Text!);
            MediaWrites.Add(item);
            return Task.FromResult(++Sequence);
        }

        public Task<uint> WriteTextAsync(string text)
        {
            TextWrites.Add(text);
            return Task.FromResult(++Sequence);
        }
    }

    private sealed class DuplexPipe
    {
        public PipeStream PadEnd { get; }
        public PipeStream PcEnd { get; }

        public DuplexPipe(int? cutPadToPcAfterBytes = null)
        {
            var padToPc = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true });
            var pcToPad = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true });
            PadEnd = new PipeStream(pcToPad.Reader, padToPc.Writer, cutPadToPcAfterBytes);
            PcEnd = new PipeStream(padToPc.Reader, pcToPad.Writer, cutAfterBytes: null);
        }

        public sealed class PipeStream(ChannelReader<byte[]> reader, ChannelWriter<byte[]> writer, int? cutAfterBytes) : Stream
        {
            private byte[]? current;
            private int currentOffset;
            private int written;
            private bool closed;

            public void CloseWrite()
            {
                if (!closed)
                {
                    closed = true;
                    writer.TryComplete();
                }
            }

            public override bool CanRead => true;
            public override bool CanSeek => false;
            public override bool CanWrite => true;
            public override long Length => throw new NotSupportedException();
            public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
            public override void Flush() { }
            public override Task FlushAsync(CancellationToken cancellationToken) => Task.CompletedTask;
            public override int Read(byte[] buffer, int offset, int count) => ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();
            public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
            public override void SetLength(long value) => throw new NotSupportedException();
            public override void Write(byte[] buffer, int offset, int count) => WriteAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();

            public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
            {
                while (current is null || currentOffset >= current.Length)
                {
                    if (!await reader.WaitToReadAsync(cancellationToken).ConfigureAwait(false))
                        return 0;
                    if (!reader.TryRead(out current))
                        continue;
                    currentOffset = 0;
                }
                var take = Math.Min(buffer.Length, current.Length - currentOffset);
                current.AsSpan(currentOffset, take).CopyTo(buffer.Span);
                currentOffset += take;
                return take;
            }

            public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
            {
                if (closed) throw new IOException("Pipe closed");
                var chunk = buffer.ToArray();
                if (cutAfterBytes is int limit)
                {
                    var remaining = limit - written;
                    if (remaining <= 0)
                    {
                        CloseWrite();
                        throw new IOException("Simulated cut");
                    }
                    if (chunk.Length >= remaining)
                    {
                        if (remaining > 0) writer.TryWrite(chunk[..remaining]);
                        written += remaining;
                        CloseWrite();
                        return ValueTask.CompletedTask;
                    }
                }
                if (chunk.Length > 0)
                {
                    written += chunk.Length;
                    writer.TryWrite(chunk);
                }
                return ValueTask.CompletedTask;
            }

            protected override void Dispose(bool disposing)
            {
                if (disposing) CloseWrite();
                base.Dispose(disposing);
            }
        }
    }

    private sealed class ControlledDelay
    {
        public sealed class PendingWait(TimeSpan duration)
        {
            public TimeSpan Duration { get; } = duration;
            private readonly TaskCompletionSource tcs = new(TaskCreationOptions.RunContinuationsAsynchronously);
            public Task Task => tcs.Task;
            public void Trigger() => tcs.TrySetResult();
            public void Cancel(CancellationToken ct) => tcs.TrySetCanceled(ct);
        }

        private readonly object gate = new();
        private readonly List<PendingWait> waits = [];
        private readonly List<(TimeSpan Expected, TaskCompletionSource<PendingWait> Waiter)> waiters = [];

        public Task DelayAsync(TimeSpan duration, CancellationToken ct)
        {
            if (ct.IsCancellationRequested) return Task.FromCanceled(ct);
            var pending = new PendingWait(duration);
            ct.Register(() => pending.Cancel(ct));
            lock (gate)
            {
                waits.Add(pending);
                for (var i = waiters.Count - 1; i >= 0; i--)
                {
                    if (waiters[i].Expected == duration)
                    {
                        waiters[i].Waiter.TrySetResult(pending);
                        waiters.RemoveAt(i);
                    }
                }
            }
            return pending.Task;
        }

        public Task<PendingWait> WaitForRequestedDelayAsync(TimeSpan expected)
        {
            lock (gate)
            {
                var existing = waits.LastOrDefault(w => w.Duration == expected && !w.Task.IsCompleted);
                if (existing is not null)
                    return Task.FromResult(existing);
                var tcs = new TaskCompletionSource<PendingWait>(TaskCreationOptions.RunContinuationsAsynchronously);
                waiters.Add((expected, tcs));
                return tcs.Task;
            }
        }
    }

    private sealed class FakeWifiSessionHandle : IWifiTransferSessionHandle
    {
        private readonly TaskCompletionSource<WifiAcceptedConnection> acceptTcs = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource acceptStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource disposedTcs = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TcpListener? loopbackListener;
        private int disposedFlag;

        public WifiApMode Mode { get; }
        public string ActualSsid { get; }
        public string Ip { get; }
        public int Port { get; }
        public bool IsDisposed => Volatile.Read(ref disposedFlag) != 0;
        public Task AcceptStarted => acceptStarted.Task;
        public Task Disposed => disposedTcs.Task;

        public FakeWifiSessionHandle(WifiApMode mode, string ssid, bool useLoopbackTcp = false)
        {
            Mode = mode;
            ActualSsid = ssid;
            Ip = "192.168.137.1";
            if (useLoopbackTcp)
            {
                loopbackListener = new TcpListener(IPAddress.Loopback, 0);
                loopbackListener.Start(1);
                Port = ((IPEndPoint)loopbackListener.LocalEndpoint).Port;
            }
            else
            {
                Port = 45678;
            }
        }

        public void ProvideConnection(Stream pcStream, Action? shutdownSend = null) =>
            acceptTcs.TrySetResult(new WifiAcceptedConnection(pcStream, shutdownSend));

        public async Task<WifiAcceptedConnection> AcceptAsync(CancellationToken cancellationToken)
        {
            acceptStarted.TrySetResult();
            if (loopbackListener is not null)
            {
                var client = await loopbackListener.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false);
                loopbackListener.Stop();
                client.NoDelay = true;
                return new WifiAcceptedConnection(
                    client.GetStream(),
                    shutdownSend: () => { try { client.Client.Shutdown(SocketShutdown.Send); } catch { } },
                    owner: new TcpOwner(client));
            }
            return await acceptTcs.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        }

        public ValueTask DisposeAsync()
        {
            StopSync();
            return ValueTask.CompletedTask;
        }

        public void StopSync()
        {
            if (Interlocked.Exchange(ref disposedFlag, 1) != 0) return;
            try { loopbackListener?.Stop(); } catch { }
            acceptTcs.TrySetCanceled();
            disposedTcs.TrySetResult();
        }

        private sealed class TcpOwner(TcpClient client) : IAsyncDisposable
        {
            public ValueTask DisposeAsync()
            {
                try { client.Dispose(); } catch { }
                return ValueTask.CompletedTask;
            }
        }
    }

    private sealed class FakeWifiHost : IWifiTransferHost
    {
        public int StartCount { get; private set; }
        public WifiApMode Mode { get; set; } = WifiApMode.Hotspot5GHz;
        public bool UseLoopbackTcp { get; set; }
        public WifiUnavailableReason? FailWith { get; set; }
        public FakeWifiSessionHandle? LastHandle { get; private set; }
        public List<FakeWifiSessionHandle> Handles { get; } = [];
        public Func<WifiTransferCredentials, CancellationToken, Task<WifiHostStartResult>>? CustomStart { get; set; }

        public Task<WifiHostStartResult> StartAsync(WifiTransferCredentials credentials, CancellationToken cancellationToken)
        {
            StartCount++;
            if (CustomStart is not null)
                return CustomStart(credentials, cancellationToken);
            if (FailWith is { } reason)
                return Task.FromResult(WifiHostStartResult.Failure(reason));
            var handle = new FakeWifiSessionHandle(Mode, credentials.Ssid, UseLoopbackTcp);
            LastHandle = handle;
            Handles.Add(handle);
            return Task.FromResult(WifiHostStartResult.Success(handle));
        }

        public void StopSync()
        {
            foreach (var h in Handles) h.StopSync();
        }
    }

    private sealed class Rig : IAsyncDisposable
    {
        public readonly SyncPairing Pairing = SyncPairing.Create("test-pc");
        public readonly FakeClipboard Clipboard = new();
        public readonly Guid DeviceId = Guid.NewGuid();
        public readonly SyncRepository Store;
        public readonly ConcurrentQueue<string> Logs = new();
        public readonly FakeWifiHost Host;
        public readonly WifiSessionReplayGuard ReplayGuard;
        public readonly SyncCoordinator Pc;
        public DateTimeOffset Now = new(2026, 11, 22, 12, 0, 0, TimeSpan.Zero);
        public bool WifiEnabled = true;

        public Rig(
            string root,
            FakeWifiHost? host = null,
            WifiSessionReplayGuard? replayGuard = null,
            WifiTransferOptions? options = null)
        {
            Store = new(root, Pairing.PcId);
            Store.Register(DeviceId, "pad", Now);
            Host = host ?? new FakeWifiHost();
            ReplayGuard = replayGuard ?? new WifiSessionReplayGuard();
            Pc = new(
                Pairing,
                Clipboard,
                Logs.Enqueue,
                Store,
                () => Now,
                wifiHost: Host,
                isWifiTransferEnabled: () => WifiEnabled,
                wifiReplayGuard: ReplayGuard,
                wifiOptions: options);
        }

        public async Task<Pad> ConnectAsync(byte version = SyncProtocol.Version, Guid? deviceId = null)
        {
            var peer = new FakePeer();
            var handshake = new SyncPadHandshake(Pairing, deviceId ?? DeviceId, protocolVersion: version);
            await Pc.ConnectAsync(peer);
            await SendFrameAsync(peer, handshake.CreateHello());
            var auth = handshake.AcceptWelcome(Assert.Single(peer.DrainFrames()));
            await SendFrameAsync(peer, auth.Auth);
            return new Pad(this, peer, auth.Keys);
        }

        public async Task SendFrameAsync(FakePeer peer, byte[] frame)
        {
            foreach (var packet in SyncPacketizer.Split(frame, peer.PacketLimit))
                Assert.True(await Pc.ReceiveAsync(peer, packet));
            await Pc.WaitForOutgoingAsync(peer);
        }

        public ValueTask DisposeAsync() => Pc.DisposeAsync();
    }

    private sealed class Pad(Rig rig, FakePeer peer, SyncSessionKeys keys)
    {
        public readonly FakePeer Peer = peer;
        public readonly SyncSessionKeys Keys = keys;
        private readonly SyncFrameSender sender = new(keys.PadToPc);
        private readonly SyncFrameReceiver receiver = new(keys.PcToPad);
        private readonly Queue<object> inbox = new();

        public Task SendSyncAsync(SyncMessage message) =>
            rig.SendFrameAsync(Peer, sender.Seal(SyncMessageCodec.Encode(message)));

        public Task SendWifiAsync(WifiControlMessage message) =>
            rig.SendFrameAsync(Peer, sender.Seal(WifiControlMessageCodec.Encode(message)));

        public byte[] SealWifi(WifiControlMessage message) =>
            sender.Seal(WifiControlMessageCodec.Encode(message));

        private void PumpInbox()
        {
            foreach (var frame in Peer.DrainFrames())
            {
                var plaintext = receiver.Open(frame);
                inbox.Enqueue(DecodeAny(plaintext));
            }
        }

        public object[] DrainAll()
        {
            PumpInbox();
            var list = new List<object>(inbox.Count);
            while (inbox.TryDequeue(out var msg))
                list.Add(msg);
            return list.ToArray();
        }

        public async Task<T> WaitForMessageAsync<T>(TimeSpan? timeout = null) where T : class
        {
            var deadline = DateTime.UtcNow + (timeout ?? TimeSpan.FromSeconds(5));
            while (DateTime.UtcNow < deadline)
            {
                PumpInbox();
                while (inbox.TryDequeue(out var msg))
                {
                    if (msg is T matched) return matched;
                }
                var remaining = deadline - DateTime.UtcNow;
                if (remaining <= TimeSpan.Zero) break;
                await Peer.WaitForPacketAsync(remaining);
                await rig.Pc.WaitForOutgoingAsync(Peer);
            }
            throw new TimeoutException($"Timed out waiting for {typeof(T).Name}.");
        }

        private static object DecodeAny(byte[] plaintext)
        {
            try { return WifiControlMessageCodec.Decode(plaintext); }
            catch (SyncProtocolException) { }
            return SyncMessageCodec.Decode(plaintext);
        }
    }

    [Fact]
    public async Task IosToPcEndToEndViaMemoryPipeSavesHistoryWritesClipboardAndRedactsLogs()
    {
        var delay = new ControlledDelay();
        await using var rig = new Rig(NewRoot(), options: new WifiTransferOptions(
            PostDoneCloseGrace: TimeSpan.Zero,
            DelayAsync: delay.DelayAsync));
        var pad = await rig.ConnectAsync();

        var data = MakeBytes(600_000, seed: 0x11);
        var secretFilename = "secret-invoice-2026.bin";
        var offer = MakeOffer(Guid.NewGuid(), "pad", data, filename: secretFilename);

        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [offer.Id]));
        var ready = await pad.WaitForMessageAsync<WifiReady>();
        Assert.Equal(90, ready.TtlSeconds);
        Assert.StartsWith("DIRECT-cp-", ready.Ssid, StringComparison.Ordinal);
        Assert.InRange(ready.Passphrase.Length, SyncProtocol.WifiMinPassphraseBytes, SyncProtocol.WifiMaxPassphraseBytes);
        Assert.Equal(32, ready.Token.Length);

        await pad.SendWifiAsync(new WifiJoinResult(ready.Session, WifiJoinStatus.Joined));
        await rig.Host.LastHandle!.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));

        var pipe = new DuplexPipe();
        rig.Host.LastHandle.ProvideConnection(pipe.PcEnd, pipe.PcEnd.CloseWrite);

        var transferKeys = WifiTransferKeys.Derive(pad.Keys, ready.Token, ready.Session);
        var padResult = await WifiTransferEngine.RunPadSessionAsync(
            pipe.PadEnd,
            transferKeys,
            outgoing: [new InMemoryWifiTransferSource(offer, data)],
            sink: new InMemoryWifiTransferSink());
        pipe.PadEnd.CloseWrite();

        Assert.Single(padResult.Sent);
        Assert.Empty(padResult.Received);
        Assert.Equal(data.Length, padResult.Sent[0].TransferredBytes);

        await rig.Pc.WaitForWifiIdleAsync();
        Assert.True(rig.Host.LastHandle.IsDisposed);

        var history = await rig.Pc.GetHistoryAsync();
        var saved = Assert.Single(history);
        Assert.Equal(offer.Id, saved.Id);
        Assert.Equal(secretFilename, saved.Filename);
        Assert.Equal(data, File.ReadAllBytes(saved.Path!));
        Assert.Single(rig.Clipboard.MediaWrites);
        Assert.Null(rig.Store.Incoming(rig.DeviceId, offer.Id));
        Assert.False(File.Exists(rig.Store.PartialPath(rig.DeviceId, offer.Id)));

        var logs = rig.Logs.ToArray();
        Assert.Contains(logs, l => l.StartsWith("wifi transfer start mode=hotspot5", StringComparison.Ordinal));
        Assert.Contains(logs, l => l.StartsWith("wifi transfer done mode=hotspot5", StringComparison.Ordinal) && l.Contains("speedMBps=", StringComparison.Ordinal));

        // Ensure no secret, SSID, passphrase, IP, token, session, device ID, or filename leaks into logs.
        var tokenHex = Convert.ToHexStringLower(ready.Token);
        foreach (var line in logs)
        {
            Assert.DoesNotContain(ready.Ssid, line, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain(ready.Passphrase, line, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain(ready.Ip, line, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain(tokenHex, line, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain(ready.Session.ToString("D"), line, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain(rig.DeviceId.ToString("D"), line, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain(secretFilename, line, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    public async Task PcToIosEndToEndViaLoopbackTcpClearsPendingQueueAndContinuesBle()
    {
        await using var rig = new Rig(NewRoot(), host: new FakeWifiHost { UseLoopbackTcp = true, Mode = WifiApMode.Hotspot5GHz });
        var bytesA = MakeBytes(700_000, seed: 0x22);
        var bytesB = MakeBytes(600_000, seed: 0x33);

        await rig.Pc.AddLocalContentsAsync([
            new ClipboardContent("file", Filename: "first.bin", Data: bytesA),
            new ClipboardContent("file", Filename: "second.bin", Data: bytesB),
        ]);
        var pendingBefore = rig.Store.Pending(rig.DeviceId);
        Assert.Equal(2, pendingBefore.Count);
        var itemA = pendingBefore[0];
        var itemB = pendingBefore[1];

        var pad = await rig.ConnectAsync();
        var bleOfferA = await pad.WaitForMessageAsync<SyncOffer>();
        Assert.Equal(itemA.Id, bleOfferA.Id);

        // Instead of BLE resume, iOS requests Wi-Fi receive for itemA.
        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Receive, [itemA.Id]));
        var ready = await pad.WaitForMessageAsync<WifiReady>();
        await pad.SendWifiAsync(new WifiJoinResult(ready.Session, WifiJoinStatus.Joined));

        // Connect over real 127.0.0.1 loopback TCP to the listener port from wifi_ready.
        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, ready.Port);
        await using var netStream = client.GetStream();

        var padSink = new InMemoryWifiTransferSink();
        var keys = WifiTransferKeys.Derive(pad.Keys, ready.Token, ready.Session);
        var result = await WifiTransferEngine.RunPadSessionAsync(
            netStream,
            keys,
            outgoing: [],
            sink: padSink);
        client.Client.Shutdown(SocketShutdown.Send);

        Assert.Empty(result.Sent);
        var rx = Assert.Single(result.Received);
        Assert.Equal(itemA.Id, rx.Offer.Id);
        Assert.Equal(bytesA, padSink.Completed[itemA.Id].Data);

        await rig.Pc.WaitForWifiIdleAsync();
        await rig.Pc.WaitForOutgoingAsync(pad.Peer);
        Assert.True(rig.Host.LastHandle!.IsDisposed);

        // Item A is removed from PC pending queue, and BLE automatically moves on to offer item B.
        var pendingAfter = rig.Store.Pending(rig.DeviceId);
        Assert.Equal([itemB.Id], pendingAfter.Select(i => i.Id).ToArray());
        var bleOfferB = await pad.WaitForMessageAsync<SyncOffer>();
        Assert.Equal(itemB.Id, bleOfferB.Id);
    }

    [Fact]
    public async Task BidirectionalBothTransferResumesBlePartialAndTransfersBothWays()
    {
        await using var rig = new Rig(NewRoot(), options: new WifiTransferOptions(PostDoneCloseGrace: TimeSpan.Zero));
        var pcData = MakeBytes(550_000, seed: 0x44);
        await rig.Pc.AddLocalContentsAsync([new ClipboardContent("file", Filename: "from-pc.bin", Data: pcData)]);
        var pcItem = Assert.Single(rig.Store.Pending(rig.DeviceId));

        // Pre-seed a partial from an earlier interrupted BLE upload (first 64 KiB already on disk).
        var padData = MakeBytes(600_000, seed: 0x55);
        var padOffer = MakeOffer(Guid.NewGuid(), "pad", padData, filename: "from-pad.bin");
        Assert.Equal(0, rig.Store.Begin(rig.DeviceId, padOffer, rig.Now));
        Assert.Equal(65_536, rig.Store.Append(rig.DeviceId, padOffer.Id, 0, padData.AsSpan(0, 65_536)));

        var pad = await rig.ConnectAsync();
        var bleOffer = await pad.WaitForMessageAsync<SyncOffer>();
        Assert.Equal(pcItem.Id, bleOffer.Id);

        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Both, [padOffer.Id, pcItem.Id]));
        var ready = await pad.WaitForMessageAsync<WifiReady>();
        await rig.Host.LastHandle!.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));

        var pipe = new DuplexPipe();
        rig.Host.LastHandle.ProvideConnection(pipe.PcEnd, pipe.PcEnd.CloseWrite);

        var padSink = new InMemoryWifiTransferSink();
        var keys = WifiTransferKeys.Derive(pad.Keys, ready.Token, ready.Session);
        var result = await WifiTransferEngine.RunPadSessionAsync(
            pipe.PadEnd,
            keys,
            outgoing: [new InMemoryWifiTransferSource(padOffer, padData)],
            sink: padSink);
        pipe.PadEnd.CloseWrite();

        // Resumed from 65,536 -> only remaining 534,464 bytes sent over Wi-Fi.
        Assert.Single(result.Sent);
        Assert.Equal(padData.Length - 65_536, result.Sent[0].TransferredBytes);
        Assert.Single(result.Received);
        Assert.Equal(pcData, padSink.Completed[pcItem.Id].Data);

        await rig.Pc.WaitForWifiIdleAsync();
        Assert.Empty(rig.Store.Pending(rig.DeviceId));
        var pcHistory = await rig.Pc.GetHistoryAsync();
        var receivedOnPc = Assert.Single(pcHistory, i => i.Id == padOffer.Id);
        Assert.Equal(padData, File.ReadAllBytes(receivedOnPc.Path!));
    }

    [Fact]
    public async Task WifiAcceptsItemLargerThan10MiBUpTo50MiBWhileBleRejectsOver10MiB()
    {
        await using var rig = new Rig(NewRoot(), options: new WifiTransferOptions(PostDoneCloseGrace: TimeSpan.Zero));
        var pad = await rig.ConnectAsync();

        var largeBytes = MakeBytes(SyncProtocol.MaxItemBytes + 1024 * 1024, seed: 0x77); // 11 MiB
        var offer = MakeOffer(Guid.NewGuid(), "pad", largeBytes, filename: "large-11mib.bin");

        // BLE codec rejects > 10 MiB.
        Assert.Throws<SyncProtocolException>(() => SyncMessageCodec.Encode(offer));

        // Wi-Fi path accepts 11 MiB (up to 50 MiB).
        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [offer.Id]));
        var ready = await pad.WaitForMessageAsync<WifiReady>();
        await rig.Host.LastHandle!.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));

        var pipe = new DuplexPipe();
        rig.Host.LastHandle.ProvideConnection(pipe.PcEnd, pipe.PcEnd.CloseWrite);

        var keys = WifiTransferKeys.Derive(pad.Keys, ready.Token, ready.Session);
        var result = await WifiTransferEngine.RunPadSessionAsync(
            pipe.PadEnd,
            keys,
            outgoing: [new InMemoryWifiTransferSource(offer, largeBytes)],
            sink: new InMemoryWifiTransferSink());
        pipe.PadEnd.CloseWrite();

        Assert.Single(result.Sent);
        await rig.Pc.WaitForWifiIdleAsync();

        var saved = Assert.Single(await rig.Pc.GetHistoryAsync());
        Assert.Equal(largeBytes.Length, saved.Size);
        Assert.Equal(offer.Sha256, saved.Hash);
        Assert.Equal(largeBytes.Length, new FileInfo(saved.Path!).Length);
    }

    [Fact]
    public async Task UnsolicitedOfferNotInRequestIdsAndWrongDirectionOfferAreRejected()
    {
        await using var rig = new Rig(NewRoot(), options: new WifiTransferOptions(PostDoneCloseGrace: TimeSpan.Zero));
        var pad = await rig.ConnectAsync();

        var allowedId = Guid.NewGuid();
        var unsolicitedBytes = MakeBytes(1024, seed: 0x09);
        var unsolicitedOffer = MakeOffer(Guid.NewGuid(), "pad", unsolicitedBytes, filename: "sneaky.bin");

        // 1. Offer ID not present in wifi_request.ids
        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [allowedId]));
        var ready1 = await pad.WaitForMessageAsync<WifiReady>();
        await rig.Host.LastHandle!.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));

        var pipe1 = new DuplexPipe();
        rig.Host.LastHandle.ProvideConnection(pipe1.PcEnd, pipe1.PcEnd.CloseWrite);

        var keys1 = WifiTransferKeys.Derive(pad.Keys, ready1.Token, ready1.Session);
        await Assert.ThrowsAnyAsync<Exception>(() => WifiTransferEngine.RunPadSessionAsync(
            pipe1.PadEnd,
            keys1,
            outgoing: [new InMemoryWifiTransferSource(unsolicitedOffer, unsolicitedBytes)],
            sink: new InMemoryWifiTransferSink()));
        pipe1.PadEnd.CloseWrite();

        var cancel1 = await pad.WaitForMessageAsync<WifiCancel>();
        Assert.Equal(ready1.Session, cancel1.Session);
        Assert.Equal(WifiCancelReason.ProtocolError, cancel1.Reason);
        await rig.Pc.WaitForWifiIdleAsync();
        Assert.Empty(await rig.Pc.GetHistoryAsync());

        // 2. Receive-only request must reject any pad->pc offer even if ID is in ids.
        var receiveOnlyOffer = MakeOffer(allowedId, "pad", unsolicitedBytes, filename: "wrong-dir.bin");
        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Receive, [allowedId]));
        var ready2 = await pad.WaitForMessageAsync<WifiReady>();
        await rig.Host.LastHandle!.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));

        var pipe2 = new DuplexPipe();
        rig.Host.LastHandle.ProvideConnection(pipe2.PcEnd, pipe2.PcEnd.CloseWrite);

        var keys2 = WifiTransferKeys.Derive(pad.Keys, ready2.Token, ready2.Session);
        await Assert.ThrowsAnyAsync<Exception>(() => WifiTransferEngine.RunPadSessionAsync(
            pipe2.PadEnd,
            keys2,
            outgoing: [new InMemoryWifiTransferSource(receiveOnlyOffer, unsolicitedBytes)],
            sink: new InMemoryWifiTransferSink()));
        pipe2.PadEnd.CloseWrite();

        var cancel2 = await pad.WaitForMessageAsync<WifiCancel>();
        Assert.Equal(ready2.Session, cancel2.Session);
        Assert.Equal(WifiCancelReason.ProtocolError, cancel2.Reason);
        await rig.Pc.WaitForWifiIdleAsync();
        Assert.Empty(await rig.Pc.GetHistoryAsync());
    }

    [Fact]
    public async Task StartupFailureReturnsStartFailedAndAllowsImmediateBleFallback()
    {
        var host = new FakeWifiHost { FailWith = WifiUnavailableReason.StartFailed };
        await using var rig = new Rig(NewRoot(), host: host);
        var data = MakeBytes(40_000, seed: 0x61);
        await rig.Pc.AddLocalContentsAsync([new ClipboardContent("file", Filename: "fallback.bin", Data: data)]);
        var item = Assert.Single(rig.Store.Pending(rig.DeviceId));

        var pad = await rig.ConnectAsync();
        var bleOffer = await pad.WaitForMessageAsync<SyncOffer>();
        Assert.Equal(item.Id, bleOffer.Id);

        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Receive, [item.Id]));
        var unavailable = await pad.WaitForMessageAsync<WifiUnavailable>();
        Assert.Equal(WifiUnavailableReason.StartFailed, unavailable.Reason);
        await rig.Pc.WaitForWifiIdleAsync();
        Assert.Contains(rig.Logs, l => l == "wifi transfer fallback reason=start_failed");

        // iOS immediately falls back to BLE using SyncResume on the existing BLE offer.
        await pad.SendSyncAsync(new SyncResume(item.Id, 0));
        var received = new MemoryStream();
        while (received.Length < data.Length)
        {
            var chunk = await pad.WaitForMessageAsync<SyncChunk>();
            Assert.Equal(item.Id, chunk.Id);
            Assert.Equal(received.Length, chunk.Offset);
            received.Write(chunk.Data);
            if (received.Length < data.Length)
                await pad.SendSyncAsync(new SyncResume(item.Id, (int)received.Length));
        }
        Assert.Equal(data, received.ToArray());
        await pad.SendSyncAsync(new SyncAck([item.Id]));
        Assert.Empty(rig.Store.Pending(rig.DeviceId));
    }

    [Fact]
    public async Task BusyRejectsSecondDeviceWithoutDisruptingFirstDeviceSession()
    {
        await using var rig = new Rig(NewRoot(), options: new WifiTransferOptions(PostDoneCloseGrace: TimeSpan.Zero));
        var secondDevice = Guid.NewGuid();
        rig.Store.Register(secondDevice, "phone", rig.Now);

        var pad1 = await rig.ConnectAsync(deviceId: rig.DeviceId);
        var pad2 = await rig.ConnectAsync(deviceId: secondDevice);

        var data1 = MakeBytes(20_000, seed: 0xA1);
        var offer1 = MakeOffer(Guid.NewGuid(), "pad", data1, filename: "one.bin");

        await pad1.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [offer1.Id]));
        var ready1 = await pad1.WaitForMessageAsync<WifiReady>();
        var handle1 = rig.Host.LastHandle!;
        await handle1.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));

        // Second device asks for Wi-Fi while first session is active -> busy.
        await pad2.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [Guid.NewGuid()]));
        var busy = await pad2.WaitForMessageAsync<WifiUnavailable>();
        Assert.Equal(WifiUnavailableReason.Busy, busy.Reason);
        Assert.Equal(1, rig.Host.StartCount);
        Assert.Contains(rig.Logs, l => l == "wifi transfer fallback reason=busy");

        // First device finishes cleanly.
        var pipe1 = new DuplexPipe();
        handle1.ProvideConnection(pipe1.PcEnd, pipe1.PcEnd.CloseWrite);
        var keys1 = WifiTransferKeys.Derive(pad1.Keys, ready1.Token, ready1.Session);
        await WifiTransferEngine.RunPadSessionAsync(
            pipe1.PadEnd,
            keys1,
            outgoing: [new InMemoryWifiTransferSource(offer1, data1)],
            sink: new InMemoryWifiTransferSink());
        pipe1.PadEnd.CloseWrite();
        await rig.Pc.WaitForWifiIdleAsync();

        // Now second device can start a Wi-Fi session.
        var data2 = MakeBytes(15_000, seed: 0xB2);
        var offer2 = MakeOffer(Guid.NewGuid(), "pad", data2, filename: "two.bin");
        await pad2.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [offer2.Id]));
        var ready2 = await pad2.WaitForMessageAsync<WifiReady>();
        await rig.Host.LastHandle!.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));
        var pipe2 = new DuplexPipe();
        rig.Host.LastHandle.ProvideConnection(pipe2.PcEnd, pipe2.PcEnd.CloseWrite);
        var keys2 = WifiTransferKeys.Derive(pad2.Keys, ready2.Token, ready2.Session);
        await WifiTransferEngine.RunPadSessionAsync(
            pipe2.PadEnd,
            keys2,
            outgoing: [new InMemoryWifiTransferSource(offer2, data2)],
            sink: new InMemoryWifiTransferSink());
        pipe2.PadEnd.CloseWrite();
        await rig.Pc.WaitForWifiIdleAsync();

        Assert.Equal(2, (await rig.Pc.GetHistoryAsync()).Count);
    }

    [Fact]
    public async Task DisabledSettingReturnsDisabledWithoutStartingHost()
    {
        await using var rig = new Rig(NewRoot());
        rig.WifiEnabled = false;
        var pad = await rig.ConnectAsync();

        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [Guid.NewGuid()]));
        var unavailable = await pad.WaitForMessageAsync<WifiUnavailable>();
        Assert.Equal(WifiUnavailableReason.Disabled, unavailable.Reason);
        Assert.Equal(0, rig.Host.StartCount);
        Assert.Contains(rig.Logs, l => l == "wifi transfer fallback reason=disabled");
    }

    [Fact]
    public async Task TtlExpirationClosesApSendsTimeoutCancelAndKeepsBleAliveForFallback()
    {
        var delay = new ControlledDelay();
        await using var rig = new Rig(NewRoot(), options: new WifiTransferOptions(
            TtlSeconds: 90,
            DelayAsync: delay.DelayAsync));

        var data = MakeBytes(40_000, seed: 0x88);
        await rig.Pc.AddLocalContentsAsync([new ClipboardContent("file", Filename: "ttl.bin", Data: data)]);
        var item = Assert.Single(rig.Store.Pending(rig.DeviceId));

        var pad = await rig.ConnectAsync();
        _ = await pad.WaitForMessageAsync<SyncOffer>();

        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Receive, [item.Id]));
        var ready = await pad.WaitForMessageAsync<WifiReady>();
        Assert.Equal(90, ready.TtlSeconds);
        var handle = rig.Host.LastHandle!;
        await handle.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));

        // At +65s (past BLE's 60s ReplyTimeout, before Wi-Fi's 90s TTL), BLE must NOT drop!
        rig.Now = rig.Now.AddSeconds(65);
        await rig.Pc.TickAsync(rig.Now);
        Assert.False(pad.Peer.Rejected);
        Assert.False(handle.IsDisposed);

        // At +91s (past 90s TTL), TTL expires deterministically via TickAsync.
        rig.Now = rig.Now.AddSeconds(26);
        await rig.Pc.TickAsync(rig.Now);

        var cancel = await pad.WaitForMessageAsync<WifiCancel>();
        Assert.Equal(ready.Session, cancel.Session);
        Assert.Equal(WifiCancelReason.Timeout, cancel.Reason);
        await rig.Pc.WaitForWifiIdleAsync();
        Assert.True(handle.IsDisposed);
        Assert.False(pad.Peer.Rejected);

        // BLE fallback works right after TTL expiry (reply deadline was refreshed).
        await pad.SendSyncAsync(new SyncResume(item.Id, 0));
        var chunk = await pad.WaitForMessageAsync<SyncChunk>();
        Assert.Equal(item.Id, chunk.Id);
        Assert.Equal(0, chunk.Offset);
    }

    [Fact]
    public async Task PreAuthReadTimeoutIs5SecondsAndPostAuthIdleTimeoutIs10Seconds()
    {
        var delay = new ControlledDelay();
        await using var rig = new Rig(NewRoot(), options: new WifiTransferOptions(
            PostDoneCloseGrace: TimeSpan.Zero,
            DelayAsync: delay.DelayAsync));
        var pad = await rig.ConnectAsync();

        // 1. Pre-auth 5-second read timeout
        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [Guid.NewGuid()]));
        var ready1 = await pad.WaitForMessageAsync<WifiReady>();
        await rig.Host.LastHandle!.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));
        var pipe1 = new DuplexPipe();
        rig.Host.LastHandle.ProvideConnection(pipe1.PcEnd, pipe1.PcEnd.CloseWrite);

        var preAuthWait = await delay.WaitForRequestedDelayAsync(TimeSpan.FromSeconds(5)).WaitAsync(TimeSpan.FromSeconds(5));
        preAuthWait.Trigger();

        var cancel1 = await pad.WaitForMessageAsync<WifiCancel>();
        Assert.Equal(ready1.Session, cancel1.Session);
        Assert.Equal(WifiCancelReason.Timeout, cancel1.Reason);
        await rig.Pc.WaitForWifiIdleAsync();
        Assert.True(rig.Host.LastHandle.IsDisposed);
        pipe1.PadEnd.Dispose();

        // 2. Post-auth 10-second idle timeout
        var data = MakeBytes(100_000, seed: 0x33);
        var offer = MakeOffer(Guid.NewGuid(), "pad", data, filename: "stall.bin");
        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [offer.Id]));
        var ready2 = await pad.WaitForMessageAsync<WifiReady>();
        await rig.Host.LastHandle!.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));
        var pipe2 = new DuplexPipe();
        rig.Host.LastHandle.ProvideConnection(pipe2.PcEnd, pipe2.PcEnd.CloseWrite);

        var keys2 = WifiTransferKeys.Derive(pad.Keys, ready2.Token, ready2.Session);
        var channel = await WifiEncryptedStream.ConnectAsPadAsync(pipe2.PadEnd, keys2);
        await channel.SendMessageAsync(new WifiStreamOffer(offer));
        var resume = Assert.IsType<WifiStreamResume>(await channel.ReceiveMessageAsync());
        Assert.Equal(0, resume.Offset);

        // Stall without sending chunks -> PC waits with exact 10-second idle timeout.
        var postAuthWait = await delay.WaitForRequestedDelayAsync(TimeSpan.FromSeconds(10)).WaitAsync(TimeSpan.FromSeconds(5));
        postAuthWait.Trigger();

        var cancel2 = await pad.WaitForMessageAsync<WifiCancel>();
        Assert.Equal(ready2.Session, cancel2.Session);
        Assert.Equal(WifiCancelReason.Timeout, cancel2.Reason);
        await rig.Pc.WaitForWifiIdleAsync();
        Assert.True(rig.Host.LastHandle.IsDisposed);
        pipe2.PadEnd.Dispose();
    }

    [Fact]
    public async Task Sha256MismatchDeletesPartialFileAndNeverCommitsToHistory()
    {
        await using var rig = new Rig(NewRoot(), options: new WifiTransferOptions(PostDoneCloseGrace: TimeSpan.Zero));
        var pad = await rig.ConnectAsync();

        var data = MakeBytes(120_000, seed: 0x99);
        var badSha = new string('f', 64);
        var badOffer = MakeOffer(Guid.NewGuid(), "pad", data, filename: "corrupt.bin", overrideSha256: badSha);

        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [badOffer.Id]));
        var ready = await pad.WaitForMessageAsync<WifiReady>();
        await rig.Host.LastHandle!.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));

        var pipe = new DuplexPipe();
        rig.Host.LastHandle.ProvideConnection(pipe.PcEnd, pipe.PcEnd.CloseWrite);

        var keys = WifiTransferKeys.Derive(pad.Keys, ready.Token, ready.Session);
        await Assert.ThrowsAnyAsync<Exception>(() => WifiTransferEngine.RunPadSessionAsync(
            pipe.PadEnd,
            keys,
            outgoing: [new InMemoryWifiTransferSource(badOffer, data)],
            sink: new InMemoryWifiTransferSink()));
        pipe.PadEnd.CloseWrite();

        var cancel = await pad.WaitForMessageAsync<WifiCancel>();
        Assert.Equal(ready.Session, cancel.Session);
        Assert.Equal(WifiCancelReason.ProtocolError, cancel.Reason);
        await rig.Pc.WaitForWifiIdleAsync();

        // Partial file MUST be deleted and nothing added to history or clipboard.
        Assert.Null(rig.Store.Incoming(rig.DeviceId, badOffer.Id));
        Assert.False(File.Exists(rig.Store.PartialPath(rig.DeviceId, badOffer.Id)));
        Assert.Empty(await rig.Pc.GetHistoryAsync());
        Assert.Empty(rig.Clipboard.MediaWrites);
    }

    [Fact]
    public async Task MidTransferDisconnectSendsTcpFailedAndPreservesPartialForResume()
    {
        await using var rig = new Rig(NewRoot(), options: new WifiTransferOptions(PostDoneCloseGrace: TimeSpan.Zero));
        var pad = await rig.ConnectAsync();

        var data = MakeBytes(600_000, seed: 0x42);
        var offer = MakeOffer(Guid.NewGuid(), "pad", data, filename: "resumable.bin");

        // Attempt 1: cut stream partway through after >1 chunk (~300 KiB of encrypted wire bytes).
        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [offer.Id]));
        var ready1 = await pad.WaitForMessageAsync<WifiReady>();
        await rig.Host.LastHandle!.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));

        var cutPipe = new DuplexPipe(cutPadToPcAfterBytes: 300_000);
        rig.Host.LastHandle.ProvideConnection(cutPipe.PcEnd, cutPipe.PcEnd.CloseWrite);

        var keys1 = WifiTransferKeys.Derive(pad.Keys, ready1.Token, ready1.Session);
        await Assert.ThrowsAnyAsync<Exception>(() => WifiTransferEngine.RunPadSessionAsync(
            cutPipe.PadEnd,
            keys1,
            outgoing: [new InMemoryWifiTransferSource(offer, data)],
            sink: new InMemoryWifiTransferSink()));

        var cancel = await pad.WaitForMessageAsync<WifiCancel>();
        Assert.Equal(ready1.Session, cancel.Session);
        Assert.Equal(WifiCancelReason.TcpFailed, cancel.Reason);
        await rig.Pc.WaitForWifiIdleAsync();
        Assert.True(rig.Host.LastHandle.IsDisposed);

        // Partial file was preserved with the first 252 KiB chunk already written.
        Assert.NotNull(rig.Store.Incoming(rig.DeviceId, offer.Id));
        var savedBytes = new FileInfo(rig.Store.PartialPath(rig.DeviceId, offer.Id)).Length;
        Assert.Equal(SyncProtocol.MaxWifiChunkBytes, savedBytes);
        Assert.Empty(await rig.Pc.GetHistoryAsync());

        // Attempt 2: resumes from saved offset and completes.
        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [offer.Id]));
        var ready2 = await pad.WaitForMessageAsync<WifiReady>();
        await rig.Host.LastHandle!.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));

        var goodPipe = new DuplexPipe();
        rig.Host.LastHandle.ProvideConnection(goodPipe.PcEnd, goodPipe.PcEnd.CloseWrite);

        var keys2 = WifiTransferKeys.Derive(pad.Keys, ready2.Token, ready2.Session);
        var result = await WifiTransferEngine.RunPadSessionAsync(
            goodPipe.PadEnd,
            keys2,
            outgoing: [new InMemoryWifiTransferSource(offer, data)],
            sink: new InMemoryWifiTransferSink());
        goodPipe.PadEnd.CloseWrite();

        Assert.Single(result.Sent);
        Assert.Equal(data.Length - SyncProtocol.MaxWifiChunkBytes, result.Sent[0].TransferredBytes);
        await rig.Pc.WaitForWifiIdleAsync();

        var saved = Assert.Single(await rig.Pc.GetHistoryAsync());
        Assert.Equal(data, File.ReadAllBytes(saved.Path!));
    }

    [Fact]
    public async Task JoinDeniedAndPeerCancelImmediatelyTearDownApWithoutWaitingForTtl()
    {
        var delay = new ControlledDelay();
        await using var rig = new Rig(NewRoot(), options: new WifiTransferOptions(DelayAsync: delay.DelayAsync));
        var pad = await rig.ConnectAsync();

        // 1. wifi_join_result(user_denied)
        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [Guid.NewGuid()]));
        var ready1 = await pad.WaitForMessageAsync<WifiReady>();
        var handle1 = rig.Host.LastHandle!;
        await handle1.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));

        await pad.SendWifiAsync(new WifiJoinResult(ready1.Session, WifiJoinStatus.UserDenied));
        await handle1.Disposed.WaitAsync(TimeSpan.FromSeconds(5));
        await rig.Pc.WaitForWifiIdleAsync();
        Assert.Empty(pad.DrainAll()); // No echo wifi_cancel needed when peer reported join failure.
        Assert.Contains(rig.Logs, l => l == "wifi transfer fallback reason=user_denied");

        // 2. wifi_cancel(user_cancelled)
        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [Guid.NewGuid()]));
        var ready2 = await pad.WaitForMessageAsync<WifiReady>();
        var handle2 = rig.Host.LastHandle!;
        await handle2.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));

        await pad.SendWifiAsync(new WifiCancel(ready2.Session, WifiCancelReason.UserCancelled));
        await handle2.Disposed.WaitAsync(TimeSpan.FromSeconds(5));
        await rig.Pc.WaitForWifiIdleAsync();
        Assert.Empty(pad.DrainAll());
        Assert.Contains(rig.Logs, l => l == "wifi transfer fallback reason=user_cancelled");
    }

    [Fact]
    public async Task Version3ConnectionNeverUsesWifiAndContinuesBleSyncNormally()
    {
        await using var rig = new Rig(NewRoot());
        var v3Pad = await rig.ConnectAsync(version: 3);
        Assert.False(v3Pad.Keys.SupportsWifiTransfer);

        // Normal BLE text sync still works on v3.
        var textItem = new SyncItem(Guid.NewGuid(), rig.Now.ToUnixTimeMilliseconds(), "pad", "hello v3");
        await v3Pad.SendSyncAsync(textItem);
        var ack = await v3Pad.WaitForMessageAsync<SyncAck>();
        Assert.Equal([textItem.Id], ack.Ids);
        Assert.Equal(["hello v3"], rig.Clipboard.TextWrites);

        // Sending wifi_request on a v3 connection is rejected and never starts Wi-Fi AP.
        var wifiFrame = v3Pad.SealWifi(new WifiRequest(WifiTransferDirection.Send, [Guid.NewGuid()]));
        var packets = SyncPacketizer.Split(wifiFrame, v3Pad.Peer.PacketLimit);
        var accepted = false;
        foreach (var p in packets)
            accepted = await rig.Pc.ReceiveAsync(v3Pad.Peer, p);

        Assert.False(accepted);
        Assert.True(v3Pad.Peer.Rejected);
        Assert.Equal(0, rig.Host.StartCount);
    }

    [Fact]
    public async Task ReplayGuardPersistsAcrossCoordinatorsAndBlocksReusedSession()
    {
        var fixedSession = Guid.NewGuid();
        var sharedReplayGuard = new WifiSessionReplayGuard();
        WifiTransferCredentials FixedCredentials() => new(
            fixedSession,
            "DIRECT-cp-REPLAY01",
            "ABCDEFGHJKLMNPQRSTUVWXYZ",
            RandomNumberGenerator.GetBytes(32));

        // First coordinator consumes fixedSession.
        await using (var rig1 = new Rig(
            NewRoot(),
            replayGuard: sharedReplayGuard,
            options: new WifiTransferOptions(PostDoneCloseGrace: TimeSpan.Zero, CredentialsFactory: FixedCredentials)))
        {
            var pad1 = await rig1.ConnectAsync();
            await pad1.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, []));
            var ready1 = await pad1.WaitForMessageAsync<WifiReady>();
            await rig1.Host.LastHandle!.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));
            var pipe1 = new DuplexPipe();
            rig1.Host.LastHandle.ProvideConnection(pipe1.PcEnd, pipe1.PcEnd.CloseWrite);
            var keys1 = WifiTransferKeys.Derive(pad1.Keys, ready1.Token, ready1.Session);
            await WifiTransferEngine.RunPadSessionAsync(pipe1.PadEnd, keys1, [], new InMemoryWifiTransferSink());
            pipe1.PadEnd.CloseWrite();
            await rig1.Pc.WaitForWifiIdleAsync();
            Assert.True(sharedReplayGuard.IsConsumed(fixedSession));
        }

        // Second coordinator sharing the process-lifetime replay guard rejects the replayed session.
        await using (var rig2 = new Rig(
            NewRoot(),
            replayGuard: sharedReplayGuard,
            options: new WifiTransferOptions(PostDoneCloseGrace: TimeSpan.Zero, CredentialsFactory: FixedCredentials)))
        {
            var pad2 = await rig2.ConnectAsync();
            await pad2.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, []));
            var ready2 = await pad2.WaitForMessageAsync<WifiReady>();
            await rig2.Host.LastHandle!.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));
            var pipe2 = new DuplexPipe();
            rig2.Host.LastHandle.ProvideConnection(pipe2.PcEnd, pipe2.PcEnd.CloseWrite);
            var keys2 = WifiTransferKeys.Derive(pad2.Keys, ready2.Token, ready2.Session);
            await Assert.ThrowsAnyAsync<Exception>(() => WifiTransferEngine.RunPadSessionAsync(
                pipe2.PadEnd, keys2, [], new InMemoryWifiTransferSink()));
            pipe2.PadEnd.CloseWrite();

            var cancel = await pad2.WaitForMessageAsync<WifiCancel>();
            Assert.Equal(WifiCancelReason.ProtocolError, cancel.Reason);
            await rig2.Pc.WaitForWifiIdleAsync();
        }
    }

    private sealed class FakeApBackend : IWifiApBackend
    {
        public bool Online { get; set; }
        public List<string> Calls { get; } = [];
        public Func<WifiTransferCredentials, WifiApAttemptResult> OnHotspot { get; set; } =
            c => WifiApAttemptResult.Success(new FakeWifiSessionHandle(WifiApMode.Hotspot5GHz, c.Ssid));
        public Func<WifiTransferCredentials, WifiApAttemptResult> OnDirect { get; set; } =
            c => WifiApAttemptResult.Success(new FakeWifiSessionHandle(WifiApMode.WifiDirect, c.Ssid));

        public bool HasInternetConnection() => Online;

        public Task<WifiApAttemptResult> TryStartHotspotAsync(WifiTransferCredentials credentials, CancellationToken cancellationToken)
        {
            Calls.Add("hotspot");
            return Task.FromResult(OnHotspot(credentials));
        }

        public Task<WifiApAttemptResult> TryStartWifiDirectAsync(WifiTransferCredentials credentials, CancellationToken cancellationToken)
        {
            Calls.Add("wifiDirect");
            return Task.FromResult(OnDirect(credentials));
        }
    }

    [Fact]
    public async Task ApStarterSelectsPrimaryByConnectivityAndFallsBackAfterDelay()
    {
        var creds = WifiTransferCredentials.CreateRandom();
        var logs = new List<string>();

        // 1. Online -> Hotspot first
        var onlineBackend = new FakeApBackend { Online = true };
        var r1 = await WifiApStarter.StartWithFallbackAsync(onlineBackend, creds, logs.Add, fallbackDelay: TimeSpan.Zero);
        Assert.True(r1.Succeeded);
        Assert.Equal(WifiApMode.Hotspot5GHz, r1.Handle!.Mode);
        Assert.Equal(["hotspot"], onlineBackend.Calls);
        await r1.Handle.DisposeAsync();

        // 2. Offline -> Wi-Fi Direct first
        var offlineBackend = new FakeApBackend { Online = false };
        var r2 = await WifiApStarter.StartWithFallbackAsync(offlineBackend, creds, logs.Add, fallbackDelay: TimeSpan.Zero);
        Assert.True(r2.Succeeded);
        Assert.Equal(WifiApMode.WifiDirect, r2.Handle!.Mode);
        Assert.Equal(["wifiDirect"], offlineBackend.Calls);
        await r2.Handle.DisposeAsync();

        // 3. Online + Hotspot fails -> waits fallbackDelay -> falls back to Wi-Fi Direct
        var delay = new ControlledDelay();
        var fallbackBackend = new FakeApBackend
        {
            Online = true,
            OnHotspot = _ => WifiApAttemptResult.Failure("RadioRestriction"),
        };
        var startTask = WifiApStarter.StartWithFallbackAsync(
            fallbackBackend,
            creds,
            logs.Add,
            fallbackDelay: TimeSpan.FromMilliseconds(800),
            delayAsync: delay.DelayAsync);
        var wait = await delay.WaitForRequestedDelayAsync(TimeSpan.FromMilliseconds(800)).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(["hotspot"], fallbackBackend.Calls);
        wait.Trigger();
        var r3 = await startTask;
        Assert.True(r3.Succeeded);
        Assert.Equal(WifiApMode.WifiDirect, r3.Handle!.Mode);
        Assert.Equal(["hotspot", "wifiDirect"], fallbackBackend.Calls);
        await r3.Handle.DisposeAsync();

        // 4. Both fail -> StartFailed
        var bothFailBackend = new FakeApBackend
        {
            Online = false,
            OnDirect = _ => WifiApAttemptResult.Failure("RadioNotAvailable"),
            OnHotspot = _ => WifiApAttemptResult.Failure("no_internet_profile"),
        };
        var r4 = await WifiApStarter.StartWithFallbackAsync(bothFailBackend, creds, logs.Add, fallbackDelay: TimeSpan.Zero);
        Assert.False(r4.Succeeded);
        Assert.Null(r4.Handle);
        Assert.Equal(WifiUnavailableReason.StartFailed, r4.FailureReason);
        Assert.Equal(["wifiDirect", "hotspot"], bothFailBackend.Calls);
    }

    [Fact]
    public void HotspotBackupRecordRestoresOnlyWhenCurrentSsidMatchesTempSsid()
    {
        var backup = new HotspotBackupRecord("MyHomeHotspot", "OriginalPass123", Band: 2, TempSsid: "DIRECT-cp-ABCD1234");
        Assert.True(backup.IsRestorable);
        Assert.True(backup.ShouldRestoreForCurrentSsid("DIRECT-cp-ABCD1234"));
        Assert.False(backup.ShouldRestoreForCurrentSsid("UserRenamedHotspot"));
        Assert.False(backup.ShouldRestoreForCurrentSsid(null));
        Assert.DoesNotContain("OriginalPass123", backup.ToString());
        Assert.DoesNotContain("MyHomeHotspot", backup.ToString());
    }

    [Fact]
    public void HotspotBackupRecordTracksMultipleTempSsidsDeserializesLegacyJsonAndRedactsSecrets()
    {
        var first = new HotspotBackupRecord("MyHomeHotspot", "OriginalPass123", Band: 2, TempSsid: "DIRECT-cp-FIRST001");
        var second = first.WithAdditionalTempSsid("DIRECT-cp-SECOND02");
        var third = second.WithAdditionalTempSsid("DIRECT-cp-THIRD003");

        Assert.Equal("MyHomeHotspot", third.Ssid);
        Assert.Equal("OriginalPass123", third.Passphrase);
        Assert.Equal(2, third.Band);
        Assert.Equal("DIRECT-cp-THIRD003", third.TempSsid);
        Assert.True(third.ShouldRestoreForCurrentSsid("DIRECT-cp-FIRST001"));
        Assert.True(third.ShouldRestoreForCurrentSsid("DIRECT-cp-SECOND02"));
        Assert.True(third.ShouldRestoreForCurrentSsid("DIRECT-cp-THIRD003"));
        Assert.False(third.ShouldRestoreForCurrentSsid("UserRenamedHotspot"));
        Assert.False(third.ShouldRestoreForCurrentSsid("MyHomeHotspot"));

        var summary = third.ToString();
        Assert.DoesNotContain("MyHomeHotspot", summary, StringComparison.Ordinal);
        Assert.DoesNotContain("OriginalPass123", summary, StringComparison.Ordinal);
        Assert.DoesNotContain("DIRECT-cp-FIRST001", summary, StringComparison.Ordinal);
        Assert.DoesNotContain("DIRECT-cp-THIRD003", summary, StringComparison.Ordinal);

        var json = System.Text.Json.JsonSerializer.Serialize(third);
        var roundTripped = System.Text.Json.JsonSerializer.Deserialize<HotspotBackupRecord>(json);
        Assert.Equal(third, roundTripped);

        const string legacyJson = """{"Ssid":"MyHomeHotspot","Passphrase":"OriginalPass123","Band":2,"TempSsid":"DIRECT-cp-LEGACY01"}""";
        var legacy = System.Text.Json.JsonSerializer.Deserialize<HotspotBackupRecord>(legacyJson);
        Assert.NotNull(legacy);
        Assert.Null(legacy!.PreviousTempSsids);
        Assert.True(legacy.ShouldRestoreForCurrentSsid("DIRECT-cp-LEGACY01"));
        Assert.False(legacy.ShouldRestoreForCurrentSsid("UserRenamedHotspot"));
    }

    [Fact]
    public async Task TtlTimerClosesSessionEvenWithoutTickAsync()
    {
        var delay = new ControlledDelay();
        await using var rig = new Rig(NewRoot(), options: new WifiTransferOptions(
            TtlSeconds: 90,
            DelayAsync: delay.DelayAsync));
        var pad = await rig.ConnectAsync();

        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [Guid.NewGuid()]));
        var ready = await pad.WaitForMessageAsync<WifiReady>();
        var handle = rig.Host.LastHandle!;
        await handle.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));

        var ttlWait = await delay.WaitForRequestedDelayAsync(TimeSpan.FromSeconds(90)).WaitAsync(TimeSpan.FromSeconds(5));
        ttlWait.Trigger();

        var cancel = await pad.WaitForMessageAsync<WifiCancel>();
        Assert.Equal(ready.Session, cancel.Session);
        Assert.Equal(WifiCancelReason.Timeout, cancel.Reason);
        await rig.Pc.WaitForWifiIdleAsync();
        Assert.True(handle.IsDisposed);
    }

    [Fact]
    public async Task SuppressesNewNonTextBleOffersDuringActiveWifiSessionAndResumesAfterTeardown()
    {
        var delay = new ControlledDelay();
        await using var rig = new Rig(NewRoot(), options: new WifiTransferOptions(
            PostDoneCloseGrace: TimeSpan.Zero,
            DelayAsync: delay.DelayAsync));
        var secondDevice = Guid.NewGuid();
        rig.Store.Register(secondDevice, "phone", rig.Now);

        var pad1 = await rig.ConnectAsync(deviceId: rig.DeviceId);
        var pad2 = await rig.ConnectAsync(deviceId: secondDevice);

        var uploadBytes = MakeBytes(600_000, seed: 0x1A);
        var uploadOffer = MakeOffer(Guid.NewGuid(), "pad", uploadBytes, filename: "up.bin");

        await pad1.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [uploadOffer.Id]));
        var ready = await pad1.WaitForMessageAsync<WifiReady>();
        var handle = rig.Host.LastHandle!;
        await handle.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));

        // While pad1's Wi-Fi session is active, add both a text item and a large attachment on PC.
        var deferredFileBytes = MakeBytes(620_000, seed: 0x2B);
        await rig.Pc.AddLocalContentsAsync([
            new ClipboardContent("text", Text: "text during wifi"),
            new ClipboardContent("file", Filename: "after-wifi.bin", Data: deferredFileBytes),
        ]);
        await rig.Pc.WaitForOutgoingAsync();

        // Pad1 receives text over BLE, but MUST NOT receive the new non-text offer while Wi-Fi is active.
        var pad1Text = await pad1.WaitForMessageAsync<SyncItem>();
        Assert.Equal("text during wifi", pad1Text.Text);
        Assert.DoesNotContain(pad1.DrainAll(), m => m is SyncOffer);

        // Pad2 is a separate connection and still receives both text and the new non-text offer over BLE.
        var pad2Text = await pad2.WaitForMessageAsync<SyncItem>();
        Assert.Equal("text during wifi", pad2Text.Text);
        var pad2Offer = await pad2.WaitForMessageAsync<SyncOffer>();
        Assert.Equal(deferredFileBytes.Length, pad2Offer.Size);

        // Advance past BLE's 60s ReplyTimeout (still under 90s Wi-Fi TTL): pad1 BLE & Wi-Fi stay alive.
        rig.Now = rig.Now.AddSeconds(65);
        await rig.Pc.TickAsync(rig.Now);
        Assert.False(pad1.Peer.Rejected);
        Assert.False(handle.IsDisposed);
        Assert.DoesNotContain(pad1.DrainAll(), m => m is SyncOffer);

        // Finish pad1's Wi-Fi session cleanly.
        var pipe = new DuplexPipe();
        handle.ProvideConnection(pipe.PcEnd, pipe.PcEnd.CloseWrite);
        var keys = WifiTransferKeys.Derive(pad1.Keys, ready.Token, ready.Session);
        await WifiTransferEngine.RunPadSessionAsync(
            pipe.PadEnd,
            keys,
            outgoing: [new InMemoryWifiTransferSource(uploadOffer, uploadBytes)],
            sink: new InMemoryWifiTransferSink());
        pipe.PadEnd.CloseWrite();

        await rig.Pc.WaitForWifiIdleAsync();
        await rig.Pc.WaitForOutgoingAsync(pad1.Peer);
        Assert.True(handle.IsDisposed);

        // After Wi-Fi teardown completes, PC automatically sends the deferred non-text offer over BLE.
        var resumedOffer = await pad1.WaitForMessageAsync<SyncOffer>();
        Assert.Equal(deferredFileBytes.Length, resumedOffer.Size);
    }

    [Fact]
    public async Task InFlightBleOfferBeforeWifiRequestDoesNotExpireDuringWifiSession()
    {
        var delay = new ControlledDelay();
        await using var rig = new Rig(NewRoot(), options: new WifiTransferOptions(
            PostDoneCloseGrace: TimeSpan.Zero,
            DelayAsync: delay.DelayAsync));

        var pcBytes = MakeBytes(40_000, seed: 0x3C);
        await rig.Pc.AddLocalContentsAsync([new ClipboardContent("file", Filename: "inflight.bin", Data: pcBytes)]);
        var pcItem = Assert.Single(rig.Store.Pending(rig.DeviceId));

        var pad = await rig.ConnectAsync();
        var bleOffer = await pad.WaitForMessageAsync<SyncOffer>();
        Assert.Equal(pcItem.Id, bleOffer.Id);

        // iOS concurrently sends wifi_request for its own upload (NOT including pcItem.Id).
        var padBytes = MakeBytes(520_000, seed: 0x4D);
        var padOffer = MakeOffer(Guid.NewGuid(), "pad", padBytes, filename: "pad-up.bin");
        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [padOffer.Id]));
        var ready = await pad.WaitForMessageAsync<WifiReady>();
        var handle = rig.Host.LastHandle!;
        await handle.AcceptStarted.WaitAsync(TimeSpan.FromSeconds(5));

        // At +65s (past BLE's 60s ReplyTimeout for pcItem, before 90s Wi-Fi TTL), BLE & Wi-Fi must NOT drop.
        rig.Now = rig.Now.AddSeconds(65);
        await rig.Pc.TickAsync(rig.Now);
        Assert.False(pad.Peer.Rejected);
        Assert.False(handle.IsDisposed);

        // Complete Wi-Fi transfer.
        var pipe = new DuplexPipe();
        handle.ProvideConnection(pipe.PcEnd, pipe.PcEnd.CloseWrite);
        var keys = WifiTransferKeys.Derive(pad.Keys, ready.Token, ready.Session);
        await WifiTransferEngine.RunPadSessionAsync(
            pipe.PadEnd,
            keys,
            outgoing: [new InMemoryWifiTransferSource(padOffer, padBytes)],
            sink: new InMemoryWifiTransferSink());
        pipe.PadEnd.CloseWrite();
        await rig.Pc.WaitForWifiIdleAsync();

        // After teardown, pcItem's reply deadline was refreshed (survives +50s more) and BLE resume succeeds.
        rig.Now = rig.Now.AddSeconds(50);
        await rig.Pc.TickAsync(rig.Now);
        Assert.False(pad.Peer.Rejected);

        await pad.SendSyncAsync(new SyncResume(pcItem.Id, 0));
        var chunk = await pad.WaitForMessageAsync<SyncChunk>();
        Assert.Equal(pcItem.Id, chunk.Id);
        Assert.Equal(0, chunk.Offset);
    }

    private sealed class AsyncFakeApBackend : IWifiApBackend
    {
        public bool Online { get; set; }
        public List<string> Calls { get; } = [];
        public Func<WifiTransferCredentials, CancellationToken, Task<WifiApAttemptResult>> OnHotspot { get; set; } =
            (c, _) => Task.FromResult(WifiApAttemptResult.Success(new FakeWifiSessionHandle(WifiApMode.Hotspot5GHz, c.Ssid)));
        public Func<WifiTransferCredentials, CancellationToken, Task<WifiApAttemptResult>> OnDirect { get; set; } =
            (c, _) => Task.FromResult(WifiApAttemptResult.Success(new FakeWifiSessionHandle(WifiApMode.WifiDirect, c.Ssid)));

        public bool HasInternetConnection() => Online;

        public Task<WifiApAttemptResult> TryStartHotspotAsync(WifiTransferCredentials credentials, CancellationToken cancellationToken)
        {
            Calls.Add("hotspot");
            return OnHotspot(credentials, cancellationToken);
        }

        public Task<WifiApAttemptResult> TryStartWifiDirectAsync(WifiTransferCredentials credentials, CancellationToken cancellationToken)
        {
            Calls.Add("wifiDirect");
            return OnDirect(credentials, cancellationToken);
        }
    }

    [Fact]
    public async Task ApStarterPrimaryTimeoutFallsBackToWifiDirectAndDisposesLateHandle()
    {
        var delay = new ControlledDelay();
        var creds = WifiTransferCredentials.CreateRandom();
        var logs = new List<string>();
        var hungHotspot = new TaskCompletionSource<WifiApAttemptResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var hotspotCancelled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var backend = new AsyncFakeApBackend
        {
            Online = true,
            OnHotspot = (_, ct) =>
            {
                ct.Register(() => hotspotCancelled.TrySetResult());
                return hungHotspot.Task;
            },
        };

        var startTask = WifiApStarter.StartWithFallbackAsync(
            backend,
            creds,
            logs.Add,
            delayAsync: delay.DelayAsync);

        // Primary hotspot times out at DefaultPrimaryAttemptTimeout (7s).
        var primaryWait = await delay.WaitForRequestedDelayAsync(WifiApStarter.DefaultPrimaryAttemptTimeout).WaitAsync(TimeSpan.FromSeconds(5));
        primaryWait.Trigger();
        await hotspotCancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));

        // Settle delay (800ms) runs before Wi-Fi Direct fallback.
        var settleWait = await delay.WaitForRequestedDelayAsync(WifiApStarter.DefaultFallbackDelay).WaitAsync(TimeSpan.FromSeconds(5));
        settleWait.Trigger();

        var result = await startTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(result.Succeeded);
        Assert.Equal(WifiApMode.WifiDirect, result.Handle!.Mode);
        Assert.Equal(["hotspot", "wifiDirect"], backend.Calls);
        Assert.Contains(logs, l => l == "wifi ap primary failed mode=hotspot reason=timeout");
        await result.Handle.DisposeAsync();

        // If the abandoned hung hotspot later resolves with a handle, it is disposed automatically.
        var lateHandle = new FakeWifiSessionHandle(WifiApMode.Hotspot5GHz, creds.Ssid);
        hungHotspot.SetResult(WifiApAttemptResult.Success(lateHandle));
        await lateHandle.Disposed.WaitAsync(TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task ApStarterTotalTimeout15SecondsCapsPrimaryFailureAndHungFallback()
    {
        var delay = new ControlledDelay();
        var creds = WifiTransferCredentials.CreateRandom();
        var logs = new List<string>();
        var hungDirect = new TaskCompletionSource<WifiApAttemptResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var directStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var directCancelled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var backend = new AsyncFakeApBackend
        {
            Online = true,
            OnHotspot = (_, _) => Task.FromResult(WifiApAttemptResult.Failure("hotspot_start_timeout")),
            OnDirect = (_, ct) =>
            {
                directStarted.TrySetResult();
                ct.Register(() => directCancelled.TrySetResult());
                return hungDirect.Task;
            },
        };

        var startTask = WifiApStarter.StartWithFallbackAsync(
            backend,
            creds,
            logs.Add,
            delayAsync: delay.DelayAsync);

        var totalWait = await delay.WaitForRequestedDelayAsync(TimeSpan.FromSeconds(15)).WaitAsync(TimeSpan.FromSeconds(5));
        var settleWait = await delay.WaitForRequestedDelayAsync(WifiApStarter.DefaultFallbackDelay).WaitAsync(TimeSpan.FromSeconds(5));
        settleWait.Trigger();
        await directStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));

        // Overall 15-second budget expires while Wi-Fi Direct is still starting.
        totalWait.Trigger();
        await directCancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));

        var result = await startTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(result.Succeeded);
        Assert.Null(result.Handle);
        Assert.Equal(WifiUnavailableReason.StartFailed, result.FailureReason);
        Assert.Contains(logs, l => l == "wifi ap primary failed mode=hotspot reason=hotspot_start_timeout");
        Assert.Contains(logs, l => l == "wifi ap fallback failed mode=wifiDirect reason=total_timeout");
    }

    [Fact]
    public async Task WifiStepTimeoutAbortsHungStepAndRespectsCallerCancellation()
    {
        var delay = new ControlledDelay();
        var hung = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        var stepCancelled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var runTask = WifiStepTimeout.RunAsync(
            ct =>
            {
                ct.Register(() => stepCancelled.TrySetResult());
                return hung.Task;
            },
            TimeSpan.FromSeconds(2),
            "hotspot_band_timeout",
            CancellationToken.None,
            delay.DelayAsync);

        var stepWait = await delay.WaitForRequestedDelayAsync(TimeSpan.FromSeconds(2)).WaitAsync(TimeSpan.FromSeconds(5));
        stepWait.Trigger();

        var ex = await Assert.ThrowsAsync<WifiStepTimeoutException>(() => runTask);
        Assert.Equal("hotspot_band_timeout", ex.Code);
        await stepCancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));

        // Caller cancellation throws OperationCanceledException instead of WifiStepTimeoutException.
        using var callerCts = new CancellationTokenSource();
        var hung2 = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancelTask = WifiStepTimeout.RunAsync(
            _ => hung2.Task,
            TimeSpan.FromSeconds(4),
            "hotspot_start_timeout",
            callerCts.Token,
            delay.DelayAsync);
        _ = await delay.WaitForRequestedDelayAsync(TimeSpan.FromSeconds(4)).WaitAsync(TimeSpan.FromSeconds(5));
        callerCts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cancelTask);
    }

    [Fact]
    public async Task CoordinatorEnforces15SecondStartTimeoutWhenWifiHostHangs()
    {
        var delay = new ControlledDelay();
        var hungStart = new TaskCompletionSource<WifiHostStartResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var hostCancelled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var host = new FakeWifiHost
        {
            CustomStart = (_, ct) =>
            {
                ct.Register(() => hostCancelled.TrySetResult());
                return hungStart.Task;
            },
        };
        await using var rig = new Rig(
            NewRoot(),
            host: host,
            options: new WifiTransferOptions(DelayAsync: delay.DelayAsync));
        var pad = await rig.ConnectAsync();

        await pad.SendWifiAsync(new WifiRequest(WifiTransferDirection.Send, [Guid.NewGuid()]));
        var startWait = await delay.WaitForRequestedDelayAsync(TimeSpan.FromSeconds(15)).WaitAsync(TimeSpan.FromSeconds(5));
        startWait.Trigger();

        await hostCancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var unavailable = await pad.WaitForMessageAsync<WifiUnavailable>();
        Assert.Equal(WifiUnavailableReason.StartFailed, unavailable.Reason);
        await rig.Pc.WaitForWifiIdleAsync();

        // Late-resolving host handle after timeout is disposed cleanly.
        var lateHandle = new FakeWifiSessionHandle(WifiApMode.Hotspot5GHz, "DIRECT-cp-LATE0001");
        hungStart.SetResult(WifiHostStartResult.Success(lateHandle));
        await lateHandle.Disposed.WaitAsync(TimeSpan.FromSeconds(5));
    }
}
