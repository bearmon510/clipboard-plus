using ClipboardPlus.Windows.Core;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class HotkeyRulesTests
{
    [Theory]
    [InlineData(HotkeyModifier.Win, 'V')]
    [InlineData(HotkeyModifier.Ctrl, 0x1D)] // Ctrl + 無変換
    [InlineData(HotkeyModifier.Alt, 'V')]
    [InlineData(HotkeyModifier.Shift, 0x70)] // Shift + F1 types nothing
    [InlineData(HotkeyModifier.Ctrl, 0xC0)]
    public void UsefulTwoKeyChordsAreAllowed(HotkeyModifier modifier, int key) =>
        Assert.Null(HotkeyRules.Problem(new HotkeyChord(modifier, key)));

    [Theory]
    [InlineData(HotkeyModifier.Shift, 'A', "大文字")]
    [InlineData(HotkeyModifier.Shift, '1', "大文字")]
    [InlineData(HotkeyModifier.Shift, 0x20, "大文字")]
    [InlineData(HotkeyModifier.Shift, 0xBA, "大文字")]
    [InlineData(HotkeyModifier.Ctrl, 'C', "コピー")]
    [InlineData(HotkeyModifier.Ctrl, 'V', "コピー")]
    [InlineData(HotkeyModifier.Ctrl, 'Z', "コピー")]
    [InlineData(HotkeyModifier.Alt, 0x09, "窓の切り替え")]
    [InlineData(HotkeyModifier.Alt, 0x73, "窓の切り替え")]
    [InlineData(HotkeyModifier.Win, 'L', "ロック")]
    public void ChordsThatBreakTypingOrEverydayShortcutsAreRefused(HotkeyModifier modifier, int key, string reason) =>
        Assert.Contains(reason, HotkeyRules.Problem(new HotkeyChord(modifier, key)));

    [Fact]
    public void AModifierAsTheSecondKeyIsNotAChord() =>
        Assert.NotNull(HotkeyRules.Problem(new HotkeyChord(HotkeyModifier.Ctrl, 0xA0))); // Ctrl + Left Shift
}
