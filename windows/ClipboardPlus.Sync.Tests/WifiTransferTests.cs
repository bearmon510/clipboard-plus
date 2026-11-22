using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using ClipboardPlus.Sync;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class WifiTransferTests : IDisposable
{
    private readonly JsonDocument vectors = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "test-vectors.json")));
    private JsonElement V => vectors.RootElement;
    private JsonElement H => V.GetProperty("handshake");
    private JsonElement W => V.GetProperty("wifiTransfer");
    private static byte[] Hex(JsonElement e, string key) => Convert.FromHexString(e.GetProperty(key).GetString()!);
    private SyncPairing Pair => SyncPairing.Parse(V.GetProperty("pairing").GetProperty("qr").GetString()!);
    private static void Error(SyncError code, Action action) => Assert.Equal(code, Assert.Throws<SyncProtocolException>(action).Code);
    private static async Task ErrorAsync(SyncError code, Func<Task> action) =>
        Assert.Equal(code, (await Assert.ThrowsAsync<SyncProtocolException>(action)).Code);

    public void Dispose() => vectors.Dispose();

    private static SyncOffer MakeOffer(Guid id, string from, byte[] data, string name = "sample.bin", string kind = "file", string type = "public.data") =>
        new(
            id,
            1794873600123L,
            from,
            kind,
            data.Length,
            Convert.ToHexStringLower(SHA256.HashData(data)),
            Convert.ToBase64String(Encoding.UTF8.GetBytes(name)),
            type);

    private static byte[] MakeDeterministicBytes(int length, byte seed = 0x5A)
    {
        var data = new byte[length];
        for (var i = 0; i < length; i++)
            data[i] = (byte)((i * 31 + seed) & 0xFF);
        return data;
    }

    private static WifiTransferKeys MakeSessionKeys(Guid? session = null)
    {
        var pairing = SyncPairing.Create("test-pc");
        var pad = new SyncPadHandshake(pairing, Guid.NewGuid());
        var pc = new SyncPcHandshake(pairing);
        var welcome = pc.AcceptHello(pad.CreateHello());
        var auth = pad.AcceptWelcome(welcome);
        var pcKeys = pc.AcceptAuth(auth.Auth);
        Assert.True(auth.Keys.SupportsWifiTransfer);
        Assert.True(pcKeys.SupportsWifiTransfer);
        Assert.Equal(auth.Keys.WifiBaseKey, pcKeys.WifiBaseKey);
        var token = RandomNumberGenerator.GetBytes(32);
        return WifiTransferKeys.Derive(auth.Keys, token, session ?? Guid.NewGuid());
    }

    /// <summary>
    /// Full-duplex in-memory byte pipe supporting partial reads, abrupt disconnect/truncation, and wire-level interception.
    /// </summary>
    private sealed class InMemoryDuplexPipe
    {
        public PipeEnd PadEnd { get; }
        public PipeEnd PcEnd { get; }

        public InMemoryDuplexPipe(Func<byte[], byte[]>? padToPcTransform = null, Func<byte[], byte[]>? pcToPadTransform = null, int? cutPadToPcAfterBytes = null)
        {
            var padToPc = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true });
            var pcToPad = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true });
            PadEnd = new PipeEnd(pcToPad.Reader, padToPc.Writer, padToPcTransform, cutPadToPcAfterBytes);
            PcEnd = new PipeEnd(padToPc.Reader, pcToPad.Writer, pcToPadTransform, cutAfterBytes: null);
        }

        public sealed class PipeEnd : Stream
        {
            private readonly ChannelReader<byte[]> reader;
            private readonly ChannelWriter<byte[]> writer;
            private readonly Func<byte[], byte[]>? writeTransform;
            private readonly int? cutAfterBytes;
            private byte[]? current;
            private int currentOffset;
            private int writtenBytes;
            private bool writerClosed;

            public PipeEnd(ChannelReader<byte[]> reader, ChannelWriter<byte[]> writer, Func<byte[], byte[]>? writeTransform, int? cutAfterBytes)
            {
                this.reader = reader;
                this.writer = writer;
                this.writeTransform = writeTransform;
                this.cutAfterBytes = cutAfterBytes;
            }

            public void CloseWrite()
            {
                if (!writerClosed)
                {
                    writerClosed = true;
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
                if (writerClosed)
                    throw new IOException("Pipe closed");

                var chunk = buffer.ToArray();
                if (writeTransform is not null)
                    chunk = writeTransform(chunk);

                if (cutAfterBytes is int limit)
                {
                    var remaining = limit - writtenBytes;
                    if (remaining <= 0)
                    {
                        CloseWrite();
                        throw new IOException("Simulated pipe disconnect");
                    }
                    if (chunk.Length >= remaining)
                    {
                        if (remaining > 0)
                            writer.TryWrite(chunk[..remaining]);
                        writtenBytes += remaining;
                        CloseWrite();
                        return ValueTask.CompletedTask;
                    }
                }

                if (chunk.Length > 0)
                {
                    writtenBytes += chunk.Length;
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

    private sealed class PatternWifiTransferSource : IWifiTransferSource
    {
        public SyncOffer Offer { get; }
        public PatternWifiTransferSource(SyncOffer offer) => Offer = offer;

        public static string ComputePatternSha256(int totalBytes)
        {
            using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var block = new byte[64 * 1024];
            var offset = 0;
            while (offset < totalBytes)
            {
                var count = Math.Min(block.Length, totalBytes - offset);
                Fill(block.AsSpan(0, count), offset);
                hasher.AppendData(block, 0, count);
                offset += count;
            }
            return Convert.ToHexStringLower(hasher.GetHashAndReset());
        }

        private static void Fill(Span<byte> dest, int startOffset)
        {
            for (var i = 0; i < dest.Length; i++)
                dest[i] = (byte)(((startOffset + i) * 17 + 3) & 0xFF);
        }

        public Task<int> ReadChunkAsync(int offset, Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            var count = Math.Min(buffer.Length, Offer.Size - offset);
            Fill(buffer.Span[..count], offset);
            return Task.FromResult(count);
        }
    }

    private sealed class StreamingHashWifiTransferSink : IWifiTransferSink
    {
        private SyncOffer? currentOffer;
        private IncrementalHash? hasher;
        private int written;
        public int CompletedCount { get; private set; }
        public int CompletedBytes { get; private set; }

        public Task<WifiOfferDecision> BeginOfferAsync(SyncOffer offer, CancellationToken cancellationToken = default)
        {
            SyncMessageCodec.ValidateOffer(offer, maxSize: SyncProtocol.MaxWifiItemBytes);
            currentOffer = offer;
            hasher?.Dispose();
            hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            written = 0;
            return Task.FromResult(WifiOfferDecision.Resume(0));
        }

        public Task<int> AppendChunkAsync(Guid id, int offset, ReadOnlyMemory<byte> data, CancellationToken cancellationToken = default)
        {
            if (currentOffer is null || currentOffer.Id != id || offset != written)
                throw new SyncProtocolException(SyncError.State);
            hasher!.AppendData(data.Span);
            written += data.Length;
            return Task.FromResult(written);
        }

        public Task VerifyAndCompleteAsync(SyncOffer offer, CancellationToken cancellationToken = default)
        {
            if (currentOffer is null || currentOffer != offer)
                throw new SyncProtocolException(SyncError.State);
            var digest = Convert.ToHexStringLower(hasher!.GetHashAndReset());
            hasher.Dispose();
            hasher = null;
            if (written != offer.Size || !string.Equals(digest, offer.Sha256, StringComparison.Ordinal))
            {
                currentOffer = null;
                written = 0;
                throw new SyncProtocolException(SyncError.Authentication);
            }
            CompletedCount++;
            CompletedBytes = written;
            currentOffer = null;
            return Task.CompletedTask;
        }

        public Task DiscardPartialAsync(Guid id, CancellationToken cancellationToken = default)
        {
            hasher?.Dispose();
            hasher = null;
            currentOffer = null;
            written = 0;
            return Task.CompletedTask;
        }
    }

    [Fact]
    public void LimitsAndLegacyV3CompatibilityMatchIndependentVectors()
    {
        var limits = V.GetProperty("limits");
        Assert.Equal(SyncProtocol.Version, V.GetProperty("version").GetInt32());
        Assert.Equal(SyncProtocol.MinSupportedVersion, V.GetProperty("minSupportedVersion").GetInt32());
        Assert.Equal(SyncProtocol.WifiTransferMinVersion, V.GetProperty("wifiTransferMinVersion").GetInt32());
        Assert.Equal(SyncProtocol.MaxWifiItemBytes, limits.GetProperty("maxWifiItemBytes").GetInt32());
        Assert.Equal(SyncProtocol.DefaultWifiThresholdBytes, limits.GetProperty("defaultWifiThresholdBytes").GetInt32());
        Assert.Equal(SyncProtocol.MaxWifiFrameBytes, limits.GetProperty("maxWifiFrameBytes").GetInt32());
        Assert.Equal(SyncProtocol.MaxWifiPlaintextBytes, limits.GetProperty("maxWifiPlaintextBytes").GetInt32());
        Assert.Equal(SyncProtocol.MaxWifiChunkBytes, limits.GetProperty("maxWifiChunkBytes").GetInt32());
        Assert.Equal(SyncProtocol.WifiDefaultTtlSeconds, limits.GetProperty("wifiDefaultTtlSeconds").GetInt32());
        Assert.Equal(SyncProtocol.WifiMaxTtlSeconds, limits.GetProperty("wifiMaxTtlSeconds").GetInt32());
        Assert.Equal(SyncProtocol.WifiMinPassphraseBytes, limits.GetProperty("wifiMinPassphraseBytes").GetInt32());
        Assert.Equal(SyncProtocol.WifiMaxPassphraseBytes, limits.GetProperty("wifiMaxPassphraseBytes").GetInt32());
        Assert.Equal(SyncProtocol.WifiMaxSsidBytes, limits.GetProperty("wifiMaxSsidBytes").GetInt32());
        Assert.Equal(SyncProtocol.WifiTcpVersion, limits.GetProperty("wifiTcpVersion").GetInt32());

        // v4 handshake produces wifiBaseKey and SupportsWifiTransfer = true.
        var padId = Guid.Parse(H.GetProperty("padId").GetString()!);
        var padV4 = new SyncPadHandshake(Pair, padId, Hex(H, "niHex"));
        var pcV4 = new SyncPcHandshake(Pair, padId, Hex(H, "npHex"));
        var authV4 = padV4.AcceptWelcome(pcV4.AcceptHello(padV4.CreateHello()));
        var pcKeysV4 = pcV4.AcceptAuth(authV4.Auth);
        Assert.Equal((byte)4, pcV4.NegotiatedVersion);
        Assert.Equal(Hex(H, "wifiBaseKeyHex"), authV4.Keys.WifiBaseKey);
        Assert.Equal(Hex(H, "wifiBaseKeyHex"), pcKeysV4.WifiBaseKey);
        Assert.True(authV4.Keys.SupportsWifiTransfer);
        Assert.True(pcKeysV4.SupportsWifiTransfer);

        // Old v3 Pad talking to v4 PC negotiates v3 cleanly with SupportsWifiTransfer = false.
        var legacy = V.GetProperty("legacyV3Handshake");
        var padV3 = new SyncPadHandshake(Pair, padId, Hex(H, "niHex"), protocolVersion: 3);
        var pcAcceptV3 = new SyncPcHandshake(Pair, padId, Hex(H, "npHex"));
        var v3Hello = padV3.CreateHello();
        Assert.Equal(Hex(legacy, "helloHex"), v3Hello);
        var v3Welcome = pcAcceptV3.AcceptHello(v3Hello);
        Assert.Equal(Hex(legacy, "welcomeHex"), v3Welcome);
        var v3Auth = padV3.AcceptWelcome(v3Welcome);
        Assert.Equal(Hex(legacy, "authHex"), v3Auth.Auth);
        var pcV3Keys = pcAcceptV3.AcceptAuth(v3Auth.Auth);
        Assert.Equal((byte)3, pcAcceptV3.NegotiatedVersion);
        foreach (var k in new[] { v3Auth.Keys, pcV3Keys })
        {
            Assert.Equal(3, k.ProtocolVersion);
            Assert.False(k.SupportsWifiTransfer);
            Assert.Null(k.WifiBaseKey);
            Assert.Equal(Hex(legacy, "padToPcKeyHex"), k.PadToPc);
            Assert.Equal(Hex(legacy, "pcToPadKeyHex"), k.PcToPad);
            Error(SyncError.State, () => WifiTransferKeys.Derive(k, RandomNumberGenerator.GetBytes(32), Guid.NewGuid()));
        }

        // v4 Pad talking to an unmodified v3 PC detects SuggestedFallbackVersion == 3.
        var probePad = new SyncPadHandshake(Pair, padId, Hex(H, "niHex"));
        probePad.CreateHello();
        Error(SyncError.Version, () => probePad.AcceptWelcome(Hex(legacy, "v3PcMismatchForV4HelloHex")));
        Assert.Equal((byte)3, probePad.SuggestedFallbackVersion);

        // Unsupported v2 mismatch from same PC must NOT suggest a fallback version.
        var v2MismatchPad = new SyncPadHandshake(Pair, padId, Hex(H, "niHex"));
        v2MismatchPad.CreateHello();
        Error(SyncError.Version, () => v2MismatchPad.AcceptWelcome(Hex(V.GetProperty("failures").GetProperty("versionMismatchSamePc"), "frameHex")));
        Assert.Null(v2MismatchPad.SuggestedFallbackVersion);
    }

    [Fact]
    public void WifiControlMessagesFramesAndFailuresMatchIndependentVectors()
    {
        var controlMessages = V.GetProperty("wifiControlMessages");
        foreach (var fixture in controlMessages.EnumerateObject())
        {
            var plaintext = Hex(fixture.Value, "plaintextHex");
            var decoded = WifiControlMessageCodec.Decode(plaintext);
            Assert.Equal(plaintext, WifiControlMessageCodec.Encode(decoded));
            var headerLen = BinaryPrimitives.ReadUInt16BigEndian(plaintext);
            Assert.Equal(fixture.Value.GetProperty("headerJson").GetString(), Encoding.ASCII.GetString(plaintext, 2, headerLen));

            if (decoded is WifiReady ready)
            {
                var summary = ready.ToString();
                Assert.DoesNotContain(ready.Ssid, summary);
                Assert.DoesNotContain(ready.Passphrase, summary);
                Assert.DoesNotContain(ready.Ip, summary);
                Assert.DoesNotContain(Convert.ToHexStringLower(ready.Token), summary);
                Assert.DoesNotContain(ready.Session.ToString("D"), summary);
            }
        }

        foreach (var direction in new[] { "pad->pc", "pc->pad" })
        {
            var key = Hex(H, direction == "pad->pc" ? "padToPcKeyHex" : "pcToPadKeyHex");
            var sender = new SyncFrameSender(key);
            var receiver = new SyncFrameReceiver(key);
            foreach (var f in V.GetProperty("wifiControlFrames").EnumerateArray().Where(x => x.GetProperty("direction").GetString() == direction))
            {
                var plaintext = Hex(controlMessages.GetProperty(f.GetProperty("message").GetString()!), "plaintextHex");
                var expected = Hex(f, "frameHex");
                Assert.Equal(expected, sender.Seal(plaintext));
                Assert.Equal(plaintext, receiver.Open(expected));
            }
        }

        foreach (var failure in V.GetProperty("wifiControlFailures").EnumerateObject())
        {
            var expected = failure.Value.GetProperty("error").GetString() == "limit" ? SyncError.Limit : SyncError.Format;
            Error(expected, () => WifiControlMessageCodec.Decode(Hex(failure.Value, "plaintextHex")));
        }

        // Valid private and link-local IPv4 ranges.
        foreach (var ip in new[] { "192.168.137.1", "10.0.0.1", "172.16.0.1", "172.31.255.254", "169.254.1.1", "169.254.254.254" })
            Assert.True(WifiControlMessageCodec.IsValidLocalIpv4(ip));
        foreach (var badIp in new[] { "", "0.0.0.0", "127.0.0.1", "8.8.8.8", "172.15.0.1", "172.32.0.1", "169.254.0.1", "169.254.255.1", "192.168.0.0", "192.168.255.255", "192.168.01.1", "255.255.255.255" })
            Assert.False(WifiControlMessageCodec.IsValidLocalIpv4(badIp));

        // Exceeding MaxPending IDs in wifi_request throws Limit.
        var tooManyIds = Enumerable.Range(0, SyncProtocol.MaxPending + 1).Select(_ => Guid.NewGuid()).ToArray();
        Error(SyncError.Limit, () => WifiControlMessageCodec.Encode(new WifiRequest(WifiTransferDirection.Send, tooManyIds)));
    }

    [Fact]
    public void WifiKeyDerivationTcpHandshakeStreamMessagesFramesAndFailuresMatchVectors()
    {
        var session = Guid.Parse(W.GetProperty("session").GetString()!);
        var bleBase = Hex(W, "bleWifiBaseKeyHex");
        var token = Hex(W, "tokenHex");
        var transferKeys = WifiTransferKeys.Derive(bleBase, token, session);

        Assert.Equal(Hex(W, "transferKeyHex"), transferKeys.TransferKey);
        Assert.Equal(Hex(W, "authKeyHex"), transferKeys.AuthKey);
        // Derived keys must never equal the BLE session keys or base key.
        Assert.NotEqual(Hex(H, "padToPcKeyHex"), transferKeys.TransferKey);
        Assert.NotEqual(Hex(H, "pcToPadKeyHex"), transferKeys.TransferKey);
        Assert.NotEqual(bleBase, transferKeys.TransferKey);
        Assert.NotEqual(transferKeys.TransferKey, transferKeys.AuthKey);
        Assert.DoesNotContain(Convert.ToHexStringLower(transferKeys.TransferKey), transferKeys.ToString());
        Assert.DoesNotContain(Convert.ToHexStringLower(transferKeys.AuthKey), transferKeys.ToString());

        var padHs = new WifiTcpPadHandshake(transferKeys, Hex(W, "padNonceHex"));
        var pcHs = new WifiTcpPcHandshake(transferKeys, Hex(W, "pcNonceHex"));
        var tcpHello = padHs.CreateHello();
        Assert.Equal(Hex(W, "tcpHelloHex"), tcpHello);
        var tcpWelcome = pcHs.AcceptHello(tcpHello);
        Assert.Equal(Hex(W, "tcpWelcomeHex"), tcpWelcome);
        Assert.Equal(Hex(W, "pcHmacHex"), tcpWelcome[54..]);
        var padAuth = padHs.AcceptWelcome(tcpWelcome);
        Assert.Equal(Hex(W, "tcpAuthHex"), padAuth.Auth);
        Assert.Equal(Hex(W, "padHmacHex"), padAuth.Auth[6..]);
        var pcTraffic = pcHs.AcceptAuth(padAuth.Auth);
        Assert.True(pcHs.IsAuthenticated);

        foreach (var tk in new[] { padAuth.Keys, pcTraffic })
        {
            Assert.Equal(Hex(W, "padToPcKeyHex"), tk.PadToPc);
            Assert.Equal(Hex(W, "pcToPadKeyHex"), tk.PcToPad);
            Assert.NotEqual(tk.PadToPc, tk.PcToPad);
            Assert.DoesNotContain(Convert.ToHexStringLower(tk.PadToPc), tk.ToString());
        }

        // Single-use handshake state enforcement.
        Error(SyncError.State, () => padHs.CreateHello());
        Error(SyncError.State, () => padHs.AcceptWelcome(tcpWelcome));
        Error(SyncError.State, () => pcHs.AcceptAuth(padAuth.Auth));

        var streamMessages = W.GetProperty("streamMessages");
        foreach (var fixture in streamMessages.EnumerateObject())
        {
            var plaintext = Hex(fixture.Value, "plaintextHex");
            var decoded = WifiStreamMessageCodec.Decode(plaintext);
            Assert.Equal(plaintext, WifiStreamMessageCodec.Encode(decoded));
            var headerLen = BinaryPrimitives.ReadUInt16BigEndian(plaintext);
            Assert.Equal(fixture.Value.GetProperty("headerJson").GetString(), Encoding.ASCII.GetString(plaintext, 2, headerLen));
        }

        foreach (var direction in new[] { "pad->pc", "pc->pad" })
        {
            var dirEnum = direction == "pad->pc" ? WifiStreamDirection.PadToPc : WifiStreamDirection.PcToPad;
            var key = Hex(W, direction == "pad->pc" ? "padToPcKeyHex" : "pcToPadKeyHex");
            var sender = new WifiStreamFrameSender(key, dirEnum);
            var receiver = new WifiStreamFrameReceiver(key, dirEnum);
            foreach (var f in W.GetProperty("streamFrames").EnumerateArray().Where(x => x.GetProperty("direction").GetString() == direction))
            {
                var plaintext = Hex(streamMessages.GetProperty(f.GetProperty("message").GetString()!), "plaintextHex");
                var expected = Hex(f, "frameHex");
                Assert.Equal(expected, sender.Seal(plaintext));
                Assert.Equal(plaintext, receiver.Open(expected));
                Assert.Equal(Hex(f, "aadHex"), expected[..14]);
                Assert.Equal(Hex(f, "tagHex"), expected[^16..]);
            }
        }

        // Vector failures.
        var failures = W.GetProperty("failures");
        var padToPcKey = Hex(W, "padToPcKeyHex");
        var rxTamperedTag = new WifiStreamFrameReceiver(padToPcKey, WifiStreamDirection.PadToPc);
        Error(SyncError.Authentication, () => rxTamperedTag.Open(Hex(failures.GetProperty("tamperedTag"), "frameHex")));
        Error(SyncError.State, () => rxTamperedTag.Open(Hex(W.GetProperty("streamFrames")[0], "frameHex")));

        Error(SyncError.Authentication, () => new WifiStreamFrameReceiver(padToPcKey, WifiStreamDirection.PadToPc)
            .Open(Hex(failures.GetProperty("tamperedCiphertext"), "frameHex")));
        Error(SyncError.Authentication, () => new WifiStreamFrameReceiver(padToPcKey, WifiStreamDirection.PadToPc)
            .Open(Hex(failures.GetProperty("wrongDirection"), "frameHex")));
        Error(SyncError.Packet, () => new WifiStreamFrameReceiver(padToPcKey, WifiStreamDirection.PadToPc)
            .Open(Hex(failures.GetProperty("truncatedFrame"), "frameHex")));

        var reordered = failures.GetProperty("reordered").GetProperty("framesHex");
        var rxReorder = new WifiStreamFrameReceiver(padToPcKey, WifiStreamDirection.PadToPc);
        rxReorder.Open(Convert.FromHexString(reordered[0].GetString()!));
        Error(SyncError.Sequence, () => rxReorder.Open(Convert.FromHexString(reordered[1].GetString()!)));

        var duplicate = failures.GetProperty("duplicate").GetProperty("framesHex");
        var rxDup = new WifiStreamFrameReceiver(padToPcKey, WifiStreamDirection.PadToPc);
        rxDup.Open(Convert.FromHexString(duplicate[0].GetString()!));
        Error(SyncError.Sequence, () => rxDup.Open(Convert.FromHexString(duplicate[1].GetString()!)));

        var badWelcomePad = new WifiTcpPadHandshake(transferKeys, Hex(W, "padNonceHex"));
        badWelcomePad.CreateHello();
        Error(SyncError.Authentication, () => badWelcomePad.AcceptWelcome(Hex(failures.GetProperty("wrongTcpWelcomeHmac"), "frameHex")));

        var badAuthPc = new WifiTcpPcHandshake(transferKeys, Hex(W, "pcNonceHex"));
        badAuthPc.AcceptHello(tcpHello);
        Error(SyncError.Authentication, () => badAuthPc.AcceptAuth(Hex(failures.GetProperty("wrongTcpAuthHmac"), "frameHex")));

        Error(SyncError.Identity, () => new WifiTcpPcHandshake(transferKeys, Hex(W, "pcNonceHex"))
            .AcceptHello(Hex(failures.GetProperty("wrongTcpSession"), "frameHex")));
        Error(SyncError.Version, () => new WifiTcpPcHandshake(transferKeys, Hex(W, "pcNonceHex"))
            .AcceptHello(Hex(failures.GetProperty("wrongTcpVersion"), "frameHex")));

        Error(SyncError.Limit, () => WifiStreamMessageCodec.Decode(Hex(failures.GetProperty("oversizedWifiOffer"), "plaintextHex")));
        var oversizedChunkBytes = failures.GetProperty("oversizedWifiChunk").GetProperty("chunkBytes").GetInt32();
        Error(SyncError.Limit, () => WifiStreamMessageCodec.Encode(new WifiStreamChunk(Guid.NewGuid(), 0, new byte[oversizedChunkBytes])));
        var oversizedPlain = new byte[SyncProtocol.MaxWifiPlaintextBytes + 1];
        Error(SyncError.Limit, () => new WifiStreamFrameSender(padToPcKey, WifiStreamDirection.PadToPc).Seal(oversizedPlain));
        Error(SyncError.Limit, () => new WifiStreamFrameReceiver(padToPcKey, WifiStreamDirection.PadToPc).Open(new byte[SyncProtocol.MaxWifiFrameBytes + 1]));
    }

    [Fact]
    public async Task InMemoryPipeNormalBidirectionalMultiItemAndEmptyTransfer()
    {
        var keys = MakeSessionKeys();
        var guard = new WifiSessionReplayGuard();
        var pipe = new InMemoryDuplexPipe();

        var padFile1 = MakeDeterministicBytes(700_000, seed: 1); // Spans multiple 252 KiB frames
        var padFile2 = Array.Empty<byte>();                        // Empty 0-byte file
        var pcFile1 = MakeDeterministicBytes(600_000, seed: 2);

        var padOffer1 = MakeOffer(Guid.NewGuid(), "pad", padFile1, "photo.png", kind: "image", type: "public.png");
        var padOffer2 = MakeOffer(Guid.NewGuid(), "pad", padFile2, "empty.txt", kind: "file", type: "public.data");
        var pcOffer1 = MakeOffer(Guid.NewGuid(), "pc", pcFile1, "report.pdf", kind: "file", type: "com.adobe.pdf");

        var pcSink = new InMemoryWifiTransferSink();
        var padSink = new InMemoryWifiTransferSink();

        var padTask = WifiTransferEngine.RunPadSessionAsync(
            pipe.PadEnd,
            keys,
            [new InMemoryWifiTransferSource(padOffer1, padFile1), new InMemoryWifiTransferSource(padOffer2, padFile2)],
            padSink);
        var pcTask = WifiTransferEngine.RunPcSessionAsync(
            pipe.PcEnd,
            keys,
            [new InMemoryWifiTransferSource(pcOffer1, pcFile1)],
            pcSink,
            replayGuard: guard);

        var results = await Task.WhenAll(padTask, pcTask);
        var padResult = results[0];
        var pcResult = results[1];

        Assert.Equal(2, padResult.Sent.Count);
        Assert.Equal(padFile1.Length, padResult.Sent[0].TransferredBytes);
        Assert.Equal(0, padResult.Sent[1].TransferredBytes);
        Assert.Single(padResult.Received);
        Assert.Equal(pcFile1, padSink.Completed[pcOffer1.Id].Data);

        Assert.Equal(2, pcResult.Received.Count);
        Assert.Equal(padFile1, pcSink.Completed[padOffer1.Id].Data);
        Assert.Equal(padFile2, pcSink.Completed[padOffer2.Id].Data);
        Assert.Single(pcResult.Sent);
        Assert.True(guard.IsConsumed(keys.Session));
    }

    [Fact]
    public async Task InMemoryPipeDisconnectMidTransferResumesFromSavedOffset()
    {
        var payload = MakeDeterministicBytes(800_000, seed: 9);
        var offer = MakeOffer(Guid.NewGuid(), "pad", payload, "big.bin");
        var pcSink = new InMemoryWifiTransferSink();
        var padSink = new InMemoryWifiTransferSink();

        // Session 1: cut the pipe mid-transfer after ~300 KB so 1st chunk succeeds and later chunk is truncated.
        var replayGuard = new WifiSessionReplayGuard();
        var keys1 = MakeSessionKeys();
        var brokenPipe = new InMemoryDuplexPipe(cutPadToPcAfterBytes: 300_000);
        var padTask1 = WifiTransferEngine.RunPadSessionAsync(
            brokenPipe.PadEnd,
            keys1,
            [new InMemoryWifiTransferSource(offer, payload)],
            padSink,
            chunkSize: 128 * 1024);
        var pcTask1 = WifiTransferEngine.RunPcSessionAsync(
            brokenPipe.PcEnd,
            keys1,
            [],
            pcSink,
            replayGuard: replayGuard);

        await ErrorAsync(SyncError.Packet, () => pcTask1);
        brokenPipe.PcEnd.CloseWrite();
        await Assert.ThrowsAnyAsync<Exception>(() => padTask1);

        // Mutual auth succeeded before truncation, so keys1.Session is already consumed and cannot be reused.
        Assert.True(replayGuard.IsConsumed(keys1.Session));
        var replayCutPipe = new InMemoryDuplexPipe();
        var replayCutPad = WifiTransferEngine.RunPadSessionAsync(
            replayCutPipe.PadEnd,
            keys1,
            [new InMemoryWifiTransferSource(offer, payload)],
            padSink);
        var replayCutPc = WifiTransferEngine.RunPcSessionAsync(
            replayCutPipe.PcEnd,
            keys1,
            [],
            pcSink,
            replayGuard: replayGuard);
        await ErrorAsync(SyncError.State, () => replayCutPc);
        replayCutPipe.PcEnd.CloseWrite();
        await Assert.ThrowsAnyAsync<Exception>(() => replayCutPad);

        Assert.True(pcSink.HasPartial(offer.Id));
        var savedBeforeResume = pcSink.PartialLength(offer.Id);
        Assert.InRange(savedBeforeResume, 128 * 1024, payload.Length - 1);
        Assert.DoesNotContain(offer.Id, pcSink.Completed.Keys);

        // Session 2: fresh one-time session keys, same offer -> resumes from savedBeforeResume!
        var keys2 = MakeSessionKeys();
        var resumePipe = new InMemoryDuplexPipe();
        var padTask2 = WifiTransferEngine.RunPadSessionAsync(
            resumePipe.PadEnd,
            keys2,
            [new InMemoryWifiTransferSource(offer, payload)],
            padSink,
            chunkSize: 128 * 1024);
        var pcTask2 = WifiTransferEngine.RunPcSessionAsync(
            resumePipe.PcEnd,
            keys2,
            [],
            pcSink,
            replayGuard: replayGuard);

        var results = await Task.WhenAll(padTask2, pcTask2);
        var sentItem = Assert.Single(results[0].Sent);
        Assert.Equal(payload.Length - savedBeforeResume, sentItem.TransferredBytes);
        Assert.False(pcSink.HasPartial(offer.Id));
        Assert.Equal(payload, pcSink.Completed[offer.Id].Data);
    }

    [Fact]
    public async Task InMemoryPipeTamperingOnWireRejectedWithAuthenticationError()
    {
        var keys = MakeSessionKeys();
        var payload = MakeDeterministicBytes(10_000, seed: 3);
        var offer = MakeOffer(Guid.NewGuid(), "pad", payload, "tamper.bin");

        var writeCount = 0;
        // Writes on Pad->PC: #1 TCP_HELLO, #2 TCP_AUTH, #3 offer frame (tamper last byte of GCM tag!).
        var pipe = new InMemoryDuplexPipe(padToPcTransform: data =>
        {
            writeCount++;
            if (writeCount == 3 && data.Length > 0)
            {
                var tampered = data.ToArray();
                tampered[^1] ^= 0x01;
                return tampered;
            }
            return data;
        });

        var pcSink = new InMemoryWifiTransferSink();
        var padSink = new InMemoryWifiTransferSink();
        var pcTask = WifiTransferEngine.RunPcSessionAsync(pipe.PcEnd, keys, [], pcSink, new WifiSessionReplayGuard());
        var padTask = WifiTransferEngine.RunPadSessionAsync(pipe.PadEnd, keys, [new InMemoryWifiTransferSource(offer, payload)], padSink);

        await ErrorAsync(SyncError.Authentication, () => pcTask);
        pipe.PcEnd.CloseWrite();
        await Assert.ThrowsAnyAsync<Exception>(() => padTask);
        Assert.Empty(pcSink.Completed);
    }

    [Fact]
    public async Task InMemoryPipeReplayOfHandshakeSessionAndFramesRejected()
    {
        // 1. Replaying a recorded TCP_HELLO + TCP_AUTH to a fresh PC handshake fails (fresh pcNonce prevents replay).
        var keys = MakeSessionKeys();
        var capturedPadWrites = new List<byte[]>();
        var pipe1 = new InMemoryDuplexPipe(padToPcTransform: data =>
        {
            capturedPadWrites.Add(data.ToArray());
            return data;
        });

        var guard = new WifiSessionReplayGuard();
        var padTask1 = WifiTransferEngine.RunPadSessionAsync(pipe1.PadEnd, keys, [], new InMemoryWifiTransferSink());
        var pcTask1 = WifiTransferEngine.RunPcSessionAsync(pipe1.PcEnd, keys, [], new InMemoryWifiTransferSink(), replayGuard: guard);
        await Task.WhenAll(padTask1, pcTask1);

        var recordedHello = capturedPadWrites[0];
        var recordedAuth = capturedPadWrites[1];
        var freshPcHs = new WifiTcpPcHandshake(keys);
        _ = freshPcHs.AcceptHello(recordedHello);
        Error(SyncError.Authentication, () => freshPcHs.AcceptAuth(recordedAuth));

        // 2. Replaying the already-consumed session UUID against the replay guard is rejected immediately.
        var pipe2 = new InMemoryDuplexPipe();
        var padTask2 = WifiTransferEngine.RunPadSessionAsync(pipe2.PadEnd, keys, [], new InMemoryWifiTransferSink());
        var pcTask2 = WifiTransferEngine.RunPcSessionAsync(pipe2.PcEnd, keys, [], new InMemoryWifiTransferSink(), replayGuard: guard);
        await ErrorAsync(SyncError.State, () => pcTask2);
        pipe2.PcEnd.CloseWrite();
        await Assert.ThrowsAnyAsync<Exception>(() => padTask2);

        // 3. Replaying an encrypted stream frame inside an active pipe is rejected with Sequence.
        var keys3 = MakeSessionKeys();
        var payload = MakeDeterministicBytes(1000);
        var offer = MakeOffer(Guid.NewGuid(), "pad", payload);
        var writes = 0;
        var pipe3 = new InMemoryDuplexPipe(padToPcTransform: data =>
        {
            writes++;
            // Duplicate the 3rd write (the offer encrypted frame) back-to-back on the wire.
            if (writes == 3) return [.. data, .. data];
            return data;
        });
        var pcTask3 = WifiTransferEngine.RunPcSessionAsync(pipe3.PcEnd, keys3, [], new InMemoryWifiTransferSink(), guard);
        var padTask3 = WifiTransferEngine.RunPadSessionAsync(pipe3.PadEnd, keys3, [new InMemoryWifiTransferSource(offer, payload)], new InMemoryWifiTransferSink());
        await ErrorAsync(SyncError.Sequence, () => pcTask3);
        pipe3.PcEnd.CloseWrite();
        await Assert.ThrowsAnyAsync<Exception>(() => padTask3);
    }

    [Fact]
    public async Task InMemoryPipeOversizedWireFrameHeaderRejectedImmediatelyWithLimit()
    {
        var keys = MakeSessionKeys();
        var pipe = new InMemoryDuplexPipe();

        var padConnect = WifiEncryptedStream.ConnectAsPadAsync(pipe.PadEnd, keys);
        var pcAccept = WifiEncryptedStream.AcceptAsPcAsync(pipe.PcEnd, keys, new WifiSessionReplayGuard());
        _ = await padConnect;
        var pcChannel = await pcAccept;

        // Inject a raw wire frame header advertising payloadLength = MaxWifiPlaintextBytes + 1 (> 256 KiB total).
        var bogusHeader = new byte[SyncProtocol.WifiFrameHeaderBytes];
        bogusHeader[0] = SyncProtocol.WifiFrameType;
        bogusHeader[1] = SyncProtocol.WifiDirectionPadToPc;
        BinaryPrimitives.WriteUInt32BigEndian(bogusHeader.AsSpan(2, 4), (uint)(SyncProtocol.MaxWifiPlaintextBytes + 1));
        BinaryPrimitives.WriteUInt64BigEndian(bogusHeader.AsSpan(6, 8), 0);
        await pipe.PadEnd.WriteAsync(bogusHeader);

        await ErrorAsync(SyncError.Limit, () => pcChannel.ReceiveMessageAsync());
    }

    [Fact]
    public async Task InMemoryPipeSha256MismatchDiscardsPartialAndRejectsWithoutAck()
    {
        var keys = MakeSessionKeys();
        var payload = MakeDeterministicBytes(20_000, seed: 7);
        // Corrupt the offer's declared sha256 so final verification fails.
        var badOffer = new SyncOffer(
            Guid.NewGuid(),
            1794873600123L,
            "pad",
            "file",
            payload.Length,
            new string('0', 64),
            Convert.ToBase64String(Encoding.UTF8.GetBytes("corrupt.bin")),
            "public.data");

        var pipe = new InMemoryDuplexPipe();
        var pcSink = new InMemoryWifiTransferSink();
        var padSink = new InMemoryWifiTransferSink();

        var pcTask = WifiTransferEngine.RunPcSessionAsync(pipe.PcEnd, keys, [], pcSink, new WifiSessionReplayGuard());
        var padTask = WifiTransferEngine.RunPadSessionAsync(pipe.PadEnd, keys, [new InMemoryWifiTransferSource(badOffer, payload)], padSink);

        await ErrorAsync(SyncError.Authentication, () => pcTask);
        pipe.PcEnd.CloseWrite();
        await Assert.ThrowsAnyAsync<Exception>(() => padTask);

        // Partial MUST be discarded on SHA-256 mismatch and item must NOT be committed.
        Assert.False(pcSink.HasPartial(badOffer.Id));
        Assert.Empty(pcSink.Completed);
    }

    [Fact]
    public async Task InMemoryPipeExact50MiBTransferSucceedsAndOver50MiBRejectedWithLimit()
    {
        // Over 50 MiB offer is rejected by codec and sender with Limit.
        var over50 = new SyncOffer(
            Guid.NewGuid(),
            1794873600123L,
            "pad",
            "file",
            SyncProtocol.MaxWifiItemBytes + 1,
            new string('a', 64),
            Convert.ToBase64String(Encoding.UTF8.GetBytes("huge.bin")),
            "public.data");
        Error(SyncError.Limit, () => WifiStreamMessageCodec.Encode(new WifiStreamOffer(over50)));

        var keysOver = MakeSessionKeys();
        var pipeOver = new InMemoryDuplexPipe();
        var pcTaskOver = WifiTransferEngine.RunPcSessionAsync(pipeOver.PcEnd, keysOver, [], new InMemoryWifiTransferSink(), new WifiSessionReplayGuard());
        var padTaskOver = WifiTransferEngine.RunPadSessionAsync(
            pipeOver.PadEnd,
            keysOver,
            [new PatternWifiTransferSource(over50)],
            new InMemoryWifiTransferSink());
        await ErrorAsync(SyncError.Limit, () => padTaskOver);
        pipeOver.PadEnd.CloseWrite();
        await ErrorAsync(SyncError.Packet, () => pcTaskOver);

        // Exact 50 MiB streaming transfer succeeds end-to-end with SHA-256 verification.
        var exact50Bytes = SyncProtocol.MaxWifiItemBytes;
        var exact50Hash = PatternWifiTransferSource.ComputePatternSha256(exact50Bytes);
        var exact50Offer = new SyncOffer(
            Guid.NewGuid(),
            1794873600123L,
            "pad",
            "file",
            exact50Bytes,
            exact50Hash,
            Convert.ToBase64String(Encoding.UTF8.GetBytes("exact50m.bin")),
            "public.data");

        var keys50 = MakeSessionKeys();
        var pipe50 = new InMemoryDuplexPipe();
        var streamingSink = new StreamingHashWifiTransferSink();
        var padTask50 = WifiTransferEngine.RunPadSessionAsync(
            pipe50.PadEnd,
            keys50,
            [new PatternWifiTransferSource(exact50Offer)],
            new InMemoryWifiTransferSink());
        var pcTask50 = WifiTransferEngine.RunPcSessionAsync(
            pipe50.PcEnd,
            keys50,
            [],
            streamingSink,
            new WifiSessionReplayGuard());

        var results = await Task.WhenAll(padTask50, pcTask50);
        Assert.Equal(exact50Bytes, Assert.Single(results[0].Sent).TransferredBytes);
        Assert.Equal(1, streamingSink.CompletedCount);
        Assert.Equal(exact50Bytes, streamingSink.CompletedBytes);
    }

    [Fact]
    public async Task InMemoryPipeCleanEofBeforeDoneDetectedAsTruncation()
    {
        var keys = MakeSessionKeys();
        var pipe = new InMemoryDuplexPipe();

        var padConnect = WifiEncryptedStream.ConnectAsPadAsync(pipe.PadEnd, keys);
        var pcAccept = WifiEncryptedStream.AcceptAsPcAsync(pipe.PcEnd, keys, new WifiSessionReplayGuard());
        _ = await padConnect;
        var pcChannel = await pcAccept;

        // Pad closes cleanly without sending authenticated Done frame.
        pipe.PadEnd.CloseWrite();
        await ErrorAsync(SyncError.Packet, () => WifiTransferEngine.ReceiveItemsAsync(pcChannel, new InMemoryWifiTransferSink(), expectedFrom: "pad"));
    }

    [Fact]
    public async Task InMemoryPipeReorderedAndMissingFramesDetectedWithSequence()
    {
        // Reorder two encrypted chunks (#4 and #5) on the wire -> Sequence error.
        var keysReorder = MakeSessionKeys();
        var payload = MakeDeterministicBytes(20_000, seed: 4);
        var offer = MakeOffer(Guid.NewGuid(), "pad", payload);
        var writeIdx = 0;
        byte[]? held = null;
        var reorderPipe = new InMemoryDuplexPipe(padToPcTransform: data =>
        {
            writeIdx++;
            if (writeIdx == 4)
            {
                held = data.ToArray();
                return [];
            }
            if (writeIdx == 5 && held is not null)
            {
                var combined = new byte[data.Length + held.Length];
                data.CopyTo(combined, 0);
                held.CopyTo(combined, data.Length);
                held = null;
                return combined;
            }
            return data;
        });

        var pcTask1 = WifiTransferEngine.RunPcSessionAsync(reorderPipe.PcEnd, keysReorder, [], new InMemoryWifiTransferSink(), new WifiSessionReplayGuard());
        var padTask1 = WifiTransferEngine.RunPadSessionAsync(
            reorderPipe.PadEnd,
            keysReorder,
            [new InMemoryWifiTransferSource(offer, payload)],
            new InMemoryWifiTransferSink(),
            chunkSize: 4096);
        await ErrorAsync(SyncError.Sequence, () => pcTask1);
        reorderPipe.PcEnd.CloseWrite();
        await Assert.ThrowsAnyAsync<Exception>(() => padTask1);

        // Drop encrypted chunk #4 on the wire -> chunk #5 arrives with seq 2 instead of 1 -> Sequence error.
        var keysDrop = MakeSessionKeys();
        var dropIdx = 0;
        var dropPipe = new InMemoryDuplexPipe(padToPcTransform: data =>
        {
            dropIdx++;
            return dropIdx == 4 ? [] : data;
        });

        var pcTask2 = WifiTransferEngine.RunPcSessionAsync(dropPipe.PcEnd, keysDrop, [], new InMemoryWifiTransferSink(), new WifiSessionReplayGuard());
        var padTask2 = WifiTransferEngine.RunPadSessionAsync(
            dropPipe.PadEnd,
            keysDrop,
            [new InMemoryWifiTransferSource(offer, payload)],
            new InMemoryWifiTransferSink(),
            chunkSize: 4096);
        await ErrorAsync(SyncError.Sequence, () => pcTask2);
        dropPipe.PcEnd.CloseWrite();
        await Assert.ThrowsAnyAsync<Exception>(() => padTask2);
    }

    [Fact]
    public async Task InMemoryPipeCorruptedPartialBeforeResumeDiscardsOnSha256MismatchAndFullPartialResumesWithImmediateAck()
    {
        var payload = MakeDeterministicBytes(60_000, seed: 11);
        var offer = MakeOffer(Guid.NewGuid(), "pad", payload, "resume-check.bin");

        // 1. Pre-populate partial with 20 KB, corrupt 1 byte, resume remaining 40 KB -> SHA-256 mismatch discards partial.
        var sink1 = new InMemoryWifiTransferSink();
        _ = await sink1.BeginOfferAsync(offer);
        _ = await sink1.AppendChunkAsync(offer.Id, 0, payload.AsMemory(0, 20_000));
        sink1.CorruptPartialByteForTest(offer.Id, 100);

        var keys1 = MakeSessionKeys();
        var pipe1 = new InMemoryDuplexPipe();
        var pcTask1 = WifiTransferEngine.RunPcSessionAsync(pipe1.PcEnd, keys1, [], sink1, new WifiSessionReplayGuard());
        var padTask1 = WifiTransferEngine.RunPadSessionAsync(pipe1.PadEnd, keys1, [new InMemoryWifiTransferSource(offer, payload)], new InMemoryWifiTransferSink());
        await ErrorAsync(SyncError.Authentication, () => pcTask1);
        pipe1.PcEnd.CloseWrite();
        await Assert.ThrowsAnyAsync<Exception>(() => padTask1);
        Assert.False(sink1.HasPartial(offer.Id));
        Assert.Empty(sink1.Completed);

        // 2. Pre-populate partial with ALL bytes (e.g. previous connection dropped right before ACK) -> immediate ACK on re-offer.
        var sink2 = new InMemoryWifiTransferSink();
        _ = await sink2.BeginOfferAsync(offer);
        _ = await sink2.AppendChunkAsync(offer.Id, 0, payload);

        var keys2 = MakeSessionKeys();
        var pipe2 = new InMemoryDuplexPipe();
        var padTask2 = WifiTransferEngine.RunPadSessionAsync(pipe2.PadEnd, keys2, [new InMemoryWifiTransferSource(offer, payload)], new InMemoryWifiTransferSink());
        var pcTask2 = WifiTransferEngine.RunPcSessionAsync(pipe2.PcEnd, keys2, [], sink2, new WifiSessionReplayGuard());
        var results2 = await Task.WhenAll(padTask2, pcTask2);
        Assert.Equal(0, Assert.Single(results2[0].Sent).TransferredBytes);
        Assert.Equal(payload, sink2.Completed[offer.Id].Data);
        Assert.False(sink2.HasPartial(offer.Id));
    }

    [Fact]
    public async Task SyncCoordinatorAcceptsLegacyV3PeerOverBleWithoutRequiringUpdate()
    {
        var pairing = SyncPairing.Create("v4-pc");
        var deviceId = Guid.NewGuid();
        var root = Path.Combine(Path.GetTempPath(), "clipboardplus-tests", Guid.NewGuid().ToString("N"));
        try
        {
            var repo = new ClipboardPlus.Windows.Core.SyncRepository(root, pairing.PcId);
            var clipboard = new StubClipboard();
            var coordinator = new ClipboardPlus.Windows.Core.SyncCoordinator(pairing, clipboard, _ => { }, repo);
            var peer = new StubPeer();
            var v3Pad = new SyncPadHandshake(pairing, deviceId, protocolVersion: 3);

            await coordinator.ConnectAsync(peer);
            foreach (var packet in SyncPacketizer.Split(v3Pad.CreateHello(), peer.PacketLimit))
                Assert.True(await coordinator.ReceiveAsync(peer, packet));
            await coordinator.WaitForOutgoingAsync(peer);

            var welcome = Assert.Single(peer.DrainFrames());
            Assert.Equal(3, welcome[1]);
            var auth = v3Pad.AcceptWelcome(welcome);
            Assert.Equal((byte)3, auth.Keys.ProtocolVersion);
            Assert.False(auth.Keys.SupportsWifiTransfer);

            foreach (var packet in SyncPacketizer.Split(auth.Auth, peer.PacketLimit))
                Assert.True(await coordinator.ReceiveAsync(peer, packet));
            await coordinator.WaitForOutgoingAsync(peer);

            var status = await coordinator.GetStatusAsync();
            Assert.Equal(1, status.Connected);
            Assert.False(status.RequiresPeerUpdate);

            // Send a BLE text item using v3 keys and verify PC receives & ACKs it.
            var sender = new SyncFrameSender(auth.Keys.PadToPc);
            var receiver = new SyncFrameReceiver(auth.Keys.PcToPad);
            var itemId = Guid.NewGuid();
            var frame = sender.Seal(SyncMessageCodec.Encode(new SyncItem(itemId, 1794873600000L, "pad", "hello from v3")));
            foreach (var packet in SyncPacketizer.Split(frame, peer.PacketLimit))
                Assert.True(await coordinator.ReceiveAsync(peer, packet));
            await coordinator.WaitForOutgoingAsync(peer);

            Assert.Equal(["hello from v3"], clipboard.Texts);
            var ackFrame = Assert.Single(peer.DrainFrames());
            var ack = Assert.IsType<SyncAck>(SyncMessageCodec.Decode(receiver.Open(ackFrame)));
            Assert.Equal(itemId, Assert.Single(ack.Ids));
            await coordinator.DisposeAsync();
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task PublicApiHidesTestNonceAndRequiresReplayGuard()
    {
        Assert.DoesNotContain(
            typeof(WifiTcpPadHandshake).GetConstructors().SelectMany(c => c.GetParameters()),
            p => p.Name == "testNonce");
        Assert.DoesNotContain(
            typeof(WifiTcpPcHandshake).GetConstructors().SelectMany(c => c.GetParameters()),
            p => p.Name == "testNonce");
        Assert.DoesNotContain(
            typeof(WifiEncryptedStream).GetMethods().SelectMany(m => m.GetParameters()),
            p => p.Name == "testNonce");
        Assert.DoesNotContain(
            typeof(WifiTransferEngine).GetMethods().SelectMany(m => m.GetParameters()),
            p => p.Name == "testNonce");

        var acceptParams = Assert.Single(typeof(WifiEncryptedStream).GetMethods(), m => m.Name == nameof(WifiEncryptedStream.AcceptAsPcAsync))
            .GetParameters();
        var acceptGuardParam = Assert.Single(acceptParams, p => p.Name == "replayGuard");
        Assert.False(acceptGuardParam.HasDefaultValue);

        var runPcParams = Assert.Single(typeof(WifiTransferEngine).GetMethods(), m => m.Name == nameof(WifiTransferEngine.RunPcSessionAsync))
            .GetParameters();
        var runPcGuardParam = Assert.Single(runPcParams, p => p.Name == "replayGuard");
        Assert.False(runPcGuardParam.HasDefaultValue);

        var keys = MakeSessionKeys();
        var pipe = new InMemoryDuplexPipe();
        await Assert.ThrowsAsync<ArgumentNullException>(() =>
            WifiEncryptedStream.AcceptAsPcAsync(pipe.PcEnd, keys, replayGuard: null!));
        await Assert.ThrowsAsync<ArgumentNullException>(() =>
            WifiTransferEngine.RunPcSessionAsync(pipe.PcEnd, keys, [], new InMemoryWifiTransferSink(), replayGuard: null!));
    }

    private sealed class StubClipboard : ClipboardPlus.Windows.Core.IClipboardAccess
    {
        private uint seq = 1;
        public readonly List<string> Texts = [];
        public Task<uint> WriteTextAsync(string text) { Texts.Add(text); return Task.FromResult(++seq); }
    }

    private sealed class StubPeer : ClipboardPlus.Windows.Core.ISyncPeer
    {
        public int PacketLimit => 512;
        private readonly List<byte[]> packets = [];
        public Task SendPacketAsync(byte[] packet) { lock (packets) packets.Add(packet.ToArray()); return Task.CompletedTask; }
        public void Reject() { }
        public byte[][] DrainFrames()
        {
            byte[][] snapshot;
            lock (packets) { snapshot = packets.ToArray(); packets.Clear(); }
            var assembler = new SyncPacketAssembler(512);
            var frames = new List<byte[]>();
            foreach (var p in snapshot) { var f = assembler.Append(p); if (f is not null) frames.Add(f); }
            assembler.Finish();
            return frames.ToArray();
        }
    }
}
