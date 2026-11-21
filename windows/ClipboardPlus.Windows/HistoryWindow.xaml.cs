using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using ClipboardPlus.Windows.Infrastructure;
using Microsoft.Win32;
// The project also uses Windows Forms, whose implicit usings bring same-named types.
using Brush = System.Windows.Media.Brush;
using Button = System.Windows.Controls.Button;
using ButtonBase = System.Windows.Controls.Primitives.ButtonBase;
using Color = System.Windows.Media.Color;
using ColorConverter = System.Windows.Media.ColorConverter;
using ContextMenu = System.Windows.Controls.ContextMenu;
using DataFormats = System.Windows.DataFormats;
using DataObject = System.Windows.DataObject;
using DispatcherPriority = System.Windows.Threading.DispatcherPriority;
using DispatcherTimer = System.Windows.Threading.DispatcherTimer;
using DragDrop = System.Windows.DragDrop;
using DragDropEffects = System.Windows.DragDropEffects;
using DragEventArgs = System.Windows.DragEventArgs;
using IDataObject = System.Windows.IDataObject;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;
using MenuItem = System.Windows.Controls.MenuItem;
using MouseEventArgs = System.Windows.Input.MouseEventArgs;
using Point = System.Windows.Point;
using TextBox = System.Windows.Controls.TextBox;

namespace ClipboardPlus.Windows;

/// <summary>One history item as the window shows it. The thumbnail loads only when a row is drawn.</summary>
public sealed class HistoryRow
{
    internal const int ThumbnailDecodeHeight = 280; // Twice the 140-DIP card slot, so a full-size image is never decoded.
    internal const int ThumbnailMaxDecodeWidth = 720;

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
    public Visibility PlainTitleVisibility => Flavor != HistoryDisplayFlavor.Link && ThumbnailVisibility != Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
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
            var probe = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnDemand);
            if (probe.Frames.Count == 0) return null;
            var probeFrame = probe.Frames[0];
            var pixelWidth = probeFrame.PixelWidth;
            var pixelHeight = probeFrame.PixelHeight;
            if (pixelWidth <= 0 || pixelHeight <= 0) return null;

            stream.Position = 0;
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            if (pixelHeight > ThumbnailDecodeHeight || pixelWidth > ThumbnailMaxDecodeWidth)
            {
                // Set only one axis so BitmapImage preserves the image's aspect ratio.
                if ((long)pixelWidth * ThumbnailDecodeHeight > (long)ThumbnailMaxDecodeWidth * pixelHeight)
                    bitmap.DecodePixelWidth = ThumbnailMaxDecodeWidth;
                else
                    bitmap.DecodePixelHeight = ThumbnailDecodeHeight;
            }
            bitmap.StreamSource = stream;
            bitmap.EndInit();
            bitmap.Freeze();
            return bitmap;
        }
        catch (Exception) { return null; }
    }
}

public abstract class TemplateListRow
{
    public abstract bool IsHeader { get; }
}

public sealed class TemplateHeaderRow(TemplateGroupView group, bool isExpanded) : TemplateListRow
{
    public override bool IsHeader => true;
    public TemplateGroupView Group { get; } = group;
    public bool IsExpanded { get; } = isExpanded;
    public string Title => Group.Title;
    public string Count => Group.Items.Count.ToString(CultureInfo.InvariantCulture);
    public bool IsUntagged => Group.Tag is null;
    public string ChevronGlyph => IsExpanded ? "\uE70D" : "\uE76C";
    public string TagGlyph => Group.Tag is null ? "\uE7B8" : "\uE8EC";
}

public sealed class TemplateCardRow : TemplateListRow
{
    public TemplateCardRow(TemplateListEntry entry)
    {
        Entry = entry;
        Flavor = HistoryText.DetectTextFlavor(Item.Text, out var link, out var color);
        PreviewText = HistoryText.TextPreview(Item.Text);
        LinkHost = link?.Host;
        LinkRemainder = link?.Remainder;
        KindGlyph = HistoryText.FlavorGlyph(Flavor);
        KindLabel = Flavor switch
        {
            HistoryDisplayFlavor.Link => "リンク",
            HistoryDisplayFlavor.Email => "メール",
            HistoryDisplayFlavor.Phone => "電話",
            HistoryDisplayFlavor.Color => "色",
            _ => "定型文",
        };
        if (color is { } rgb)
        {
            var brush = new SolidColorBrush(Color.FromRgb(rgb.Red, rgb.Green, rgb.Blue));
            brush.Freeze();
            SwatchBrush = brush;
        }
    }

    public override bool IsHeader => false;
    public TemplateListEntry Entry { get; }
    public TemplateSyncItem Item => Entry.Item!;
    public string? Name => Item.Title;
    public HistoryDisplayFlavor Flavor { get; }
    public string PreviewText { get; }
    public string? LinkHost { get; }
    public string? LinkRemainder { get; }
    public string KindGlyph { get; }
    public string KindLabel { get; }
    public Brush? SwatchBrush { get; }

    public Visibility NameVisibility => !string.IsNullOrEmpty(Name) ? Visibility.Visible : Visibility.Collapsed;
    public Visibility LinkVisibility => Flavor == HistoryDisplayFlavor.Link ? Visibility.Visible : Visibility.Collapsed;
    public Visibility LinkRemainderVisibility => !string.IsNullOrEmpty(LinkRemainder) ? Visibility.Visible : Visibility.Collapsed;
    public Visibility PlainTextVisibility => Flavor != HistoryDisplayFlavor.Link ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ColorSwatchVisibility => Flavor == HistoryDisplayFlavor.Color ? Visibility.Visible : Visibility.Collapsed;
    public bool CanMoveUp => TemplateWindowLogic.CanMoveInGroup(Entry, -1);
    public bool CanMoveDown => TemplateWindowLogic.CanMoveInGroup(Entry, +1);
}

/// <summary>
/// The history window opened by the hotkey: search, pick, drag out, manage templates, and paste into the window that was in front.
/// It is created once and hidden between uses.
/// </summary>
public partial class HistoryWindow : Window, IHistoryPresenter
{
    private const double ResizeBorderDip = 5;
    internal const string SelfDragFormat = "ClipboardPlus.HistoryDrag";

    private enum EditorMode { None, CreateTemplate, EditTemplate, RenameTag }

    private readonly Action<string> log;
    private readonly Func<bool> pasteOnSelect;
    private readonly Func<nint, CancellationToken, Task<bool>> paste;
    private readonly Action openSettings;
    private readonly Func<WindowPlacement?>? loadPlacement;
    private readonly Action<WindowPlacement>? savePlacement;
    private readonly ObservableCollection<HistoryRow> rows = [];
    private readonly ObservableCollection<TemplateListRow> templateRows = [];
    private readonly HashSet<string> openTemplateTags = new(StringComparer.Ordinal);
    private readonly HashSet<string> closedTemplateTags = new(StringComparer.Ordinal);
    private readonly PasteTargetTracker pasteTarget = new();

