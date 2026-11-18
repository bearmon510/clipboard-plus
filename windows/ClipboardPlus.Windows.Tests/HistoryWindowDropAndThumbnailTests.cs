using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using Xunit;
using DataFormats = System.Windows.DataFormats;
using DataObject = System.Windows.DataObject;

namespace ClipboardPlus.Windows.Tests;

public sealed class HistoryWindowDropAndThumbnailTests : IDisposable
{
    private readonly string tempDir = Path.Combine(Path.GetTempPath(), "clipboardplus-drop-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { if (Directory.Exists(tempDir)) Directory.Delete(tempDir, recursive: true); }
        catch { }
    }

    private static void RunSta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try { action(); }
            catch (Exception ex) { failure = ex; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null)
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
    }

    private static byte[] MakePng(int width, int height)
    {
        var stride = width * 4;
        var pixels = new byte[stride * height];
        for (var i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = 40;
            pixels[i + 1] = 120;
            pixels[i + 2] = 220;
            pixels[i + 3] = 255;
        }
        var source = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, stride);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(source));
        using var output = new MemoryStream();
        encoder.Save(output);
        return output.ToArray();
    }

    private static byte[] MakeDib(int width, int height)
    {
        var stride = width * 4;
        var pixels = new byte[stride * height];
        for (var i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = 10;
            pixels[i + 1] = 200;
            pixels[i + 2] = 50;
            pixels[i + 3] = 255;
        }
        var source = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, stride);
        var encoder = new BmpBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(source));
        using var bmp = new MemoryStream();
        encoder.Save(bmp);
        var bmpBytes = bmp.ToArray();
        return bmpBytes[14..];
    }

    [Fact]
    public void HistoryRowDownscalesLargeThumbnailsKeepsAspectRatioAndAllowsDeletion()
    {
        Directory.CreateDirectory(tempDir);
        var largePath = Path.Combine(tempDir, "large.png");
        var smallPath = Path.Combine(tempDir, "small.png");
        var widePath = Path.Combine(tempDir, "wide.png");
        File.WriteAllBytes(largePath, MakePng(600, 400));
        File.WriteAllBytes(smallPath, MakePng(4, 3));
        File.WriteAllBytes(widePath, MakePng(1200, 100));

        RunSta(() =>
        {
            var now = DateTimeOffset.UtcNow;
            var largeRow = new HistoryRow(new HistoryItem(Guid.NewGuid(), "image", null, null, largePath, 100, now.ToUnixTimeMilliseconds(), "iPad", new string('a', 64), "public.png"), now);
            Assert.Equal(Visibility.Visible, largeRow.ThumbnailVisibility);
            Assert.Equal(Visibility.Collapsed, largeRow.ImageFallbackVisibility);
            Assert.Equal(Visibility.Collapsed, largeRow.PlainTitleVisibility);

            var largeThumb = Assert.IsAssignableFrom<BitmapSource>(largeRow.Thumbnail);
            Assert.Equal(HistoryRow.ThumbnailDecodeHeight, largeThumb.PixelHeight);
            Assert.Equal(420, largeThumb.PixelWidth);

            // Stream was closed and shared for delete, so cleanup succeeds immediately.
            File.Delete(largePath);
            Assert.False(File.Exists(largePath));

            var smallRow = new HistoryRow(new HistoryItem(Guid.NewGuid(), "image", null, null, smallPath, 50, now.ToUnixTimeMilliseconds(), "PC", new string('b', 64), "public.png"), now);
            var smallThumb = Assert.IsAssignableFrom<BitmapSource>(smallRow.Thumbnail);
            Assert.Equal(4, smallThumb.PixelWidth);
            Assert.Equal(3, smallThumb.PixelHeight);

            var wideRow = new HistoryRow(new HistoryItem(Guid.NewGuid(), "image", null, null, widePath, 100, now.ToUnixTimeMilliseconds(), "PC", new string('c', 64), "public.png"), now);
            var wideThumb = Assert.IsAssignableFrom<BitmapSource>(wideRow.Thumbnail);
            Assert.Equal(HistoryRow.ThumbnailMaxDecodeWidth, wideThumb.PixelWidth);
            Assert.Equal(60, wideThumb.PixelHeight);
        });
    }

    [Fact]
    public void HistoryRowFallsBackToIconWhenImageIsCorruptOrMissing()
    {
        Directory.CreateDirectory(tempDir);
        var corruptPath = Path.Combine(tempDir, "corrupt.png");
        File.WriteAllBytes(corruptPath, [1, 2, 3, 4, 5]);

        RunSta(() =>
        {
            var now = DateTimeOffset.UtcNow;
            var corruptRow = new HistoryRow(new HistoryItem(Guid.NewGuid(), "image", null, "broken.png", corruptPath, 5, now.ToUnixTimeMilliseconds(), "PC", new string('d', 64), "public.png"), now);
            Assert.Null(corruptRow.Thumbnail);
            Assert.Equal(Visibility.Collapsed, corruptRow.ThumbnailVisibility);
            Assert.Equal(Visibility.Visible, corruptRow.ImageFallbackVisibility);
            Assert.Equal(Visibility.Visible, corruptRow.PlainTitleVisibility);
            Assert.Equal("broken.png", corruptRow.Title);
        });
    }

    [Fact]
    public void DetectDropSourceRejectsSelfDragAndRespectsFormatPriority()
    {
        RunSta(() =>
        {
            var logs = new List<string>();
            var selfItem = new HistoryItem(Guid.NewGuid(), "text", "internal", null, null, 8, 100, "PC", new string('e', 64), "public.utf8-plain-text");
            var selfData = HistoryWindow.BuildDragDataObject(selfItem, Path.Combine(tempDir, "drag"), logs.Add);
            Assert.NotNull(selfData);
            Assert.Equal(DropSourceKind.None, HistoryWindow.DetectDropSource(selfData, isDraggingFromSelf: false));

            var externalFileAndText = new DataObject();
            externalFileAndText.SetData(DataFormats.FileDrop, new[] { Path.Combine(tempDir, "a.txt") });
            externalFileAndText.SetData(DataFormats.UnicodeText, "fallback");
            Assert.Equal(DropSourceKind.FileDrop, HistoryWindow.DetectDropSource(externalFileAndText, isDraggingFromSelf: false));
            Assert.Equal(DropSourceKind.None, HistoryWindow.DetectDropSource(externalFileAndText, isDraggingFromSelf: true));

            var externalImageAndText = new DataObject();
            externalImageAndText.SetData("PNG", new MemoryStream(MakePng(2, 2)));
            externalImageAndText.SetData(DataFormats.UnicodeText, "https://example.com/a.png");
            Assert.Equal(DropSourceKind.Image, HistoryWindow.DetectDropSource(externalImageAndText, isDraggingFromSelf: false));

            var externalText = new DataObject();
            externalText.SetData(DataFormats.UnicodeText, "hello drop");
            Assert.Equal(DropSourceKind.Text, HistoryWindow.DetectDropSource(externalText, isDraggingFromSelf: false));
        });
    }

    [Fact]
    public void ReadDroppedFilesReadsUpToLimitAndSkipsOversizedDirectoriesAndMissing()
    {
        Directory.CreateDirectory(tempDir);
        var subDir = Path.Combine(tempDir, "folder");
        Directory.CreateDirectory(subDir);

        var paths = new List<string> { subDir, Path.Combine(tempDir, "does-not-exist.txt") };

        var oversizedPath = Path.Combine(tempDir, "secret-oversized.bin");
        using (var fs = File.Create(oversizedPath))
            fs.SetLength(SyncProtocol.MaxItemBytes + 1);
        paths.Add(oversizedPath);

        var exactMaxPath = Path.Combine(tempDir, "exact-max.bin");
        using (var fs = File.Create(exactMaxPath))
            fs.SetLength(SyncProtocol.MaxItemBytes);
        paths.Add(exactMaxPath);

        for (var i = 0; i < SyncProtocol.MaxFilesPerCopy; i++)
        {
            var filePath = Path.Combine(tempDir, $"sample-{i}.txt");
            File.WriteAllText(filePath, $"body-{i}");
            paths.Add(filePath);
        }

        var result = HistoryWindow.ReadDroppedFiles(paths);

        Assert.Equal(SyncProtocol.MaxFilesPerCopy, result.Contents.Count);
        Assert.Equal("exact-max.bin", result.Contents[0].Filename);
        Assert.Equal(SyncProtocol.MaxItemBytes, result.Contents[0].Data!.Length);
        Assert.All(result.Contents, c => Assert.Equal("file", c.Kind));
        Assert.Equal(1, result.TooLargeCount);
        Assert.Equal(1, result.DirectoryOrLinkCount);
        Assert.Equal(1, result.UnavailableCount);
        Assert.Equal(1, result.TooManyFilesCount);
    }

    [Fact]
    public void ExtractNonFileDropHandlesPngDibBitmapAndTextLimits()
    {
        RunSta(() =>
        {
            var pngData = new DataObject();
            pngData.SetData("PNG", new MemoryStream(MakePng(5, 4)));
            var pngExtracted = HistoryWindow.ExtractNonFileDrop(pngData, DropSourceKind.Image);
            var pngContent = Assert.Single(pngExtracted.Contents);
            Assert.Equal("image", pngContent.Kind);
            Assert.Equal("public.png", pngContent.Type);
            Assert.NotEmpty(pngContent.Data!);

            var oversizedPngData = new DataObject();
            oversizedPngData.SetData("PNG", new MemoryStream(new byte[SyncProtocol.MaxItemBytes + 1]));
            var oversizedPngExtracted = HistoryWindow.ExtractNonFileDrop(oversizedPngData, DropSourceKind.Image);
            Assert.Empty(oversizedPngExtracted.Contents);
            Assert.Equal(1, oversizedPngExtracted.TooLargeCount);

            var dibData = new DataObject();
            dibData.SetData(DataFormats.Dib, new MemoryStream(MakeDib(3, 2)));
            var dibExtracted = HistoryWindow.ExtractNonFileDrop(dibData, DropSourceKind.Image);
            Assert.Equal("image", Assert.Single(dibExtracted.Contents).Kind);

            var bitmapSource = BitmapSource.Create(4, 3, 96, 96, PixelFormats.Bgra32, null, new byte[4 * 3 * 4], 4 * 4);
            var bmpData = new DataObject();
            bmpData.SetData(DataFormats.Bitmap, bitmapSource);
            var bmpExtracted = HistoryWindow.ExtractNonFileDrop(bmpData, DropSourceKind.Image);
            Assert.Equal("image", Assert.Single(bmpExtracted.Contents).Kind);

            const int bigW = 40_001;
            const int bigH = 1_000;
            var bigStride = (bigW + 7) / 8;
            var hugeBitmap = BitmapSource.Create(bigW, bigH, 96, 96, PixelFormats.BlackWhite, null, new byte[bigStride * bigH], bigStride);
            var hugeBmpData = new DataObject();
            hugeBmpData.SetData(DataFormats.Bitmap, hugeBitmap);
            var hugeBmpExtracted = HistoryWindow.ExtractNonFileDrop(hugeBmpData, DropSourceKind.Image);
            Assert.Empty(hugeBmpExtracted.Contents);
            Assert.Equal(1, hugeBmpExtracted.TooLargeCount);

            var textData = new DataObject();
            textData.SetData(DataFormats.UnicodeText, "dropped text");
            var textExtracted = HistoryWindow.ExtractNonFileDrop(textData, DropSourceKind.Text);
            Assert.Equal("dropped text", Assert.Single(textExtracted.Contents).Text);

            var bigTextData = new DataObject();
            bigTextData.SetData(DataFormats.UnicodeText, new string('t', SyncProtocol.MaxPlaintextBytes + 1));
            var bigTextExtracted = HistoryWindow.ExtractNonFileDrop(bigTextData, DropSourceKind.Text);
            Assert.Empty(bigTextExtracted.Contents);
            Assert.Equal(1, bigTextExtracted.TooLargeCount);
            Assert.True(bigTextExtracted.TextTooLarge);

            var emptyTextData = new DataObject();
            emptyTextData.SetData(DataFormats.UnicodeText, "");
            var emptyTextExtracted = HistoryWindow.ExtractNonFileDrop(emptyTextData, DropSourceKind.Text);
            Assert.Empty(emptyTextExtracted.Contents);
            Assert.Equal(1, emptyTextExtracted.InvalidOrEmptyCount);
        });
    }
}
