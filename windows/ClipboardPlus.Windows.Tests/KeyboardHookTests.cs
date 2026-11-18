using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using ClipboardPlus.Windows.Core;
using ClipboardPlus.Windows.Infrastructure;
using Xunit;

namespace ClipboardPlus.Windows.Tests;

public sealed class KeyboardHookTests
{
    private const int VkNonConvert = 0x1D;
    private const int VkV = 0x56;
    private const int VkLWin = 0x5B;
    private const int VkLControl = 0xA2;
    private const nint CallNextSentinel = 42;

    private sealed class FakeHookHost : IDisposable
    {
        private readonly ConcurrentDictionary<uint, BlockingCollection<KeyboardHook.MSG>> queues = new();
        private readonly ThreadLocal<uint> currentThreadId = new();
        private int nextThreadId = 100;
        private nint nextHookHandle = 1;

        public ConcurrentQueue<string> Logs { get; } = new();
        public List<uint> SetHookThreadIds { get; } = [];
        public int SetHookCount { get; private set; }
        public int UnhookCount { get; private set; }
        public int CallNextHookCount { get; private set; }
        public int TriggeredCount { get; private set; }
        public KeyboardHook.LowLevelKeyboardProc? ActiveProc { get; private set; }
        public ManualResetEventSlim HookInstalled { get; } = new(false);
        public ManualResetEventSlim HookRemoved { get; } = new(false);

        public Func<bool> SendMenuMaskResult { get; set; } = () => true;
        public Func<int, bool> KeyDownState { get; set; } = _ => false;
        public Func<int, (int status, int error)?>? ScriptedGetMessage { get; set; }
        public Func<(bool ok, int error)>? ScriptedUnhook { get; set; }
        public Func<uint, uint, (bool ok, int error)?>? ScriptedPostThreadMessage { get; set; }

        public KeyboardHook CreateHook() => new(
            onTriggered: () => TriggeredCount++,
            dispatch: action => action(),
            log: Logs.Enqueue,
            backend: BuildBackend());

        public nint SendKey(int vk, bool isKeyDown, uint flags = 0, nuint extraInfo = 0)
        {
            var proc = ActiveProc ?? throw new InvalidOperationException("Hook proc not installed.");
            var info = new KeyboardHook.KBDLLHOOKSTRUCT
            {
                vkCode = unchecked((uint)vk),
                flags = flags,
                dwExtraInfo = extraInfo,
            };
            var ptr = Marshal.AllocHGlobal(Marshal.SizeOf<KeyboardHook.KBDLLHOOKSTRUCT>());
            try
            {
                Marshal.StructureToPtr(info, ptr, fDeleteOld: false);
                var wParam = (nint)(isKeyDown ? KeyboardHook.WmKeyDown : KeyboardHook.WmKeyUp);
                return proc(0, wParam, ptr);
            }
            finally
            {
                Marshal.FreeHGlobal(ptr);
            }
        }

