using System.Globalization;
using System.Text;
using System.Text.Json;

namespace ClipboardPlus.Sync;

public enum TemplateSyncKind
{
    Text,
    Url,
}

public sealed record TemplateSyncItem(
    Guid Id,
    TemplateSyncKind Kind,
    string Text,
    string? Title,
    string? Tag,
    int Order,
    long UpdatedAt,
    string? BaseHash = null);

public sealed record TemplateSyncTombstone(
    Guid Id,
    long DeletedAt,
    string? BaseHash = null);

public sealed record TemplateSyncPage(
    int? Version,
    long? SentAt,
    IReadOnlyList<TemplateSyncItem> Templates,
    IReadOnlyList<TemplateSyncTombstone> Tombstones);

public sealed record TemplateSyncSnapshot(
    long SentAt,
    IReadOnlyList<TemplateSyncItem> Templates,
    IReadOnlyList<TemplateSyncTombstone> Tombstones);

public abstract record TemplateSyncMessage;

public sealed record TemplateSyncPull(Guid Op) : TemplateSyncMessage;

public sealed record TemplateSyncPush(Guid Op, int Part, int Total, TemplateSyncPage Page) : TemplateSyncMessage;

public sealed record TemplateSyncStateMessage(Guid Op, int Part, int Total, TemplateSyncPage Page) : TemplateSyncMessage;

public sealed record TemplateSyncAck(Guid Op) : TemplateSyncMessage;

internal static class TemplateCanonicalJson
{
    internal static string SerializeString(string value)
    {
        var sb = new StringBuilder(value.Length + 2);
        sb.Append('"');
        foreach (var rune in value.EnumerateRunes())
        {
            var cp = rune.Value;
            switch (cp)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (cp < 0x20)
                        sb.Append($"\\u{cp:x4}");
                    else
                        sb.Append(rune.ToString());
                    break;
            }
        }
        sb.Append('"');
        return sb.ToString();
    }

    internal static string SerializeItem(TemplateSyncItem item, bool includeBaseHash)
    {
        var sb = new StringBuilder();
        sb.Append('{');
        var first = true;
        void Comma() { if (!first) sb.Append(','); first = false; }

        if (includeBaseHash && item.BaseHash is not null)
        {
            Comma();
            sb.Append("\"baseHash\":");
            sb.Append(SerializeString(item.BaseHash));
        }
        Comma();
        sb.Append("\"id\":");
        sb.Append(SerializeString(SyncProtocol.Id(item.Id)));
        Comma();
        sb.Append("\"kind\":");
        sb.Append(item.Kind == TemplateSyncKind.Url ? "\"url\"" : "\"text\"");
        Comma();
        sb.Append("\"order\":");
        sb.Append(item.Order.ToString(CultureInfo.InvariantCulture));
        if (item.Tag is not null)
        {
            Comma();
            sb.Append("\"tag\":");
            sb.Append(SerializeString(item.Tag));
        }
        Comma();
        sb.Append("\"text\":");
        sb.Append(SerializeString(item.Text));
        if (item.Title is not null)
        {
            Comma();
            sb.Append("\"title\":");
            sb.Append(SerializeString(item.Title));
        }
        Comma();
        sb.Append("\"updatedAt\":");
        sb.Append(item.UpdatedAt.ToString(CultureInfo.InvariantCulture));
        sb.Append('}');
        return sb.ToString();
    }

    internal static string SerializeTombstone(TemplateSyncTombstone tomb)
    {
        var sb = new StringBuilder();
        sb.Append('{');
        var first = true;
        void Comma() { if (!first) sb.Append(','); first = false; }

        if (tomb.BaseHash is not null)
        {
            Comma();
            sb.Append("\"baseHash\":");
            sb.Append(SerializeString(tomb.BaseHash));
        }
        Comma();
        sb.Append("\"deletedAt\":");
        sb.Append(tomb.DeletedAt.ToString(CultureInfo.InvariantCulture));
        Comma();
        sb.Append("\"id\":");
        sb.Append(SerializeString(SyncProtocol.Id(tomb.Id)));
        sb.Append('}');
        return sb.ToString();
    }

    internal static string SerializePage(TemplateSyncPage page, bool isFirstPage, bool includeItemBaseHash)
    {
        var sb = new StringBuilder();
        sb.Append('{');
        if (isFirstPage)
        {
            sb.Append("\"sentAt\":");
            sb.Append(page.SentAt!.Value.ToString(CultureInfo.InvariantCulture));
            sb.Append(',');
        }
        sb.Append("\"templates\":[");
        for (var i = 0; i < page.Templates.Count; i++)
        {
            if (i > 0) sb.Append(',');
            sb.Append(SerializeItem(page.Templates[i], includeItemBaseHash));
        }
        sb.Append("],\"tombstones\":[");
        for (var i = 0; i < page.Tombstones.Count; i++)
        {
            if (i > 0) sb.Append(',');
            sb.Append(SerializeTombstone(page.Tombstones[i]));
        }
        sb.Append(']');
        if (isFirstPage)
        {
            sb.Append(",\"v\":");
            sb.Append(page.Version!.Value.ToString(CultureInfo.InvariantCulture));
        }
        sb.Append('}');
        return sb.ToString();
    }
}

