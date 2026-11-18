using ClipboardPlus.Windows.Infrastructure;
using Xunit;

namespace ClipboardPlus.Windows.Tests;

public sealed class ForegroundContextTests
{
    private const nint TargetWindow = 0x1234;
    private const nint OtherWindow = 0x5678;

    [Fact]
    public async Task PasteAsyncReturnsFalseWithoutSendingCtrlVWhenForegroundDiffersBeforeSend()
    {
        var foreground = TargetWindow;
        var setForegroundCalled = false;
        var sendCtrlVCalled = false;

        var ops = new ForegroundContext.PasteOperations(
            IsWindow: w => w == TargetWindow,
            SetForegroundWindow: w =>
            {
                setForegroundCalled = w == TargetWindow;
                // Simulate another window taking focus during activation delay.
                foreground = OtherWindow;
                return true;
            },
            GetForegroundWindow: () => foreground,
            IsAnyModifierDown: () => false,
            SendCtrlV: () =>
            {
                sendCtrlVCalled = true;
                return true;
            },
            GetTickCount64: () => 0,
            Delay: (_, _) => Task.CompletedTask);

        var pasted = await ForegroundContext.PasteAsync(TargetWindow, CancellationToken.None, ops);

        Assert.True(setForegroundCalled);
        Assert.False(pasted);
        Assert.False(sendCtrlVCalled);
    }

    [Fact]
    public async Task PasteAsyncReturnsTrueAndSendsCtrlVWhenTargetRemainsForeground()
    {
        var sendCtrlVCalled = false;
        var ops = new ForegroundContext.PasteOperations(
            IsWindow: w => w == TargetWindow,
            SetForegroundWindow: w => w == TargetWindow,
            GetForegroundWindow: () => TargetWindow,
            IsAnyModifierDown: () => false,
            SendCtrlV: () =>
            {
                sendCtrlVCalled = true;
                return true;
            },
            GetTickCount64: () => 0,
            Delay: (_, _) => Task.CompletedTask);

        var pasted = await ForegroundContext.PasteAsync(TargetWindow, CancellationToken.None, ops);

        Assert.True(pasted);
        Assert.True(sendCtrlVCalled);
    }

    [Fact]
    public async Task PasteAsyncReturnsFalseAfterTimeoutWhenModifiersRemainDown()
    {
        long now = 0;
        var setForegroundCalled = false;
        var sendCtrlVCalled = false;

        var ops = new ForegroundContext.PasteOperations(
            IsWindow: w => w == TargetWindow,
            SetForegroundWindow: _ =>
            {
                setForegroundCalled = true;
                return true;
            },
            GetForegroundWindow: () => TargetWindow,
            IsAnyModifierDown: () => true,
            SendCtrlV: () =>
            {
                sendCtrlVCalled = true;
                return true;
            },
            GetTickCount64: () => now,
            Delay: (ms, _) =>
            {
                now += ms;
                return Task.CompletedTask;
            });

        var pasted = await ForegroundContext.PasteAsync(TargetWindow, CancellationToken.None, ops);

        Assert.False(pasted);
        Assert.False(setForegroundCalled);
        Assert.False(sendCtrlVCalled);
        Assert.True(now >= 1000);
    }

    [Fact]
    public async Task PasteAsyncReturnsFalseWhenModifierPressedAgainDuringActivationDelay()
    {
        var modifierDown = false;
        var sendCtrlVCalled = false;

        var ops = new ForegroundContext.PasteOperations(
            IsWindow: w => w == TargetWindow,
            SetForegroundWindow: w => w == TargetWindow,
            GetForegroundWindow: () => TargetWindow,
            IsAnyModifierDown: () => modifierDown,
            SendCtrlV: () =>
            {
                sendCtrlVCalled = true;
                return true;
            },
            GetTickCount64: () => 0,
            Delay: (ms, _) =>
            {
                if (ms == 25) modifierDown = true;
                return Task.CompletedTask;
            });

        var pasted = await ForegroundContext.PasteAsync(TargetWindow, CancellationToken.None, ops);

        Assert.False(pasted);
        Assert.False(sendCtrlVCalled);
    }

