using System.Diagnostics;
using System.Threading;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using ClipboardPlus.Windows.Infrastructure;
using Forms = System.Windows.Forms;

namespace ClipboardPlus.Windows;

public partial class App : System.Windows.Application
{
    private Mutex? mutex;
    private EventWaitHandle? activation;
    private RegisteredWaitHandle? activationWait;
    private Forms.NotifyIcon? tray;
    private ClipboardMonitor? clipboard;
    private BleServer? server;
    private SyncCoordinator? coordinator;
    private AppLog? log;
    private MainWindow? window;
    private KeyboardHook? keyboardHook;
    private IHistoryPresenter? historyPresenter;
    private HistoryWindow? historyWindow;
    private bool exiting;
    private bool repairing;
    private Task? repairTask;
    private Task pendingSettingsSave = Task.CompletedTask;
    private const string InstanceName = @"Local\clipboardplus.windows.instance.v1";

    internal AppSettings Settings { get; private set; } = null!;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Contains("--preview"))
        {
            // A UI-only mode: no store, registry access, IPC, clipboard listener,
            // tray icon or Bluetooth. Pairing lives only in this process's memory.
            ShutdownMode = ShutdownMode.OnMainWindowClose;
            Settings = new AppSettings(load: false);
            var previewWindow = new MainWindow(SyncPairing.Create("プレビュー"), _ => { }, preview: true);
            previewWindow.ConfigureHotkey(Settings, _ => Task.FromResult<HotkeyChord?>(null), () => { });
            MainWindow = previewWindow;
            MainWindow.Show();
            return;
        }
        mutex = new Mutex(true, InstanceName, out var first);
        if (!first)
        {
            // The first process may still be constructing its event.
            for (var i = 0; i < 20; i++)
            {
                if (EventWaitHandle.TryOpenExisting(InstanceName + ".open", out var existing))
                {
                    var hwnd = FindWindow(null, "clipboard+ for Windows");
                    if (hwnd != IntPtr.Zero)
                    {
                        GetWindowThreadProcessId(hwnd, out var processId);
                        AllowSetForegroundWindow(processId);
                    }
                    using (existing) existing.Set(); break;
                }
                Thread.Sleep(50);
            }
            Shutdown(); return;
        }
        try
        {
            log = new AppLog(); log.Write("application starting");
            Settings = new AppSettings(log: log.Write);
            HistoryWindow.ClearDragStaging(HistoryWindow.DragStagingRoot);
            var pairing = LocalStore.LoadOrCreate();
            window = new MainWindow(pairing, log.Write);
            MainWindow = window;
            _ = new WindowInteropHelper(window).EnsureHandle();
            window.RepairRequested += RepairAsync;
            activation = new EventWaitHandle(false, EventResetMode.AutoReset, InstanceName + ".open");
            activationWait = ThreadPool.RegisterWaitForSingleObject(activation, (_, _) => Dispatcher.BeginInvoke(OpenWindow), null, Timeout.Infinite, false);
            clipboard = new ClipboardMonitor(Dispatcher, log.Write);
            clipboard.Changed += ClipboardChanged;
            historyWindow = new HistoryWindow(
                log.Write,
                () => Settings.PasteOnSelect,
                ForegroundContext.PasteAsync,
                OpenWindow,
                () => Settings.HistoryWindow,
                SaveHistoryPlacement);
            historyPresenter = historyWindow;
            StartSync(pairing);
            keyboardHook = new KeyboardHook(OpenHistory, action => Dispatcher.BeginInvoke(action), log.Write);
            ApplyHotkeySettings();
            window.ConfigureHotkey(Settings, RecordHotkeyAsync, ApplyHotkeySettings);
            window.HistoryRequested += OpenHistoryWithoutPaste;
            tray = new Forms.NotifyIcon
            {
                Text = "clipboard+ for Windows",
                Icon = System.Drawing.SystemIcons.Application,
                Visible = true,
                ContextMenuStrip = new Forms.ContextMenuStrip()
            };
            tray.ContextMenuStrip.Items.Add("履歴を開く", null, (_, _) => OpenHistoryWithoutPaste());
            tray.ContextMenuStrip.Items.Add("開く", null, (_, _) => OpenWindow());
            tray.ContextMenuStrip.Items.Add("終了", null, async (_, _) => await ExitAsync());
            tray.DoubleClick += (_, _) => OpenWindow();
            if (!e.Args.Contains("--background")) OpenWindow();
        }
        catch (Exception ex)
        {
            log?.Write($"startup failed error={ex.GetType().Name}");
            System.Windows.MessageBox.Show("起動できませんでした。保存先へのアクセスとBluetoothの設定を確認してください。\n組にする情報の読み込みに失敗した場合は、ログとpairing.datを退避してから起動し直してください。", "clipboard+", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }

    private void StartSync(SyncPairing pairing)
    {
        coordinator = new(pairing, clipboard!, log!.Write, new SyncRepository(LocalStore.Root, pairing.PcId));
        var current = coordinator;
        historyWindow?.Attach(current);
        coordinator.Changed += state => Dispatcher.BeginInvoke(() => { if (coordinator == current) window!.UpdateSync(state); });
        // Devices paired in an earlier run show before anything changes.
        _ = current.GetStatusAsync().ContinueWith(task =>
        {
            if (task.IsCompletedSuccessfully)
                Dispatcher.BeginInvoke(() => { if (coordinator == current) window!.UpdateSync(task.Result); });
        }, TaskScheduler.Default);
        server = new(coordinator, log.Write, Dispatcher);
        var currentServer = server;
        server.StatusChanged += state => Dispatcher.BeginInvoke(() => { if (server == currentServer) window!.UpdateBluetooth(state); });
        server.Start();
    }

    private async void ClipboardChanged(ClipboardSnapshot snapshot)
    {
        if (coordinator is not null && !exiting)
            try { await coordinator.ClipboardChangedAsync(snapshot); }
            catch (Exception e) { log!.Write($"clipboard event error={e.GetType().Name}"); }
    }

    private async void RepairAsync()
    {
        if (window is null || exiting || repairing || repairTask is not null) return;
        repairing = true;
        try
        {
            if (System.Windows.MessageBox.Show(window, "組にする鍵を作り直します。いま組んでいるiPhone・iPadはつながらなくなります。\n新しいQRコードを読み直してください。", "組み直す", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK)
                return;
            if (exiting) return;
            repairTask = ExecuteRepairAsync();
            await repairTask;
        }
        finally
        {
            repairing = false;
            repairTask = null;
        }
    }

    private async Task ExecuteRepairAsync()
    {
        window!.SetBusy(true);
        try
        {
            // Persist successfully before retiring the old pairing.
            var pairing = LocalStore.CreatePairing();
            var oldCoordinator = coordinator;
            var oldServer = server;
            coordinator = null;
            server = null;
            // A stopped coordinator copies nothing, so choosing an item would paste stale content.
            historyWindow?.Attach(null);
            historyWindow?.Hide();
            HistoryWindow.ClearDragStaging(HistoryWindow.DragStagingRoot);
            try
            {
                if (oldServer is not null) await oldServer.DisposeAsync();
            }
            finally
            {
                if (oldCoordinator is not null) await oldCoordinator.DisposeAsync();
            }
            if (exiting) return;
            window.UpdatePairing(pairing);
            StartSync(pairing);
            log!.Write("pairing replaced");
        }
        catch (Exception e)
        {
            log!.Write($"repair failed error={e.GetType().Name}");
            if (!exiting)
                System.Windows.MessageBox.Show(window!, "組み直せませんでした。ログを確認して、アプリを起動し直してください。", "clipboard+");
        }
        finally { window.SetBusy(false); }
    }

    private void OpenWindow()
    {
        if (window is null || exiting) return;
        window.Show(); window.WindowState = WindowState.Normal;
        window.Activate();
        window.Topmost = true; window.Topmost = false;
    }

    private void OpenHistory() => OpenHistory(pasteTarget: true);

    /// <summary>From the tray or the main window, the window in front is not where the user is typing.</summary>
    private void OpenHistoryWithoutPaste() => OpenHistory(pasteTarget: false);

    private void OpenHistory(bool pasteTarget)
    {
        if (exiting) return;
        var invocation = ForegroundContext.Capture();
        if (!pasteTarget) invocation = invocation with { PreviousWindow = 0 };
        if (historyPresenter is null)
        {
            log?.Write("history presenter not ready");
            return;
        }
        historyPresenter.Present(invocation);
    }

    private void SaveHistoryPlacement(WindowPlacement placement)
    {
        if (Settings is null || !Settings.TrySetHistoryWindow(placement))
            return;
        var previous = pendingSettingsSave;
        pendingSettingsSave = SaveSettingsAfterAsync(previous);
    }

    private async Task SaveSettingsAfterAsync(Task previous)
    {
        try { await previous; } catch { }
        await Task.Run(() =>
        {
            try { Settings?.Save(); }
            catch (Exception ex) { log?.Write($"settings save error={ex.GetType().Name}"); }
        });
    }

    internal void ApplyHotkeySettings()
    {
        if (exiting || keyboardHook is null) return;
        var chord = Settings.ParsedHotkey;
        if (HotkeyRules.Problem(chord) is not null)
        {
            log?.Write("hotkey from settings refused; using the default");
            chord = HotkeyChord.Default;
        }
        if (Settings.HotkeyEnabled)
            keyboardHook.Enable(chord);
        else
            keyboardHook.Disable();
    }

    internal Task<HotkeyChord?> RecordHotkeyAsync(CancellationToken cancellationToken = default)
    {
        if (exiting || keyboardHook is null) return Task.FromResult<HotkeyChord?>(null);
        return keyboardHook.RecordAsync(cancellationToken);
    }

    private async Task ExitAsync()
    {
        if (exiting) return;
        exiting = true;
        tray!.Visible = false;
        keyboardHook?.Dispose();
        clipboard?.Dispose();
        if (repairTask is { } running) await running;
        var currentServer = server;
        var currentCoordinator = coordinator;
        server = null;
        coordinator = null;
        if (historyWindow is not null)
        {
            historyWindow.Attach(null);
            historyWindow.AllowClose = true;
            historyWindow.Close();
        }
        HistoryWindow.ClearDragStaging(HistoryWindow.DragStagingRoot);
        await pendingSettingsSave;
        if (window is not null)
            await window.StopWifiProbeAsync();
        try
        {
            if (currentServer is not null) await currentServer.DisposeAsync();
        }
        finally
        {
            if (currentCoordinator is not null) await currentCoordinator.DisposeAsync();
        }
        log?.Write("application stopped");
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        window?.StopWifiProbeSync();
        keyboardHook?.Dispose();
        tray?.Dispose();
        activationWait?.Unregister(null); activation?.Dispose();
        mutex?.Dispose();
        base.OnExit(e);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string? className, string title);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] private static extern bool AllowSetForegroundWindow(uint processId);
}
