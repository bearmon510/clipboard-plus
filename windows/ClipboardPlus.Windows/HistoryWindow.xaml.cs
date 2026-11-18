using System.Collections.ObjectModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ClipboardPlus.Windows.Core;
using ClipboardPlus.Windows.Infrastructure;
using Microsoft.Win32;
// The project also uses Windows Forms, whose implicit usings bring same-named types.
using Color = System.Windows.Media.Color;
using ColorConverter = System.Windows.Media.ColorConverter;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;
using Point = System.Windows.Point;

namespace ClipboardPlus.Windows;

/// <summary>One history item as the window shows it. The thumbnail loads only when a row is drawn.</summary>
public sealed class HistoryRow
{
    private readonly Lazy<ImageSource?> thumbnail;

    public HistoryRow(HistoryItem item, DateTimeOffset now)
    {
        Item = item;
        Title = HistoryText.Title(item);
        Meta = HistoryText.Meta(item, now);
        thumbnail = new(() => item.Kind == "image" ? LoadThumbnail(item.Path) : null);
    }

    public HistoryItem Item { get; }
    public string Title { get; }
    public string Meta { get; }
    public ImageSource? Thumbnail => thumbnail.Value;
    public Visibility ThumbnailVisibility => Item.Kind == "image" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility FileIconVisibility => Item.Kind == "file" ? Visibility.Visible : Visibility.Collapsed;

    private static ImageSource? LoadThumbnail(string? path)
    {
        if (string.IsNullOrEmpty(path)) return null;
        try
        {
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.CreateOptions = BitmapCreateOptions.IgnoreImageCache;
            bitmap.DecodePixelWidth = 112; // Twice the 56-pixel slot, so a full-size image is never decoded.
            bitmap.UriSource = new Uri(path);
            bitmap.EndInit();
            bitmap.Freeze();
            return bitmap;
        }
        catch (Exception) { return null; }
    }
}

/// <summary>
/// The history window opened by the hotkey: search, pick, and paste into the window that was in front.
/// It is created once and hidden between uses.
/// </summary>
public partial class HistoryWindow : Window, IHistoryPresenter
{
    private readonly Action<string> log;
    private readonly Func<bool> pasteOnSelect;
    private readonly Func<nint, CancellationToken, Task<bool>> paste;
    private readonly Action openSettings;
    private readonly ObservableCollection<HistoryRow> rows = [];
    private SyncCoordinator? coordinator;
    private HistoryInvocation? invocation;
    private int reloadVersion;
    private bool choosing;

    public HistoryWindow(Action<string> log, Func<bool> pasteOnSelect,
        Func<nint, CancellationToken, Task<bool>> paste, Action openSettings)
    {
        this.log = log;
        this.pasteOnSelect = pasteOnSelect;
        this.paste = paste;
        this.openSettings = openSettings;
        InitializeComponent();
        HistoryList.ItemsSource = rows;
        ApplyTheme();
        SourceInitialized += (_, _) => RoundCorners();
    }

    /// <summary>Follows the coordinator, which re-pairing replaces.</summary>
    public void Attach(SyncCoordinator? next)
    {
        if (coordinator is not null) coordinator.HistoryChanged -= OnHistoryChanged;
        coordinator = next;
        if (coordinator is not null) coordinator.HistoryChanged += OnHistoryChanged;
        if (IsVisible) _ = ReloadAsync();
    }

    public void Present(HistoryInvocation value)
    {
        // The hotkey a second time closes the window, as Win+V does.
        if (IsVisible) { Hide(); return; }
        invocation = value;
        ApplyTheme();
        SearchBox.Text = "";
        var hwnd = new WindowInteropHelper(this).EnsureHandle();
        PlaceNear(value);
        Show();
        BringToFront(hwnd);
        SearchBox.Focus();
        _ = ReloadAsync();
    }

    // HistoryChanged fires while the coordinator holds its lock, so the reload is posted.
    private void OnHistoryChanged() => Dispatcher.BeginInvoke(() => { if (IsVisible) _ = ReloadAsync(); });

