using System.Runtime.InteropServices;
using ClipboardPlus.Windows.Core;

namespace ClipboardPlus.Windows.Infrastructure;

/// <summary>Global low-level keyboard hook running on a dedicated Win32 message-loop thread.</summary>
internal sealed class KeyboardHook : IDisposable
{
    private const int WhKeyboardLl = 13;
    private const int WmKeyDown = 0x0100;
    private const int WmKeyUp = 0x0101;
    private const int WmSysKeyDown = 0x0104;
    private const int WmSysKeyUp = 0x0105;
    private const uint WmQuit = 0x0012;
    private const uint WmSyncHook = 0x8001;
    private const uint LlkhfInjected = 0x00000010;

    private readonly Action onTriggered;
    private readonly Action<Action> dispatch;
    private readonly Action<string> log;
    private readonly HotkeyMatcher matcher = new();
    private readonly LowLevelKeyboardProc hookProc;
    private readonly object lifecycleGate = new();

    private Thread? thread;
    private uint nativeThreadId;
    private nint hook;
    private bool enabled;
    private volatile bool disposed;
    private TaskCompletionSource<HotkeyChord?>? recordTcs;
    private CancellationTokenRegistration recordRegistration;

    public KeyboardHook(Action onTriggered, Action<Action> dispatch, Action<string> log)
    {
        this.onTriggered = onTriggered ?? throw new ArgumentNullException(nameof(onTriggered));
        this.dispatch = dispatch ?? throw new ArgumentNullException(nameof(dispatch));
        this.log = log ?? throw new ArgumentNullException(nameof(log));
        hookProc = HookCallback;
    }

    public void Enable(HotkeyChord chord)
    {
        if (!chord.IsValid)
            throw new ArgumentException("Invalid hotkey chord.", nameof(chord));

        uint threadId;
        lock (lifecycleGate)
        {
            if (disposed) return;
            matcher.Target = chord;
            enabled = true;
            if (!EnsureThreadStartedLocked()) return;
            threadId = nativeThreadId;
        }
        PostThreadMessage(threadId, WmSyncHook, 0, 0);
    }

    public void Disable()
    {
        uint threadId;
        lock (lifecycleGate)
        {
            enabled = false;
            matcher.Target = null;
            if (disposed || nativeThreadId == 0) return;
            threadId = nativeThreadId;
        }
        PostThreadMessage(threadId, WmSyncHook, 0, 0);
    }

    public Task<HotkeyChord?> RecordAsync(CancellationToken cancellationToken = default)
    {
        if (cancellationToken.IsCancellationRequested)
            return Task.FromCanceled<HotkeyChord?>(cancellationToken);

        var tcs = new TaskCompletionSource<HotkeyChord?>(TaskCreationOptions.RunContinuationsAsynchronously);
        TaskCompletionSource<HotkeyChord?>? previousTcs;
        CancellationTokenRegistration previousReg;
        uint threadId;

        lock (lifecycleGate)
        {
            if (disposed)
                return Task.FromResult<HotkeyChord?>(null);

            previousTcs = recordTcs;
            previousReg = recordRegistration;
            recordTcs = tcs;
            recordRegistration = default;
            matcher.StartRecording();

            if (!EnsureThreadStartedLocked())
            {
                recordTcs = null;
                matcher.CancelRecording();
                previousReg.Dispose();
                previousTcs?.TrySetResult(null);
                return Task.FromResult<HotkeyChord?>(null);
            }

            threadId = nativeThreadId;
        }

        previousReg.Dispose();
        previousTcs?.TrySetResult(null);
        PostThreadMessage(threadId, WmSyncHook, 0, 0);

        if (cancellationToken.CanBeCanceled)
        {
            var reg = cancellationToken.Register(() => CancelRecording(tcs, cancellationToken));
            lock (lifecycleGate)
            {
                if (recordTcs == tcs)
                {
                    recordRegistration = reg;
                }
                else
                {
                    reg.Dispose();
                }
            }
        }

        return tcs.Task;
    }

    public void Dispose()
    {
        TaskCompletionSource<HotkeyChord?>? pendingTcs;
        CancellationTokenRegistration pendingReg;
        Thread? hookThread;
        uint threadId;

        lock (lifecycleGate)
        {
            if (disposed) return;
            disposed = true;
            enabled = false;
            matcher.Reset();
            pendingTcs = recordTcs;
            pendingReg = recordRegistration;
            recordTcs = null;
            recordRegistration = default;
            hookThread = thread;
            threadId = nativeThreadId;
        }

        pendingReg.Dispose();
        pendingTcs?.TrySetResult(null);

        if (threadId != 0)
            PostThreadMessage(threadId, WmQuit, 0, 0);

        if (hookThread is not null && Thread.CurrentThread != hookThread)
            hookThread.Join(TimeSpan.FromSeconds(2));
    }

    private bool EnsureThreadStartedLocked()
    {
        if (disposed) return false;
        if (thread is not null) return true;

        using var ready = new ManualResetEventSlim(false);
        var started = new Thread(() => MessageLoop(ready))
        {
            IsBackground = true,
            Name = "clipboard+ keyboard hook",
        };
        thread = started;
        started.Start();
        ready.Wait();
        return nativeThreadId != 0;
    }

