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
    private int connected;
    private bool requiresPeerUpdate;
    private readonly bool preview;
    public event Action? RepairRequested;

    public MainWindow(SyncPairing pairing, Action<string> log, bool preview = false)
    {
        this.log = log; this.preview = preview;
        InitializeComponent();
        UpdatePairing(pairing);
        if (preview)
        {
            Title = "clipboard+ for Windows — プレビュー";
            RepairButton.IsEnabled = LogsButton.IsEnabled = StartupCheck.IsEnabled = false;
            UpdateBluetooth("プレビュー表示");
        }
        else StartupCheck.IsChecked = LocalStore.StartupEnabled;
    }

    public void UpdatePairing(SyncPairing pairing)
    {
        using var data = QRCodeGenerator.GenerateQrCode(pairing.ToQrString(), QRCodeGenerator.ECCLevel.Q);
        using var code = new PngByteQRCode(data);
        using var stream = new MemoryStream(code.GetGraphic(8));
        var bitmap = new BitmapImage();
        bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad; bitmap.StreamSource = stream; bitmap.EndInit(); bitmap.Freeze();
        QrImage.Source = bitmap;
        connected = 0; requiresPeerUpdate = false; UpdateStatus();
        PairingTitle.Text = "iPhone・iPadと組にする";
        SentText.Text = ReceivedText.Text = "まだありません";
        PendingText.Text = "確認待ち 0 件";
    }

    public void UpdateBluetooth(string state) { bluetoothState = state; UpdateStatus(); }
    public void UpdateSync(SyncStatus state)
    {
        connected = state.Connected;
        SentText.Text = state.LastSent?.ToLocalTime().ToString("MM/dd HH:mm:ss") ?? "まだありません";
        ReceivedText.Text = state.LastReceived?.ToLocalTime().ToString("MM/dd HH:mm:ss") ?? "まだありません";
        PendingText.Text = $"確認待ち {state.Pending} 件";
        requiresPeerUpdate = state.RequiresPeerUpdate;
        if (connected > 0) PairingTitle.Text = "組にするコード";
        UpdateStatus();
    }
    private void UpdateStatus()
    {
        var baseStatus = connected > 0 ? "iPhone・iPadとつながっています" : bluetoothState;
        StatusText.Text = requiresPeerUpdate ? $"{baseStatus}\n相手のアプリを更新してください" : baseStatus;
    }
    public void SetBusy(bool busy) => RepairButton.IsEnabled = !busy;
    private void OnClosing(object? sender, CancelEventArgs e) { if (!preview) { e.Cancel = true; Hide(); } }
    private void OnRepair(object sender, RoutedEventArgs e) => RepairRequested?.Invoke();
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
}