    private SyncCoordinator? coordinator;
    private CancellationTokenSource? pasteCancel;
    private HwndSource? hwndSource;
    private WinEventDelegate? foregroundHookProc;
    private nint foregroundHook;
    private DispatcherTimer? noticeTimer;
    private HistoryWindowTab activeTab = TemplateWindowLogic.InitialTab();
    private int reloadVersion;
    private int? preferredIndex;
    private int? preferredTemplateIndex;
    private Guid? preferredTemplateId;
    private string? preferredHeaderTag;
    private bool hasPreferredHeaderTag;
    private bool choosing;
    private bool deleting;
    private bool dragging;
    private bool dropOverlayActive;
    private bool pendingReloadAfterDrag;
    private bool placedForDisplay;
    private bool syncingTemplates;
    private bool savingEditor;
    private Point? dragStartPoint;
    private HistoryRow? dragCandidate;
    private HistoryRow? pendingClickRow;
    private TemplateCardRow? dragTemplateCandidate;
    private TemplateCardRow? pendingTemplateClickRow;
    private TemplateHeaderRow? pendingTemplateHeaderClick;
    private TemplateSyncItem? pendingUndoTemplate;
    private EditorMode editorMode = EditorMode.None;
    private Guid? editingTemplateId;
    private TemplateSyncItem? editingOriginalTemplate;
    private string? renamingOldTag;

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
        TemplateList.ItemsSource = templateRows;
        ApplyTheme();
        UpdateTabVisuals();
        SourceInitialized += OnSourceInitialized;
        Closed += OnWindowClosed;
        IsVisibleChanged += OnWindowVisibleChanged;
    }

    /// <summary>Set when the app exits. Until then, closing (Alt+F4) only hides the reused window.</summary>
    public bool AllowClose { get; set; }

    internal static string DragStagingRoot => Path.Combine(LocalStore.Root, "drag");

    private bool IsEditorOpen => editorMode != EditorMode.None;

    /// <summary>Follows the coordinator, which re-pairing replaces. Null while there is none.</summary>
    public void Attach(SyncCoordinator? next)
    {
        if (coordinator is not null)
        {
            coordinator.HistoryChanged -= OnHistoryChanged;
            coordinator.TemplatesChanged -= OnTemplatesChanged;
        }
        coordinator = next;
        if (coordinator is not null)
        {
            coordinator.HistoryChanged += OnHistoryChanged;
            coordinator.TemplatesChanged += OnTemplatesChanged;
        }
        if (IsVisible) _ = ReloadAsync();
    }

    public void Present(HistoryInvocation value)
    {
        if (dragging) return;
        // A paste still waiting for keys to be released belongs to the previous opening.
        pasteCancel?.Cancel();
        // The hotkey a second time closes the window, as Win+V does.
        if (IsVisible && HistoryWindowPlacement.ShouldCloseWindow(HistoryWindowTrigger.HotkeyWhileVisible))
        {
            Hide();
            return;
        }

        pasteTarget.Reset(value.PreviousWindow);
        ApplyTheme();
        CloseEditor();
        ClearPendingUndo();
        activeTab = TemplateWindowLogic.InitialTab();
        UpdateTabVisuals();
        SearchBox.Text = "";

        var hwnd = new WindowInteropHelper(this).EnsureHandle();
        var target = ComputeTargetRect(hwnd, value);

        // Clear MinWidth/MinHeight across positioning and Show() so old-DPI limits never force cross-monitor overflow.
        MinWidth = 0;
        MinHeight = 0;
        try
        {
            ApplyPixelBounds(hwnd, target);
            placedForDisplay = true;

            Show();
            ApplyPixelBounds(hwnd, target);
            SetWindowPos(hwnd, HwndTopMost, 0, 0, 0, 0, SwpNoMove | SwpNoSize | SwpNoActivate);
        }
        finally
        {
            var actualScale = GetWindowScale(hwnd);
            MinWidth = Math.Min(HistoryWindowPlacement.MinWidth, target.Width / actualScale);
            MinHeight = Math.Min(HistoryWindowPlacement.MinHeight, target.Height / actualScale);
        }

        if (!ForegroundContext.BringToFront(hwnd, () => _ = Activate()))
            log("history window could not take the foreground");

        StartForegroundTracking();
        SearchBox.Focus();
        Keyboard.Focus(SearchBox);
        _ = ReloadAsync();
    }

    // HistoryChanged fires while the coordinator holds its lock, so the reload is posted.
    private void OnHistoryChanged() => Dispatcher.BeginInvoke(() =>
    {
        if (dragging)
        {
            pendingReloadAfterDrag = true;
            return;
        }
        if (IsVisible && activeTab == HistoryWindowTab.History)
        {
            _ = ReloadAsync();
            return;
        }
        if (HasDragStagingEntries(DragStagingRoot))
            _ = PruneDragStagingAsync();
    });

    private void OnTemplatesChanged() => Dispatcher.BeginInvoke(() =>
    {
        if (dragging)
        {
            pendingReloadAfterDrag = true;
            return;
        }
        if (IsVisible && activeTab == HistoryWindowTab.Templates)
            _ = ReloadAsync();
    });

    private void SwitchTab(HistoryWindowTab nextTab)
    {
        if (activeTab == nextTab) return;
        CloseEditor();
        ClearPendingUndo();
        HideNotice();
        ResetDragState();
        activeTab = nextTab;
        UpdateTabVisuals();
        SearchBox.Focus();
        Keyboard.Focus(SearchBox);
        if (IsVisible) _ = ReloadAsync();
    }

    private void UpdateTabVisuals()
    {
        var isTemplates = activeTab == HistoryWindowTab.Templates;
        TabHistoryButton.Tag = isTemplates ? null : "Active";
        TabTemplatesButton.Tag = isTemplates ? "Active" : null;
        TemplateActionsPanel.Visibility = isTemplates ? Visibility.Visible : Visibility.Collapsed;
        TitleModeText.Text = TemplateWindowLogic.TitleModeLabel(activeTab);
        SearchHint.Text = TemplateWindowLogic.SearchHint(activeTab);
        FooterHintText.Text = TemplateWindowLogic.FooterHint(activeTab);
        UpdateSyncButtonVisuals();

        if (isTemplates)
        {
            HistoryList.Visibility = Visibility.Collapsed;
            TemplateList.Visibility = templateRows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        else
        {
            TemplateList.Visibility = Visibility.Collapsed;
            HistoryList.Visibility = rows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private void UpdateSyncButtonVisuals()
    {
        TemplateSyncButton.IsEnabled = !syncingTemplates;
        TemplateSyncText.Text = syncingTemplates ? "同期中" : "同期";
    }

    private void SetTemplateSyncing(bool syncing)
    {
        syncingTemplates = syncing;
        UpdateSyncButtonVisuals();
        if (syncing)
        {
            var anim = new DoubleAnimation(0, 360, TimeSpan.FromMilliseconds(900))
            {
                RepeatBehavior = RepeatBehavior.Forever,
            };
            TemplateSyncRotate.BeginAnimation(RotateTransform.AngleProperty, anim);
        }
        else
        {
            TemplateSyncRotate.BeginAnimation(RotateTransform.AngleProperty, null);
            TemplateSyncRotate.Angle = 0;
        }
    }

    private async Task ReloadAsync()
    {
        var version = ++reloadVersion;
        var tab = activeTab;
        var current = coordinator;
        var search = SearchBox.Text.Trim();

        if (tab == HistoryWindowTab.Templates)
        {
            IReadOnlyList<TemplateGroupView> groups = [];
            if (current is not null)
            {
                try { groups = await current.GetTemplateGroupsAsync(search.Length == 0 ? null : search); }
                catch (Exception ex) { log($"template load error={ex.GetType().Name}"); return; }
            }
            if (version != reloadVersion || !IsVisible || activeTab != HistoryWindowTab.Templates)
                return;

            var selectedCardId = (SelectedTemplateRow as TemplateCardRow)?.Item.Id;
            var selectedHeaderTag = (SelectedTemplateRow as TemplateHeaderRow)?.Group.Tag;
            var hasSelectedHeader = SelectedTemplateRow is TemplateHeaderRow;

            var entries = TemplateWindowLogic.BuildVisibleEntries(groups, search, openTemplateTags, closedTemplateTags);
            templateRows.Clear();
            foreach (var entry in entries)
            {
                templateRows.Add(entry.IsHeader
                    ? new TemplateHeaderRow(entry.Group, entry.IsExpanded)
                    : new TemplateCardRow(entry));
            }

            UpdateEmptyState(tab, search);
            TemplateList.Visibility = templateRows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            HistoryList.Visibility = Visibility.Collapsed;

            var nextIndex = -1;
            if (preferredTemplateId is Guid prefId)
                nextIndex = IndexOfTemplateCard(prefId);
            else if (hasPreferredHeaderTag)
                nextIndex = IndexOfTemplateHeader(preferredHeaderTag);
            else if (selectedCardId is Guid prevId)
                nextIndex = IndexOfTemplateCard(prevId);
            else if (hasSelectedHeader)
                nextIndex = IndexOfTemplateHeader(selectedHeaderTag);

            if (nextIndex < 0 && preferredTemplateIndex is int place && templateRows.Count > 0)
                nextIndex = Math.Clamp(place, 0, templateRows.Count - 1);

            preferredTemplateId = null;
            preferredHeaderTag = null;
            hasPreferredHeaderTag = false;
            preferredTemplateIndex = null;

            TemplateList.SelectedIndex = nextIndex >= 0 ? nextIndex : (templateRows.Count > 0 ? 0 : -1);
            if (TemplateList.SelectedItem is not null) TemplateList.ScrollIntoView(TemplateList.SelectedItem);
            return;
        }

        IReadOnlyList<HistoryItem> items = [];
        if (current is not null)
        {
            try { items = await current.GetHistoryAsync(search.Length == 0 ? null : search); }
            catch (Exception ex) { log($"history load error={ex.GetType().Name}"); return; }
        }
        if (version != reloadVersion) return; // A newer search or change already reloaded.

        if (!dragging && HasDragStagingEntries(DragStagingRoot))
        {
            if (search.Length == 0)
                PruneDragStaging(DragStagingRoot, items);
            else if (current is not null)
                _ = PruneDragStagingAsync();
        }

        if (!IsVisible || activeTab != HistoryWindowTab.History) return;

        var selected = Selected?.Item.Id;
        var now = DateTimeOffset.Now;
        rows.Clear();
        foreach (var item in items) rows.Add(new HistoryRow(item, now));
        UpdateEmptyState(tab, search);
        HistoryList.Visibility = rows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        TemplateList.Visibility = Visibility.Collapsed;
        // Keep the selected item; if it is gone (deleted), stay at the same place in the list.
        var index = selected is Guid id ? IndexOf(id) : -1;
        if (index < 0 && preferredIndex is int placeHistory) index = Math.Min(placeHistory, rows.Count - 1);
        preferredIndex = null;
        HistoryList.SelectedIndex = index >= 0 ? index : (rows.Count > 0 ? 0 : -1);
        if (HistoryList.SelectedItem is not null) HistoryList.ScrollIntoView(HistoryList.SelectedItem);
    }

    private async Task PruneDragStagingAsync()
    {
        var current = coordinator;
        if (current is null || dragging || !HasDragStagingEntries(DragStagingRoot)) return;
        try
        {
            var allItems = await current.GetHistoryAsync(null);
            if (!dragging)
                PruneDragStaging(DragStagingRoot, allItems);
        }
        catch (Exception ex)
        {
            log($"history drag cleanup error={ex.GetType().Name}");
        }
    }

    private void UpdateEmptyState(HistoryWindowTab tab, string search)
    {
        var count = tab == HistoryWindowTab.Templates ? templateRows.Count : rows.Count;
        if (count > 0)
        {
            EmptyPanel.Visibility = Visibility.Collapsed;
            return;
        }
        var searching = !string.IsNullOrWhiteSpace(search);
        if (tab == HistoryWindowTab.Templates)
        {
            EmptyIcon.Text = searching ? "\uE721" : "\uE8EC";
            EmptyTitleText.Text = TemplateWindowLogic.TemplateEmptyTitle(search);
            EmptyDetailText.Text = TemplateWindowLogic.TemplateEmptyDetail(search);
            EmptyClearButton.Visibility = searching ? Visibility.Visible : Visibility.Collapsed;
            EmptyAddTemplateButton.Visibility = searching ? Visibility.Collapsed : Visibility.Visible;
        }
        else
        {
            EmptyIcon.Text = searching ? "\uE721" : "\uE77F";
            EmptyTitleText.Text = HistoryText.EmptyTitle(search);
            EmptyDetailText.Text = HistoryText.EmptyDetail(search);
            EmptyClearButton.Visibility = searching ? Visibility.Visible : Visibility.Collapsed;
            EmptyAddTemplateButton.Visibility = Visibility.Collapsed;
        }
        EmptyPanel.Visibility = Visibility.Visible;
    }

    private HistoryRow? Selected => HistoryList.SelectedItem as HistoryRow;
    private TemplateListRow? SelectedTemplateRow => TemplateList.SelectedItem as TemplateListRow;

    private int IndexOf(Guid id)
    {
        for (var i = 0; i < rows.Count; i++) if (rows[i].Item.Id == id) return i;
        return -1;
    }

    private int IndexOfTemplateCard(Guid id)
    {
        for (var i = 0; i < templateRows.Count; i++)
            if (templateRows[i] is TemplateCardRow card && card.Item.Id == id) return i;
        return -1;
    }

    private int IndexOfTemplateHeader(string? tag)
    {
        for (var i = 0; i < templateRows.Count; i++)
            if (templateRows[i] is TemplateHeaderRow header && string.Equals(header.Group.Tag, tag, StringComparison.Ordinal)) return i;
        return -1;
    }

    private void Move(int step)
    {
        if (activeTab == HistoryWindowTab.Templates)
        {
            if (templateRows.Count == 0) return;
            var idx = Math.Clamp(TemplateList.SelectedIndex + step, 0, templateRows.Count - 1);
            TemplateList.SelectedIndex = idx;
            TemplateList.ScrollIntoView(templateRows[idx]);
            return;
        }
        if (rows.Count == 0) return;
        var index = Math.Clamp(HistoryList.SelectedIndex + step, 0, rows.Count - 1);
        HistoryList.SelectedIndex = index;
        HistoryList.ScrollIntoView(rows[index]);
    }

    private async Task ChooseAsync(HistoryRow? row, bool? explicitPaste, bool ctrlPressed = false)
    {
        var current = coordinator;
        if (row is null || current is null || choosing) return;
        await CopyAndPasteAsync(() => current.CopyHistoryAsync(row.Item.Id), explicitPaste, ctrlPressed, "history");
    }

    private async Task ChooseTemplateAsync(TemplateCardRow? row, bool? explicitPaste, bool ctrlPressed = false)
    {
        var current = coordinator;
        if (row is null || current is null || choosing) return;
        await CopyAndPasteAsync(() => current.CopyTemplateAsync(row.Item.Id), explicitPaste, ctrlPressed, "template");
    }

    private async Task CopyAndPasteAsync(Func<Task> copyAction, bool? explicitPaste, bool ctrlPressed, string logKind)
    {
        choosing = true;
        nint target;
        HistorySelectionDecision decision;
        try
        {
            await copyAction();
            target = pasteTarget.CurrentTarget;
            // Opened from clipboard+'s own window or tray with no other window visited, there is nothing to paste into.
            var validTarget = target != 0 && ForegroundContext.IsWindowHandle(target) && !ForegroundContext.IsOwnProcessWindow(target);
            decision = HistoryWindowPlacement.DecideSelection(pasteOnSelect(), ctrlPressed, explicitPaste, validTarget);
            // Hand foreground to the target app while leaving this Topmost window open for further selections.
            if (decision.ShouldPaste) SetForegroundWindow(target);
            if (decision.ShouldClose) Hide();
        }
        catch (Exception ex)
        {
            // An item deleted meanwhile, or an image the clipboard refuses.
            log($"{logKind} choose error={ex.GetType().Name}");
            return;
        }
        finally { choosing = false; }

        if (!decision.ShouldPaste) return;
        pasteCancel?.Cancel();
        var cancel = pasteCancel = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try
        {
            if (!await paste(target, cancel.Token)) log($"{logKind} paste not delivered");
        }
        catch (OperationCanceledException) { log($"{logKind} paste cancelled"); }
        catch (Exception ex) { log($"{logKind} paste error={ex.GetType().Name}"); }
        finally
        {
            if (pasteCancel == cancel) pasteCancel = null;
            cancel.Dispose();
        }
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

    private async Task DeleteTemplateAsync(TemplateCardRow? row)
    {
        var current = coordinator;
        if (row is null || current is null || deleting) return;
        deleting = true;
        preferredTemplateIndex = TemplateList.SelectedIndex;
        try
        {
            var result = await current.DeleteTemplateAsync(row.Item.Id);
            if (result.Succeeded && result.Deleted is { } deleted && IsVisible)
            {
                pendingUndoTemplate = deleted;
                ShowNotice("テンプレートを削除しました", isWarning: false, showUndo: true, durationMs: 5000);
            }
        }
        catch (Exception ex)
        {
            log($"template delete error={ex.GetType().Name}");
            preferredTemplateIndex = null;
        }
        finally { deleting = false; }
    }

    private async Task MoveTemplateInGroupAsync(TemplateCardRow? row, int delta)
    {
        var current = coordinator;
        if (row is null || current is null || !TemplateWindowLogic.CanMoveInGroup(row.Entry, delta)) return;
        preferredTemplateId = row.Item.Id;
        try
        {
            if (!await current.MoveTemplateInGroupAsync(row.Item.Id, delta))
                preferredTemplateId = null;
        }
        catch (Exception ex)
        {
            log($"template reorder error={ex.GetType().Name}");
            preferredTemplateId = null;
        }
    }

    private void ToggleTemplateGroup(TemplateHeaderRow header)
    {
        var search = SearchBox.Text.Trim();
        var groupCount = templateRows.OfType<TemplateHeaderRow>().Count();
        TemplateWindowLogic.ToggleGroupExpansion(header.Group.Tag, groupCount, search, openTemplateTags, closedTemplateTags);
        preferredHeaderTag = header.Group.Tag;
        hasPreferredHeaderTag = true;
        _ = ReloadAsync();
    }

    private void EnsureGroupExpanded(string? tag)
    {
        var key = TemplateWindowLogic.GroupKey(tag);
        openTemplateTags.Add(key);
        closedTemplateTags.Remove(key);
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        // AttachThreadInput can reset this thread's key state, so Ctrl is also asked of Windows.
        var ctrl = IsCtrlPressed();
        var alt = (Keyboard.Modifiers & ModifierKeys.Alt) != 0;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;

        if (IsEditorOpen)
        {
            if (key == Key.Escape)
            {
                CloseEditor();
                e.Handled = true;
            }
            else if (key == Key.Enter && (ctrl || !ReferenceEquals(Keyboard.FocusedElement, TemplateBodyBox)))
            {
                _ = SaveEditorAsync();
                e.Handled = true;
            }
            return;
        }

        if (ctrl && key == Key.Tab)
        {
            SwitchTab(TemplateWindowLogic.ToggleTab(activeTab));
            e.Handled = true;
            return;
        }

        if (alt && activeTab == HistoryWindowTab.Templates && key is Key.Up or Key.Down)
        {
            if (SelectedTemplateRow is TemplateCardRow cardRow)
                _ = MoveTemplateInGroupAsync(cardRow, key == Key.Up ? -1 : 1);
            e.Handled = true;
            return;
        }

        switch (key)
        {
            case Key.Escape:
                if (HistoryWindowPlacement.ShouldCloseWindow(HistoryWindowTrigger.EscapeKey, IsActive))
                    Hide();
                break;
            case Key.Down: Move(1); break;
            case Key.Up: Move(-1); break;
            case Key.PageDown: Move(5); break;
            case Key.PageUp: Move(-5); break;
            case Key.Enter:
                if (activeTab == HistoryWindowTab.Templates)
                {
                    var decision = TemplateWindowLogic.DecideTemplateActivation(
                        SelectedTemplateRow is TemplateHeaderRow,
                        pasteOnSelect(),
                        ctrl,
                        explicitPaste: null,
                        hasValidExternalTarget: false);
                    if (decision.Action == TemplateActivationAction.ToggleGroup && SelectedTemplateRow is TemplateHeaderRow header)
                        ToggleTemplateGroup(header);
                    else if (decision.Action == TemplateActivationAction.SelectItem && SelectedTemplateRow is TemplateCardRow card)
                        _ = ChooseTemplateAsync(card, explicitPaste: null, ctrlPressed: ctrl);
                }
                else
                {
                    _ = ChooseAsync(Selected, explicitPaste: null, ctrlPressed: ctrl);
                }
                break;
            // While a search is typed, Delete edits the search; with an empty box it removes the item.
            case Key.Delete when SearchBox.Text.Length == 0:
                if (activeTab == HistoryWindowTab.Templates)
                {
                    if (SelectedTemplateRow is TemplateCardRow card)
                        _ = DeleteTemplateAsync(card);
                }
                else
                {
                    _ = DeleteAsync(Selected);
                }
                break;
            default: return;
        }
        e.Handled = true;
    }

    private bool IsCtrlPressed() =>
        (Keyboard.Modifiers & ModifierKeys.Control) != 0 || (GetAsyncKeyState(VirtualKeyControl) & 0x8000) != 0;

    private void OnTitleBarMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState != MouseButtonState.Pressed || IsInsideButton(e.OriginalSource as DependencyObject))
            return;
        try { DragMove(); }
        catch (InvalidOperationException) { }
    }

    private void OnCloseClicked(object sender, RoutedEventArgs e)
    {
        if (HistoryWindowPlacement.ShouldCloseWindow(HistoryWindowTrigger.CloseButton))
            Hide();
    }

    private void OnTabHistoryClick(object sender, RoutedEventArgs e) => SwitchTab(HistoryWindowTab.History);
    private void OnTabTemplatesClick(object sender, RoutedEventArgs e) => SwitchTab(HistoryWindowTab.Templates);

    private async void OnTemplateSyncClick(object sender, RoutedEventArgs e)
    {
        if (syncingTemplates) return;
        var current = coordinator;
        if (current is null)
        {
            ShowNotice("いまは同期できません", isWarning: true);
            return;
        }
        SetTemplateSyncing(true);
        try
        {
            var result = await current.SyncTemplatesAsync();
            if (IsVisible && TemplateWindowLogic.FormatSyncNotice(result) is { } notice)
                ShowNotice(notice.Message, notice.IsWarning, showUndo: false, durationMs: 4200);
        }
        catch (Exception ex)
        {
            log($"template sync ui error={ex.GetType().Name}");
            if (IsVisible)
                ShowNotice("テンプレートの同期に失敗しました", isWarning: true);
        }
        finally
        {
            SetTemplateSyncing(false);
        }
    }

    private void OnAddTemplateClick(object sender, RoutedEventArgs e) => OpenTemplateEditor(existing: null, presetTag: null);

    private void OpenTemplateEditor(TemplateSyncItem? existing, string? presetTag)
    {
        ClearEditorError();
        if (existing is null)
        {
            editorMode = EditorMode.CreateTemplate;
            editingTemplateId = null;
            editingOriginalTemplate = null;
            EditorTitleText.Text = "テンプレートを追加";
            TemplateNameBox.Text = "";
            TemplateTagBox.Text = presetTag ?? "";
            TemplateBodyBox.Text = "";
        }
        else
        {
            editorMode = EditorMode.EditTemplate;
            editingTemplateId = existing.Id;
            editingOriginalTemplate = existing;
            EditorTitleText.Text = "テンプレートを編集";
            TemplateNameBox.Text = existing.Title ?? "";
            TemplateTagBox.Text = existing.Tag ?? "";
            TemplateBodyBox.Text = existing.Text;
        }
        EditorSaveButton.Content = "保存";
        TemplateEditFields.Visibility = Visibility.Visible;
        RenameTagFields.Visibility = Visibility.Collapsed;
        TemplateEditorOverlay.Visibility = Visibility.Visible;
        TemplateBodyBox.Focus();
        TemplateBodyBox.CaretIndex = TemplateBodyBox.Text.Length;
    }

    private void OpenRenameTagEditor(string? currentTag)
    {
        ClearEditorError();
        editorMode = EditorMode.RenameTag;
        editingTemplateId = null;
        editingOriginalTemplate = null;
        renamingOldTag = currentTag;
        EditorTitleText.Text = currentTag is null ? "タグを付ける" : "タグ名を変更";
        RenameTagBox.Text = currentTag ?? "";
        EditorSaveButton.Content = "変更";
        TemplateEditFields.Visibility = Visibility.Collapsed;
        RenameTagFields.Visibility = Visibility.Visible;
        TemplateEditorOverlay.Visibility = Visibility.Visible;
        RenameTagBox.Focus();
        RenameTagBox.SelectAll();
    }

    private void CloseEditor()
    {
        editorMode = EditorMode.None;
        editingTemplateId = null;
        editingOriginalTemplate = null;
        renamingOldTag = null;
        savingEditor = false;
        ClearEditorError();
        TemplateEditorOverlay.Visibility = Visibility.Collapsed;
        if (IsVisible)
        {
            SearchBox.Focus();
            Keyboard.Focus(SearchBox);
        }
    }

    private void ShowEditorError(string message)
    {
        EditorErrorText.Text = message;
        EditorErrorText.Visibility = Visibility.Visible;
    }

    private void ClearEditorError()
    {
        EditorErrorText.Text = "";
        EditorErrorText.Visibility = Visibility.Collapsed;
    }

    private async Task SaveEditorAsync()
    {
        if (savingEditor || !IsEditorOpen) return;
        var current = coordinator;
        if (current is null)
        {
            ShowEditorError("いまは保存できません");
            return;
        }
        savingEditor = true;
        try
        {
            if (editorMode == EditorMode.RenameTag)
            {
                var newTag = TemplateRepository.SanitizeTag(RenameTagBox.Text);
                TemplateWindowLogic.TransferGroupExpansionOnRename(renamingOldTag, newTag, openTemplateTags, closedTemplateTags);
                preferredHeaderTag = newTag;
                hasPreferredHeaderTag = true;
                await current.RenameTemplateTagAsync(renamingOldTag, newTag);
                CloseEditor();
                return;
            }

            var body = TemplateBodyBox.Text;
            var name = TemplateNameBox.Text;
            var tag = TemplateTagBox.Text;
            var result = editorMode == EditorMode.EditTemplate && editingTemplateId is Guid editId
                ? await current.UpdateTemplateAsync(editId, body, name, tag, editingOriginalTemplate)
                : await current.CreateTemplateAsync(body, name, tag);

            if (!result.Succeeded)
            {
                ShowEditorError(result.ErrorMessage ?? "保存できませんでした");
                return;
            }

            if (result.Item is { } saved)
            {
                EnsureGroupExpanded(saved.Tag);
                preferredTemplateId = saved.Id;
            }
            var hadConflictCopy = result.ConflictCopy is not null;
            CloseEditor();
            if (hadConflictCopy && IsVisible)
                ShowNotice("別の端末で更新された本文を「その他」に残しました", isWarning: true, showUndo: false, durationMs: 4200);
        }
        catch (Exception ex)
        {
            log($"template save error={ex.GetType().Name}");
            ShowEditorError("テンプレートを保存できませんでした");
        }
        finally
        {
            savingEditor = false;
        }
    }

    private async void OnPickTagClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn)
            await ShowTagPickerMenuAsync(btn, TemplateTagBox, includeUntaggedOption: true);
    }

    private async void OnPickRenameTagClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn)
            await ShowTagPickerMenuAsync(btn, RenameTagBox, includeUntaggedOption: true);
    }

    private async Task ShowTagPickerMenuAsync(Button anchor, TextBox targetBox, bool includeUntaggedOption)
    {
        var current = coordinator;
        if (current is null) return;
        IReadOnlyList<string> tags;
        try { tags = await current.GetTemplateTagsAsync(); }
        catch (Exception ex) { log($"template tag list error={ex.GetType().Name}"); return; }

        if (!IsVisible || !IsEditorOpen) return;
        var menu = new ContextMenu { PlacementTarget = anchor, Placement = PlacementMode.Bottom };
        foreach (var tag in tags)
        {
            var chosen = tag;
            var item = new MenuItem { Header = chosen };
            item.Click += (_, _) =>
            {
                targetBox.Text = chosen;
                targetBox.Focus();
                targetBox.CaretIndex = targetBox.Text.Length;
            };
            menu.Items.Add(item);
        }
        if (includeUntaggedOption)
        {
            if (tags.Count > 0) menu.Items.Add(new Separator());
            var untagged = new MenuItem { Header = "タグなし（その他）" };
            untagged.Click += (_, _) =>
            {
                targetBox.Text = "";
                targetBox.Focus();
            };
            menu.Items.Add(untagged);
        }
        menu.IsOpen = true;
    }

    private void OnEditorBackdropMouseDown(object sender, MouseButtonEventArgs e)
    {
        CloseEditor();
        e.Handled = true;
    }

    private void OnEditorCardMouseDown(object sender, MouseButtonEventArgs e) => e.Handled = true;
    private void OnEditorCancel(object sender, RoutedEventArgs e) => CloseEditor();
    private void OnEditorSave(object sender, RoutedEventArgs e) => _ = SaveEditorAsync();

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
            _ = ChooseAsync(clickRow, explicitPaste: null, ctrlPressed: false);
    }

    private void OnTemplateListMouseDown(object sender, MouseButtonEventArgs e)
    {
        ResetDragState();
        if (IsInsideButton(e.OriginalSource as DependencyObject)) return;
        var row = TemplateRowAt(e.OriginalSource);
        if (row is TemplateHeaderRow header)
        {
            TemplateList.SelectedItem = header;
            pendingTemplateHeaderClick = header;
            return;
        }
        if (row is TemplateCardRow card)
        {
            dragStartPoint = e.GetPosition(this);
            dragTemplateCandidate = card;
            pendingTemplateClickRow = card;
        }
    }

    private void OnTemplateListMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed)
        {
            ResetDragState();
            return;
        }
        if (dragging || dragStartPoint is not { } start || dragTemplateCandidate is not { } row)
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

        pendingTemplateClickRow = null;
        dragStartPoint = null;
        dragTemplateCandidate = null;
        StartTemplateDrag(row);
    }

    private void OnTemplateListMouseUp(object sender, MouseButtonEventArgs e)
    {
        var clickHeader = pendingTemplateHeaderClick;
        var clickCard = pendingTemplateClickRow;
        ResetDragState();
        if (dragging || IsInsideButton(e.OriginalSource as DependencyObject))
            return;
        var currentRow = TemplateRowAt(e.OriginalSource);
        if (clickHeader is not null && ReferenceEquals(currentRow, clickHeader))
        {
            ToggleTemplateGroup(clickHeader);
            return;
        }
        if (clickCard is not null && ReferenceEquals(currentRow, clickCard))
            _ = ChooseTemplateAsync(clickCard, explicitPaste: null, ctrlPressed: false);
    }

    private void OnThumbnailImageSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (sender is not FrameworkElement element) return;
        if (e.NewSize.Width <= 0 || e.NewSize.Height <= 0)
        {
            element.Clip = null;
            return;
        }
        var clip = new RectangleGeometry(new Rect(0, 0, e.NewSize.Width, e.NewSize.Height), 8, 8);
        clip.Freeze();
        element.Clip = clip;
    }

    private void StartDrag(HistoryRow row)
    {
        if (dragging) return;
        var data = BuildDragDataObject(row.Item, DragStagingRoot, log);
        if (data is null) return;
        RunDragDrop(HistoryList, data);
    }

    private void StartTemplateDrag(TemplateCardRow row)
    {
        if (dragging) return;
        var data = BuildTextDragDataObject(row.Item.Text);
        RunDragDrop(TemplateList, data);
    }

    private void RunDragDrop(DependencyObject source, DataObject data)
    {
        dragging = true;
        try
        {
            DragDrop.DoDragDrop(source, data, DragDropEffects.Copy);
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
            else if (HasDragStagingEntries(DragStagingRoot)) _ = PruneDragStagingAsync();
        }
    }

    internal static DataObject BuildTextDragDataObject(string text)
    {
        var data = new DataObject();
        data.SetData(SelfDragFormat, true);
        data.SetText(text);
        return data;
    }

    internal static DataObject? BuildDragDataObject(
        HistoryItem item,
        string stagingRoot,
        Action<string> log,
        Func<string, string, bool>? tryHardLink = null)
    {
        try
        {
            if (item.Kind == "text")
                return BuildTextDragDataObject(item.Text ?? "");

            var data = new DataObject();
            data.SetData(SelfDragFormat, true);

            if (string.IsNullOrEmpty(item.Path) || !File.Exists(item.Path))
                return null;

            var folderKey = StagingFolderKey(item);
            var fileName = HistoryText.DragFileName(item);

            if (item.Kind == "image")
            {
                BitmapFrame bitmap;
                MemoryStream pngStream;
                using (var stream = new FileStream(item.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    bitmap = ClipboardMonitor.LoadClipboardImage(stream, item.Type);
                    if (item.Type == "public.png")
                    {
                        stream.Position = 0;
                        pngStream = new MemoryStream(checked((int)stream.Length));
                        stream.CopyTo(pngStream);
                        pngStream.Position = 0;
                    }
                    else
                    {
                        pngStream = ClipboardMonitor.EncodeClipboardPng(bitmap);
                    }
                }

                var staged = StageBodyFile(item.Path, stagingRoot, folderKey, fileName, tryHardLink);
                if (staged is not null)
                    data.SetFileDropList(new StringCollection { staged });

                data.SetData(System.Windows.DataFormats.Bitmap, bitmap);
                data.SetData("PNG", pngStream);
                return data;
            }

            var stagedFile = StageBodyFile(item.Path, stagingRoot, folderKey, fileName, tryHardLink);
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

    internal static string StagingFolderKey(HistoryItem item)
    {
        if (!string.IsNullOrEmpty(item.Hash) && item.Hash.All(char.IsAsciiHexDigit))
            return item.Hash.ToLowerInvariant();
        return item.Id.ToString("N");
    }

    private static string? StageBodyFile(
        string sourcePath,
        string stagingRoot,
        string folderKey,
        string fileName,
        Func<string, string, bool>? tryHardLink)
    {
        var sourceLength = new FileInfo(sourcePath).Length;
        var folder = Path.Combine(stagingRoot, folderKey);
        Directory.CreateDirectory(folder);
        var destination = Path.Combine(folder, fileName);

        if (File.Exists(destination))
        {
            try
            {
                if (new FileInfo(destination).Length == sourceLength)
                    return destination;
                File.Delete(destination);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
            }
        }

        tryHardLink ??= static (linkPath, existingPath) => CreateHardLink(linkPath, existingPath, 0);
        if (tryHardLink(destination, sourcePath))
            return destination;

        var tempPath = Path.Combine(folder, Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var input = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var output = new FileStream(tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                input.CopyTo(output);
            }
            File.Move(tempPath, destination, overwrite: true);
            return destination;
        }
        catch
        {
            try { File.Delete(tempPath); } catch { }
            throw;
        }
    }

    internal static bool HasDragStagingEntries(string stagingRoot)
    {
        try { return Directory.Exists(stagingRoot) && Directory.EnumerateFileSystemEntries(stagingRoot).Any(); }
        catch (Exception) { return false; }
    }

    internal static void ClearDragStaging(string stagingRoot)
    {
        try
        {
            if (Directory.Exists(stagingRoot))
                Directory.Delete(stagingRoot, recursive: true);
        }
        catch (Exception) { }
    }

    internal static void PruneDragStaging(string stagingRoot, IReadOnlyList<HistoryItem> items)
    {
        try
        {
            if (!Directory.Exists(stagingRoot)) return;
            var keep = items
                .Where(i => i.Kind != "text")
                .Select(StagingFolderKey)
                .ToHashSet(StringComparer.OrdinalIgnoreCase);

            foreach (var dir in Directory.EnumerateDirectories(stagingRoot))
            {
                var name = Path.GetFileName(dir);
                if (keep.Contains(name)) continue;
                try { Directory.Delete(dir, recursive: true); }
                catch (Exception) { }
            }
            foreach (var file in Directory.EnumerateFiles(stagingRoot))
            {
                try { File.Delete(file); }
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
        dragTemplateCandidate = null;
        pendingTemplateClickRow = null;
        pendingTemplateHeaderClick = null;
    }

    private void OnListRightDown(object sender, MouseButtonEventArgs e)
    {
        if (RowAt(e.OriginalSource) is { } row) HistoryList.SelectedItem = row;
    }

    /// <summary>The menu acts on the row under the pointer, so it does not open over empty space.</summary>
    private void OnContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        if (RowAt(e.OriginalSource) is not { } row)
        {
            e.Handled = true;
            return;
        }
        HistoryMenuMoveToTemplates.Visibility = row.Item.Kind == "text" ? Visibility.Visible : Visibility.Collapsed;
        if (HistoryList.ContextMenu is { } menu)
        {
            menu.PlacementTarget = HistoryList;
            menu.Placement = PlacementMode.MousePoint;
        }
    }

    private void OnCardMenuClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button) return;
        if (button.DataContext is HistoryRow row)
        {
            HistoryList.SelectedItem = row;
            HistoryMenuMoveToTemplates.Visibility = row.Item.Kind == "text" ? Visibility.Visible : Visibility.Collapsed;
        }
        if (HistoryList.ContextMenu is not { } menu) return;
        menu.PlacementTarget = button;
        menu.Placement = PlacementMode.Bottom;
        menu.IsOpen = true;
        e.Handled = true;
    }

    private void OnTemplateListRightDown(object sender, MouseButtonEventArgs e)
    {
        if (TemplateRowAt(e.OriginalSource) is { } row) TemplateList.SelectedItem = row;
    }

    private void OnTemplateContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        if (TemplateRowAt(e.OriginalSource) is not { } row)
        {
            e.Handled = true;
            return;
        }
        ConfigureTemplateContextMenu(row);
        if (TemplateList.ContextMenu is { } menu)
        {
            menu.PlacementTarget = TemplateList;
            menu.Placement = PlacementMode.MousePoint;
        }
    }

    private void OnTemplateRowMenuClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button) return;
        if (button.DataContext is TemplateListRow row)
        {
            TemplateList.SelectedItem = row;
            ConfigureTemplateContextMenu(row);
        }
        if (TemplateList.ContextMenu is not { } menu) return;
        menu.PlacementTarget = button;
        menu.Placement = PlacementMode.Bottom;
        menu.IsOpen = true;
        e.Handled = true;
    }

    private void ConfigureTemplateContextMenu(TemplateListRow row)
    {
        if (row is TemplateCardRow card)
        {
            TplMenuPaste.Visibility = Visibility.Visible;
            TplMenuCopy.Visibility = Visibility.Visible;
            TplMenuSep1.Visibility = Visibility.Visible;
            TplMenuEdit.Visibility = Visibility.Visible;
            TplMenuMoveUp.Visibility = Visibility.Visible;
            TplMenuMoveUp.IsEnabled = card.CanMoveUp;
            TplMenuMoveDown.Visibility = Visibility.Visible;
            TplMenuMoveDown.IsEnabled = card.CanMoveDown;
            TplMenuSep2.Visibility = Visibility.Visible;
            TplMenuDelete.Visibility = Visibility.Visible;
            TplMenuAddInTag.Visibility = Visibility.Collapsed;
            TplMenuRenameTag.Visibility = Visibility.Collapsed;
        }
        else if (row is TemplateHeaderRow header)
        {
            TplMenuPaste.Visibility = Visibility.Collapsed;
            TplMenuCopy.Visibility = Visibility.Collapsed;
            TplMenuSep1.Visibility = Visibility.Collapsed;
            TplMenuEdit.Visibility = Visibility.Collapsed;
            TplMenuMoveUp.Visibility = Visibility.Collapsed;
            TplMenuMoveDown.Visibility = Visibility.Collapsed;
            TplMenuSep2.Visibility = Visibility.Collapsed;
            TplMenuDelete.Visibility = Visibility.Collapsed;
            TplMenuAddInTag.Visibility = Visibility.Visible;
            TplMenuRenameTag.Visibility = Visibility.Visible;
            TplMenuRenameTag.Header = header.IsUntagged ? "タグを付ける…" : "タグ名を変更…";
        }
    }

    private HistoryRow? RowAt(object source)
    {
        var current = UnwrapContentElement(source as DependencyObject);
        return current is not null && ItemsControl.ContainerFromElement(HistoryList, current) is ListBoxItem item
            ? item.DataContext as HistoryRow
            : null;
    }

    private TemplateListRow? TemplateRowAt(object source)
    {
        var current = UnwrapContentElement(source as DependencyObject);
        return current is not null && ItemsControl.ContainerFromElement(TemplateList, current) is ListBoxItem item
            ? item.DataContext as TemplateListRow
            : null;
    }

    private static DependencyObject? UnwrapContentElement(DependencyObject? current)
    {
        while (current is ContentElement content)
            current = ContentOperations.GetParent(content) ?? LogicalTreeHelper.GetParent(content);
        return current;
    }

    internal static bool IsInsideButton(DependencyObject? source)
    {
        while (source is not null)
        {
            if (source is ButtonBase) return true;
            source = source switch
            {
                Visual or System.Windows.Media.Media3D.Visual3D =>
                    VisualTreeHelper.GetParent(source) ?? LogicalTreeHelper.GetParent(source),
                ContentElement content =>
                    ContentOperations.GetParent(content) ?? LogicalTreeHelper.GetParent(content),
                _ => LogicalTreeHelper.GetParent(source),
            };
        }
        return false;
    }

    private void OnMenuPaste(object sender, RoutedEventArgs e) => _ = ChooseAsync(Selected, explicitPaste: true);
    private void OnMenuCopy(object sender, RoutedEventArgs e) => _ = ChooseAsync(Selected, explicitPaste: false);
    private void OnMenuDelete(object sender, RoutedEventArgs e) => _ = DeleteAsync(Selected);

    private async void OnMenuMoveToTemplates(object sender, RoutedEventArgs e)
    {
        var row = Selected;
        var current = coordinator;
        if (row is null || current is null || row.Item.Kind != "text") return;
        try
        {
            var result = await current.MoveHistoryToTemplatesAsync(row.Item.Id);
            if (!IsVisible) return;
            if (result.Succeeded)
                ShowNotice("テンプレートの「その他」に移動しました", isWarning: false);
            else
                ShowNotice(result.ErrorMessage ?? "テンプレートに移動できませんでした", isWarning: true);
        }
        catch (Exception ex)
        {
            log($"template move error={ex.GetType().Name}");
            if (IsVisible) ShowNotice("テンプレートに移動できませんでした", isWarning: true);
        }
    }

    private void OnTemplateMenuPaste(object sender, RoutedEventArgs e)
    {
        if (SelectedTemplateRow is TemplateCardRow card)
            _ = ChooseTemplateAsync(card, explicitPaste: true);
    }

    private void OnTemplateMenuCopy(object sender, RoutedEventArgs e)
    {
        if (SelectedTemplateRow is TemplateCardRow card)
            _ = ChooseTemplateAsync(card, explicitPaste: false);
    }

    private void OnTemplateMenuEdit(object sender, RoutedEventArgs e)
    {
        if (SelectedTemplateRow is TemplateCardRow card)
            OpenTemplateEditor(card.Item, presetTag: null);
    }

    private void OnTemplateMenuMoveUp(object sender, RoutedEventArgs e)
    {
        if (SelectedTemplateRow is TemplateCardRow card)
            _ = MoveTemplateInGroupAsync(card, -1);
    }

    private void OnTemplateMenuMoveDown(object sender, RoutedEventArgs e)
    {
        if (SelectedTemplateRow is TemplateCardRow card)
            _ = MoveTemplateInGroupAsync(card, 1);
    }

    private void OnTemplateMenuDelete(object sender, RoutedEventArgs e)
    {
        if (SelectedTemplateRow is TemplateCardRow card)
            _ = DeleteTemplateAsync(card);
    }

    private void OnTemplateMenuAddInTag(object sender, RoutedEventArgs e)
    {
        if (SelectedTemplateRow is TemplateHeaderRow header)
            OpenTemplateEditor(existing: null, presetTag: header.Group.Tag);
    }

    private void OnTemplateMenuRenameTag(object sender, RoutedEventArgs e)
    {
        if (SelectedTemplateRow is TemplateHeaderRow header)
            OpenRenameTagEditor(header.Group.Tag);
    }

    private async void OnUndoNoticeClick(object sender, RoutedEventArgs e)
    {
        var deleted = pendingUndoTemplate;
        var current = coordinator;
        ClearPendingUndo();
        HideNotice();
        if (deleted is null || current is null) return;
        try
        {
            var result = await current.RestoreDeletedTemplateAsync(deleted);
            if (result.Succeeded && result.Item is { } restored)
            {
                EnsureGroupExpanded(restored.Tag);
                preferredTemplateId = restored.Id;
            }
            else if (!result.Succeeded && IsVisible)
            {
                ShowNotice(result.ErrorMessage ?? "元に戻せませんでした", isWarning: true);
            }
        }
        catch (Exception ex)
        {
            log($"template undo error={ex.GetType().Name}");
            if (IsVisible) ShowNotice("元に戻せませんでした", isWarning: true);
        }
    }

    private void OnDismissNotice(object sender, RoutedEventArgs e)
    {
        ClearPendingUndo();
        HideNotice();
    }

    private void OnPreviewDragEnter(object sender, DragEventArgs e) => HandleDragOver(e);
    private void OnPreviewDragOver(object sender, DragEventArgs e) => HandleDragOver(e);

    private void HandleDragOver(DragEventArgs e)
    {
        var sourceKind = IsEditorOpen ? DropSourceKind.None : DetectDropSource(e.Data, dragging);
        var acceptable = sourceKind != DropSourceKind.None && (e.AllowedEffects & DragDropEffects.Copy) != 0;
        if (acceptable)
        {
            e.Effects = DragDropEffects.Copy;
            SetDropOverlayActive(true);
        }
        else
        {
            e.Effects = DragDropEffects.None;
            SetDropOverlayActive(false);
        }
        e.Handled = true;
    }

    private void OnPreviewDragLeave(object sender, DragEventArgs e)
    {
        dropOverlayActive = false;
        e.Handled = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
        {
            if (!dropOverlayActive)
                DropOverlay.Visibility = Visibility.Collapsed;
        });
    }

    private async void OnPreviewDrop(object sender, DragEventArgs e)
    {
        e.Handled = true;
        SetDropOverlayActive(false);
        if (IsEditorOpen) return;

        var sourceKind = DetectDropSource(e.Data, dragging);
        if (sourceKind == DropSourceKind.None || (e.AllowedEffects & DragDropEffects.Copy) == 0)
            return;

        DropExtractionResult extracted;
        try
        {
            if (sourceKind == DropSourceKind.FileDrop)
            {
                var paths = e.Data.GetData(DataFormats.FileDrop) as string[] ?? [];
                extracted = await Task.Run(() => ReadDroppedFiles(paths));
            }
            else
            {
                extracted = ExtractNonFileDrop(e.Data, sourceKind);
            }
        }
        catch (Exception ex)
        {
            log($"history drop error={ex.GetType().Name}");
            if (IsVisible) ShowNotice("追加できない項目がありました", isWarning: true);
            return;
        }

        var added = 0;
        var protocolSkipped = 0;
        if (extracted.Contents.Count > 0)
        {
            var current = coordinator;
            if (current is null)
            {
                if (IsVisible) ShowNotice("いまは履歴に追加できません", isWarning: true);
                return;
            }
            try
            {
                var result = await current.AddLocalContentsAsync(extracted.Contents);
                added = result.Added;
                protocolSkipped = result.Skipped;
            }
            catch (Exception ex)
            {
                log($"history drop add error={ex.GetType().Name}");
                if (IsVisible) ShowNotice("履歴に追加できませんでした", isWarning: true);
                return;
            }
        }

        var summary = new DropNoticeSummary(
            Added: added,
            TooLargeCount: extracted.TooLargeCount,
            TooManyFilesCount: extracted.TooManyFilesCount,
            DirectoryOrLinkCount: extracted.DirectoryOrLinkCount,
            InvalidOrEmptyCount: extracted.InvalidOrEmptyCount,
            UnavailableCount: extracted.UnavailableCount,
            ProtocolSkippedCount: protocolSkipped,
            TextTooLarge: extracted.TextTooLarge || (sourceKind == DropSourceKind.Text && protocolSkipped > 0));

        if (IsVisible && HistoryDrop.FormatDropNotice(summary) is { } notice)
            ShowNotice(notice.Message, notice.IsWarning);
    }

    private void SetDropOverlayActive(bool active)
    {
        dropOverlayActive = active;
        DropOverlay.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ShowNotice(string message, bool isWarning, bool showUndo = false, int durationMs = 3500)
    {
        if (!showUndo) ClearPendingUndo();
        NoticeBanner.SetResourceReference(Border.BackgroundProperty, isWarning ? "NoticeWarningBg" : "NoticeBg");
        NoticeBanner.SetResourceReference(Border.BorderBrushProperty, isWarning ? "NoticeWarningBorder" : "NoticeBorder");
        NoticeIcon.SetResourceReference(TextBlock.ForegroundProperty, isWarning ? "NoticeWarningFg" : "NoticeFg");
        NoticeText.SetResourceReference(TextBlock.ForegroundProperty, isWarning ? "NoticeWarningFg" : "NoticeFg");
        NoticeIcon.Text = isWarning ? "\uE7BA" : "\uE73E";
        NoticeText.Text = message;
        NoticeUndoButton.Visibility = showUndo ? Visibility.Visible : Visibility.Collapsed;
        NoticeBanner.Visibility = Visibility.Visible;

        if (noticeTimer is null)
        {
            noticeTimer = new DispatcherTimer();
            noticeTimer.Tick += (_, _) =>
            {
                ClearPendingUndo();
                HideNotice();
            };
        }
        noticeTimer.Stop();
        noticeTimer.Interval = TimeSpan.FromMilliseconds(durationMs);
        noticeTimer.Start();
    }

    private void ClearPendingUndo() => pendingUndoTemplate = null;

    private void HideNotice()
    {
        noticeTimer?.Stop();
        NoticeUndoButton.Visibility = Visibility.Collapsed;
        NoticeBanner.Visibility = Visibility.Collapsed;
        NoticeText.Text = "";
    }

    internal sealed record DropExtractionResult(
        IReadOnlyList<ClipboardContent> Contents,
        int TooLargeCount,
        int TooManyFilesCount,
        int DirectoryOrLinkCount,
        int InvalidOrEmptyCount,
        int UnavailableCount,
        bool TextTooLarge = false);

    internal static DropSourceKind DetectDropSource(IDataObject? data, bool isDraggingFromSelf)
    {
        if (data is null) return DropSourceKind.None;
        return HistoryDrop.SelectDropSource(
            isDraggingFromSelf: isDraggingFromSelf,
            hasSelfDragMarker: data.GetDataPresent(SelfDragFormat),
            hasFileDrop: data.GetDataPresent(DataFormats.FileDrop),
            hasImage: data.GetDataPresent("PNG") || data.GetDataPresent(DataFormats.Dib) || data.GetDataPresent(DataFormats.Bitmap),
            hasText: data.GetDataPresent(DataFormats.UnicodeText) || data.GetDataPresent(DataFormats.Text) || data.GetDataPresent(typeof(string)));
    }

    internal static DropExtractionResult ExtractNonFileDrop(IDataObject data, DropSourceKind kind)
    {
        if (kind == DropSourceKind.Text)
        {
            var text = data.GetData(DataFormats.UnicodeText) as string
                ?? data.GetData(DataFormats.Text) as string
                ?? data.GetData(typeof(string)) as string;
            var evaluation = HistoryDrop.EvaluateTextDrop(text);
            if (!evaluation.Accepted)
            {
                return evaluation.Reason == DropSkipReason.TooLarge
                    ? new([], 1, 0, 0, 0, 0, TextTooLarge: true)
                    : new([], 0, 0, 0, 1, 0);
            }
            return new([new ClipboardContent("text", Text: text)], 0, 0, 0, 0, 0);
        }

        if (kind == DropSourceKind.Image)
        {
            if (TryExtractImageDrop(data, out var pngBytes, out var failureReason) && pngBytes is not null)
                return new([new ClipboardContent("image", Data: pngBytes, Type: "public.png")], 0, 0, 0, 0, 0);

            return failureReason == DropSkipReason.TooLarge
                ? new([], 1, 0, 0, 0, 0)
                : new([], 0, 0, 0, 1, 0);
        }

        return new([], 0, 0, 0, 0, 0);
    }

    internal static DropExtractionResult ReadDroppedFiles(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0)
            return new([], 0, 0, 0, 0, 0);

        var entries = new List<DroppedFileEntry>(paths.Count);
        foreach (var rawPath in paths)
        {
            if (string.IsNullOrWhiteSpace(rawPath))
            {
                entries.Add(new("", "", Exists: false, IsDirectoryOrReparsePoint: false, Length: -1));
                continue;
            }
            try
            {
                var attrs = File.GetAttributes(rawPath);
                var isDirOrLink = (attrs & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0;
                var info = new FileInfo(rawPath);
                var length = isDirOrLink ? 0L : info.Length;
                entries.Add(new(info.FullName, info.Name, Exists: true, IsDirectoryOrReparsePoint: isDirOrLink, Length: length));
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or System.Security.SecurityException)
            {
                entries.Add(new(rawPath, "", Exists: false, IsDirectoryOrReparsePoint: false, Length: -1));
            }
        }

        var plan = HistoryDrop.PlanFileDrops(entries);
        var contents = new List<ClipboardContent>(plan.Accepted.Count);
        var tooLarge = plan.TooLargeCount;
        var unavailable = plan.UnavailableCount;

        foreach (var entry in plan.Accepted)
        {
            try
            {
                using var stream = new FileStream(entry.FullPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                if (stream.Length > HistoryDrop.MaxAttachmentBytes)
                {
                    tooLarge++;
                    continue;
                }
                var data = ReadStreamUpToLimit(stream, HistoryDrop.MaxAttachmentBytes, out var exceeded);
                if (exceeded)
                {
                    tooLarge++;
                    continue;
                }
                contents.Add(new("file", Filename: entry.FileName, Data: data));
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                unavailable++;
            }
        }

        return new DropExtractionResult(
            contents,
            tooLarge,
            plan.TooManyFilesCount,
            plan.DirectoryOrLinkCount,
            plan.InvalidOrEmptyCount,
            unavailable);
    }

    private static bool TryExtractImageDrop(IDataObject data, out byte[]? pngBytes, out DropSkipReason failureReason)
    {
        pngBytes = null;
        failureReason = DropSkipReason.InvalidFormatOrEmpty;

        if (data.GetDataPresent("PNG"))
        {
            var rawPng = ReadBytesFromDataObject(data, "PNG", HistoryDrop.MaxAttachmentBytes, out var exceeded);
            if (exceeded)
            {
                failureReason = DropSkipReason.TooLarge;
                return false;
            }
            if (rawPng is not null)
            {
                if (TryNormalizeImageBytesToPng(rawPng, out pngBytes, out failureReason))
                    return true;
                if (failureReason == DropSkipReason.TooLarge)
                    return false;
            }
        }

        if (data.GetDataPresent(DataFormats.Dib))
        {
            var maxDibBytes = HistoryDrop.MaxImagePixels * 4 + 4096;
            var dib = ReadBytesFromDataObject(data, DataFormats.Dib, maxDibBytes, out var exceeded);
            if (exceeded)
            {
                failureReason = DropSkipReason.TooLarge;
                return false;
            }
            if (dib is not null && TryConvertDibToBmpBytes(dib) is { } bmpBytes)
            {
                if (TryNormalizeImageBytesToPng(bmpBytes, out pngBytes, out failureReason))
                    return true;
                if (failureReason == DropSkipReason.TooLarge)
                    return false;
            }
        }

        if (data.GetDataPresent(DataFormats.Bitmap))
        {
            var bitmapObj = data.GetData(DataFormats.Bitmap);
            if (bitmapObj is BitmapSource bitmapSource)
            {
                if (TryEncodeBitmapSourceToPng(bitmapSource, out pngBytes, out failureReason))
                    return true;
                if (failureReason == DropSkipReason.TooLarge)
                    return false;
            }
            else if (bitmapObj is System.Drawing.Bitmap drawingBitmap)
            {
                if (!HistoryDrop.IsImageWithinPixelLimit(drawingBitmap.Width, drawingBitmap.Height))
                {
                    failureReason = DropSkipReason.TooLarge;
                    return false;
                }
                try
                {
                    using var encoded = new MemoryStream();
                    drawingBitmap.Save(encoded, System.Drawing.Imaging.ImageFormat.Png);
                    if (!HistoryDrop.IsImageWithinByteLimit(encoded.Length))
                    {
                        failureReason = DropSkipReason.TooLarge;
                        return false;
                    }
                    pngBytes = encoded.ToArray();
                    return true;
                }
                catch (Exception ex) when (ex is not OutOfMemoryException) { }
            }
        }

        return false;
    }

    private static byte[]? ReadBytesFromDataObject(IDataObject data, string format, long maxBytes, out bool exceeded)
    {
        exceeded = false;
        object? raw;
        try { raw = data.GetData(format); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { return null; }

        if (raw is byte[] bytes)
        {
            if (bytes.LongLength > maxBytes)
            {
                exceeded = true;
                return null;
            }
            return bytes;
        }
        if (raw is Stream stream)
        {
            if (stream.CanSeek) stream.Position = 0;
            var result = ReadStreamUpToLimit(stream, maxBytes, out exceeded);
            return exceeded ? null : result;
        }
        return null;
    }

    private static byte[] ReadStreamUpToLimit(Stream stream, long maxBytes, out bool exceeded)
    {
        exceeded = false;
        if (stream.CanSeek && stream.Length - stream.Position > maxBytes)
        {
            exceeded = true;
            return [];
        }
        using var output = new MemoryStream();
        var buffer = new byte[64 * 1024];
        while (true)
        {
            var remaining = maxBytes - output.Length + 1;
            var toRead = (int)Math.Min(buffer.Length, remaining);
            var read = stream.Read(buffer, 0, toRead);
            if (read <= 0) break;
            if (output.Length + read > maxBytes)
            {
                exceeded = true;
                return [];
            }
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }

    private static byte[]? TryConvertDibToBmpBytes(byte[] dib)
    {
        if (dib.Length < 40) return null;
        var header = BitConverter.ToInt32(dib, 0);
        if (header < 40 || header > dib.Length) return null;
        var bits = BitConverter.ToUInt16(dib, 14);
        var compression = BitConverter.ToInt32(dib, 16);
        var colors = BitConverter.ToUInt32(dib, 32);
        if (colors == 0 && bits <= 8) colors = 1u << bits;
        var paletteBytes = (long)colors * 4 + (header == 40 && compression == 3 ? 12 : 0);
        if (paletteBytes < 0 || paletteBytes > dib.Length - header) return null;
        var offsetLong = 14L + header + paletteBytes;
        if (offsetLong > int.MaxValue || offsetLong > 14L + dib.Length) return null;

        var input = new byte[14 + dib.Length];
        input[0] = (byte)'B';
        input[1] = (byte)'M';
        BitConverter.GetBytes(input.Length).CopyTo(input, 2);
        BitConverter.GetBytes((int)offsetLong).CopyTo(input, 10);
        dib.CopyTo(input, 14);
        return input;
    }

    private static bool TryNormalizeImageBytesToPng(byte[] imageBytes, out byte[]? pngBytes, out DropSkipReason failureReason)
    {
        pngBytes = null;
        failureReason = DropSkipReason.InvalidFormatOrEmpty;
        try
        {
            using var stream = new MemoryStream(imageBytes);
            var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnDemand);
            if (decoder.Frames.Count == 0)
                return false;
            var frame = decoder.Frames[0];
            if (!HistoryDrop.IsImageWithinPixelLimit(frame.PixelWidth, frame.PixelHeight))
            {
                failureReason = DropSkipReason.TooLarge;
                return false;
            }
            return TryEncodeBitmapSourceToPng(frame, out pngBytes, out failureReason);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return false;
        }
    }

    private static bool TryEncodeBitmapSourceToPng(BitmapSource source, out byte[]? pngBytes, out DropSkipReason failureReason)
    {
        pngBytes = null;
        failureReason = DropSkipReason.InvalidFormatOrEmpty;
        try
        {
            if (!HistoryDrop.IsImageWithinPixelLimit(source.PixelWidth, source.PixelHeight))
            {
                failureReason = DropSkipReason.TooLarge;
                return false;
            }
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(source is BitmapFrame frame ? frame : BitmapFrame.Create(source));
            using var result = new MemoryStream();
            encoder.Save(result);
            if (!HistoryDrop.IsImageWithinByteLimit(result.Length))
            {
                failureReason = DropSkipReason.TooLarge;
                return false;
            }
            pngBytes = result.ToArray();
            return true;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return false;
        }
    }

    private void OnSettings(object sender, RoutedEventArgs e)
    {
        Hide();
        openSettings();
    }

    private void OnActivated(object? sender, EventArgs e)
    {
        if (editorMode == EditorMode.RenameTag)
            RenameTagBox.Focus();
        else if (IsEditorOpen)
            TemplateBodyBox.Focus();
        else
            SearchBox.Focus();
    }

    private void OnDeactivated(object? sender, EventArgs e)
    {
        if (!IsVisible) return;
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () =>
        {
            if (IsVisible)
                pasteTarget.RecordForeground(ForegroundContext.CurrentForegroundWindow());
        });
    }

    private void OnWindowVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (IsVisible) return;
        reloadVersion++;
        SaveCurrentPlacement();
        StopForegroundTracking();
        pasteTarget.Reset();
        ResetDragState();
        SetDropOverlayActive(false);
        CloseEditor();
        ClearPendingUndo();
        HideNotice();
        // Hidden rows keep decoded thumbnails alive, so they go with the window.
        rows.Clear();
        templateRows.Clear();
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
        StopForegroundTracking();
    }

    private void OnWindowClosed(object? sender, EventArgs e)
    {
        noticeTimer?.Stop();
        StopForegroundTracking();
        if (hwndSource is not null)
        {
            hwndSource.RemoveHook(WindowProc);
            hwndSource = null;
        }
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        hwndSource = HwndSource.FromHwnd(hwnd);
        hwndSource?.AddHook(WindowProc);
        RoundCorners(hwnd);
        DisableMaximizeAndMinimizeButtons(hwnd);
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
        }
        return 0;
    }

    private void StartForegroundTracking()
    {
        if (foregroundHook != 0) return;
        foregroundHookProc ??= OnForegroundWinEvent;
        foregroundHook = SetWinEventHook(
            EventSystemForeground,
            EventSystemForeground,
            0,
            foregroundHookProc,
            0,
            0,
            WinEventOutOfContext | WinEventSkipOwnProcess);
        if (foregroundHook == 0)
            log("foreground hook install failed");
    }

    private void StopForegroundTracking()
    {
        if (foregroundHook == 0) return;
        UnhookWinEvent(foregroundHook);
        foregroundHook = 0;
    }

    private void OnForegroundWinEvent(
        nint hWinEventHook,
        uint eventType,
        nint hwnd,
        int idObject,
        int idChild,
        uint idEventThread,
        uint dwmsEventTime)
    {
        if (!IsVisible || eventType != EventSystemForeground || idObject != 0 || idChild != 0)
            return;
        pasteTarget.RecordForeground(hwnd);
    }

    private WindowPixelRect ComputeTargetRect(nint hwnd, HistoryInvocation value)
    {
        var screens = GetScreens(hwnd);
        if (loadPlacement?.Invoke() is { } saved &&
            HistoryWindowPlacement.TryNormalize(saved.Left, saved.Top, saved.Width, saved.Height, saved.Scale, out var validSaved))
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
        if (hwnd == 0 || IsIconic(hwnd) || !GetWindowRect(hwnd, out var rect)) return null;
        var scale = GetWindowScale(hwnd);
        var widthDip = (rect.right - rect.left) / scale;
        var heightDip = (rect.bottom - rect.top) / scale;
        return HistoryWindowPlacement.Normalize(rect.left, rect.top, widthDip, heightDip, scale);
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
        Set("TabTrack", "#E7EBF2", "#20232B");
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
        Set("ErrorFg", "#DC2626", "#FCA5A5");
        Set("OverlayScrim", "#660F172A", "#88000000");
        Set("ScrollThumb", "#CBD5E1", "#474C59");
        Set("LinkTint", "#2663EB", "#73A3FF");
        Set("ImageTint", "#7C3AED", "#A78BFA");
        Set("ImageBadgeBg", "#1A7C3AED", "#26A78BFA");
        Set("FileTint", "#0D9488", "#2DD4BF");
        Set("FileBadgeBg", "#1A0D9488", "#262DD4BF");
        Set("EmailPhoneTint", "#16A34A", "#4ADE80");
        Set("ColorTint", "#DB2777", "#F472B6");
        Set("DropOverlayBg", "#1A2663EB", "#2473A3FF");
        Set("NoticeBg", "#EFF6FF", "#1E293B");
        Set("NoticeBorder", "#BFDBFE", "#3B82F6");
        Set("NoticeFg", "#1D4ED8", "#93C5FD");
        Set("NoticeWarningBg", "#FEF3C7", "#3B2811");
        Set("NoticeWarningBorder", "#F59E0B", "#D97706");
        Set("NoticeWarningFg", "#92400E", "#FCD34D");
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
            SetWindowStyle(hwnd, updated);
        SetWindowPos(hwnd, 0, 0, 0, 0, 0, SwpNoMove | SwpNoSize | SwpNoZOrder | SwpNoActivate | SwpFrameChanged);
    }

    private static nint GetWindowStyle(nint hwnd) =>
        Environment.Is64BitProcess ? GetWindowLongPtr64(hwnd, GwlStyle) : GetWindowLong32(hwnd, GwlStyle);

    private static nint SetWindowStyle(nint hwnd, nint value) =>
        Environment.Is64BitProcess ? SetWindowLongPtr64(hwnd, GwlStyle, value) : SetWindowLong32(hwnd, GwlStyle, value);

    private const int VirtualKeyControl = 0x11;
    private const int DwmWindowCornerPreference = 33;
    private const int DwmRound = 2;
    private const int GwlStyle = -16;
    private const uint WsMaximizeBox = 0x00010000;
    private const uint WsMinimizeBox = 0x00020000;
    private const int WmNcCalcSize = 0x0083;
    private const int WmNcHitTest = 0x0084;
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoZOrder = 0x0004;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpFrameChanged = 0x0020;
    private static readonly nint HwndTopMost = -1;
    private const uint MonitorDefaultToNearest = 2;
    private const int MdtEffectiveDpi = 0;
    private const int DpiAwarenessPerMonitorAware = 2;
    private const uint EventSystemForeground = 0x0003;
    private const uint WinEventOutOfContext = 0x0000;
    private const uint WinEventSkipOwnProcess = 0x0002;

    private delegate void WinEventDelegate(
        nint hWinEventHook,
        uint eventType,
        nint hwnd,
        int idObject,
        int idChild,
        uint idEventThread,
        uint dwmsEventTime);

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
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(nint hwnd, out RECT rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsIconic(nint hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowPos(nint hwnd, nint hwndInsertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern nint SetWinEventHook(uint eventMin, uint eventMax, nint hmodWinEventProc, WinEventDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnhookWinEvent(nint hWinEventHook);
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
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateHardLink(string lpFileName, string lpExistingFileName, nint lpSecurityAttributes);
}
