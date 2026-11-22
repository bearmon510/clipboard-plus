using System.Buffers.Binary;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace ClipboardPlus.Sync;

public abstract record SyncMessage;
public sealed record SyncItem(Guid Id, long At, string From, string Text) : SyncMessage;
public sealed record SyncAck(IReadOnlyList<Guid> Ids) : SyncMessage;
public sealed record SyncPing : SyncMessage;
public sealed record SyncPong : SyncMessage;
public sealed record SyncDevice(string Kind) : SyncMessage;
public sealed record SyncOffer(Guid Id, long At, string From, string Kind, int Size, string Sha256, string Name64, string Type) : SyncMessage
{
    public string Filename => Name64 is null ? "" : SyncProtocol.Utf8.GetString(Convert.FromBase64String(Name64));
}
public sealed record SyncChunk(Guid Id, int Offset, byte[] Data) : SyncMessage;
public sealed record SyncResume(Guid Id, int Offset) : SyncMessage;

public static class SyncMessageCodec
{
    public static byte[] Encode(SyncMessage message)
    {
        try
        {
            using var stream = new MemoryStream();
            using var json = new Utf8JsonWriter(stream, new JsonWriterOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
            byte[] body = [];
            json.WriteStartObject();
            switch (message)
            {
                case SyncDevice device:
                    SyncProtocol.Require(device.Kind is "phone" or "pad");
                    json.WriteString("kind", device.Kind); json.WriteString("t", "device"); break;
                case SyncOffer offer:
                    ValidateOffer(offer);
                    json.WriteNumber("at", offer.At); json.WriteString("from", offer.From);
                    json.WriteString("id", SyncProtocol.Id(offer.Id)); json.WriteString("kind", offer.Kind);
                    json.WriteString("name64", offer.Name64); json.WriteString("sha256", offer.Sha256);
                    json.WriteNumber("size", offer.Size); json.WriteString("t", "offer"); json.WriteString("type", offer.Type); break;
                case SyncResume resume:
                    SyncProtocol.Require(resume.Offset is >= 0 and <= SyncProtocol.MaxItemBytes);
                    json.WriteString("id", SyncProtocol.Id(resume.Id)); json.WriteNumber("offset", resume.Offset);
                    json.WriteString("t", "resume"); break;
                case SyncChunk chunk:
                    SyncProtocol.Require(chunk.Offset >= 0 && chunk.Data.Length is > 0 and <= SyncProtocol.ChunkBytes && chunk.Offset <= SyncProtocol.MaxItemBytes - chunk.Data.Length);
                    json.WriteString("id", SyncProtocol.Id(chunk.Id)); json.WriteNumber("offset", chunk.Offset);
                    json.WriteString("t", "chunk"); body = chunk.Data; break;
                case SyncItem item:
                    SyncProtocol.Require(item.Text is not null && item.At >= -SyncProtocol.MaxTimestamp && item.At <= SyncProtocol.MaxTimestamp && item.From is "pad" or "pc");
                    SyncProtocol.Require(SyncProtocol.Utf8.GetByteCount(item.Text) <= SyncProtocol.MaxPlaintextBytes, SyncError.Limit);
                    body = SyncProtocol.Utf8.GetBytes(item.Text);
                    json.WriteNumber("at", item.At);
                    json.WriteString("from", item.From);
                    json.WriteString("id", SyncProtocol.Id(item.Id));
                    json.WriteString("kind", "text");
                    json.WriteString("t", "item");
                    break;
                case SyncAck ack:
                    SyncProtocol.Require(ack.Ids is not null);
                    SyncProtocol.Require(ack.Ids.Count is >= 1 and <= SyncProtocol.MaxAckIds, SyncError.Limit);
                    json.WriteStartArray("ids");
                    foreach (var id in ack.Ids) json.WriteStringValue(SyncProtocol.Id(id));
                    json.WriteEndArray(); json.WriteString("t", "ack");
                    break;
                case SyncPing:
                    json.WriteString("t", "ping"); break;
                case SyncPong:
                    json.WriteString("t", "pong"); break;
                default: throw new SyncProtocolException(SyncError.Format);
            }
            json.WriteEndObject(); json.Flush();
            return FramePlaintext(stream.ToArray(), body);
        }
        catch (EncoderFallbackException) { throw new SyncProtocolException(SyncError.Format); }
    }

    internal static byte[] FramePlaintext(ReadOnlySpan<byte> header, ReadOnlySpan<byte> body)
    {
        SyncProtocol.Require(header.Length <= SyncProtocol.MaxHeaderBytes && 2 + header.Length + body.Length <= SyncProtocol.MaxPlaintextBytes, SyncError.Limit);
        var result = new byte[2 + header.Length + body.Length];
        BinaryPrimitives.WriteUInt16BigEndian(result, (ushort)header.Length);
        header.CopyTo(result.AsSpan(2));
        body.CopyTo(result.AsSpan(2 + header.Length));
        return result;
    }

    internal static (byte[] Header, ReadOnlyMemory<byte> Body) SplitPlaintext(byte[] plaintext)
    {
        SyncProtocol.Require(plaintext.Length <= SyncProtocol.MaxPlaintextBytes, SyncError.Limit);
        SyncProtocol.Require(plaintext.Length >= 2);
        var length = BinaryPrimitives.ReadUInt16BigEndian(plaintext);
        SyncProtocol.Require(length > 0 && length <= plaintext.Length - 2);
        var header = plaintext.AsSpan(2, length).ToArray();
        SyncProtocol.Require(header.All(b => b < 128));
        return (header, plaintext.AsMemory(2 + length));
    }

    internal static void CheckAsciiJson(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.String) SyncProtocol.Require(element.GetString()!.All(c => c < 128));
        if (element.ValueKind == JsonValueKind.Array) foreach (var e in element.EnumerateArray()) CheckAsciiJson(e);
        if (element.ValueKind == JsonValueKind.Object) foreach (var p in element.EnumerateObject())
        { SyncProtocol.Require(p.Name.All(c => c < 128)); CheckAsciiJson(p.Value); }
    }

