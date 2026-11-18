using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ClipboardPlus.Windows.Core;
using ClipboardPlus.Windows.Infrastructure;
using Microsoft.Win32;
// The project also uses Windows Forms, whose implicit usings bring same-named types.
using Brush = System.Windows.Media.Brush;
using Button = System.Windows.Controls.Button;
using ButtonBase = System.Windows.Controls.Primitives.ButtonBase;
using Color = System.Windows.Media.Color;
using ColorConverter = System.Windows.Media.ColorConverter;
using DataObject = System.Windows.DataObject;
using DragDrop = System.Windows.DragDrop;
using DragDropEffects = System.Windows.DragDropEffects;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;
using MouseEventArgs = System.Windows.Input.MouseEventArgs;
using Point = System.Windows.Point;

namespace ClipboardPlus.Windows;

/// <summary>One history item as the window shows it. The thumbnail loads only when a row is drawn.</summary>
public sealed class HistoryRow
{
    private readonly Lazy<ImageSource?> thumbnail;

    public HistoryRow(HistoryItem item, DateTimeOffset now)
    {
        Item = item;
        Flavor = HistoryText.DetectFlavor(item, out var link, out var color);
        Title = HistoryText.Title(item);
        LinkHost = link?.Host;
        LinkRemainder = link?.Remainder;
        Meta = HistoryText.Meta(item, now);
        KindGlyph = HistoryText.FlavorGlyph(Flavor);
        if (color is { } rgb)
        {
            var brush = new SolidColorBrush(Color.FromRgb(rgb.Red, rgb.Green, rgb.Blue));
            brush.Freeze();
            SwatchBrush = brush;
        }
        thumbnail = new(() => item.Kind == "image" ? LoadThumbnail(item.Path) : null);
    }

    public HistoryItem Item { get; }
    public HistoryDisplayFlavor Flavor { get; }
    public string Title { get; }
    public string? LinkHost { get; }
    public string? LinkRemainder { get; }
    public string Meta { get; }
    public string KindGlyph { get; }
    public Brush? SwatchBrush { get; }
    public ImageSource? Thumbnail => thumbnail.Value;

    public Visibility LinkVisibility => Flavor == HistoryDisplayFlavor.Link ? Visibility.Visible : Visibility.Collapsed;
    public Visibility LinkRemainderVisibility => !string.IsNullOrEmpty(LinkRemainder) ? Visibility.Visible : Visibility.Collapsed;
    public Visibility PlainTitleVisibility => Flavor != HistoryDisplayFlavor.Link ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ThumbnailVisibility => Flavor == HistoryDisplayFlavor.Image && Thumbnail is not null ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ImageFallbackVisibility => Flavor == HistoryDisplayFlavor.Image && Thumbnail is null ? Visibility.Visible : Visibility.Collapsed;
    public Visibility FileIconVisibility => Flavor == HistoryDisplayFlavor.File ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ColorSwatchVisibility => Flavor == HistoryDisplayFlavor.Color ? Visibility.Visible : Visibility.Collapsed;

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
            bitmap.DecodePixelHeight = 88; // Twice the 44-pixel slot, so a full-size image is never decoded.
            bitmap.StreamSource = stream;
            bitmap.EndInit();
            bitmap.Freeze();
            return bitmap;
        }
        catch (Exception) { return null; }
    }
}

/// <summary>
/// The history window opened by the hotkey: search, pick, drag out, and paste into the window that was in front.
/// It is created once and hidden between uses.
/// </summary>
public partial class HistoryWindow : Window, IHistoryPresenter
{
    private const double ResizeBorderDip = 5;
    private const int EscHotKeyId = 0x4350;
    private static readonly TimeSpan DragStagingRetention = TimeSpan.FromHours(1);

    private readonly Action<string> log;
    private readonly Func<bool> pasteOnSelect;
    private readonly Func<nint, CancellationToken, Task<bool>> paste;
    private readonly Action openSettings;
    private readonly Func<WindowPlacement?>? loadPlacement;
    private readonly Action<WindowPlacement>? savePlacement;
    private readonly ObservableCollection<HistoryRow> rows = [];