public static class TemplateSyncMessageCodec
{
    public static int CountGraphemeClusters(string value) => new StringInfo(value).LengthInTextElements;

    internal static void ValidateTextString(string? text, int maxBytes)
    {
        SyncProtocol.Require(text is not null);
        try
        {
            var bytes = SyncProtocol.Utf8.GetByteCount(text);
            SyncProtocol.Require(bytes <= maxBytes, SyncError.Limit);
        }
        catch (EncoderFallbackException) { throw new SyncProtocolException(SyncError.Format); }
    }

    internal static void ValidateLabelString(string value, int maxChars, int maxBytes)
    {
        try
        {
            var bytes = SyncProtocol.Utf8.GetByteCount(value);
            foreach (var c in value) SyncProtocol.Require(!SyncProtocol.IsControlOrNewline(c));
            SyncProtocol.Require(bytes <= maxBytes, SyncError.Limit);
            SyncProtocol.Require(CountGraphemeClusters(value) <= maxChars, SyncError.Limit);
        }
        catch (EncoderFallbackException) { throw new SyncProtocolException(SyncError.Format); }
    }

    public static void ValidateItem(TemplateSyncItem item, bool allowBaseHash)
    {
        SyncProtocol.Require(item is not null);
        SyncProtocol.Require(item.Kind is TemplateSyncKind.Text or TemplateSyncKind.Url);
        ValidateTextString(item.Text, SyncProtocol.MaxTemplateTextBytes);
        if (item.Title is not null) ValidateLabelString(item.Title, SyncProtocol.MaxTemplateTitleCharacters, SyncProtocol.MaxTemplateTitleBytes);
        if (item.Tag is not null) ValidateLabelString(item.Tag, SyncProtocol.MaxTemplateTagCharacters, SyncProtocol.MaxTemplateTagBytes);
        SyncProtocol.Require(item.Order >= 0);
        SyncProtocol.Require(item.UpdatedAt is >= -SyncProtocol.MaxTimestamp and <= SyncProtocol.MaxTimestamp);
        if (!allowBaseHash)
            SyncProtocol.Require(item.BaseHash is null);
        else if (item.BaseHash is not null)
            SyncProtocol.Require(SyncProtocol.IsLowerHex64(item.BaseHash));
    }

    public static void ValidateTombstone(TemplateSyncTombstone tomb)
    {
        SyncProtocol.Require(tomb is not null);
        SyncProtocol.Require(tomb.DeletedAt is >= -SyncProtocol.MaxTimestamp and <= SyncProtocol.MaxTimestamp);
        if (tomb.BaseHash is not null)
            SyncProtocol.Require(SyncProtocol.IsLowerHex64(tomb.BaseHash));
    }

