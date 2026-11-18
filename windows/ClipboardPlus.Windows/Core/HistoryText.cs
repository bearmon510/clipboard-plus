using System.Globalization;

namespace ClipboardPlus.Windows.Core;

/// <summary>Wording for the history window, kept apart from WPF so it can be tested.</summary>
public static class HistoryText
{
    public const int MaxTitleLength = 120;

    /// <summary>The first lines of a text, a file's name, or a word for an image.</summary>
    public static string Title(HistoryItem item)
    {
        switch (item.Kind)
        {
            case "text":
                var lines = (item.Text ?? "")
                    .Split('\n')
                    .Select(line => line.Trim())
                    .Where(line => line.Length > 0)
                    .Take(2);
                var joined = string.Join("\n", lines);
                if (joined.Length == 0) return "（空白だけの文章）";
                if (joined.Length <= MaxTitleLength) return joined;
                // Never split a surrogate pair (an emoji, say) at the cut.
                var cut = char.IsHighSurrogate(joined[MaxTitleLength - 1]) ? MaxTitleLength - 1 : MaxTitleLength;
                return joined[..cut] + "…";
            case "image":
                return string.IsNullOrWhiteSpace(item.Filename) ? "画像" : item.Filename!;
            default:
                return string.IsNullOrWhiteSpace(item.Filename) ? "ファイル" : item.Filename!;
        }
    }

    /// <summary>"iPhone・3分前": where it came from and how long ago.</summary>
    public static string Meta(HistoryItem item, DateTimeOffset now)
    {
        var source = item.Source is "iPhone" or "iPad" ? item.Source : "PC";
        // An unnamed image is already titled "画像", so the kind is not repeated.
        var kind = item.Kind switch
        {
            "image" when !string.IsNullOrWhiteSpace(item.Filename) => "画像・",
            "file" => "ファイル・",
            _ => "",
        };
        return $"{kind}{source}・{Ago(DateTimeOffset.FromUnixTimeMilliseconds(item.At), now)}";
    }

    public static string Ago(DateTimeOffset at, DateTimeOffset now)
    {
        var elapsed = now - at;
        if (elapsed < TimeSpan.FromMinutes(1)) return "たった今";
        if (elapsed < TimeSpan.FromHours(1)) return $"{(int)elapsed.TotalMinutes}分前";
        if (elapsed < TimeSpan.FromDays(1)) return $"{(int)elapsed.TotalHours}時間前";
        return at.ToLocalTime().ToString("MM/dd HH:mm", CultureInfo.InvariantCulture);
    }

    public static string Empty(string? search) =>
        string.IsNullOrWhiteSpace(search) ? "まだ履歴がありません。コピーすると、ここに並びます。" : "見つかりませんでした。";
}