    [Fact]
    public async Task PasteAsyncSucceedsWhenModifiersAreReleasedBeforeTimeout()
    {
        long now = 0;
        var checks = 0;
        var sendCtrlVCalled = false;

        var ops = new ForegroundContext.PasteOperations(
            IsWindow: w => w == TargetWindow,
            SetForegroundWindow: w => w == TargetWindow,
            GetForegroundWindow: () => TargetWindow,
            IsAnyModifierDown: () =>
            {
                checks++;
                return checks <= 3;
            },
            SendCtrlV: () =>
            {
                sendCtrlVCalled = true;
                return true;
            },
            GetTickCount64: () => now,
            Delay: (ms, _) =>
            {
                now += ms;
                return Task.CompletedTask;
            });

        var pasted = await ForegroundContext.PasteAsync(TargetWindow, CancellationToken.None, ops);

        Assert.True(pasted);
        Assert.True(sendCtrlVCalled);
    }

    [Fact]
    public void BringToFrontReturnsTrueImmediatelyWhenDirectSetForegroundSucceeds()
    {
        var foreground = OtherWindow;
        var attachedCalls = 0;
        var maskTapCalls = 0;
        var managedActivated = false;

        var ops = new ForegroundContext.ActivateOperations(
            IsWindow: w => w == TargetWindow,
            GetForegroundWindow: () => foreground,
            SetForegroundWindow: w => { foreground = w; return true; },
            BringWindowToTop: _ => true,
            SetActiveWindow: w => w,
            IsHungAppWindow: _ => false,
            GetWindowThreadProcessId: _ => 200,
            GetCurrentThreadId: () => 100,
            AttachThreadInput: (_, _, _) => { attachedCalls++; return true; },
            SendUnassignedKeyTap: () => { maskTapCalls++; return true; },
            ActivateManaged: () => managedActivated = true);

        Assert.True(ForegroundContext.BringToFront(TargetWindow, ops));
        Assert.True(managedActivated);
        Assert.Equal(0, attachedCalls);
        Assert.Equal(0, maskTapCalls);
    }

    [Fact]
    public void BringToFrontUsesAttachThreadInputWhenDirectSetForegroundFails()
    {
        var foreground = OtherWindow;
        var attached = false;
        var attachEvents = new List<bool>();
        var bringToTopCalled = false;
        var setActiveCalled = false;
        var maskTapCalls = 0;

        var ops = new ForegroundContext.ActivateOperations(
            IsWindow: w => w == TargetWindow,
            GetForegroundWindow: () => foreground,
            SetForegroundWindow: w =>
            {
                if (attached)
                {
                    foreground = w;
                    return true;
                }
                return false;
            },
            BringWindowToTop: _ => { bringToTopCalled = true; return true; },
            SetActiveWindow: w => { setActiveCalled = true; return w; },
            IsHungAppWindow: _ => false,
            GetWindowThreadProcessId: _ => 200,
            GetCurrentThreadId: () => 100,
            AttachThreadInput: (_, _, value) =>
            {
                attached = value;
                attachEvents.Add(value);
                return true;
            },
            SendUnassignedKeyTap: () => { maskTapCalls++; return true; },
            ActivateManaged: () => { });

        Assert.True(ForegroundContext.BringToFront(TargetWindow, ops));
        Assert.Equal([true, false], attachEvents);
        Assert.True(bringToTopCalled);
        Assert.True(setActiveCalled);
        Assert.Equal(0, maskTapCalls);
    }

    [Fact]
    public void BringToFrontFallsBackToUnassignedKeyTapWhenForegroundWindowIsHungOrRefusesAttach()
    {
        var foreground = OtherWindow;
        var maskTapped = false;
        var attachAttempts = 0;

        var ops = new ForegroundContext.ActivateOperations(
            IsWindow: w => w == TargetWindow,
            GetForegroundWindow: () => foreground,
            SetForegroundWindow: w =>
            {
                if (maskTapped)
                {
                    foreground = w;
                    return true;
                }
                return false;
            },
            BringWindowToTop: _ => true,
            SetActiveWindow: w => w,
            IsHungAppWindow: w => w == OtherWindow,
            GetWindowThreadProcessId: _ => 200,
            GetCurrentThreadId: () => 100,
            AttachThreadInput: (_, _, _) => { attachAttempts++; return true; },
            SendUnassignedKeyTap: () => { maskTapped = true; return true; },
            ActivateManaged: () => { });

        Assert.True(ForegroundContext.BringToFront(TargetWindow, ops));
        Assert.Equal(0, attachAttempts);
        Assert.True(maskTapped);
    }

