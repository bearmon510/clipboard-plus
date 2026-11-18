using System.Runtime.InteropServices;

namespace ClipboardPlus.Windows.Infrastructure;

public sealed record HistoryInvocation(nint PreviousWindow, int? CaretX, int? CaretY, int CursorX, int CursorY);

/// <summary>Captures the active window and caret/cursor position, and restores focus to paste.</summary>
public static class ForegroundContext
{
    public static HistoryInvocation Capture()
    {
        var previousWindow = GetForegroundWindow();
        GetCursorPos(out var cursor);

        int? caretX = null;
        int? caretY = null;
        if (previousWindow != 0)
        {
            var threadId = GetWindowThreadProcessId(previousWindow, out _);
            if (threadId != 0)
            {
                var info = new GUITHREADINFO { cbSize = (uint)Marshal.SizeOf<GUITHREADINFO>() };
                if (GetGUIThreadInfo(threadId, ref info) &&
                    info.hwndCaret != 0 &&
                    (info.rcCaret.left != info.rcCaret.right || info.rcCaret.top != info.rcCaret.bottom))
                {
                    var caretPoint = new POINT { x = info.rcCaret.left, y = info.rcCaret.bottom };
                    if (ClientToScreen(info.hwndCaret, ref caretPoint))
                    {
                        caretX = caretPoint.x;
                        caretY = caretPoint.y;
                    }
                }
            }
        }

        return new HistoryInvocation(previousWindow, caretX, caretY, cursor.x, cursor.y);
    }

    internal sealed record PasteOperations(
        Func<nint, bool> IsWindow,
        Func<nint, bool> SetForegroundWindow,
        Func<nint> GetForegroundWindow,
        Func<bool> IsAnyModifierDown,
        Func<bool> SendCtrlV,
        Func<long> GetTickCount64,
        Func<int, CancellationToken, Task> Delay);

    private static readonly PasteOperations DefaultPasteOperations = new(
        IsWindow,
        SetForegroundWindow,
        GetForegroundWindow,
        NativeInput.IsAnyModifierDown,
        NativeInput.SendCtrlV,
        () => Environment.TickCount64,
        static (ms, ct) => Task.Delay(ms, ct));

    internal static nint CurrentForegroundWindow() => GetForegroundWindow();

    internal static bool IsWindowHandle(nint hwnd) => hwnd != 0 && IsWindow(hwnd);

    internal static bool IsOwnProcessWindow(nint hwnd)
    {
        if (hwnd == 0) return false;
        GetWindowThreadProcessId(hwnd, out var processId);
        return processId == (uint)Environment.ProcessId;
    }

    internal sealed record ActivateOperations(
        Func<nint, bool> IsWindow,
        Func<nint> GetForegroundWindow,
        Func<nint, bool> SetForegroundWindow,
        Func<nint, bool> BringWindowToTop,
        Func<nint, nint> SetActiveWindow,
        Func<nint, bool> IsHungAppWindow,
        Func<nint, uint> GetWindowThreadProcessId,
        Func<uint> GetCurrentThreadId,
        Func<uint, uint, bool, bool> AttachThreadInput,
        Func<bool> SendUnassignedKeyTap,
        Action ActivateManaged);

    private static ActivateOperations CreateDefaultActivateOperations(Action activateManaged) => new(
        IsWindow,
        GetForegroundWindow,
        SetForegroundWindow,
        BringWindowToTop,
        SetActiveWindow,
        IsHungAppWindow,
        hwnd => GetWindowThreadProcessId(hwnd, out _),
        GetCurrentThreadId,
        AttachThreadInput,
        NativeInput.SendMenuMask,
        activateManaged);

    public static bool BringToFront(nint hwnd, Action activateManaged) =>
        BringToFront(hwnd, CreateDefaultActivateOperations(activateManaged));

    internal static bool BringToFront(nint hwnd, ActivateOperations ops)
    {
        if (hwnd == 0 || !ops.IsWindow(hwnd)) return false;

        if (ops.GetForegroundWindow() == hwnd)
        {
            ops.ActivateManaged();
            return true;
        }

        if (ops.SetForegroundWindow(hwnd) && ops.GetForegroundWindow() == hwnd)
        {
            ops.ActivateManaged();
            return true;
        }

        var front = ops.GetForegroundWindow();
        if (front != 0 && front != hwnd && !ops.IsHungAppWindow(front))
        {
            var frontThread = ops.GetWindowThreadProcessId(front);
            var selfThread = ops.GetCurrentThreadId();
            var attached = frontThread != 0 && frontThread != selfThread && ops.AttachThreadInput(selfThread, frontThread, true);
            try
            {
                ops.SetForegroundWindow(hwnd);
                ops.BringWindowToTop(hwnd);
                ops.SetActiveWindow(hwnd);
            }
            finally
            {
                if (attached) ops.AttachThreadInput(selfThread, frontThread, false);
            }
        }

        if (ops.GetForegroundWindow() == hwnd)
        {
            ops.ActivateManaged();
            return true;
        }

        // Tap unassigned VK 0xE8 (no extended flag) so Windows treats us as the last-input process for SetForegroundWindow.
        if (ops.SendUnassignedKeyTap())
        {
            ops.SetForegroundWindow(hwnd);
            ops.BringWindowToTop(hwnd);
            ops.SetActiveWindow(hwnd);
        }

        ops.ActivateManaged();
        return ops.GetForegroundWindow() == hwnd;
    }

