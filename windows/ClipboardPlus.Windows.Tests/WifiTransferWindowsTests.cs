using System.IO;
using System.Text;
using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using ClipboardPlus.Windows.Infrastructure;
using Xunit;

namespace ClipboardPlus.Windows.Tests;

public sealed class WifiTransferWindowsTests : IDisposable
{
    private readonly string tempDir = Path.Combine(Path.GetTempPath(), "clipboardplus-wifi-win-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { if (Directory.Exists(tempDir)) Directory.Delete(tempDir, recursive: true); }
        catch { }
    }

    [Fact]
    public void HotspotConfigBackupStoreProtectsPassphraseWithDpapiAndRoundTrips()
    {
        var store = new HotspotConfigBackupStore(tempDir);
        Assert.False(store.Exists);
        Assert.Null(store.Load());

        var record = new HotspotBackupRecord(
            Ssid: "MyWindowsHotspot",
            Passphrase: "SuperSecretHotspotPassword123",
            Band: 2,
            TempSsid: "DIRECT-cp-12345678");
        store.Save(record);

        Assert.True(store.Exists);
        var files = Directory.GetFiles(tempDir);
        var backupFile = Assert.Single(files);
        var rawText = Encoding.UTF8.GetString(File.ReadAllBytes(backupFile));
        Assert.DoesNotContain("SuperSecretHotspotPassword123", rawText, StringComparison.Ordinal);
        Assert.DoesNotContain("MyWindowsHotspot", rawText, StringComparison.Ordinal);

        var loaded = store.Load();
        Assert.Equal(record, loaded);

        store.Clear();
        Assert.False(store.Exists);
        Assert.Null(store.Load());
    }

    [Fact]
    public void HotspotConfigBackupStoreClearsCorruptFileWithoutLoggingSecretsOrPath()
    {
        Directory.CreateDirectory(tempDir);
        var file = Path.Combine(tempDir, "hotspot-restore.dat");
        File.WriteAllBytes(file, [0x01, 0x02, 0x03, 0x04]);

        var logs = new List<string>();
        var store = new HotspotConfigBackupStore(tempDir);
        Assert.Null(store.Load(logs.Add));
        Assert.False(store.Exists);
        Assert.NotEmpty(logs);
        Assert.All(logs, line => Assert.DoesNotContain(tempDir, line, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void HardwareLeasePreventsSimultaneousProductionAndProbeUse()
    {
        Assert.True(WindowsWifiHardwareLease.TryAcquire("test-a"));
        try
        {
            Assert.False(WindowsWifiHardwareLease.TryAcquire("test-b"));
            WindowsWifiHardwareLease.Release("test-b");
            Assert.Equal("test-a", WindowsWifiHardwareLease.CurrentOwner);
        }
        finally
        {
            WindowsWifiHardwareLease.Release("test-a");
        }
        Assert.Null(WindowsWifiHardwareLease.CurrentOwner);
    }

    [Fact]
    public void WifiTransferHostStepTimeoutsFitWithin15SecondTotalBudget()
    {
        Assert.Equal(TimeSpan.FromSeconds(15), WifiApStarter.DefaultTotalStartTimeout);
        Assert.True(WindowsWifiTransferHost.HotspotBandQueryTimeout > TimeSpan.Zero);
        Assert.True(WindowsWifiTransferHost.HotspotConfigureTimeout > TimeSpan.Zero);
        Assert.True(WindowsWifiTransferHost.HotspotStartTimeout > TimeSpan.Zero);
        Assert.True(WindowsWifiTransferHost.HotspotCleanupOnStartFailureTimeout > TimeSpan.Zero);
        Assert.True(WindowsWifiTransferHost.VirtualIpBindTimeout > TimeSpan.Zero);
        Assert.True(WindowsWifiTransferHost.DirectStartTimeout > TimeSpan.Zero);
        Assert.True(
            WifiApStarter.DefaultPrimaryAttemptTimeout +
            WindowsWifiTransferHost.HotspotCleanupOnStartFailureTimeout +
            WifiApStarter.DefaultFallbackDelay < WifiApStarter.DefaultTotalStartTimeout);
    }

    [Fact]
    public void MainWindowWifiTransferCheckboxReflectsAndSavesSetting()
    {
        RunSta(() =>
        {
            var pairing = SyncPairing.Create("テスト");
            var settings = new AppSettings(tempDir);
            Assert.True(settings.WifiTransferEnabled);

            var preview = new MainWindow(pairing, _ => { }, preview: true, hotspotBandSupported: false, hotspotSixGHzSupported: false);
            preview.ConfigureHotkey(settings, _ => Task.FromResult<HotkeyChord?>(null), () => { });
            Assert.True(preview.WifiTransferCheck.IsChecked);
            Assert.False(preview.WifiTransferCheck.IsEnabled);

            var normal = new MainWindow(pairing, _ => { }, preview: false, hotspotBandSupported: false, hotspotSixGHzSupported: false);
            try
            {
                normal.ConfigureHotkey(settings, _ => Task.FromResult<HotkeyChord?>(null), () => { });
                Assert.True(normal.WifiTransferCheck.IsChecked);
                Assert.True(normal.WifiTransferCheck.IsEnabled);

                normal.WifiTransferCheck.IsChecked = false;
                normal.WifiTransferCheck.RaiseEvent(new System.Windows.RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));

                Assert.False(settings.WifiTransferEnabled);
                var reloaded = new AppSettings(tempDir);
                Assert.False(reloaded.WifiTransferEnabled);
            }
            finally
            {
                normal.StopWifiProbeSync();
                normal.Close();
            }
        });
    }

    private static void RunSta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try { action(); }
            catch (Exception ex) { failure = ex; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null)
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
    }
}
