using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using ClipboardPlus.Sync;

namespace ClipboardPlus.Windows.Core;

public enum TemplateEditError
{
    None,
    Empty,
    Duplicate,
    TooLarge,
    InvalidText,
    LimitExceeded,
    NotFound,
    UnsupportedKind,
    Stopped,
}

public sealed record TemplateEditResult(
    bool Succeeded,
    TemplateEditError Error = TemplateEditError.None,
    TemplateSyncItem? Item = null)
{
    public string? ErrorMessage => Error switch
    {
        TemplateEditError.None => null,
        TemplateEditError.Empty => "本文を入力してください",
        TemplateEditError.Duplicate => "同じ内容のテンプレートがすでにあります",
        TemplateEditError.TooLarge => "本文が長すぎます（64 KB まで）",
        TemplateEditError.InvalidText => "使えない文字が含まれています",
        TemplateEditError.LimitExceeded => "テンプレートは 300 件までです",
        TemplateEditError.NotFound => "テンプレートが見つかりませんでした",
        TemplateEditError.UnsupportedKind => "文章とリンクだけをテンプレートに移動できます",
        TemplateEditError.Stopped => "いまは操作できません",
        _ => "テンプレートを保存できませんでした",
    };
}

public sealed record TemplateDeleteResult(bool Succeeded, TemplateSyncItem? Deleted = null);

public sealed record TemplateGroupView(string? Tag, string Title, IReadOnlyList<TemplateSyncItem> Items);

/// <summary>
/// Atomic JSON repository for templates and tombstones in templates.json.
/// Tolerates corrupt files without crashing and must be called from the coordinator's serialized gate.
/// </summary>
public sealed class TemplateRepository
{
    public const int CurrentFormatVersion = 1;
    public const string FileName = "templates.json";

    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private sealed class StoredTemplate
    {
        public Guid Id { get; set; }
        public string Kind { get; set; } = "text";
        public string Text { get; set; } = "";
        public string? Title { get; set; }
        public string? Tag { get; set; }
        public int Order { get; set; }
        public long UpdatedAt { get; set; }
    }

    private sealed class StoredTombstone
    {
        public Guid Id { get; set; }
        public long DeletedAt { get; set; }
        public string? BaseHash { get; set; }
    }

    private sealed class StoredState
    {
        public int FormatVersion { get; set; } = CurrentFormatVersion;
        public List<StoredTemplate> Templates { get; set; } = [];
        public List<StoredTombstone> Tombstones { get; set; } = [];
    }

    private sealed class RepositoryState
    {
        public List<TemplateSyncItem> Templates { get; set; } = [];
        public List<TemplateSyncTombstone> Tombstones { get; set; } = [];
    }

    private readonly string filePath;
    private readonly Action<string>? log;
    private RepositoryState state;
    private byte[] durable;

    public TemplateRepository(string root, Action<string>? log = null)
    {
        var fullRoot = Path.GetFullPath(root);
        Directory.CreateDirectory(fullRoot);
        filePath = Path.Combine(fullRoot, FileName);
        this.log = log;
        state = LoadState();
        durable = SerializeState(state);
    }

    public int Count => state.Templates.Count;

    public int TombstoneCount => state.Tombstones.Count;

    public TemplateSyncItem? Get(Guid id) =>
        state.Templates.FirstOrDefault(t => t.Id == id);

    public TemplateSyncState GetState() =>
        new(state.Templates.ToArray(), state.Tombstones.ToArray());

    public IReadOnlyList<TemplateSyncItem> List(string? search = null)
    {
        var groups = GetGroups(search);
        if (groups.Count == 0) return [];
        var result = new List<TemplateSyncItem>();
        foreach (var group in groups)
            result.AddRange(group.Items);
        return result;
    }

    public IReadOnlyList<string> Tags() =>
        state.Templates
            .Select(t => t.Tag)
            .Where(t => t is not null)
            .Cast<string>()
            .Distinct(StringComparer.Ordinal)
            .OrderBy(t => t, NaturalTagComparer.Instance)
            .ToArray();

