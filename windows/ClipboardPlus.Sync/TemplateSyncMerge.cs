using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace ClipboardPlus.Sync;

public sealed record TemplateSyncState(
    IReadOnlyList<TemplateSyncItem> Templates,
    IReadOnlyList<TemplateSyncTombstone> Tombstones);

public sealed record TemplateSyncRemoteState(
    TemplateSyncState State,
    long? SentAtMillis = null);

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

public sealed record TemplateSyncMultiMergeResult(
    IReadOnlyList<TemplateSyncItem> Templates,
    IReadOnlyList<TemplateSyncTombstone> Tombstones,
    int ConflictCopyCount,
    int SubsumedDuplicateCount,
    TemplateSyncSideChanges PcChanges,
    IReadOnlyList<TemplateSyncSideChanges> RemoteChanges,
    IReadOnlyList<long?> RemoteClockSkewSeconds);

public sealed record TemplateSyncPreparedState(
    TemplateSyncState State,
    int ExcludedTemplateCount);

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

    public static string NormalizeLineEndings(string text)
    {
        SyncProtocol.Require(text is not null);
        if (!text.Contains('\r')) return text;
        var sb = new StringBuilder(text.Length);
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (c == '\r')
            {
                sb.Append('\n');
                if (i + 1 < text.Length && text[i + 1] == '\n') i++;
            }
            else
            {
                sb.Append(c);
            }
        }
        return sb.ToString();
    }

    public static string ContentHash(TemplateSyncItem item) =>
        ContentHash(item.Kind, item.Text, item.Title, item.Tag);

    public static string ContentHash(TemplateSyncKind kind, string text, string? title, string? tag)
    {
        SyncProtocol.Require(text is not null);
        var normText = NormalizeLineEndings(text);
        var normTitle = NormalizedTitle(title);
        var normTag = NormalizedTag(tag);
        var bytes = TemplateCanonicalJson.SerializeContentHashInput(kind, normText, normTitle, normTag);
        return Convert.ToHexStringLower(SHA256.HashData(bytes));
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

    private static readonly string PlaceholderBaseHash = new('0', 64);

    public static Guid DeterministicConflictId(Guid originalId, string loserContentHash, ISet<Guid> usedIds)
    {
        for (var counter = 0; ; counter++)
        {
            var candidate = ConflictUuid(originalId, loserContentHash, counter);
            if (usedIds.Add(candidate)) return candidate;
        }
    }

    private static Guid? ResolveConflictId(
        Guid originalId,
        string loserContentHash,
        ISet<Guid> activeIds,
        IReadOnlySet<Guid> tombstoneIds)
    {
        for (var counter = 0; ; counter++)
        {
            var candidate = ConflictUuid(originalId, loserContentHash, counter);
            // Suppress recreation if this conflict copy was already deleted (tombstone present).
            if (tombstoneIds.Contains(candidate)) return null;
            if (activeIds.Add(candidate)) return candidate;
        }
    }

    private static Guid ConflictUuid(Guid originalId, string loserContentHash, int counter)
    {
        Span<byte> uuid = stackalloc byte[16];
        var input = counter == 0
            ? $"clipboardplus-tpl-conflict-v1:{SyncProtocol.Id(originalId)}:{loserContentHash}"
            : $"clipboardplus-tpl-conflict-v1:{SyncProtocol.Id(originalId)}:{loserContentHash}:{counter}";
        var digest = SHA256.HashData(SyncProtocol.Utf8.GetBytes(input));
        digest.AsSpan(0, 16).CopyTo(uuid);
        uuid[6] = (byte)((uuid[6] & 0x0F) | 0x40);
        uuid[8] = (byte)((uuid[8] & 0x3F) | 0x80);
        return new Guid(uuid, bigEndian: true);
    }

    private sealed record NormalizedEntry(TemplateSyncItem Item, string Hash);
    private sealed record ConflictCandidate(Guid OriginalId, TemplateSyncItem Loser, string LoserHash);

    private readonly record struct PagePackerState(int FlushedPages, int FlushedTotalBytes, int CurrentPageBytes, bool CurrentHasItems)
    {
        public static PagePackerState Initial(int firstPageEmptyBytes) =>
            new(0, 0, firstPageEmptyBytes, false);

        public bool TryAddItem(int itemBytes, int continuationEmptyBytes, out PagePackerState next)
        {
            var commaBytes = CurrentHasItems ? 1 : 0;
            if (CurrentPageBytes + commaBytes + itemBytes <= SyncProtocol.MaxTemplatePageBodyBytes)
            {
                next = new PagePackerState(FlushedPages, FlushedTotalBytes, CurrentPageBytes + commaBytes + itemBytes, true);
                return true;
            }
            if (!CurrentHasItems || FlushedPages + 1 >= SyncProtocol.MaxTemplatePages)
            {
                next = default;
                return false;
            }
            var newTotal = FlushedTotalBytes + CurrentPageBytes;
            if (newTotal > SyncProtocol.MaxTemplateTotalBytes || continuationEmptyBytes + itemBytes > SyncProtocol.MaxTemplatePageBodyBytes)
            {
                next = default;
                return false;
            }
            next = new PagePackerState(FlushedPages + 1, newTotal, continuationEmptyBytes + itemBytes, true);
            return true;
        }

        public bool CanFinishWithTombstones(IReadOnlyList<int> tombstoneByteSizes, int continuationEmptyBytes)
        {
            var pages = FlushedPages;
            var totalBytes = FlushedTotalBytes;
            var currentBytes = CurrentPageBytes;
            var hasItems = CurrentHasItems;
            var hasTombstones = false;

            foreach (var tombBytes in tombstoneByteSizes)
            {
                var commaBytes = hasTombstones ? 1 : 0;
                if (currentBytes + commaBytes + tombBytes > SyncProtocol.MaxTemplatePageBodyBytes)
                {
                    if (!hasItems && !hasTombstones) return false;
                    if (pages + 1 >= SyncProtocol.MaxTemplatePages) return false;
                    totalBytes += currentBytes;
                    if (totalBytes > SyncProtocol.MaxTemplateTotalBytes) return false;
                    pages += 1;
                    currentBytes = continuationEmptyBytes;
                    hasItems = false;
                    hasTombstones = false;
                    commaBytes = 0;
                    if (currentBytes + tombBytes > SyncProtocol.MaxTemplatePageBodyBytes) return false;
                }
                hasTombstones = true;
                currentBytes += commaBytes + tombBytes;
            }

            return pages + 1 <= SyncProtocol.MaxTemplatePages &&
                   totalBytes + currentBytes <= SyncProtocol.MaxTemplateTotalBytes;
        }
    }

    public static TemplateSyncPreparedState PrepareSyncState(
        IReadOnlyList<TemplateSyncItem> templates,
        IReadOnlyList<TemplateSyncTombstone> tombstones,
        long nowMillis,
        long? sentAtMillis = null)
    {
        SyncProtocol.Require(templates is not null && tombstones is not null);
        SyncProtocol.Require(nowMillis is >= -SyncProtocol.MaxTimestamp and <= SyncProtocol.MaxTimestamp);
        var effectiveSentAt = sentAtMillis ?? nowMillis;
        SyncProtocol.Require(effectiveSentAt is >= -SyncProtocol.MaxTimestamp and <= SyncProtocol.MaxTimestamp);

        var firstPageEmptyBytes = TemplateCanonicalJson.MeasurePageUtf8Bytes(
            new TemplateSyncPage(1, effectiveSentAt, [], []),
            isFirstPage: true,
            includeItemBaseHash: true,
            maxBytes: SyncProtocol.MaxTemplatePageBodyBytes);
        var continuationEmptyBytes = TemplateCanonicalJson.MeasurePageUtf8Bytes(
            new TemplateSyncPage(null, null, [], []),
            isFirstPage: false,
            includeItemBaseHash: true,
            maxBytes: SyncProtocol.MaxTemplatePageBodyBytes);

        var inputTemplateIds = new HashSet<Guid>();
        foreach (var t in templates)
        {
            if (t is not null) inputTemplateIds.Add(t.Id);
        }

        var validTombs = new Dictionary<Guid, TemplateSyncTombstone>();
        foreach (var tomb in tombstones)
        {
            if (tomb is null) continue;
            if (inputTemplateIds.Contains(tomb.Id)) continue;
            if (tomb.DeletedAt is < -SyncProtocol.MaxTimestamp or > SyncProtocol.MaxTimestamp) continue;
            if (tomb.BaseHash is not null && !SyncProtocol.IsLowerHex64(tomb.BaseHash)) continue;
            if (IsExpiredTombstone(tomb.DeletedAt, nowMillis)) continue;
            validTombs[tomb.Id] = validTombs.TryGetValue(tomb.Id, out var existing)
                ? MergeTombstones(existing, tomb)
                : tomb;
        }

        var cappedTombstones = PruneAndSortTombstones(validTombs.Values, nowMillis);
        var tombByteSizes = new int[cappedTombstones.Count];
        for (var i = 0; i < cappedTombstones.Count; i++)
        {
            tombByteSizes[i] = TemplateCanonicalJson.MeasureTombstoneUtf8Bytes(
                cappedTombstones[i],
                maxBytes: SyncProtocol.MaxTemplatePageBodyBytes - continuationEmptyBytes);
        }

        var accepted = new List<TemplateSyncItem>();
        var seenItemIds = new HashSet<Guid>();
        var excluded = 0;
        var packer = PagePackerState.Initial(firstPageEmptyBytes);

        foreach (var raw in templates)
        {
            if (raw is null || !seenItemIds.Add(raw.Id))
            {
                excluded++;
                continue;
            }
            var normalized = NormalizeInputItem(raw);
            if (!TryMeasureSyncableItemBytes(normalized, firstPageEmptyBytes, out var itemBytes))
            {
                excluded++;
                continue;
            }
            if (accepted.Count >= SyncProtocol.MaxTemplates ||
                !packer.TryAddItem(itemBytes, continuationEmptyBytes, out var nextPacker) ||
                !nextPacker.CanFinishWithTombstones(tombByteSizes, continuationEmptyBytes))
            {
                excluded++;
                continue;
            }
            accepted.Add(normalized);
            packer = nextPacker;
        }

        return new TemplateSyncPreparedState(
            new TemplateSyncState(accepted, cappedTombstones),
            excluded);
    }

    private static bool TryMeasureSyncableItemBytes(TemplateSyncItem item, int firstPageEmptyBytes, out int itemBytes)
    {
        itemBytes = 0;
        if (item.Kind is not (TemplateSyncKind.Text or TemplateSyncKind.Url)) return false;
        if (item.Order is < 0 or > TemplateSyncMessageCodec.MaxOrder) return false;
        if (item.UpdatedAt is < -SyncProtocol.MaxTimestamp or > SyncProtocol.MaxTimestamp) return false;
        if (item.BaseHash is not null && !SyncProtocol.IsLowerHex64(item.BaseHash)) return false;

        try
        {
            TemplateSyncMessageCodec.ValidateItem(item, allowBaseHash: true);
            // Reserve space for a 64-hex baseHash so items selected by PC remain syncable after iOS computes baseHash.
            var sizingItem = item.BaseHash is not null ? item : item with { BaseHash = PlaceholderBaseHash };
            itemBytes = TemplateCanonicalJson.MeasureItemUtf8Bytes(
                sizingItem,
                includeBaseHash: true,
                maxBytes: SyncProtocol.MaxTemplatePageBodyBytes - firstPageEmptyBytes);
            return true;
        }
        catch (SyncProtocolException)
        {
            return false;
        }
    }

    private static bool FitsWithinSyncBudget(IReadOnlyList<TemplateSyncItem> templates, IReadOnlyList<TemplateSyncTombstone> tombstones)
    {
        var firstPageEmptyBytes = TemplateCanonicalJson.MeasurePageUtf8Bytes(
            new TemplateSyncPage(1, -SyncProtocol.MaxTimestamp, [], []),
            isFirstPage: true,
            includeItemBaseHash: true,
            maxBytes: SyncProtocol.MaxTemplatePageBodyBytes);
        var continuationEmptyBytes = TemplateCanonicalJson.MeasurePageUtf8Bytes(
            new TemplateSyncPage(null, null, [], []),
            isFirstPage: false,
            includeItemBaseHash: true,
            maxBytes: SyncProtocol.MaxTemplatePageBodyBytes);

        var packer = PagePackerState.Initial(firstPageEmptyBytes);
        foreach (var item in templates)
        {
            var sizingItem = item.BaseHash is not null ? item : item with { BaseHash = PlaceholderBaseHash };
            var itemBytes = TemplateCanonicalJson.MeasureItemUtf8Bytes(
                sizingItem,
                includeBaseHash: true,
                maxBytes: SyncProtocol.MaxTemplatePageBodyBytes - continuationEmptyBytes);
            if (!packer.TryAddItem(itemBytes, continuationEmptyBytes, out packer))
                return false;
        }

        var tombByteSizes = new int[tombstones.Count];
        for (var i = 0; i < tombstones.Count; i++)
        {
            tombByteSizes[i] = TemplateCanonicalJson.MeasureTombstoneUtf8Bytes(
                tombstones[i],
                maxBytes: SyncProtocol.MaxTemplatePageBodyBytes - continuationEmptyBytes);
        }
        return packer.CanFinishWithTombstones(tombByteSizes, continuationEmptyBytes);
    }

    public static TemplateSyncMergeResult Merge(
        TemplateSyncState pc,
        TemplateSyncState remote,
        long nowMillis,
        long? remoteSentAtMillis = null)
    {
        SyncProtocol.Require(remote is not null);
        var multi = MergeAll(pc, [new TemplateSyncRemoteState(remote, remoteSentAtMillis)], nowMillis);
        return new TemplateSyncMergeResult(
            multi.Templates,
            multi.Tombstones,
            multi.ConflictCopyCount,
            multi.SubsumedDuplicateCount,
            multi.PcChanges,
            multi.RemoteChanges[0],
            multi.RemoteClockSkewSeconds[0]);
    }

    public static TemplateSyncMultiMergeResult MergeAll(
        TemplateSyncState pc,
        IReadOnlyList<TemplateSyncRemoteState> remotes,
        long nowMillis)
    {
        SyncProtocol.Require(pc is not null && remotes is not null);
        SyncProtocol.Require(nowMillis is >= -SyncProtocol.MaxTimestamp and <= SyncProtocol.MaxTimestamp);

        var (pcItems, pcTombs) = IndexSide(pc, nowMillis, sentAtMillis: null, knownPcTombs: null);

        var remoteItemsList = new List<Dictionary<Guid, NormalizedEntry>>(remotes.Count);
        var remoteTombsList = new List<Dictionary<Guid, TemplateSyncTombstone>>(remotes.Count);
        var remoteClockSkews = new List<long?>(remotes.Count);

        var allIds = new HashSet<Guid>(pcItems.Keys);
        allIds.UnionWith(pcTombs.Keys);

        foreach (var remote in remotes)
        {
            SyncProtocol.Require(remote is not null && remote.State is not null);
            long? skew = remote.SentAtMillis is long sentAt ? ClockSkewSeconds(sentAt, nowMillis) : null;
            remoteClockSkews.Add(skew);
            var (rItems, rTombs) = IndexSide(remote.State, nowMillis, remote.SentAtMillis, pcTombs);
            remoteItemsList.Add(rItems);
            remoteTombsList.Add(rTombs);
            allIds.UnionWith(rItems.Keys);
            allIds.UnionWith(rTombs.Keys);
        }

        var survivingItems = new List<NormalizedEntry>();
        var survivingTombs = new Dictionary<Guid, TemplateSyncTombstone>();
        var conflictCandidates = new List<ConflictCandidate>();

        foreach (var id in allIds)
        {
            var activeEntries = new List<NormalizedEntry>();
            if (pcItems.TryGetValue(id, out var pcEntry))
                activeEntries.Add(pcEntry);
            foreach (var rItems in remoteItemsList)
            {
                if (rItems.TryGetValue(id, out var rEntry))
                    activeEntries.Add(rEntry);
            }

            pcTombs.TryGetValue(id, out var pcTomb);
            var tombs = new List<TemplateSyncTombstone>();
            if (pcTomb is not null)
                tombs.Add(pcTomb);
            foreach (var rTombs in remoteTombsList)
            {
                if (rTombs.TryGetValue(id, out var rTomb))
                    tombs.Add(rTomb);
            }

            if (tombs.Count > 0)
            {
                var pcHasEntry = pcItems.TryGetValue(id, out var pcEntryForCheck);
                var pcEntryKilledOrAbsent = !pcHasEntry || IsDirectlyKilledByTombstones(pcEntryForCheck!, pcTomb, tombs);
                var remainingActive = activeEntries
                    .Where(e => !IsKilledByTombstones(e, pcTomb, pcEntryKilledOrAbsent, tombs))
                    .ToList();
                if (remainingActive.Count == 0)
                {
                    var mergedTomb = tombs[0];
                    for (var i = 1; i < tombs.Count; i++)
                        mergedTomb = MergeTombstones(mergedTomb, tombs[i]);
                    survivingTombs[id] = mergedTomb;
                }
                else
                {
                    ResolveActiveEntries(remainingActive, survivingItems, conflictCandidates);
                }
            }
            else if (activeEntries.Count > 0)
            {
                ResolveActiveEntries(activeEntries, survivingItems, conflictCandidates);
            }
        }

        var (dedupedItems, subsumedCount) = DeduplicateSameText(survivingItems, survivingTombs, nowMillis);

        var activeIds = new HashSet<Guid>(dedupedItems.Select(x => x.Item.Id));
        var tombstoneIds = new HashSet<Guid>(survivingTombs.Keys);
        var activeTexts = new HashSet<string>(dedupedItems.Select(x => x.Item.Text), StringComparer.Ordinal);
        var conflictCopies = new List<TemplateSyncItem>();
        foreach (var candidate in conflictCandidates
            .OrderBy(c => c.Loser.UpdatedAt)
            .ThenBy(c => c.LoserHash, StringComparer.Ordinal)
            .ThenBy(c => SyncProtocol.Id(c.OriginalId), StringComparer.Ordinal))
        {
            if (activeTexts.Contains(candidate.Loser.Text)) continue;
            var newId = ResolveConflictId(candidate.OriginalId, candidate.LoserHash, activeIds, tombstoneIds);
            if (newId is null) continue;
            activeTexts.Add(candidate.Loser.Text);
            conflictCopies.Add(new TemplateSyncItem(
                newId.Value,
                candidate.Loser.Kind,
                candidate.Loser.Text,
                MakeConflictTitle(candidate.Loser.Title),
                null,
                TemplateSyncMessageCodec.MaxOrder,
                candidate.Loser.UpdatedAt,
                null));
        }

        SyncProtocol.Require(dedupedItems.Count + conflictCopies.Count <= SyncProtocol.MaxTemplates, SyncError.Limit);

        var finalTemplates = OrderAndRenumber(dedupedItems.Select(x => x.Item), conflictCopies);
        var finalTombstones = PruneAndSortTombstones(survivingTombs.Values, nowMillis);
        SyncProtocol.Require(FitsWithinSyncBudget(finalTemplates, finalTombstones), SyncError.Limit);

        var pcChanges = ComputeChanges(pcItems.Values.Select(x => x.Item), finalTemplates);
        var remoteChanges = new List<TemplateSyncSideChanges>(remoteItemsList.Count);
        foreach (var rItems in remoteItemsList)
            remoteChanges.Add(ComputeChanges(rItems.Values.Select(x => x.Item), finalTemplates));

        return new TemplateSyncMultiMergeResult(
            finalTemplates,
            finalTombstones,
            conflictCopies.Count,
            subsumedCount,
            pcChanges,
            remoteChanges,
            remoteClockSkews);
    }

    private static (Dictionary<Guid, NormalizedEntry> Items, Dictionary<Guid, TemplateSyncTombstone> Tombs) IndexSide(
        TemplateSyncState side,
        long nowMillis,
        long? sentAtMillis,
        IReadOnlyDictionary<Guid, TemplateSyncTombstone>? knownPcTombs)
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
            items[normalized.Id] = new NormalizedEntry(normalized, ContentHash(normalized));
        }

        var tombs = new Dictionary<Guid, TemplateSyncTombstone>();
        foreach (var tomb in side.Tombstones)
        {
            TemplateSyncMessageCodec.ValidateTombstone(tomb);
            SyncProtocol.Require(sideIds.Add(tomb.Id));
            if (sentAtMillis is long sentAt)
            {
                if (knownPcTombs is not null && knownPcTombs.TryGetValue(tomb.Id, out var existingPcTomb))
                {
                    // Already recorded on PC: preserve PC's deletedAt so resends never extend retention.
                    tombs[tomb.Id] = tomb with { DeletedAt = existingPcTomb.DeletedAt };
                    continue;
                }
                var adjustedRaw = tomb.DeletedAt + (nowMillis - sentAt);
                var clamped = Math.Clamp(adjustedRaw, -SyncProtocol.MaxTimestamp, SyncProtocol.MaxTimestamp);
                var adjusted = Math.Min(nowMillis, clamped);
                if (!IsExpiredTombstone(adjusted, nowMillis))
                    tombs[tomb.Id] = tomb with { DeletedAt = adjusted };
            }
            else if (!IsExpiredTombstone(tomb.DeletedAt, nowMillis))
            {
                tombs[tomb.Id] = tomb;
            }
        }
        return (items, tombs);
    }

    private static TemplateSyncItem NormalizeInputItem(TemplateSyncItem raw)
    {
        SyncProtocol.Require(raw is not null);
        var text = NormalizeLineEndings(raw.Text);
        var title = NormalizedTitle(raw.Title);
        var tag = NormalizedTag(raw.Tag);
        return raw with { Text = text, Title = title, Tag = tag };
    }

    private static bool IsExpiredTombstone(long deletedAt, long nowMillis) =>
        nowMillis - deletedAt > SyncProtocol.TemplateTombstoneLifetimeMillis;

    private static bool IsDirectlyKilledByTombstones(
        NormalizedEntry entry,
        TemplateSyncTombstone? pcTomb,
        List<TemplateSyncTombstone> allTombs)
    {
        foreach (var tomb in allTombs)
        {
            if (tomb.BaseHash is not null && tomb.BaseHash == entry.Hash)
                return true;
        }
        if (entry.Item.BaseHash is not null && entry.Item.BaseHash == entry.Hash)
        {
            if (pcTomb is not null) return true;
            foreach (var tomb in allTombs)
            {
                if (tomb.BaseHash is null) return true;
            }
        }
        return false;
    }

    private static bool IsKilledByTombstones(
        NormalizedEntry entry,
        TemplateSyncTombstone? pcTomb,
        bool pcEntryKilledOrAbsent,
        List<TemplateSyncTombstone> allTombs)
    {
        if (IsDirectlyKilledByTombstones(entry, pcTomb, allTombs))
            return true;
        if (entry.Item.BaseHash is not null && entry.Item.BaseHash == entry.Hash && pcEntryKilledOrAbsent)
            return true;
        return false;
    }

    private static void ResolveActiveEntries(
        List<NormalizedEntry> entries,
        List<NormalizedEntry> survivingItems,
        List<ConflictCandidate> conflictCandidates)
    {
        if (entries.Count == 1)
        {
            survivingItems.Add(new NormalizedEntry(entries[0].Item with { BaseHash = null }, entries[0].Hash));
            return;
        }

        var firstHash = entries[0].Hash;
        if (entries.All(e => e.Hash == firstHash))
        {
            survivingItems.Add(CombineMatchingEntries(entries));
            return;
        }

        var editedBaseHashes = new HashSet<string>(StringComparer.Ordinal);
        foreach (var e in entries)
        {
            if (e.Item.BaseHash is not null && e.Item.BaseHash != e.Hash)
                editedBaseHashes.Add(e.Item.BaseHash);
        }

        var edited = entries.Where(e =>
            e.Item.BaseHash is not null
                ? e.Item.BaseHash != e.Hash
                : !editedBaseHashes.Contains(e.Hash)).ToList();
        var pool = edited.Count > 0 ? edited : entries;

        var byHash = pool
            .GroupBy(e => e.Hash, StringComparer.Ordinal)
            .Select(g => CombineMatchingEntries(g))
            .ToList();

        if (byHash.Count == 1)
        {
            survivingItems.Add(CombineMatchingEntries(entries.Where(e => e.Hash == byHash[0].Hash)));
            return;
        }

        byHash.Sort((a, b) =>
        {
            var cmp = b.Item.UpdatedAt.CompareTo(a.Item.UpdatedAt);
            return cmp != 0 ? cmp : string.CompareOrdinal(a.Hash, b.Hash);
        });

        var winner = CombineMatchingEntries(entries.Where(e => e.Hash == byHash[0].Hash));
        survivingItems.Add(winner);
        for (var i = 1; i < byHash.Count; i++)
        {
            var loser = byHash[i];
            if (!string.Equals(winner.Item.Text, loser.Item.Text, StringComparison.Ordinal))
                conflictCandidates.Add(new ConflictCandidate(winner.Item.Id, loser.Item, loser.Hash));
        }
    }

    private static NormalizedEntry CombineMatchingEntries(IEnumerable<NormalizedEntry> entries)
    {
        NormalizedEntry? best = null;
        foreach (var e in entries)
        {
            if (best is null ||
                e.Item.UpdatedAt > best.Item.UpdatedAt ||
                (e.Item.UpdatedAt == best.Item.UpdatedAt && e.Item.Order < best.Item.Order))
            {
                best = e;
            }
        }
        return new NormalizedEntry(best!.Item with { BaseHash = null }, best.Hash);
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
            .Where(t => !IsExpiredTombstone(t.DeletedAt, nowMillis))
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
