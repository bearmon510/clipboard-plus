using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace ClipboardPlus.Sync;

public sealed record TemplateSyncState(
    IReadOnlyList<TemplateSyncItem> Templates,
    IReadOnlyList<TemplateSyncTombstone> Tombstones);

public sealed record TemplateSyncSideChanges(int Added, int Updated, int Deleted)
{
    public int Total => Added + Updated + Deleted;
}

public sealed record TemplateSyncMergeResult(
    IReadOnlyList<TemplateSyncItem> Templates,
    IReadOnlyList<TemplateSyncTombstone> Tombstones,
    int ConflictCopyCount,
    int SubsumedDuplicateCount,
    TemplateSyncSideChanges PcChanges,
    TemplateSyncSideChanges RemoteChanges,
    long? ClockSkewSeconds);

public static class TemplateSyncMerge
{
    public static string? NormalizedTitle(string? title) =>
        NormalizeLabel(title, SyncProtocol.MaxTemplateTitleCharacters, SyncProtocol.MaxTemplateTitleBytes);

    public static string? NormalizedTag(string? tag) =>
        NormalizeLabel(tag, SyncProtocol.MaxTemplateTagCharacters, SyncProtocol.MaxTemplateTagBytes);

    private static string? NormalizeLabel(string? value, int maxChars, int maxBytes)
    {
        if (value is null) return null;
        var trimmed = value.Trim();
        if (trimmed.Length == 0) return null;
        var capped = TruncateByGraphemesAndBytes(trimmed, maxChars, maxBytes).Trim();
        return capped.Length == 0 ? null : capped;
    }

    internal static string TruncateByGraphemesAndBytes(string value, int maxChars, int maxBytes)
    {
        if (value.Length == 0 || maxChars <= 0 || maxBytes <= 0) return "";
        var sb = new StringBuilder();
        var chars = 0;
        var bytes = 0;
        var enumerator = StringInfo.GetTextElementEnumerator(value);
        while (enumerator.MoveNext())
        {
            var elem = enumerator.GetTextElement();
            var elemBytes = SyncProtocol.Utf8.GetByteCount(elem);
            if (chars + 1 > maxChars || bytes + elemBytes > maxBytes) break;
            sb.Append(elem);
            chars++;
            bytes += elemBytes;
        }
        return sb.ToString();
    }

    public static string ContentHash(TemplateSyncItem item) =>
        ContentHash(item.Kind, item.Text, item.Title, item.Tag);

    public static string ContentHash(TemplateSyncKind kind, string text, string? title, string? tag)
    {
        SyncProtocol.Require(text is not null);
        var kindStr = kind == TemplateSyncKind.Url ? "url" : "text";
        var normTitle = NormalizedTitle(title);
        var normTag = NormalizedTag(tag);
        var json = new StringBuilder();
        json.Append('[');
        json.Append(TemplateCanonicalJson.SerializeString(kindStr));
        json.Append(',');
        json.Append(TemplateCanonicalJson.SerializeString(text));
        json.Append(',');
        json.Append(normTitle is null ? "null" : TemplateCanonicalJson.SerializeString(normTitle));
        json.Append(',');
        json.Append(normTag is null ? "null" : TemplateCanonicalJson.SerializeString(normTag));
        json.Append(']');
        var hash = SHA256.HashData(SyncProtocol.Utf8.GetBytes(json.ToString()));
        return Convert.ToHexStringLower(hash);
    }

    public static long NextUpdatedAt(long nowMillis, long? existingUpdatedAt)
    {
        var clampedNow = Math.Clamp(nowMillis, -SyncProtocol.MaxTimestamp, SyncProtocol.MaxTimestamp);
        if (existingUpdatedAt is not long prev) return clampedNow;
        if (prev > clampedNow && prev - clampedNow > SyncProtocol.TemplateFutureTimestampCapMillis)
            return clampedNow;
        var bumped = prev >= SyncProtocol.MaxTimestamp ? SyncProtocol.MaxTimestamp : prev + 1;
        return Math.Clamp(Math.Max(clampedNow, bumped), -SyncProtocol.MaxTimestamp, SyncProtocol.MaxTimestamp);
    }

    public static long? ClockSkewSeconds(long remoteSentAtMillis, long nowMillis)
    {
        SyncProtocol.Require(remoteSentAtMillis is >= -SyncProtocol.MaxTimestamp and <= SyncProtocol.MaxTimestamp);
        SyncProtocol.Require(nowMillis is >= -SyncProtocol.MaxTimestamp and <= SyncProtocol.MaxTimestamp);
        var diff = Math.Abs(remoteSentAtMillis - nowMillis);
        return diff >= SyncProtocol.TemplateClockSkewWarningMillis ? diff / 1000 : null;
    }