    public IReadOnlyList<TemplateGroupView> GetGroups(string? search = null)
    {
        var query = (search ?? "").Trim();
        var filtered = query.Length == 0
            ? state.Templates
            : state.Templates.Where(t => MatchesSearch(t, query));

        var byTag = new Dictionary<string, List<TemplateSyncItem>>(StringComparer.Ordinal);
        var untagged = new List<TemplateSyncItem>();

        foreach (var item in filtered)
        {
            if (item.Tag is null)
            {
                untagged.Add(item);
            }
            else
            {
                if (!byTag.TryGetValue(item.Tag, out var bucket))
                    byTag[item.Tag] = bucket = [];
                bucket.Add(item);
            }
        }

        var groups = new List<TemplateGroupView>(byTag.Count + (untagged.Count > 0 ? 1 : 0));
        foreach (var tag in byTag.Keys.OrderBy(t => t, NaturalTagComparer.Instance))
            groups.Add(new TemplateGroupView(tag, tag, SortGroupItems(byTag[tag])));

        if (untagged.Count > 0)
            groups.Add(new TemplateGroupView(null, "その他", SortGroupItems(untagged)));

        return groups;
    }

    public TemplateEditResult Create(string text, string? title, string? tag, long nowMillis)
    {
        var validationError = ValidateWritableText(text);
        if (validationError != TemplateEditError.None)
            return new TemplateEditResult(false, validationError);

        if (state.Templates.Count >= SyncProtocol.MaxTemplates)
            return new TemplateEditResult(false, TemplateEditError.LimitExceeded);

        if (state.Templates.Any(t => string.Equals(t.Text, text, StringComparison.Ordinal)))
            return new TemplateEditResult(false, TemplateEditError.Duplicate);

        var normTitle = SanitizeTitle(title);
        var normTag = SanitizeTag(tag);
        var kind = ClassifyKind(text);
        var updatedAt = TemplateSyncMerge.NextUpdatedAt(nowMillis, null);

        var groupItems = GetGroupOrdered(normTag);
        var nextOrder = groupItems.Count;
        var created = new TemplateSyncItem(
            Guid.NewGuid(),
            kind,
            text,
            normTitle,
            normTag,
            nextOrder,
            updatedAt);

        state.Templates.Add(created);
        RenumberGroup(normTag);
        Save();
        return new TemplateEditResult(true, TemplateEditError.None, Get(created.Id));
    }

    public TemplateEditResult Update(Guid id, string text, string? title, string? tag, long nowMillis)
    {
        var index = state.Templates.FindIndex(t => t.Id == id);
        if (index < 0)
            return new TemplateEditResult(false, TemplateEditError.NotFound);

        var validationError = ValidateWritableText(text);
        if (validationError != TemplateEditError.None)
            return new TemplateEditResult(false, validationError);

        if (state.Templates.Any(t => t.Id != id && string.Equals(t.Text, text, StringComparison.Ordinal)))
            return new TemplateEditResult(false, TemplateEditError.Duplicate);

        var existing = state.Templates[index];
        var normTitle = SanitizeTitle(title);
        var normTag = SanitizeTag(tag);
        var newKind = ClassifyKind(text);

        if (existing.Kind == newKind &&
            string.Equals(existing.Text, text, StringComparison.Ordinal) &&
            string.Equals(existing.Title, normTitle, StringComparison.Ordinal) &&
            string.Equals(existing.Tag, normTag, StringComparison.Ordinal))
        {
            return new TemplateEditResult(true, TemplateEditError.None, existing);
        }

        var updatedAt = TemplateSyncMerge.NextUpdatedAt(nowMillis, existing.UpdatedAt);
        var tagChanged = !string.Equals(existing.Tag, normTag, StringComparison.Ordinal);
        var newOrder = tagChanged ? GetGroupOrdered(normTag).Count : existing.Order;

        var updated = existing with
        {
            Kind = newKind,
            Text = text,
            Title = normTitle,
            Tag = normTag,
            Order = newOrder,
            UpdatedAt = updatedAt,
            BaseHash = null,
        };

        state.Templates[index] = updated;
        if (tagChanged)
        {
            RenumberGroup(existing.Tag);
            RenumberGroup(normTag);
        }
        Save();
        return new TemplateEditResult(true, TemplateEditError.None, Get(id));
    }

