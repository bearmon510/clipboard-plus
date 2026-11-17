using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Threading;
using System.Windows.Media.Imaging;
using System.Text;
using ClipboardPlus.Sync;
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
    private readonly uint png = RegisterClipboardFormat("PNG");
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
                    IReadOnlyList<ClipboardContent>? contents = null;
                    if (!blocked && IsClipboardFormatAvailable(15)) contents = ReadFiles();
                    else if (!blocked && (IsClipboardFormatAvailable(png) || IsClipboardFormatAvailable(8)))
                    {
                        try { contents = [new("image", Data: ReadPng(), Type: "public.png")]; }
                        catch (Exception e) when (e is not OutOfMemoryException) { log("clipboard skipped items=1 reason=image-size-or-format"); contents = []; }
                    }
                    else if (!blocked && IsClipboardFormatAvailable(13))
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
                    snapshot = new(sequence, text, blocked, contents);
                }
                finally { CloseClipboard(); }
                Changed?.Invoke(snapshot);
                return;
            }
            await Task.Delay(40 * (attempt + 1));
        }
        if (!disposed) log("clipboard read busy retries=5");
    }

    private byte[] NativeBytes(uint format, long limit = SyncProtocol.MaxItemBytes)
    {
        var handle = GetClipboardData(format); var length = (ulong)GlobalSize(handle);
        if (length > (ulong)limit || length == 0) throw new IOException("Native size");
        var ptr = GlobalLock(handle); if (ptr == IntPtr.Zero) throw new IOException("Native lock");
        try { var data = new byte[(int)length]; Marshal.Copy(ptr, data, 0, data.Length); return data; }
        finally { GlobalUnlock(handle); }
    }
    private byte[] ReadPng()
    {
        byte[] input;
        if (IsClipboardFormatAvailable(png)) input = NativeBytes(png);
        else
        {
            var dib = NativeBytes(8, SyncProtocol.MaxImagePixels * 4 + 4096);
            if (dib.Length < 40) throw new IOException("DIB header");
            var header = BitConverter.ToInt32(dib, 0);
            if (header < 40 || header > dib.Length) throw new IOException("DIB header");
            var bits = BitConverter.ToUInt16(dib, 14); var compression = BitConverter.ToInt32(dib, 16);
            var colors = BitConverter.ToUInt32(dib, 32);
            if (colors == 0 && bits <= 8) colors = 1u << bits;
            var offset = checked(14 + header + (int)colors * 4 + (header == 40 && compression == 3 ? 12 : 0));
            input = new byte[14 + dib.Length]; input[0] = (byte)'B'; input[1] = (byte)'M';
            BitConverter.GetBytes(input.Length).CopyTo(input, 2); BitConverter.GetBytes(offset).CopyTo(input, 10); dib.CopyTo(input, 14);
        }
        using var stream = new MemoryStream(input);
        var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnDemand);
        var frame = decoder.Frames[0];
        if ((long)frame.PixelWidth * frame.PixelHeight > SyncProtocol.MaxImagePixels) throw new IOException("Image dimensions");
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(frame));
        using var result = new MemoryStream(); encoder.Save(result);
        if (result.Length > SyncProtocol.MaxItemBytes) throw new IOException("Image size");
        return result.ToArray();
    }
    private IReadOnlyList<ClipboardContent> ReadFiles()
    {
        var drop = GetClipboardData(15); var count = DragQueryFile(drop, uint.MaxValue, null, 0);
        var contents = new List<ClipboardContent>(); var skipped = 0;
        for (uint i = 0; i < count; i++)
        {
            if (contents.Count == SyncProtocol.MaxFilesPerCopy) { skipped += checked((int)(count - i)); break; }
            var length = DragQueryFile(drop, i, null, 0);
            if (length > 32767) { skipped++; continue; }
            var name = new StringBuilder((int)length + 1); DragQueryFile(drop, i, name, (uint)name.Capacity);
            try
            {
                var file = new FileInfo(name.ToString());
                if ((file.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 || file.Length > SyncProtocol.MaxItemBytes) { skipped++; continue; }
                using var input = new FileStream(file.FullName, FileMode.Open, FileAccess.Read, FileShare.Read);
                if (input.Length > SyncProtocol.MaxItemBytes) { skipped++; continue; }
                var data = new byte[(int)input.Length]; input.ReadExactly(data);
                contents.Add(new("file", Filename: file.Name, Data: data));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { skipped++; }
        }
        if (skipped > 0) log($"clipboard skipped items={skipped} reason=file-limit-or-unavailable");
        return contents;
    }

    public Task<uint> WriteItemAsync(HistoryItem item)
    {
        if (item.Kind == "text") return WriteTextAsync(item.Text!);
        return dispatcher.InvokeAsync(async () =>
        {
            var data = new System.Windows.DataObject();
            if (item.Kind == "image")
            {
                using var stream = File.OpenRead(item.Path!);
                try
                {
                    // Probe dimensions before OnLoad so oversized images fail without allocating pixel buffers.
                    var probe = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnDemand);
                    if ((item.Type == "public.png" && probe is not PngBitmapDecoder) ||
                        (item.Type == "public.jpeg" && probe is not JpegBitmapDecoder) ||
                        item.Type is not ("public.png" or "public.jpeg"))
                        throw new ClipboardContentRejectedException(ClipboardRejectReason.ImageFormat);
                    if (probe.Frames.Count == 0)
                        throw new ClipboardContentRejectedException(ClipboardRejectReason.ImageCorrupt);
                    var probeFrame = probe.Frames[0];
                    if ((long)probeFrame.PixelWidth * probeFrame.PixelHeight > SyncProtocol.MaxImagePixels)
                        throw new ClipboardContentRejectedException(ClipboardRejectReason.ImageDimensions);

                    stream.Position = 0;
                    var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                    if (decoder.Frames.Count == 0)
                        throw new ClipboardContentRejectedException(ClipboardRejectReason.ImageCorrupt);
                    var bitmap = decoder.Frames[0];
                    if ((long)bitmap.PixelWidth * bitmap.PixelHeight > SyncProtocol.MaxImagePixels)
                        throw new ClipboardContentRejectedException(ClipboardRejectReason.ImageDimensions);
                    bitmap.Freeze(); data.SetData(System.Windows.DataFormats.Bitmap, bitmap);
                    var encoder = new PngBitmapEncoder(); encoder.Frames.Add(bitmap);
                    var encoded = new MemoryStream(); encoder.Save(encoded); encoded.Position = 0;
                    data.SetData("PNG", encoded);
                }
                catch (Exception ex) when (ex is FileFormatException or NotSupportedException or InvalidDataException or OverflowException or ArgumentException or COMException)
                {
                    throw new ClipboardContentRejectedException(ClipboardRejectReason.ImageCorrupt);
                }
            }
            else
            {
                var folder = Path.Combine(LocalStore.Root, "received"); Directory.CreateDirectory(folder);
                var safe = SafeFilename(item.Filename ?? "file");
                var target = Path.Combine(folder, Guid.NewGuid().ToString("N") + "-" + safe);
                File.Copy(item.Path!, target, false);
                data.SetFileDropList(new System.Collections.Specialized.StringCollection { target });
            }
            for (var attempt = 0; ; attempt++)
            {
                try { System.Windows.Clipboard.SetDataObject(data, true); return GetClipboardSequenceNumber(); }
                catch (ExternalException) when (attempt < 4) { await Task.Delay(40 * (attempt + 1)); }
            }
        }).Task.Unwrap();
    }
    internal static string SafeFilename(string name) => SyncRepository.SafeFilename(name);

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
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern uint DragQueryFile(IntPtr drop, uint index, StringBuilder? filename, uint length);
}
