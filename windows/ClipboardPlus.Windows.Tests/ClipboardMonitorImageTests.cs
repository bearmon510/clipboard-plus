using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using ClipboardPlus.Windows.Infrastructure;
using Xunit;

namespace ClipboardPlus.Windows.Tests;

public sealed class ClipboardMonitorImageTests
{
    private static byte[] MakePng(int width, int height, byte r = 10, byte g = 20, byte b = 30)
    {
        var stride = width * 4;
        var pixels = new byte[stride * height];
        for (var i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = b;
            pixels[i + 1] = g;
            pixels[i + 2] = r;
            pixels[i + 3] = 255;
        }
        var source = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, stride);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(source));
        using var output = new MemoryStream();
        encoder.Save(output);
        return output.ToArray();
    }

    private static byte[] MakeJpeg(int width, int height)
    {
        var source = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgr24, null, new byte[width * height * 3], width * 3);
        var encoder = new JpegBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(source));
        using var output = new MemoryStream();
        encoder.Save(output);
        return output.ToArray();
    }

    [Fact]
    public void LoadClipboardImageLoadsPixelsBeforeStreamClosesForPngAndJpeg()
    {
        var pngBytes = MakePng(2, 2, 120, 45, 200);
        BitmapFrame pngBitmap;
        using (var stream = new MemoryStream(pngBytes))
            pngBitmap = ClipboardMonitor.LoadClipboardImage(stream, "public.png");

        var reencoded = ClipboardMonitor.EncodeClipboardPng(pngBitmap);
        Assert.True(reencoded.Length > 0);
        var pixels = new byte[2 * 2 * 4];
        pngBitmap.CopyPixels(pixels, 2 * 4, 0);
        Assert.Equal(200, pixels[0]);
        Assert.Equal(45, pixels[1]);
        Assert.Equal(120, pixels[2]);

        var jpegBytes = MakeJpeg(3, 2);
        BitmapFrame jpegBitmap;
        using (var stream = new MemoryStream(jpegBytes))
            jpegBitmap = ClipboardMonitor.LoadClipboardImage(stream, "public.jpeg");

        Assert.Equal(3, jpegBitmap.PixelWidth);
        Assert.Equal(2, jpegBitmap.PixelHeight);
        Assert.True(ClipboardMonitor.EncodeClipboardPng(jpegBitmap).Length > 0);
    }

    [Fact]
    public void LoadClipboardImageRejectsFormatMismatchWithImageFormat()
    {
        var pngBytes = MakePng(2, 2);
        var jpegBytes = MakeJpeg(2, 2);

        using (var stream = new MemoryStream(jpegBytes))
        {
            var ex = Assert.Throws<ClipboardContentRejectedException>(() => ClipboardMonitor.LoadClipboardImage(stream, "public.png"));
            Assert.Equal(ClipboardRejectReason.ImageFormat, ex.Reason);
        }
        using (var stream = new MemoryStream(pngBytes))
        {
            var ex = Assert.Throws<ClipboardContentRejectedException>(() => ClipboardMonitor.LoadClipboardImage(stream, "public.jpeg"));
            Assert.Equal(ClipboardRejectReason.ImageFormat, ex.Reason);
        }
        using (var stream = new MemoryStream(pngBytes))
        {
            var ex = Assert.Throws<ClipboardContentRejectedException>(() => ClipboardMonitor.LoadClipboardImage(stream, "public.tiff"));
            Assert.Equal(ClipboardRejectReason.ImageFormat, ex.Reason);
        }
    }

    [Fact]
    public void LoadClipboardImageRejectsOversizedDimensionsBeforeDecode()
    {
        const int width = 40_001;
        const int height = 1_000; // 40,001,000 > SyncProtocol.MaxImagePixels (40,000,000)
        var stride = (width + 7) / 8;
        var source = BitmapSource.Create(width, height, 96, 96, PixelFormats.BlackWhite, null, new byte[stride * height], stride);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(source));
        using var encoded = new MemoryStream();
        encoder.Save(encoded);
        encoded.Position = 0;

        var ex = Assert.Throws<ClipboardContentRejectedException>(() => ClipboardMonitor.LoadClipboardImage(encoded, "public.png"));
        Assert.Equal(ClipboardRejectReason.ImageDimensions, ex.Reason);
    }

    [Theory]
    [InlineData(new byte[0])]
    [InlineData(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10, 0, 0 })]
    [InlineData(new byte[] { 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10 })]
    public void LoadClipboardImageRejectsCorruptStreamsWithImageCorrupt(byte[] bytes)
    {
        using var stream = new MemoryStream(bytes);
        var ex = Assert.Throws<ClipboardContentRejectedException>(() => ClipboardMonitor.LoadClipboardImage(stream, "public.png"));
        Assert.Equal(ClipboardRejectReason.ImageCorrupt, ex.Reason);
    }
}