    internal static void ValidatePage(TemplateSyncPage page, int part, int total, bool isState)
    {
        SyncProtocol.Require(total >= 1);
        SyncProtocol.Require(total <= SyncProtocol.MaxTemplatePages, SyncError.Limit);
        SyncProtocol.Require(part >= 0 && part < total);
        SyncProtocol.Require(page is not null && page.Templates is not null && page.Tombstones is not null);
        if (part == 0)
        {
            SyncProtocol.Require(page.Version == 1);
            SyncProtocol.Require(page.SentAt is >= -SyncProtocol.MaxTimestamp and <= SyncProtocol.MaxTimestamp);
        }
        else
        {
            SyncProtocol.Require(page.Version is null && page.SentAt is null);
        }
        SyncProtocol.Require(page.Templates.Count <= SyncProtocol.MaxTemplates, SyncError.Limit);
        SyncProtocol.Require(page.Tombstones.Count <= SyncProtocol.MaxTemplateTombstones, SyncError.Limit);

        var seenIds = new HashSet<Guid>();
        foreach (var item in page.Templates)
        {
            ValidateItem(item, allowBaseHash: !isState);
            SyncProtocol.Require(seenIds.Add(item.Id));
        }
        foreach (var tomb in page.Tombstones)
        {
            ValidateTombstone(tomb);
            SyncProtocol.Require(seenIds.Add(tomb.Id));
        }
    }

    public static byte[] Encode(TemplateSyncMessage message)
    {
        try
        {
            string header;
            byte[] body;
            switch (message)
            {
                case TemplateSyncPull pull:
                    header = $"{{\"op\":\"{SyncProtocol.Id(pull.Op)}\",\"t\":\"tpl_pull\"}}";
                    body = [];
                    break;
                case TemplateSyncAck ack:
                    header = $"{{\"op\":\"{SyncProtocol.Id(ack.Op)}\",\"t\":\"tpl_ack\"}}";
                    body = [];
                    break;
                case TemplateSyncPush push:
                    ValidatePage(push.Page, push.Part, push.Total, isState: false);
                    header = $"{{\"op\":\"{SyncProtocol.Id(push.Op)}\",\"part\":{push.Part},\"t\":\"tpl_push\",\"total\":{push.Total}}}";
                    body = SyncProtocol.Utf8.GetBytes(TemplateCanonicalJson.SerializePage(push.Page, push.Part == 0, includeItemBaseHash: true));
                    SyncProtocol.Require(body.Length <= SyncProtocol.MaxTemplatePageBodyBytes, SyncError.Limit);
                    break;
                case TemplateSyncStateMessage state:
                    ValidatePage(state.Page, state.Part, state.Total, isState: true);
                    header = $"{{\"op\":\"{SyncProtocol.Id(state.Op)}\",\"part\":{state.Part},\"t\":\"tpl_state\",\"total\":{state.Total}}}";
                    body = SyncProtocol.Utf8.GetBytes(TemplateCanonicalJson.SerializePage(state.Page, state.Part == 0, includeItemBaseHash: false));
                    SyncProtocol.Require(body.Length <= SyncProtocol.MaxTemplatePageBodyBytes, SyncError.Limit);
                    break;
                default:
                    throw new SyncProtocolException(SyncError.Format);
            }
            return SyncMessageCodec.FramePlaintext(Encoding.ASCII.GetBytes(header), body);
        }
        catch (EncoderFallbackException) { throw new SyncProtocolException(SyncError.Format); }
    }