    public TemplateDeleteResult Delete(Guid id, long nowMillis)
    {
        var index = state.Templates.FindIndex(t => t.Id == id);
        if (index < 0)
            return new TemplateDeleteResult(false);

        var existing = state.Templates[index];
        state.Templates.RemoveAt(index);
        RenumberGroup(existing.Tag);

        var clampedNow = ClampTimestamp(nowMillis);
        var hash = TemplateSyncMerge.ContentHash(existing);
        state.Tombstones.RemoveAll(t => t.Id == existing.Id);
        state.Tombstones.Add(new TemplateSyncTombstone(existing.Id, clampedNow, hash));
        PruneTombstonesInMemory(clampedNow);
        Save();
        return new TemplateDeleteResult(true, existing);
    }

    public TemplateEditResult Restore(TemplateSyncItem deletedItem, long nowMillis)
    {
        ArgumentNullException.ThrowIfNull(deletedItem);

        var validationError = ValidateWritableText(deletedItem.Text);
        if (validationError != TemplateEditError.None)
            return new TemplateEditResult(false, validationError);

        if (state.Templates.Count >= SyncProtocol.MaxTemplates)
            return new TemplateEditResult(false, TemplateEditError.LimitExceeded);

        if (state.Templates.Any(t => t.Id == deletedItem.Id || string.Equals(t.Text, deletedItem.Text, StringComparison.Ordinal)))
            return new TemplateEditResult(false, TemplateEditError.Duplicate);

        var tomb = state.Tombstones.FirstOrDefault(t => t.Id == deletedItem.Id);
        var minPreviousAt = tomb is not null
            ? Math.Max(deletedItem.UpdatedAt, tomb.DeletedAt)
            : deletedItem.UpdatedAt;

        var normTitle = SanitizeTitle(deletedItem.Title);
        var normTag = SanitizeTag(deletedItem.Tag);
        var updatedAt = TemplateSyncMerge.NextUpdatedAt(nowMillis, minPreviousAt);

        var group = GetGroupOrdered(normTag);
        var insertAt = Math.Clamp(deletedItem.Order, 0, group.Count);
        var restored = new TemplateSyncItem(
            deletedItem.Id,
            ClassifyKind(deletedItem.Text),
            deletedItem.Text,
            normTitle,
            normTag,
            insertAt,
            updatedAt);

        group.Insert(insertAt, restored);
        for (var i = 0; i < group.Count; i++)
        {
            if (group[i].Order != i)
                group[i] = group[i] with { Order = i };
        }
        ReplaceGroupItems(normTag, group);
        state.Tombstones.RemoveAll(t => t.Id == deletedItem.Id);
        Save();
        return new TemplateEditResult(true, TemplateEditError.None, Get(restored.Id));
    }

    public bool MoveInGroup(Guid id, int delta, long nowMillis)
    {
        if (delta == 0) return false;
        var existing = Get(id);
        if (existing is null) return false;

        var group = GetGroupOrdered(existing.Tag);
        var index = group.FindIndex(t => t.Id == id);
        var targetIndex = index + delta;
        if (index < 0 || targetIndex < 0 || targetIndex >= group.Count)
            return false;

        var moving = group[index];
        group.RemoveAt(index);
        group.Insert(targetIndex, moving);

        for (var i = 0; i < group.Count; i++)
        {
            var current = group[i];
            if (current.Order != i || current.Id == id)
            {
                var updatedAt = TemplateSyncMerge.NextUpdatedAt(nowMillis, current.UpdatedAt);
                group[i] = current with { Order = i, UpdatedAt = updatedAt, BaseHash = null };
            }
        }

        ReplaceGroupItems(existing.Tag, group);
        Save();
        return true;
    }

