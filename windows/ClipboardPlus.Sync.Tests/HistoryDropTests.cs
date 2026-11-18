using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class HistoryDropTests
{
    [Fact]
    public void SelectDropSourceRejectsSelfDragAndPrioritizesFileThenImageThenText()
    {
        Assert.Equal(DropSourceKind.None, HistoryDrop.SelectDropSource(
            isDraggingFromSelf: true, hasSelfDragMarker: false, hasFileDrop: true, hasImage: true, hasText: true));
        Assert.Equal(DropSourceKind.None, HistoryDrop.SelectDropSource(
            isDraggingFromSelf: false, hasSelfDragMarker: true, hasFileDrop: true, hasImage: true, hasText: true));

        Assert.Equal(DropSourceKind.FileDrop, HistoryDrop.SelectDropSource(
            isDraggingFromSelf: false, hasSelfDragMarker: false, hasFileDrop: true, hasImage: true, hasText: true));
        Assert.Equal(DropSourceKind.Image, HistoryDrop.SelectDropSource(
            isDraggingFromSelf: false, hasSelfDragMarker: false, hasFileDrop: false, hasImage: true, hasText: true));
        Assert.Equal(DropSourceKind.Text, HistoryDrop.SelectDropSource(
            isDraggingFromSelf: false, hasSelfDragMarker: false, hasFileDrop: false, hasImage: false, hasText: true));
        Assert.Equal(DropSourceKind.None, HistoryDrop.SelectDropSource(
            isDraggingFromSelf: false, hasSelfDragMarker: false, hasFileDrop: false, hasImage: false, hasText: false));
    }

    [Fact]
    public void PlanFileDropsEnforcesSizeCountDirectoryFilenameAndAvailabilityLimits()
    {
        var entries = new List<DroppedFileEntry>
        {
            new(@"C:\tmp\empty.bin", "empty.bin", Exists: true, IsDirectoryOrReparsePoint: false, Length: 0),
            new(@"C:\tmp\exact10m.bin", "exact10m.bin", Exists: true, IsDirectoryOrReparsePoint: false, Length: SyncProtocol.MaxItemBytes),
            new(@"C:\tmp\too-big.bin", "too-big.bin", Exists: true, IsDirectoryOrReparsePoint: false, Length: SyncProtocol.MaxItemBytes + 1),
            new(@"C:\tmp\folder", "folder", Exists: true, IsDirectoryOrReparsePoint: true, Length: 0),
            new(@"C:\tmp\missing.bin", "missing.bin", Exists: false, IsDirectoryOrReparsePoint: false, Length: 10),
            new(@"C:\tmp\bad", "bad\nname.txt", Exists: true, IsDirectoryOrReparsePoint: false, Length: 10),
            new(@"C:\tmp\long", new string('a', 1025), Exists: true, IsDirectoryOrReparsePoint: false, Length: 10),
        };

        for (var i = 0; i < SyncProtocol.MaxFilesPerCopy; i++)
            entries.Add(new($@"C:\tmp\ok-{i}.txt", $"ok-{i}.txt", Exists: true, IsDirectoryOrReparsePoint: false, Length: 100));

        var plan = HistoryDrop.PlanFileDrops(entries);

        Assert.Equal(SyncProtocol.MaxFilesPerCopy, plan.Accepted.Count);
        Assert.Equal("empty.bin", plan.Accepted[0].FileName);
        Assert.Equal("exact10m.bin", plan.Accepted[1].FileName);
        Assert.Equal("ok-7.txt", plan.Accepted[^1].FileName);
        Assert.Equal(1, plan.TooLargeCount);
        Assert.Equal(1, plan.DirectoryOrLinkCount);
        Assert.Equal(1, plan.UnavailableCount);
        Assert.Equal(2, plan.InvalidOrEmptyCount);
        Assert.Equal(2, plan.TooManyFilesCount);
    }

    [Fact]
    public void ImageAndTextLimitsEnforceProtocolBoundariesWithoutOverflow()
    {
        Assert.False(HistoryDrop.IsImageWithinPixelLimit(0, 100));
        Assert.False(HistoryDrop.IsImageWithinPixelLimit(100, -1));
        Assert.True(HistoryDrop.IsImageWithinPixelLimit(8_000, 5_000));
        Assert.False(HistoryDrop.IsImageWithinPixelLimit(8_001, 5_000));
        Assert.False(HistoryDrop.IsImageWithinPixelLimit(int.MaxValue, int.MaxValue));

        Assert.False(HistoryDrop.IsImageWithinByteLimit(0));
        Assert.True(HistoryDrop.IsImageWithinByteLimit(1));
        Assert.True(HistoryDrop.IsImageWithinByteLimit(SyncProtocol.MaxItemBytes));
        Assert.False(HistoryDrop.IsImageWithinByteLimit(SyncProtocol.MaxItemBytes + 1));

        Assert.Equal(new TextDropEvaluation(false, DropSkipReason.InvalidFormatOrEmpty), HistoryDrop.EvaluateTextDrop(null));
        Assert.Equal(new TextDropEvaluation(false, DropSkipReason.InvalidFormatOrEmpty), HistoryDrop.EvaluateTextDrop(""));
        Assert.Equal(new TextDropEvaluation(true, DropSkipReason.None), HistoryDrop.EvaluateTextDrop("   "));
        Assert.Equal(new TextDropEvaluation(true, DropSkipReason.None), HistoryDrop.EvaluateTextDrop(new string('a', SyncProtocol.MaxPlaintextBytes)));
        Assert.Equal(new TextDropEvaluation(false, DropSkipReason.TooLarge), HistoryDrop.EvaluateTextDrop(new string('a', SyncProtocol.MaxPlaintextBytes + 1)));
    }

    [Fact]
    public void FormatDropNoticeCoversSuccessLimitAndUnsupportedCasesWithoutSensitiveData()
    {
        Assert.Null(HistoryDrop.FormatDropNotice(new(0, 0, 0, 0, 0, 0, 0)));

        var oneAdded = HistoryDrop.FormatDropNotice(new(1, 0, 0, 0, 0, 0, 0));
        Assert.NotNull(oneAdded);
        Assert.False(oneAdded!.Value.IsWarning);

        var multiAdded = HistoryDrop.FormatDropNotice(new(3, 0, 0, 0, 0, 0, 0));
        Assert.NotNull(multiAdded);
        Assert.False(multiAdded!.Value.IsWarning);
        Assert.Contains("3件", multiAdded.Value.Message);

        var partialLarge = HistoryDrop.FormatDropNotice(new(2, 1, 0, 0, 0, 0, 0));
        Assert.True(partialLarge!.Value.IsWarning);
        Assert.Contains("2件", partialLarge.Value.Message);
        Assert.Contains("1件", partialLarge.Value.Message);

        var tooLargeAttachment = HistoryDrop.FormatDropNotice(new(0, 1, 0, 0, 0, 0, 0));
        Assert.True(tooLargeAttachment!.Value.IsWarning);
        Assert.Contains("10 MiB", tooLargeAttachment.Value.Message);

        var tooLargeText = HistoryDrop.FormatDropNotice(new(0, 1, 0, 0, 0, 0, 0, TextTooLarge: true));
        Assert.True(tooLargeText!.Value.IsWarning);
        Assert.DoesNotContain("10 MiB", tooLargeText.Value.Message);

        var folder = HistoryDrop.FormatDropNotice(new(0, 0, 0, 1, 0, 0, 0));
        Assert.True(folder!.Value.IsWarning);

        var unavailable = HistoryDrop.FormatDropNotice(new(0, 0, 0, 0, 0, 1, 0));
        Assert.True(unavailable!.Value.IsWarning);

        var invalid = HistoryDrop.FormatDropNotice(new(0, 0, 0, 0, 1, 0, 0));
        Assert.True(invalid!.Value.IsWarning);

        var tooManyPartial = HistoryDrop.FormatDropNotice(new(10, 0, 2, 0, 0, 0, 0));
        Assert.True(tooManyPartial!.Value.IsWarning);
        Assert.Contains("10件", tooManyPartial.Value.Message);
    }
}