    private void MessageLoop(ManualResetEventSlim ready)
    {
        try
        {
            // Force creation of the thread message queue before releasing EnsureThreadStartedLocked.
            PeekMessage(out _, 0, 0, 0, 0);
            nativeThreadId = GetCurrentThreadId();
        }
        finally
        {
            ready.Set();
        }

        try
        {
            SyncHookState();
            while (GetMessage(out var msg, 0, 0, 0) > 0)
            {
                if (msg.message == WmSyncHook)
                {
                    SyncHookState();
                }
                else
                {
                    TranslateMessage(ref msg);
                    DispatchMessage(ref msg);
                }
            }
        }
        catch (Exception ex)
        {
            log($"keyboard hook loop error={ex.GetType().Name}");
        }
        finally
        {
            UninstallHook();
        }
    }

    private void SyncHookState()
    {
        bool shouldHook;
        lock (lifecycleGate)
        {
            shouldHook = !disposed && (enabled || recordTcs is not null);
        }

        if (shouldHook && hook == 0)
        {
            var module = GetModuleHandle(null);
            hook = SetWindowsHookEx(WhKeyboardLl, hookProc, module, 0);
            if (hook == 0)
            {
                var error = Marshal.GetLastWin32Error();
                log($"keyboard hook install failed error={error}");
                FailPendingRecording();
            }
            else
            {
                log("keyboard hook installed");
            }
        }
        else if (!shouldHook && hook != 0)
        {
            UninstallHook();
        }
    }

    private void UninstallHook()
    {
        if (hook == 0) return;
        UnhookWindowsHookEx(hook);
        hook = 0;
        matcher.Reset();
        log("keyboard hook removed");
    }

    private nint HookCallback(int nCode, nint wParam, nint lParam)
    {
        if (nCode < 0 || disposed)
            return CallNextHookEx(hook, nCode, wParam, lParam);

        var msg = unchecked((int)wParam);
        var isKeyDown = msg is WmKeyDown or WmSysKeyDown;
        var isKeyUp = msg is WmKeyUp or WmSysKeyUp;
        if (!isKeyDown && !isKeyUp)
            return CallNextHookEx(hook, nCode, wParam, lParam);

        var info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        var isSelfInjected = (info.flags & LlkhfInjected) != 0 && info.dwExtraInfo == NativeInput.SelfExtraInfo;
        if (isSelfInjected)
            return CallNextHookEx(hook, nCode, wParam, lParam);

        var currentVk = unchecked((int)info.vkCode);
        matcher.PruneReleasedKeys(vk => vk == currentVk || NativeInput.IsKeyDown(vk));
        var result = matcher.Process(currentVk, isKeyDown, isInjected: false);

        if (result.NeedsMenuMask)
            NativeInput.SendMenuMask();

        if (result.RecordedChord is { } recorded)
            CompleteRecording(recorded);
        else if (result.RecordingCancelled)
            CompleteRecording(null);

        if (result.Action == HotkeyAction.SwallowAndTrigger)
        {
            try { dispatch(onTriggered); }
            catch { }
            return 1;
        }

        return result.Action == HotkeyAction.Swallow
            ? 1
            : CallNextHookEx(hook, nCode, wParam, lParam);
    }

    private void FailPendingRecording()
    {
        TaskCompletionSource<HotkeyChord?>? tcs;
        CancellationTokenRegistration reg;
        lock (lifecycleGate)
        {
            tcs = recordTcs;
            reg = recordRegistration;
            recordTcs = null;
            recordRegistration = default;
            matcher.CancelRecording();
        }
        reg.Dispose();
        tcs?.TrySetResult(null);
    }

    private void CompleteRecording(HotkeyChord? chord)
    {
        TaskCompletionSource<HotkeyChord?>? tcs;
        CancellationTokenRegistration reg;
        uint threadId = 0;
        lock (lifecycleGate)
        {
            tcs = recordTcs;
            reg = recordRegistration;
            recordTcs = null;
            recordRegistration = default;
            if (!enabled && !disposed) threadId = nativeThreadId;
        }
        reg.Dispose();
        tcs?.TrySetResult(chord);
        if (threadId != 0)
            PostThreadMessage(threadId, WmSyncHook, 0, 0);
    }

    private void CancelRecording(TaskCompletionSource<HotkeyChord?> targetTcs, CancellationToken token)
    {
        CancellationTokenRegistration reg;
        uint threadId = 0;
        lock (lifecycleGate)
        {
            if (recordTcs != targetTcs) return;
            recordTcs = null;
            reg = recordRegistration;
            recordRegistration = default;
            matcher.CancelRecording();
            if (!enabled && !disposed) threadId = nativeThreadId;
        }
        reg.Dispose();
        targetTcs.TrySetCanceled(token);
        if (threadId != 0)
            PostThreadMessage(threadId, WmSyncHook, 0, 0);
    }

    private delegate nint LowLevelKeyboardProc(int nCode, nint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public nuint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int x;
        public int y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public nint hwnd;
        public uint message;
        public nuint wParam;
        public nint lParam;
        public uint time;
        public POINT pt;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, nint hmod, uint dwThreadId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(nint hhk);

    [DllImport("user32.dll")]
    private static extern nint CallNextHookEx(nint hhk, int nCode, nint wParam, nint lParam);

    [DllImport("user32.dll")]
    private static extern int GetMessage(out MSG lpMsg, nint hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PeekMessage(out MSG lpMsg, nint hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern nint DispatchMessage(ref MSG lpMsg);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostThreadMessage(uint idThread, uint msg, nuint wParam, nint lParam);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint GetModuleHandle(string? lpModuleName);
}