    public int RenameTag(string? oldTag, string? newTag, long nowMillis)
    {
        var normOld = SanitizeTag(oldTag);
        var normNew = SanitizeTag(newTag);
        if (string.Equals(normOld, normNew, StringComparison.Ordinal))
            return 0;

        var sourceItems = GetGroupOrdered(normOld);
        if (sourceItems.Count == 0)
            return 0;

        var targetItems = GetGroupOrdered(normNew);
        var nextOrder = targetItems.Count;

        foreach (var item in sourceItems)
        {
            var updatedAt = TemplateSyncMerge.NextUpdatedAt(nowMillis, item.UpdatedAt);
            var moved = item with
            {
                Tag = normNew,
                Order = nextOrder++,
                UpdatedAt = updatedAt,
                BaseHash = null,
            };
            var idx = state.Templates.FindIndex(t => t.Id == item.Id);
            if (idx >= 0) state.Templates[idx] = moved;
        }

        RenumberGroup(normNew);
        Save();
        return sourceItems.Count;
    }

    public void ApplyMerged(IReadOnlyList<TemplateSyncItem> templates, IReadOnlyList<TemplateSyncTombstone> tombstones) =>
        ApplyMerged(templates, tombstones, []);

    public IReadOnlyList<TemplateSyncItem> ApplyMerged(
        IReadOnlyList<TemplateSyncItem> templates,
        IReadOnlyList<TemplateSyncTombstone> tombstones,
        IReadOnlyList<TemplateSyncItem> preservedLocal)
    {
        ArgumentNullException.ThrowIfNull(templates);
        ArgumentNullException.ThrowIfNull(tombstones);
        ArgumentNullException.ThrowIfNull(preservedLocal);
        if (templates.Count > SyncProtocol.MaxTemplates) throw new SyncProtocolException(SyncError.Limit);
        if (tombstones.Count > SyncProtocol.MaxTemplateTombstones) throw new SyncProtocolException(SyncError.Limit);

        var nextTemplates = new List<TemplateSyncItem>(templates.Count + preservedLocal.Count);
        var activeIds = new HashSet<Guid>();
        var activeTexts = new HashSet<string>(StringComparer.Ordinal);
        var untaggedNextOrder = 0;
        var nextOrderByTag = new Dictionary<string, int>(StringComparer.Ordinal);

        foreach (var item in templates)
        {
            var clean = item with
            {
                Title = SanitizeTitle(item.Title),
                Tag = SanitizeTag(item.Tag),
                BaseHash = null,
            };
            TemplateSyncMessageCodec.ValidateItem(clean, allowBaseHash: false);
            nextTemplates.Add(clean);
            activeIds.Add(clean.Id);
            activeTexts.Add(clean.Text);
            if (clean.Tag is null)
            {
                if (clean.Order >= untaggedNextOrder)
                    untaggedNextOrder = clean.Order + 1;
            }
            else
            {
                var current = nextOrderByTag.GetValueOrDefault(clean.Tag);
                if (clean.Order >= current)
                    nextOrderByTag[clean.Tag] = clean.Order + 1;
            }
        }

        if (preservedLocal.Count > 0)
        {
            foreach (var item in SortGroupItems(preservedLocal))
            {
                var cleanTitle = SanitizeTitle(item.Title);
                var cleanTag = SanitizeTag(item.Tag);
                if (activeIds.Contains(item.Id) || activeTexts.Contains(item.Text))
                    continue;
                if (nextTemplates.Count >= SyncProtocol.MaxTemplates)
                    throw new SyncProtocolException(SyncError.Limit);

                int order;
                if (cleanTag is null)
                {
                    order = untaggedNextOrder++;
                }
                else
                {
                    order = nextOrderByTag.GetValueOrDefault(cleanTag);
                    nextOrderByTag[cleanTag] = order + 1;
                }

                var clean = item with
                {
                    Title = cleanTitle,
                    Tag = cleanTag,
                    Order = order,
                    BaseHash = null,
                };
                TemplateSyncMessageCodec.ValidateItem(clean, allowBaseHash: false);
                nextTemplates.Add(clean);
                activeIds.Add(clean.Id);
                activeTexts.Add(clean.Text);
            }
        }

        var nextTombstones = new List<TemplateSyncTombstone>(tombstones.Count);
        foreach (var tomb in tombstones)
        {
            TemplateSyncMessageCodec.ValidateTombstone(tomb);
            if (activeIds.Contains(tomb.Id))
                continue;
            nextTombstones.Add(tomb);
        }

        state = new RepositoryState
        {
            Templates = nextTemplates,
            Tombstones = nextTombstones,
        };
        Save();
        return nextTemplates.ToArray();
    }