    public static string MakeConflictTitle(string? originalTitle)
    {
        var norm = NormalizedTitle(originalTitle);
        if (norm is null) return "別の端末の編集";
        const string suffix = "（別の端末の編集）";
        var suffixChars = TemplateSyncMessageCodec.CountGraphemeClusters(suffix);
        var suffixBytes = SyncProtocol.Utf8.GetByteCount(suffix);
        var prefix = TruncateByGraphemesAndBytes(
            norm,
            SyncProtocol.MaxTemplateTitleCharacters - suffixChars,
            SyncProtocol.MaxTemplateTitleBytes - suffixBytes).TrimEnd();
        return prefix + suffix;
    }

    public static Guid DeterministicConflictId(Guid originalId, string loserContentHash, ISet<Guid> usedIds)
    {
        Span<byte> uuid = stackalloc byte[16];
        for (var counter = 0; ; counter++)
        {
            var input = counter == 0
                ? $"clipboardplus-tpl-conflict-v1:{SyncProtocol.Id(originalId)}:{loserContentHash}"
                : $"clipboardplus-tpl-conflict-v1:{SyncProtocol.Id(originalId)}:{loserContentHash}:{counter}";
            var digest = SHA256.HashData(SyncProtocol.Utf8.GetBytes(input));
            digest.AsSpan(0, 16).CopyTo(uuid);
            uuid[6] = (byte)((uuid[6] & 0x0F) | 0x40);
            uuid[8] = (byte)((uuid[8] & 0x3F) | 0x80);
            var candidate = new Guid(uuid, bigEndian: true);
            if (usedIds.Add(candidate)) return candidate;
        }
    }

    private sealed record NormalizedEntry(TemplateSyncItem Item, string Hash);
    private sealed record ConflictCandidate(Guid OriginalId, TemplateSyncItem Loser, string LoserHash);

    public static TemplateSyncMergeResult Merge(
        TemplateSyncState pc,
        TemplateSyncState remote,
        long nowMillis,
        long? remoteSentAtMillis = null)
    {
        SyncProtocol.Require(pc is not null && remote is not null);
        SyncProtocol.Require(nowMillis is >= -SyncProtocol.MaxTimestamp and <= SyncProtocol.MaxTimestamp);
        long? clockSkew = remoteSentAtMillis is long sentAt ? ClockSkewSeconds(sentAt, nowMillis) : null;

        var usedIds = new HashSet<Guid>();
        var (pcItems, pcTombs) = IndexSide(pc, nowMillis, usedIds);
        var (remoteItems, remoteTombs) = IndexSide(remote, nowMillis, usedIds);

        var allIds = new HashSet<Guid>(pcItems.Keys);
        allIds.UnionWith(pcTombs.Keys);
        allIds.UnionWith(remoteItems.Keys);
        allIds.UnionWith(remoteTombs.Keys);

        var survivingItems = new List<NormalizedEntry>();
        var survivingTombs = new Dictionary<Guid, TemplateSyncTombstone>();
        var conflictCandidates = new List<ConflictCandidate>();

        foreach (var id in allIds)
        {
            pcItems.TryGetValue(id, out var pcEntry);
            remoteItems.TryGetValue(id, out var remoteEntry);
            pcTombs.TryGetValue(id, out var pcTomb);
            remoteTombs.TryGetValue(id, out var remoteTomb);

            if (pcEntry is not null && remoteEntry is not null)
            {
                ResolveBothActive(pcEntry, remoteEntry, survivingItems, conflictCandidates);
            }
            else if (pcEntry is not null && remoteTomb is not null)
            {
                ResolveActiveVsTombstone(pcEntry, remoteTomb, survivingItems, survivingTombs);
            }
            else if (remoteEntry is not null && pcTomb is not null)
            {
                ResolveActiveVsTombstone(remoteEntry, pcTomb, survivingItems, survivingTombs);
            }
            else if (pcEntry is not null)
            {
                survivingItems.Add(pcEntry);
            }
            else if (remoteEntry is not null)
            {
                survivingItems.Add(remoteEntry);
            }
            else if (pcTomb is not null && remoteTomb is not null)
            {
                survivingTombs[id] = MergeTombstones(pcTomb, remoteTomb);
            }
            else if (pcTomb is not null)
            {
                survivingTombs[id] = pcTomb;
            }
            else if (remoteTomb is not null)
            {
                survivingTombs[id] = remoteTomb;
            }
        }

        var (dedupedItems, subsumedCount) = DeduplicateSameText(survivingItems, survivingTombs, nowMillis);

        var activeTexts = new HashSet<string>(dedupedItems.Select(x => x.Item.Text), StringComparer.Ordinal);
        var conflictCopies = new List<TemplateSyncItem>();
        foreach (var candidate in conflictCandidates.OrderBy(c => c.Loser.UpdatedAt).ThenBy(c => c.LoserHash, StringComparer.Ordinal).ThenBy(c => SyncProtocol.Id(c.OriginalId), StringComparer.Ordinal))
        {
            if (!activeTexts.Add(candidate.Loser.Text)) continue;
            var newId = DeterministicConflictId(candidate.OriginalId, candidate.LoserHash, usedIds);
            conflictCopies.Add(new TemplateSyncItem(
                newId,
                candidate.Loser.Kind,
                candidate.Loser.Text,
                MakeConflictTitle(candidate.Loser.Title),
                null,
                int.MaxValue,
                candidate.Loser.UpdatedAt,
                null));
        }

        SyncProtocol.Require(dedupedItems.Count + conflictCopies.Count <= SyncProtocol.MaxTemplates, SyncError.Limit);

        var finalTemplates = OrderAndRenumber(dedupedItems.Select(x => x.Item), conflictCopies);
        var finalTombstones = PruneAndSortTombstones(survivingTombs.Values, nowMillis);

        var pcChanges = ComputeChanges(pcItems.Values.Select(x => x.Item), finalTemplates);
        var remoteChanges = ComputeChanges(remoteItems.Values.Select(x => x.Item), finalTemplates);

        return new TemplateSyncMergeResult(
            finalTemplates,
            finalTombstones,
            conflictCopies.Count,
            subsumedCount,
            pcChanges,
            remoteChanges,
            clockSkew);
    }

