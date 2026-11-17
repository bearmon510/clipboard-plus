using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using ClipboardPlus.Sync;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class SyncProtocolTests : IDisposable
{
    private readonly JsonDocument vectors = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "test-vectors.json")));
    private JsonElement V => vectors.RootElement;
    private JsonElement H => V.GetProperty("handshake");
    private static byte[] Hex(JsonElement e, string key) => Convert.FromHexString(e.GetProperty(key).GetString()!);
    private SyncPairing Pair => SyncPairing.Parse(V.GetProperty("pairing").GetProperty("qr").GetString()!);
    private SyncPadHandshake Pad() => new(Pair, Guid.Parse(H.GetProperty("padId").GetString()!), Hex(H, "niHex"));
    private SyncPcHandshake Pc() => new(Pair, Guid.Parse(H.GetProperty("padId").GetString()!), Hex(H, "npHex"));
    private static void Error(SyncError code, Action action) => Assert.Equal(code, Assert.Throws<SyncProtocolException>(action).Code);
    private byte[] Key(string direction) => Hex(H, direction == "pad->pc" ? "padToPcKeyHex" : "pcToPadKeyHex");
    public void Dispose() => vectors.Dispose();

    [Fact]
    public void PairingAndBothHandshakeRolesMatchIndependentVectors()
    {
        var p = V.GetProperty("pairing"); var parsed = p.GetProperty("parsed");
        Assert.Equal(p.GetProperty("qr").GetString(), Pair.ToQrString());
        Assert.Equal(parsed.GetProperty("name").GetString(), Pair.Name);
        Assert.Equal(Guid.Parse(parsed.GetProperty("pcId").GetString()!), Pair.PcId);
        Assert.Equal(Hex(parsed, "keyHex"), Pair.Key);
        var pad = Pad(); var pc = Pc();
        var hello = pad.CreateHello(); Assert.Equal(Hex(H, "helloHex"), hello);
        var welcome = pc.AcceptHello(hello); Assert.Equal(Hex(H, "welcomeHex"), welcome);
        Assert.Null(pc.AuthenticatedPadId);
        Assert.Equal(Hex(H, "pcHmacHex"), welcome[50..]);
        var authentication = pad.AcceptWelcome(welcome);
        Assert.Equal(Hex(H, "authHex"), authentication.Auth);
        Assert.Equal(Hex(H, "padHmacHex"), authentication.Auth[1..]);
        var keys = pc.AcceptAuth(authentication.Auth);
        Assert.Equal(Guid.Parse(H.GetProperty("padId").GetString()!), pc.AuthenticatedPadId);
        foreach (var result in new[] { keys, authentication.Keys })
        {
            Assert.Equal(Key("pad->pc"), result.PadToPc);
            Assert.Equal(Key("pc->pad"), result.PcToPad);
        }
        Error(SyncError.State, () => pad.AcceptWelcome(welcome));
        Error(SyncError.State, () => pc.AcceptAuth(authentication.Auth));
    }

    [Fact]
    public void EveryMessageFrameAndFragmentMatchesIndependentVectors()
    {
        foreach (var fixture in V.GetProperty("messages").EnumerateObject())
        {
            var plaintext = Hex(fixture.Value, "plaintextHex");
            var message = SyncMessageCodec.Decode(plaintext);
            Assert.Equal(plaintext, SyncMessageCodec.Encode(message));
            var length = BinaryPrimitives.ReadUInt16BigEndian(plaintext);
            Assert.Equal(fixture.Value.GetProperty("headerJson").GetString(), Encoding.ASCII.GetString(plaintext, 2, length));
            if (message is SyncItem item) Assert.Equal(fixture.Value.GetProperty("bodyUtf8").GetString(), item.Text);
            if (message is SyncAck ack) Assert.Equal(2, ack.Ids.Count);
        }
        foreach (var direction in new[] { "pad->pc", "pc->pad" })
        {
            var sender = new SyncFrameSender(Key(direction)); var receiver = new SyncFrameReceiver(Key(direction));
            foreach (var f in V.GetProperty("frames").EnumerateArray().Where(f => f.GetProperty("direction").GetString() == direction))
            {
                var plaintext = Hex(V.GetProperty("messages").GetProperty(f.GetProperty("message").GetString()!), "plaintextHex");
                var expected = Hex(f, "frameHex");
                Assert.Equal(expected, sender.Seal(plaintext));
                Assert.Equal(plaintext, receiver.Open(expected));
                Assert.Equal(Hex(f, "aadHex"), expected[..9]);
                Assert.Equal(Hex(f, "tagHex"), expected[^16..]);
            }
        }
        foreach (var fixture in V.GetProperty("fragmentation").EnumerateArray())
        {
            var limit = fixture.GetProperty("packetLimit").GetInt32();
            var frame = Hex(V.GetProperty("frames")[fixture.GetProperty("frameIndex").GetInt32()], "frameHex");
            var packets = SyncPacketizer.Split(frame, limit);
            Assert.Equal(fixture.GetProperty("packetsHex").EnumerateArray().Select(p => p.GetString()), packets.Select(p => Convert.ToHexString(p).ToLowerInvariant()));
            var assembler = new SyncPacketAssembler(limit);
            for (var i = 0; i < packets.Count; i++)
            {
                var result = assembler.Append(packets[i]);
                if (i == packets.Count - 1) Assert.Equal(frame, result); else Assert.Null(result);
            }
            Assert.False(assembler.HasPartialFrame);
            // Complete frames can follow without resetting the assembler.
            Assert.Equal(new byte[] { 7 }, assembler.Append([3, 7]));
            assembler.Finish();
        }
    }

    [Fact]
    public void FailureVectorsRejectAndPermanentlyInvalidateState()
    {
        var failures = V.GetProperty("failures");
        var receiver = new SyncFrameReceiver(Key("pad->pc"));
        Error(SyncError.Authentication, () => receiver.Open(Hex(failures.GetProperty("tamperedTag"), "frameHex")));
        Error(SyncError.State, () => receiver.Open(Hex(V.GetProperty("frames")[0], "frameHex")));
        receiver = new SyncFrameReceiver(Key("pad->pc"));
        var rollback = failures.GetProperty("rollback").GetProperty("framesHex");
        receiver.Open(Convert.FromHexString(rollback[0].GetString()!));
        Error(SyncError.Sequence, () => receiver.Open(Convert.FromHexString(rollback[1].GetString()!)));
        var pad = Pad(); pad.CreateHello();
        Error(SyncError.Authentication, () => pad.AcceptWelcome(Hex(failures.GetProperty("welcomeHmac"), "frameHex")));
        Error(SyncError.State, () => pad.AcceptWelcome(Hex(H, "welcomeHex")));
        var pc = Pc(); pc.AcceptHello(Hex(H, "helloHex"));
        Error(SyncError.Authentication, () => pc.AcceptAuth(Hex(failures.GetProperty("authHmac"), "frameHex")));
        Assert.Null(pc.AuthenticatedPadId);
        Error(SyncError.State, () => pc.AcceptAuth(Hex(H, "authHex")));
        foreach (var name in new[] { "unfinishedStart", "continuationWithoutStart" })
        {
            var fixture = failures.GetProperty(name); var assembler = new SyncPacketAssembler(20);
            Error(SyncError.Packet, () =>
            {
                foreach (var p in fixture.GetProperty("packetsHex").EnumerateArray()) assembler.Append(Convert.FromHexString(p.GetString()!));
                if (fixture.GetProperty("finish").GetBoolean()) assembler.Finish();
            });
            Error(SyncError.State, () => assembler.Append([3, 7]));
        }
        var large = failures.GetProperty("oversizedFrame");
        var oversized = Enumerable.Repeat(large.GetProperty("fillByte").GetByte(), large.GetProperty("byteLength").GetInt32()).ToArray();
        Error(SyncError.Limit, () => SyncPacketizer.Split(oversized, 182));
        Error(SyncError.Limit, () => new SyncFrameReceiver(Key("pad->pc")).Open(oversized));
        var limit = large.GetProperty("packetLimit").GetInt32(); var assembly = new SyncPacketAssembler(limit);
        Error(SyncError.Limit, () =>
        {
            for (var offset = 0; offset < oversized.Length;)
            {
                var count = Math.Min(limit - 1, oversized.Length - offset);
                byte flags = (byte)((offset == 0 ? 1 : 0) | (offset + count == oversized.Length ? 2 : 0));
                assembly.Append([flags, .. oversized.AsSpan(offset, count).ToArray()]); offset += count;
            }
        });
    }

    [Theory]
    [InlineData("clipboardplus-pair:2:a:b:c")]
    [InlineData("clipboardplus-pair:1:a:b:c")]
    public void InvalidPairingPrefixAndLengths(string qr) => Error(SyncError.Format, () => SyncPairing.Parse(qr));

    [Fact]
    public void StrictPairingAndIdentityValidation()
    {
        var parts = Pair.ToQrString().Split(':');
        foreach (var name in new[] { "", "%", "%GG", "%C0%AF", "%ED%A0%80", "%00", "%0A", "raw+name", "raw name", "日本語", new string('a', 256) })
            Error(SyncError.Format, () => SyncPairing.Parse(string.Join(':', parts[..4]) + ":" + name));
        foreach (var suffix in new[] { "=", ":extra" }) Error(SyncError.Format, () => SyncPairing.Parse(Pair.ToQrString() + suffix));
        var noncanonical = parts.ToArray(); noncanonical[2] = noncanonical[2][..^1] + "x";
        Error(SyncError.Format, () => SyncPairing.Parse(string.Join(':', noncanonical)));
        var padded = parts.ToArray(); padded[3] += "=";
        Error(SyncError.Format, () => SyncPairing.Parse(string.Join(':', padded)));
        Assert.Equal("A", SyncPairing.Parse(string.Join(':', parts[..4]) + ":%41").Name);
        Assert.Equal(new string('a', 255), SyncPairing.Parse(string.Join(':', parts[..4]) + ":" + new string('a', 255)).Name);
        var pad = Pad(); pad.CreateHello(); var wrongId = Hex(H, "welcomeHex"); wrongId[2] ^= 1;
        Error(SyncError.Identity, () => pad.AcceptWelcome(wrongId));
        var pc = Pc(); var wrongPad = Hex(H, "helloHex"); wrongPad[2] ^= 1;
        Error(SyncError.Identity, () => pc.AcceptHello(wrongPad));
        Error(SyncError.State, () => Pc().AcceptAuth(Hex(H, "authHex")));
        Error(SyncError.State, () => Pad().AcceptWelcome(Hex(H, "welcomeHex")));
        pad = Pad(); pad.CreateHello(); Error(SyncError.State, () => pad.CreateHello());
        foreach (var frame in new[] { Hex(H, "helloHex")[..^1], Hex(H, "helloHex").Concat(new byte[] { 0 }).ToArray(), new byte[50] })
            Error(SyncError.Format, () => Pc().AcceptHello(frame));
    }

    private static byte[] Plain(string header, byte[]? body = null)
    {
        var h = Encoding.UTF8.GetBytes(header); var b = body ?? [];
        var result = new byte[2 + h.Length + b.Length]; BinaryPrimitives.WriteUInt16BigEndian(result, (ushort)h.Length);
        h.CopyTo(result, 2); b.CopyTo(result, 2 + h.Length); return result;
    }

    [Fact]
    public void ReadersAllowWhitespaceOrderAndLowercaseUuidButRejectMalformedMessages()
    {
        const string id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
        var item = (SyncItem)SyncMessageCodec.Decode(Plain($$""" { "t" : "item", "kind":"text", "id":"{{id}}", "from":"pc", "at": -123 } """, Encoding.UTF8.GetBytes("日本語\n📋")));
        Assert.Equal(-123, item.At); Assert.Equal("日本語\n📋", item.Text);
        var encoded = SyncMessageCodec.Encode(item);
        Assert.Contains(id.ToUpperInvariant(), Encoding.ASCII.GetString(encoded));
        foreach (var header in new[] { "{}", "[]", "{\"t\":\"image\"}", "{\"t\":\"ping\",\"extra\":0}", "{\"t\":\"ping\",\"t\":\"ping\"}", "{\"t\":\"ping\",}", "{\"t\":\"ping\"} trailing", "{\"t\":\"p\\u00E9ng\"}", "{\"t\":\"ping\",\"日本語\":0}", "{\"ids\":[\"bad\"],\"t\":\"ack\"}" })
            Error(SyncError.Format, () => SyncMessageCodec.Decode(Plain(header)));
        foreach (var at in new[] { "true", "1.0", "1e3", "\"1\"", "9007199254740992", "-9007199254740992", "null" })
            Error(SyncError.Format, () => SyncMessageCodec.Decode(Plain($$"""{"t":"item","kind":"text","id":"{{id}}","from":"pad","at":{{at}}} """)));
        foreach (var at in new[] { -SyncProtocol.MaxTimestamp, 0, SyncProtocol.MaxTimestamp })
            Assert.Equal(at, ((SyncItem)SyncMessageCodec.Decode(SyncMessageCodec.Encode(new SyncItem(Guid.Parse(id), at, "pc", "")))).At);
        Error(SyncError.Format, () => SyncMessageCodec.Decode(Plain("{\"t\":\"ping\"}", [0])));
        Error(SyncError.Format, () => SyncMessageCodec.Decode(Plain("{\"t\":\"pong\"}", [0])));
        Error(SyncError.Format, () => SyncMessageCodec.Decode(Plain("{\"t\":\"pong\",\"extra\":0}")));
        Assert.IsType<SyncPong>(SyncMessageCodec.Decode(Plain("{\"t\":\"pong\"}")));
        Error(SyncError.Format, () => SyncMessageCodec.Decode(Plain("{\"t\":\"ack\",\"ids\":[\"" + id + "\"]}", [0])));
        Error(SyncError.Format, () => SyncMessageCodec.Decode(Plain($$"""{"t":"item","kind":"text","id":"{{id}}","from":"pad","at":0}""", [0xC0, 0xAF])));
        Error(SyncError.Format, () => SyncMessageCodec.Decode([0, 30, 123]));
        Error(SyncError.Format, () => SyncMessageCodec.Decode([0]));
        Error(SyncError.Limit, () => SyncMessageCodec.Encode(new SyncAck([])));
        Error(SyncError.Limit, () => SyncMessageCodec.Decode(Plain("{\"t\":\"ack\",\"ids\":[]}")));
        Error(SyncError.Limit, () => SyncMessageCodec.Encode(new SyncAck(Enumerable.Repeat(Guid.Empty, 1025).ToArray())));
        Error(SyncError.Limit, () => SyncMessageCodec.Encode(new SyncItem(Guid.Empty, 0, "pad", new string('a', SyncProtocol.MaxPlaintextBytes))));
        var maxAck = new SyncAck(Enumerable.Repeat(Guid.Empty, 1024).ToArray());
        Assert.Equal(1024, ((SyncAck)SyncMessageCodec.Decode(SyncMessageCodec.Encode(maxAck))).Ids.Count);
    }

    [Fact]
    public void PacketBoundariesAndCipherFailures()
    {
        foreach (var packet in new byte[][] { [], [1], [4, 0], [0, 1], [2, 1], new byte[21] })
            Error(SyncError.Packet, () => new SyncPacketAssembler(20).Append(packet));
        var assembly = new SyncPacketAssembler(20); assembly.Append([1, 1]);
        Error(SyncError.Packet, () => assembly.Append([1, 2]));
        Error(SyncError.Limit, () => new SyncPacketAssembler(1));
        Error(SyncError.Limit, () => SyncPacketizer.Split([1], 1));
        Error(SyncError.Limit, () => SyncPacketizer.Split([], 20));
        Assert.Equal(new byte[] { 3, 1 }, SyncPacketizer.Split([1], 2).Single());
        var max = new byte[SyncProtocol.MaxFrameBytes];
        var boundary = new SyncPacketAssembler(182); byte[]? complete = null;
        foreach (var packet in SyncPacketizer.Split(max, 182)) complete = boundary.Append(packet);
        Assert.Equal(max, complete);
        var key = Key("pad->pc"); var sender = new SyncFrameSender(key);
        var maxPlain = new byte[SyncProtocol.MaxPlaintextBytes];
        var maxFrame = sender.Seal(maxPlain); Assert.Equal(SyncProtocol.MaxFrameBytes, maxFrame.Length);
        Assert.Equal(maxPlain, new SyncFrameReceiver(key).Open(maxFrame));
        Error(SyncError.Limit, () => sender.Seal(new byte[SyncProtocol.MaxPlaintextBytes + 1]));
        var frame = Hex(V.GetProperty("frames")[0], "frameHex");
        var receiver = new SyncFrameReceiver(key); receiver.Open(frame);
        Error(SyncError.Sequence, () => receiver.Open(frame));
        Error(SyncError.Authentication, () => new SyncFrameReceiver(Key("pc->pad")).Open(frame));
        foreach (var offset in new[] { 8, 10, frame.Length - 1 })
        { var tampered = frame.ToArray(); tampered[offset] ^= 1; Error(SyncError.Authentication, () => new SyncFrameReceiver(key).Open(tampered)); }
        Error(SyncError.Format, () => new SyncFrameReceiver(key).Open(frame[..20]));
        var wrongType = frame.ToArray(); wrongType[0] = 0x11;
        Error(SyncError.Format, () => new SyncFrameReceiver(key).Open(wrongType));
        // Reconnecting uses new random nonces, so starting at sequence zero has a different key.
        var pad = new SyncPadHandshake(Pair, Guid.NewGuid()); var pc = new SyncPcHandshake(Pair);
        var auth = pad.AcceptWelcome(pc.AcceptHello(pad.CreateHello())); var keys = pc.AcceptAuth(auth.Auth);
        Assert.NotEqual(key, keys.PadToPc);
        var fresh = new SyncFrameSender(keys.PadToPc).Seal(SyncMessageCodec.Encode(new SyncPing()));
        Assert.Equal(new SyncPing(), SyncMessageCodec.Decode(new SyncFrameReceiver(auth.Keys.PadToPc).Open(fresh)));
    }

    [Fact]
    public void NullAndNonStringHeaderFieldsThrowFormatError()
    {
        const string id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
        var sha = new string('a', 64);
        foreach (var json in new[]
        {
            $$"""{"t":null}""",
            $$"""{"t":1}""",
            $$"""{"t":"device","kind":null}""",
            $$"""{"t":"ack","ids":[null]}""",
            $$"""{"t":"resume","id":null,"offset":0}""",
            $$"""{"t":"item","kind":"text","id":null,"from":"pad","at":0}""",
            $$"""{"t":"item","kind":"text","id":"{{id}}","from":null,"at":0}""",
            $$"""{"t":"item","kind":null,"id":"{{id}}","from":"pad","at":0}""",
            $$"""{"t":"offer","id":"{{id}}","at":0,"from":"pad","kind":"file","size":4,"sha256":"{{sha}}","name64":null,"type":"public.data"}""",
            $$"""{"t":"offer","id":"{{id}}","at":0,"from":"pad","kind":"file","size":4,"sha256":"{{sha}}","name64":123,"type":"public.data"}""",
            $$"""{"t":"offer","id":null,"at":0,"from":"pad","kind":"file","size":4,"sha256":"{{sha}}","name64":"YS50eHQ=","type":"public.data"}""",
            $$"""{"t":"offer","id":"{{id}}","at":0,"from":null,"kind":"file","size":4,"sha256":"{{sha}}","name64":"YS50eHQ=","type":"public.data"}""",
            $$"""{"t":"offer","id":"{{id}}","at":0,"from":"pad","kind":null,"size":4,"sha256":"{{sha}}","name64":"YS50eHQ=","type":"public.data"}""",
            $$"""{"t":"offer","id":"{{id}}","at":0,"from":"pad","kind":"file","size":4,"sha256":null,"name64":"YS50eHQ=","type":"public.data"}""",
            $$"""{"t":"offer","id":"{{id}}","at":0,"from":"pad","kind":"file","size":4,"sha256":"{{sha}}","name64":"YS50eHQ=","type":null}"""
        })
            Error(SyncError.Format, () => SyncMessageCodec.Decode(Plain(json)));

        Error(SyncError.Format, () => SyncMessageCodec.ValidateOffer(new(Guid.Parse(id), 0, "pc", "file", 4, sha, null!, "public.data")));
        Error(SyncError.Format, () => SyncMessageCodec.Encode(new SyncItem(Guid.Parse(id), 0, "pc", null!)));
        Error(SyncError.Format, () => SyncMessageCodec.Encode(new SyncAck(null!)));
    }

    [Fact]
    public void OfferFilenameAllowsFormatControlsAndRejectsControlCharacters()
    {
        var zwj = (SyncOffer)SyncMessageCodec.Decode(Hex(V.GetProperty("messages").GetProperty("zwjOffer"), "plaintextHex"));
        Assert.Equal("家族👨‍👩‍👧‍👦.txt", zwj.Filename);
        Assert.Contains("\u200D", zwj.Filename);

        var bad = V.GetProperty("failures").GetProperty("controlNameOffer");
        Assert.Equal("format", bad.GetProperty("error").GetString());
        Error(SyncError.Format, () => SyncMessageCodec.Decode(Hex(bad, "plaintextHex")));

        var sha = new string('a', 64);
        foreach (var allowed in new[] { "a\u200Db.txt", "a\u200Eb.txt", "a\u202Eb.txt", "a\uFEFFb.txt" })
        {
            var offer = new SyncOffer(Guid.NewGuid(), 0, "pc", "file", 1, sha, Convert.ToBase64String(Encoding.UTF8.GetBytes(allowed)), "public.data");
            var roundtrip = Assert.IsType<SyncOffer>(SyncMessageCodec.Decode(SyncMessageCodec.Encode(offer)));
            Assert.Equal(allowed, roundtrip.Filename);
        }
        foreach (var forbidden in new[] { "\u0000", "\u0007", "\u001F", "\u007F", "\u0080", "\u0085", "\u009F" })
        {
            var offer = new SyncOffer(Guid.NewGuid(), 0, "pc", "file", 1, sha, Convert.ToBase64String(Encoding.UTF8.GetBytes("a" + forbidden + "b")), "public.data");
            Error(SyncError.Format, () => SyncMessageCodec.ValidateOffer(offer));
        }
    }
}