    internal static void CheckNoDuplicateKeys(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in element.EnumerateArray()) CheckNoDuplicateKeys(item);
        }
        else if (element.ValueKind == JsonValueKind.Object)
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var p in element.EnumerateObject())
            {
                SyncProtocol.Require(seen.Add(p.Name));
                CheckNoDuplicateKeys(p.Value);
            }
        }
    }

    public static SyncMessage Decode(ReadOnlySpan<byte> plaintext)
    {
        var (header, bodyMemory) = SplitPlaintext(plaintext.ToArray());
        var body = bodyMemory.Span;
        try
        {
            using var doc = JsonDocument.Parse(header, new JsonDocumentOptions { MaxDepth = 8 });
            var root = doc.RootElement;
            SyncProtocol.Require(root.ValueKind == JsonValueKind.Object);
            var properties = root.EnumerateObject().ToArray();
            SyncProtocol.Require(properties.Select(p => p.Name).Distinct(StringComparer.Ordinal).Count() == properties.Length);
            // ASCII applies to decoded header strings too (including JSON escapes).
            CheckAsciiJson(root);
            void Keys(params string[] expected) => SyncProtocol.Require(properties.Length == expected.Length && expected.All(k => root.TryGetProperty(k, out _)));
            var messageType = String(root, "t");
            switch (messageType)
            {
                case "device":
                    Keys("kind", "t"); SyncProtocol.Require(body.IsEmpty);
                    var kind = String(root, "kind");
                    SyncProtocol.Require(kind is "phone" or "pad"); return new SyncDevice(kind);
                case "offer":
                    Keys("at", "from", "id", "kind", "name64", "sha256", "size", "t", "type");
                    SyncProtocol.Require(body.IsEmpty);
                    var offer = new SyncOffer(SyncProtocol.ParseId(String(root, "id")), Integer(root, "at"),
                        String(root, "from"), String(root, "kind"), checked((int)Integer(root, "size")),
                        String(root, "sha256"), String(root, "name64"), String(root, "type"));
                    ValidateOffer(offer); return offer;
                case "chunk":
                case "resume":
                    Keys("id", "offset", "t");
                    var offset = Integer(root, "offset");
                    SyncProtocol.Require(offset >= 0 && offset <= SyncProtocol.MaxItemBytes);
                    var itemId = SyncProtocol.ParseId(String(root, "id"));
                    if (messageType == "resume")
                    { SyncProtocol.Require(body.IsEmpty); return new SyncResume(itemId, (int)offset); }
                    SyncProtocol.Require(body.Length is > 0 and <= SyncProtocol.ChunkBytes && offset + body.Length <= SyncProtocol.MaxItemBytes);
                    return new SyncChunk(itemId, (int)offset, body.ToArray());
                case "item":
                    Keys("at", "from", "id", "kind", "t");
                    SyncProtocol.Require(String(root, "kind") == "text");
                    var from = String(root, "from");
                    SyncProtocol.Require(from is "pad" or "pc");
                    var millis = Integer(root, "at");
                    SyncProtocol.Require(millis >= -SyncProtocol.MaxTimestamp && millis <= SyncProtocol.MaxTimestamp);
                    return new SyncItem(SyncProtocol.ParseId(String(root, "id")), millis, from, SyncProtocol.Utf8.GetString(body));
                case "ack":
                    Keys("ids", "t"); SyncProtocol.Require(body.IsEmpty);
                    var ids = root.GetProperty("ids");
                    SyncProtocol.Require(ids.ValueKind == JsonValueKind.Array);
                    SyncProtocol.Require(ids.GetArrayLength() is >= 1 and <= SyncProtocol.MaxAckIds, SyncError.Limit);
                    return new SyncAck(ids.EnumerateArray().Select(v =>
                    {
                        SyncProtocol.Require(v.ValueKind == JsonValueKind.String);
                        return SyncProtocol.ParseId(v.GetString());
                    }).ToArray());
                case "ping":
                    Keys("t"); SyncProtocol.Require(body.IsEmpty); return new SyncPing();
                case "pong":
                    Keys("t"); SyncProtocol.Require(body.IsEmpty); return new SyncPong();
                default: throw new SyncProtocolException(SyncError.Format);
            }
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or DecoderFallbackException or OverflowException)
        { throw new SyncProtocolException(SyncError.Format); }
    }

    internal static string String(JsonElement root, string key)
    {
        var value = root.GetProperty(key);
        SyncProtocol.Require(value.ValueKind == JsonValueKind.String);
        return value.GetString()!;
    }
    internal static long Integer(JsonElement root, string key)
    {
        var value = root.GetProperty(key);
        SyncProtocol.Require(value.ValueKind == JsonValueKind.Number && value.GetRawText().All(c => c is >= '0' and <= '9' or '-') && value.TryGetInt64(out _));
        return value.GetInt64();
    }
    public static void ValidateOffer(SyncOffer o, int maxSize = SyncProtocol.MaxItemBytes)
    {
        SyncProtocol.Require(o.At >= -SyncProtocol.MaxTimestamp && o.At <= SyncProtocol.MaxTimestamp && o.From is "pc" or "pad");
        SyncProtocol.Require(o.Kind is "image" or "file" && o.Size >= 0);
        SyncProtocol.Require(o.Size <= maxSize, maxSize > SyncProtocol.MaxItemBytes ? SyncError.Limit : SyncError.Format);
        SyncProtocol.Require(SyncProtocol.IsLowerHex64(o.Sha256));
        SyncProtocol.Require(o.Type is { Length: > 0 and <= 255 } && o.Type.All(c => c is >= (char)32 and < (char)127));
        SyncProtocol.Require(o.Kind != "image" || o.Type is "public.png" or "public.jpeg");
        SyncProtocol.Require(o.Name64 is not null);
        try
        {
            var name = Convert.FromBase64String(o.Name64);
            SyncProtocol.Require(name.Length <= 1024 && Convert.ToBase64String(name) == o.Name64);
            var decoded = SyncProtocol.Utf8.GetString(name);
            // Reject Unicode Cc (U+0000..U+001F, U+007F..U+009F) while permitting Cf (e.g. U+200D ZWJ).
            SyncProtocol.Require(!decoded.Any(char.IsControl) && (o.Kind != "file" || decoded.Length > 0));
        }
        catch (Exception e) when (e is FormatException or DecoderFallbackException) { throw new SyncProtocolException(SyncError.Format); }
    }
}
