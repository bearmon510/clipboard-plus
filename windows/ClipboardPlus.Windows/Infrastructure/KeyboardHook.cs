using System.Runtime.InteropServices;
using ClipboardPlus.Windows.Core;

namespace ClipboardPlus.Windows.Infrastructure;

/// <summary>Global low-level keyboard hook running on a dedicated Win32 message-loop thread.</summary>
internal sealed class KeyboardHook : IDisposable
{
    internal const int WhKeyboardLl = 13;
    internal const int WmKeyDown = 0x0100;
    internal const int WmKeyUp = 0x0101;
    internal const int WmSysKeyDown = 0x0104;
    internal const int WmSysKeyUp = 0x0105;
    internal const uint WmQuit = 0x0012;
    internal const uint WmSyncHook = 0x8001;
    internal const uint LlkhfInjected = 0x00000010;

    private readonly Action onTriggered;
    private readonly Action<Action> dispatch;
    private readonly Action<string> log;
    private readonly HookBackend backend;
    private readonly HotkeyMatcher matcher = new();
    private readonly LowLevelKeyboardProc hookProc;
    private readonly object lifecycleGate = new();

    private Thread? thread;
    private uint nativeThreadId;
    private bool loopRunning;
    private long syncRequestedVersion;
    private long lastSyncedVersion;
    private nint hook;
    private bool enabled;
    private volatile bool disposed;
    private TaskCompletionSource<HotkeyChord?>? recordTcs;
    private CancellationTokenRegistration recordRegistration;

    public KeyboardHook(Action onTriggered, Action<Action> dispatch, Action<string> log)
        : this(onTriggered, dispatch, log, HookBackend.Native)
    {
    }

    internal KeyboardHook(Action onTriggered, Action<Action> dispatch, Action<string> log, HookBackend backend)
    {
        this.onTriggered = onTriggered ?? throw new ArgumentNullException(nameof(onTriggered));
        this.dispatch = dispatch ?? throw new ArgumentNullException(nameof(dispatch));
        this.log = log ?? throw new ArgumentNullException(nameof(log));
        this.backend = backend ?? throw new ArgumentNullException(nameof(backend));
        hookProc = HookCallback;
    }

    public void Enable(HotkeyChord chord)
    {
        if (!chord.IsValid)
            throw new ArgumentException("Invalid hotkey chord.", nameof(chord));

        lock (lifecycleGate)
        {
            if (disposed) return;
            matcher.Target = chord;
            enabled = true;
            syncRequestedVersion++;
        }

        if (!EnsureHookThreadAndGetId(out var threadId))
            return;

        PostSyncOrRecover(threadId, allowRecover: true);
    }

    public void Disable()
    {
        uint threadId;
        lock (lifecycleGate)
        {
            enabled = false;
            matcher.Target = null;
            syncRequestedVersion++;
            if (disposed || nativeThreadId == 0 || !loopRunning) return;
            threadId = nativeThreadId;
        }
        PostSyncMessage(threadId);
    }

    public Task<HotkeyChord?> RecordAsync(CancellationToken cancellationToken = default)
    {
        if (cancellationToken.IsCancellationRequested)
            return Task.FromCanceled<HotkeyChord?>(cancellationToken);

        var tcs = new TaskCompletionSource<HotkeyChord?>(TaskCreationOptions.RunContinuationsAsynchronously);
        TaskCompletionSource<HotkeyChord?>? previousTcs;
        CancellationTokenRegistration previousReg;

        lock (lifecycleGate)
        {
            if (disposed)
                return Task.FromResult<HotkeyChord?>(null);

            previousTcs = recordTcs;
            previousReg = recordRegistration;
            recordTcs = tcs;
            recordRegistration = default;
            matcher.StartRecording();
            syncRequestedVersion++;
        }

        // Unregister outside lifecycleGate so we never wait on an in-flight cancellation callback.
        previousReg.Unregister();
        previousTcs?.TrySetResult(null);

        if (!EnsureHookThreadAndGetId(out var threadId))
        {
            CancellationTokenRegistration failedReg = default;
            var failedSelf = false;
            lock (lifecycleGate)
            {
                if (recordTcs == tcs)
                {
                    failedReg = recordRegistration;
                    recordTcs = null;
                    recordRegistration = default;
                    matcher.CancelRecording();
                    syncRequestedVersion++;
                    failedSelf = true;
                }
            }
            failedReg.Unregister();
            if (failedSelf)
                tcs.TrySetResult(null);
            return tcs.Task;
        }

        PostSyncOrRecover(threadId, allowRecover: true);

        if (cancellationToken.CanBeCanceled)
        {
            var reg = cancellationToken.Register(() => CancelRecording(tcs, cancellationToken));
            bool keepReg;
            lock (lifecycleGate)
            {
                keepReg = !disposed && recordTcs == tcs;
                if (keepReg)
                    recordRegistration = reg;
            }
            if (!keepReg)
                reg.Unregister();
        }

        return tcs.Task;
    }