    public static TemplateSyncMessage Decode(ReadOnlySpan<byte> plaintext)
    {
        var (header, bodyMemory) = SyncMessageCodec.SplitPlaintext(plaintext.ToArray());
        var body = bodyMemory.Span;
        try
        {
            using var doc = JsonDocument.Parse(header, new JsonDocumentOptions { MaxDepth = 8 });
            var root = doc.RootElement;
            SyncProtocol.Require(root.ValueKind == JsonValueKind.Object);
            SyncMessageCodec.CheckNoDuplicateKeys(root);
            SyncMessageCodec.CheckAsciiJson(root);

            var propCount = root.EnumerateObject().Count();
            void Keys(params string[] expected) =>
                SyncProtocol.Require(propCount == expected.Length && expected.All(k => root.TryGetProperty(k, out _)));

            var messageType = SyncMessageCodec.String(root, "t");
            switch (messageType)
            {
                case "tpl_pull":
                    Keys("op", "t");
                    SyncProtocol.Require(body.IsEmpty);
                    return new TemplateSyncPull(SyncProtocol.ParseId(SyncMessageCodec.String(root, "op")));
                case "tpl_ack":
                    Keys("op", "t");
                    SyncProtocol.Require(body.IsEmpty);
                    return new TemplateSyncAck(SyncProtocol.ParseId(SyncMessageCodec.String(root, "op")));
                case "tpl_push":
                case "tpl_state":
                    Keys("op", "part", "t", "total");
                    var op = SyncProtocol.ParseId(SyncMessageCodec.String(root, "op"));
                    var totalLong = SyncMessageCodec.Integer(root, "total");
                    SyncProtocol.Require(totalLong >= 1);
                    SyncProtocol.Require(totalLong <= SyncProtocol.MaxTemplatePages, SyncError.Limit);
                    var partLong = SyncMessageCodec.Integer(root, "part");
                    SyncProtocol.Require(partLong >= 0 && partLong < totalLong);
                    var part = (int)partLong;
                    var total = (int)totalLong;
                    var isState = messageType == "tpl_state";

                    SyncProtocol.Require(!body.IsEmpty);
                    SyncProtocol.Require(body.Length <= SyncProtocol.MaxTemplatePageBodyBytes, SyncError.Limit);
                    // Verify strict UTF-8 before parsing.
                    _ = SyncProtocol.Utf8.GetString(body);

                    var page = DecodePage(body, part, isState);
                    ValidatePage(page, part, total, isState);
                    return isState
                        ? new TemplateSyncStateMessage(op, part, total, page)
                        : new TemplateSyncPush(op, part, total, page);
                default:
                    throw new SyncProtocolException(SyncError.Format);
            }
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or DecoderFallbackException or OverflowException)
        { throw new SyncProtocolException(SyncError.Format); }
    }

    private static TemplateSyncPage DecodePage(ReadOnlySpan<byte> body, int part, bool isState)
    {
        using var doc = JsonDocument.Parse(body.ToArray(), new JsonDocumentOptions { MaxDepth = 8 });
        var root = doc.RootElement;
        SyncProtocol.Require(root.ValueKind == JsonValueKind.Object);
        SyncMessageCodec.CheckNoDuplicateKeys(root);

        var props = root.EnumerateObject().ToArray();
        void Keys(params string[] expected) =>
            SyncProtocol.Require(props.Length == expected.Length && expected.All(k => root.TryGetProperty(k, out _)));

        int? version = null;
        long? sentAt = null;
        if (part == 0)
        {
            Keys("sentAt", "templates", "tombstones", "v");
            var v = SyncMessageCodec.Integer(root, "v");
            SyncProtocol.Require(v == 1);
            version = 1;
            sentAt = SyncMessageCodec.Integer(root, "sentAt");
            SyncProtocol.Require(sentAt is >= -SyncProtocol.MaxTimestamp and <= SyncProtocol.MaxTimestamp);
        }
        else
        {
            Keys("templates", "tombstones");
        }

        var templatesElem = root.GetProperty("templates");
        var tombstonesElem = root.GetProperty("tombstones");
        SyncProtocol.Require(templatesElem.ValueKind == JsonValueKind.Array);
        SyncProtocol.Require(tombstonesElem.ValueKind == JsonValueKind.Array);
        SyncProtocol.Require(templatesElem.GetArrayLength() <= SyncProtocol.MaxTemplates, SyncError.Limit);
        SyncProtocol.Require(tombstonesElem.GetArrayLength() <= SyncProtocol.MaxTemplateTombstones, SyncError.Limit);

        var templates = new List<TemplateSyncItem>(templatesElem.GetArrayLength());
        foreach (var el in templatesElem.EnumerateArray())
            templates.Add(DecodeItem(el, allowBaseHash: !isState));

        var tombstones = new List<TemplateSyncTombstone>(tombstonesElem.GetArrayLength());
        foreach (var el in tombstonesElem.EnumerateArray())
            tombstones.Add(DecodeTombstone(el));

        return new TemplateSyncPage(version, sentAt, templates, tombstones);
    }

