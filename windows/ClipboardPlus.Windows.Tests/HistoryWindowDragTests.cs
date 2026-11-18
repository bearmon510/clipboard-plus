using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ClipboardPlus.Windows.Core;
using Xunit;
using DataFormats = System.Windows.DataFormats;
using DataObject = System.Windows.DataObject;

namespace ClipboardPlus.Windows.Tests;

public sealed class HistoryWindowDragTests : IDisposable
{
    private readonly string tempDir = Path.Combine(Path.GetTempPath(), "clipboardplus-drag-tests", Guid.NewGuid().ToString("N"));

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
            pixels[i] = 200;
            pixels[i + 1] = 100;
            pixels[i + 2] = 50;
            pixels[i + 3] = 255;
        }
        var source = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, stride);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(source));
        using var output = new MemoryStream();
        encoder.Save(output);
        return output.ToArray();
    }

    [Fact]
    public void BuildDragDataObjectForTextProvidesUnicodeText()
    {
        RunSta(() =>
        {
            var logs = new List<string>();
            var item = new HistoryItem(Guid.NewGuid(), "text", "Hello clipboard+", null, null, 16, 100, "PC", new string('a', 64), "public.utf8-plain-text");

            var data = HistoryWindow.BuildDragDataObject(item, tempDir, logs.Add);

            Assert.NotNull(data);
            Assert.True(data!.GetDataPresent(DataFormats.UnicodeText));
            Assert.Equal("Hello clipboard+", data.GetText());
            Assert.Empty(logs);
        });
    }

    [Fact]
    public void BuildDragDataObjectForImageProvidesBothFileDropAndImageFormats()
    {
        Directory.CreateDirectory(tempDir);
        var bodyPath = Path.Combine(tempDir, new string('b', 64));
        var pngBytes = MakePng(4, 3);
        File.WriteAllBytes(bodyPath, pngBytes);
        var stagingRoot = Path.Combine(tempDir, "drag");

        RunSta(() =>
        {
            var logs = new List<string>();
            var item = new HistoryItem(Guid.NewGuid(), "image", null, "capture", bodyPath, pngBytes.Length, 100, "iPad", new string('b', 64), "public.png");

            var data = HistoryWindow.BuildDragDataObject(item, stagingRoot, logs.Add);

            Assert.NotNull(data);
            Assert.True(data!.ContainsFileDropList());
            var files = data.GetFileDropList();
            var droppedPath = Assert.Single(files.Cast<string>());
            Assert.EndsWith("capture.png", droppedPath);
            Assert.Equal(pngBytes, File.ReadAllBytes(droppedPath));

            Assert.True(data.GetDataPresent(DataFormats.Bitmap));
            Assert.True(data.GetDataPresent("PNG"));
            var bitmap = Assert.IsAssignableFrom<BitmapSource>(data.GetData(DataFormats.Bitmap));
            Assert.Equal(4, bitmap.PixelWidth);
            Assert.Equal(3, bitmap.PixelHeight);
            Assert.Empty(logs);
        });
    }

    [Fact]
    public void BuildDragDataObjectForFileStagesSafeFilenameInFileDrop()
    {
        Directory.CreateDirectory(tempDir);
        var bodyPath = Path.Combine(tempDir, new string('c', 64));
        var fileBytes = "sample file bytes"u8.ToArray();
        File.WriteAllBytes(bodyPath, fileBytes);
        var stagingRoot = Path.Combine(tempDir, "drag");

        RunSta(() =>
        {
            var logs = new List<string>();
            var item = new HistoryItem(Guid.NewGuid(), "file", null, "見積.pdf", bodyPath, fileBytes.Length, 100, "iPhone", new string('c', 64), "com.adobe.pdf");

            var data = HistoryWindow.BuildDragDataObject(item, stagingRoot, logs.Add);

            Assert.NotNull(data);
            Assert.True(data!.ContainsFileDropList());
            var files = data.GetFileDropList();
            var droppedPath = Assert.Single(files.Cast<string>());
            Assert.Equal("見積.pdf", Path.GetFileName(droppedPath));
            Assert.Equal(fileBytes, File.ReadAllBytes(droppedPath));
            Assert.Empty(logs);
        });
    }

    [Fact]
    public void BuildDragDataObjectReturnsNullWithoutLoggingPathsWhenBodyMissingOrCorrupt()
    {
        Directory.CreateDirectory(tempDir);
        var corruptPath = Path.Combine(tempDir, "secret-corrupt-name");
        File.WriteAllBytes(corruptPath, [1, 2, 3, 4]);
        var missingPath = Path.Combine(tempDir, "secret-missing-name");
        var stagingRoot = Path.Combine(tempDir, "drag");

        RunSta(() =>
        {
            var logs = new List<string>();
            var missing = new HistoryItem(Guid.NewGuid(), "file", null, "secret.txt", missingPath, 10, 100, "PC", new string('d', 64), "public.data");
            Assert.Null(HistoryWindow.BuildDragDataObject(missing, stagingRoot, logs.Add));

            var corruptImage = new HistoryItem(Guid.NewGuid(), "image", null, "secret.png", corruptPath, 4, 100, "PC", new string('e', 64), "public.png");
            Assert.Null(HistoryWindow.BuildDragDataObject(corruptImage, stagingRoot, logs.Add));
            Assert.All(logs, entry =>
            {
                Assert.DoesNotContain("secret", entry, StringComparison.OrdinalIgnoreCase);
                Assert.DoesNotContain(tempDir, entry, StringComparison.OrdinalIgnoreCase);
            });
        });
    }

    [Fact]
    public void HistoryRowPreparesLinkColorAndImageFallbackViewsCleanly()
    {
        RunSta(() =>
        {
            var now = DateTimeOffset.UtcNow;
            var linkRow = new HistoryRow(new HistoryItem(Guid.NewGuid(), "text", "https://example.com/a/b", null, null, 23, now.ToUnixTimeMilliseconds(), "PC", new string('1', 64), "public.utf8-plain-text"), now);
            Assert.Equal(HistoryDisplayFlavor.Link, linkRow.Flavor);
            Assert.Equal("example.com", linkRow.LinkHost);
            Assert.Equal("/a/b", linkRow.LinkRemainder);
            Assert.Equal(Visibility.Visible, linkRow.LinkVisibility);
            Assert.Equal(Visibility.Collapsed, linkRow.PlainTitleVisibility);

            var colorRow = new HistoryRow(new HistoryItem(Guid.NewGuid(), "text", "#2E6BF0", null, null, 7, now.ToUnixTimeMilliseconds(), "PC", new string('2', 64), "public.utf8-plain-text"), now);
            Assert.Equal(HistoryDisplayFlavor.Color, colorRow.Flavor);
            Assert.Equal(Visibility.Visible, colorRow.ColorSwatchVisibility);
            Assert.NotNull(colorRow.SwatchBrush);

            var brokenImageRow = new HistoryRow(new HistoryItem(Guid.NewGuid(), "image", null, null, Path.Combine(tempDir, "missing"), 10, now.ToUnixTimeMilliseconds(), "iPad", new string('3', 64), "public.png"), now);
            Assert.Equal(Visibility.Collapsed, brokenImageRow.ThumbnailVisibility);
            Assert.Equal(Visibility.Visible, brokenImageRow.ImageFallbackVisibility);
        });
    }

    [Fact]
    public void BuildDragDataObjectPassesRawPngBytesWithoutReencodingForPngItems()
    {
        Directory.CreateDirectory(tempDir);
        var bodyPath = Path.Combine(tempDir, new string('f', 64));
        var pngBytes = MakePng(4, 3);
        File.WriteAllBytes(bodyPath, pngBytes);
        var stagingRoot = Path.Combine(tempDir, "drag");

        RunSta(() =>
        {
            var logs = new List<string>();
            var item = new HistoryItem(Guid.NewGuid(), "image", null, "raw.png", bodyPath, pngBytes.Length, 100, "PC", new string('f', 64), "public.png");

            var data = HistoryWindow.BuildDragDataObject(item, stagingRoot, logs.Add);

            Assert.NotNull(data);
            var pngData = Assert.IsAssignableFrom<Stream>(data!.GetData("PNG"));
            using var copy = new MemoryStream();
            pngData.CopyTo(copy);
            Assert.Equal(pngBytes, copy.ToArray());
            Assert.Empty(logs);
        });
    }

    [Fact]
    public void BuildDragDataObjectReusesStagedFileByHashAndFallsBackToCopyWhenHardLinkFails()
    {
        Directory.CreateDirectory(tempDir);
        var hash = new string('1', 64);
        var bodyPath = Path.Combine(tempDir, hash);
        var payload = "hardlink and reuse payload"u8.ToArray();
        File.WriteAllBytes(bodyPath, payload);
        var stagingRoot = Path.Combine(tempDir, "drag");

        RunSta(() =>
        {
            var logs = new List<string>();
            var item = new HistoryItem(Guid.NewGuid(), "file", null, "memo.txt", bodyPath, payload.Length, 100, "PC", hash, "public.data");

            // First call uses default CreateHardLink on the same volume.
            var first = HistoryWindow.BuildDragDataObject(item, stagingRoot, logs.Add);
            Assert.NotNull(first);
            var firstPath = Assert.Single(first!.GetFileDropList().Cast<string>());
            Assert.Contains(hash, firstPath);
            Assert.Equal(payload, File.ReadAllBytes(firstPath));

            // Second call for the same hash reuses the existing staged file without linking or copying again.
            var linkAttempts = 0;
            var second = HistoryWindow.BuildDragDataObject(item, stagingRoot, logs.Add, (_, _) => { linkAttempts++; return false; });
            Assert.NotNull(second);
            var secondPath = Assert.Single(second!.GetFileDropList().Cast<string>());
            Assert.Equal(firstPath, secondPath);
            Assert.Equal(0, linkAttempts);

            // When staging a new hash and hard link fails (e.g., cross-volume), it falls back to copying.
            var otherHash = new string('2', 64);
            var otherBody = Path.Combine(tempDir, otherHash);
            File.WriteAllBytes(otherBody, payload);
            var otherItem = new HistoryItem(Guid.NewGuid(), "file", null, "other.txt", otherBody, payload.Length, 100, "PC", otherHash, "public.data");
            var fallbackAttempts = 0;
            var fallback = HistoryWindow.BuildDragDataObject(otherItem, stagingRoot, logs.Add, (_, _) => { fallbackAttempts++; return false; });
            Assert.NotNull(fallback);
            Assert.Equal(1, fallbackAttempts);
            var fallbackPath = Assert.Single(fallback!.GetFileDropList().Cast<string>());
            Assert.Equal(payload, File.ReadAllBytes(fallbackPath));
            Assert.Empty(logs);
        });
    }

    [Fact]
    public void PruneAndClearDragStagingRemoveDeletedOrAllStagedEntries()
    {
        var stagingRoot = Path.Combine(tempDir, "drag");
        var keepHash = new string('a', 64);
        var dropHash = new string('b', 64);
        Directory.CreateDirectory(Path.Combine(stagingRoot, keepHash));
        File.WriteAllText(Path.Combine(stagingRoot, keepHash, "keep.txt"), "keep");
        Directory.CreateDirectory(Path.Combine(stagingRoot, dropHash));
        File.WriteAllText(Path.Combine(stagingRoot, dropHash, "drop.txt"), "drop");

        var activeItem = new HistoryItem(Guid.NewGuid(), "file", null, "keep.txt", "ignored", 4, 100, "PC", keepHash, "public.data");
        HistoryWindow.PruneDragStaging(stagingRoot, [activeItem]);

        Assert.True(Directory.Exists(Path.Combine(stagingRoot, keepHash)));
        Assert.False(Directory.Exists(Path.Combine(stagingRoot, dropHash)));
        Assert.True(HistoryWindow.HasDragStagingEntries(stagingRoot));

        // Clearing history leaves only text (or empty) -> prune removes remaining staged hash.
        HistoryWindow.PruneDragStaging(stagingRoot, []);
        Assert.False(Directory.Exists(Path.Combine(stagingRoot, keepHash)));
        Assert.False(HistoryWindow.HasDragStagingEntries(stagingRoot));

        // Recreate and verify ClearDragStaging deletes the entire root.
        Directory.CreateDirectory(Path.Combine(stagingRoot, keepHash));
        HistoryWindow.ClearDragStaging(stagingRoot);
        Assert.False(Directory.Exists(stagingRoot));
    }

    [Fact]
    public void IsInsideButtonHandlesContentElementsWithoutThrowing()
    {
        RunSta(() =>
        {
            var runInside = new Run("操作");
            var insideText = new TextBlock(runInside);
            var button = new Button { Content = insideText };

            var runOutside = new Run("項目");
            var outsideText = new TextBlock(runOutside);

            Assert.True(HistoryWindow.IsInsideButton(runInside));
            Assert.True(HistoryWindow.IsInsideButton(button));
            Assert.False(HistoryWindow.IsInsideButton(runOutside));
            Assert.False(HistoryWindow.IsInsideButton(outsideText));
            Assert.False(HistoryWindow.IsInsideButton(null));
        });
    }
}
