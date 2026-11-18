using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Media.Imaging;
using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using ClipboardPlus.Windows.Infrastructure;
using QRCoder;

namespace ClipboardPlus.Windows;

public partial class MainWindow : Window
{
    private readonly Action<string> log;
    private string bluetoothState = "Bluetoothを確認しています";
    private string? connectedText;
    private bool requiresPeerUpdate;
    private readonly bool preview;
    private AppSettings? settings;
    private Func<CancellationToken, Task<HotkeyChord?>>? recordHotkey;
    private Action? applyHotkey;
    private CancellationTokenSource? recording;
    private readonly WifiTransferProbe? wifiProbe;
    private string? renderedProbeQrText;
    public event Action? RepairRequested;
    public event Action? HistoryRequested;

    public MainWindow(SyncPairing pairing, Action<string> log, bool preview = false)
    {
        this.log = log; this.preview = preview;
        InitializeComponent();
        // Recording swallows keys across the PC, so it never outlives this window being in front.
        Deactivated += (_, _) => StopRecording();
        UpdatePairing(pairing);
        if (preview)
        {
            Title = "clipboard+ for Windows — プレビュー";
            RepairButton.IsEnabled = LogsButton.IsEnabled = StartupCheck.IsEnabled = false;
            WifiProbeModeDirect.IsEnabled = WifiProbeModeHotspot.IsEnabled = WifiProbeStartButton.IsEnabled = false;
            UpdateBluetooth("プレビュー表示");
        }
        else
        {
            StartupCheck.IsChecked = LocalStore.StartupEnabled;
            wifiProbe = new WifiTransferProbe(log, Dispatcher);
            wifiProbe.SnapshotChanged += UpdateWifiProbe;
            UpdateWifiProbe(wifiProbe.CurrentSnapshot);
        }
    }

    public void UpdatePairing(SyncPairing pairing)
    {
        QrImage.Source = RenderQrBitmap(pairing.ToQrString());
        // A new pairing forgets the devices, so the window starts over too.
        UpdateSync(new SyncStatus(0, 0, null, null, Devices: []));
    }

    private static BitmapImage RenderQrBitmap(string content)
    {
        using var data = QRCodeGenerator.GenerateQrCode(content, QRCodeGenerator.ECCLevel.Q);
        using var code = new PngByteQRCode(data);
        using var stream = new MemoryStream(code.GetGraphic(8));
        var bitmap = new BitmapImage();
        bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad; bitmap.StreamSource = stream; bitmap.EndInit(); bitmap.Freeze();
        return bitmap;
    }

    public void UpdateBluetooth(string state) { bluetoothState = state; UpdateStatus(); }
    public void UpdateSync(SyncStatus state)
    {
        connectedText = SyncStatusText.Connected(state);
        SentText.Text = state.LastSent?.ToLocalTime().ToString("MM/dd HH:mm:ss") ?? "まだありません";
        ReceivedText.Text = state.LastReceived?.ToLocalTime().ToString("MM/dd HH:mm:ss") ?? "まだありません";
        DevicesText.Text = string.Join("\n", SyncStatusText.Devices(state));
        var transfers = SyncStatusText.Transfers(state);
        TransferText.Text = string.Join("\n", transfers);
        TransferText.Visibility = transfers.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        PairingTitle.Text = SyncStatusText.PairingTitle(state);
        requiresPeerUpdate = state.RequiresPeerUpdate;
        UpdateStatus();
    }
    private void UpdateStatus()
    {
        var baseStatus = connectedText ?? bluetoothState;
        StatusText.Text = requiresPeerUpdate ? $"{baseStatus}\n相手のアプリを更新してください" : baseStatus;
    }
    public void SetBusy(bool busy) => RepairButton.IsEnabled = !busy;

    /// <summary>Connects the history window settings. Recording swallows the next chord pressed anywhere.</summary>
    internal void ConfigureHotkey(AppSettings value, Func<CancellationToken, Task<HotkeyChord?>> record, Action apply)
    {
        settings = value; recordHotkey = record; applyHotkey = apply;
        if (preview) HotkeyCheck.IsEnabled = RecordButton.IsEnabled = PasteCheck.IsEnabled = HistoryButton.IsEnabled = false;
        ShowHotkey();
    }

    private void ShowHotkey()
    {
        if (settings is null) return;
        HotkeyCheck.IsChecked = settings.HotkeyEnabled;
        HotkeyText.Text = settings.ParsedHotkey.DisplayName;
        PasteCheck.IsChecked = settings.PasteOnSelect;
        ResetHotkeyButton.IsEnabled = !preview && settings.ParsedHotkey != HotkeyChord.Default;
    }