    private SyncCoordinator? coordinator;
    private HistoryInvocation? invocation;
    private CancellationTokenSource? pasteCancel;
    private HwndSource? hwndSource;
    private int reloadVersion;
    private int? preferredIndex;
    private bool choosing;
    private bool deleting;
    private bool dragging;
    private bool pendingReloadAfterDrag;
    private bool placedForDisplay;
    private bool escHotKeyRegistered;
    private Point? dragStartPoint;
    private HistoryRow? dragCandidate;
    private HistoryRow? pendingClickRow;

    public HistoryWindow(Action<string> log, Func<bool> pasteOnSelect,
        Func<nint, CancellationToken, Task<bool>> paste, Action openSettings)
        : this(log, pasteOnSelect, paste, openSettings, null, null)
    {
    }

    public HistoryWindow(Action<string> log, Func<bool> pasteOnSelect,
        Func<nint, CancellationToken, Task<bool>> paste, Action openSettings,
        Func<WindowPlacement?>? loadPlacement, Action<WindowPlacement>? savePlacement)
    {
        this.log = log;
        this.pasteOnSelect = pasteOnSelect;
        this.paste = paste;
        this.openSettings = openSettings;
        this.loadPlacement = loadPlacement;
        this.savePlacement = savePlacement;
        InitializeComponent();
        HistoryList.ItemsSource = rows;
        ApplyTheme();
        SourceInitialized += OnSourceInitialized;
        Closed += OnWindowClosed;
        IsVisibleChanged += OnWindowVisibleChanged;
    }

    /// <summary>Set when the app exits. Until then, closing (Alt+F4) only hides the reused window.</summary>
    public bool AllowClose { get; set; }

    private static string DragStagingRoot => Path.Combine(LocalStore.Root, "drag");

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
        CleanupOldDragStagingFiles(DragStagingRoot);

        var hwnd = new WindowInteropHelper(this).EnsureHandle();
        var target = ComputeTargetRect(hwnd, value);
        ApplyPixelBounds(hwnd, target);
        placedForDisplay = true;

        Show();
        ApplyPixelBounds(hwnd, target);
        SetWindowPos(hwnd, HwndTopMost, 0, 0, 0, 0, SwpNoMove | SwpNoSize | SwpNoActivate);

        var tookForeground = ForegroundContext.BringToFront(hwnd, () => _ = Activate());
        if (tookForeground)
        {
            UnregisterEscFallbackHotkey(hwnd);
        }
        else
        {
            log("history window could not take the foreground");
            RegisterEscFallbackHotkey(hwnd);
        }

