using System.Buffers.Binary;
using System.Text;
using ClipboardPlus.Sync;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class TemplateSyncTests
{
    private static void Error(SyncError expected, Action action) =>
        Assert.Equal(expected, Assert.Throws<SyncProtocolException>(action).Code);

    private static byte[] Plain(string header, byte[]? body = null)
    {
        var h = Encoding.UTF8.GetBytes(header);
        var b = body ?? [];
        var result = new byte[2 + h.Length + b.Length];
        BinaryPrimitives.WriteUInt16BigEndian(result, (ushort)h.Length);
        h.CopyTo(result, 2);
        b.CopyTo(result, 2 + h.Length);
        return result;
    }

    [Fact]
    public void SplitPagesAndAssemblerRoundtripAcross256KiBPageBoundaries()
    {
        var op = Guid.NewGuid();
        var items = Enumerable.Range(0, 10).Select(i => new TemplateSyncItem(
            Guid.NewGuid(),
            i % 2 == 0 ? TemplateSyncKind.Text : TemplateSyncKind.Url,
            (i % 2 == 0 ? "本文" : "https://example.com/") + new string((char)('a' + i), 60_000),
            $"題名{i}",
            i < 5 ? "仕事" : null,
            i % 5,
            1_794_873_600_000 + i,
            new string('a', 64))).ToArray();
        var tombs = Enumerable.Range(0, 10).Select(i =>
            new TemplateSyncTombstone(Guid.NewGuid(), 1_794_873_500_000 + i, new string('b', 64))).ToArray();

        var snapshot = new TemplateSyncSnapshot(1_794_873_600_500, items, tombs);
        var pages = TemplateSyncMessageCodec.SplitPages(op, snapshot, isState: false);
        Assert.True(pages.Count >= 3);

        var assembler = new TemplateSyncPageAssembler(expectedOp: op, expectedIsState: false);
        TemplateSyncSnapshot? reassembled = null;
        for (var i = 0; i < pages.Count; i++)
        {
            var encoded = TemplateSyncMessageCodec.Encode(pages[i]);
            var decoded = Assert.IsType<TemplateSyncPush>(TemplateSyncMessageCodec.Decode(encoded));
            Assert.Equal(i, decoded.Part);
            Assert.Equal(pages.Count, decoded.Total);
            reassembled = assembler.Append(decoded);
            if (i < pages.Count - 1) Assert.Null(reassembled);
        }
        Assert.NotNull(reassembled);
        Assert.Equal(snapshot.SentAt, reassembled!.SentAt);
        Assert.Equal(items, reassembled.Templates);
        Assert.Equal(tombs, reassembled.Tombstones);
        assembler.Finish();
        Error(SyncError.State, () => assembler.Append(pages[0]));
    }

    [Fact]
    public void EmptySnapshotSerializesToSinglePageAndAssemblerRejectsBadSequence()
    {
        var op = Guid.NewGuid();
        var empty = new TemplateSyncSnapshot(12345, [], []);
        var pages = TemplateSyncMessageCodec.SplitPages(op, empty, isState: true);
        var single = Assert.IsType<TemplateSyncStateMessage>(Assert.Single(pages));
        Assert.Equal(0, single.Part);
        Assert.Equal(1, single.Total);

        var roundtrip = Assert.IsType<TemplateSyncStateMessage>(TemplateSyncMessageCodec.Decode(TemplateSyncMessageCodec.Encode(single)));
        Assert.Equal(12345, roundtrip.Page.SentAt);
        Assert.Empty(roundtrip.Page.Templates);
        Assert.Empty(roundtrip.Page.Tombstones);

        // Assembler rejections invalidate state permanently.
        var badStart = new TemplateSyncPageAssembler();
        var p1of2 = new TemplateSyncPush(op, 1, 2, new TemplateSyncPage(null, null, [], []));
        Error(SyncError.State, () => badStart.Append(p1of2));
        Error(SyncError.State, () => badStart.Append(new TemplateSyncPush(op, 0, 1, new TemplateSyncPage(1, 0, [], []))));

        var wrongOp = new TemplateSyncPageAssembler(expectedOp: Guid.NewGuid());
        Error(SyncError.State, () => wrongOp.Append(new TemplateSyncPush(op, 0, 1, new TemplateSyncPage(1, 0, [], []))));

        var incomplete = new TemplateSyncPageAssembler();
        Assert.Null(incomplete.Append(new TemplateSyncPush(op, 0, 2, new TemplateSyncPage(1, 0, [], []))));
        Assert.True(incomplete.HasPartialSnapshot);
        Error(SyncError.State, () => incomplete.Finish());

        var dupAcrossPages = new TemplateSyncPageAssembler();
        var dupId = Guid.NewGuid();
        var item = new TemplateSyncItem(dupId, TemplateSyncKind.Text, "x", null, null, 0, 1);
        Assert.Null(dupAcrossPages.Append(new TemplateSyncPush(op, 0, 2, new TemplateSyncPage(1, 0, [item], []))));
        Error(SyncError.Format, () => dupAcrossPages.Append(new TemplateSyncPush(op, 1, 2, new TemplateSyncPage(null, null, [item with { Text = "y" }], []))));

        var pullRejected = new TemplateSyncPageAssembler();
        Error(SyncError.State, () => pullRejected.Append(new TemplateSyncPull(op)));
    }

    [Fact]
    public void StrictJsonRejectsMalformedHeadersAndBodiesAndAllowsGraphemeAndZwjLimits()
    {
        const string op = "22222222-3333-4444-8555-666666666666";
        const string id = "44444444-5555-4666-8777-888888888881";

        // Header edge cases
        Error(SyncError.Format, () => TemplateSyncMessageCodec.Decode(Plain($"{{\"t\":\"tpl_pull\",\"op\":\"{op}\",}}")));
        Error(SyncError.Format, () => TemplateSyncMessageCodec.Decode(Plain($"{{\"t\":\"tpl_pull\",\"op\":\"{op}\",\"\\u0074\":\"tpl_pull\"}}")));
        Error(SyncError.Format, () => TemplateSyncMessageCodec.Decode(Plain($"{{\"t\":\"tpl_ack\",\"op\":\"{op}\",\"extra\":1}}")));
        Error(SyncError.Format, () => TemplateSyncMessageCodec.Decode(Plain($"{{\"t\":\"tpl_push\",\"op\":\"{op}\",\"part\":0,\"total\":1.0}}", Encoding.UTF8.GetBytes("{}"))));

        // Body JSON edge cases
        var validHeader = $"{{\"t\":\"tpl_push\",\"op\":\"{op}\",\"part\":0,\"total\":1}}";
        foreach (var badBody in new[]
        {
            """{"v":1,"sentAt":1,"templates":[],"tombstones":[],}""",
            """{"v":1,"sentAt":1,"templates":[],"tombstones":[]} trailing""",
            """{"v":1,"sentAt":1.0,"templates":[],"tombstones":[]}""",
            """{"v":1,"sentAt":1e3,"templates":[],"tombstones":[]}""",
            """{"v":true,"sentAt":1,"templates":[],"tombstones":[]}""",
            """{"v":1,"sentAt":1,"templates":[],"templates":[],"tombstones":[]}""",
            $$$"""{"v":1,"sentAt":1,"templates":[{"id":"{{{id}}}","kind":"text","text":"a","title":null,"order":0,"updatedAt":1}],"tombstones":[]}""",
            $$$"""{"v":1,"sentAt":1,"templates":[{"id":"{{{id}}}","kind":"text","text":"a","title":"x\u2028y","order":0,"updatedAt":1}],"tombstones":[]}""",
            $$$"""{"v":1,"sentAt":1,"templates":[{"id":"{{{id}}}","kind":"text","text":"\uD800","order":0,"updatedAt":1}],"tombstones":[]}""",
        })
        {
            Error(SyncError.Format, () => TemplateSyncMessageCodec.Decode(Plain(validHeader, Encoding.UTF8.GetBytes(badBody))));
        }

        // Invalid UTF-8 bytes in body
        Error(SyncError.Format, () => TemplateSyncMessageCodec.Decode(Plain(validHeader, [0xC0, 0xAF])));

        // Grapheme clusters: 100 ZWJ clusters would exceed 400 bytes, while 16 * 25 = 400 bytes & 16 <= 100 passes!
        var title400 = string.Concat(Enumerable.Repeat("👨‍👩‍👧‍👦", 16));
        Assert.Equal(16, TemplateSyncMessageCodec.CountGraphemeClusters(title400));
        Assert.Equal(400, Encoding.UTF8.GetByteCount(title400));
        var title100 = new string('あ', 100);
        var tag30 = new string('あ', 30);
        var tag120 = string.Concat(Enumerable.Repeat("😀", 30)); // 30 * 4 = 120 bytes
        foreach (var (title, tag) in new[] { (title400, tag120), (title100, tag30) })
        {
            var msg = new TemplateSyncPush(Guid.Parse(op), 0, 1, new TemplateSyncPage(1, 0, [
                new TemplateSyncItem(Guid.Parse(id), TemplateSyncKind.Text, "ok", title, tag, 0, 1)
            ], []));
            var roundtrip = Assert.IsType<TemplateSyncPush>(TemplateSyncMessageCodec.Decode(TemplateSyncMessageCodec.Encode(msg)));
            Assert.Equal(title, roundtrip.Page.Templates[0].Title);
            Assert.Equal(tag, roundtrip.Page.Templates[0].Tag);
        }

        // Single-item JSON exceeding 256 KiB page body due to escaping (65,536 control bytes -> 393,216 bytes escaped)
        var heavyControlItem = new TemplateSyncItem(Guid.Parse(id), TemplateSyncKind.Text, new string('\u0001', SyncProtocol.MaxTemplateTextBytes), null, null, 0, 1);
        Error(SyncError.Limit, () => TemplateSyncMessageCodec.SplitPages(Guid.Parse(op), new TemplateSyncSnapshot(0, [heavyControlItem], []), isState: false));
    }

    [Fact]
    public void MergeHelpersEnforceNextUpdatedAtClockSkewConflictTitleAndLimits()
    {
        const long now = 1_794_873_600_000;

        // NextUpdatedAt: normal advance, slow-clock monotonic increment, and >1 year future reset
        Assert.Equal(now, TemplateSyncMerge.NextUpdatedAt(now, null));
        Assert.Equal(now, TemplateSyncMerge.NextUpdatedAt(now, now - 10_000));
        Assert.Equal(now + 1, TemplateSyncMerge.NextUpdatedAt(now - 3_600_000, now));
        Assert.Equal(now, TemplateSyncMerge.NextUpdatedAt(now, now + SyncProtocol.TemplateFutureTimestampCapMillis + 1));
        Assert.Equal(now + SyncProtocol.TemplateFutureTimestampCapMillis + 1,
            TemplateSyncMerge.NextUpdatedAt(now, now + SyncProtocol.TemplateFutureTimestampCapMillis));

        // ClockSkewSeconds threshold at 5 minutes (300,000 ms)
        Assert.Null(TemplateSyncMerge.ClockSkewSeconds(now + 299_999, now));
        Assert.Equal(300, TemplateSyncMerge.ClockSkewSeconds(now + 300_000, now));
        Assert.Equal(3600, TemplateSyncMerge.ClockSkewSeconds(now - 3_600_000, now));

        // MakeConflictTitle truncation stays within 100 chars and 400 UTF-8 bytes
        Assert.Equal("別の端末の編集", TemplateSyncMerge.MakeConflictTitle(null));
        Assert.Equal("別の端末の編集", TemplateSyncMerge.MakeConflictTitle("   \n "));
        var longTitle = new string('あ', 100);
        var conflictLong = TemplateSyncMerge.MakeConflictTitle(longTitle);
        Assert.EndsWith("（別の端末の編集）", conflictLong);
        Assert.True(TemplateSyncMessageCodec.CountGraphemeClusters(conflictLong) <= 100);
        Assert.True(Encoding.UTF8.GetByteCount(conflictLong) <= 400);

        var emojiTitle = string.Concat(Enumerable.Repeat("👨‍👩‍👧‍👦", 20)); // capped to 16 by NormalizedTitle (400B)
        var conflictEmoji = TemplateSyncMerge.MakeConflictTitle(emojiTitle);
        Assert.EndsWith("（別の端末の編集）", conflictEmoji);
        Assert.True(TemplateSyncMessageCodec.CountGraphemeClusters(conflictEmoji) <= 100);
        Assert.True(Encoding.UTF8.GetByteCount(conflictEmoji) <= 400);

        // Tombstone cap keeps latest 1,000 when > 1,000
        var pcTombs = Enumerable.Range(0, 600)
            .Select(i => new TemplateSyncTombstone(Guid.NewGuid(), now - 10_000 + i)).ToArray();
        var remoteTombs = Enumerable.Range(600, 600)
            .Select(i => new TemplateSyncTombstone(Guid.NewGuid(), now - 10_000 + i)).ToArray();
        var capped = TemplateSyncMerge.Merge(
            new TemplateSyncState([], pcTombs),
            new TemplateSyncState([], remoteTombs),
            now);
        Assert.Equal(1000, capped.Tombstones.Count);
        Assert.Equal(now - 10_000 + 200, capped.Tombstones[0].DeletedAt);
        Assert.Equal(now - 10_000 + 1199, capped.Tombstones[^1].DeletedAt);

        // Merged templates > 300 throws Limit instead of silently dropping data
        var pc200 = Enumerable.Range(0, 200)
            .Select(i => new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, $"pc-{i}", null, null, i, now)).ToArray();
        var remote200 = Enumerable.Range(0, 200)
            .Select(i => new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, $"rem-{i}", null, null, i, now)).ToArray();
        Error(SyncError.Limit, () => TemplateSyncMerge.Merge(
            new TemplateSyncState(pc200, []),
            new TemplateSyncState(remote200, []),
            now));

        // Conflict copy skipped when another active template already has loser's exact text
        var sharedId = Guid.NewGuid();
        var otherId = Guid.NewGuid();
        var hOrig = TemplateSyncMerge.ContentHash(TemplateSyncKind.Text, "orig", null, null);
        var conflictWithExistingText = TemplateSyncMerge.Merge(
            new TemplateSyncState([
                new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "winner", null, null, 0, now),
                new TemplateSyncItem(otherId, TemplateSyncKind.Text, "existing", null, null, 1, now),
            ], []),
            new TemplateSyncState([
                new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "existing", null, null, 0, now - 1000, hOrig),
            ], []),
            now);
        Assert.Equal(0, conflictWithExistingText.ConflictCopyCount);
        Assert.Equal(2, conflictWithExistingText.Templates.Count);

        // Merged 150 + 150 = 300 x 64KiB distinct items (needs 100 pages > 80) throws Limit in Merge/MergeAll
        var pc150 = Enumerable.Range(0, 150)
            .Select(i => new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, $"pc-{i:D3}-" + new string('a', SyncProtocol.MaxTemplateTextBytes - 7), null, null, i, now)).ToArray();
        var remote150 = Enumerable.Range(0, 150)
            .Select(i => new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, $"rm-{i:D3}-" + new string('b', SyncProtocol.MaxTemplateTextBytes - 7), null, null, i, now)).ToArray();
        Error(SyncError.Limit, () => TemplateSyncMerge.Merge(
            new TemplateSyncState(pc150, []),
            new TemplateSyncState(remote150, []),
            now));

        // Bounded writer rejects oversized pages during Encode and Assembler.Append
        var op = Guid.NewGuid();
        var maxOrderItem = new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "max-order", null, null, TemplateSyncMessageCodec.MaxOrder, 1);
        var encodedMaxOrder = TemplateSyncMessageCodec.Encode(new TemplateSyncPush(op, 0, 1, new TemplateSyncPage(1, 0, [maxOrderItem], [])));
        var decodedMaxOrder = Assert.IsType<TemplateSyncPush>(TemplateSyncMessageCodec.Decode(encodedMaxOrder));
        Assert.Equal(TemplateSyncMessageCodec.MaxOrder, decodedMaxOrder.Page.Templates[0].Order);

        var oversizedPage = new TemplateSyncPage(1, 0, [
            new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, new string('\u0001', SyncProtocol.MaxTemplateTextBytes), null, null, 0, 1)
        ], []);
        Error(SyncError.Limit, () => TemplateSyncMessageCodec.Encode(new TemplateSyncPush(op, 0, 1, oversizedPage)));
        var manyLargeItems = Enumerable.Range(0, 10)
            .Select(i => new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, new string((char)('a' + i), SyncProtocol.MaxTemplateTextBytes), null, null, i, 1)).ToArray();
        Error(SyncError.Limit, () => TemplateSyncMessageCodec.Encode(new TemplateSyncPush(op, 0, 1, new TemplateSyncPage(1, 0, manyLargeItems, []))));
        var assembler = new TemplateSyncPageAssembler();
        Error(SyncError.Limit, () => assembler.Append(new TemplateSyncPush(op, 0, 1, oversizedPage)));

        // PrepareSyncState excludes invalid/dirty local entries (control chars, duplicates) and preserves local active item over same-ID tombstone
        var keepId = Guid.NewGuid();
        var ctrlId = Guid.NewGuid();
        var preparedDirty = TemplateSyncMerge.PrepareSyncState([
            new TemplateSyncItem(keepId, TemplateSyncKind.Text, "valid", "ok", "tag", 0, now),
            new TemplateSyncItem(keepId, TemplateSyncKind.Text, "duplicate-id", null, null, 1, now),
            new TemplateSyncItem(ctrlId, TemplateSyncKind.Text, "bad-title", "a\u0007b", null, 2, now),
        ], [
            new TemplateSyncTombstone(keepId, now - 1000),
        ], now);
        Assert.Single(preparedDirty.State.Templates);
        Assert.Equal(keepId, preparedDirty.State.Templates[0].Id);
        Assert.Empty(preparedDirty.State.Tombstones);
        Assert.Equal(2, preparedDirty.ExcludedTemplateCount);
    }

    [Fact]
    public void ThreeDeviceMergeAllDeleteDoesNotResurrectStaleUneditedVersionAndKeepsConcurrentEdit()
    {
        const long now = 1_794_873_600_000;
        var sharedId = Guid.NewGuid();
        var hV1 = TemplateSyncMerge.ContentHash(TemplateSyncKind.Text, "v1", "題", "仕事");
        var hV2 = TemplateSyncMerge.ContentHash(TemplateSyncKind.Text, "v2", "題", "仕事");

        // 1. PC has v2, iPad deleted v2 (baseHash = H(v2)), iPhone is stale unedited v1 (baseHash = H(v1)).
        //    In both remote orderings, T must be deleted and NOT resurrected as v1.
        var pcState = new TemplateSyncState([
            new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "v2", "題", "仕事", 0, now - 10_000)
        ], []);
        var iPadDelete = new TemplateSyncRemoteState(
            new TemplateSyncState([], [new TemplateSyncTombstone(sharedId, now - 5_000, hV2)]),
            now);
        var iPhoneStale = new TemplateSyncRemoteState(
            new TemplateSyncState([new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "v1", "題", "仕事", 0, now - 20_000, hV1)], []),
            now);

        foreach (var order in new[] { new[] { iPadDelete, iPhoneStale }, new[] { iPhoneStale, iPadDelete } })
        {
            var merged = TemplateSyncMerge.MergeAll(pcState, order, now);
            Assert.Empty(merged.Templates);
            Assert.Single(merged.Tombstones, t => t.Id == sharedId);
            Assert.Equal(1, merged.PcChanges.Deleted);
        }

        // 2. If iPhone actually edited v1 -> v3 concurrently (hash != baseHash), v3 MUST survive.
        var iPhoneEdited = new TemplateSyncRemoteState(
            new TemplateSyncState([new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "v3-edited", "題", "仕事", 0, now - 3_000, hV1)], []),
            now);
        foreach (var order in new[] { new[] { iPadDelete, iPhoneEdited }, new[] { iPhoneEdited, iPadDelete } })
        {
            var merged = TemplateSyncMerge.MergeAll(pcState, order, now);
            var survivor = Assert.Single(merged.Templates);
            Assert.Equal(sharedId, survivor.Id);
            Assert.Equal("v3-edited", survivor.Text);
            Assert.Empty(merged.Tombstones);
        }
    }

    [Fact]
    public void LineEndingsNormalizeCrlfAndCrToLfInHashPrepareAndMerge()
    {
        const long now = 1_794_873_600_000;
        Assert.Equal("a\nb\nc\n", TemplateSyncMerge.NormalizeLineEndings("a\r\nb\rc\r\n"));
        Assert.Equal("plain", TemplateSyncMerge.NormalizeLineEndings("plain"));
        Assert.Equal(
            TemplateSyncMerge.ContentHash(TemplateSyncKind.Text, "line1\nline2\nline3", "題", "仕事"),
            TemplateSyncMerge.ContentHash(TemplateSyncKind.Text, "line1\r\nline2\rline3", "題", "仕事"));

        var pcId = Guid.NewGuid();
        var iosId = Guid.NewGuid();
        var prepared = TemplateSyncMerge.PrepareSyncState([
            new TemplateSyncItem(pcId, TemplateSyncKind.Text, "one\r\ntwo\rthree", "題", null, 0, now),
        ], [], now);
        Assert.Equal("one\ntwo\nthree", Assert.Single(prepared.State.Templates).Text);

        var merged = TemplateSyncMerge.Merge(
            new TemplateSyncState([new TemplateSyncItem(pcId, TemplateSyncKind.Text, "line1\r\nline2", "PC題", null, 0, now - 1_000)], []),
            new TemplateSyncState([new TemplateSyncItem(iosId, TemplateSyncKind.Text, "line1\nline2", null, "仕事", 0, now)], []),
            now);
        var kept = Assert.Single(merged.Templates);
        Assert.Equal(iosId, kept.Id);
        Assert.Equal("line1\nline2", kept.Text);
        Assert.Equal("PC題", kept.Title);
        Assert.Equal("仕事", kept.Tag);
        Assert.Equal(1, merged.SubsumedDuplicateCount);
    }

    [Fact]
    public void ThreeDeviceMergePreservesIndependentRemoteVersionEvenWhenOtherDeviceEditedSameBaseHash()
    {
        const long now = 1_794_873_600_000;
        var sharedId = Guid.NewGuid();
        var hA = TemplateSyncMerge.ContentHash(TemplateSyncKind.Text, "A", null, "仕事");

        // PC edited A -> C; iPad wrote back to A mid-sync (independent version with BaseHash = null);
        // iPhone concurrently edited A -> D (BaseHash = H(A)). All three texts must survive.
        var pcState = new TemplateSyncState([
            new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "C", null, "仕事", 0, now - 20_000),
        ], []);
        var iPadIndependent = new TemplateSyncRemoteState(
            new TemplateSyncState([new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "A", null, "仕事", 0, now - 10_000, null)], []),
            now);
        var iPhoneEdited = new TemplateSyncRemoteState(
            new TemplateSyncState([new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "D", null, "仕事", 0, now - 15_000, hA)], []),
            now);

        foreach (var order in new[] { new[] { iPadIndependent, iPhoneEdited }, new[] { iPhoneEdited, iPadIndependent } })
        {
            var merged = TemplateSyncMerge.MergeAll(pcState, order, now);
            Assert.Equal(3, merged.Templates.Count);
            Assert.Contains(merged.Templates, t => t.Id == sharedId && t.Text == "A" && t.Tag == "仕事");
            Assert.Contains(merged.Templates, t => t.Text == "C" && t.Tag is null);
            Assert.Contains(merged.Templates, t => t.Text == "D" && t.Tag is null);
        }
    }

    [Fact]
    public void DeletedItemDoesNotResurrectAfter181DaysOr1000TombstoneCapForUneditedDeviceButKeepsEdit()
    {
        const long now = 1_794_873_600_000;
        var idUnedited = Guid.NewGuid();
        var idEdited = Guid.NewGuid();
        var hUnedited = TemplateSyncMerge.ContentHash(TemplateSyncKind.Text, "削除済みの未編集項目", null, null);
        var hOriginal = TemplateSyncMerge.ContentHash(TemplateSyncKind.Text, "削除済みの元項目", null, null);

        // 1. After 181 days, PC's tombstones expired and were pruned; unedited item must NOT resurrect,
        //    while an offline-edited item MUST survive.
        var pcAfter181Days = new TemplateSyncState([], [
            new TemplateSyncTombstone(idUnedited, now - SyncProtocol.TemplateTombstoneLifetimeMillis - 86_400_000, hUnedited),
            new TemplateSyncTombstone(idEdited, now - SyncProtocol.TemplateTombstoneLifetimeMillis - 86_400_000, hOriginal),
        ]);
        var remoteAfter181Days = new TemplateSyncState([
            new TemplateSyncItem(idUnedited, TemplateSyncKind.Text, "削除済みの未編集項目", null, null, 0, now - 200L * 86_400_000, hUnedited),
            new TemplateSyncItem(idEdited, TemplateSyncKind.Text, "オフラインで書き換えた本文", null, null, 1, now - 10_000, hOriginal),
        ], []);

        var merged181 = TemplateSyncMerge.Merge(pcAfter181Days, remoteAfter181Days, now, now);
        var survivor = Assert.Single(merged181.Templates);
        Assert.Equal(idEdited, survivor.Id);
        Assert.Equal("オフラインで書き換えた本文", survivor.Text);
        Assert.Equal(1, merged181.RemoteChanges.Deleted);

        // 2. After 1,000 newer tombstones evict idUnedited's tombstone from PC, unedited item still must NOT resurrect.
        var newer1000Tombs = Enumerable.Range(0, SyncProtocol.MaxTemplateTombstones)
            .Select(i => new TemplateSyncTombstone(Guid.NewGuid(), now - 10_000 + i))
            .ToArray();
        var mergedEvicted = TemplateSyncMerge.Merge(
            new TemplateSyncState([], newer1000Tombs),
            new TemplateSyncState([
                new TemplateSyncItem(idUnedited, TemplateSyncKind.Text, "削除済みの未編集項目", null, null, 0, now - 50_000, hUnedited),
            ], []),
            now,
            now);
        Assert.Empty(mergedEvicted.Templates);
        Assert.Equal(1, mergedEvicted.RemoteChanges.Deleted);
    }

    [Fact]
    public void EditedConflictCopyIsNotDuplicatedWhenRemoteResendsLoser()
    {
        const long now = 1_794_873_600_000;
        var sharedId = Guid.NewGuid();
        var hA = TemplateSyncMerge.ContentHash(TemplateSyncKind.Text, "A", "題", "仕事");

        // 1. Initial conflict: PC has C, remote has B (baseHash = H(A)).
        var first = TemplateSyncMerge.Merge(
            new TemplateSyncState([new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "C", "題", "仕事", 0, now - 10_000)], []),
            new TemplateSyncState([new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "B", "題", "仕事", 0, now - 20_000, hA)], []),
            now,
            now);
        Assert.Equal(1, first.ConflictCopyCount);
        var copy = Assert.Single(first.Templates, t => t.Id != sharedId);
        Assert.Equal("B", copy.Text);

        // 2. Disconnect before remote receives reply; PC edits conflict copy B -> B2.
        var editedCopy = copy with { Text = "B2", UpdatedAt = now + 5_000 };
        var pcAfterEdit = new TemplateSyncState([
            first.Templates.Single(t => t.Id == sharedId),
            editedCopy,
        ], first.Tombstones);

        // 3. Remote resends B (baseHash = H(A)) -> B2 stays, NO second copy of B is created!
        var second = TemplateSyncMerge.Merge(
            pcAfterEdit,
            new TemplateSyncState([new TemplateSyncItem(sharedId, TemplateSyncKind.Text, "B", "題", "仕事", 0, now - 20_000, hA)], []),
            now + 10_000,
            now + 10_000);
        Assert.Equal(0, second.ConflictCopyCount);
        Assert.Equal(2, second.Templates.Count);
        Assert.Contains(second.Templates, t => t.Id == sharedId && t.Text == "C");
        Assert.Contains(second.Templates, t => t.Id == copy.Id && t.Text == "B2");
        Assert.DoesNotContain(second.Templates, t => t.Text == "B");
    }
}