        private KeyboardHook.HookBackend BuildBackend() => new()
        {
            GetModuleHandle = () => 1,
            SetHook = (KeyboardHook.LowLevelKeyboardProc proc, nint _, out int error) =>
            {
                error = 0;
                ActiveProc = proc;
                SetHookCount++;
                SetHookThreadIds.Add(currentThreadId.Value);
                HookRemoved.Reset();
                HookInstalled.Set();
                return nextHookHandle++;
            },
            Unhook = (nint _, out int error) =>
            {
                UnhookCount++;
                HookInstalled.Reset();
                if (ScriptedUnhook?.Invoke() is { } scripted)
                {
                    error = scripted.error;
                    HookRemoved.Set();
                    return scripted.ok;
                }
                error = 0;
                HookRemoved.Set();
                return true;
            },
            CallNextHook = (_, _, _, _) =>
            {
                CallNextHookCount++;
                return CallNextSentinel;
            },
            PeekMessage = (out KeyboardHook.MSG msg, nint _, uint _, uint _, uint _) =>
            {
                msg = default;
                var id = unchecked((uint)Interlocked.Increment(ref nextThreadId));
                currentThreadId.Value = id;
                queues[id] = new BlockingCollection<KeyboardHook.MSG>();
                return false;
            },
            GetCurrentThreadId = () => currentThreadId.Value,
            GetMessage = (out KeyboardHook.MSG msg, nint _, uint _, uint _, out int error) =>
            {
                msg = default;
                var id = currentThreadId.Value;
                if (ScriptedGetMessage?.Invoke(SetHookCount) is { } scripted)
                {
                    error = scripted.error;
                    if (scripted.status <= 0 && queues.TryRemove(id, out var removed))
                        removed.CompleteAdding();
                    return scripted.status;
                }
                error = 0;
                if (!queues.TryGetValue(id, out var queue))
                    return 0;
                try
                {
                    msg = queue.Take();
                }
                catch (InvalidOperationException)
                {
                    return 0;
                }
                if (msg.message == KeyboardHook.WmQuit)
                {
                    queues.TryRemove(id, out _);
                    queue.CompleteAdding();
                    return 0;
                }
                return 1;
            },
            TranslateMessage = (ref KeyboardHook.MSG _) => true,
            DispatchMessage = _ => 0,
            PostThreadMessage = (uint tid, uint message, nuint wParam, nint lParam, out int error) =>
            {
                if (ScriptedPostThreadMessage?.Invoke(tid, message) is { } scripted)
                {
                    error = scripted.error;
                    return scripted.ok;
                }
                if (queues.TryGetValue(tid, out var queue))
                {
                    try
                    {
                        queue.Add(new KeyboardHook.MSG { message = message, wParam = wParam, lParam = lParam });
                        error = 0;
                        return true;
                    }
                    catch (InvalidOperationException)
                    {
                    }
                }
                error = 1444;
                return false;
            },
            IsKeyDown = vk => KeyDownState(vk),
            SendMenuMask = () => SendMenuMaskResult(),
        };

        public void Dispose()
        {
            foreach (var queue in queues.Values)
                queue.CompleteAdding();
            HookInstalled.Dispose();
            HookRemoved.Dispose();
            currentThreadId.Dispose();
        }
    }

    [Fact]
    public async Task HookCallbackCompletionDoesNotBlockWhenCancellationCallbackIsInFlight()
    {
        using var host = new FakeHookHost();
        using var hook = host.CreateHook();
        using var cts = new CancellationTokenSource();
        using var cancelStarted = new ManualResetEventSlim(false);
        using var allowCancelFinish = new ManualResetEventSlim(false);

        var recordTask = hook.RecordAsync(cts.Token);
        Assert.True(host.HookInstalled.Wait(TimeSpan.FromSeconds(2)));

        using var blockingSibling = cts.Token.Register(() =>
        {
            cancelStarted.Set();
            allowCancelFinish.Wait(TimeSpan.FromSeconds(5));
        });

        var cancelTask = Task.Run(() => cts.Cancel());
        Assert.True(cancelStarted.Wait(TimeSpan.FromSeconds(2)));

        // Complete recording inside the hook callback while cts.Cancel() is blocked in another callback.
        var hookCallTask = Task.Run(() =>
        {
            var r1 = host.SendKey(VkLControl, isKeyDown: true);
            var r2 = host.SendKey(VkNonConvert, isKeyDown: true);
            return (r1, r2);
        });

        var completedHook = await Task.WhenAny(hookCallTask, Task.Delay(TimeSpan.FromSeconds(2)));
        Assert.Same(hookCallTask, completedHook);
        var (r1, r2) = await hookCallTask;
        Assert.Equal((nint)1, r1);
        Assert.Equal((nint)1, r2);

        var chord = await recordTask.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.Equal(new HotkeyChord(HotkeyModifier.Ctrl, VkNonConvert), chord);

        allowCancelFinish.Set();
        await cancelTask.WaitAsync(TimeSpan.FromSeconds(2));
    }

