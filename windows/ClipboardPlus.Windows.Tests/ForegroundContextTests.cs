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
}