        SearchBox.Focus();
        Keyboard.Focus(SearchBox);
        _ = ReloadAsync();
    }

    // HistoryChanged fires while the coordinator holds its lock, so the reload is posted.
    private void OnHistoryChanged() => Dispatcher.BeginInvoke(() =>
    {
        if (!IsVisible) return;
        if (dragging) { pendingReloadAfterDrag = true; return; }
        _ = ReloadAsync();
    });

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
        UpdateEmptyState(search);
        // Keep the selected item; if it is gone (deleted), stay at the same place in the list.
        var index = selected is Guid id ? IndexOf(id) : -1;
        if (index < 0 && preferredIndex is int place) index = Math.Min(place, rows.Count - 1);
        preferredIndex = null;
        HistoryList.SelectedIndex = index >= 0 ? index : (rows.Count > 0 ? 0 : -1);
        if (HistoryList.SelectedItem is not null) HistoryList.ScrollIntoView(HistoryList.SelectedItem);
    }

    private void UpdateEmptyState(string search)
    {
        if (rows.Count > 0)
        {
            EmptyPanel.Visibility = Visibility.Collapsed;
            return;
        }
        var searching = !string.IsNullOrWhiteSpace(search);
        EmptyIcon.Text = searching ? "\uE721" : "\uE77F";
        EmptyTitleText.Text = HistoryText.EmptyTitle(search);
        EmptyDetailText.Text = HistoryText.EmptyDetail(search);
        EmptyClearButton.Visibility = searching ? Visibility.Visible : Visibility.Collapsed;
        EmptyPanel.Visibility = Visibility.Visible;
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

    private void OnTitleBarMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState != MouseButtonState.Pressed || IsInsideButton(e.OriginalSource as DependencyObject))
            return;
        try { DragMove(); }
        catch (InvalidOperationException) { }
    }

    private void OnCloseClicked(object sender, RoutedEventArgs e) => Hide();

    private void OnClearSearch(object sender, RoutedEventArgs e)
    {
        SearchBox.Text = "";
        SearchBox.Focus();
    }

    private void OnSearchChanged(object sender, TextChangedEventArgs e)
    {
        var empty = SearchBox.Text.Length == 0;
        SearchHint.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        ClearSearchButton.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        if (IsVisible) _ = ReloadAsync();
    }

    private void OnListMouseDown(object sender, MouseButtonEventArgs e)
    {
        ResetDragState();
        if (IsInsideButton(e.OriginalSource as DependencyObject)) return;
        if (RowAt(e.OriginalSource) is not { } row) return;

        dragStartPoint = e.GetPosition(this);
        dragCandidate = row;
        pendingClickRow = row;
    }

    private void OnListMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed)
        {
            ResetDragState();
            return;
        }
        if (dragging || dragStartPoint is not { } start || dragCandidate is not { } row)
            return;

        var current = e.GetPosition(this);
        if (!HistoryWindowPlacement.IsDragDistanceReached(
                current.X - start.X,
                current.Y - start.Y,
                SystemParameters.MinimumHorizontalDragDistance,
                SystemParameters.MinimumVerticalDragDistance))
        {
            return;
        }

        // Clear the click candidate before DoDragDrop so a drag can never turn into a paste.
        pendingClickRow = null;
        dragStartPoint = null;
        dragCandidate = null;
        StartDrag(row);
    }

    private void OnListMouseUp(object sender, MouseButtonEventArgs e)
    {
        var clickRow = pendingClickRow;
        ResetDragState();
        if (clickRow is null || dragging || IsInsideButton(e.OriginalSource as DependencyObject))
            return;
        if (RowAt(e.OriginalSource) == clickRow)
            _ = ChooseAsync(clickRow, pasteAfter: pasteOnSelect());
    }

    private void StartDrag(HistoryRow row)
    {
        var data = BuildDragDataObject(row.Item, DragStagingRoot, log);
        if (data is null) return;

        dragging = true;
        try
        {
            DragDrop.DoDragDrop(HistoryList, data, DragDropEffects.Copy);
        }
        catch (Exception ex)
        {
            log($"history drag error={ex.GetType().Name}");
        }
        finally
        {
            dragging = false;
            ResetDragState();
        }

        if (pendingReloadAfterDrag)
        {
            pendingReloadAfterDrag = false;
            if (IsVisible) _ = ReloadAsync();
        }

        if (IsVisible && !IsActive && !choosing && HistoryList.ContextMenu?.IsOpen != true)
            Hide();
    }

    internal static DataObject? BuildDragDataObject(HistoryItem item, string stagingRoot, Action<string> log)
    {
        try
        {
            var data = new DataObject();
            if (item.Kind == "text")
            {
                data.SetText(item.Text ?? "");
                return data;
            }

            if (string.IsNullOrEmpty(item.Path) || !File.Exists(item.Path))
                return null;

            if (item.Kind == "image")
            {
                var staged = StageBodyFile(item.Path, stagingRoot, HistoryText.DragFileName(item));
                if (staged is not null)
                    data.SetFileDropList(new StringCollection { staged });

                using (var stream = new FileStream(item.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    var bitmap = ClipboardMonitor.LoadClipboardImage(stream, item.Type);
                    data.SetData(System.Windows.DataFormats.Bitmap, bitmap);
                    data.SetData("PNG", ClipboardMonitor.EncodeClipboardPng(bitmap));
                }
                return data;
            }

            var stagedFile = StageBodyFile(item.Path, stagingRoot, HistoryText.DragFileName(item));
            if (stagedFile is null) return null;
            data.SetFileDropList(new StringCollection { stagedFile });
            return data;
        }
        catch (Exception ex)
        {
            log($"history drag error={ex.GetType().Name}");
            return null;
        }
    }

    private static string? StageBodyFile(string sourcePath, string stagingRoot, string fileName)
    {
        var folder = Path.Combine(stagingRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var destination = Path.Combine(folder, fileName);
        using var input = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        input.CopyTo(output);
        return destination;
    }

    private static void CleanupOldDragStagingFiles(string stagingRoot)
    {
        try
        {
            if (!Directory.Exists(stagingRoot)) return;
            var cutoff = DateTime.UtcNow - DragStagingRetention;
            foreach (var dir in Directory.EnumerateDirectories(stagingRoot))
            {
                try
                {
                    if (Directory.GetCreationTimeUtc(dir) < cutoff)
                        Directory.Delete(dir, recursive: true);
                }
                catch (Exception) { }
            }
        }
        catch (Exception) { }
    }

    private void ResetDragState()
    {
        dragStartPoint = null;
        dragCandidate = null;
        pendingClickRow = null;
    }

    private void OnListRightDown(object sender, MouseButtonEventArgs e)
    {
        if (RowAt(e.OriginalSource) is { } row) HistoryList.SelectedItem = row;
    }

    /// <summary>The menu acts on the row under the pointer, so it does not open over empty space.</summary>
    private void OnContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        if (RowAt(e.OriginalSource) is null)
        {
            e.Handled = true;
            return;
        }
        if (HistoryList.ContextMenu is { } menu)
        {
            menu.PlacementTarget = HistoryList;
            menu.Placement = PlacementMode.MousePoint;
        }
    }

    private void OnCardMenuClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button) return;
        if (button.DataContext is HistoryRow row) HistoryList.SelectedItem = row;
        if (HistoryList.ContextMenu is not { } menu) return;
        menu.PlacementTarget = button;
        menu.Placement = PlacementMode.Bottom;
        menu.IsOpen = true;
        e.Handled = true;
    }

    private void OnContextMenuClosed(object sender, RoutedEventArgs e)
    {
        // Closing the menu by clicking another app leaves this window inactive without a new Deactivated.
        if (IsVisible && !IsActive && !choosing && !dragging) Hide();
    }

    private HistoryRow? RowAt(object source) =>
        source is DependencyObject element && ItemsControl.ContainerFromElement(HistoryList, element) is ListBoxItem item
            ? item.DataContext as HistoryRow
            : null;

    private static bool IsInsideButton(DependencyObject? source)
    {
        while (source is not null)
        {
            if (source is ButtonBase) return true;
            source = VisualTreeHelper.GetParent(source) ?? LogicalTreeHelper.GetParent(source);
        }
        return false;
    }

    private void OnMenuPaste(object sender, RoutedEventArgs e) => _ = ChooseAsync(Selected, pasteAfter: true);
    private void OnMenuCopy(object sender, RoutedEventArgs e) => _ = ChooseAsync(Selected, pasteAfter: false);
    private void OnMenuDelete(object sender, RoutedEventArgs e) => _ = DeleteAsync(Selected);

    private void OnSettings(object sender, RoutedEventArgs e)
    {
        Hide();
        openSettings();
    }

    private void OnActivated(object? sender, EventArgs e)
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        UnregisterEscFallbackHotkey(hwnd);
        SearchBox.Focus();
    }

    private void OnDeactivated(object? sender, EventArgs e)
    {
        // The context menu is a separate popup and drag-and-drop runs a modal loop; neither should close the window.
        if (HistoryList.ContextMenu?.IsOpen == true || choosing || dragging) return;
        Hide();
    }

    private void OnWindowVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (IsVisible) return;
        SaveCurrentPlacement();
        var hwnd = new WindowInteropHelper(this).Handle;
        UnregisterEscFallbackHotkey(hwnd);
        ResetDragState();
        // Hidden rows keep decoded thumbnails alive, so they go with the window.
        rows.Clear();
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (!AllowClose)
        {
            e.Cancel = true; // Alt+F4 would destroy the window that the hotkey reuses.
            Hide();
            return;
        }
        if (IsVisible) SaveCurrentPlacement();
        UnregisterEscFallbackHotkey(new WindowInteropHelper(this).Handle);
    }

    private void OnWindowClosed(object? sender, EventArgs e)
    {
        if (hwndSource is not null)
        {
            hwndSource.RemoveHook(WindowProc);
            hwndSource = null;
        }
        UnregisterEscFallbackHotkey(new WindowInteropHelper(this).Handle);
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        RoundCorners(hwnd);
        DisableMaximizeAndMinimizeButtons(hwnd);
        hwndSource = HwndSource.FromHwnd(hwnd);
        hwndSource?.AddHook(WindowProc);
    }

    private nint WindowProc(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        switch (msg)
        {
            case WmNcCalcSize when wParam != 0:
                handled = true;
                return 0;
            case WmNcHitTest when GetWindowRect(hwnd, out var rect):
                var x = unchecked((short)((long)lParam & 0xFFFF));
                var y = unchecked((short)(((long)lParam >> 16) & 0xFFFF));
                var scale = GetWindowScale(hwnd);
                var border = Math.Max(4, (int)Math.Round(ResizeBorderDip * scale));
                var hit = HistoryWindowPlacement.ComputeResizeHit(x, y, rect.left, rect.top, rect.right, rect.bottom, border, border);
                if (hit != HistoryWindowPlacement.HitNone)
                {
                    handled = true;
                    return hit;
                }
                break;
            case WmHotKey when (int)wParam == EscHotKeyId:
                handled = true;
                Hide();
                return 0;
        }
        return 0;
    }

    private void RegisterEscFallbackHotkey(nint hwnd)
    {
        if (hwnd == 0 || escHotKeyRegistered) return;
        escHotKeyRegistered = RegisterHotKey(hwnd, EscHotKeyId, 0, VirtualKeyEscape);
    }

    private void UnregisterEscFallbackHotkey(nint hwnd)
    {
        if (!escHotKeyRegistered || hwnd == 0) return;
        UnregisterHotKey(hwnd, EscHotKeyId);
        escHotKeyRegistered = false;
    }

    private WindowPixelRect ComputeTargetRect(nint hwnd, HistoryInvocation value)
    {
        var screens = GetScreens(hwnd);
        if (loadPlacement?.Invoke() is { } saved &&
            HistoryWindowPlacement.TryNormalize(saved.Left, saved.Top, saved.Width, saved.Height, out var validSaved))
        {
            return HistoryWindowPlacement.ResolveSaved(validSaved, screens);
        }

        var anchorX = value.CaretX ?? value.CursorX;
        var anchorY = value.CaretY ?? value.CursorY;
        return HistoryWindowPlacement.PlaceNearAnchor(
            anchorX,
            anchorY,
            value.CaretY is not null,
            HistoryWindowPlacement.DefaultWidth,
            HistoryWindowPlacement.DefaultHeight,
            screens);
    }

    private void ApplyPixelBounds(nint hwnd, WindowPixelRect target)
    {
        SetWindowPos(hwnd, 0, target.Left, target.Top, target.Width, target.Height, SwpNoZOrder | SwpNoActivate);
        // Moving across monitors with different DPIs can trigger WM_DPICHANGED; re-apply exact pixel bounds if shifted.
        if (GetWindowRect(hwnd, out var actual) &&
            (actual.left != target.Left ||
             actual.top != target.Top ||
             actual.right - actual.left != target.Width ||
             actual.bottom - actual.top != target.Height))
        {
            SetWindowPos(hwnd, 0, target.Left, target.Top, target.Width, target.Height, SwpNoZOrder | SwpNoActivate);
        }
    }

    private void SaveCurrentPlacement()
    {
        if (!placedForDisplay) return;
        placedForDisplay = false;
        if (savePlacement is null) return;
        if (ReadCurrentPlacement() is { } placement)
            savePlacement(placement);
    }

    private WindowPlacement? ReadCurrentPlacement()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == 0 || !GetWindowRect(hwnd, out var rect)) return null;
        var scale = GetWindowScale(hwnd);
        var widthDip = (rect.right - rect.left) / scale;
        var heightDip = (rect.bottom - rect.top) / scale;
        return HistoryWindowPlacement.Normalize(rect.left, rect.top, widthDip, heightDip);
    }

    private IReadOnlyList<ScreenBounds> GetScreens(nint hwnd)
    {
        var perMonitor = IsPerMonitorDpiAware();
        var fallbackScale = GetWindowScale(hwnd);
        var screens = new List<ScreenBounds>();
        foreach (var screen in System.Windows.Forms.Screen.AllScreens)
        {
            var work = screen.WorkingArea;
            var scale = perMonitor ? GetMonitorScaleForWorkArea(work, fallbackScale) : fallbackScale;
            screens.Add(new ScreenBounds(work.Left, work.Top, work.Right, work.Bottom, scale));
        }
        return screens;
    }

    private double GetWindowScale(nint hwnd)
    {
        if (hwnd != 0)
        {
            try
            {
                var dpi = GetDpiForWindow(hwnd);
                if (dpi > 0) return HistoryWindowPlacement.NormalizeScale(dpi / 96.0);
            }
            catch (EntryPointNotFoundException) { }
        }
        var source = PresentationSource.FromVisual(this) ?? (hwnd != 0 ? HwndSource.FromHwnd(hwnd) : null);
        var matrixScale = source?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
        return HistoryWindowPlacement.NormalizeScale(matrixScale);
    }

    private static bool IsPerMonitorDpiAware()
    {
        try
        {
            var context = GetThreadDpiAwarenessContext();
            return GetAwarenessFromDpiAwarenessContext(context) == DpiAwarenessPerMonitorAware;
        }
        catch (EntryPointNotFoundException)
        {
            return false;
        }
    }

    private static double GetMonitorScaleForWorkArea(System.Drawing.Rectangle work, double fallbackScale)
    {
        try
        {
            var center = new POINT
            {
                x = work.Left + work.Width / 2,
                y = work.Top + work.Height / 2,
            };
            var monitor = MonitorFromPoint(center, MonitorDefaultToNearest);
            if (monitor != 0 && GetDpiForMonitor(monitor, MdtEffectiveDpi, out var dpiX, out _) == 0 && dpiX > 0)
                return HistoryWindowPlacement.NormalizeScale(dpiX / 96.0);
        }
        catch (EntryPointNotFoundException) { }
        return fallbackScale;
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

        Set("Bg", "#F2F4F8", "#181A1F");
        Set("Card", "#FFFFFF", "#25272E");
        Set("CardBorder", "#0F000000", "#14FFFFFF");
        Set("Hover", "#EEF3FA", "#2E313A");
        Set("HoverBorder", "#262663EB", "#28FFFFFF");
        Set("Selected", "#E3ECFD", "#24385E");
        Set("SelectedBorder", "#2663EB", "#73A3FF");
        Set("Line", "#E2E8F0", "#353842");
        Set("Field", "#FFFFFF", "#25272E");
        Set("Fg", "#1F2937", "#F1F5F9");
        Set("Sub", "#64748B", "#9AA4B2");
        Set("Accent", "#2663EB", "#73A3FF");
        Set("AccentSoft", "#1F2663EB", "#2673A3FF");
        Set("CloseHover", "#FEE2E2", "#4C1D24");
        Set("ClosePressed", "#FECACA", "#68252E");
        Set("CloseHoverFg", "#DC2626", "#FCA5A5");
        Set("ScrollThumb", "#CBD5E1", "#474C59");
        Set("LinkTint", "#2663EB", "#73A3FF");
        Set("ImageTint", "#7C3AED", "#A78BFA");
        Set("ImageBadgeBg", "#1A7C3AED", "#26A78BFA");
        Set("FileTint", "#0D9488", "#2DD4BF");
        Set("FileBadgeBg", "#1A0D9488", "#262DD4BF");
        Set("EmailPhoneTint", "#16A34A", "#4ADE80");
        Set("ColorTint", "#DB2777", "#F472B6");
    }

    /// <summary>Rounded corners on Windows 11. Earlier versions ignore the attribute.</summary>
    private static void RoundCorners(nint hwnd)
    {
        if (hwnd == 0) return;
        var preference = DwmRound;
        _ = DwmSetWindowAttribute(hwnd, DwmWindowCornerPreference, ref preference, sizeof(int));
    }

    private static void DisableMaximizeAndMinimizeButtons(nint hwnd)
    {
        if (hwnd == 0) return;
        var style = GetWindowStyle(hwnd);
        var updated = style & ~(nint)(WsMaximizeBox | WsMinimizeBox);
        if (updated != style)
        {
            SetWindowStyle(hwnd, updated);
            SetWindowPos(hwnd, 0, 0, 0, 0, 0, SwpNoMove | SwpNoSize | SwpNoZOrder | SwpNoActivate | SwpFrameChanged);
        }
    }

    private static nint GetWindowStyle(nint hwnd) =>
        Environment.Is64BitProcess ? GetWindowLongPtr64(hwnd, GwlStyle) : GetWindowLong32(hwnd, GwlStyle);

    private static nint SetWindowStyle(nint hwnd, nint value) =>
        Environment.Is64BitProcess ? SetWindowLongPtr64(hwnd, GwlStyle, value) : SetWindowLong32(hwnd, GwlStyle, value);

    private const int VirtualKeyControl = 0x11;
    private const uint VirtualKeyEscape = 0x1B;
    private const int DwmWindowCornerPreference = 33;
    private const int DwmRound = 2;
    private const int GwlStyle = -16;
    private const uint WsMaximizeBox = 0x00010000;
    private const uint WsMinimizeBox = 0x00020000;
    private const int WmNcCalcSize = 0x0083;
    private const int WmNcHitTest = 0x0084;
    private const int WmHotKey = 0x0312;
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoZOrder = 0x0004;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpFrameChanged = 0x0020;
    private static readonly nint HwndTopMost = -1;
    private const uint MonitorDefaultToNearest = 2;
    private const int MdtEffectiveDpi = 0;
    private const int DpiAwarenessPerMonitorAware = 2;

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

    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindow(nint hwnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint hwnd, out uint processId);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(nint hwnd, out RECT rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowPos(nint hwnd, nint hwndInsertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RegisterHotKey(nint hwnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnregisterHotKey(nint hwnd, int id);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint hwnd);
    [DllImport("user32.dll")] private static extern nint GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")] private static extern int GetAwarenessFromDpiAwarenessContext(nint value);
    [DllImport("user32.dll")] private static extern nint MonitorFromPoint(POINT pt, uint flags);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(nint hmonitor, int dpiType, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll", EntryPoint = "GetWindowLong")] private static extern nint GetWindowLong32(nint hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] private static extern nint GetWindowLongPtr64(nint hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLong")] private static extern nint SetWindowLong32(nint hwnd, int index, nint value);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")] private static extern nint SetWindowLongPtr64(nint hwnd, int index, nint value);
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);
}