    private static TemplateSyncItem DecodeItem(JsonElement el, bool allowBaseHash)
    {
        SyncProtocol.Require(el.ValueKind == JsonValueKind.Object);
        foreach (var p in el.EnumerateObject())
        {
            switch (p.Name)
            {
                case "id" or "kind" or "text" or "order" or "updatedAt" or "title" or "tag":
                    break;
                case "baseHash":
                    SyncProtocol.Require(allowBaseHash);
                    break;
                default:
                    throw new SyncProtocolException(SyncError.Format);
            }
        }
        SyncProtocol.Require(el.TryGetProperty("id", out _));
        SyncProtocol.Require(el.TryGetProperty("kind", out _));
        SyncProtocol.Require(el.TryGetProperty("text", out _));
        SyncProtocol.Require(el.TryGetProperty("order", out _));
        SyncProtocol.Require(el.TryGetProperty("updatedAt", out _));

        var id = SyncProtocol.ParseId(SyncMessageCodec.String(el, "id"));
        var kind = SyncMessageCodec.String(el, "kind") switch
        {
            "text" => TemplateSyncKind.Text,
            "url" => TemplateSyncKind.Url,
            _ => throw new SyncProtocolException(SyncError.Format),
        };
        var text = SyncMessageCodec.String(el, "text");
        string? title = el.TryGetProperty("title", out var titleElem)
            ? (titleElem.ValueKind == JsonValueKind.String ? titleElem.GetString()! : throw new SyncProtocolException(SyncError.Format))
            : null;
        string? tag = el.TryGetProperty("tag", out var tagElem)
            ? (tagElem.ValueKind == JsonValueKind.String ? tagElem.GetString()! : throw new SyncProtocolException(SyncError.Format))
            : null;
        var orderLong = SyncMessageCodec.Integer(el, "order");
        SyncProtocol.Require(orderLong is >= 0 and <= int.MaxValue);
        var updatedAt = SyncMessageCodec.Integer(el, "updatedAt");
        string? baseHash = allowBaseHash && el.TryGetProperty("baseHash", out var bhElem)
            ? (bhElem.ValueKind == JsonValueKind.String ? bhElem.GetString()! : throw new SyncProtocolException(SyncError.Format))
            : null;

        return new TemplateSyncItem(id, kind, text, title, tag, (int)orderLong, updatedAt, baseHash);
    }

    private static TemplateSyncTombstone DecodeTombstone(JsonElement el)
    {
        SyncProtocol.Require(el.ValueKind == JsonValueKind.Object);
        foreach (var p in el.EnumerateObject())
        {
            if (p.Name is not ("id" or "deletedAt" or "baseHash"))
                throw new SyncProtocolException(SyncError.Format);
        }
        SyncProtocol.Require(el.TryGetProperty("id", out _));
        SyncProtocol.Require(el.TryGetProperty("deletedAt", out _));

        var id = SyncProtocol.ParseId(SyncMessageCodec.String(el, "id"));
        var deletedAt = SyncMessageCodec.Integer(el, "deletedAt");
        string? baseHash = el.TryGetProperty("baseHash", out var bhElem)
            ? (bhElem.ValueKind == JsonValueKind.String ? bhElem.GetString()! : throw new SyncProtocolException(SyncError.Format))
            : null;

        return new TemplateSyncTombstone(id, deletedAt, baseHash);
    }

