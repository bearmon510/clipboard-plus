using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Threading;
using ClipboardPlus.Windows.Core;

namespace ClipboardPlus.Windows.Infrastructure;

internal sealed class ClipboardMonitor : IClipboardAccess, IDisposable
{
    private readonly Dispatcher dispatcher;
    private readonly HwndSource source;
    private readonly Action<string> log;
    private bool disposed;
    private readonly uint exclude = RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
    private readonly uint history = RegisterClipboardFormat("CanIncludeInClipboardHistory");
    private readonly uint cloud = RegisterClipboardFormat("CanUploadToCloudClipboard");
    public event Action<ClipboardSnapshot>? Changed;

    public ClipboardMonitor(Dispatcher dispatcher, Action<string> log)
    {
        this.dispatcher = dispatcher; this.log = log;
        source = new HwndSource(new HwndSourceParameters("clipboard+ listener") { ParentWindow = new IntPtr(-3) });
        source.AddHook(Hook);
        if (!AddClipboardFormatListener(source.Handle)) throw new System.ComponentModel.Win32Exception();
    }

    private IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == 0x031D && !disposed) _ = ReadChangeAsync();
        return IntPtr.Zero;
    }

    private async Task ReadChangeAsync()
    {
        // Capture text and exclusion formats while holding the same clipboard lock.
        for (var attempt = 0; attempt < 5 && !disposed; attempt++)
        {
            if (OpenClipboard(source.Handle))
            {
                ClipboardSnapshot snapshot;
                try
                {
                    var sequence = GetClipboardSequenceNumber();
                    var blocked = IsClipboardFormatAvailable(exclude) || IsZero(history) || IsZero(cloud);
                    string? text = null;
                    if (!blocked && IsClipboardFormatAvailable(13))
                    {
                        var handle = GetClipboardData(13);
                        var ptr = GlobalLock(handle);
                        if (ptr != IntPtr.Zero)
                        {
                            try
                            {
                                // Bound the native scan before allocating an unbounded string.
                                var chars = (int)Math.Min((ulong)GlobalSize(handle) / 2, (ulong)ClipboardPlus.Sync.SyncProtocol.MaxPlaintextBytes + 1);
                                var length = 0;
                                while (length < chars && Marshal.ReadInt16(ptr, length * 2) != 0) length++;
                                if (length < chars) text = Marshal.PtrToStringUni(ptr, length);
                                else log("clipboard skipped oversized or unterminated");
                            }
                            finally { GlobalUnlock(handle); }
                        }
                    }
                    snapshot = new(sequence, text, blocked);
                }
                finally { CloseClipboard(); }
                Changed?.Invoke(snapshot);
                return;
            }
            await Task.Delay(40 * (attempt + 1));
        }
        if (!disposed) log("clipboard read busy retries=5");
    }

    private static bool IsZero(uint format)
    {
        if (!IsClipboardFormatAvailable(format)) return false;
        var handle = GetClipboardData(format);
        // If a privacy marker is present but unreadable, err on the side of skipping.
        if ((ulong)GlobalSize(handle) < 4) return true;
        var ptr = GlobalLock(handle);
        if (ptr == IntPtr.Zero) return true;
        try { return Marshal.ReadInt32(ptr) == 0; }
        finally { GlobalUnlock(handle); }
    }

    public Task<uint> WriteTextAsync(string text) => dispatcher.InvokeAsync(async () =>
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                System.Windows.Clipboard.SetText(text);
                return GetClipboardSequenceNumber();
            }
            catch (ExternalException) when (attempt < 4) { await Task.Delay(40 * (attempt + 1)); }
        }
        throw new InvalidOperationException("Clipboard unavailable");
    }).Task.Unwrap();

    public void Dispose()
    {
        disposed = true;
        RemoveClipboardFormatListener(source.Handle);
        source.RemoveHook(Hook); source.Dispose();
    }

    [DllImport("user32.dll", SetLastError = true)] private static extern bool AddClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool OpenClipboard(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool CloseClipboard();
    [DllImport("user32.dll")] private static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll")] private static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterClipboardFormat(string format);
    [DllImport("kernel32.dll")] private static extern IntPtr GlobalLock(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern UIntPtr GlobalSize(IntPtr handle);
}
