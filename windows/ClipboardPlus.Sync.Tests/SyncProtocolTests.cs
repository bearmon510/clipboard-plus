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
        Assert.Equal(Hex(H, "versionMismatchWelcomeHex"), pc.CreateVersionMismatch());
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
        var samePcMismatch = Pad(); samePcMismatch.CreateHello();
        Error(SyncError.Version, () => samePcMismatch.AcceptWelcome(Hex(failures.GetProperty("versionMismatchSamePc"), "frameHex")));
        var otherPcMismatch = Pad(); otherPcMismatch.CreateHello();
        Error(SyncError.Identity, () => otherPcMismatch.AcceptWelcome(Hex(failures.GetProperty("versionMismatchOtherPc"), "frameHex")));
        var legacyZeroMismatch = Pad(); legacyZeroMismatch.CreateHello();
        Error(SyncError.Identity, () => legacyZeroMismatch.AcceptWelcome(Hex(failures.GetProperty("versionMismatchLegacyZeroId"), "frameHex")));
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
        foreach (var header in new[] { "{}", "[]", "{\"t\":\"image\"}", "{\"t\":\"ping\",\"extra\":0}", "{\"t\":\"ping\",\"t\":\"ping\"}", "{\"t\":\"ping\",}", "{\"t\":\"ping\"} trailing", "{\"t\":\"p\\u00E9ng\"}", "{\"t\":\"ping\",\"日本語\":0}", "{\"ids\":[\"bad\"],\"t\":\"ack\"}",
            "{\"ids\":[\"+0112233-4455-6677-8899-AABBCCDDEEFF\"],\"t\":\"ack\"}",
            "{\"ids\":[\"00112233-+455-6677-8899-AABBCCDDEEFF\"],\"t\":\"ack\"}",
            "{\"ids\":[\"00112233-4455-6677-8899-AABBCCDDEE+F\"],\"t\":\"ack\"}",
            "{\"ids\":[\" 0112233-4455-6677-8899-AABBCCDDEEFF\"],\"t\":\"ack\"}",
            "{\"ids\":[\"00112233_4455_6677_8899_AABBCCDDEEFF\"],\"t\":\"ack\"}" })
            Error(SyncError.Format, () => SyncMessageCodec.Decode(Plain(header)));
        var mixedCaseId = "aAbBcCdD-eEfF-4123-8456-001122334455";
        var mixedAck = Assert.IsType<SyncAck>(SyncMessageCodec.Decode(Plain($$"""{"t":"ack","ids":["{{mixedCaseId}}"]}""")));
        Assert.Equal(Guid.Parse(mixedCaseId), Assert.Single(mixedAck.Ids));
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

    [Fact]
    public void TemplateMessagesFramesAndFragmentsMatchIndependentVectors()
    {
        Assert.Equal(SyncProtocol.Version, V.GetProperty("version").GetInt32());
        var limits = V.GetProperty("limits");
        Assert.Equal(SyncProtocol.MaxTemplates, limits.GetProperty("maxTemplates").GetInt32());
        Assert.Equal(SyncProtocol.MaxTemplateTombstones, limits.GetProperty("maxTemplateTombstones").GetInt32());
        Assert.Equal(SyncProtocol.MaxTemplateTextBytes, limits.GetProperty("maxTemplateTextBytes").GetInt32());
        Assert.Equal(SyncProtocol.MaxTemplateTitleCharacters, limits.GetProperty("maxTemplateTitleChars").GetInt32());
        Assert.Equal(SyncProtocol.MaxTemplateTitleBytes, limits.GetProperty("maxTemplateTitleUtf8Bytes").GetInt32());
        Assert.Equal(SyncProtocol.MaxTemplateTagCharacters, limits.GetProperty("maxTemplateTagChars").GetInt32());
        Assert.Equal(SyncProtocol.MaxTemplateTagBytes, limits.GetProperty("maxTemplateTagUtf8Bytes").GetInt32());
        Assert.Equal(SyncProtocol.MaxTemplatePageBodyBytes, limits.GetProperty("maxTemplatePageBodyBytes").GetInt32());
        Assert.Equal(SyncProtocol.MaxTemplatePages, limits.GetProperty("maxTemplatePages").GetInt32());
        Assert.Equal(SyncProtocol.MaxTemplateTotalBytes, limits.GetProperty("maxTemplateTotalBytes").GetInt32());
        Assert.Equal(TemplateSyncMessageCodec.MaxOrder, limits.GetProperty("maxTemplateOrder").GetInt32());
        Assert.Equal(32, limits.GetProperty("emptyContinuationPageBytes").GetInt32());

        var tplMessages = V.GetProperty("templateMessages");
        var decoded = new Dictionary<string, TemplateSyncMessage>();
        foreach (var fixture in tplMessages.EnumerateObject())
        {
            var plaintext = Hex(fixture.Value, "plaintextHex");
            var msg = TemplateSyncMessageCodec.Decode(plaintext);
            decoded[fixture.Name] = msg;
            Assert.Equal(plaintext, TemplateSyncMessageCodec.Encode(msg));
            var length = BinaryPrimitives.ReadUInt16BigEndian(plaintext);
            Assert.Equal(fixture.Value.GetProperty("headerJson").GetString(), Encoding.ASCII.GetString(plaintext, 2, length));
        }

        var assembler = new TemplateSyncPageAssembler(expectedIsState: false);
        Assert.Null(assembler.Append(decoded["tplPushPage0"]));
        Assert.True(assembler.HasPartialSnapshot);
        var combined = assembler.Append(decoded["tplPushPage1"]);
        Assert.NotNull(combined);
        Assert.False(assembler.HasPartialSnapshot);
        Assert.Equal(2, combined!.Templates.Count);
        Assert.Single(combined.Tombstones);
        assembler.Finish();

        foreach (var direction in new[] { "pad->pc", "pc->pad" })
        {
            var sender = new SyncFrameSender(Key(direction));
            var receiver = new SyncFrameReceiver(Key(direction));
            foreach (var f in V.GetProperty("templateFrames").EnumerateArray().Where(f => f.GetProperty("direction").GetString() == direction))
            {
                var plaintext = Hex(tplMessages.GetProperty(f.GetProperty("message").GetString()!), "plaintextHex");
                var expected = Hex(f, "frameHex");
                Assert.Equal(expected, sender.Seal(plaintext));
                Assert.Equal(plaintext, receiver.Open(expected));
                Assert.Equal(Hex(f, "aadHex"), expected[..9]);
                Assert.Equal(Hex(f, "tagHex"), expected[^16..]);
            }
        }

        foreach (var fixture in V.GetProperty("templateFragmentation").EnumerateArray())
        {
            var limit = fixture.GetProperty("packetLimit").GetInt32();
            var frame = Hex(V.GetProperty("templateFrames")[fixture.GetProperty("frameIndex").GetInt32()], "frameHex");
            var packets = SyncPacketizer.Split(frame, limit);
            Assert.Equal(fixture.GetProperty("packetsHex").EnumerateArray().Select(p => p.GetString()),
                packets.Select(p => Convert.ToHexString(p).ToLowerInvariant()));
            var packetAssembler = new SyncPacketAssembler(limit);
            byte[]? assembled = null;
            foreach (var packet in packets) assembled = packetAssembler.Append(packet);
            Assert.Equal(frame, assembled);
            packetAssembler.Finish();
        }
    }

    [Fact]
    public void TemplateFailuresRejectExpectedVectors()
    {
        var failures = V.GetProperty("templateFailures");
        foreach (var prop in failures.EnumerateObject())
        {
            var expectedError = prop.Value.GetProperty("error").GetString() switch
            {
                "format" => SyncError.Format,
                "limit" => SyncError.Limit,
                _ => throw new InvalidOperationException($"Unknown error {prop.Name}"),
            };
            if (prop.Value.TryGetProperty("plaintextHex", out var hexElem))
            {
                var bytes = Convert.FromHexString(hexElem.GetString()!);
                Error(expectedError, () => TemplateSyncMessageCodec.Decode(bytes));
            }
        }

        var op = Guid.NewGuid();
        var oversizedBytes = failures.GetProperty("oversizedTemplateText").GetProperty("textBytes").GetInt32();
        var maxTextItem = new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, new string('a', SyncProtocol.MaxTemplateTextBytes), null, null, 0, 1);
        Assert.IsType<TemplateSyncPush>(TemplateSyncMessageCodec.Decode(TemplateSyncMessageCodec.Encode(
            new TemplateSyncPush(op, 0, 1, new TemplateSyncPage(1, 0, [maxTextItem], [])))));
        Error(SyncError.Limit, () => TemplateSyncMessageCodec.Encode(
            new TemplateSyncPush(op, 0, 1, new TemplateSyncPage(1, 0, [maxTextItem with { Text = new string('a', oversizedBytes) }], []))));

        var tooManyCount = failures.GetProperty("tooManyTemplates").GetProperty("count").GetInt32();
        var maxTemplates = Enumerable.Range(0, SyncProtocol.MaxTemplates)
            .Select(i => new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, $"t{i}", null, null, i, 1)).ToArray();
        Assert.IsType<TemplateSyncPush>(TemplateSyncMessageCodec.Decode(TemplateSyncMessageCodec.Encode(
            new TemplateSyncPush(op, 0, 1, new TemplateSyncPage(1, 0, maxTemplates, [])))));
        var overTemplates = maxTemplates.Append(new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "extra", null, null, 300, 1)).ToArray();
        Error(SyncError.Limit, () => TemplateSyncMessageCodec.Encode(
            new TemplateSyncPush(op, 0, 1, new TemplateSyncPage(1, 0, overTemplates, []))));

        var tooManyTombCount = failures.GetProperty("tooManyTombstones").GetProperty("count").GetInt32();
        var maxTombs = Enumerable.Range(0, SyncProtocol.MaxTemplateTombstones)
            .Select(i => new TemplateSyncTombstone(Guid.NewGuid(), i)).ToArray();
        Assert.IsType<TemplateSyncPush>(TemplateSyncMessageCodec.Decode(TemplateSyncMessageCodec.Encode(
            new TemplateSyncPush(op, 0, 1, new TemplateSyncPage(1, 0, [], maxTombs)))));
        var overTombs = maxTombs.Append(new TemplateSyncTombstone(Guid.NewGuid(), tooManyTombCount)).ToArray();
        Error(SyncError.Limit, () => TemplateSyncMessageCodec.Encode(
            new TemplateSyncPush(op, 0, 1, new TemplateSyncPage(1, 0, [], overTombs))));

        var oversizedBodyLen = failures.GetProperty("oversizedPageBody").GetProperty("bodyBytes").GetInt32();
        var bigBody = Encoding.UTF8.GetBytes("{\"sentAt\":0,\"templates\":[{\"id\":\"44444444-5555-4666-8777-888888888881\",\"kind\":\"text\",\"order\":0,\"text\":\"" +
            new string('a', oversizedBodyLen) + "\",\"updatedAt\":1}],\"tombstones\":[],\"v\":1}");
        var hdr = Encoding.ASCII.GetBytes($"{{\"op\":\"{op.ToString("D").ToUpperInvariant()}\",\"part\":0,\"t\":\"tpl_push\",\"total\":1}}");
        var oversizedPlain = new byte[2 + hdr.Length + bigBody.Length];
        BinaryPrimitives.WriteUInt16BigEndian(oversizedPlain, (ushort)hdr.Length);
        hdr.CopyTo(oversizedPlain, 2);
        bigBody.CopyTo(oversizedPlain, 2 + hdr.Length);
        Error(SyncError.Limit, () => TemplateSyncMessageCodec.Decode(oversizedPlain));
    }

    [Fact]
    public void TemplateMergeCasesMatchIndependentVectors()
    {
        static TemplateSyncItem ParseItem(JsonElement el) => new(
            Guid.Parse(el.GetProperty("id").GetString()!),
            el.GetProperty("kind").GetString()! == "url" ? TemplateSyncKind.Url : TemplateSyncKind.Text,
            el.GetProperty("text").GetString()!,
            el.TryGetProperty("title", out var t) ? t.GetString() : null,
            el.TryGetProperty("tag", out var g) ? g.GetString() : null,
            el.GetProperty("order").GetInt32(),
            el.GetProperty("updatedAt").GetInt64(),
            el.TryGetProperty("baseHash", out var bh) ? bh.GetString() : null);

        static TemplateSyncTombstone ParseTomb(JsonElement el) => new(
            Guid.Parse(el.GetProperty("id").GetString()!),
            el.GetProperty("deletedAt").GetInt64(),
            el.TryGetProperty("baseHash", out var bh) ? bh.GetString() : null);

        static TemplateSyncState ParseSide(JsonElement el) => new(
            el.GetProperty("templates").EnumerateArray().Select(ParseItem).ToArray(),
            el.GetProperty("tombstones").EnumerateArray().Select(ParseTomb).ToArray());

        static TemplateSyncSideChanges ParseChanges(JsonElement el) => new(
            el.GetProperty("added").GetInt32(),
            el.GetProperty("updated").GetInt32(),
            el.GetProperty("deleted").GetInt32());

        foreach (var testCase in V.GetProperty("templateMergeCases").EnumerateArray())
        {
            var nowMillis = testCase.GetProperty("nowMillis").GetInt64();
            long? remoteSentAt = testCase.TryGetProperty("remoteSentAtMillis", out var rs) ? rs.GetInt64() : null;
            var pc = ParseSide(testCase.GetProperty("pc"));
            var remote = ParseSide(testCase.GetProperty("remote"));
            var actual = TemplateSyncMerge.Merge(pc, remote, nowMillis, remoteSentAt);

            var expected = testCase.GetProperty("expected");
            var expectedTemplates = expected.GetProperty("templates").EnumerateArray().Select(ParseItem).ToArray();
            var expectedTombs = expected.GetProperty("tombstones").EnumerateArray().Select(ParseTomb).ToArray();

            Assert.Equal(expectedTemplates, actual.Templates);
            Assert.Equal(expectedTemplates.Select(t => Encoding.UTF8.GetBytes(t.Text)).ToArray(), actual.Templates.Select(t => Encoding.UTF8.GetBytes(t.Text)).ToArray());
            Assert.Equal(expectedTombs, actual.Tombstones);
            Assert.Equal(expected.GetProperty("conflictCopyCount").GetInt32(), actual.ConflictCopyCount);
            Assert.Equal(expected.GetProperty("subsumedDuplicateCount").GetInt32(), actual.SubsumedDuplicateCount);
            Assert.Equal(ParseChanges(expected.GetProperty("pcChanges")), actual.PcChanges);
            Assert.Equal(ParseChanges(expected.GetProperty("remoteChanges")), actual.RemoteChanges);
            long? expectedSkew = expected.TryGetProperty("clockSkewSeconds", out var cs) ? cs.GetInt64() : null;
            Assert.Equal(expectedSkew, actual.ClockSkewSeconds);

            if (testCase.TryGetProperty("alsoCheckCommutative", out var comm) && comm.GetBoolean())
            {
                var swapped = TemplateSyncMerge.Merge(remote, pc, nowMillis, remoteSentAt);
                Assert.Equal(actual.Templates, swapped.Templates);
                Assert.Equal(actual.Tombstones, swapped.Tombstones);
            }

            if (testCase.TryGetProperty("alsoCheckIdempotent", out var idem) && idem.GetBoolean())
            {
                var pc2 = new TemplateSyncState(actual.Templates, actual.Tombstones);
                var remote2 = new TemplateSyncState(
                    actual.Templates.Select(t => t with { BaseHash = TemplateSyncMerge.ContentHash(t) }).ToArray(),
                    actual.Tombstones);
                var resync = TemplateSyncMerge.Merge(pc2, remote2, nowMillis + 1000, nowMillis + 1000);
                Assert.Equal(0, resync.PcChanges.Total);
                Assert.Equal(0, resync.RemoteChanges.Total);
                Assert.Equal(0, resync.ConflictCopyCount);
                Assert.Equal(0, resync.SubsumedDuplicateCount);
                Assert.Equal(actual.Templates, resync.Templates);
                Assert.Equal(actual.Tombstones, resync.Tombstones);
            }

            if (testCase.TryGetProperty("alsoCheckSlowClockResendNotExtended", out var slowResend) && slowResend.GetBoolean() && remoteSentAt is long sentAt)
            {
                const long tenDays = 10L * 24 * 60 * 60 * 1000;
                var laterNow = nowMillis + tenDays;
                var laterSentAt = sentAt + tenDays;
                var pc2 = new TemplateSyncState(actual.Templates, actual.Tombstones);
                var remoteSynced = new TemplateSyncState(
                    actual.Templates.Select(t => t with { BaseHash = TemplateSyncMerge.ContentHash(t) }).ToArray(),
                    actual.Tombstones);
                var resyncSynced = TemplateSyncMerge.Merge(pc2, remoteSynced, laterNow, laterSentAt);
                Assert.Equal(0, resyncSynced.PcChanges.Total);
                Assert.Equal(actual.Tombstones, resyncSynced.Tombstones);

                var resyncUnacked = TemplateSyncMerge.Merge(pc2, remote, laterNow, laterSentAt - 3000);
                Assert.Equal(actual.Tombstones, resyncUnacked.Tombstones);
            }
        }
    }

    [Fact]
    public void TemplateMultiMergeCasesMatchIndependentVectors()
    {
        static TemplateSyncItem ParseItem(JsonElement el) => new(
            Guid.Parse(el.GetProperty("id").GetString()!),
            el.GetProperty("kind").GetString()! == "url" ? TemplateSyncKind.Url : TemplateSyncKind.Text,
            el.GetProperty("text").GetString()!,
            el.TryGetProperty("title", out var t) ? t.GetString() : null,
            el.TryGetProperty("tag", out var g) ? g.GetString() : null,
            el.GetProperty("order").GetInt32(),
            el.GetProperty("updatedAt").GetInt64(),
            el.TryGetProperty("baseHash", out var bh) ? bh.GetString() : null);

        static TemplateSyncTombstone ParseTomb(JsonElement el) => new(
            Guid.Parse(el.GetProperty("id").GetString()!),
            el.GetProperty("deletedAt").GetInt64(),
            el.TryGetProperty("baseHash", out var bh) ? bh.GetString() : null);

        static TemplateSyncState ParseSide(JsonElement el) => new(
            el.GetProperty("templates").EnumerateArray().Select(ParseItem).ToArray(),
            el.GetProperty("tombstones").EnumerateArray().Select(ParseTomb).ToArray());

        static TemplateSyncSideChanges ParseChanges(JsonElement el) => new(
            el.GetProperty("added").GetInt32(),
            el.GetProperty("updated").GetInt32(),
            el.GetProperty("deleted").GetInt32());

        foreach (var testCase in V.GetProperty("templateMultiMergeCases").EnumerateArray())
        {
            var nowMillis = testCase.GetProperty("nowMillis").GetInt64();
            var pc = ParseSide(testCase.GetProperty("pc"));
            var remotes = testCase.GetProperty("remotes").EnumerateArray().Select(r =>
            {
                long? sentAt = r.TryGetProperty("sentAtMillis", out var sa) && sa.ValueKind != JsonValueKind.Null ? sa.GetInt64() : null;
                return new TemplateSyncRemoteState(ParseSide(r.GetProperty("state")), sentAt);
            }).ToArray();

            var actual = TemplateSyncMerge.MergeAll(pc, remotes, nowMillis);
            var expected = testCase.GetProperty("expected");
            var expectedTemplates = expected.GetProperty("templates").EnumerateArray().Select(ParseItem).ToArray();
            var expectedTombs = expected.GetProperty("tombstones").EnumerateArray().Select(ParseTomb).ToArray();

            Assert.Equal(expectedTemplates, actual.Templates);
            Assert.Equal(expectedTemplates.Select(t => Encoding.UTF8.GetBytes(t.Text)).ToArray(), actual.Templates.Select(t => Encoding.UTF8.GetBytes(t.Text)).ToArray());
            Assert.Equal(expectedTombs, actual.Tombstones);
            Assert.Equal(expected.GetProperty("conflictCopyCount").GetInt32(), actual.ConflictCopyCount);
            Assert.Equal(expected.GetProperty("subsumedDuplicateCount").GetInt32(), actual.SubsumedDuplicateCount);
            Assert.Equal(ParseChanges(expected.GetProperty("pcChanges")), actual.PcChanges);

            var expectedRemoteChanges = expected.GetProperty("remoteChanges").EnumerateArray().Select(ParseChanges).ToArray();
            Assert.Equal(expectedRemoteChanges, actual.RemoteChanges);

            var expectedSkews = expected.GetProperty("remoteClockSkewSeconds").EnumerateArray()
                .Select(el => el.ValueKind == JsonValueKind.Null ? (long?)null : el.GetInt64()).ToArray();
            Assert.Equal(expectedSkews, actual.RemoteClockSkewSeconds);

            if (testCase.TryGetProperty("alsoCheckAllPermutations", out var perm) && perm.GetBoolean() && remotes.Length == 2)
            {
                var swapped = TemplateSyncMerge.MergeAll(pc, [remotes[1], remotes[0]], nowMillis);
                Assert.Equal(actual.Templates, swapped.Templates);
                Assert.Equal(actual.Tombstones, swapped.Tombstones);
                Assert.Equal(actual.ConflictCopyCount, swapped.ConflictCopyCount);
                Assert.Equal(actual.SubsumedDuplicateCount, swapped.SubsumedDuplicateCount);
                Assert.Equal(actual.PcChanges, swapped.PcChanges);
                Assert.Equal([actual.RemoteChanges[1], actual.RemoteChanges[0]], swapped.RemoteChanges);
            }
        }
    }

    [Fact]
    public void TemplatePageSplitCasesMatchIndependentVectors()
    {
        var op = Guid.NewGuid();
        foreach (var testCase in V.GetProperty("templatePageSplitCases").EnumerateArray())
        {
            var sentAt = testCase.GetProperty("sentAt").GetInt64();
            var isState = testCase.GetProperty("isState").GetBoolean();
            var items = testCase.GetProperty("items").EnumerateArray().Select(el => new TemplateSyncItem(
                Guid.Parse(el.GetProperty("id").GetString()!),
                TemplateSyncKind.Text,
                new string(el.GetProperty("fillChar").GetString()![0], el.GetProperty("textBytes").GetInt32()),
                null,
                null,
                el.GetProperty("order").GetInt32(),
                el.GetProperty("updatedAt").GetInt64(),
                el.TryGetProperty("baseHash", out var bh) && bh.ValueKind != JsonValueKind.Null ? bh.GetString() : null)).ToArray();

            var snapshot = new TemplateSyncSnapshot(sentAt, items, []);
            var pages = TemplateSyncMessageCodec.SplitPages(op, snapshot, isState);
            var expectedCounts = testCase.GetProperty("expectedPageItemCounts").EnumerateArray().Select(e => e.GetInt32()).ToArray();
            var expectedBodyBytes = testCase.GetProperty("expectedPageBodyBytes").EnumerateArray().Select(e => e.GetInt32()).ToArray();
            Assert.Equal(expectedCounts.Length, pages.Count);

            var assembler = new TemplateSyncPageAssembler(expectedOp: op, expectedIsState: isState);
            TemplateSyncSnapshot? roundtrip = null;
            for (var i = 0; i < pages.Count; i++)
            {
                var encoded = TemplateSyncMessageCodec.Encode(pages[i]);
                var hdrLen = BinaryPrimitives.ReadUInt16BigEndian(encoded);
                var bodyLen = encoded.Length - 2 - hdrLen;
                Assert.Equal(expectedBodyBytes[i], bodyLen);

                var decoded = TemplateSyncMessageCodec.Decode(encoded);
                var pageTemplates = decoded switch
                {
                    TemplateSyncPush p => p.Page.Templates,
                    TemplateSyncStateMessage s => s.Page.Templates,
                    _ => throw new InvalidOperationException(),
                };
                Assert.Equal(expectedCounts[i], pageTemplates.Count);
                roundtrip = assembler.Append(decoded);
            }
            Assert.NotNull(roundtrip);
            Assert.Equal(items, roundtrip!.Templates);
            assembler.Finish();
        }
    }

    [Fact]
    public void TemplatePrepareCasesMatchIndependentVectors()
    {
        var op = Guid.NewGuid();
        foreach (var testCase in V.GetProperty("templatePrepareCases").EnumerateArray())
        {
            var name = testCase.GetProperty("name").GetString()!;
            var nowMillis = testCase.GetProperty("nowMillis").GetInt64();
            var sentAtMillis = testCase.GetProperty("sentAtMillis").GetInt64();
            if (name == "threeHundred64KiBItemsCappedAt240")
            {
                var count = testCase.GetProperty("itemCount").GetInt32();
                var textBytes = testCase.GetProperty("textBytes").GetInt32();
                var items = Enumerable.Range(0, count).Select(i => new TemplateSyncItem(
                    Guid.Parse($"66666666-5555-4666-8777-{i:D12}"),
                    TemplateSyncKind.Text,
                    new string('x', textBytes),
                    null,
                    null,
                    i,
                    nowMillis)).ToArray();
                var prepared = TemplateSyncMerge.PrepareSyncState(items, [], nowMillis, sentAtMillis);
                Assert.Equal(testCase.GetProperty("expectedKeptCount").GetInt32(), prepared.State.Templates.Count);
                Assert.Equal(testCase.GetProperty("expectedExcludedCount").GetInt32(), prepared.ExcludedTemplateCount);
                var pages = TemplateSyncMessageCodec.SplitPages(op, new TemplateSyncSnapshot(sentAtMillis, prepared.State.Templates, prepared.State.Tombstones), isState: false);
                Assert.Equal(testCase.GetProperty("expectedPageCount").GetInt32(), pages.Count);
                foreach (var p in pages) _ = TemplateSyncMessageCodec.Encode(p);
            }
            else if (name == "oversizedTextAndControlEscapedExcluded")
            {
                var items = new[]
                {
                    new TemplateSyncItem(Guid.Parse("44444444-5555-4666-8777-888888888881"), TemplateSyncKind.Text, "ok-1", null, null, 0, nowMillis),
                    new TemplateSyncItem(Guid.Parse("44444444-5555-4666-8777-888888888882"), TemplateSyncKind.Text, new string('a', SyncProtocol.MaxTemplateTextBytes + 1), null, null, 1, nowMillis),
                    new TemplateSyncItem(Guid.Parse("44444444-5555-4666-8777-888888888883"), TemplateSyncKind.Text, new string('\u0001', SyncProtocol.MaxTemplateTextBytes), null, null, 2, nowMillis),
                    new TemplateSyncItem(Guid.Parse("44444444-5555-4666-8777-888888888884"), TemplateSyncKind.Text, "ok-2", null, null, 3, nowMillis),
                };
                var prepared = TemplateSyncMerge.PrepareSyncState(items, [], nowMillis, sentAtMillis);
                var expectedIds = testCase.GetProperty("expectedKeptIds").EnumerateArray().Select(e => Guid.Parse(e.GetString()!)).ToArray();
                Assert.Equal(expectedIds, prepared.State.Templates.Select(t => t.Id).ToArray());
                Assert.Equal(testCase.GetProperty("expectedExcludedCount").GetInt32(), prepared.ExcludedTemplateCount);
            }
            else if (name == "over300TemplatesAndOver1000Tombstones")
            {
                var count = testCase.GetProperty("itemCount").GetInt32();
                var tombCount = testCase.GetProperty("tombstoneCount").GetInt32();
                var items = Enumerable.Range(0, count).Select(i => new TemplateSyncItem(
                    Guid.Parse($"77777777-5555-4666-8777-{i:D12}"),
                    TemplateSyncKind.Text,
                    $"item-{i}",
                    null,
                    null,
                    i,
                    nowMillis)).ToArray();
                var tombs = Enumerable.Range(0, tombCount).Select(i => new TemplateSyncTombstone(
                    Guid.Parse($"88888888-5555-4666-8777-{i:D12}"),
                    nowMillis - 10_000 + i)).ToArray();
                var prepared = TemplateSyncMerge.PrepareSyncState(items, tombs, nowMillis, sentAtMillis);
                Assert.Equal(testCase.GetProperty("expectedKeptCount").GetInt32(), prepared.State.Templates.Count);
                Assert.Equal(testCase.GetProperty("expectedExcludedCount").GetInt32(), prepared.ExcludedTemplateCount);
                Assert.Equal(testCase.GetProperty("expectedTombstoneCount").GetInt32(), prepared.State.Tombstones.Count);
                Assert.Equal(testCase.GetProperty("expectedFirstTombstoneDeletedAt").GetInt64(), prepared.State.Tombstones[0].DeletedAt);
                Assert.Equal(testCase.GetProperty("expectedLastTombstoneDeletedAt").GetInt64(), prepared.State.Tombstones[^1].DeletedAt);
            }
            else
            {
                throw new InvalidOperationException($"Unknown prepare case: {name}");
            }
        }
    }
}