    public static Task<bool> PasteAsync(nint window, CancellationToken token) =>
        PasteAsync(window, token, DefaultPasteOperations);

    internal static async Task<bool> PasteAsync(nint window, CancellationToken token, PasteOperations ops)
    {
        if (window == 0 || !ops.IsWindow(window)) return false;

        var deadline = ops.GetTickCount64() + 1000;
        while (ops.IsAnyModifierDown())
        {
            if (ops.GetTickCount64() >= deadline) return false;
            await ops.Delay(15, token);
        }
        token.ThrowIfCancellationRequested();

        if (!ops.IsWindow(window) || !ops.SetForegroundWindow(window))
            return false;

        // Yield briefly so the target window completes activation before receiving Ctrl+V.
        await ops.Delay(25, token);
        token.ThrowIfCancellationRequested();
        if (!ops.IsWindow(window) || ops.GetForegroundWindow() != window || ops.IsAnyModifierDown())
            return false;

        return ops.SendCtrlV();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int x;
        public int y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct GUITHREADINFO
    {
        public uint cbSize;
        public uint flags;
        public nint hwndActive;
        public nint hwndFocus;
        public nint hwndCapture;
        public nint hwndMenuOwner;
        public nint hwndMoveSize;
        public nint hwndCaret;
        public RECT rcCaret;
    }

    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(nint hWnd, out uint processId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO lpgui);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ClientToScreen(nint hWnd, ref POINT lpPoint);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindow(nint hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BringWindowToTop(nint hWnd);

    [DllImport("user32.dll")]
    private static extern nint SetActiveWindow(nint hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsHungAppWindow(nint hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, [MarshalAs(UnmanagedType.Bool)] bool attach);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();
}

/// <summary>Tracks the most recent foreground window outside this process while the history window is open.</summary>
internal sealed class PasteTargetTracker(Func<nint, bool> isWindow, Func<nint, bool> isOwnWindow)
{
    private nint target;

    public PasteTargetTracker()
        : this(ForegroundContext.IsWindowHandle, ForegroundContext.IsOwnProcessWindow)
    {
    }

    public nint CurrentTarget => IsValidTarget(target) ? target : 0;

    public void Reset(nint initialWindow = 0)
    {
        target = IsValidTarget(initialWindow) ? initialWindow : 0;
    }

    public bool RecordForeground(nint hwnd)
    {
        if (!IsValidTarget(hwnd)) return false;
        target = hwnd;
        return true;
    }

    private bool IsValidTarget(nint hwnd) =>
        hwnd != 0 && isWindow(hwnd) && !isOwnWindow(hwnd);
}

internal static class NativeInput
{
    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;
    private const ushort VkControl = 0x11;
    private const ushort VkV = 0x56;
    internal const ushort VkMenuMask = 0xE8;

    private static readonly int[] ModifierVirtualKeys =
    [
        0x10, 0x11, 0x12,
        0x5B, 0x5C,
        0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5,
    ];

    public static readonly nuint SelfExtraInfo = 0x43504B01u;

    public static bool IsKeyDown(int virtualKey) => (GetAsyncKeyState(virtualKey) & 0x8000) != 0;

    public static bool IsAnyModifierDown()
    {
        foreach (var vk in ModifierVirtualKeys)
        {
            if (IsKeyDown(vk)) return true;
        }
        return false;
    }

    internal static INPUT[] CreateMenuMaskInputs() =>
    [
        KeyboardInput(VkMenuMask, 0, keyUp: false),
        KeyboardInput(VkMenuMask, 0, keyUp: true),
    ];

    public static bool SendMenuMask()
    {
        var inputs = CreateMenuMaskInputs();
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>()) == inputs.Length;
    }

    public static bool SendCtrlV()
    {
        var ctrlScan = (ushort)MapVirtualKey(VkControl, 0);
        var vScan = (ushort)MapVirtualKey(VkV, 0);
        INPUT[] inputs =
        [
            KeyboardInput(VkControl, ctrlScan, keyUp: false),
            KeyboardInput(VkV, vScan, keyUp: false),
            KeyboardInput(VkV, vScan, keyUp: true),
            KeyboardInput(VkControl, ctrlScan, keyUp: true),
        ];
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>()) == inputs.Length;
    }

    private static INPUT KeyboardInput(ushort vk, ushort scan, bool keyUp) => new()
    {
        type = InputKeyboard,
        U = new InputUnion
        {
            ki = new KEYBDINPUT
            {
                wVk = vk,
                wScan = scan,
                dwFlags = keyUp ? KeyEventKeyUp : 0,
                dwExtraInfo = SelfExtraInfo,
            },
        },
    };

    [StructLayout(LayoutKind.Sequential)]
    internal struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    internal struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public nuint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public nuint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, [MarshalAs(UnmanagedType.LPArray), In] INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    private static extern uint MapVirtualKey(uint uCode, uint uMapType);
}
