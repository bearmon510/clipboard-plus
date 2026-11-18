using System.Globalization;

namespace ClipboardPlus.Windows.Core;

public enum HotkeyModifier
{
    Win,
    Ctrl,
    Alt,
    Shift,
}

/// <summary>Two-key global shortcut: one modifier plus one non-modifier virtual key.</summary>
public readonly record struct HotkeyChord(HotkeyModifier Modifier, int VirtualKey)
{
    private readonly record struct KeyInfo(int VirtualKey, string SaveName, string DisplayName, string[] Aliases);

    private static readonly KeyInfo[] KnownKeys = BuildKnownKeys();
    private static readonly Dictionary<int, KeyInfo> KeysByVk = KnownKeys.ToDictionary(k => k.VirtualKey);
    private static readonly Dictionary<string, int> KeysByName = BuildKeysByName();

    public static HotkeyChord Default => new(HotkeyModifier.Win, 0x56); // Win + V

    public bool IsValid => Enum.IsDefined(Modifier) && IsValidTriggerKey(VirtualKey);

    public string DisplayName => $"{ModifierName(Modifier)} + {KeyDisplayName(VirtualKey)}";

    public override string ToString() => $"{ModifierName(Modifier)}+{KeySaveName(VirtualKey)}";

    public static bool IsModifierKey(int virtualKey) => TryGetModifier(virtualKey, out _);

    public static bool IsValidTriggerKey(int virtualKey) =>
        virtualKey is >= 0x01 and <= 0xFE &&
        virtualKey is not (0x01 or 0x02 or 0x04 or 0x05 or 0x06) &&
        !IsModifierKey(virtualKey);

    public static bool TryGetModifier(int virtualKey, out HotkeyModifier modifier)
    {
        switch (virtualKey)
        {
            case 0x5B:
            case 0x5C:
                modifier = HotkeyModifier.Win;
                return true;
            case 0x11:
            case 0xA2:
            case 0xA3:
                modifier = HotkeyModifier.Ctrl;
                return true;
            case 0x12:
            case 0xA4:
            case 0xA5:
                modifier = HotkeyModifier.Alt;
                return true;
            case 0x10:
            case 0xA0:
            case 0xA1:
                modifier = HotkeyModifier.Shift;
                return true;
            default:
                modifier = default;
                return false;
        }
    }

    public static bool TryParse(string? text, out HotkeyChord chord)
    {
        chord = default;
        if (string.IsNullOrWhiteSpace(text)) return false;

        var plus = text.IndexOf('+');
        if (plus <= 0 || plus == text.Length - 1) return false;

        var modPart = text[..plus].Trim();
        var keyPart = text[(plus + 1)..].Trim();
        if (!TryParseModifier(modPart, out var modifier) || !TryParseKey(keyPart, out var virtualKey))
            return false;

        var candidate = new HotkeyChord(modifier, virtualKey);
        if (!candidate.IsValid) return false;

        chord = candidate;
        return true;
    }

    private static bool TryParseModifier(string text, out HotkeyModifier modifier)
    {
        if (text.Equals("Win", StringComparison.OrdinalIgnoreCase) ||
            text.Equals("Windows", StringComparison.OrdinalIgnoreCase))
        {
            modifier = HotkeyModifier.Win;
            return true;
        }
        if (text.Equals("Ctrl", StringComparison.OrdinalIgnoreCase) ||
            text.Equals("Control", StringComparison.OrdinalIgnoreCase))
        {
            modifier = HotkeyModifier.Ctrl;
            return true;
        }
        if (text.Equals("Alt", StringComparison.OrdinalIgnoreCase))
        {
            modifier = HotkeyModifier.Alt;
            return true;
        }
        if (text.Equals("Shift", StringComparison.OrdinalIgnoreCase))
        {
            modifier = HotkeyModifier.Shift;
            return true;
        }
        modifier = default;
        return false;
    }

    private static bool TryParseKey(string text, out int virtualKey)
    {
        virtualKey = 0;
        if (string.IsNullOrEmpty(text)) return false;

        if (KeysByName.TryGetValue(text, out virtualKey))
            return IsValidTriggerKey(virtualKey);

        if (text.StartsWith("VK_", StringComparison.OrdinalIgnoreCase))
        {
            var hex = text[3..];
            if (hex.Length is >= 1 and <= 2 &&
                hex.All(IsHexDigit) &&
                int.TryParse(hex, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var parsed) &&
                IsValidTriggerKey(parsed))
            {
                virtualKey = parsed;
                return true;
            }
        }
        return false;
    }

    private static bool IsHexDigit(char c) =>
        c is (>= '0' and <= '9') or (>= 'a' and <= 'f') or (>= 'A' and <= 'F');

    private static string ModifierName(HotkeyModifier modifier) => modifier switch
    {
        HotkeyModifier.Win => "Win",
        HotkeyModifier.Ctrl => "Ctrl",
        HotkeyModifier.Alt => "Alt",
        HotkeyModifier.Shift => "Shift",
        _ => modifier.ToString(),
    };

    private static string KeySaveName(int virtualKey) =>
        KeysByVk.TryGetValue(virtualKey, out var info) ? info.SaveName : FormattableString.Invariant($"VK_{virtualKey:X2}");

    private static string KeyDisplayName(int virtualKey) =>
        KeysByVk.TryGetValue(virtualKey, out var info) ? info.DisplayName : FormattableString.Invariant($"VK_{virtualKey:X2}");

    private static KeyInfo[] BuildKnownKeys()
    {
        var list = new List<KeyInfo>
        {
            new(0x08, "Backspace", "Backspace", ["Back"]),
            new(0x09, "Tab", "Tab", []),
            new(0x0D, "Enter", "Enter", ["Return"]),
            new(0x13, "Pause", "Pause", []),
            new(0x14, "CapsLock", "CapsLock", ["Capital"]),
            new(0x15, "Kana", "かな", ["KanaMode", "Hangul"]),
            new(0x19, "Kanji", "漢字", ["KanjiMode", "Hanja"]),
            new(0x1B, "Escape", "Esc", ["Esc"]),
            new(0x1C, "Convert", "変換", ["ImeConvert", "変換"]),
            new(0x1D, "NonConvert", "無変換", ["ImeNonConvert", "無変換"]),
            new(0x20, "Space", "Space", ["Spacebar"]),
            new(0x21, "PageUp", "PageUp", ["Prior", "PgUp"]),
            new(0x22, "PageDown", "PageDown", ["Next", "PgDn"]),
            new(0x23, "End", "End", []),
            new(0x24, "Home", "Home", []),
            new(0x25, "Left", "←", ["←"]),
            new(0x26, "Up", "↑", ["↑"]),
            new(0x27, "Right", "→", ["→"]),
            new(0x28, "Down", "↓", ["↓"]),
            new(0x2C, "PrintScreen", "PrintScreen", ["Snapshot", "PrtSc"]),
            new(0x2D, "Insert", "Insert", ["Ins"]),
            new(0x2E, "Delete", "Delete", ["Del"]),
            new(0x5D, "Apps", "Menu", ["Menu"]),
            new(0x6A, "NumMultiply", "Num *", ["Multiply"]),
            new(0x6B, "NumAdd", "Num +", ["Add"]),
            new(0x6D, "NumSubtract", "Num -", ["Subtract"]),
            new(0x6E, "NumDecimal", "Num .", ["Decimal"]),
            new(0x6F, "NumDivide", "Num /", ["Divide"]),
            new(0x90, "NumLock", "NumLock", []),
            new(0x91, "ScrollLock", "ScrollLock", ["Scroll"]),
            new(0xBA, "Oem1", ";", ["Semicolon", ";"]),
            new(0xBB, "Plus", "+", ["OemPlus", "="]),
            new(0xBC, "Comma", ",", ["OemComma", ","]),
            new(0xBD, "Minus", "-", ["OemMinus", "-"]),
            new(0xBE, "Period", ".", ["OemPeriod", "."]),
            new(0xBF, "Slash", "/", ["Oem2", "/"]),
            new(0xC0, "`", "`", ["Backquote", "Backtick", "Grave", "Oem3"]),
            new(0xDB, "Oem4", "[", ["OpenBracket", "["]),
            new(0xDC, "Oem5", "\\", ["Backslash", "\\"]),
            new(0xDD, "Oem6", "]", ["CloseBracket", "]"]),
            new(0xDE, "Oem7", "'", ["Quote", "'"]),
            new(0xDF, "Oem8", "Oem8", []),
            new(0xE2, "Oem102", "\\_", ["\\_"]),
            new(0xF0, "Alphanumeric", "英数", ["Eisu", "OemAttn", "英数"]),
            new(0xF2, "KatakanaHiragana", "カタカナ/ひらがな", ["Hiragana", "OemCopy", "カタカナ/ひらがな"]),
            new(0xF3, "Hankaku", "半角/全角", ["HankakuZenkaku", "OemAuto", "半角/全角"]),
            new(0xF4, "Zenkaku", "半角/全角", ["OemEnlw"]),
        };

        for (var d = 0; d <= 9; d++)
        {
            var s = d.ToString(CultureInfo.InvariantCulture);
            list.Add(new(0x30 + d, s, s, [$"D{s}"]));
            list.Add(new(0x60 + d, $"Num{s}", $"Num {s}", [$"NumPad{s}"]));
        }

        for (var ch = 'A'; ch <= 'Z'; ch++)
        {
            var s = ch.ToString();
            list.Add(new(ch, s, s, []));
        }

        for (var f = 1; f <= 24; f++)
        {
            var s = FormattableString.Invariant($"F{f}");
            list.Add(new(0x70 + f - 1, s, s, []));
        }

        return [.. list];
    }

    private static Dictionary<string, int> BuildKeysByName()
    {
        var map = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var info in KnownKeys)
        {
            map[info.SaveName] = info.VirtualKey;
            foreach (var alias in info.Aliases)
                map[alias] = info.VirtualKey;
        }
        return map;
    }
}
