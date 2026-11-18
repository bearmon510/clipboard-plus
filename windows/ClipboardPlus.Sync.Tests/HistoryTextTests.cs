using ClipboardPlus.Windows.Core;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class HistoryTextTests
{
    private static HistoryItem Item(string kind, string? text = null, string? filename = null, string source = "PC", long at = 0) =>
        new(Guid.NewGuid(), kind, text, filename, null, 0, at, source, new string('a', 64), "public.data");

    [Fact]
    public void TextTitleKeepsTheFirstTwoNonEmptyLinesAndCutsLongOnes()
    {
        Assert.Equal("一行目\n二行目", HistoryText.Title(Item("text", "\n  一行目  \n\n二行目\n三行目")));
        Assert.Equal("（空白だけの文章）", HistoryText.Title(Item("text", " \n\t\n")));
        var title = HistoryText.Title(Item("text", new string('あ', 300)));
        Assert.Equal(HistoryText.MaxTitleLength + 1, title.Length);
        Assert.EndsWith("…", title);
        // An emoji straddling the cut is dropped whole rather than split into half a surrogate pair.
        var emoji = HistoryText.Title(Item("text", new string('a', HistoryText.MaxTitleLength - 1) + "😀😀"));
        Assert.Equal(new string('a', HistoryText.MaxTitleLength - 1) + "…", emoji);
    }

    [Fact]
    public void ImagesAndFilesUseTheirNameOrAWord()
    {
        Assert.Equal("画像", HistoryText.Title(Item("image", filename: "")));
        Assert.Equal("写真.png", HistoryText.Title(Item("image", filename: "写真.png")));
        Assert.Equal("ファイル", HistoryText.Title(Item("file")));
        Assert.Equal("見積.pdf", HistoryText.Title(Item("file", filename: "見積.pdf")));
    }

    [Fact]
    public void MetaNamesTheKindTheSourceAndHowLongAgo()
    {
        var now = new DateTimeOffset(2026, 11, 18, 3, 0, 0, TimeSpan.Zero);
        long Ago(TimeSpan span) => (now - span).ToUnixTimeMilliseconds();
        Assert.Equal("iPhone・たった今", HistoryText.Meta(Item("text", "a", source: "iPhone", at: Ago(TimeSpan.FromSeconds(20))), now));
        Assert.Equal("iPad・5分前", HistoryText.Meta(Item("image", source: "iPad", at: Ago(TimeSpan.FromMinutes(5.5))), now));
        Assert.Equal("画像・iPad・5分前", HistoryText.Meta(Item("image", filename: "写真.png", source: "iPad", at: Ago(TimeSpan.FromMinutes(5.5))), now));
        Assert.Equal("ファイル・PC・2時間前", HistoryText.Meta(Item("file", at: Ago(TimeSpan.FromHours(2.2))), now));
        // Anything unexpected in Source is shown as the PC rather than echoed.
        Assert.StartsWith("PC・", HistoryText.Meta(Item("text", "a", source: "C:\\secret", at: Ago(TimeSpan.Zero)), now));
        var old = now - TimeSpan.FromDays(3);
        Assert.Equal(old.ToLocalTime().ToString("MM/dd HH:mm", System.Globalization.CultureInfo.InvariantCulture),
            HistoryText.Ago(old, now));
    }

    [Fact]
    public void EmptyStateDependsOnTheSearch()
    {
        Assert.StartsWith("まだ履歴がありません", HistoryText.Empty(null));
        Assert.Equal("見つかりませんでした。", HistoryText.Empty("abc"));
        Assert.Equal("コピーすると、ここに並びます", HistoryText.EmptyTitle(null));
        Assert.Equal("コピーすると、ここに並びます", HistoryText.EmptyTitle("   "));
        Assert.Equal("見つかりませんでした", HistoryText.EmptyTitle("abc"));
        Assert.False(string.IsNullOrWhiteSpace(HistoryText.EmptyDetail(null)));
        Assert.False(string.IsNullOrWhiteSpace(HistoryText.EmptyDetail("abc")));
    }

    [Fact]
    public void DetectFlavorIdentifiesLinksColorsEmailsPhonesImagesAndFiles()
    {
        Assert.Equal(HistoryDisplayFlavor.Link, HistoryText.DetectFlavor(Item("text", "https://example.com/docs/guide?tab=1#top"), out var link, out _));
        Assert.Equal(new HistoryLinkParts("example.com", "/docs/guide?tab=1#top"), link);

        Assert.Equal(HistoryDisplayFlavor.Link, HistoryText.DetectFlavor(Item("text", "  http://localhost:8080/  "), out var rootLink, out _));
        Assert.Equal(new HistoryLinkParts("localhost:8080", null), rootLink);

        Assert.Equal(HistoryDisplayFlavor.Text, HistoryText.DetectFlavor(Item("text", "https://example.com\nsecond line")));
        Assert.Equal(HistoryDisplayFlavor.Text, HistoryText.DetectFlavor(Item("text", "ftp://example.com/file")));

        Assert.Equal(HistoryDisplayFlavor.Color, HistoryText.DetectFlavor(Item("text", "#2E6BF0"), out _, out var rgb));
        Assert.Equal(new HistoryRgbColor(0x2E, 0x6B, 0xF0), rgb);
        Assert.Equal(HistoryDisplayFlavor.Color, HistoryText.DetectFlavor(Item("text", "#F0A"), out _, out var shortRgb));
        Assert.Equal(new HistoryRgbColor(0xFF, 0x00, 0xAA), shortRgb);
        Assert.Equal(HistoryDisplayFlavor.Color, HistoryText.DetectFlavor(Item("text", "#10203080"), out _, out var rgba));
        Assert.Equal(new HistoryRgbColor(0x10, 0x20, 0x30), rgba);

        Assert.Equal(HistoryDisplayFlavor.Email, HistoryText.DetectFlavor(Item("text", "user+tag@example.co.jp")));
        Assert.Equal(HistoryDisplayFlavor.Phone, HistoryText.DetectFlavor(Item("text", "090-1234-5678")));
        Assert.Equal(HistoryDisplayFlavor.Phone, HistoryText.DetectFlavor(Item("text", "+81 3 1234 5678")));
        Assert.Equal(HistoryDisplayFlavor.Text, HistoryText.DetectFlavor(Item("text", "2026-11-18")));

        Assert.Equal(HistoryDisplayFlavor.Image, HistoryText.DetectFlavor(Item("image")));
        Assert.Equal(HistoryDisplayFlavor.File, HistoryText.DetectFlavor(Item("file", filename: "a.pdf")));
    }

    [Fact]
    public void FlavorGlyphReturnsDistinctIconsAndDragFileNameSanitizesAndPreservesExtensions()
    {
        var glyphs = Enum.GetValues<HistoryDisplayFlavor>().Select(HistoryText.FlavorGlyph).ToArray();
        Assert.Equal(glyphs.Length, glyphs.Distinct().Count());

        var png = new HistoryItem(Guid.NewGuid(), "image", null, null, null, 0, 0, "PC", new string('a', 64), "public.png");
        var jpg = new HistoryItem(Guid.NewGuid(), "image", null, "photo", null, 0, 0, "PC", new string('a', 64), "public.jpeg");
        var namedPng = new HistoryItem(Guid.NewGuid(), "image", null, "shot.PNG", null, 0, 0, "PC", new string('a', 64), "public.png");
        var reserved = new HistoryItem(Guid.NewGuid(), "file", null, "CON.txt", null, 0, 0, "PC", new string('a', 64), "public.data");
        var traversal = new HistoryItem(Guid.NewGuid(), "file", null, "../../secret:doc?.pdf", null, 0, 0, "PC", new string('a', 64), "public.data");

        Assert.Equal("image.png", HistoryText.DragFileName(png));
        Assert.Equal("photo.jpg", HistoryText.DragFileName(jpg));
        Assert.Equal("shot.PNG", HistoryText.DragFileName(namedPng));
        Assert.Equal("_CON.txt", HistoryText.DragFileName(reserved));
        Assert.DoesNotContain("/", HistoryText.DragFileName(traversal));
        Assert.DoesNotContain(":", HistoryText.DragFileName(traversal));
        Assert.EndsWith(".pdf", HistoryText.DragFileName(traversal));
    }

    [Fact]
    public void DragFileNamePreservesExtensionOnLongNamesAndGuardsSuperscriptReservedNames()
    {
        var longPdf = Item("file", filename: new string('a', 150) + ".pdf");
        var draggedPdf = HistoryText.DragFileName(longPdf);
        Assert.Equal(HistoryText.MaxDragFileNameLength, draggedPdf.Length);
        Assert.EndsWith(".pdf", draggedPdf);

        var longEmojiPdf = Item("file", filename: new string('a', HistoryText.MaxDragFileNameLength - 5) + "😀😀.pdf");
        var draggedEmojiPdf = HistoryText.DragFileName(longEmojiPdf);
        Assert.Equal(new string('a', HistoryText.MaxDragFileNameLength - 5) + ".pdf", draggedEmojiPdf);

        var longImageNoExt = new HistoryItem(Guid.NewGuid(), "image", null, new string('b', 150), null, 0, 0, "PC", new string('a', 64), "public.png");
        var draggedImage = HistoryText.DragFileName(longImageNoExt);
        Assert.Equal(HistoryText.MaxDragFileNameLength, draggedImage.Length);
        Assert.EndsWith(".png", draggedImage);

        foreach (var name in new[] { "COM¹.txt", "com².pdf", "COM³", "LPT¹.log", "lpt².dat", "LPT³", "CON  .txt" })
        {
            var dragged = HistoryText.DragFileName(Item("file", filename: name));
            Assert.StartsWith("_", dragged);
        }

        var longReserved = HistoryText.DragFileName(Item("file", filename: "CON." + new string('x', 150) + ".pdf"));
        Assert.StartsWith("_CON.", longReserved);
        Assert.EndsWith(".pdf", longReserved);
        Assert.Equal(HistoryText.MaxDragFileNameLength, longReserved.Length);
    }

    [Fact]
    public void LinkRemainderIsCappedWithoutSplittingSurrogatePairs()
    {
        var longUrl = "https://example.com/" + new string('a', 300);
        Assert.Equal(HistoryDisplayFlavor.Link, HistoryText.DetectFlavor(Item("text", longUrl), out var link, out _));
        Assert.NotNull(link);
        Assert.NotNull(link!.Value.Remainder);
        Assert.Equal(HistoryText.MaxLinkRemainderLength + 1, link.Value.Remainder!.Length);
        Assert.EndsWith("…", link.Value.Remainder);

        var unicodeUrl = "https://example.com/" + new string('a', HistoryText.MaxLinkRemainderLength - 2) + "😀😀";
        Assert.Equal(HistoryDisplayFlavor.Link, HistoryText.DetectFlavor(Item("text", unicodeUrl), out var unicodeLink, out _));
        Assert.NotNull(unicodeLink!.Value.Remainder);
        Assert.True(unicodeLink.Value.Remainder!.Length <= HistoryText.MaxLinkRemainderLength + 1);
        Assert.EndsWith("…", unicodeLink.Value.Remainder);
        Assert.DoesNotContain(unicodeLink.Value.Remainder, char.IsSurrogate);

        var prefix = "/" + new string('a', HistoryText.MaxLinkRemainderLength - 2);
        Assert.Equal(prefix + "…", HistoryText.TruncateWithEllipsis(prefix + "😀😀", HistoryText.MaxLinkRemainderLength));
    }
}