    public static IReadOnlyList<TemplateSyncMessage> SplitPages(Guid op, TemplateSyncSnapshot snapshot, bool isState)
    {
        SyncProtocol.Require(snapshot is not null && snapshot.Templates is not null && snapshot.Tombstones is not null);
        SyncProtocol.Require(snapshot.SentAt is >= -SyncProtocol.MaxTimestamp and <= SyncProtocol.MaxTimestamp);
        SyncProtocol.Require(snapshot.Templates.Count <= SyncProtocol.MaxTemplates, SyncError.Limit);
        SyncProtocol.Require(snapshot.Tombstones.Count <= SyncProtocol.MaxTemplateTombstones, SyncError.Limit);

        var seenIds = new HashSet<Guid>();
        foreach (var item in snapshot.Templates)
        {
            ValidateItem(item, allowBaseHash: !isState);
            SyncProtocol.Require(seenIds.Add(item.Id));
        }
        foreach (var tomb in snapshot.Tombstones)
        {
            ValidateTombstone(tomb);
            SyncProtocol.Require(seenIds.Add(tomb.Id));
        }

        const int continuationOverhead = 28; // {"templates":[],"tombstones":[]}
        var firstHeaderBytes = SyncProtocol.Utf8.GetByteCount(
            $"{{\"sentAt\":{snapshot.SentAt.ToString(CultureInfo.InvariantCulture)},\"templates\":[],\"tombstones\":[],\"v\":1}}");

        var pages = new List<TemplateSyncPage>();
        var currentTemplates = new List<TemplateSyncItem>();
        var currentTombstones = new List<TemplateSyncTombstone>();
        var currentBytes = firstHeaderBytes;
        var totalBodyBytes = 0;

        void FlushPage()
        {
            var isFirst = pages.Count == 0;
            SyncProtocol.Require(pages.Count < SyncProtocol.MaxTemplatePages, SyncError.Limit);
            totalBodyBytes += currentBytes;
            SyncProtocol.Require(totalBodyBytes <= SyncProtocol.MaxTemplateTotalBytes, SyncError.Limit);
            pages.Add(new TemplateSyncPage(
                isFirst ? 1 : null,
                isFirst ? snapshot.SentAt : null,
                currentTemplates,
                currentTombstones));
            currentTemplates = [];
            currentTombstones = [];
            currentBytes = continuationOverhead;
        }

        foreach (var item in snapshot.Templates)
        {
            var itemBytes = SyncProtocol.Utf8.GetByteCount(TemplateCanonicalJson.SerializeItem(item, includeBaseHash: !isState));
            var commaBytes = currentTemplates.Count > 0 ? 1 : 0;
            if (currentBytes + commaBytes + itemBytes > SyncProtocol.MaxTemplatePageBodyBytes)
            {
                SyncProtocol.Require(currentTemplates.Count > 0 || currentTombstones.Count > 0, SyncError.Limit);
                FlushPage();
                commaBytes = 0;
                SyncProtocol.Require(currentBytes + itemBytes <= SyncProtocol.MaxTemplatePageBodyBytes, SyncError.Limit);
            }
            currentTemplates.Add(item);
            currentBytes += commaBytes + itemBytes;
        }

        foreach (var tomb in snapshot.Tombstones)
        {
            var tombBytes = SyncProtocol.Utf8.GetByteCount(TemplateCanonicalJson.SerializeTombstone(tomb));
            var commaBytes = currentTombstones.Count > 0 ? 1 : 0;
            if (currentBytes + commaBytes + tombBytes > SyncProtocol.MaxTemplatePageBodyBytes)
            {
                SyncProtocol.Require(currentTemplates.Count > 0 || currentTombstones.Count > 0, SyncError.Limit);
                FlushPage();
                commaBytes = 0;
                SyncProtocol.Require(currentBytes + tombBytes <= SyncProtocol.MaxTemplatePageBodyBytes, SyncError.Limit);
            }
            currentTombstones.Add(tomb);
            currentBytes += commaBytes + tombBytes;
        }

        if (pages.Count == 0 || currentTemplates.Count > 0 || currentTombstones.Count > 0)
            FlushPage();

        var total = pages.Count;
        var result = new TemplateSyncMessage[total];
        for (var i = 0; i < total; i++)
        {
            result[i] = isState
                ? new TemplateSyncStateMessage(op, i, total, pages[i])
                : new TemplateSyncPush(op, i, total, pages[i]);
        }
        return result;
    }
}

