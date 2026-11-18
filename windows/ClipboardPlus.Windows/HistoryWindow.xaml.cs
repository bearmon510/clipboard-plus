using System.Collections.ObjectModel;
using System.ComponentModel;
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
            // The stream is closed here, and shared for deletion, so cleaning up bodies never waits on it.
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.CreateOptions = BitmapCreateOptions.IgnoreImageCache;
            bitmap.DecodePixelHeight = 84; // Twice the 42-pixel slot, so a full-size image is never decoded.
            bitmap.StreamSource = stream;
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
    private const double CaretLineHeight = 32; // Room left for the caret's own line when opening upward.
    private readonly Action<string> log;
    private readonly Func<bool> pasteOnSelect;
    private readonly Func<nint, CancellationToken, Task<bool>> paste;
    private readonly Action openSettings;
    private readonly ObservableCollection<HistoryRow> rows = [];
    private SyncCoordinator? coordinator;
    private HistoryInvocation? invocation;
    private CancellationTokenSource? pasteCancel;
    private int reloadVersion;
    private int? preferredIndex;
    private bool choosing;
    private bool deleting;

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
        // Hidden rows keep decoded thumbnails alive, so they go with the window.
        IsVisibleChanged += (_, _) => { if (!IsVisible) rows.Clear(); };
    }

    /// <summary>Set when the app exits. Until then, closing (Alt+F4) only hides the reused window.</summary>
    public bool AllowClose { get; set; }

    /// <summary>Follows the coordinator, which re-pairing replaces. Null while there is none.</summary>
    public void Attach(SyncCoordinator? next)
    {
        if (coordinator is not null) coordinator.HistoryChanged -= OnHistoryChanged;
        coordinator = next;
        if (coordinator is not null) coordinator.HistoryChanged += OnHistoryChanged;
        if (IsVisible) _ = ReloadAsync();
    }

    public void Present(HistoryInvocation value)
    {
        // A paste still waiting for keys to be released belongs to the previous opening.
        pasteCancel?.Cancel();
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
        // Keep the selected item; if it is gone (deleted), stay at the same place in the list.
        var index = selected is Guid id ? IndexOf(id) : -1;
        if (index < 0 && preferredIndex is int place) index = Math.Min(place, rows.Count - 1);
        preferredIndex = null;
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
        nint target;
        try
        {
            await current.CopyHistoryAsync(row.Item.Id);
            target = invocation?.PreviousWindow ?? 0;
            // Opened from clipboard+'s own window or tray, there is nothing to paste into.
            pasteAfter = pasteAfter && target != 0 && IsWindow(target) && !IsOwnWindow(target);
            // While this window still holds the foreground, hand it back; once hidden, Windows may refuse.
            if (pasteAfter) SetForegroundWindow(target);
            Hide();
        }
        catch (Exception ex)
        {
            // An item deleted meanwhile, or an image the clipboard refuses.
            log($"history choose error={ex.GetType().Name}");
            return;
        }
        finally { choosing = false; }

        if (!pasteAfter) return;
        pasteCancel?.Cancel();
        var cancel = pasteCancel = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try
        {
            if (!await paste(target, cancel.Token)) log("history paste not delivered");
        }
        catch (OperationCanceledException) { log("history paste cancelled"); }
        catch (Exception ex) { log($"history paste error={ex.GetType().Name}"); }
        finally
        {
            if (pasteCancel == cancel) pasteCancel = null;
            cancel.Dispose();
        }
    }

    private static bool IsOwnWindow(nint window)
    {
        GetWindowThreadProcessId(window, out var processId);
        return processId == (uint)Environment.ProcessId;
    }

    private async Task DeleteAsync(HistoryRow? row)
    {
        var current = coordinator;
        if (row is null || current is null || deleting) return;
        deleting = true;
        // HistoryChanged reloads the list; this keeps the selection at the same place.
        preferredIndex = HistoryList.SelectedIndex;
        try { await current.DeleteHistoryAsync(row.Item.Id); }
        catch (Exception ex) { log($"history delete error={ex.GetType().Name}"); preferredIndex = null; }
        finally { deleting = false; }
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        // AttachThreadInput can reset this thread's key state, so Ctrl is also asked of Windows.
        var ctrl = (Keyboard.Modifiers & ModifierKeys.Control) != 0 || (GetAsyncKeyState(VirtualKeyControl) & 0x8000) != 0;
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

    /// <summary>The menu acts on the row under the pointer, so it does not open over empty space.</summary>
    private void OnContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        if (RowAt(e.OriginalSource) is null) e.Handled = true;
    }

    private void OnContextMenuClosed(object sender, RoutedEventArgs e)
    {
        // Closing the menu by clicking another app leaves this window inactive without a new Deactivated.
        if (IsVisible && !IsActive && !choosing) Hide();
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

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (AllowClose) return;
        e.Cancel = true; // Alt+F4 would destroy the window that the hotkey reuses.
        Hide();
    }

    /// <summary>Below the caret if known, else by the pointer, kept inside the work area of that screen.</summary>
    private void PlaceNear(HistoryInvocation value)
    {
        var source = PresentationSource.FromVisual(this) ?? HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
        var fromDevice = source?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var anchorX = value.CaretX ?? value.CursorX;
        var anchorY = value.CaretY ?? value.CursorY;
        // Screen gives the work area in the same device units as the caret and pointer positions.
        var work = System.Windows.Forms.Screen.FromPoint(new System.Drawing.Point(anchorX, anchorY)).WorkingArea;
        var topLeft = fromDevice.Transform(new Point(work.Left, work.Top));
        var bottomRight = fromDevice.Transform(new Point(work.Right, work.Bottom));
        var anchor = fromDevice.Transform(new Point(anchorX, anchorY));
        var caretKnown = value.CaretY is not null;
        // CaretY is the bottom of the caret: open just below it, or above its line if there is no room.
        var y = anchor.Y + (caretKnown ? 6 : 8);
        if (y + Height > bottomRight.Y) y = anchor.Y - Height - (caretKnown ? CaretLineHeight : 8);
        Left = Math.Clamp(anchor.X, topLeft.X, Math.Max(topLeft.X, bottomRight.X - Width));
        Top = Math.Clamp(y, topLeft.Y, Math.Max(topLeft.Y, bottomRight.Y - Height));
    }

    /// <summary>
    /// The hotkey arrives while another app is in front, and Windows may refuse to hand the
    /// foreground to us. Joining the front window's input queue for the call is the usual way in,
    /// but not with a window that has stopped responding, which would stall this thread too.
    /// </summary>
    private void BringToFront(nint hwnd)
    {
        var front = GetForegroundWindow();
        if (front == hwnd || SetForegroundWindow(hwnd)) { Activate(); return; }
        if (front != 0 && !IsHungAppWindow(front))
        {
            var frontThread = GetWindowThreadProcessId(front, out _);
            var selfThread = GetCurrentThreadId();
            var attached = frontThread != 0 && frontThread != selfThread && AttachThreadInput(selfThread, frontThread, true);
            try { SetForegroundWindow(hwnd); }
            finally { if (attached) AttachThreadInput(selfThread, frontThread, false); }
        }
        Activate();
        if (GetForegroundWindow() != hwnd) log("history window could not take the foreground");
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

    private const int VirtualKeyControl = 0x11;
    private const int DwmWindowCornerPreference = 33;
    private const int DwmRound = 2;

    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindow(nint hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsHungAppWindow(nint hwnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint hwnd, out uint processId);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, [MarshalAs(UnmanagedType.Bool)] bool attach);
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);
}