    [Fact]
    public async Task RecordAsyncSupersedeDoesNotDeadlockWhilePreviousCancellationIsInFlight()
    {
        using var host = new FakeHookHost();
        using var hook = host.CreateHook();
        using var cts1 = new CancellationTokenSource();
        using var cts2 = new CancellationTokenSource();
        using var cancelStarted = new ManualResetEventSlim(false);
        using var allowCancelFinish = new ManualResetEventSlim(false);

        var firstTask = hook.RecordAsync(cts1.Token);
        Assert.True(host.HookInstalled.Wait(TimeSpan.FromSeconds(2)));

        using var blockingSibling = cts1.Token.Register(() =>
        {
            cancelStarted.Set();
            allowCancelFinish.Wait(TimeSpan.FromSeconds(5));
        });

        var cancelTask = Task.Run(() => cts1.Cancel());
        Assert.True(cancelStarted.Wait(TimeSpan.FromSeconds(2)));

        // Replacing the recording session must not block on the prior CancellationToken's Dispose().
        var supersedeTask = Task.Factory.StartNew(
            () => hook.RecordAsync(cts2.Token),
            CancellationToken.None,
            TaskCreationOptions.DenyChildAttach,
            TaskScheduler.Default);
        var completedSupersede = await Task.WhenAny(supersedeTask, Task.Delay(TimeSpan.FromSeconds(2)));
        Assert.Same(supersedeTask, completedSupersede);
        var secondTask = await supersedeTask;

        allowCancelFinish.Set();
        await cancelTask.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.Null(await firstTask.WaitAsync(TimeSpan.FromSeconds(2)));

        cts2.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => secondTask.WaitAsync(TimeSpan.FromSeconds(2)));
    }

    [Fact]
    public async Task ConcurrentRecordingCompletionAndCancellationNeverDeadlock()
    {
        using var host = new FakeHookHost();
        using var hook = host.CreateHook();
        hook.Enable(HotkeyChord.Default);
        Assert.True(host.HookInstalled.Wait(TimeSpan.FromSeconds(2)));

        for (var i = 0; i < 100; i++)
        {
            using var cts = new CancellationTokenSource();
            var task = hook.RecordAsync(cts.Token);

            var cancelTask = Task.Run(() => cts.Cancel());
            var hookTask = Task.Run(() =>
            {
                host.SendKey(VkLControl, isKeyDown: true);
                host.SendKey(VkNonConvert, isKeyDown: true);
                host.SendKey(VkNonConvert, isKeyDown: false);
                host.SendKey(VkLControl, isKeyDown: false);
            });

            await Task.WhenAll(cancelTask, hookTask).WaitAsync(TimeSpan.FromSeconds(2));
            try
            {
                await task.WaitAsync(TimeSpan.FromSeconds(2));
            }
            catch (OperationCanceledException)
            {
            }

            using var ctsA = new CancellationTokenSource();
            using var ctsB = new CancellationTokenSource();
            var taskA = hook.RecordAsync(ctsA.Token);
            var cancelATask = Task.Run(() => ctsA.Cancel());
            var taskB = await Task.Factory.StartNew(
                () => hook.RecordAsync(ctsB.Token),
                CancellationToken.None,
                TaskCreationOptions.DenyChildAttach,
                TaskScheduler.Default).WaitAsync(TimeSpan.FromSeconds(2));
            await cancelATask.WaitAsync(TimeSpan.FromSeconds(2));
            try { await taskA.WaitAsync(TimeSpan.FromSeconds(2)); }
            catch (OperationCanceledException) { }
            ctsB.Cancel();
            try { await taskB.WaitAsync(TimeSpan.FromSeconds(2)); }
            catch (OperationCanceledException) { }
        }
    }

    [Fact]
    public void HookPassesWinVAndDoesNotTriggerWhenMenuMaskSendInputFails()
    {
        using var host = new FakeHookHost();
        var winDown = false;
        host.KeyDownState = vk => vk == VkLWin && winDown;
        host.SendMenuMaskResult = () => false;

        using var hook = host.CreateHook();
        hook.Enable(HotkeyChord.Default);
        Assert.True(host.HookInstalled.Wait(TimeSpan.FromSeconds(2)));

        winDown = true;
        Assert.Equal(CallNextSentinel, host.SendKey(VkLWin, isKeyDown: true));
        Assert.Equal(CallNextSentinel, host.SendKey(VkV, isKeyDown: true));
        Assert.Equal(CallNextSentinel, host.SendKey(VkV, isKeyDown: true));
        Assert.Equal(CallNextSentinel, host.SendKey(VkV, isKeyDown: false));
        winDown = false;
        Assert.Equal(CallNextSentinel, host.SendKey(VkLWin, isKeyDown: false));

        Assert.Equal(0, host.TriggeredCount);
        Assert.Equal(5, host.CallNextHookCount);
        Assert.Contains(host.Logs, entry => entry.Contains("menu mask failed", StringComparison.Ordinal));
    }

    [Fact]
    public void HookSwallowsAndTriggersWinVWhenMenuMaskSucceeds()
    {
        using var host = new FakeHookHost();
        var winDown = false;
        host.KeyDownState = vk => vk == VkLWin && winDown;
        host.SendMenuMaskResult = () => true;

        using var hook = host.CreateHook();
        hook.Enable(HotkeyChord.Default);
        Assert.True(host.HookInstalled.Wait(TimeSpan.FromSeconds(2)));

        winDown = true;
        Assert.Equal(CallNextSentinel, host.SendKey(VkLWin, isKeyDown: true));
        Assert.Equal((nint)1, host.SendKey(VkV, isKeyDown: true));
        Assert.Equal((nint)1, host.SendKey(VkV, isKeyDown: true));
        winDown = false;
        Assert.Equal(CallNextSentinel, host.SendKey(VkLWin, isKeyDown: false));
        Assert.Equal((nint)1, host.SendKey(VkV, isKeyDown: false));

        Assert.Equal(1, host.TriggeredCount);
        Assert.Equal(2, host.CallNextHookCount);
    }

    [Fact]
    public void HookThreadRestartsOnNextEnableAfterGetMessageFailure()
    {
        using var host = new FakeHookHost();
        host.ScriptedGetMessage = hookCount => hookCount == 1 ? (-1, 1400) : null;

        using var hook = host.CreateHook();
        hook.Enable(HotkeyChord.Default);

        // First loop installs hook, then exits with GetMessage == -1 and cleans up.
        Assert.True(host.HookRemoved.Wait(TimeSpan.FromSeconds(2)));
        Assert.Contains(host.Logs, entry => entry.Contains("getmessage failed error=1400", StringComparison.Ordinal));

        // Re-enabling after abnormal exit must start a new thread and re-install the hook.
        host.HookInstalled.Reset();
        hook.Enable(new HotkeyChord(HotkeyModifier.Ctrl, VkNonConvert));
        Assert.True(host.HookInstalled.Wait(TimeSpan.FromSeconds(2)));
        Assert.Equal(2, host.SetHookCount);
        Assert.Equal(2, host.SetHookThreadIds.Distinct().Count());
    }

    [Fact]
    public void UnhookAndPostThreadMessageFailuresAreLoggedWithoutThrowing()
    {
        using var host = new FakeHookHost();
        host.ScriptedUnhook = () => (false, 1404);
        var failSyncPost = false;
        host.ScriptedPostThreadMessage = (_, msg) =>
            failSyncPost && msg == KeyboardHook.WmSyncHook ? (false, 1444) : null;

        using var hook = host.CreateHook();
        hook.Enable(HotkeyChord.Default);
        Assert.True(host.HookInstalled.Wait(TimeSpan.FromSeconds(2)));

        hook.Disable();
        Assert.True(host.HookRemoved.Wait(TimeSpan.FromSeconds(2)));

        failSyncPost = true;
        hook.Disable();
        hook.Dispose();

        Assert.Contains(host.Logs, entry => entry.Contains("remove failed error=1404", StringComparison.Ordinal));
        Assert.Contains(host.Logs, entry => entry.Contains("post message failed error=1444", StringComparison.Ordinal));
    }
}