    public bool PruneTombstones(long nowMillis)
    {
        if (!PruneTombstonesInMemory(ClampTimestamp(nowMillis)))
            return false;
        Save();
        return true;
    }

    public void ClearTombstones()
    {
        if (state.Tombstones.Count == 0) return;
        state.Tombstones.Clear();
        Save();
    }

    public static TemplateSyncKind ClassifyKind(string text) =>
        HistoryText.IsLinkText(text) ? TemplateSyncKind.Url : TemplateSyncKind.Text;

    public static string? SanitizeTitle(string? title) =>
        TemplateSyncMerge.NormalizedTitle(StripControlCharacters(title));

    public static string? SanitizeTag(string? tag) =>
        TemplateSyncMerge.NormalizedTag(StripControlCharacters(tag));

    private static TemplateEditError ValidateWritableText(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return TemplateEditError.Empty;
        try
        {
            var bytes = StrictUtf8.GetByteCount(text);
            return bytes > SyncProtocol.MaxTemplateTextBytes ? TemplateEditError.TooLarge : TemplateEditError.None;
        }
        catch (EncoderFallbackException)
        {
            return TemplateEditError.InvalidText;
        }
    }

    private static string? StripControlCharacters(string? value)
    {
        if (value is null) return null;
        var sb = new StringBuilder(value.Length);
        for (var i = 0; i < value.Length; i++)
        {
            var c = value[i];
            if (char.IsHighSurrogate(c))
            {
                if (i + 1 < value.Length && char.IsLowSurrogate(value[i + 1]))
                {
                    sb.Append(c);
                    sb.Append(value[i + 1]);
                    i++;
                }
                continue;
            }
            if (char.IsLowSurrogate(c))
                continue;
            if (c is '\r' or '\n' or '\t' or '\u2028' or '\u2029')
                sb.Append(' ');
            else if (!char.IsControl(c))
                sb.Append(c);
        }
        return sb.ToString();
    }

    private static bool MatchesSearch(TemplateSyncItem item, string query) =>
        (!string.IsNullOrEmpty(item.Title) && item.Title.Contains(query, StringComparison.OrdinalIgnoreCase)) ||
        (!string.IsNullOrEmpty(item.Tag) && item.Tag.Contains(query, StringComparison.OrdinalIgnoreCase)) ||
        item.Text.Contains(query, StringComparison.OrdinalIgnoreCase);

    private List<TemplateSyncItem> GetGroupOrdered(string? tag) =>
        SortGroupItems(state.Templates.Where(t => string.Equals(t.Tag, tag, StringComparison.Ordinal)));

    private static List<TemplateSyncItem> SortGroupItems(IEnumerable<TemplateSyncItem> items) =>
        items
            .OrderBy(t => t.Order)
            .ThenBy(t => t.UpdatedAt)
            .ThenBy(t => t.Id.ToString("D").ToUpperInvariant(), StringComparer.Ordinal)
            .ToList();

