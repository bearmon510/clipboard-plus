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
    }
}