    private async Task ReloadAsync()
    {
        var version = ++reloadVersion;
        var current = coordinator;
        var search = SearchBox.Text.Trim();
        IReadOnlyList<HistoryItem> items = [];
        if (current is not null)
        {
            try { items = await current.GetHistoryAsync(search.Length == 0 ? null : search); }
            catch (Exception ex) { log($"history load error={ex.GetType().Name}"); return; }
        }
        if (version != reloadVersion) return; // A newer search or change already reloaded.
        var selected = Selected?.Item.Id;
        var now = DateTimeOffset.Now;
        rows.Clear();
        foreach (var item in items) rows.Add(new HistoryRow(item, now));
        EmptyText.Text = HistoryText.Empty(search);
        EmptyText.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        var index = selected is Guid id ? IndexOf(id) : -1;
        HistoryList.SelectedIndex = index >= 0 ? index : (rows.Count > 0 ? 0 : -1);
        if (HistoryList.SelectedItem is not null) HistoryList.ScrollIntoView(HistoryList.SelectedItem);
    }

    private HistoryRow? Selected => HistoryList.SelectedItem as HistoryRow;

    private int IndexOf(Guid id)
    {
        for (var i = 0; i < rows.Count; i++) if (rows[i].Item.Id == id) return i;
        return -1;
    }

    private void Move(int step)
    {
        if (rows.Count == 0) return;
        var index = Math.Clamp(HistoryList.SelectedIndex + step, 0, rows.Count - 1);
        HistoryList.SelectedIndex = index;
        HistoryList.ScrollIntoView(rows[index]);
    }

