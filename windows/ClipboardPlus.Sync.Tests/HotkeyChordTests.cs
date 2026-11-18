using ClipboardPlus.Windows.Core;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class HotkeyChordTests
{
    [Fact]
    public void DefaultIsWinV()
    {
        Assert.True(HotkeyChord.Default.IsValid);
        Assert.Equal(HotkeyModifier.Win, HotkeyChord.Default.Modifier);
        Assert.Equal(0x56, HotkeyChord.Default.VirtualKey);
        Assert.Equal("Win+V", HotkeyChord.Default.ToString());
        Assert.Equal("Win + V", HotkeyChord.Default.DisplayName);
    }

    [Theory]
    [InlineData("Win+V", HotkeyModifier.Win, 0x56, "Win+V", "Win + V")]
    [InlineData("Ctrl+NonConvert", HotkeyModifier.Ctrl, 0x1D, "Ctrl+NonConvert", "Ctrl + 無変換")]
    [InlineData("Ctrl+Convert", HotkeyModifier.Ctrl, 0x1C, "Ctrl+Convert", "Ctrl + 変換")]
    [InlineData("Alt+F1", HotkeyModifier.Alt, 0x70, "Alt+F1", "Alt + F1")]
    [InlineData("Shift+F24", HotkeyModifier.Shift, 0x87, "Shift+F24", "Shift + F24")]
    [InlineData("Ctrl+Space", HotkeyModifier.Ctrl, 0x20, "Ctrl+Space", "Ctrl + Space")]
    [InlineData("Win+`", HotkeyModifier.Win, 0xC0, "Win+`", "Win + `")]
    [InlineData("Shift+0", HotkeyModifier.Shift, 0x30, "Shift+0", "Shift + 0")]
    [InlineData("Ctrl+9", HotkeyModifier.Ctrl, 0x39, "Ctrl+9", "Ctrl + 9")]
    public void TryParseAndFormatRoundTripsKnownKeys(
        string input, HotkeyModifier expectedMod, int expectedVk, string expectedSave, string expectedDisplay)
    {
        Assert.True(HotkeyChord.TryParse(input, out var chord));
        Assert.True(chord.IsValid);
        Assert.Equal(expectedMod, chord.Modifier);
        Assert.Equal(expectedVk, chord.VirtualKey);
        Assert.Equal(expectedSave, chord.ToString());
        Assert.Equal(expectedDisplay, chord.DisplayName);
    }

    [Theory]
    [InlineData("win + v", "Win+V")]
    [InlineData("control+nonconvert", "Ctrl+NonConvert")]
    [InlineData("Ctrl + 無変換", "Ctrl+NonConvert")]
    [InlineData("alt+oem3", "Alt+`")]
    [InlineData("shift+d5", "Shift+5")]
    [InlineData("Win+VK_56", "Win+V")]
    public void TryParseAcceptsCaseAliasesAndSpacing(string input, string expectedSave)
    {
        Assert.True(HotkeyChord.TryParse(input, out var chord));
        Assert.Equal(expectedSave, chord.ToString());
    }

    [Fact]
    public void UnnamedKeysRoundTripViaVkHex()
    {
        Assert.True(HotkeyChord.TryParse("Alt+VK_9f", out var chord));
        Assert.True(chord.IsValid);
        Assert.Equal(HotkeyModifier.Alt, chord.Modifier);
        Assert.Equal(0x9F, chord.VirtualKey);
        Assert.Equal("Alt+VK_9F", chord.ToString());
        Assert.Equal("Alt + VK_9F", chord.DisplayName);
    }

    [Theory]
    [InlineData(0x10)] // VK_SHIFT
    [InlineData(0x11)] // VK_CONTROL
    [InlineData(0x12)] // VK_MENU
    [InlineData(0x5B)] // VK_LWIN
    [InlineData(0x5C)] // VK_RWIN
    [InlineData(0xA0)] // VK_LSHIFT
    [InlineData(0xA1)] // VK_RSHIFT
    [InlineData(0xA2)] // VK_LCONTROL
    [InlineData(0xA3)] // VK_RCONTROL
    [InlineData(0xA4)] // VK_LMENU
    [InlineData(0xA5)] // VK_RMENU
    public void ModifierVirtualKeysAreInvalidAsSecondKey(int modifierVk)
    {
        Assert.True(HotkeyChord.IsModifierKey(modifierVk));
        Assert.False(new HotkeyChord(HotkeyModifier.Win, modifierVk).IsValid);
        Assert.False(HotkeyChord.TryParse($"Win+VK_{modifierVk:X2}", out _));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("V")]
    [InlineData("Win")]
    [InlineData("Win+")]
    [InlineData("+V")]
    [InlineData("Ctrl+Alt+V")]
    [InlineData("Win+Shift+V")]
    [InlineData("Win+Shift")]
    [InlineData("Ctrl+LControl")]
    [InlineData("Win+UnknownKey")]
    [InlineData("Win+VK_00")]
    [InlineData("Win+VK_01")]
    [InlineData("Win+VK_FF")]
    [InlineData("Win+VK_100")]
    [InlineData("Win+VK_ZZ")]
    [InlineData("Win+VK_-1")]
    public void TryParseRejectsInvalidStrings(string? input)
    {
        Assert.False(HotkeyChord.TryParse(input, out var chord));
        Assert.Equal(default, chord);
        Assert.False(chord.IsValid);
    }
}