    private void ShowHotkeyMessage(string? text)
    {
        HotkeyMessage.Text = text ?? "";
        HotkeyMessage.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void SaveHotkey(Action<AppSettings> change)
    {
        if (settings is null) return;
        change(settings);
        try { settings.Save(); ShowHotkeyMessage(null); }
        catch (Exception ex)
        {
            log($"settings save error={ex.GetType().Name}");
            ShowHotkeyMessage("設定を保存できませんでした。今回だけ、この設定で動きます。");
        }
        applyHotkey?.Invoke();
        ShowHotkey();
    }

    private void StopRecording() => recording?.Cancel();

    private void OnHotkeyEnabledChanged(object sender, RoutedEventArgs e) { StopRecording(); SaveHotkey(s => s.HotkeyEnabled = HotkeyCheck.IsChecked == true); }
    private void OnPasteChanged(object sender, RoutedEventArgs e) { StopRecording(); SaveHotkey(s => s.PasteOnSelect = PasteCheck.IsChecked == true); }
    private void OnResetHotkey(object sender, RoutedEventArgs e)
    {
        StopRecording();
        ShowHotkeyMessage(null);
        SaveHotkey(s => s.Hotkey = HotkeyChord.Default.ToString());
    }

    private async void OnRecordHotkey(object sender, RoutedEventArgs e)
    {
        if (recordHotkey is null) return;
        if (recording is not null) { recording.Cancel(); return; } // The button reads "やめる" while recording.
        recording = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        RecordButton.Content = "やめる";
        HotkeyText.Text = "新しい組み合わせを押してください（Escでやめる）";
        ShowHotkeyMessage(null);
        try
        {
            if (await recordHotkey(recording.Token) is HotkeyChord chord)
            {
                if (HotkeyRules.Problem(chord) is { } problem) ShowHotkeyMessage(problem);
                else SaveHotkey(s => s.Hotkey = chord.ToString());
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { log($"hotkey record error={ex.GetType().Name}"); }
        finally
        {
            recording.Dispose(); recording = null;
            RecordButton.Content = "キーを変える";
            ShowHotkey();
        }
    }

    private void OnOpenHistory(object sender, RoutedEventArgs e) { StopRecording(); HistoryRequested?.Invoke(); }
    private void OnClosing(object? sender, CancelEventArgs e) { StopRecording(); if (!preview) { e.Cancel = true; Hide(); } }
    private void OnRepair(object sender, RoutedEventArgs e) { StopRecording(); RepairRequested?.Invoke(); }
    private void OnOpenLogs(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo(LocalStore.Logs) { UseShellExecute = true }); }
        catch (Exception ex) { log($"open logs error={ex.GetType().Name}"); }
    }
    private void OnStartupChanged(object sender, RoutedEventArgs e)
    {
        try { LocalStore.StartupEnabled = StartupCheck.IsChecked == true; }
        catch (Exception ex)
        {
            log($"startup setting error={ex.GetType().Name}");
            StartupCheck.IsChecked = LocalStore.StartupEnabled;
            System.Windows.MessageBox.Show(this, "起動時の設定を保存できませんでした。", "clipboard+");
        }
    }

    internal async Task StopWifiProbeAsync()
    {
        if (wifiProbe is not null)
            await wifiProbe.DisposeAsync();
    }

    internal void StopWifiProbeSync() => wifiProbe?.StopSync();

    private async void OnStartWifiProbe(object sender, RoutedEventArgs e)
    {
        if (wifiProbe is null || preview) return;
        var mode = WifiProbeModeHotspot.IsChecked == true
            ? WifiProbeMode.MobileHotspot
            : WifiProbeMode.WifiDirectLegacy;
        WifiProbeStartButton.IsEnabled = false;
        WifiProbeModeDirect.IsEnabled = WifiProbeModeHotspot.IsEnabled = false;
        WifiProbeStopButton.IsEnabled = true;
        await wifiProbe.StartAsync(mode);
    }

    private async void OnStopWifiProbe(object sender, RoutedEventArgs e)
    {
        if (wifiProbe is null) return;
        WifiProbeStopButton.IsEnabled = false;
        await wifiProbe.StopAsync();
    }

    private void UpdateWifiProbe(WifiProbeSnapshot state)
    {
        WifiProbeStartButton.IsEnabled = !preview && !state.IsRunning;
        WifiProbeModeDirect.IsEnabled = !preview && !state.IsRunning;
        WifiProbeModeHotspot.IsEnabled = !preview && !state.IsRunning;
        WifiProbeStopButton.IsEnabled = !preview && state.IsRunning;
        WifiProbeStatusText.Text = state.StatusMessage;

        if (string.IsNullOrEmpty(state.ErrorMessage))
        {
            WifiProbeErrorText.Text = "";
            WifiProbeErrorText.Visibility = Visibility.Collapsed;
        }
        else
        {
            WifiProbeErrorText.Text = state.ErrorMessage;
            WifiProbeErrorText.Visibility = Visibility.Visible;
        }

        if (state.QrPayload is { } qr)
        {
            var text = qr.ToQrString();
            if (renderedProbeQrText != text)
            {
                WifiProbeQrImage.Source = RenderQrBitmap(text);
                renderedProbeQrText = text;
            }
            WifiProbeQrPanel.Visibility = Visibility.Visible;
        }
        else
        {
            renderedProbeQrText = null;
            WifiProbeQrImage.Source = null;
            WifiProbeQrPanel.Visibility = Visibility.Collapsed;
        }

        WifiProbeTimelineText.Text = WifiProbeText.FormatTimeline(state);
    }
}
