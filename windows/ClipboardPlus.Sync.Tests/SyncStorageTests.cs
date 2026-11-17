using System.Security.Cryptography;
using ClipboardPlus.Windows.Core;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class SyncStorageTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "clipboardplus-tests", Guid.NewGuid().ToString("N"));
    private readonly Guid pair = Guid.NewGuid(), device = Guid.NewGuid();
    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }

    [Fact]
    public void OfflineQueuesSurviveRestartAreBoundedAndExpireAndRepairClearsThem()
    {
        var now = DateTimeOffset.UtcNow; var store = new SyncRepository(root, pair);
        store.Register(device, "phone", now);
        for (var n = 0; n < 102; n++) store.Enqueue(store.Create(new("text", Text: $"entry {n}"), now.AddSeconds(n).ToUnixTimeMilliseconds(), "PC"), now);
        store = new(root, pair);
        Assert.Equal(100, store.Pending(device).Count); Assert.Equal("entry 2", store.Pending(device)[0].Text);
        Assert.Equal("phone", Assert.Single(store.Devices).Kind);
        store.Prune(now.AddHours(24).AddMinutes(2)); Assert.Empty(store.Pending(device));
        store = new(root, Guid.NewGuid()); Assert.Empty(store.Devices); Assert.Equal(0, store.PendingCount);
    }

    [Fact]
    public void PartialLargerThanFrameSurvivesProcessRestartAndVerifiesWholeHash()
    {
        var data = new byte[SyncProtocol.MaxFrameBytes + 19]; RandomNumberGenerator.Fill(data);
        var offer = new SyncOffer(Guid.NewGuid(), 0, "pad", "file", data.Length, Convert.ToHexStringLower(SHA256.HashData(data)), "YS50eHQ=", "public.data");
        var store = new SyncRepository(root, pair); var now = DateTimeOffset.UtcNow;
        Assert.Equal(0, store.Begin(device, offer, now));
        var offset = 0;
        while (offset < data.Length)
        {
            var count = Math.Min(SyncProtocol.ChunkBytes, data.Length - offset);
            offset = store.Append(device, new SyncChunk(offer.Id, offset, data[offset..(offset + count)]));
            if (offset == SyncProtocol.ChunkBytes * 3) { store = new(root, pair); Assert.Equal(offset, store.Begin(device, offer, now)); }
        }
        var item = store.Complete(device, offer, "iPad"); Assert.Equal(data, File.ReadAllBytes(item.Path!));
    }

    [Fact]
    public void WrongOffsetsChangedOffersAndHashMismatchNeverCommit()
    {
        var store = new SyncRepository(root, pair);
        var offer = new SyncOffer(Guid.NewGuid(), 0, "pad", "file", 2, new string('0', 64), "YS50eHQ=", "public.data");
        store.Begin(device, offer, DateTimeOffset.UtcNow);
        Assert.Throws<SyncProtocolException>(() => store.Begin(device, offer with { Size = 3 }, DateTimeOffset.UtcNow));
        Assert.Throws<SyncProtocolException>(() => store.Append(device, new(offer.Id, 1, [1])));
        store.Append(device, new(offer.Id, 0, [1, 2]));
        Assert.Throws<SyncProtocolException>(() => store.Complete(device, offer, "iPad"));
        Assert.Null(store.Incoming(device, offer.Id)); Assert.Empty(store.List());
    }

    [Fact]
    public void HistoryDeduplicatesCapsAt300AndDeletionDropsPendingBodies()
    {
        var store = new SyncRepository(root, pair); var now = DateTimeOffset.UtcNow;
        store.Register(device, "pad", now);
        for (var n = 0; n < 301; n++) store.AddHistory(store.Create(new("text", Text: $"text {n}"), n, "PC"));
        Assert.Equal(300, store.List().Count);
        var latest = store.List()[0]; store.AddHistory(store.Create(new("text", Text: latest.Text), 1000, "iPhone"));
        Assert.Equal(latest.Id, store.List()[0].Id); Assert.Equal(1000, store.List()[0].At);
        var media = store.Create(new("file", Filename: "document.txt", Data: [1, 2]), now.ToUnixTimeMilliseconds(), "PC");
        store.AddHistory(media); store.Enqueue(media, now); store.Delete(media.Id);
        Assert.Empty(store.Pending(device)); Assert.False(File.Exists(media.Path));
        store = new(root, pair); Assert.Empty(store.List("document"));
    }

    [Fact]
    public void DedupeWindowPersistsAndDistinguishesDevicesAndKinds()
    {
        var now = DateTimeOffset.UtcNow; var store = new SyncRepository(root, pair);
        var item = store.Create(new("text", Text: "same"), 1, "iPad");
        store.CommitReceived(item, device, now, false); store = new(root, pair);
        Assert.True(store.Seen(device, item.Id)); Assert.False(store.Duplicate(item, device, now));
        Assert.True(store.Duplicate(item, Guid.NewGuid(), now.AddMinutes(9)));
        Assert.False(store.Duplicate(item, Guid.NewGuid(), now.AddMinutes(11)));
        Assert.False(store.Duplicate(item with { Kind = "file" }, Guid.NewGuid(), now));
    }

    [Fact]
    public void EmptyFileAndMaximumItemBoundary()
    {
        var store = new SyncRepository(root, pair);
        var offer = new SyncOffer(Guid.NewGuid(), 0, "pad", "file", 0, Convert.ToHexStringLower(SHA256.HashData([])), "YS50eHQ=", "public.data");
        Assert.Equal(0, store.Begin(device, offer, DateTimeOffset.UtcNow));
        Assert.Equal(0, store.Complete(device, offer, "iPad").Size);
        Assert.Throws<SyncProtocolException>(() => SyncMessageCodec.Encode(offer with { Size = SyncProtocol.MaxItemBytes + 1 }));
        Assert.IsType<SyncOffer>(SyncMessageCodec.Decode(SyncMessageCodec.Encode(offer with { Size = SyncProtocol.MaxItemBytes })));
    }

    [Fact]
    public void IdentityIsAuthenticatedAndVersionMismatchIsDistinct()
    {
        var pairing = SyncPairing.Create("test"); var pad = new SyncPadHandshake(pairing, device); var pc = new SyncPcHandshake(pairing);
        var hello = pad.CreateHello(); hello[2] ^= 1;
        var welcome = pc.AcceptHello(hello);
        Assert.Equal(SyncError.Authentication, Assert.Throws<SyncProtocolException>(() => pad.AcceptWelcome(welcome)).Code);
        hello = new SyncPadHandshake(pairing, device).CreateHello(); hello[1] = 1;
        Assert.Equal(SyncError.Version, Assert.Throws<SyncProtocolException>(() => new SyncPcHandshake(pairing).AcceptHello(hello)).Code);
    }

    [Fact]
    public void EqualTimestampsKeepNewestAdmissionsAndFailedSaveDoesNotAcknowledgeInMemory()
    {
        var now = DateTimeOffset.UtcNow; var store = new SyncRepository(root, pair);
        store.Register(device, "pad", now);
        for (var n = 0; n < 102; n++) store.Enqueue(store.Create(new("text", Text: $"entry {n}"), now.ToUnixTimeMilliseconds(), "PC"), now);
        Assert.Equal("entry 2", store.Pending(device)[0].Text);
        Assert.Equal("entry 101", store.Pending(device)[^1].Text);
        var item = store.Create(new("text", Text: "received"), now.ToUnixTimeMilliseconds(), "iPad");
        // A directory occupying the atomic-write temporary name simulates a failed metadata commit.
        Directory.CreateDirectory(Path.Combine(root, "sync-state.json.tmp"));
        var failure = Assert.ThrowsAny<Exception>(() => store.Ack(device, new HashSet<Guid> { store.Pending(device)[0].Id }));
        Assert.True(failure is IOException or UnauthorizedAccessException);
        Assert.Equal(100, store.Pending(device).Count);
        try { store.CommitReceived(item, device, now, false); Assert.Fail("Save should fail"); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        Assert.False(store.Seen(device, item.Id)); Assert.Empty(store.List());
    }

    [Fact]
    public void BeginEvictsOldestPartialAtLimitPerDevice()
    {
        var now = DateTimeOffset.UtcNow; var store = new SyncRepository(root, pair);
        var other = Guid.NewGuid();
        var sha = Convert.ToHexStringLower(SHA256.HashData([1]));
        var otherOffer = new SyncOffer(Guid.NewGuid(), 0, "pad", "file", 1, sha, "b3RoZXIudHh0", "public.data");
        store.Begin(other, otherOffer, now);

        var created = new List<SyncOffer>();
        for (var i = 0; i < SyncProtocol.MaxPending; i++)
        {
            var offer = new SyncOffer(Guid.NewGuid(), i, "pad", "file", 1, sha, Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes($"f{i}.txt")), "public.data");
            created.Add(offer);
            // First two share the exact same Created timestamp to verify FIFO tie-breaking.
            store.Begin(device, offer, i <= 1 ? now : now.AddSeconds(i));
        }
        var extra = new SyncOffer(Guid.NewGuid(), 999, "pad", "file", 1, sha, "ZXh0cmEudHh0", "public.data");
        Assert.Equal(0, store.Begin(device, extra, now.AddSeconds(500)));
        Assert.Null(store.Incoming(device, created[0].Id));
        Assert.False(File.Exists(store.PartialPath(device, created[0].Id)));
        Assert.NotNull(store.Incoming(device, created[1].Id));
        Assert.NotNull(store.Incoming(device, extra.Id));
        Assert.NotNull(store.Incoming(other, otherOffer.Id));

        // Second eviction removes created[1] (the other equal-timestamp entry).
        var extra2 = new SyncOffer(Guid.NewGuid(), 1000, "pad", "file", 1, sha, "ZXh0cmEyLnR4dA==", "public.data");
        store.Begin(device, extra2, now.AddSeconds(501));
        Assert.Null(store.Incoming(device, created[1].Id));
        Assert.False(File.Exists(store.PartialPath(device, created[1].Id)));
    }

    [Fact]
    public void PruneAndStartupRemoveMissingOrMismatchedQueueAndPartialFiles()
    {
        var now = DateTimeOffset.UtcNow; var store = new SyncRepository(root, pair);
        store.Register(device, "pad", now);
        var good = store.Create(new("file", Filename: "good.bin", Data: [1, 2, 3]), now.ToUnixTimeMilliseconds(), "PC");
        var missing = store.Create(new("file", Filename: "missing.bin", Data: [4, 5, 6]), now.AddSeconds(1).ToUnixTimeMilliseconds(), "PC");
        var wrongSize = store.Create(new("file", Filename: "wrong.bin", Data: [7, 8, 9]), now.AddSeconds(2).ToUnixTimeMilliseconds(), "PC");
        store.AddAndEnqueue(good, now);
        store.AddAndEnqueue(missing, now);
        store.AddAndEnqueue(wrongSize, now);

        var partialGood = new SyncOffer(Guid.NewGuid(), 0, "pad", "file", 2, Convert.ToHexStringLower(SHA256.HashData([1, 2])), "Z29vZC5iaW4=", "public.data");
        var partialMissing = new SyncOffer(Guid.NewGuid(), 0, "pad", "file", 2, Convert.ToHexStringLower(SHA256.HashData([3, 4])), "bWlzcy5iaW4=", "public.data");
        var partialOversized = new SyncOffer(Guid.NewGuid(), 0, "pad", "file", 2, Convert.ToHexStringLower(SHA256.HashData([5, 6])), "b3Zlci5iaW4=", "public.data");
        store.Begin(device, partialGood, now);
        store.Begin(device, partialMissing, now);
        store.Begin(device, partialOversized, now);

        File.Delete(missing.Path!);
        File.WriteAllBytes(wrongSize.Path!, [7]);
        File.Delete(store.PartialPath(device, partialMissing.Id));
        File.WriteAllBytes(store.PartialPath(device, partialOversized.Id), [1, 2, 3]);

        store.Prune(now);
        Assert.Equal([good.Id], store.Pending(device).Select(i => i.Id).ToArray());
        Assert.NotNull(store.Incoming(device, partialGood.Id));
        Assert.Null(store.Incoming(device, partialMissing.Id));
        Assert.Null(store.Incoming(device, partialOversized.Id));
        Assert.False(File.Exists(store.PartialPath(device, partialOversized.Id)));

        // Also check startup verification after reloading from disk.
        File.Delete(good.Path!);
        File.Delete(store.PartialPath(device, partialGood.Id));
        var reloaded = new SyncRepository(root, pair);
        Assert.Empty(reloaded.Pending(device));
        Assert.Null(reloaded.Incoming(device, partialGood.Id));
    }

    [Fact]
    public void EqualTimestampsInHistoryKeepNewestAdmissionsAndOrderNewestFirst()
    {
        var store = new SyncRepository(root, pair);
        const long at = 1_700_000_000_000;
        for (var n = 0; n <= SyncProtocol.MaxHistory; n++)
            store.AddHistory(store.Create(new("text", Text: $"item {n}"), at, "PC"));

        var list = store.List();
        Assert.Equal(SyncProtocol.MaxHistory, list.Count);
        Assert.Equal($"item {SyncProtocol.MaxHistory}", list[0].Text);
        Assert.Equal("item 1", list[^1].Text);
        Assert.DoesNotContain(list, i => i.Text == "item 0");
    }

    [Fact]
    public void DuplicateDoesNotExtendOrOverwriteRecentWindowForOriginalDevice()
    {
        var now = DateTimeOffset.UtcNow; var store = new SyncRepository(root, pair);
        var other = Guid.NewGuid();
        var itemA = store.Create(new("text", Text: "A"), 100, "iPhone");
        store.CommitReceived(itemA, device, now, duplicate: false);

        var dup = store.Duplicate(itemA, other, now.AddMinutes(1));
        Assert.True(dup);
        store.CommitReceived(itemA with { Id = Guid.NewGuid() }, other, now.AddMinutes(1), duplicate: true);

        // Original device copying "A" again must not be treated as a duplicate of the dropped copy.
        Assert.False(store.Duplicate(itemA with { Id = Guid.NewGuid() }, device, now.AddMinutes(2)));
    }

    [Fact]
    public void CompleteReusesMatchingBodyWithoutSharingViolationAndDuplicateCleansOrphanBody()
    {
        var now = DateTimeOffset.UtcNow; var store = new SyncRepository(root, pair);
        var data = new byte[] { 10, 20, 30, 40 };
        var sha = Convert.ToHexStringLower(SHA256.HashData(data));
        var existing = store.Create(new("file", Filename: "shared.bin", Data: data), now.ToUnixTimeMilliseconds(), "PC");
        store.AddHistory(existing);
        store.MarkSent(existing, now);

        var offer = new SyncOffer(Guid.NewGuid(), now.ToUnixTimeMilliseconds(), "pad", "file", data.Length, sha, "c2hhcmVkLmJpbg==", "public.data");
        store.Begin(device, offer, now);
        store.Append(device, new(offer.Id, 0, data));

        using (var activeRead = new FileStream(existing.Path!, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var completed = store.Complete(device, offer, "iPad");
            Assert.Equal(existing.Path, completed.Path);
        }
        store.DiscardPartial(device, offer.Id);

        // Evict existing from history so bodies/<sha> is removed, then receive duplicate attachment.
        for (var i = 0; i < SyncProtocol.MaxHistory; i++)
            store.AddHistory(store.Create(new("text", Text: $"fill {i}"), now.AddSeconds(i + 1).ToUnixTimeMilliseconds(), "PC"));
        Assert.False(File.Exists(existing.Path));

        var other = Guid.NewGuid();
        var dupOffer = new SyncOffer(Guid.NewGuid(), now.ToUnixTimeMilliseconds(), "pad", "file", data.Length, sha, "ZHVwLmJpbg==", "public.data");
        store.Begin(other, dupOffer, now);
        store.Append(other, new(dupOffer.Id, 0, data));
        var dupItem = store.Complete(other, dupOffer, "iPad");
        Assert.True(File.Exists(dupItem.Path));
        Assert.True(store.Duplicate(dupItem, other, now.AddMinutes(1)));
        store.CommitReceived(dupItem, other, now.AddMinutes(1), duplicate: true);
        store.DiscardPartial(other, dupOffer.Id);
        Assert.False(File.Exists(dupItem.Path));
    }

    [Fact]
    public void SafeFilenameReplacesControlAndBidiCharactersWhileKeepingZwj()
    {
        Assert.Equal("家族👨‍👩‍👧‍👦.png", SyncRepository.SafeFilename("家族👨‍👩‍👧‍👦.png"));
        Assert.Equal("a_b_c.txt", SyncRepository.SafeFilename("a/b:c.txt"));
        Assert.Equal("bad_name_.txt", SyncRepository.SafeFilename("bad\u0007name\u0085.txt"));
        foreach (var bidi in new[] { '\u061C', '\u200E', '\u200F', '\u202A', '\u202B', '\u202C', '\u202D', '\u202E', '\u2066', '\u2067', '\u2068', '\u2069' })
            Assert.Equal("a_b.txt", SyncRepository.SafeFilename($"a{bidi}b.txt"));
    }

    [Fact]
    public void BeginEvictionAtomicWriteFailureDoesNotLoseExistingPartial()
    {
        var now = DateTimeOffset.UtcNow;
        var store = new SyncRepository(root, pair);
        var sha = Convert.ToHexStringLower(SHA256.HashData([1]));
        var created = new List<SyncOffer>();
        for (var i = 0; i < SyncProtocol.MaxPending; i++)
        {
            var offer = new SyncOffer(Guid.NewGuid(), i, "pad", "file", 1, sha, Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes($"p{i}.txt")), "public.data");
            created.Add(offer);
            store.Begin(device, offer, now.AddSeconds(i));
        }

        var extra = new SyncOffer(Guid.NewGuid(), 999, "pad", "file", 1, sha, "ZXh0cmEudHh0", "public.data");
        Directory.CreateDirectory(store.PartialPath(device, extra.Id) + ".tmp");

        var failure = Assert.ThrowsAny<Exception>(() => store.Begin(device, extra, now.AddSeconds(500)));
        Assert.True(failure is IOException or UnauthorizedAccessException);

        Assert.NotNull(store.Incoming(device, created[0].Id));
        Assert.True(File.Exists(store.PartialPath(device, created[0].Id)));
        Assert.Null(store.Incoming(device, extra.Id));

        // A later successful Save() must preserve the un-evicted oldest partial on disk as well.
        store.Register(Guid.NewGuid(), "phone", now);
        var reloaded = new SyncRepository(root, pair);
        Assert.NotNull(reloaded.Incoming(device, created[0].Id));
        Assert.True(File.Exists(reloaded.PartialPath(device, created[0].Id)));
    }
}
