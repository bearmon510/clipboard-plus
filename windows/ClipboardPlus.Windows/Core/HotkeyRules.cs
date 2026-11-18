namespace ClipboardPlus.Windows.Core;

/// <summary>
/// Chords the hook must not take, because swallowing them would break ordinary typing or
/// everyday shortcuts everywhere on the PC.
/// </summary>
public static class HotkeyRules
{
    private const int Tab = 0x09, Escape = 0x1B, Space = 0x20, F4 = 0x73;

    /// <summary>Why the chord cannot be used, or null when it can.</summary>
    public static string? Problem(HotkeyChord chord)
    {
        if (!chord.IsValid) return "修飾キー（Win・Ctrl・Alt・Shift）と、ほかのキー1つを押してください。";
        return chord.Modifier switch
        {
            HotkeyModifier.Shift when IsTypingKey(chord.VirtualKey) =>
                "Shiftと文字のキーでは、大文字や記号が打てなくなります。別の組み合わせにしてください。",
            HotkeyModifier.Ctrl when chord.VirtualKey is 'A' or 'C' or 'V' or 'X' or 'Z' or 'Y' or 'S' or Escape =>
                "コピーや貼り付けなど、よく使う操作と重なります。別の組み合わせにしてください。",
            HotkeyModifier.Alt when chord.VirtualKey is Tab or F4 or Space or Escape =>
                "窓の切り替えや閉じる操作と重なります。別の組み合わせにしてください。",
            HotkeyModifier.Win when chord.VirtualKey is 'L' =>
                "Win + L は画面のロックに使われていて、変えられません。別の組み合わせにしてください。",
            _ => null,
        };
    }

    /// <summary>Keys that type a character: letters, digits, the space bar and punctuation.</summary>
    private static bool IsTypingKey(int key) =>
        key is Space or >= '0' and <= '9' or >= 'A' and <= 'Z' or >= 0xBA and <= 0xC0 or >= 0xDB and <= 0xDF or 0xE2;
}