    private static (Dictionary<Guid, NormalizedEntry> Items, Dictionary<Guid, TemplateSyncTombstone> Tombs) IndexSide(
        TemplateSyncState side, long nowMillis, HashSet<Guid> usedIds)
    {
        SyncProtocol.Require(side.Templates is not null && side.Tombstones is not null);
        SyncProtocol.Require(side.Templates.Count <= SyncProtocol.MaxTemplates, SyncError.Limit);
        var sideIds = new HashSet<Guid>();
        var items = new Dictionary<Guid, NormalizedEntry>(side.Templates.Count);
        foreach (var raw in side.Templates)
        {
            var normalized = NormalizeInputItem(raw);
            TemplateSyncMessageCodec.ValidateItem(normalized, allowBaseHash: true);
            SyncProtocol.Require(sideIds.Add(normalized.Id));
            usedIds.Add(normalized.Id);
            items[normalized.Id] = new NormalizedEntry(normalized, ContentHash(normalized));
        }

        var tombs = new Dictionary<Guid, TemplateSyncTombstone>();
        foreach (var tomb in side.Tombstones)
        {
            TemplateSyncMessageCodec.ValidateTombstone(tomb);
            SyncProtocol.Require(sideIds.Add(tomb.Id));
            usedIds.Add(tomb.Id);
            if (!IsExpiredTombstone(tomb, nowMillis))
                tombs[tomb.Id] = tomb;
        }
        return (items, tombs);
    }

    private static TemplateSyncItem NormalizeInputItem(TemplateSyncItem raw)
    {
        SyncProtocol.Require(raw is not null);
        var title = NormalizedTitle(raw.Title);
        var tag = NormalizedTag(raw.Tag);
        return raw with { Title = title, Tag = tag };
    }

    private static bool IsExpiredTombstone(TemplateSyncTombstone tomb, long nowMillis) =>
        nowMillis - tomb.DeletedAt > SyncProtocol.TemplateTombstoneLifetimeMillis;