public sealed class TemplateSyncPageAssembler
{
    private readonly Guid? expectedOp;
    private readonly bool? expectedIsState;
    private Guid? op;
    private bool? isState;
    private int? total;
    private int nextPart;
    private long sentAt;
    private readonly List<TemplateSyncItem> templates = [];
    private readonly List<TemplateSyncTombstone> tombstones = [];
    private readonly HashSet<Guid> seenIds = [];
    private int totalBodyBytes;
    private bool completed;
    private bool failed;

    public bool HasPartialSnapshot => nextPart > 0 && !completed && !failed;

    public TemplateSyncPageAssembler(Guid? expectedOp = null, bool? expectedIsState = null)
    {
        this.expectedOp = expectedOp;
        this.expectedIsState = expectedIsState;
    }

    public TemplateSyncSnapshot? Append(TemplateSyncMessage message)
    {
        SyncProtocol.Require(!failed && !completed, SyncError.State);
        try
        {
            Guid msgOp;
            int part, msgTotal;
            TemplateSyncPage page;
            bool msgIsState;
            switch (message)
            {
                case TemplateSyncPush push:
                    msgOp = push.Op; part = push.Part; msgTotal = push.Total; page = push.Page; msgIsState = false;
                    break;
                case TemplateSyncStateMessage state:
                    msgOp = state.Op; part = state.Part; msgTotal = state.Total; page = state.Page; msgIsState = true;
                    break;
                default:
                    throw new SyncProtocolException(SyncError.State);
            }

            TemplateSyncMessageCodec.ValidatePage(page, part, msgTotal, msgIsState);

            if (nextPart == 0)
            {
                SyncProtocol.Require(part == 0, SyncError.State);
                SyncProtocol.Require(expectedOp is null || msgOp == expectedOp.Value, SyncError.State);
                SyncProtocol.Require(expectedIsState is null || msgIsState == expectedIsState.Value, SyncError.State);
                op = msgOp;
                isState = msgIsState;
                total = msgTotal;
                sentAt = page.SentAt!.Value;
            }
            else
            {
                SyncProtocol.Require(msgOp == op!.Value && msgIsState == isState!.Value && msgTotal == total!.Value && part == nextPart, SyncError.State);
            }

            var pageBytes = SyncProtocol.Utf8.GetByteCount(
                TemplateCanonicalJson.SerializePage(page, part == 0, includeItemBaseHash: !msgIsState));
            SyncProtocol.Require(pageBytes <= SyncProtocol.MaxTemplatePageBodyBytes, SyncError.Limit);
            totalBodyBytes += pageBytes;
            SyncProtocol.Require(totalBodyBytes <= SyncProtocol.MaxTemplateTotalBytes, SyncError.Limit);
            SyncProtocol.Require(templates.Count + page.Templates.Count <= SyncProtocol.MaxTemplates, SyncError.Limit);
            SyncProtocol.Require(tombstones.Count + page.Tombstones.Count <= SyncProtocol.MaxTemplateTombstones, SyncError.Limit);

            foreach (var item in page.Templates)
            {
                SyncProtocol.Require(seenIds.Add(item.Id));
                templates.Add(item);
            }
            foreach (var tomb in page.Tombstones)
            {
                SyncProtocol.Require(seenIds.Add(tomb.Id));
                tombstones.Add(tomb);
            }

            nextPart++;
            if (nextPart < total!.Value) return null;

            completed = true;
            return new TemplateSyncSnapshot(sentAt, templates.ToArray(), tombstones.ToArray());
        }
        catch
        {
            failed = true;
            templates.Clear();
            tombstones.Clear();
            seenIds.Clear();
            throw;
        }
    }

    public void Finish()
    {
        SyncProtocol.Require(!failed, SyncError.State);
        failed = true;
        var incomplete = nextPart > 0 && !completed;
        templates.Clear();
        tombstones.Clear();
        seenIds.Clear();
        SyncProtocol.Require(!incomplete, SyncError.State);
    }
}