    private void RenumberGroup(string? tag)
    {
        var group = GetGroupOrdered(tag);
        for (var i = 0; i < group.Count; i++)
        {
            if (group[i].Order != i)
                group[i] = group[i] with { Order = i };
        }
        ReplaceGroupItems(tag, group);
    }

    private void ReplaceGroupItems(string? tag, IReadOnlyList<TemplateSyncItem> orderedGroup)
    {
        state.Templates.RemoveAll(t => string.Equals(t.Tag, tag, StringComparison.Ordinal));
        state.Templates.AddRange(orderedGroup);
    }

    private bool PruneTombstonesInMemory(long nowMillis)
    {
        var before = state.Tombstones.Count;
        var kept = state.Tombstones
            .Where(t => nowMillis - t.DeletedAt <= SyncProtocol.TemplateTombstoneLifetimeMillis)
            .OrderBy(t => t.DeletedAt)
            .ThenBy(t => t.Id.ToString("D").ToUpperInvariant(), StringComparer.Ordinal)
            .ToList();

        if (kept.Count > SyncProtocol.MaxTemplateTombstones)
            kept.RemoveRange(0, kept.Count - SyncProtocol.MaxTemplateTombstones);

        var changed = kept.Count != before;
        if (!changed)
        {
            for (var i = 0; i < kept.Count; i++)
            {
                if (kept[i] != state.Tombstones[i])
                {
                    changed = true;
                    break;
                }
            }
        }
        if (changed)
            state.Tombstones = kept;
        return changed;
    }