    private static void ResolveBothActive(
        NormalizedEntry pc,
        NormalizedEntry remote,
        List<NormalizedEntry> survivingItems,
        List<ConflictCandidate> conflictCandidates)
    {
        if (pc.Hash == remote.Hash)
        {
            var order = remote.Item.UpdatedAt > pc.Item.UpdatedAt
                ? remote.Item.Order
                : pc.Item.UpdatedAt > remote.Item.UpdatedAt
                    ? pc.Item.Order
                    : Math.Min(pc.Item.Order, remote.Item.Order);
            var updatedAt = Math.Max(pc.Item.UpdatedAt, remote.Item.UpdatedAt);
            var chosen = pc.Item with { Order = order, UpdatedAt = updatedAt, BaseHash = null };
            survivingItems.Add(new NormalizedEntry(chosen, pc.Hash));
            return;
        }

        var remoteUnedited = remote.Item.BaseHash is not null && remote.Item.BaseHash == remote.Hash;
        var pcUnedited = remote.Item.BaseHash is not null && remote.Item.BaseHash == pc.Hash;

        if (remoteUnedited && !pcUnedited)
        {
            survivingItems.Add(new NormalizedEntry(pc.Item with { BaseHash = null }, pc.Hash));
            return;
        }
        if (pcUnedited && !remoteUnedited)
        {
            survivingItems.Add(new NormalizedEntry(remote.Item with { BaseHash = null }, remote.Hash));
            return;
        }

        NormalizedEntry winner, loser;
        if (pc.Item.UpdatedAt > remote.Item.UpdatedAt)
        {
            winner = pc; loser = remote;
        }
        else if (remote.Item.UpdatedAt > pc.Item.UpdatedAt)
        {
            winner = remote; loser = pc;
        }
        else if (string.CompareOrdinal(pc.Hash, remote.Hash) <= 0)
        {
            winner = pc; loser = remote;
        }
        else
        {
            winner = remote; loser = pc;
        }

        survivingItems.Add(new NormalizedEntry(winner.Item with { BaseHash = null }, winner.Hash));
        if (!string.Equals(winner.Item.Text, loser.Item.Text, StringComparison.Ordinal))
        {
            conflictCandidates.Add(new ConflictCandidate(winner.Item.Id, loser.Item with { BaseHash = null }, loser.Hash));
        }
    }

    private static void ResolveActiveVsTombstone(
        NormalizedEntry survivor,
        TemplateSyncTombstone tomb,
        List<NormalizedEntry> survivingItems,
        Dictionary<Guid, TemplateSyncTombstone> survivingTombs)
    {
        var survivorUnedited =
            (survivor.Item.BaseHash is not null && survivor.Item.BaseHash == survivor.Hash) ||
            (tomb.BaseHash is not null && tomb.BaseHash == survivor.Hash);
        if (survivorUnedited)
            survivingTombs[tomb.Id] = tomb with { BaseHash = tomb.BaseHash ?? survivor.Hash };
        else
            survivingItems.Add(new NormalizedEntry(survivor.Item with { BaseHash = null }, survivor.Hash));
    }

    private static TemplateSyncTombstone MergeTombstones(TemplateSyncTombstone a, TemplateSyncTombstone b)
    {
        if (a.DeletedAt > b.DeletedAt) return a with { BaseHash = a.BaseHash ?? b.BaseHash };
        if (b.DeletedAt > a.DeletedAt) return b with { BaseHash = b.BaseHash ?? a.BaseHash };
        var hash = a.BaseHash is null ? b.BaseHash
            : b.BaseHash is null ? a.BaseHash
            : string.CompareOrdinal(a.BaseHash, b.BaseHash) <= 0 ? a.BaseHash : b.BaseHash;
        return new TemplateSyncTombstone(a.Id, a.DeletedAt, hash);
    }

    private static (List<NormalizedEntry> Items, int SubsumedCount) DeduplicateSameText(
        List<NormalizedEntry> items,
        Dictionary<Guid, TemplateSyncTombstone> tombs,
        long nowMillis)
    {
        var groups = items.GroupBy(e => e.Item.Text, StringComparer.Ordinal);
        var result = new List<NormalizedEntry>();
        var subsumed = 0;
        foreach (var group in groups)
        {
            var ordered = group
                .OrderByDescending(e => e.Item.UpdatedAt)
                .ThenBy(e => SyncProtocol.Id(e.Item.Id), StringComparer.Ordinal)
                .ToArray();
            var primary = ordered[0].Item;
            var title = primary.Title;
            var tag = primary.Tag;
            for (var i = 1; i < ordered.Length; i++)
            {
                var other = ordered[i];
                if (title is null && other.Item.Title is not null) title = other.Item.Title;
                if (tag is null && other.Item.Tag is not null) tag = other.Item.Tag;
                var tomb = new TemplateSyncTombstone(other.Item.Id, nowMillis, other.Hash);
                tombs[tomb.Id] = tombs.TryGetValue(tomb.Id, out var existing) ? MergeTombstones(existing, tomb) : tomb;
                subsumed++;
            }
            var merged = primary with { Title = title, Tag = tag, BaseHash = null };
            result.Add(new NormalizedEntry(merged, ContentHash(merged)));
        }
        return (result, subsumed);
    }

