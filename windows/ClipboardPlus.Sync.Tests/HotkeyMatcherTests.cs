using ClipboardPlus.Windows.Core;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class HotkeyMatcherTests
{
    private const int VkEscape = 0x1B;
    private const int VkConvert = 0x1C;
    private const int VkNonConvert = 0x1D;
    private const int VkA = 0x41;
    private const int VkB = 0x42;
    private const int VkE = 0x45;
    private const int VkV = 0x56;
    private const int VkLWin = 0x5B;
    private const int VkRWin = 0x5C;
    private const int VkF1 = 0x70;
    private const int VkLShift = 0xA0;
    private const int VkRShift = 0xA1;
    private const int VkLControl = 0xA2;
    private const int VkRControl = 0xA3;
    private const int VkLMenu = 0xA4;
    private const int VkRMenu = 0xA5;

    [Theory]
    [InlineData(HotkeyModifier.Win, VkV, VkLWin, true)]
    [InlineData(HotkeyModifier.Win, VkV, VkRWin, true)]
    [InlineData(HotkeyModifier.Ctrl, VkNonConvert, VkLControl, false)]
    [InlineData(HotkeyModifier.Ctrl, VkNonConvert, VkRControl, false)]
    [InlineData(HotkeyModifier.Alt, VkF1, VkLMenu, false)]
    [InlineData(HotkeyModifier.Alt, VkF1, VkRMenu, false)]
    [InlineData(HotkeyModifier.Shift, VkA, VkLShift, false)]
    [InlineData(HotkeyModifier.Shift, VkA, VkRShift, false)]
    public void LeftAndRightModifiersMatchAndSetMenuMaskOnlyForWin(
        HotkeyModifier modifier, int triggerVk, int modVk, bool expectedMenuMask)
    {
        var matcher = new HotkeyMatcher(new HotkeyChord(modifier, triggerVk));

        Assert.Equal(HotkeyAction.Pass, matcher.Process(modVk, isKeyDown: true, isInjected: false).Action);

        var triggerResult = matcher.Process(triggerVk, isKeyDown: true, isInjected: false);
        Assert.Equal(HotkeyAction.SwallowAndTrigger, triggerResult.Action);
        Assert.Equal(expectedMenuMask, triggerResult.NeedsMenuMask);

        Assert.Equal(HotkeyAction.Swallow, matcher.Process(triggerVk, isKeyDown: false, isInjected: false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(modVk, isKeyDown: false, isInjected: false).Action);
    }

    [Fact]
    public void AutoRepeatDoesNotReTriggerAndKeyUpIsSwallowedEvenAfterModifierRelease()
    {
        var matcher = new HotkeyMatcher(HotkeyChord.Default);

        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, true, false).Action);
        Assert.Equal(HotkeyAction.SwallowAndTrigger, matcher.Process(VkV, true, false).Action);

        // Repeated key-downs while held must swallow without triggering again.
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkV, true, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkV, true, false).Action);

        // User releases Win before releasing V.
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, false, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkV, true, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkV, false, false).Action);

        // Subsequent plain V passes normally.
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, false, false).Action);
    }

    [Fact]
    public void ExtraModifiersPreventMatchWhileHoldingSameSideBothModifiersMatches()
    {
        var matcher = new HotkeyMatcher(new HotkeyChord(HotkeyModifier.Ctrl, VkV));

        // Ctrl+Shift+V must pass through, not trigger Ctrl+V.
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLControl, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLShift, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, false, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLShift, false, false).Action);

        // Holding both LControl and RControl, then releasing one, still represents Ctrl.
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkRControl, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLControl, false, false).Action);
        Assert.Equal(HotkeyAction.SwallowAndTrigger, matcher.Process(VkV, true, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkV, false, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkRControl, false, false).Action);
    }

    [Fact]
    public void TriggerKeyPressedBeforeModifierDoesNotTrigger()
    {
        var matcher = new HotkeyMatcher(HotkeyChord.Default);

        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, false, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, false, false).Action);
    }

    [Fact]
    public void InjectedInputAlwaysPassesWithoutMutatingState()
    {
        var matcher = new HotkeyMatcher(new HotkeyChord(HotkeyModifier.Ctrl, VkV));

        // Synthetic Ctrl+V (like PasteAsync) passes even when hotkey is Ctrl+V.
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLControl, true, isInjected: true).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, true, isInjected: true).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, false, isInjected: true).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLControl, false, isInjected: true).Action);

        // Injected LControl must not leave Ctrl marked held for a real V press.
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, true, isInjected: false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, false, isInjected: false).Action);
    }

    [Fact]
    public void UnmatchedKeyOrDisabledTargetPasses()
    {
        var matcher = new HotkeyMatcher(HotkeyChord.Default);

        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkE, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkE, false, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, false, false).Action);

        matcher.Target = null;
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, false, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, false, false).Action);
    }

    [Fact]
    public void RecordingSwallowsAllKeysReturnsRecordedChordAndSwallowsRelease()
    {
        var matcher = new HotkeyMatcher(HotkeyChord.Default);
        matcher.StartRecording();
        Assert.True(matcher.IsRecording);

        // Single unmodified key (not Esc) is swallowed and keeps recording.
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkA, true, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkA, false, false).Action);
        Assert.True(matcher.IsRecording);

        // Two different modifiers + key is ignored (keeps waiting).
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkLControl, true, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkLShift, true, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkB, true, false).Action);
        Assert.True(matcher.IsRecording);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkB, false, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkLShift, false, false).Action);

        // Now only Ctrl is held, pressing NonConvert completes recording.
        var recorded = matcher.Process(VkNonConvert, true, false);
        Assert.Equal(HotkeyAction.Swallow, recorded.Action);
        Assert.Equal(new HotkeyChord(HotkeyModifier.Ctrl, VkNonConvert), recorded.RecordedChord);
        Assert.False(recorded.RecordingCancelled);
        Assert.False(matcher.IsRecording);

        // Even if the new chord is applied immediately, holding/releasing those keys must swallow without triggering.
        matcher.Target = recorded.RecordedChord;
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkNonConvert, true, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkNonConvert, false, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkLControl, false, false).Action);

        // Pressing Ctrl+NonConvert fresh afterwards triggers normally.
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLControl, true, false).Action);
        Assert.Equal(HotkeyAction.SwallowAndTrigger, matcher.Process(VkNonConvert, true, false).Action);
    }

    [Fact]
    public void RecordingCancelsOnEscapeAloneAndRecordsModifierPlusEscape()
    {
        var matcher = new HotkeyMatcher(HotkeyChord.Default);

        matcher.StartRecording();
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkLWin, true, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkLWin, false, false).Action);

        var cancelled = matcher.Process(VkEscape, true, false);
        Assert.Equal(HotkeyAction.Swallow, cancelled.Action);
        Assert.True(cancelled.RecordingCancelled);
        Assert.Null(cancelled.RecordedChord);
        Assert.False(matcher.IsRecording);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkEscape, false, false).Action);

        // Holding Shift while pressing Escape records Shift+Escape rather than cancelling.
        matcher.StartRecording();
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkRShift, true, false).Action);
        var shiftEsc = matcher.Process(VkEscape, true, false);
        Assert.False(shiftEsc.RecordingCancelled);
        Assert.Equal(new HotkeyChord(HotkeyModifier.Shift, VkEscape), shiftEsc.RecordedChord);
        Assert.False(matcher.IsRecording);
    }

    [Fact]
    public void PruneReleasedKeysPreventsStuckModifierAfterMissedKeyUp()
    {
        var matcher = new HotkeyMatcher(HotkeyChord.Default);

        // Simulate Win+L where LWin key-up is lost on lock screen.
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, true, false).Action);
        matcher.PruneReleasedKeys(_ => false);

        // Plain V after unlocking must pass instead of triggering Win+V.
        var result = matcher.Process(VkV, true, false);
        Assert.Equal(HotkeyAction.Pass, result.Action);
    }

    [Fact]
    public void InvalidChordInConstructorOrTargetThrows()
    {
        Assert.Throws<ArgumentException>(() => new HotkeyMatcher(new HotkeyChord(HotkeyModifier.Win, VkLWin)));
        var matcher = new HotkeyMatcher(HotkeyChord.Default);
        Assert.Throws<ArgumentException>(() => matcher.Target = new HotkeyChord(HotkeyModifier.Ctrl, VkRMenu));
    }

    [Fact]
    public void KeyPressedBeforeRecordingKeepsPassingThroughRepeatAndRelease()
    {
        var matcher = new HotkeyMatcher(HotkeyChord.Default);

        // Modifier and normal key pressed before recording starts must pass on repeat and key-up.
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLControl, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkA, true, false).Action);

        matcher.StartRecording();

        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLControl, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLControl, false, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkA, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkA, false, false).Action);
        // Key-up for a key pressed before the hook existed must also pass.
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkB, false, false).Action);
        Assert.True(matcher.IsRecording);
    }

    [Fact]
    public void NormalModeKeyPressedBeforeModifierPassesOnRepeatAndRelease()
    {
        var matcher = new HotkeyMatcher(HotkeyChord.Default);

        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, false, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, false, false).Action);

        // Extra-modifier chord that initially passed must keep passing on repeat after extra modifier lifts.
        var ctrlNonConvert = new HotkeyMatcher(new HotkeyChord(HotkeyModifier.Ctrl, VkNonConvert));
        Assert.Equal(HotkeyAction.Pass, ctrlNonConvert.Process(VkLControl, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, ctrlNonConvert.Process(VkLShift, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, ctrlNonConvert.Process(VkNonConvert, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, ctrlNonConvert.Process(VkLShift, false, false).Action);
        Assert.Equal(HotkeyAction.Pass, ctrlNonConvert.Process(VkNonConvert, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, ctrlNonConvert.Process(VkNonConvert, false, false).Action);
        Assert.Equal(HotkeyAction.Pass, ctrlNonConvert.Process(VkLControl, false, false).Action);
    }

    [Fact]
    public void RecordingKeepsSwallowedModifierAcrossPruneAndCompletesChord()
    {
        var matcher = new HotkeyMatcher(HotkeyChord.Default);
        matcher.StartRecording();

        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkLControl, true, false).Action);
        // Swallowed key-down is never reflected in GetAsyncKeyState, so prune reports false.
        matcher.PruneReleasedKeys(_ => false);

        var recorded = matcher.Process(VkNonConvert, true, false);
        Assert.Equal(HotkeyAction.Swallow, recorded.Action);
        Assert.Equal(new HotkeyChord(HotkeyModifier.Ctrl, VkNonConvert), recorded.RecordedChord);
        Assert.False(matcher.IsRecording);

        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkNonConvert, false, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkLControl, false, false).Action);
    }

    [Fact]
    public void RecordingEscapeCancelsEvenWhenMultipleModifiersAreHeld()
    {
        var matcher = new HotkeyMatcher(HotkeyChord.Default);
        matcher.StartRecording();

        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkLControl, true, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkLShift, true, false).Action);

        var cancelled = matcher.Process(VkEscape, true, false);
        Assert.Equal(HotkeyAction.Swallow, cancelled.Action);
        Assert.True(cancelled.RecordingCancelled);
        Assert.Null(cancelled.RecordedChord);
        Assert.False(matcher.IsRecording);

        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkEscape, false, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkLShift, false, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkLControl, false, false).Action);
    }

    [Fact]
    public void SwallowedTriggerKeyStaysSwallowedAcrossPruneWhenWinReleasedFirst()
    {
        var matcher = new HotkeyMatcher(HotkeyChord.Default);

        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, true, false).Action);
        Assert.Equal(HotkeyAction.SwallowAndTrigger, matcher.Process(VkV, true, false).Action);

        // Win key-up arrives while GetAsyncKeyState(V) is false because V was swallowed.
        matcher.PruneReleasedKeys(vk => vk == VkLWin);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, false, false).Action);

        matcher.PruneReleasedKeys(vk => vk == VkV);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkV, true, false).Action);
        matcher.PruneReleasedKeys(_ => false);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkV, false, false).Action);

        // Next plain V passes.
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, false, false).Action);
    }

    [Fact]
    public void SwallowedTriggerKeyDoesNotRetriggerOnRepeatAfterAnotherKeyWhileWinHeld()
    {
        var matcher = new HotkeyMatcher(HotkeyChord.Default);

        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, true, false).Action);
        Assert.Equal(HotkeyAction.SwallowAndTrigger, matcher.Process(VkV, true, false).Action);

        // Press and release E while Win and V remain held; OS reports only Win (and E) down, not swallowed V.
        matcher.PruneReleasedKeys(vk => vk == VkLWin || vk == VkE);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkE, true, false).Action);
        matcher.PruneReleasedKeys(vk => vk == VkLWin || vk == VkE);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkE, false, false).Action);

        // Auto-repeat of V must keep swallowing without triggering again.
        matcher.PruneReleasedKeys(vk => vk == VkLWin);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkV, true, false).Action);
        Assert.Equal(HotkeyAction.Swallow, matcher.Process(VkV, false, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, false, false).Action);
    }

    [Fact]
    public void RevertSwallowToPassAllowsRepeatAndReleaseToPass()
    {
        var matcher = new HotkeyMatcher(HotkeyChord.Default);

        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, true, false).Action);
        var match = matcher.Process(VkV, true, false);
        Assert.Equal(HotkeyAction.SwallowAndTrigger, match.Action);
        Assert.True(match.NeedsMenuMask);

        matcher.RevertSwallowToPass(VkV);

        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, true, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkV, false, false).Action);
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, false, false).Action);

        // Fresh Win+V still triggers afterwards.
        Assert.Equal(HotkeyAction.Pass, matcher.Process(VkLWin, true, false).Action);
        Assert.Equal(HotkeyAction.SwallowAndTrigger, matcher.Process(VkV, true, false).Action);
    }
}