    [Fact]
    public void BringToFrontReturnsFalseWhenAllAttemptsFail()
    {
        var maskTapCalls = 0;
        var managedActivated = false;

        var ops = new ForegroundContext.ActivateOperations(
            IsWindow: w => w == TargetWindow,
            GetForegroundWindow: () => OtherWindow,
            SetForegroundWindow: _ => false,
            BringWindowToTop: _ => false,
            SetActiveWindow: _ => 0,
            IsHungAppWindow: _ => false,
            GetWindowThreadProcessId: _ => 200,
            GetCurrentThreadId: () => 100,
            AttachThreadInput: (_, _, _) => false,
            SendUnassignedKeyTap: () => { maskTapCalls++; return true; },
            ActivateManaged: () => managedActivated = true);

        Assert.False(ForegroundContext.BringToFront(TargetWindow, ops));
        Assert.True(managedActivated);
        Assert.Equal(1, maskTapCalls);
    }

    [Fact]
    public void NativeInputMenuMaskUsesUnassignedKeyWithoutExtendedFlagOrAlt()
    {
        var inputs = NativeInput.CreateMenuMaskInputs();
        Assert.Equal(2, inputs.Length);
        Assert.All(inputs, input =>
        {
            Assert.Equal(1u, input.type);
            Assert.Equal(NativeInput.VkMenuMask, input.U.ki.wVk);
            Assert.Equal((ushort)0, input.U.ki.wScan);
            Assert.Equal((uint)0, input.U.ki.dwFlags & 0x0001u); // No KeyEventExtendedKey.
            Assert.Equal(NativeInput.SelfExtraInfo, input.U.ki.dwExtraInfo);
        });
        Assert.Equal(0u, inputs[0].U.ki.dwFlags);
        Assert.Equal(0x0002u, inputs[1].U.ki.dwFlags);
    }

    [Fact]
    public void PasteTargetTrackerFollowsLatestExternalWindowAndIgnoresOwnWindows()
    {
        const nint ownHistoryWindow = 0x1001;
        const nint ownSettingsWindow = 0x1002;
        const nint appA = 0x2001;
        const nint appB = 0x2002;
        var alive = new HashSet<nint> { ownHistoryWindow, ownSettingsWindow, appA, appB };

        var tracker = new PasteTargetTracker(
            isWindow: w => alive.Contains(w),
            isOwnWindow: w => w is ownHistoryWindow or ownSettingsWindow);

        // Initialized from hotkey invocation on appA.
        tracker.Reset(appA);
        Assert.Equal(appA, tracker.CurrentTarget);

        // Switching to own windows keeps the previous external target.
        Assert.False(tracker.RecordForeground(ownHistoryWindow));
        Assert.False(tracker.RecordForeground(ownSettingsWindow));
        Assert.Equal(appA, tracker.CurrentTarget);

        // Moving to another external app updates the paste target to that latest app.
        Assert.True(tracker.RecordForeground(appB));
        Assert.Equal(appB, tracker.CurrentTarget);

        // Returning to history window keeps appB as the paste target.
        Assert.False(tracker.RecordForeground(ownHistoryWindow));
        Assert.Equal(appB, tracker.CurrentTarget);

        // Closing appB invalidates the handle so paste is not sent to a dead window.
        alive.Remove(appB);
        Assert.Equal((nint)0, tracker.CurrentTarget);

        // Opened from tray/settings (0 or own window) yields no paste target until another app is visited.
        tracker.Reset(ownSettingsWindow);
        Assert.Equal((nint)0, tracker.CurrentTarget);
        Assert.False(tracker.RecordForeground(ownHistoryWindow));
        Assert.Equal((nint)0, tracker.CurrentTarget);
        alive.Add(appB);
        Assert.True(tracker.RecordForeground(appB));
        Assert.Equal(appB, tracker.CurrentTarget);

        // Hiding resets the tracker.
        tracker.Reset();
        Assert.Equal((nint)0, tracker.CurrentTarget);
    }
}