    private static IReadOnlyList<TemplateSyncItem> OrderAndRenumber(
        IEnumerable<TemplateSyncItem> normalItems,
        IReadOnlyList<TemplateSyncItem> conflictCopies)
    {
        var byTag = new Dictionary<string, List<(TemplateSyncItem Item, bool IsConflict)>>(StringComparer.Ordinal);
        var untagged = new List<(TemplateSyncItem Item, bool IsConflict)>();

        foreach (var item in normalItems)
        {
            if (item.Tag is null) untagged.Add((item, false));
            else
            {
                if (!byTag.TryGetValue(item.Tag, out var list)) byTag[item.Tag] = list = [];
                list.Add((item, false));
            }
        }
        foreach (var copy in conflictCopies)
            untagged.Add((copy, true));

        var result = new List<TemplateSyncItem>();
        foreach (var tag in byTag.Keys.OrderBy(k => k, UnicodeScalarComparer.Instance))
            AppendTagGroup(byTag[tag], result);
        AppendTagGroup(untagged, result);
        return result;
    }

    private static void AppendTagGroup(List<(TemplateSyncItem Item, bool IsConflict)> group, List<TemplateSyncItem> output)
    {
        var sorted = group
            .OrderBy(x => x.IsConflict ? 1 : 0)
            .ThenBy(x => x.Item.Order)
            .ThenBy(x => x.Item.UpdatedAt)
            .ThenBy(x => SyncProtocol.Id(x.Item.Id), StringComparer.Ordinal);
        var order = 0;
        foreach (var entry in sorted)
            output.Add(entry.Item with { Order = order++, BaseHash = null });
    }

    private static IReadOnlyList<TemplateSyncTombstone> PruneAndSortTombstones(
        IEnumerable<TemplateSyncTombstone> tombs, long nowMillis)
    {
        var sorted = tombs
            .Where(t => !IsExpiredTombstone(t, nowMillis))
            .OrderBy(t => t.DeletedAt)
            .ThenBy(t => SyncProtocol.Id(t.Id), StringComparer.Ordinal)
            .ToList();
        if (sorted.Count > SyncProtocol.MaxTemplateTombstones)
            sorted.RemoveRange(0, sorted.Count - SyncProtocol.MaxTemplateTombstones);
        return sorted;
    }

    private static TemplateSyncSideChanges ComputeChanges(
        IEnumerable<TemplateSyncItem> before,
        IReadOnlyList<TemplateSyncItem> after)
    {
        var beforeById = before.ToDictionary(i => i.Id);
        var afterById = after.ToDictionary(i => i.Id);
        var added = 0;
        var updated = 0;
        var deleted = 0;

        foreach (var (id, afterItem) in afterById)
        {
            if (!beforeById.TryGetValue(id, out var beforeItem))
            {
                added++;
            }
            else if (beforeItem.Kind != afterItem.Kind ||
                     !string.Equals(beforeItem.Text, afterItem.Text, StringComparison.Ordinal) ||
                     !string.Equals(beforeItem.Title, afterItem.Title, StringComparison.Ordinal) ||
                     !string.Equals(beforeItem.Tag, afterItem.Tag, StringComparison.Ordinal) ||
                     beforeItem.Order != afterItem.Order)
            {
                updated++;
            }
        }
        foreach (var id in beforeById.Keys)
        {
            if (!afterById.ContainsKey(id)) deleted++;
        }
        return new TemplateSyncSideChanges(added, updated, deleted);
    }

    private sealed class UnicodeScalarComparer : IComparer<string>
    {
        public static readonly UnicodeScalarComparer Instance = new();

        public int Compare(string? x, string? y)
        {
            if (ReferenceEquals(x, y)) return 0;
            if (x is null) return -1;
            if (y is null) return 1;
            var ex = x.EnumerateRunes();
            var ey = y.EnumerateRunes();
            while (true)
            {
                var hasX = ex.MoveNext();
                var hasY = ey.MoveNext();
                if (!hasX && !hasY) return 0;
                if (!hasX) return -1;
                if (!hasY) return 1;
                var cmp = ex.Current.Value.CompareTo(ey.Current.Value);
                if (cmp != 0) return cmp;
            }
        }
    }
}