    private async Task ChooseAsync(HistoryRow? row, bool pasteAfter)
    {
        var current = coordinator;
        if (row is null || current is null || choosing) return;
        choosing = true;
        try
        {
            await current.CopyHistoryAsync(row.Item.Id);
            var target = invocation?.PreviousWindow ?? 0;
            Hide();
            // Opened from clipboard+'s own window or tray, there is nothing to paste into.
            if (pasteAfter && target != 0 && !IsOwnWindow(target))
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
                if (!await paste(target, timeout.Token)) log("history paste not delivered");
            }
        }
        catch (Exception ex)
        {
            // An item deleted meanwhile, or an image the clipboard refuses.
            log($"history choose error={ex.GetType().Name}");
        }
        finally { choosing = false; }
    }

    private static bool IsOwnWindow(nint window)
    {
        GetWindowThreadProcessId(window, out var processId);
        return processId == (uint)Environment.ProcessId;
    }

    private async Task DeleteAsync(HistoryRow? row)
    {
        var current = coordinator;
        if (row is null || current is null) return;
        var index = HistoryList.SelectedIndex;
        try { await current.DeleteHistoryAsync(row.Item.Id); }
        catch (Exception ex) { log($"history delete error={ex.GetType().Name}"); return; }
        await ReloadAsync();
        if (rows.Count > 0) HistoryList.SelectedIndex = Math.Clamp(index, 0, rows.Count - 1);
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        var ctrl = (Keyboard.Modifiers & ModifierKeys.Control) != 0;
        switch (e.Key)
        {
            case Key.Escape: Hide(); break;
            case Key.Down: Move(1); break;
            case Key.Up: Move(-1); break;
            case Key.PageDown: Move(5); break;
            case Key.PageUp: Move(-5); break;
            case Key.Enter: _ = ChooseAsync(Selected, pasteAfter: !ctrl && pasteOnSelect()); break;
            // While a search is typed, Delete edits the search; with an empty box it removes the item.
            case Key.Delete when SearchBox.Text.Length == 0: _ = DeleteAsync(Selected); break;
            default: return;
        }
        e.Handled = true;
    }

    private void OnSearchChanged(object sender, TextChangedEventArgs e)
    {
        SearchHint.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (IsVisible) _ = ReloadAsync();
    }

    private void OnListClick(object sender, MouseButtonEventArgs e)
    {
        if (RowAt(e.OriginalSource) is { } row) _ = ChooseAsync(row, pasteAfter: pasteOnSelect());
    }

    private void OnListRightDown(object sender, MouseButtonEventArgs e)
    {
        if (RowAt(e.OriginalSource) is { } row) HistoryList.SelectedItem = row;
    }

    private HistoryRow? RowAt(object source) =>
        source is DependencyObject element && ItemsControl.ContainerFromElement(HistoryList, element) is ListBoxItem item
            ? item.DataContext as HistoryRow
            : null;

    private void OnMenuPaste(object sender, RoutedEventArgs e) => _ = ChooseAsync(Selected, pasteAfter: true);
    private void OnMenuCopy(object sender, RoutedEventArgs e) => _ = ChooseAsync(Selected, pasteAfter: false);
    private void OnMenuDelete(object sender, RoutedEventArgs e) => _ = DeleteAsync(Selected);

    private void OnSettings(object sender, RoutedEventArgs e)
    {
        Hide();
        openSettings();
    }

    private void OnDeactivated(object? sender, EventArgs e)
    {
        // The context menu is a separate popup; opening it must not close the window.
        if (HistoryList.ContextMenu?.IsOpen == true || choosing) return;
        Hide();
    }

    /// <summary>Below the caret if known, else by the pointer, kept inside the work area of that screen.</summary>
    private void PlaceNear(HistoryInvocation value)
    {
        var source = PresentationSource.FromVisual(this) ?? HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
        var fromDevice = source?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var anchorX = value.CaretX ?? value.CursorX;
        var anchorY = value.CaretY ?? value.CursorY;
        var work = WorkArea(anchorX, anchorY);
        var topLeft = fromDevice.Transform(new Point(work.Left, work.Top));
        var bottomRight = fromDevice.Transform(new Point(work.Right, work.Bottom));
        var anchor = fromDevice.Transform(new Point(anchorX, anchorY));
        var gap = value.CaretY is null ? 8.0 : 24.0; // Below the caret's line, or just off the pointer.
        var x = anchor.X;
        var y = anchor.Y + gap;
        if (y + Height > bottomRight.Y) y = anchor.Y - Height - 8; // No room below: open upward.
        Left = Math.Clamp(x, topLeft.X, Math.Max(topLeft.X, bottomRight.X - Width));
        Top = Math.Clamp(y, topLeft.Y, Math.Max(topLeft.Y, bottomRight.Y - Height));
    }

    private static Rect WorkArea(int x, int y)
    {
        var monitor = MonitorFromPoint(new NativePoint { X = x, Y = y }, MonitorDefaultToNearest);
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (monitor != 0 && GetMonitorInfo(monitor, ref info))
            return new Rect(info.Work.Left, info.Work.Top, info.Work.Right - info.Work.Left, info.Work.Bottom - info.Work.Top);
        return SystemParameters.WorkArea;
    }

    /// <summary>
    /// The hotkey arrives while another app is in front, and Windows may refuse to hand the
    /// foreground to us. Joining the front window's input queue for the call is the usual way in.
    /// </summary>
    private void BringToFront(nint hwnd)
    {
        var front = GetForegroundWindow();
        if (front == hwnd) { Activate(); return; }
        var frontThread = GetWindowThreadProcessId(front, out _);
        var selfThread = GetCurrentThreadId();
        var attached = frontThread != 0 && frontThread != selfThread && AttachThreadInput(selfThread, frontThread, true);
        try
        {
            SetForegroundWindow(hwnd);
            Activate();
        }
        finally
        {
            if (attached) AttachThreadInput(selfThread, frontThread, false);
        }
    }

    private void ApplyTheme()
    {
        var dark = false;
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            dark = key?.GetValue("AppsUseLightTheme") is int light && light == 0;
        }
        catch (Exception) { }
        void Set(string name, string light, string darkColor) =>
            Resources[name] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(dark ? darkColor : light));
        Set("Bg", "#F3F5F8", "#202124");
        Set("Card", "#FFFFFF", "#2B2D31");
        Set("Hover", "#EEF2F7", "#34373C");
        Set("Selected", "#DCE7FB", "#2E4A7A");
        Set("Line", "#E2E8F0", "#3A3D42");
        Set("Field", "#FFFFFF", "#2B2D31");
        Set("Fg", "#1F2937", "#F1F5F9");
        Set("Sub", "#64748B", "#9AA4B2");
        Set("Accent", "#2E6BF0", "#7EA6FF");
    }

    /// <summary>Rounded corners on Windows 11. Earlier versions ignore the attribute.</summary>
    private void RoundCorners()
    {
        var preference = DwmRound;
        _ = DwmSetWindowAttribute(new WindowInteropHelper(this).Handle, DwmWindowCornerPreference, ref preference, sizeof(int));
    }

    private const int MonitorDefaultToNearest = 2;
    private const int DwmWindowCornerPreference = 33;
    private const int DwmRound = 2;

    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo { public int Size; public NativeRect Monitor; public NativeRect Work; public uint Flags; }

    [DllImport("user32.dll")] private static extern nint MonitorFromPoint(NativePoint point, int flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint hwnd, out uint processId);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, [MarshalAs(UnmanagedType.Bool)] bool attach);
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);
}
