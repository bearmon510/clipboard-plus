using System.Text;
using ClipboardPlus.Sync;

namespace ClipboardPlus.Windows.Core;

public enum DropSourceKind
{
    None,
    FileDrop,
    Image,
    Text,
}

public enum DropSkipReason
{
    None,
    TooLarge,
    TooManyFiles,
    DirectoryOrLink,
    InvalidFormatOrEmpty,
    Unavailable,
}

public readonly record struct DroppedFileEntry(
    string FullPath,
    string FileName,
    bool Exists,
    bool IsDirectoryOrReparsePoint,
    long Length);

public readonly record struct FileDropPlan(
    IReadOnlyList<DroppedFileEntry> Accepted,
    int TooLargeCount,
    int TooManyFilesCount,
    int DirectoryOrLinkCount,
    int InvalidOrEmptyCount,
    int UnavailableCount);

public readonly record struct TextDropEvaluation(
    bool Accepted,
    DropSkipReason Reason);

public readonly record struct DropNoticeSummary(
    int Added,
    int TooLargeCount,
    int TooManyFilesCount,
    int DirectoryOrLinkCount,
    int InvalidOrEmptyCount,
    int UnavailableCount,
    int ProtocolSkippedCount,
    bool TextTooLarge = false)
{
    public int TotalSkipped =>
        TooLargeCount + TooManyFilesCount + DirectoryOrLinkCount +
        InvalidOrEmptyCount + UnavailableCount + ProtocolSkippedCount;
}

public readonly record struct DropNotice(string Message, bool IsWarning);

/// <summary>
/// Pure classification, limit validation, and user-facing notice rules for dropping
/// external files, images, and text into the history window.
/// </summary>
public static class HistoryDrop
{
    public const int MaxFilesPerDrop = SyncProtocol.MaxFilesPerCopy;
    public const int MaxAttachmentBytes = SyncProtocol.MaxItemBytes;
    public const long MaxImagePixels = SyncProtocol.MaxImagePixels;
    public const int MaxTextUtf8Bytes = SyncProtocol.MaxPlaintextBytes;

    public static DropSourceKind SelectDropSource(
        bool isDraggingFromSelf,
        bool hasSelfDragMarker,
        bool hasFileDrop,
        bool hasImage,
        bool hasText)
    {
        if (isDraggingFromSelf || hasSelfDragMarker)
            return DropSourceKind.None;
        if (hasFileDrop)
            return DropSourceKind.FileDrop;
        if (hasImage)
            return DropSourceKind.Image;
        if (hasText)
            return DropSourceKind.Text;
        return DropSourceKind.None;
    }

    public static FileDropPlan PlanFileDrops(IReadOnlyList<DroppedFileEntry> entries)
    {
        var accepted = new List<DroppedFileEntry>();
        var tooLarge = 0;
        var tooMany = 0;
        var dirOrLink = 0;
        var invalid = 0;
        var unavailable = 0;

        for (var i = 0; i < entries.Count; i++)
        {
            if (accepted.Count >= MaxFilesPerDrop)
            {
                tooMany += entries.Count - i;
                break;
            }

            var entry = entries[i];
            if (!entry.Exists)
            {
                unavailable++;
                continue;
            }
            if (entry.IsDirectoryOrReparsePoint)
            {
                dirOrLink++;
                continue;
            }
            if (entry.Length < 0 || entry.Length > MaxAttachmentBytes)
            {
                tooLarge++;
                continue;
            }
            if (!IsValidOfferFilename(entry.FileName))
            {
                invalid++;
                continue;
            }
            accepted.Add(entry);
        }

        return new FileDropPlan(accepted, tooLarge, tooMany, dirOrLink, invalid, unavailable);
    }

    public static bool IsValidOfferFilename(string? fileName)
    {
        if (string.IsNullOrEmpty(fileName))
            return false;
        if (fileName.Any(char.IsControl))
            return false;
        return Encoding.UTF8.GetByteCount(fileName) <= 1024;
    }

    public static bool IsImageWithinPixelLimit(long pixelWidth, long pixelHeight)
    {
        if (pixelWidth <= 0 || pixelHeight <= 0)
            return false;
        return pixelWidth <= MaxImagePixels / pixelHeight;
    }

    public static bool IsImageWithinByteLimit(long byteLength) =>
        byteLength > 0 && byteLength <= MaxAttachmentBytes;

    public static TextDropEvaluation EvaluateTextDrop(string? text)
    {
        if (string.IsNullOrEmpty(text))
            return new TextDropEvaluation(false, DropSkipReason.InvalidFormatOrEmpty);
        if (Encoding.UTF8.GetByteCount(text) > MaxTextUtf8Bytes)
            return new TextDropEvaluation(false, DropSkipReason.TooLarge);
        return new TextDropEvaluation(true, DropSkipReason.None);
    }

    public static DropNotice? FormatDropNotice(DropNoticeSummary summary)
    {
        var totalSkipped = summary.TotalSkipped;
        if (summary.Added == 0 && totalSkipped == 0)
            return null;

        if (summary.Added > 0 && totalSkipped == 0)
        {
            var addedText = summary.Added == 1
                ? "履歴に追加しました"
                : $"{summary.Added}件を履歴に追加しました";
            return new DropNotice(addedText, IsWarning: false);
        }

        var largeCount = summary.TooLargeCount + summary.ProtocolSkippedCount;

        if (summary.Added > 0)
        {
            if (summary.TooManyFilesCount > 0 && totalSkipped == summary.TooManyFilesCount)
                return new DropNotice($"{summary.Added}件を追加しました（1回に{MaxFilesPerDrop}件まで）", IsWarning: true);
            if (largeCount > 0 && totalSkipped == largeCount)
                return new DropNotice($"{summary.Added}件を追加しました（上限を超える{largeCount}件は見送り）", IsWarning: true);
            return new DropNotice($"{summary.Added}件を追加しました（{totalSkipped}件は見送り）", IsWarning: true);
        }

        if (largeCount == totalSkipped)
        {
            return summary.TextTooLarge
                ? new DropNotice("文章が長すぎるため追加できませんでした", IsWarning: true)
                : new DropNotice("大きさの上限（10 MiB）を超えるため追加できませんでした", IsWarning: true);
        }
        if (summary.DirectoryOrLinkCount == totalSkipped)
            return new DropNotice("フォルダは追加できません", IsWarning: true);
        if (summary.UnavailableCount == totalSkipped)
            return new DropNotice("ファイルを読み込めませんでした", IsWarning: true);
        if (summary.InvalidOrEmptyCount == totalSkipped)
            return new DropNotice("この形式は追加できません", IsWarning: true);
        return new DropNotice("追加できない項目がありました（上限や非対応の形式）", IsWarning: true);
    }
}
