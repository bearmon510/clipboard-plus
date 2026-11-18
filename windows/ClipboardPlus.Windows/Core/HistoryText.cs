using System.Globalization;
using System.Text.RegularExpressions;

namespace ClipboardPlus.Windows.Core;

public enum HistoryDisplayFlavor
{
    Text,
    Link,
    Email,
    Phone,
    Color,
    Image,
    File,
}

public readonly record struct HistoryLinkParts(string Host, string? Remainder);

public readonly record struct HistoryRgbColor(byte Red, byte Green, byte Blue);

/// <summary>Wording and display classification for the history window, kept apart from WPF so it can be tested.</summary>
public static partial class HistoryText
{
    public const int MaxTitleLength = 120;

    private static readonly HashSet<string> ReservedWindowsNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    [GeneratedRegex(@"^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")]
    private static partial Regex EmailRegex();

    [GeneratedRegex(@"^[+0][0-9 ()-]{8,18}$")]
    private static partial Regex PhoneRegex();

    [GeneratedRegex(@"^#[0-9A-Fa-f]+$")]
    private static partial Regex HexColorRegex();

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

    public static HistoryDisplayFlavor DetectFlavor(HistoryItem item) => DetectFlavor(item, out _, out _);

    public static HistoryDisplayFlavor DetectFlavor(
        HistoryItem item,
        out HistoryLinkParts? link,
        out HistoryRgbColor? color)
    {
        link = null;
        color = null;

        switch (item.Kind)
        {
            case "image":
                return HistoryDisplayFlavor.Image;
            case "file":
                return HistoryDisplayFlavor.File;
            default:
                var trimmed = (item.Text ?? "").Trim();
                if (trimmed.Length == 0) return HistoryDisplayFlavor.Text;

                if (TrySplitLink(trimmed, out var parsedLink))
                {
                    link = parsedLink;
                    return HistoryDisplayFlavor.Link;
                }

                if (trimmed.Length <= 64)
                {
                    if (TryParseHexColor(trimmed, out var parsedColor))
                    {
                        color = parsedColor;
                        return HistoryDisplayFlavor.Color;
                    }
                    if (EmailRegex().IsMatch(trimmed))
                        return HistoryDisplayFlavor.Email;
                    if (IsPhoneNumber(trimmed))
                        return HistoryDisplayFlavor.Phone;
                }

                return HistoryDisplayFlavor.Text;
        }
    }

    public static string FlavorGlyph(HistoryDisplayFlavor flavor) => flavor switch
    {
        HistoryDisplayFlavor.Link => "\uE71B",
        HistoryDisplayFlavor.Email => "\uE715",
        HistoryDisplayFlavor.Phone => "\uE717",
        HistoryDisplayFlavor.Color => "\uE790",
        HistoryDisplayFlavor.Image => "\uE8B9",
        HistoryDisplayFlavor.File => "\uE8A5",
        _ => "\uE8E4",
    };

    public static string DragFileName(HistoryItem item)
    {
        if (item.Kind == "image")
        {
            var expectedExt = item.Type == "public.jpeg" ? ".jpg" : ".png";
            if (string.IsNullOrWhiteSpace(item.Filename))
                return "image" + expectedExt;

            var safe = SafeDragFileName(item.Filename, "image");
            var ext = Path.GetExtension(safe);
            var validExt = item.Type == "public.jpeg"
                ? ext.Equals(".jpg", StringComparison.OrdinalIgnoreCase) || ext.Equals(".jpeg", StringComparison.OrdinalIgnoreCase)
                : ext.Equals(".png", StringComparison.OrdinalIgnoreCase);
            return validExt ? safe : safe + expectedExt;
        }

        return SafeDragFileName(item.Filename, "file");
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

    public static string EmptyTitle(string? search) =>
        string.IsNullOrWhiteSpace(search) ? "コピーすると、ここに並びます" : "見つかりませんでした";

    public static string EmptyDetail(string? search) =>
        string.IsNullOrWhiteSpace(search)
            ? "ほかのアプリで文章や画像、ファイルをコピーしてみてください。"
            : "検索語を変えるか、検索をクリアしてください。";

    private static bool TrySplitLink(string trimmed, out HistoryLinkParts link)
    {
        link = default;
        if (trimmed.Any(char.IsWhiteSpace)) return false;
        if (!trimmed.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
            !trimmed.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            return false;
        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var uri)) return false;
        if ((uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps) ||
            string.IsNullOrEmpty(uri.Host))
            return false;

        var host = uri.IsDefaultPort ? uri.Host : FormattableString.Invariant($"{uri.Host}:{uri.Port}");
        var remainder = uri.PathAndQuery + uri.Fragment;
        link = new HistoryLinkParts(host, string.IsNullOrEmpty(remainder) || remainder == "/" ? null : remainder);
        return true;
    }

    private static bool TryParseHexColor(string value, out HistoryRgbColor color)
    {
        color = default;
        if (!HexColorRegex().IsMatch(value)) return false;

        var digits = value[1..];
        if (digits.Length == 3)
            digits = string.Concat(digits[0], digits[0], digits[1], digits[1], digits[2], digits[2]);

        if (digits.Length is not (6 or 8)) return false;

        if (!byte.TryParse(digits[..2], NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var r) ||
            !byte.TryParse(digits[2..4], NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var g) ||
            !byte.TryParse(digits[4..6], NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var b))
            return false;

        color = new HistoryRgbColor(r, g, b);
        return true;
    }

    private static bool IsPhoneNumber(string value)
    {
        if (!PhoneRegex().IsMatch(value)) return false;
        var digits = value.Count(char.IsAsciiDigit);
        return digits is >= 10 and <= 15;
    }

    private static string SafeDragFileName(string? rawName, string fallback)
    {
        var safe = string.IsNullOrWhiteSpace(rawName) ? fallback : SyncRepository.SafeFilename(rawName);
        var dot = safe.IndexOf('.');
        var stem = dot >= 0 ? safe[..dot] : safe;
        return ReservedWindowsNames.Contains(stem) ? "_" + safe : safe;
    }
}
