using System.Buffers.Binary;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace ClipboardPlus.Sync;

public abstract record SyncMessage;
public sealed record SyncItem(Guid Id, long At, string From, string Text) : SyncMessage;
public sealed record SyncAck(IReadOnlyList<Guid> Ids) : SyncMessage;
public sealed record SyncPing : SyncMessage;

public static class SyncMessageCodec
{
    public static byte[] Encode(SyncMessage message)
    {
        try
        {
            using var stream = new MemoryStream();
            using var json = new Utf8JsonWriter(stream);
            byte[] body = [];
            json.WriteStartObject();
            switch (message)
            {
                case SyncItem item:
                    SyncProtocol.Require(item.At >= -SyncProtocol.MaxTimestamp && item.At <= SyncProtocol.MaxTimestamp && item.From is "pad" or "pc");
                    SyncProtocol.Require(SyncProtocol.Utf8.GetByteCount(item.Text) <= SyncProtocol.MaxPlaintextBytes, SyncError.Limit);
                    body = SyncProtocol.Utf8.GetBytes(item.Text);
                    json.WriteNumber("at", item.At);
                    json.WriteString("from", item.From);
                    json.WriteString("id", SyncProtocol.Id(item.Id));
                    json.WriteString("kind", "text");
                    json.WriteString("t", "item");
                    break;
                case SyncAck ack:
                    SyncProtocol.Require(ack.Ids.Count is >= 1 and <= SyncProtocol.MaxAckIds, SyncError.Limit);
                    json.WriteStartArray("ids");
                    foreach (var id in ack.Ids) json.WriteStringValue(SyncProtocol.Id(id));
                    json.WriteEndArray(); json.WriteString("t", "ack");
                    break;
                case SyncPing:
                    json.WriteString("t", "ping"); break;
                default: throw new SyncProtocolException(SyncError.Format);
            }
            json.WriteEndObject(); json.Flush();
            var header = stream.ToArray();
            SyncProtocol.Require(header.Length <= SyncProtocol.MaxHeaderBytes && 2 + header.Length + body.Length <= SyncProtocol.MaxPlaintextBytes, SyncError.Limit);
            var result = new byte[2 + header.Length + body.Length];
            BinaryPrimitives.WriteUInt16BigEndian(result, (ushort)header.Length);
            header.CopyTo(result, 2); body.CopyTo(result, 2 + header.Length);
            return result;
        }
        catch (EncoderFallbackException) { throw new SyncProtocolException(SyncError.Format); }
    }

    public static SyncMessage Decode(ReadOnlySpan<byte> plaintext)
    {
        SyncProtocol.Require(plaintext.Length <= SyncProtocol.MaxPlaintextBytes, SyncError.Limit);
        SyncProtocol.Require(plaintext.Length >= 2);
        var length = BinaryPrimitives.ReadUInt16BigEndian(plaintext);
        SyncProtocol.Require(length > 0 && length <= plaintext.Length - 2);
        var header = plaintext.Slice(2, length).ToArray();
        SyncProtocol.Require(header.All(b => b < 128));
        var body = plaintext[(2 + length)..];
        try
        {
            using var doc = JsonDocument.Parse(header, new JsonDocumentOptions { MaxDepth = 8 });
            var root = doc.RootElement;
            SyncProtocol.Require(root.ValueKind == JsonValueKind.Object);
            var properties = root.EnumerateObject().ToArray();
            SyncProtocol.Require(properties.Select(p => p.Name).Distinct(StringComparer.Ordinal).Count() == properties.Length);
            // ASCII applies to decoded header strings too (including JSON escapes).
            static void Ascii(JsonElement element)
            {
                if (element.ValueKind == JsonValueKind.String) SyncProtocol.Require(element.GetString()!.All(c => c < 128));
                if (element.ValueKind == JsonValueKind.Array) foreach (var e in element.EnumerateArray()) Ascii(e);
                if (element.ValueKind == JsonValueKind.Object) foreach (var p in element.EnumerateObject())
                { SyncProtocol.Require(p.Name.All(c => c < 128)); Ascii(p.Value); }
            }
            Ascii(root);
            void Keys(params string[] expected) => SyncProtocol.Require(properties.Length == expected.Length && expected.All(k => root.TryGetProperty(k, out _)));
            switch (root.GetProperty("t").GetString())
            {
                case "item":
                    Keys("at", "from", "id", "kind", "t");
                    SyncProtocol.Require(root.GetProperty("kind").GetString() == "text");
                    var from = root.GetProperty("from").GetString();
                    SyncProtocol.Require(from is "pad" or "pc");
                    var at = root.GetProperty("at");
                    var raw = at.GetRawText();
                    SyncProtocol.Require(at.ValueKind == JsonValueKind.Number && raw.All(c => c is >= '0' and <= '9' or '-') && at.TryGetInt64(out _));
                    var millis = at.GetInt64();
                    SyncProtocol.Require(millis >= -SyncProtocol.MaxTimestamp && millis <= SyncProtocol.MaxTimestamp);
                    return new SyncItem(SyncProtocol.ParseId(root.GetProperty("id").GetString()), millis, from!, SyncProtocol.Utf8.GetString(body));
                case "ack":
                    Keys("ids", "t"); SyncProtocol.Require(body.IsEmpty);
                    var ids = root.GetProperty("ids");
                    SyncProtocol.Require(ids.ValueKind == JsonValueKind.Array);
                    SyncProtocol.Require(ids.GetArrayLength() is >= 1 and <= SyncProtocol.MaxAckIds, SyncError.Limit);
                    return new SyncAck(ids.EnumerateArray().Select(v => SyncProtocol.ParseId(v.GetString())).ToArray());
                case "ping":
                    Keys("t"); SyncProtocol.Require(body.IsEmpty); return new SyncPing();
                default: throw new SyncProtocolException(SyncError.Format);
            }
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or DecoderFallbackException)
        { throw new SyncProtocolException(SyncError.Format); }
    }
}