    private RepositoryState LoadState()
    {
        if (!File.Exists(filePath))
            return new RepositoryState();

        try
        {
            var rawBytes = File.ReadAllBytes(filePath);
            ReadOnlySpan<byte> span = rawBytes;
            if (span is [0xEF, 0xBB, 0xBF, ..])
                span = span[3..];
            if (span.IsEmpty)
            {
                log?.Invoke("templates load failed reason=empty");
                return new RepositoryState();
            }

            using var doc = JsonDocument.Parse(span.ToArray(), new JsonDocumentOptions { MaxDepth = 16 });
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                log?.Invoke("templates load failed reason=root-type");
                return new RepositoryState();
            }

            if (!root.TryGetProperty("FormatVersion", out var versionEl) ||
                versionEl.ValueKind != JsonValueKind.Number ||
                !versionEl.TryGetInt32(out var version) ||
                version != CurrentFormatVersion)
            {
                log?.Invoke("templates load failed reason=format-version");
                return new RepositoryState();
            }

            if (!root.TryGetProperty("Templates", out var templatesEl) || templatesEl.ValueKind != JsonValueKind.Array ||
                !root.TryGetProperty("Tombstones", out var tombsEl) || tombsEl.ValueKind != JsonValueKind.Array)
            {
                log?.Invoke("templates load failed reason=missing-arrays");
                return new RepositoryState();
            }

            var skipped = 0;
            var seenIds = new HashSet<Guid>();
            var byText = new Dictionary<string, TemplateSyncItem>(StringComparer.Ordinal);

            foreach (var el in templatesEl.EnumerateArray())
            {
                if (!TryParseStoredItem(el, out var item))
                {
                    skipped++;
                    continue;
                }
                if (!seenIds.Add(item.Id))
                {
                    skipped++;
                    continue;
                }
                if (byText.TryGetValue(item.Text, out var existing))
                {
                    skipped++;
                    if (item.UpdatedAt > existing.UpdatedAt)
                        byText[item.Text] = item;
                    continue;
                }
                if (byText.Count >= SyncProtocol.MaxTemplates)
                {
                    skipped++;
                    continue;
                }
                byText[item.Text] = item;
            }

            var loadedTemplates = byText.Values.ToList();
            var loadedIds = loadedTemplates.Select(t => t.Id).ToHashSet();
            var loadedTombs = new List<TemplateSyncTombstone>();

            foreach (var el in tombsEl.EnumerateArray())
            {
                if (!TryParseStoredTombstone(el, out var tomb) || !loadedIds.Add(tomb.Id))
                {
                    skipped++;
                    continue;
                }
                loadedTombs.Add(tomb);
            }

            if (loadedTombs.Count > SyncProtocol.MaxTemplateTombstones)
            {
                skipped += loadedTombs.Count - SyncProtocol.MaxTemplateTombstones;
                loadedTombs = loadedTombs
                    .OrderBy(t => t.DeletedAt)
                    .ThenBy(t => t.Id.ToString("D").ToUpperInvariant(), StringComparer.Ordinal)
                    .TakeLast(SyncProtocol.MaxTemplateTombstones)
                    .ToList();
            }

            if (skipped > 0)
                log?.Invoke($"templates load skipped={skipped}");

            return new RepositoryState
            {
                Templates = loadedTemplates,
                Tombstones = loadedTombs,
            };
        }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException or NotSupportedException or FormatException or DecoderFallbackException)
        {
            log?.Invoke($"templates load failed error={ex.GetType().Name}");
            return new RepositoryState();
        }
    }

    private static bool TryParseStoredItem(JsonElement el, out TemplateSyncItem item)
    {
        item = default!;
        if (el.ValueKind != JsonValueKind.Object) return false;

        if (!el.TryGetProperty("Id", out var idEl) || idEl.ValueKind != JsonValueKind.String ||
            !Guid.TryParse(idEl.GetString(), out var id))
            return false;

        if (!el.TryGetProperty("Kind", out var kindEl) || kindEl.ValueKind != JsonValueKind.String)
            return false;
        TemplateSyncKind kind;
        var kindStr = kindEl.GetString();
        if (string.Equals(kindStr, "text", StringComparison.OrdinalIgnoreCase)) kind = TemplateSyncKind.Text;
        else if (string.Equals(kindStr, "url", StringComparison.OrdinalIgnoreCase)) kind = TemplateSyncKind.Url;
        else return false;

        if (!el.TryGetProperty("Text", out var textEl) || textEl.ValueKind != JsonValueKind.String)
            return false;
        var text = textEl.GetString()!;
        try
        {
            if (StrictUtf8.GetByteCount(text) > SyncProtocol.MaxTemplateTextBytes)
                return false;
        }
        catch (EncoderFallbackException) { return false; }

        string? title = null;
        if (el.TryGetProperty("Title", out var titleEl))
        {
            if (titleEl.ValueKind == JsonValueKind.String) title = SanitizeTitle(titleEl.GetString());
            else if (titleEl.ValueKind != JsonValueKind.Null) return false;
        }

        string? tag = null;
        if (el.TryGetProperty("Tag", out var tagEl))
        {
            if (tagEl.ValueKind == JsonValueKind.String) tag = SanitizeTag(tagEl.GetString());
            else if (tagEl.ValueKind != JsonValueKind.Null) return false;
        }

        if (!el.TryGetProperty("Order", out var orderEl) || orderEl.ValueKind != JsonValueKind.Number ||
            !orderEl.TryGetInt32(out var order) || order < 0)
            return false;

        if (!el.TryGetProperty("UpdatedAt", out var updatedEl) || updatedEl.ValueKind != JsonValueKind.Number ||
            !updatedEl.TryGetInt64(out var updatedAt) ||
            updatedAt < -SyncProtocol.MaxTimestamp || updatedAt > SyncProtocol.MaxTimestamp)
            return false;

        item = new TemplateSyncItem(id, kind, text, title, tag, order, updatedAt);
        return true;
    }

    private static bool TryParseStoredTombstone(JsonElement el, out TemplateSyncTombstone tombstone)
    {
        tombstone = default!;
        if (el.ValueKind != JsonValueKind.Object) return false;

        if (!el.TryGetProperty("Id", out var idEl) || idEl.ValueKind != JsonValueKind.String ||
            !Guid.TryParse(idEl.GetString(), out var id))
            return false;

        if (!el.TryGetProperty("DeletedAt", out var deletedEl) || deletedEl.ValueKind != JsonValueKind.Number ||
            !deletedEl.TryGetInt64(out var deletedAt) ||
            deletedAt < -SyncProtocol.MaxTimestamp || deletedAt > SyncProtocol.MaxTimestamp)
            return false;

        string? baseHash = null;
        if (el.TryGetProperty("BaseHash", out var hashEl))
        {
            if (hashEl.ValueKind == JsonValueKind.String)
            {
                var normalized = hashEl.GetString()!.ToLowerInvariant();
                if (IsLowerHex64(normalized))
                    baseHash = normalized;
            }
            else if (hashEl.ValueKind != JsonValueKind.Null)
            {
                return false;
            }
        }

        tombstone = new TemplateSyncTombstone(id, deletedAt, baseHash);
        return true;
    }

    private static bool IsLowerHex64(string? value) =>
        value is { Length: 64 } && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static long ClampTimestamp(long value) =>
        Math.Clamp(value, -SyncProtocol.MaxTimestamp, SyncProtocol.MaxTimestamp);

    private void Save()
    {
        try
        {
            var bytes = SerializeState(state);
            AtomicWrite(filePath, bytes);
            durable = bytes;
        }
        catch
        {
            state = DeserializeDurable(durable);
            throw;
        }
    }

    private static byte[] SerializeState(RepositoryState source)
    {
        var dto = new StoredState
        {
            FormatVersion = CurrentFormatVersion,
            Templates = source.Templates.Select(t => new StoredTemplate
            {
                Id = t.Id,
                Kind = t.Kind == TemplateSyncKind.Url ? "url" : "text",
                Text = t.Text,
                Title = t.Title,
                Tag = t.Tag,
                Order = t.Order,
                UpdatedAt = t.UpdatedAt,
            }).ToList(),
            Tombstones = source.Tombstones.Select(t => new StoredTombstone
            {
                Id = t.Id,
                DeletedAt = t.DeletedAt,
                BaseHash = t.BaseHash,
            }).ToList(),
        };
        return JsonSerializer.SerializeToUtf8Bytes(dto, JsonOptions);
    }

    private static RepositoryState DeserializeDurable(byte[] bytes)
    {
        var dto = JsonSerializer.Deserialize<StoredState>(bytes, JsonOptions) ?? new StoredState();
        return new RepositoryState
        {
            Templates = dto.Templates.Select(t => new TemplateSyncItem(
                t.Id,
                string.Equals(t.Kind, "url", StringComparison.OrdinalIgnoreCase) ? TemplateSyncKind.Url : TemplateSyncKind.Text,
                t.Text,
                t.Title,
                t.Tag,
                t.Order,
                t.UpdatedAt)).ToList(),
            Tombstones = dto.Tombstones.Select(t => new TemplateSyncTombstone(
                t.Id,
                t.DeletedAt,
                t.BaseHash)).ToList(),
        };
    }

    private static void AtomicWrite(string path, byte[] bytes)
    {
        var tempPath = path + ".tmp";
        try
        {
            using (var file = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                file.Write(bytes);
                file.Flush(true);
            }
            File.Move(tempPath, path, overwrite: true);
        }
        catch
        {
            try
            {
                if (File.Exists(tempPath)) File.Delete(tempPath);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
            throw;
        }
    }

    private sealed class NaturalTagComparer : IComparer<string>
    {
        public static readonly NaturalTagComparer Instance = new();
        private static readonly CompareInfo CompareInfo = CultureInfo.CurrentCulture.CompareInfo;

        public int Compare(string? x, string? y)
        {
            if (ReferenceEquals(x, y)) return 0;
            if (x is null) return -1;
            if (y is null) return 1;
            var cmp = CompareInfo.Compare(x, y, CompareOptions.IgnoreCase | CompareOptions.NumericOrdering);
            return cmp != 0 ? cmp : string.CompareOrdinal(x, y);
        }
    }
}
