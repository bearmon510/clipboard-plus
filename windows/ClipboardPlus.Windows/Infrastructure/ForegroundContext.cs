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

    public static async Task<bool> PasteAsync(nint window, CancellationToken token)
    {
        if (window == 0 || !IsWindow(window)) return false;

        var deadline = Environment.TickCount64 + 1000;
        while (NativeInput.IsAnyModifierDown())
        {
            if (Environment.TickCount64 >= deadline) break;
            await Task.Delay(15, token);
        }
        token.ThrowIfCancellationRequested();

        if (!IsWindow(window) || !SetForegroundWindow(window))
            return false;

        // Yield briefly so the target window completes activation before receiving Ctrl+V.
        await Task.Delay(25, token);
        if (!IsWindow(window)) return false;

        return NativeInput.SendCtrlV();
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
}

internal static class NativeInput
{
    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;
    private const ushort VkControl = 0x11;
    private const ushort VkV = 0x56;
    private const ushort VkMenuMask = 0xE8;

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

    public static void SendMenuMask()
    {
        INPUT[] inputs =
        [
            KeyboardInput(VkMenuMask, 0, keyUp: false),
            KeyboardInput(VkMenuMask, 0, keyUp: true),
        ];
        _ = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
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
