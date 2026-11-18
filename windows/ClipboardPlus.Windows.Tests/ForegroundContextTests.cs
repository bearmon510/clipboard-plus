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
        var altDownCalls = 0;
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
            IsAltDown: () => false,
            SendAltDown: () => { altDownCalls++; return true; },
            SendAltUp: _ => true,
            ActivateManaged: () => managedActivated = true);

        Assert.True(ForegroundContext.BringToFront(TargetWindow, ops));
        Assert.True(managedActivated);
        Assert.Equal(0, attachedCalls);
        Assert.Equal(0, altDownCalls);
    }

    [Fact]
    public void BringToFrontUsesAttachThreadInputWhenDirectSetForegroundFails()
    {
        var foreground = OtherWindow;
        var attached = false;
        var attachEvents = new List<bool>();
        var bringToTopCalled = false;
        var setActiveCalled = false;
        var altDownCalls = 0;

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
            IsAltDown: () => false,
            SendAltDown: () => { altDownCalls++; return true; },
            SendAltUp: _ => true,
            ActivateManaged: () => { });

        Assert.True(ForegroundContext.BringToFront(TargetWindow, ops));
        Assert.Equal([true, false], attachEvents);
        Assert.True(bringToTopCalled);
        Assert.True(setActiveCalled);
        Assert.Equal(0, altDownCalls);
    }

    [Fact]
    public void BringToFrontFallsBackToAltTapWhenForegroundWindowIsHungOrRefusesAttach()
    {
        var foreground = OtherWindow;
        var altDown = false;
        var attachAttempts = 0;
        var maskFlags = new List<bool>();

        var ops = new ForegroundContext.ActivateOperations(
            IsWindow: w => w == TargetWindow,
            GetForegroundWindow: () => foreground,
            SetForegroundWindow: w =>
            {
                if (altDown)
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
            IsAltDown: () => false,
            SendAltDown: () => { altDown = true; return true; },
            SendAltUp: mask => { altDown = false; maskFlags.Add(mask); return true; },
            ActivateManaged: () => { });

        Assert.True(ForegroundContext.BringToFront(TargetWindow, ops));
        Assert.Equal(0, attachAttempts);
        Assert.False(altDown);
        Assert.Equal([false], maskFlags);
    }

    [Fact]
    public void BringToFrontReleasesAltWithMenuMaskAndReturnsFalseWhenAllAttemptsFail()
    {
        var altDown = false;
        var maskFlags = new List<bool>();
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
            IsAltDown: () => false,
            SendAltDown: () => { altDown = true; return true; },
            SendAltUp: mask => { altDown = false; maskFlags.Add(mask); return true; },
            ActivateManaged: () => managedActivated = true);

        Assert.False(ForegroundContext.BringToFront(TargetWindow, ops));
        Assert.True(managedActivated);
        Assert.False(altDown);
        Assert.Equal([true], maskFlags);
    }

    [Fact]
    public void BringToFrontSkipsAltInjectionWhenAltIsAlreadyPhysicallyHeld()
    {
        var altDownCalls = 0;

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
            IsAltDown: () => true,
            SendAltDown: () => { altDownCalls++; return true; },
            SendAltUp: _ => true,
            ActivateManaged: () => { });

        Assert.False(ForegroundContext.BringToFront(TargetWindow, ops));
        Assert.Equal(0, altDownCalls);
    }
}