    public void Dispose()
    {
        TaskCompletionSource<HotkeyChord?>? pendingTcs;
        CancellationTokenRegistration pendingReg;
        Thread? hookThread;
        uint threadId;
        bool shouldPostQuit;

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
            shouldPostQuit = threadId != 0 && loopRunning;
            thread = null;
            nativeThreadId = 0;
            loopRunning = false;
        }

        pendingReg.Unregister();
        pendingTcs?.TrySetResult(null);

        if (shouldPostQuit && !backend.PostThreadMessage(threadId, WmQuit, 0, 0, out var error))
            log($"keyboard hook quit failed error={error}");

        if (hookThread is not null && Thread.CurrentThread != hookThread)
            hookThread.Join(TimeSpan.FromSeconds(2));
    }

    private bool EnsureHookThreadAndGetId(out uint threadId)
    {
        for (var attempt = 0; attempt < 2; attempt++)
        {
            Thread? exitingThread;
            lock (lifecycleGate)
            {
                if (disposed)
                {
                    threadId = 0;
                    return false;
                }

                if (thread is not null)
                {
                    if (loopRunning && thread.IsAlive && nativeThreadId != 0)
                    {
                        threadId = nativeThreadId;
                        return true;
                    }
                    exitingThread = thread;
                }
                else
                {
                    if (StartThreadLocked())
                    {
                        threadId = nativeThreadId;
                        return true;
                    }
                    threadId = 0;
                    return false;
                }
            }

            if (Thread.CurrentThread != exitingThread)
                exitingThread.Join(TimeSpan.FromSeconds(1));

            lock (lifecycleGate)
            {
                if (ReferenceEquals(thread, exitingThread) && !exitingThread.IsAlive)
                {
                    thread = null;
                    nativeThreadId = 0;
                    loopRunning = false;
                }
            }
        }

        threadId = 0;
        return false;
    }

    private bool StartThreadLocked()
    {
        if (disposed) return false;

        using var ready = new ManualResetEventSlim(false);
        var started = new Thread(() => MessageLoop(ready))
        {
            IsBackground = true,
            Name = "clipboard+ keyboard hook",
        };
        thread = started;
        loopRunning = true;
        try
        {
            started.Start();
        }
        catch
        {
            thread = null;
            nativeThreadId = 0;
            loopRunning = false;
            return false;
        }

        ready.Wait();
        if (nativeThreadId == 0)
        {
            thread = null;
            loopRunning = false;
            return false;
        }
        return true;
    }

    private void PostSyncOrRecover(uint threadId, bool allowRecover)
    {
        if (PostSyncMessage(threadId) || !allowRecover)
            return;

        Thread? exitingThread = null;
        uint existingActiveId = 0;
        lock (lifecycleGate)
        {
            if (disposed || (!enabled && recordTcs is null))
                return;

            if (nativeThreadId != 0 && nativeThreadId != threadId && loopRunning)
            {
                existingActiveId = nativeThreadId;
            }
            else if (thread is not null)
            {
                if (loopRunning && thread.IsAlive)
                    return;
                exitingThread = thread;
            }
        }

        if (existingActiveId != 0)
        {
            PostSyncMessage(existingActiveId);
            return;
        }

        if (exitingThread is not null)
        {
            if (Thread.CurrentThread != exitingThread)
                exitingThread.Join(TimeSpan.FromSeconds(1));

            lock (lifecycleGate)
            {
                if (ReferenceEquals(thread, exitingThread) && !exitingThread.IsAlive)
                {
                    thread = null;
                    nativeThreadId = 0;
                    loopRunning = false;
                }
            }
        }

        if (EnsureHookThreadAndGetId(out var restartedId))
            PostSyncMessage(restartedId);
    }

    private bool PostSyncMessage(uint threadId)
    {
        if (backend.PostThreadMessage(threadId, WmSyncHook, 0, 0, out var error))
            return true;
        log($"keyboard hook post message failed error={error}");
        return false;
    }

    private void ResyncIfNeeded()
    {
        lock (lifecycleGate)
        {
            if (disposed || (!enabled && recordTcs is null))
                return;
        }
        if (EnsureHookThreadAndGetId(out var threadId))
            PostSyncMessage(threadId);
    }

    private void MessageLoop(ManualResetEventSlim ready)
    {
        try
        {
            // Force creation of the thread message queue before releasing StartThreadLocked.
            backend.PeekMessage(out _, 0, 0, 0, 0);
            nativeThreadId = backend.GetCurrentThreadId();
        }
        finally
        {
            ready.Set();
        }

        try
        {
            SyncHookState();
            while (true)
            {
                var status = backend.GetMessage(out var msg, 0, 0, 0, out var error);
                if (status == 0)
                    break;
                if (status < 0)
                {
                    log($"keyboard hook getmessage failed error={error}");
                    break;
                }

                if (msg.message == WmSyncHook)
                {
                    SyncHookState();
                }
                else
                {
                    backend.TranslateMessage(ref msg);
                    backend.DispatchMessage(msg);
                }
            }
        }
        catch (Exception ex)
        {
            log($"keyboard hook loop error={ex.GetType().Name}");
        }
        finally
        {
            lock (lifecycleGate)
            {
                if (ReferenceEquals(thread, Thread.CurrentThread))
                    loopRunning = false;
            }
            UninstallHook();
            FailPendingRecording();
            bool missedSync;
            lock (lifecycleGate)
            {
                if (ReferenceEquals(thread, Thread.CurrentThread))
                {
                    thread = null;
                    nativeThreadId = 0;
                    loopRunning = false;
                }
                missedSync = !disposed && (enabled || recordTcs is not null) && syncRequestedVersion != lastSyncedVersion;
            }
            if (missedSync)
                ThreadPool.QueueUserWorkItem(_ => ResyncIfNeeded());
        }
    }

    private void SyncHookState()
    {
        bool shouldHook;
        lock (lifecycleGate)
        {
            shouldHook = !disposed && (enabled || recordTcs is not null);
            lastSyncedVersion = syncRequestedVersion;
        }

        if (shouldHook && hook == 0)
        {
            var module = backend.GetModuleHandle();
            hook = backend.SetHook(hookProc, module, out var error);
            if (hook == 0)
            {
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
        if (!backend.Unhook(hook, out var error))
            log($"keyboard hook remove failed error={error}");
        else
            log("keyboard hook removed");
        hook = 0;
        matcher.Reset();
    }

    private nint HookCallback(int nCode, nint wParam, nint lParam)
    {
        if (nCode < 0 || disposed)
            return backend.CallNextHook(hook, nCode, wParam, lParam);

        var msg = unchecked((int)wParam);
        var isKeyDown = msg is WmKeyDown or WmSysKeyDown;
        var isKeyUp = msg is WmKeyUp or WmSysKeyUp;
        if (!isKeyDown && !isKeyUp)
            return backend.CallNextHook(hook, nCode, wParam, lParam);

        var info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        var isSelfInjected = (info.flags & LlkhfInjected) != 0 && info.dwExtraInfo == NativeInput.SelfExtraInfo;
        if (isSelfInjected)
            return backend.CallNextHook(hook, nCode, wParam, lParam);

        var currentVk = unchecked((int)info.vkCode);
        matcher.PruneReleasedKeys(backend.IsKeyDown);
        var result = matcher.Process(currentVk, isKeyDown, isInjected: false);

        if (result.NeedsMenuMask && !backend.SendMenuMask())
        {
            matcher.RevertSwallowToPass(currentVk);
            log("keyboard hook menu mask failed");
            return backend.CallNextHook(hook, nCode, wParam, lParam);
        }

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
            : backend.CallNextHook(hook, nCode, wParam, lParam);
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
        reg.Unregister();
        tcs?.TrySetResult(null);
    }

    private void CompleteRecording(HotkeyChord? chord)
    {
        TaskCompletionSource<HotkeyChord?>? tcs;
        CancellationTokenRegistration reg;
        uint threadId = 0;
        lock (lifecycleGate)
        {
            if (recordTcs is null || matcher.IsRecording)
                return;
            tcs = recordTcs;
            reg = recordRegistration;
            recordTcs = null;
            recordRegistration = default;
            if (!enabled && !disposed && loopRunning) threadId = nativeThreadId;
        }
        // Unregister without blocking inside the low-level hook callback.
        reg.Unregister();
        tcs.TrySetResult(chord);
        if (threadId != 0)
            PostSyncMessage(threadId);
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
            if (!enabled && !disposed && loopRunning) threadId = nativeThreadId;
        }
        reg.Unregister();
        targetTcs.TrySetCanceled(token);
        if (threadId != 0)
            PostSyncMessage(threadId);
    }

    internal delegate nint LowLevelKeyboardProc(int nCode, nint wParam, nint lParam);

    internal sealed class HookBackend
    {
        public delegate nint SetHookDelegate(LowLevelKeyboardProc proc, nint module, out int error);
        public delegate bool UnhookDelegate(nint hookHandle, out int error);
        public delegate int GetMessageDelegate(out MSG msg, nint hwnd, uint filterMin, uint filterMax, out int error);
        public delegate bool PeekMessageDelegate(out MSG msg, nint hwnd, uint filterMin, uint filterMax, uint removeMsg);
        public delegate bool TranslateMessageDelegate(ref MSG msg);
        public delegate bool PostThreadMessageDelegate(uint threadId, uint msg, nuint wParam, nint lParam, out int error);

        public static HookBackend Native { get; } = new();

        public Func<nint> GetModuleHandle { get; init; } = () => KeyboardHook.GetModuleHandle(null);
        public SetHookDelegate SetHook { get; init; } = static (proc, mod, out error) =>
        {
            var handle = SetWindowsHookEx(WhKeyboardLl, proc, mod, 0);
            error = handle == 0 ? Marshal.GetLastWin32Error() : 0;
            return handle;
        };
        public UnhookDelegate Unhook { get; init; } = static (hhk, out error) =>
        {
            var ok = UnhookWindowsHookEx(hhk);
            error = ok ? 0 : Marshal.GetLastWin32Error();
            return ok;
        };
        public Func<nint, int, nint, nint, nint> CallNextHook { get; init; } = CallNextHookEx;
        public PeekMessageDelegate PeekMessage { get; init; } =
            static (out MSG msg, nint hwnd, uint min, uint max, uint remove) =>
                KeyboardHook.PeekMessage(out msg, hwnd, min, max, remove);
        public GetMessageDelegate GetMessage { get; init; } = static (out MSG msg, nint hwnd, uint min, uint max, out int error) =>
        {
            var status = KeyboardHook.GetMessage(out msg, hwnd, min, max);
            error = status < 0 ? Marshal.GetLastWin32Error() : 0;
            return status;
        };
        public TranslateMessageDelegate TranslateMessage { get; init; } =
            static (ref MSG msg) => KeyboardHook.TranslateMessage(ref msg);
        public Func<MSG, nint> DispatchMessage { get; init; } =
            static msg => KeyboardHook.DispatchMessage(ref msg);
        public PostThreadMessageDelegate PostThreadMessage { get; init; } =
            static (uint idThread, uint msg, nuint wParam, nint lParam, out int error) =>
            {
                var ok = KeyboardHook.PostThreadMessage(idThread, msg, wParam, lParam);
                error = ok ? 0 : Marshal.GetLastWin32Error();
                return ok;
            };
        public Func<uint> GetCurrentThreadId { get; init; } = KeyboardHook.GetCurrentThreadId;
        public Func<int, bool> IsKeyDown { get; init; } = NativeInput.IsKeyDown;
        public Func<bool> SendMenuMask { get; init; } = NativeInput.SendMenuMask;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public nuint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct POINT
    {
        public int x;
        public int y;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MSG
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

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(nint hhk);

    [DllImport("user32.dll")]
    private static extern nint CallNextHookEx(nint hhk, int nCode, nint wParam, nint lParam);

    [DllImport("user32.dll", SetLastError = true)]
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
