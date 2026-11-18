using System.Text;
using System.Text.Json;
using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class TemplateRepositoryTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "clipboardplus-tpl-repo-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
            Directory.Delete(root, recursive: true);
    }

    [Fact]
    public void CreateUpdateDeleteRestoreAndPersistRoundTripMatchesSchema()
    {
        const long t0 = 1_794_873_600_000;
        var repo = new TemplateRepository(root);
        Assert.Equal(0, repo.Count);

        var r1 = repo.Create("お世話になっております。\nよろしくお願いいたします。", "挨拶", "仕事", t0);
        Assert.True(r1.Succeeded);
        Assert.NotNull(r1.Item);
        Assert.Equal(TemplateSyncKind.Text, r1.Item!.Kind);
        Assert.Equal("挨拶", r1.Item.Title);
        Assert.Equal("仕事", r1.Item.Tag);
        Assert.Equal(0, r1.Item.Order);

        var r2 = repo.Create("https://example.com/docs/1", "仕様書", "仕事", t0 + 100);
        Assert.True(r2.Succeeded);
        Assert.Equal(TemplateSyncKind.Url, r2.Item!.Kind);
        Assert.Equal(1, r2.Item.Order);

        // Verify JSON file format on disk matches design doc.
        var jsonPath = Path.Combine(root, TemplateRepository.FileName);
        Assert.True(File.Exists(jsonPath));
        using (var doc = JsonDocument.Parse(File.ReadAllBytes(jsonPath)))
        {
            var jsonRoot = doc.RootElement;
            Assert.Equal(1, jsonRoot.GetProperty("FormatVersion").GetInt32());
            Assert.Equal(2, jsonRoot.GetProperty("Templates").GetArrayLength());
            Assert.Equal(0, jsonRoot.GetProperty("Tombstones").GetArrayLength());
            var first = jsonRoot.GetProperty("Templates")[0];
            Assert.Equal("text", first.GetProperty("Kind").GetString());
            Assert.Equal("挨拶", first.GetProperty("Title").GetString());
            Assert.Equal("仕事", first.GetProperty("Tag").GetString());
            Assert.Equal(0, first.GetProperty("Order").GetInt32());
        }

        // Update text to a link and change tag -> kind reclassifies, old tag renumbers, moves to end of new tag.
        var updated = repo.Update(r1.Item.Id, "https://clipboardplus.example/help", "ヘルプ", null, t0 + 200);
        Assert.True(updated.Succeeded);
        Assert.Equal(TemplateSyncKind.Url, updated.Item!.Kind);
        Assert.Null(updated.Item.Tag);
        Assert.Equal(0, updated.Item.Order);
        Assert.Equal(0, repo.Get(r2.Item.Id)!.Order);

        // Delete records tombstone with ContentHash; Restore within undo puts item back and removes tombstone.
        var deleted = repo.Delete(r2.Item.Id, t0 + 300);
        Assert.True(deleted.Succeeded);
        Assert.Equal(1, repo.Count);
        Assert.Equal(1, repo.TombstoneCount);
        var tombstone = Assert.Single(repo.GetState().Tombstones);
        Assert.Equal(r2.Item.Id, tombstone.Id);
        Assert.Equal(t0 + 300, tombstone.DeletedAt);
        Assert.Equal(TemplateSyncMerge.ContentHash(r2.Item), tombstone.BaseHash);

        var restored = repo.Restore(deleted.Deleted!, t0 + 310);
        Assert.True(restored.Succeeded);
        Assert.Equal(2, repo.Count);
        Assert.Equal(0, repo.TombstoneCount);
        Assert.Equal(t0 + 310, restored.Item!.UpdatedAt);

        // Reload from disk.
        var reloaded = new TemplateRepository(root);
        Assert.Equal(2, reloaded.Count);
        Assert.Equal(updated.Item, reloaded.Get(r1.Item.Id));
        Assert.Equal(restored.Item, reloaded.Get(r2.Item.Id));
    }

    [Fact]
    public void ValidationEnforcesEmptyDuplicateSizeLimitAndLabelSanitization()
    {
        const long t0 = 1_794_873_600_000;
        var repo = new TemplateRepository(root);

        Assert.Equal(TemplateEditError.Empty, repo.Create("  \n\t ", null, null, t0).Error);
        Assert.Equal(TemplateEditError.InvalidText, repo.Create("\uD800", null, null, t0).Error);
        Assert.Equal(TemplateEditError.TooLarge, repo.Create(new string('a', SyncProtocol.MaxTemplateTextBytes + 1), null, null, t0).Error);

        var maxOk = repo.Create(new string('a', SyncProtocol.MaxTemplateTextBytes), "名前\n改行\u0007除去😀", "タグ\t1👨‍👩‍👧‍👦", t0);
        Assert.True(maxOk.Succeeded);
        Assert.Equal("名前 改行除去😀", maxOk.Item!.Title);
        Assert.Equal("タグ 1👨‍👩‍👧‍👦", maxOk.Item.Tag);
        TemplateSyncMessageCodec.ValidateItem(maxOk.Item, allowBaseHash: false);

        // Exact duplicate rejected on Create and Update (other item), while updating self metadata is allowed.
        var dup = repo.Create(maxOk.Item.Text, "別名", null, t0 + 1);
        Assert.False(dup.Succeeded);
        Assert.Equal(TemplateEditError.Duplicate, dup.Error);

        var second = repo.Create("  leading spaces preserved  ", null, null, t0 + 2);
        Assert.True(second.Succeeded);
        Assert.Equal("  leading spaces preserved  ", second.Item!.Text);
        Assert.Equal(TemplateEditError.Duplicate, repo.Update(second.Item.Id, maxOk.Item.Text, null, null, t0 + 3).Error);
        Assert.True(repo.Update(second.Item.Id, second.Item.Text, "名前追加", "仕事", t0 + 4).Succeeded);

        // Fill up to 300 and verify 301st fails cleanly.
        for (var i = 2; i < SyncProtocol.MaxTemplates; i++)
            Assert.True(repo.Create($"template-{i}", null, null, t0 + 10 + i).Succeeded);
        Assert.Equal(SyncProtocol.MaxTemplates, repo.Count);
        Assert.Equal(TemplateEditError.LimitExceeded, repo.Create("template-300", null, null, t0 + 1000).Error);
    }

    [Fact]
    public void CorruptOrUnreadableFilesDoNotCrashAndRecoverValidEntries()
    {
        var logs = new List<string>();
        var jsonPath = Path.Combine(root, TemplateRepository.FileName);
        Directory.CreateDirectory(root);

        foreach (var badContent in new[]
        {
            "",
            "{ not valid json",
            "null",
            "[]",
            """{"FormatVersion":99,"Templates":[],"Tombstones":[]}""",
            """{"FormatVersion":"1","Templates":[],"Tombstones":[]}""",
            """{"FormatVersion":1,"Templates":"oops","Tombstones":[]}""",
        })
        {
            File.WriteAllText(jsonPath, badContent, Encoding.UTF8);
            var repo = new TemplateRepository(root, logs.Add);
            Assert.Equal(0, repo.Count);
            Assert.Equal(0, repo.TombstoneCount);
        }

        // BOM + partially corrupt array recovers valid items and skips bad ones without logging text/paths.
        var validId = Guid.NewGuid();
        var tombId = Guid.NewGuid();
        var partialJson = $$$"""
        {
          "FormatVersion": 1,
          "Templates": [
            { "Id": "{{{validId}}}", "Kind": "text", "Text": "secret-valid-body", "Title": "secret-title", "Tag": "secret-tag", "Order": 0, "UpdatedAt": 100 },
            { "Id": "not-a-guid", "Kind": "text", "Text": "bad-id", "Order": 0, "UpdatedAt": 100 },
            { "Id": "{{{Guid.NewGuid()}}}", "Kind": "image", "Text": "bad-kind", "Order": 0, "UpdatedAt": 100 },
            { "Id": "{{{Guid.NewGuid()}}}", "Kind": "text", "Text": "{{{new string('x', SyncProtocol.MaxTemplateTextBytes + 1)}}}", "Order": 0, "UpdatedAt": 100 },
            { "Id": "{{{validId}}}", "Kind": "text", "Text": "duplicate-id", "Order": 1, "UpdatedAt": 200 }
          ],
          "Tombstones": [
            { "Id": "{{{tombId}}}", "DeletedAt": 500, "BaseHash": "{{{new string('A', 64)}}}" },
            { "Id": "{{{validId}}}", "DeletedAt": 501 },
            { "Id": "bad-tomb-id", "DeletedAt": 502 }
          ]
        }
        """;
        var withBom = new byte[] { 0xEF, 0xBB, 0xBF }.Concat(Encoding.UTF8.GetBytes(partialJson)).ToArray();
        File.WriteAllBytes(jsonPath, withBom);

        logs.Clear();
        var partialRepo = new TemplateRepository(root, logs.Add);
        Assert.Equal(1, partialRepo.Count);
        var loaded = Assert.Single(partialRepo.List());
        Assert.Equal(validId, loaded.Id);
        Assert.Equal("secret-valid-body", loaded.Text);
        Assert.Equal(1, partialRepo.TombstoneCount);
        Assert.Equal(new string('a', 64), partialRepo.GetState().Tombstones[0].BaseHash);
        Assert.Contains(logs, l => l.Contains("templates load skipped="));
        Assert.DoesNotContain(logs, l => l.Contains("secret") || l.Contains(root));
    }

    [Fact]
    public void AtomicWriteFailureRollsBackInMemoryAndPreservesExistingFile()
    {
        const long t0 = 1_794_873_600_000;
        var repo = new TemplateRepository(root);
        var first = repo.Create("durable-item", "固定", "仕事", t0);
        Assert.True(first.Succeeded);

        var tempConflictDir = Path.Combine(root, TemplateRepository.FileName + ".tmp");
        Directory.CreateDirectory(tempConflictDir);

        var ex = Assert.ThrowsAny<Exception>(() => repo.Create("should-rollback", null, null, t0 + 1));
        Assert.True(ex is IOException or UnauthorizedAccessException);

        Assert.Equal(1, repo.Count);
        Assert.Equal("durable-item", Assert.Single(repo.List()).Text);

        Directory.Delete(tempConflictDir);
        var reloaded = new TemplateRepository(root);
        Assert.Equal(1, reloaded.Count);
        Assert.Equal("durable-item", Assert.Single(reloaded.List()).Text);
    }

    [Fact]
    public void NaturalTagOrderSearchMoveRenameAndClearTombstonesForRepair()
    {
        const long t0 = 1_794_873_600_000;
        var repo = new TemplateRepository(root);

        var u1 = repo.Create("その他1", null, null, t0).Item!;
        var t10 = repo.Create("十番", "タイトルA", "タグ10", t0 + 1).Item!;
        var t2a = repo.Create("二番A", null, "タグ2", t0 + 2).Item!;
        var t2b = repo.Create("二番B", "タイトルB", "タグ2", t0 + 3).Item!;

        // Natural numeric order puts タグ2 before タグ10, and その他 last.
        var groups = repo.GetGroups();
        Assert.Equal(["タグ2", "タグ10", "その他"], groups.Select(g => g.Title).ToArray());
        Assert.Equal([t2a.Id, t2b.Id], groups[0].Items.Select(i => i.Id).ToArray());

        // Search matches Title, Tag, or Text case-insensitively.
        Assert.Single(repo.List("タイトルa"));
        Assert.Equal(2, repo.List("タグ2").Count);
        Assert.Single(repo.List("その他1"));

        // Move in group swaps items, updates order and updatedAt.
        Assert.False(repo.MoveInGroup(t2a.Id, -1, t0 + 10));
        Assert.True(repo.MoveInGroup(t2b.Id, -1, t0 + 10));
        var reordered = repo.GetGroups()[0].Items;
        Assert.Equal([t2b.Id, t2a.Id], reordered.Select(i => i.Id).ToArray());
        Assert.Equal([0, 1], reordered.Select(i => i.Order).ToArray());
        Assert.True(reordered[0].UpdatedAt >= t0 + 10);
        Assert.True(reordered[1].UpdatedAt >= t0 + 10);

        // RenameTag merges タグ2 into タグ10 (appended after existing タグ10 item).
        Assert.Equal(2, repo.RenameTag("タグ2", "タグ10", t0 + 20));
        var afterRename = repo.GetGroups();
        Assert.Equal(["タグ10", "その他"], afterRename.Select(g => g.Title).ToArray());
        Assert.Equal([t10.Id, t2b.Id, t2a.Id], afterRename[0].Items.Select(i => i.Id).ToArray());
        Assert.Equal([0, 1, 2], afterRename[0].Items.Select(i => i.Order).ToArray());

        // Delete creates tombstone; ClearTombstones (for repair) clears tombstones while keeping templates.
        repo.Delete(u1.Id, t0 + 30);
        Assert.Equal(1, repo.TombstoneCount);
        Assert.Equal(3, repo.Count);

        repo.ClearTombstones();
        Assert.Equal(0, repo.TombstoneCount);
        Assert.Equal(3, repo.Count);
        var reloaded = new TemplateRepository(root);
        Assert.Equal(0, reloaded.TombstoneCount);
        Assert.Equal(3, reloaded.Count);
    }

    [Fact]
    public void TombstonePruningEnforces180DayLifetimeAnd1000ItemCap()
    {
        const long t0 = 1_794_873_600_000;
        var repo = new TemplateRepository(root);

        var oldTomb = new TemplateSyncTombstone(Guid.NewGuid(), t0);
        var recentTombs = Enumerable.Range(0, SyncProtocol.MaxTemplateTombstones - 1)
            .Select(i => new TemplateSyncTombstone(Guid.NewGuid(), t0 + SyncProtocol.TemplateTombstoneLifetimeMillis + i))
            .ToArray();

        repo.ApplyMerged([], [oldTomb, .. recentTombs]);
        Assert.Equal(SyncProtocol.MaxTemplateTombstones, repo.TombstoneCount);

        // Prune at t0 + lifetime: oldTomb is at exact 180-day boundary (<= lifetime), so kept; +1ms expires it.
        Assert.False(repo.PruneTombstones(t0 + SyncProtocol.TemplateTombstoneLifetimeMillis));
        var freshCheck = t0 + SyncProtocol.TemplateTombstoneLifetimeMillis + 1;
        Assert.True(repo.PruneTombstones(freshCheck));
        Assert.Equal(SyncProtocol.MaxTemplateTombstones - 1, repo.TombstoneCount);
        Assert.DoesNotContain(repo.GetState().Tombstones, t => t.Id == oldTomb.Id);

        // Deleting one more item when at 1000 caps at 1000 dropping oldest.
        var excessTombs = Enumerable.Range(0, SyncProtocol.MaxTemplateTombstones)
            .Select(i => new TemplateSyncTombstone(Guid.NewGuid(), t0 + 10_000 + i))
            .ToArray();
        var item = new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "will-delete", null, null, 0, t0);
        repo.ApplyMerged([item], excessTombs);
        var del = repo.Delete(item.Id, t0 + 20_000);
        Assert.True(del.Succeeded);
        Assert.Equal(SyncProtocol.MaxTemplateTombstones, repo.TombstoneCount);
        Assert.DoesNotContain(repo.GetState().Tombstones, t => t.Id == excessTombs[0].Id);
        Assert.Contains(repo.GetState().Tombstones, t => t.Id == item.Id);
    }

    [Fact]
    public void ApplyMergedPreservingLocalRetainsExcludedItemsDropsConflictingTombstonesAndEnforcesLimit()
    {
        const long t0 = 1_794_873_600_000;
        var repo = new TemplateRepository(root);

        var synced = new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "synced", null, "仕事", 0, t0);
        var preserved1 = new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "preserved-1", null, "仕事", 2, t0 + 1);
        var preserved2 = new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "preserved-2", null, "仕事", 1, t0 + 2);
        var sameTextPreserved = new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "synced", null, null, 0, t0 + 3);
        var tombstoneForPreserved = new TemplateSyncTombstone(preserved1.Id, t0 + 10);
        var validTombstone = new TemplateSyncTombstone(Guid.NewGuid(), t0 + 11);

        var saved = repo.ApplyMerged(
            [synced],
            [tombstoneForPreserved, validTombstone],
            [preserved1, preserved2, sameTextPreserved]);

        Assert.Equal(3, saved.Count);
        Assert.Equal([synced.Id, preserved2.Id, preserved1.Id], saved.Select(t => t.Id).ToArray());
        Assert.Equal([0, 1, 2], saved.Select(t => t.Order).ToArray());
        Assert.Equal([validTombstone], repo.GetState().Tombstones);

        // Exceeding 300 total (synced + preserved) throws Limit without overwriting previous durable state.
        var synced300 = Enumerable.Range(0, SyncProtocol.MaxTemplates)
            .Select(i => new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, $"item-{i}", null, null, i, t0))
            .ToArray();
        var ex = Assert.Throws<SyncProtocolException>(() => repo.ApplyMerged(synced300, [], [preserved1]));
        Assert.Equal(SyncError.Limit, ex.Code);
        Assert.Equal(3, repo.Count);
        Assert.Equal(3, new TemplateRepository(root).Count);
    }
}
