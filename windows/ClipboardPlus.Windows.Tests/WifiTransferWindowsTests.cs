using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
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
    public void HotspotConfigBackupStoreQuarantinesCorruptFileWithoutLoggingSecretsOrPath()
    {
        Directory.CreateDirectory(tempDir);
        var file = Path.Combine(tempDir, "hotspot-restore.dat");
        byte[] corruptBytes = [0x01, 0x02, 0x03, 0x04];
        File.WriteAllBytes(file, corruptBytes);

        var logs = new List<string>();
        var store = new HotspotConfigBackupStore(tempDir);
        Assert.Null(store.Load(logs.Add));
        Assert.False(store.Exists);
        Assert.NotEmpty(logs);
        Assert.All(logs, line => Assert.DoesNotContain(tempDir, line, StringComparison.OrdinalIgnoreCase));
        Assert.All(logs, line => Assert.DoesNotContain("hotspot-restore", line, StringComparison.OrdinalIgnoreCase));

        // Corrupt record must be preserved under a quarantine name, not deleted.
        var quarantined = Assert.Single(Directory.GetFiles(tempDir, "hotspot-restore.corrupt.*.dat"));
        Assert.Equal(corruptBytes, File.ReadAllBytes(quarantined));
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

    [Fact]
    public async Task HotspotSessionPreservesExistingBackupRecordAndRestoresOriginalConfig()
    {
        var store = new HotspotConfigBackupStore(tempDir);
        var original = new HotspotBackupRecord(
            Ssid: "UserHomeHotspot",
            Passphrase: "OriginalUserPass123",
            Band: 2,
            TempSsid: "DIRECT-cp-PREV0001");
        store.Save(original);

        var manager = new FakeHotspotTetheringManager(
            new HotspotAccessPointConfig("DIRECT-cp-PREV0001", "OldTempPass12345", Band: 2));
        var platform = new FakeWindowsWifiPlatform(manager);
        var logs = new ConcurrentQueue<string>();
        var host = new WindowsWifiTransferHost(logs.Enqueue, store, platform: platform, fallbackDelay: TimeSpan.Zero);

        var creds2 = MakeCredentials("DIRECT-cp-NEXT0002", "NextTempPass1234");
        var started = await host.StartAsync(creds2, CancellationToken.None);
        try
        {
            Assert.True(started.Succeeded);
            Assert.NotNull(started.Handle);
            Assert.Equal(WifiApMode.Hotspot5GHz, started.Handle!.Mode);

            // Saved backup must still contain the user's original config, with both temp SSIDs tracked.
            var persisted = store.Load();
            Assert.NotNull(persisted);
            Assert.Equal("UserHomeHotspot", persisted!.Ssid);
            Assert.Equal("OriginalUserPass123", persisted.Passphrase);
            Assert.Equal(2, persisted.Band);
            Assert.Equal("DIRECT-cp-NEXT0002", persisted.TempSsid);
            Assert.True(persisted.ShouldRestoreForCurrentSsid("DIRECT-cp-PREV0001"));
            Assert.True(persisted.ShouldRestoreForCurrentSsid("DIRECT-cp-NEXT0002"));
            Assert.False(persisted.ShouldRestoreForCurrentSsid("UserRenamedHotspot"));

            // DPAPI file must never store plaintext SSIDs or passphrase.
            var rawText = Encoding.UTF8.GetString(File.ReadAllBytes(Path.Combine(tempDir, "hotspot-restore.dat")));
            Assert.DoesNotContain("UserHomeHotspot", rawText, StringComparison.Ordinal);
            Assert.DoesNotContain("OriginalUserPass123", rawText, StringComparison.Ordinal);
            Assert.DoesNotContain("DIRECT-cp-PREV0001", rawText, StringComparison.Ordinal);
            Assert.DoesNotContain("DIRECT-cp-NEXT0002", rawText, StringComparison.Ordinal);

            await started.Handle.DisposeAsync();

            // Teardown must restore the original config from the backup, NOT DIRECT-cp-PREV0001.
            Assert.Equal(new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 2), manager.CurrentConfig);
            Assert.False(manager.IsOn);
            Assert.False(store.Exists);
        }
        finally
        {
            if (started.Handle is not null)
                await started.Handle.DisposeAsync();
        }

        AssertNoSecretOrPathInLogs(logs, tempDir, "UserHomeHotspot", "OriginalUserPass123", "DIRECT-cp-PREV0001", "DIRECT-cp-NEXT0002", "NextTempPass1234");
    }

    [Fact]
    public async Task HotspotCleanupTimeoutPreservesBackupAndNextSessionRestoresOriginalConfig()
    {
        var delay = new ControlledDelay();
        var store = new HotspotConfigBackupStore(tempDir);
        var originalConfig = new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 1);
        var manager = new FakeHotspotTetheringManager(originalConfig);
        var platform = new FakeWindowsWifiPlatform(manager);
        var logs = new ConcurrentQueue<string>();

        var restoreEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var hungRestore = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var blockRestore = true;
        manager.OnConfigureAsync = (config, _) =>
        {
            if (blockRestore && config.Ssid == "UserHomeHotspot")
            {
                restoreEntered.TrySetResult();
                return hungRestore.Task;
            }
            return Task.CompletedTask;
        };

        var host = new WindowsWifiTransferHost(
            logs.Enqueue,
            store,
            platform: platform,
            delayAsync: delay.DelayAsync,
            fallbackDelay: TimeSpan.Zero);

        var creds1 = MakeCredentials("DIRECT-cp-SESS0001", "TempPassSession1");
        var start1 = await host.StartAsync(creds1, CancellationToken.None);
        Assert.True(start1.Succeeded);
        Assert.Equal("DIRECT-cp-SESS0001", manager.CurrentConfig?.Ssid);

        // Dispose session 1 while restore hangs -> trigger the 4s cleanup timeout deterministically.
        var disposeTask1 = start1.Handle!.DisposeAsync().AsTask();
        await restoreEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var cleanupWait = await delay.WaitForRequestedDelayAsync(TimeSpan.FromSeconds(4)).WaitAsync(TimeSpan.FromSeconds(5));
        cleanupWait.Trigger();
        await disposeTask1.WaitAsync(TimeSpan.FromSeconds(5));

        // Backup must remain intact after cleanup timeout, while Windows still has SESS0001.
        Assert.True(store.Exists);
        Assert.Equal("DIRECT-cp-SESS0001", manager.CurrentConfig?.Ssid);
        var afterTimeout = store.Load();
        Assert.NotNull(afterTimeout);
        Assert.Equal("UserHomeHotspot", afterTimeout!.Ssid);
        Assert.Equal("OriginalUserPass123", afterTimeout.Passphrase);
        Assert.Equal(1, afterTimeout.Band);

        // Session 2 starts while Windows still has SESS0001; restore now succeeds.
        blockRestore = false;
        var creds2 = MakeCredentials("DIRECT-cp-SESS0002", "TempPassSession2");
        var start2 = await host.StartAsync(creds2, CancellationToken.None);
        try
        {
            Assert.True(start2.Succeeded);
            var duringSession2 = store.Load();
            Assert.NotNull(duringSession2);
            Assert.Equal("UserHomeHotspot", duringSession2!.Ssid);
            Assert.True(duringSession2.ShouldRestoreForCurrentSsid("DIRECT-cp-SESS0001"));
            Assert.True(duringSession2.ShouldRestoreForCurrentSsid("DIRECT-cp-SESS0002"));

            await start2.Handle!.DisposeAsync();

            Assert.Equal(originalConfig, manager.CurrentConfig);
            Assert.False(store.Exists);
        }
        finally
        {
            if (start2.Handle is not null)
                await start2.Handle.DisposeAsync();
        }
    }

    [Fact]
    public async Task HotspotStartFailureBeforeConfigureWithPendingBackupKeepsBackupOnRestoreTimeout()
    {
        var delay = new ControlledDelay();
        var store = new HotspotConfigBackupStore(tempDir);
        store.Save(new HotspotBackupRecord("UserHomeHotspot", "OriginalUserPass123", Band: 2, TempSsid: "DIRECT-cp-OLD00001"));

        var manager = new FakeHotspotTetheringManager(
            new HotspotAccessPointConfig("DIRECT-cp-OLD00001", "OldTempPass12345", Band: 2));

        var restoreEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var hungRestore = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var blockRestore = true;
        manager.OnConfigureAsync = (config, _) =>
        {
            if (blockRestore && config.Ssid == "UserHomeHotspot")
            {
                restoreEntered.TrySetResult();
                return hungRestore.Task;
            }
            return Task.CompletedTask;
        };

        var platform = new FakeWindowsWifiPlatform(manager)
        {
            OnIsHotspotBandApiSupported = () => throw new InvalidOperationException("band api check failed"),
        };
        var logs = new ConcurrentQueue<string>();
        var host = new WindowsWifiTransferHost(
            logs.Enqueue,
            store,
            platform: platform,
            delayAsync: delay.DelayAsync,
            fallbackDelay: TimeSpan.Zero);

        var creds2 = MakeCredentials("DIRECT-cp-NEW00002", "NewTempPass12345");
        var startTask = host.StartAsync(creds2, CancellationToken.None);

        // Even though session 2 failed before configuring NEW00002, HadPendingRestore triggers restore of UserHomeHotspot.
        await restoreEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var cleanupTimeout = await delay.WaitForRequestedDelayAsync(WindowsWifiTransferHost.HotspotCleanupOnStartFailureTimeout)
            .WaitAsync(TimeSpan.FromSeconds(5));
        cleanupTimeout.Trigger();

        var result = await startTask.WaitAsync(TimeSpan.FromSeconds(5));
        try
        {
            Assert.True(result.Succeeded);
            Assert.Equal(WifiApMode.WifiDirect, result.Handle!.Mode);

            // Backup MUST NOT have been cleared, and MUST still recognize OLD00001 (the actual SSID on Windows).
            Assert.True(store.Exists);
            var persisted = store.Load();
            Assert.NotNull(persisted);
            Assert.Equal("UserHomeHotspot", persisted!.Ssid);
            Assert.True(persisted.ShouldRestoreForCurrentSsid("DIRECT-cp-OLD00001"));
            Assert.True(persisted.ShouldRestoreForCurrentSsid("DIRECT-cp-NEW00002"));
        }
        finally
        {
            if (result.Handle is not null)
                await result.Handle.DisposeAsync();
        }

        // Next startup restore cleans up OLD00001 back to UserHomeHotspot and clears backup.
        blockRestore = false;
        await WindowsWifiApController.TryRestorePendingHotspotConfigAsync(store, () => manager, logs.Enqueue);
        Assert.Equal(new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 2), manager.CurrentConfig);
        Assert.False(store.Exists);
    }

    [Fact]
    public async Task SyncStopTimeoutDoesNotClearBackupAndNextStartupRestoresOriginalConfig()
    {
        var store = new HotspotConfigBackupStore(tempDir);
        var originalConfig = new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 2);
        var logs = new ConcurrentQueue<string>();

        // 1. Real Task.Wait(TimeSpan.Zero) on an incomplete configure task returns false without waiting -> backup stays.
        var record1 = new HotspotBackupRecord(originalConfig.Ssid, originalConfig.Passphrase, originalConfig.Band, "DIRECT-cp-SYNC0001");
        store.Save(record1);
        var hangingConfigTcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var realWaitManager = new FakeHotspotTetheringManager(new HotspotAccessPointConfig("DIRECT-cp-SYNC0001", "TempPassSync0001", Band: 2))
        {
            IsOn = true,
            OnConfigureAsync = (_, _) => hangingConfigTcs.Task,
        };
        var state1 = new ActiveHotspotState(realWaitManager, record1, hadPendingRestore: false, store);
        Assert.True(state1.TryMarkConfigModified());
        WindowsWifiApController.StopHotspotAndRestoreSync(state1, stepTimeout: TimeSpan.Zero, waitSync: null);
        Assert.True(store.Exists);
        Assert.Equal(record1, store.Load());

        // 2. Host.StopSync() passes the 1.5s budget and keeps backup when ConfigureAccessPointAsync wait returns false.
        store.Clear();
        var manager2 = new FakeHotspotTetheringManager(originalConfig);
        var platform2 = new FakeWindowsWifiPlatform(manager2);
        var seenBudgets = new List<TimeSpan>();
        var waitCallIndex = 0;
        var host2 = new WindowsWifiTransferHost(
            logs.Enqueue,
            store,
            platform: platform2,
            waitSync: (task, budget) =>
            {
                seenBudgets.Add(budget);
                waitCallIndex++;
                // First wait is StopTetheringAsync (succeeds); second wait is ConfigureAccessPointAsync (times out).
                return waitCallIndex == 1 && task.Wait(TimeSpan.Zero);
            },
            fallbackDelay: TimeSpan.Zero);

        var start2 = await host2.StartAsync(MakeCredentials("DIRECT-cp-SYNC0002", "TempPassSync0002"), CancellationToken.None);
        Assert.True(start2.Succeeded);
        manager2.OnConfigureAsync = (_, _) => new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously).Task;
        host2.StopSync();

        Assert.Equal([WindowsWifiApController.SyncStopDefaultStepTimeout, WindowsWifiApController.SyncStopDefaultStepTimeout], seenBudgets);
        Assert.True(store.Exists);
        Assert.Equal("UserHomeHotspot", store.Load()!.Ssid);

        // 3. StopTetheringAsync timing out also leaves backup intact and skips ConfigureAccessPointAsync.
        var configCallsBefore = manager2.ConfigureCallCount;
        var state3 = new ActiveHotspotState(manager2, store.Load()!, hadPendingRestore: false, store);
        manager2.IsOn = true;
        Assert.True(state3.TryMarkConfigModified());
        WindowsWifiApController.StopHotspotAndRestoreSync(state3, waitSync: (_, _) => false);
        Assert.Equal(configCallsBefore, manager2.ConfigureCallCount);
        Assert.True(store.Exists);

        // 4. Next startup restores the original config from the preserved backup and clears it.
        manager2.OnConfigureAsync = null;
        await WindowsWifiApController.TryRestorePendingHotspotConfigAsync(store, () => manager2, logs.Enqueue);
        Assert.Equal(originalConfig, manager2.CurrentConfig);
        Assert.False(manager2.IsOn);
        Assert.False(store.Exists);

        // 5. When both StopTetheringAsync and ConfigureAccessPointAsync finish before timeout, backup IS cleared.
        var record5 = new HotspotBackupRecord(originalConfig.Ssid, originalConfig.Passphrase, originalConfig.Band, "DIRECT-cp-SYNC0005");
        store.Save(record5);
        var manager5 = new FakeHotspotTetheringManager(new HotspotAccessPointConfig("DIRECT-cp-SYNC0005", "TempPassSync0005", Band: 2))
        {
            IsOn = true,
        };
        var state5 = new ActiveHotspotState(manager5, record5, hadPendingRestore: false, store);
        Assert.True(state5.TryMarkConfigModified());
        WindowsWifiApController.StopHotspotAndRestoreSync(state5);
        Assert.Equal(originalConfig, manager5.CurrentConfig);
        Assert.False(manager5.IsOn);
        Assert.False(store.Exists);
    }

    [Fact]
    public async Task HotspotPreparationFailureFallsBackToWifiDirectWithoutModifyingHotspot()
    {
        // A. Reading current config throws -> do not modify hotspot, fall back to Wi-Fi Direct, log reason code.
        {
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "read-throws"));
            var manager = new FakeHotspotTetheringManager(new HotspotAccessPointConfig("UserSsid", "UserPass1234", 2))
            {
                OnGetCurrent = () => throw new InvalidOperationException("read failed"),
            };
            var platform = new FakeWindowsWifiPlatform(manager);
            var logs = new ConcurrentQueue<string>();
            var host = new WindowsWifiTransferHost(logs.Enqueue, store, platform: platform, fallbackDelay: TimeSpan.Zero);

            var creds = MakeCredentials("DIRECT-cp-PREP0001", "TempPassPrep0001");
            var result = await host.StartAsync(creds, CancellationToken.None);
            try
            {
                Assert.True(result.Succeeded);
                Assert.Equal(WifiApMode.WifiDirect, result.Handle!.Mode);
                Assert.Equal(0, manager.ConfigureCallCount);
                Assert.Equal(0, manager.StartCallCount);
                Assert.Equal(1, platform.WifiDirectCallCount);
                Assert.False(store.Exists);
                Assert.Contains(logs, l => l == "wifi hotspot config read error=InvalidOperationException");
                Assert.Contains(logs, l => l == "wifi ap primary failed mode=hotspot reason=hotspot_config_unreadable");
                AssertNoSecretOrPathInLogs(logs, tempDir, "UserSsid", "UserPass1234", creds.Ssid, creds.Passphrase);
            }
            finally
            {
                if (result.Handle is not null)
                    await result.Handle.DisposeAsync();
            }
        }

        // B. Current config is null or unrestorable (short passphrase) -> fall back to Wi-Fi Direct without modifying hotspot.
        foreach (var badConfig in new HotspotAccessPointConfig?[] { null, new("UserSsid", "short", 2), new("", "ValidPass1234", 2) })
        {
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "unrestorable-" + Guid.NewGuid().ToString("N")));
            var manager = new FakeHotspotTetheringManager(badConfig);
            var platform = new FakeWindowsWifiPlatform(manager);
            var logs = new ConcurrentQueue<string>();
            var host = new WindowsWifiTransferHost(logs.Enqueue, store, platform: platform, fallbackDelay: TimeSpan.Zero);

            var creds = MakeCredentials("DIRECT-cp-PREP0002", "TempPassPrep0002");
            var result = await host.StartAsync(creds, CancellationToken.None);
            try
            {
                Assert.True(result.Succeeded);
                Assert.Equal(WifiApMode.WifiDirect, result.Handle!.Mode);
                Assert.Equal(0, manager.ConfigureCallCount);
                Assert.Equal(0, manager.StartCallCount);
                Assert.False(store.Exists);
                Assert.Contains(logs, l => l == "wifi ap primary failed mode=hotspot reason=hotspot_config_unreadable");
            }
            finally
            {
                if (result.Handle is not null)
                    await result.Handle.DisposeAsync();
            }
        }

        // C. Saving backup fails on real HotspotConfigBackupStore (blocked by directory at target path) -> fall back to Wi-Fi Direct.
        {
            var blockedDir = Path.Combine(tempDir, "save-fails");
            Directory.CreateDirectory(Path.Combine(blockedDir, "hotspot-restore.dat"));
            var store = new HotspotConfigBackupStore(blockedDir);
            var manager = new FakeHotspotTetheringManager(new HotspotAccessPointConfig("UserSsid", "UserPass1234", 2));
            var platform = new FakeWindowsWifiPlatform(manager);
            var logs = new ConcurrentQueue<string>();
            var host = new WindowsWifiTransferHost(logs.Enqueue, store, platform: platform, fallbackDelay: TimeSpan.Zero);

            var creds = MakeCredentials("DIRECT-cp-PREP0003", "TempPassPrep0003");
            var result = await host.StartAsync(creds, CancellationToken.None);
            try
            {
                Assert.True(result.Succeeded);
                Assert.Equal(WifiApMode.WifiDirect, result.Handle!.Mode);
                Assert.Equal(0, manager.ConfigureCallCount);
                Assert.Equal(0, manager.StartCallCount);
                Assert.Contains(logs, l => l.StartsWith("wifi hotspot backup save error=", StringComparison.Ordinal));
                Assert.Contains(logs, l => l == "wifi ap primary failed mode=hotspot reason=hotspot_backup_save_failed");
                AssertNoSecretOrPathInLogs(logs, tempDir, "UserSsid", "UserPass1234", creds.Ssid, creds.Passphrase);
            }
            finally
            {
                if (result.Handle is not null)
                    await result.Handle.DisposeAsync();
            }
        }

        // D. Saving backup fails while an existing backup is present -> existing backup stays untouched and hotspot is not modified.
        {
            var existingRecord = new HotspotBackupRecord("UserOrig", "OrigPass1234", 2, "DIRECT-cp-OLD00001");
            var failingStore = new FailingSaveBackupStore(existingRecord);
            var manager = new FakeHotspotTetheringManager(new HotspotAccessPointConfig("DIRECT-cp-OLD00001", "OldTempPass1234", 2));
            var platform = new FakeWindowsWifiPlatform(manager);
            var logs = new ConcurrentQueue<string>();
            var host = new WindowsWifiTransferHost(logs.Enqueue, failingStore, platform: platform, fallbackDelay: TimeSpan.Zero);

            var result = await host.StartAsync(MakeCredentials("DIRECT-cp-PREP0004", "TempPassPrep0004"), CancellationToken.None);
            try
            {
                Assert.True(result.Succeeded);
                Assert.Equal(WifiApMode.WifiDirect, result.Handle!.Mode);
                Assert.Equal(0, manager.ConfigureCallCount);
                Assert.Equal(0, manager.StartCallCount);
                Assert.Equal(existingRecord, failingStore.Load());
                Assert.Contains(logs, l => l == "wifi ap primary failed mode=hotspot reason=hotspot_backup_save_failed");
            }
            finally
            {
                if (result.Handle is not null)
                    await result.Handle.DisposeAsync();
            }
        }
    }

    [Fact]
    public async Task HotspotSessionWaitsForStartupRestoreBeforeReadingOrModifyingConfig()
    {
        var store = new HotspotConfigBackupStore(tempDir);
        store.Save(new HotspotBackupRecord("UserHomeHotspot", "OriginalUserPass123", Band: 2, TempSsid: "DIRECT-cp-CRASH001"));

        var manager = new FakeHotspotTetheringManager(
            new HotspotAccessPointConfig("DIRECT-cp-CRASH001", "CrashTempPass123", Band: 2));
        var restoreEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var allowRestoreFinish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var sessionReadAttemptedBeforeRestoreFinished = false;
        var restoreFinished = false;

        manager.OnConfigureAsync = async (config, _) =>
        {
            if (config.Ssid == "UserHomeHotspot" && !restoreFinished)
            {
                restoreEntered.TrySetResult();
                await allowRestoreFinish.Task.ConfigureAwait(false);
            }
        };

        var logs = new ConcurrentQueue<string>();
        var startupRestoreTask = WindowsWifiApController.TryRestorePendingHotspotConfigAsync(store, () => manager, logs.Enqueue);
        await restoreEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        var getCurrentCountAfterRestoreStart = manager.GetCurrentCallCount;
        manager.OnGetCurrent = () =>
        {
            if (!restoreFinished)
                sessionReadAttemptedBeforeRestoreFinished = true;
            return manager.CurrentConfig;
        };

        var platform = new FakeWindowsWifiPlatform(manager);
        var host = new WindowsWifiTransferHost(
            logs.Enqueue,
            store,
            startupRestoreTask: startupRestoreTask,
            platform: platform,
            fallbackDelay: TimeSpan.Zero);

        var creds2 = MakeCredentials("DIRECT-cp-NEXT0009", "NextTempPass0009");
        var startTask = host.StartAsync(creds2, CancellationToken.None);

        // StartAsync synchronously enters TryStartHotspotAsync and suspends on startupRestoreTask before touching the manager.
        Assert.False(startTask.IsCompleted);
        Assert.Equal(1, platform.HasInternetCallCount);
        Assert.Equal(0, platform.AcquireHotspotCallCount);
        Assert.Equal(getCurrentCountAfterRestoreStart, manager.GetCurrentCallCount);
        Assert.False(sessionReadAttemptedBeforeRestoreFinished);

        // Signal startup restore to finish -> restores UserHomeHotspot and clears backup, then session runs cleanly.
        restoreFinished = true;
        allowRestoreFinish.SetResult();
        await startupRestoreTask.WaitAsync(TimeSpan.FromSeconds(5));

        var started = await startTask.WaitAsync(TimeSpan.FromSeconds(5));
        try
        {
            Assert.True(started.Succeeded);
            Assert.Equal(WifiApMode.Hotspot5GHz, started.Handle!.Mode);
            Assert.False(sessionReadAttemptedBeforeRestoreFinished);

            // Session read the restored UserHomeHotspot as the original config, not DIRECT-cp-CRASH001.
            var persisted = store.Load();
            Assert.NotNull(persisted);
            Assert.Equal("UserHomeHotspot", persisted!.Ssid);
            Assert.Equal("OriginalUserPass123", persisted.Passphrase);
            Assert.Equal("DIRECT-cp-NEXT0009", persisted.TempSsid);
            Assert.Null(persisted.PreviousTempSsids);

            await started.Handle.DisposeAsync();
            Assert.Equal(new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 2), manager.CurrentConfig);
            Assert.False(store.Exists);
        }
        finally
        {
            if (started.Handle is not null)
                await started.Handle.DisposeAsync();
        }
    }

    [Fact]
    public async Task HotspotSessionWaitsForHungStartupRestoreAndFallsBackToWifiDirectOnRestoreWaitTimeout()
    {
        var delay = new ControlledDelay();
        var store = new HotspotConfigBackupStore(tempDir);
        store.Save(new HotspotBackupRecord("UserHomeHotspot", "OriginalUserPass123", Band: 2, TempSsid: "DIRECT-cp-HUNG0001"));

        var manager = new FakeHotspotTetheringManager(
            new HotspotAccessPointConfig("DIRECT-cp-HUNG0001", "HungTempPass0001", Band: 2));
        var platform = new FakeWindowsWifiPlatform(manager);
        var logs = new ConcurrentQueue<string>();
        var hungStartupRestore = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var host = new WindowsWifiTransferHost(
            logs.Enqueue,
            store,
            startupRestoreTask: hungStartupRestore.Task,
            platform: platform,
            delayAsync: delay.DelayAsync,
            fallbackDelay: TimeSpan.Zero);

        var startTask = host.StartAsync(MakeCredentials("DIRECT-cp-NEXT0010", "NextTempPass0010"), CancellationToken.None);
        Assert.Equal(1, platform.HasInternetCallCount);
        Assert.Equal(0, platform.AcquireHotspotCallCount);
        Assert.Equal(0, manager.GetCurrentCallCount);
        Assert.Equal(0, manager.ConfigureCallCount);

        // Startup restore wait uses its own budget outside the 7s primary attempt timeout.
        var restoreWait = await delay.WaitForRequestedDelayAsync(WindowsWifiTransferHost.HotspotStartupRestoreWaitTimeout)
            .WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(delay.HasRequestedDelay(WifiApStarter.DefaultPrimaryAttemptTimeout));
        restoreWait.Trigger();

        var result = await startTask.WaitAsync(TimeSpan.FromSeconds(5));
        try
        {
            Assert.True(result.Succeeded);
            Assert.Equal(WifiApMode.WifiDirect, result.Handle!.Mode);
            Assert.Equal(0, platform.AcquireHotspotCallCount);
            Assert.Equal(0, manager.GetCurrentCallCount);
            Assert.Equal(0, manager.ConfigureCallCount);
            Assert.True(store.Exists);
            Assert.Equal("UserHomeHotspot", store.Load()!.Ssid);
            Assert.Contains(logs, l => l == "wifi ap primary failed mode=hotspot reason=hotspot_startup_restore_timeout");
        }
        finally
        {
            hungStartupRestore.TrySetResult();
            if (result.Handle is not null)
                await result.Handle.DisposeAsync();
        }
    }

    [Fact]
    public async Task OfflineOrUnreadableStartupRestoreKeepsBackupAndLaterOnlineSessionRestoresOriginalConfig()
    {
        var store = new HotspotConfigBackupStore(tempDir);
        store.Save(new HotspotBackupRecord("UserHomeHotspot", "OriginalUserPass123", Band: 2, TempSsid: "DIRECT-cp-CRASH002"));
        var logs = new ConcurrentQueue<string>();

        // 1. Offline at startup (no tethering manager) -> keep backup.
        await WindowsWifiApController.TryRestorePendingHotspotConfigAsync(store, () => null, logs.Enqueue);
        Assert.True(store.Exists);

        // 2. Current config unreadable at startup (returns null) -> must NOT clear backup.
        var unreadableManager = new FakeHotspotTetheringManager(null);
        await WindowsWifiApController.TryRestorePendingHotspotConfigAsync(store, () => unreadableManager, logs.Enqueue);
        Assert.True(store.Exists);

        // 3. Later online session starts while Windows still has CRASH002 -> preserves UserHomeHotspot and restores it.
        var onlineManager = new FakeHotspotTetheringManager(
            new HotspotAccessPointConfig("DIRECT-cp-CRASH002", "CrashTempPass002", Band: 2));
        var platform = new FakeWindowsWifiPlatform(onlineManager);
        var host = new WindowsWifiTransferHost(logs.Enqueue, store, platform: platform, fallbackDelay: TimeSpan.Zero);

        var started = await host.StartAsync(MakeCredentials("DIRECT-cp-ONLINE03", "OnlineTempPass03"), CancellationToken.None);
        try
        {
            Assert.True(started.Succeeded);
            Assert.Equal("UserHomeHotspot", store.Load()!.Ssid);
            await started.Handle!.DisposeAsync();
            Assert.Equal(new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 2), onlineManager.CurrentConfig);
            Assert.False(store.Exists);
        }
        finally
        {
            if (started.Handle is not null)
                await started.Handle.DisposeAsync();
        }
    }

    [Fact]
    public async Task EmergencyCrashStopUsesShortTimeoutIsIdempotentAndPreservesBackupOnTimeout()
    {
        var store = new HotspotConfigBackupStore(tempDir);
        var originalConfig = new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 2);
        var manager = new FakeHotspotTetheringManager(originalConfig);
        var platform = new FakeWindowsWifiPlatform(manager);
        var logs = new ConcurrentQueue<string>();

        var seenBudgets = new List<TimeSpan>();
        var allowSyncComplete = false;
        var host = new WindowsWifiTransferHost(
            logs.Enqueue,
            store,
            platform: platform,
            waitSync: (task, budget) =>
            {
                seenBudgets.Add(budget);
                return allowSyncComplete && task.Wait(TimeSpan.Zero);
            },
            fallbackDelay: TimeSpan.Zero);

        // 1. Mid-start in-flight hotspot (after ConfigureAccessPointAsync, paused in StartTetheringAsync).
        var startEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseStart = new TaskCompletionSource<(bool, string)>(TaskCreationOptions.RunContinuationsAsynchronously);
        manager.OnStartAsync = _ =>
        {
            startEntered.TrySetResult();
            return releaseStart.Task;
        };

        var startTask = host.StartAsync(MakeCredentials("DIRECT-cp-CRASH101", "CrashTempPass101"), CancellationToken.None);
        await startEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        // Simulate crash handler calling best-effort stop with short budget; probe callback throws but is swallowed.
        var probeCalled = false;
        App.RunBestEffortHotspotStop(
            () => host.StopSync(WindowsWifiApController.EmergencyStopStepTimeout),
            () =>
            {
                probeCalled = true;
                throw new InvalidOperationException("probe boom");
            });
        // Calling a second time (e.g. ProcessExit after UnhandledException) is an idempotent no-op.
        App.RunBestEffortHotspotStop(
            () => host.StopSync(WindowsWifiApController.EmergencyStopStepTimeout),
            null);

        Assert.True(probeCalled);
        Assert.Equal([WindowsWifiApController.EmergencyStopStepTimeout], seenBudgets);
        Assert.True(WindowsWifiApController.EmergencyStopStepTimeout < WindowsWifiApController.SyncStopDefaultStepTimeout);
        // Timed out -> backup remains on disk for next startup!
        Assert.True(store.Exists);
        Assert.Equal("UserHomeHotspot", store.Load()!.Ssid);

        releaseStart.SetResult((false, "Aborted"));
        var startResult = await startTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(startResult.Succeeded); // Fell back to Wi-Fi Direct in fake platform
        await startResult.Handle!.DisposeAsync();

        // 2. When emergency stop completes before timeout, original config is restored and backup is cleared.
        manager.OnStartAsync = null;
        seenBudgets.Clear();
        allowSyncComplete = true;
        var started2 = await host.StartAsync(MakeCredentials("DIRECT-cp-CRASH102", "CrashTempPass102"), CancellationToken.None);
        Assert.True(started2.Succeeded);

        App.RunBestEffortHotspotStop(
            () => host.StopSync(WindowsWifiApController.EmergencyStopStepTimeout),
            null);

        Assert.Equal([WindowsWifiApController.EmergencyStopStepTimeout, WindowsWifiApController.EmergencyStopStepTimeout], seenBudgets);
        Assert.Equal(originalConfig, manager.CurrentConfig);
        Assert.False(manager.IsOn);
        Assert.False(store.Exists);
        Assert.Null(WindowsWifiHardwareLease.CurrentOwner);
    }

    [Fact]
    public async Task StaleSessionCleanupDoesNotClearNewerBackupAndClearIfTempSsidMatchesProtectsCorruptFiles()
    {
        var store = new HotspotConfigBackupStore(tempDir);
        var originalConfig = new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 2);
        var prep1 = store.PrepareForSession(originalConfig, "DIRECT-cp-SESS0001");
        Assert.True(prep1.Succeeded);

        // Session 2 starts while Windows still has SESS0001 -> record's TempSsid advances to SESS0002.
        var prep2 = store.PrepareForSession(
            new HotspotAccessPointConfig("DIRECT-cp-SESS0001", "TempPass12345678", Band: 2),
            "DIRECT-cp-SESS0002");
        Assert.True(prep2.Succeeded);
        Assert.True(prep2.PreservedExistingBackup);

        // Direct ClearIfTempSsidMatches for stale SESS0001 must NOT delete SESS0002's backup.
        Assert.False(store.ClearIfTempSsidMatches("DIRECT-cp-SESS0001"));
        Assert.True(store.Exists);
        Assert.Equal("DIRECT-cp-SESS0002", store.Load()!.TempSsid);

        // Session 1's StopHotspotAndRestoreAsync finishing after session 2 saved must also keep SESS0002's backup.
        var manager1 = new FakeHotspotTetheringManager(new HotspotAccessPointConfig("DIRECT-cp-SESS0001", "TempPass12345678", Band: 2));
        var state1 = new ActiveHotspotState(manager1, prep1.Record!, hadPendingRestore: false, store);
        Assert.True(state1.TryMarkConfigModified());
        await WindowsWifiApController.StopHotspotAndRestoreAsync(state1, _ => { }, "wifi transfer");
        Assert.True(store.Exists);
        Assert.Equal("DIRECT-cp-SESS0002", store.Load()!.TempSsid);

        // Session 1's StopHotspotAndRestoreSync finishing after session 2 saved must also keep SESS0002's backup.
        var state1Sync = new ActiveHotspotState(manager1, prep1.Record!, hadPendingRestore: false, store);
        Assert.True(state1Sync.TryMarkConfigModified());
        WindowsWifiApController.StopHotspotAndRestoreSync(state1Sync);
        Assert.True(store.Exists);
        Assert.Equal("DIRECT-cp-SESS0002", store.Load()!.TempSsid);

        // Session 2's cleanup matches SESS0002 and clears the backup.
        var state2 = new ActiveHotspotState(manager1, prep2.Record!, hadPendingRestore: true, store);
        Assert.True(state2.TryMarkConfigModified());
        await WindowsWifiApController.StopHotspotAndRestoreAsync(state2, _ => { }, "wifi transfer");
        Assert.False(store.Exists);

        // ClearIfTempSsidMatches must never delete an undecryptable file.
        var rawPath = Path.Combine(tempDir, "hotspot-restore.dat");
        File.WriteAllBytes(rawPath, [0xDE, 0xAD, 0xBE, 0xEF]);
        Assert.False(store.ClearIfTempSsidMatches("DIRECT-cp-SESS0002"));
        Assert.True(File.Exists(rawPath));
    }

    [Fact]
    public async Task HardwareLeaseRemainsHeldUntilTimedOutStartCleanupAndLateHandleDisposeComplete()
    {
        // Part 1: Timed-out primary start whose cleanup is still running keeps hardware lease held until cleanup finishes.
        {
            var delay = new ControlledDelay();
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "lease-cleanup"));
            var originalConfig = new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 2);
            var manager = new FakeHotspotTetheringManager(originalConfig);

            var startEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var hungStart = new TaskCompletionSource<(bool, string)>(TaskCreationOptions.RunContinuationsAsynchronously);
            var cleanupEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var allowCleanupFinish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

            manager.OnStartAsync = _ =>
            {
                startEntered.TrySetResult();
                return hungStart.Task;
            };
            manager.OnConfigureAsync = async (config, _) =>
            {
                if (config.Ssid == originalConfig.Ssid)
                {
                    cleanupEntered.TrySetResult();
                    await allowCleanupFinish.Task.ConfigureAwait(false);
                }
            };

            var platform = new FakeWindowsWifiPlatform(manager)
            {
                OnTryStartWifiDirect = (_, _) => Task.FromResult(WifiApAttemptResult.Failure("RadioNotAvailable")),
            };
            var logs = new ConcurrentQueue<string>();
            var host = new WindowsWifiTransferHost(
                logs.Enqueue,
                store,
                platform: platform,
                delayAsync: delay.DelayAsync,
                fallbackDelay: TimeSpan.Zero);

            var startTask1 = host.StartAsync(MakeCredentials("DIRECT-cp-LEAS0001", "TempPassLease001"), CancellationToken.None);
            await startEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

            // Trigger 7s primary attempt timeout -> TryStartHotspotAsync cancels and starts CleanupPendingHotspotAsync,
            // while fallback Wi-Fi Direct fails immediately so StartAsync returns StartFailed.
            var primaryWait = await delay.WaitForRequestedDelayAsync(WifiApStarter.DefaultPrimaryAttemptTimeout)
                .WaitAsync(TimeSpan.FromSeconds(5));
            primaryWait.Trigger();

            await cleanupEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var result1 = await startTask1.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.False(result1.Succeeded);

            // Cleanup from attempt 1 is STILL running -> hardware lease MUST remain held!
            Assert.Equal("production", WindowsWifiHardwareLease.CurrentOwner);
            Assert.False(WindowsWifiHardwareLease.TryAcquire("probe"));
            var busyResult = await host.StartAsync(MakeCredentials("DIRECT-cp-LEAS0002", "TempPassLease002"), CancellationToken.None);
            Assert.False(busyResult.Succeeded);
            Assert.Equal(WifiUnavailableReason.Busy, busyResult.FailureReason);

            // Complete hung StartTetheringAsync and let cleanup finish -> lease is released!
            hungStart.TrySetResult((false, "Aborted"));
            allowCleanupFinish.SetResult();
            await host.WaitForHardwareIdleAsync().WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Null(WindowsWifiHardwareLease.CurrentOwner);

            // Next transfer can now acquire the lease and succeed cleanly.
            manager.OnStartAsync = null;
            manager.OnConfigureAsync = null;
            var result3 = await host.StartAsync(MakeCredentials("DIRECT-cp-LEAS0003", "TempPassLease003"), CancellationToken.None);
            try
            {
                Assert.True(result3.Succeeded);
                Assert.Equal(WifiApMode.Hotspot5GHz, result3.Handle!.Mode);
            }
            finally
            {
                if (result3.Handle is not null)
                    await result3.Handle.DisposeAsync();
            }
            Assert.Null(WindowsWifiHardwareLease.CurrentOwner);
        }

        // Part 2: Late-succeeding hotspot handle after primary timeout keeps hardware lease held until late handle DisposeAsync completes.
        {
            var delay = new ControlledDelay();
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "lease-late-handle"));
            var originalConfig = new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 2);
            var manager = new FakeHotspotTetheringManager(originalConfig);

            var bindEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var allowBindFinish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var lateCleanupEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var allowLateCleanupFinish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

            manager.OnConfigureAsync = async (config, _) =>
            {
                if (config.Ssid == originalConfig.Ssid)
                {
                    lateCleanupEntered.TrySetResult();
                    await allowLateCleanupFinish.Task.ConfigureAwait(false);
                }
            };

            var platform = new FakeWindowsWifiPlatform(manager)
            {
                OnTryStartWifiDirect = (_, _) => Task.FromResult(WifiApAttemptResult.Failure("RadioNotAvailable")),
                OnBindAsync = async _ =>
                {
                    bindEntered.TrySetResult();
                    await allowBindFinish.Task.ConfigureAwait(false);
                },
            };
            var logs = new ConcurrentQueue<string>();
            var host = new WindowsWifiTransferHost(
                logs.Enqueue,
                store,
                platform: platform,
                delayAsync: delay.DelayAsync,
                fallbackDelay: TimeSpan.Zero);

            var startTask = host.StartAsync(MakeCredentials("DIRECT-cp-LATE0001", "TempPassLate0001"), CancellationToken.None);
            await bindEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

            // Primary 7s timeout fires while bind ignores cancellation -> fallback fails -> StartAsync returns StartFailed.
            var primaryWait = await delay.WaitForRequestedDelayAsync(WifiApStarter.DefaultPrimaryAttemptTimeout)
                .WaitAsync(TimeSpan.FromSeconds(5));
            primaryWait.Trigger();

            var startResult = await startTask.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.False(startResult.Succeeded);
            Assert.Equal("production", WindowsWifiHardwareLease.CurrentOwner);

            // Bind completes late -> TryStartHotspotAsync returns a late handle -> DisposeHandleIfLateSuccess calls DisposeAsync().
            allowBindFinish.SetResult();
            await lateCleanupEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

            // Lease MUST stay held throughout late handle's StopHotspotAndRestoreAsync!
            Assert.Equal("production", WindowsWifiHardwareLease.CurrentOwner);
            var busy = await host.StartAsync(MakeCredentials("DIRECT-cp-LATE0002", "TempPassLate0002"), CancellationToken.None);
            Assert.False(busy.Succeeded);
            Assert.Equal(WifiUnavailableReason.Busy, busy.FailureReason);

            // Finish late handle cleanup -> backup cleared and lease released!
            allowLateCleanupFinish.SetResult();
            await host.WaitForHardwareIdleAsync().WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Null(WindowsWifiHardwareLease.CurrentOwner);
            Assert.Equal(originalConfig, manager.CurrentConfig);
            Assert.False(store.Exists);
        }
    }

    [Fact]
    public async Task StopSyncDuringInFlightConfigureOrStartPreservesBackupEvenWhenRestoreSucceeds()
    {
        // Case 1: StopSync runs while ConfigureAccessPointAsync is still in-flight (and best-effort restore succeeds immediately).
        {
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "inflight-configure"));
            var originalConfig = new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 2);
            var manager = new FakeHotspotTetheringManager(originalConfig);

            var tempConfigureEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var releaseTempConfigure = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            manager.OnConfigureAsync = (config, _) =>
            {
                if (config.Ssid == "DIRECT-cp-INFL0001")
                {
                    tempConfigureEntered.TrySetResult();
                    return releaseTempConfigure.Task;
                }
                // Best-effort restore of originalConfig succeeds immediately!
                return Task.CompletedTask;
            };

            var platform = new FakeWindowsWifiPlatform(manager);
            var logs = new ConcurrentQueue<string>();
            var host = new WindowsWifiTransferHost(logs.Enqueue, store, platform: platform, fallbackDelay: TimeSpan.Zero);

            using var cts = new CancellationTokenSource();
            var startTask = host.StartAsync(MakeCredentials("DIRECT-cp-INFL0001", "TempPassInfl0001"), cts.Token);
            await tempConfigureEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

            // Shutdown StopSync runs while temporary ConfigureAccessPointAsync is still pending in Windows.
            host.StopSync();

            // Even though restore of UserHomeHotspot succeeded, backup MUST remain because temp configure was in-flight!
            Assert.True(store.Exists);
            Assert.Equal("UserHomeHotspot", store.Load()!.Ssid);

            // Simulate the in-flight temporary configure taking effect AFTER StopSync's restore!
            releaseTempConfigure.SetResult();
            cts.Cancel();
            try
            {
                var r = await startTask.WaitAsync(TimeSpan.FromSeconds(5));
                if (r.Handle is not null) await r.Handle.DisposeAsync();
            }
            catch (OperationCanceledException) { }
            await host.WaitForHardwareIdleAsync().WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Null(WindowsWifiHardwareLease.CurrentOwner);

            Assert.Equal("DIRECT-cp-INFL0001", manager.CurrentConfig?.Ssid);
            Assert.True(store.Exists);

            // Next app startup restores the user's original config from the preserved backup and clears it.
            manager.OnConfigureAsync = null;
            await WindowsWifiApController.TryRestorePendingHotspotConfigAsync(store, () => manager, logs.Enqueue);
            Assert.Equal(originalConfig, manager.CurrentConfig);
            Assert.False(store.Exists);
        }

        // Case 2: StopSync runs while StartTetheringAsync is still in-flight (and best-effort restore succeeds immediately).
        {
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "inflight-start"));
            var originalConfig = new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 2);
            var manager = new FakeHotspotTetheringManager(originalConfig);

            var startEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var releaseStart = new TaskCompletionSource<(bool, string)>(TaskCreationOptions.RunContinuationsAsynchronously);
            manager.OnStartAsync = _ =>
            {
                startEntered.TrySetResult();
                return releaseStart.Task;
            };

            var platform = new FakeWindowsWifiPlatform(manager);
            var logs = new ConcurrentQueue<string>();
            var host = new WindowsWifiTransferHost(logs.Enqueue, store, platform: platform, fallbackDelay: TimeSpan.Zero);

            using var cts = new CancellationTokenSource();
            var startTask = host.StartAsync(MakeCredentials("DIRECT-cp-INFL0002", "TempPassInfl0002"), cts.Token);
            await startEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

            // StopSync restores synchronously (succeeds!), but StartTetheringAsync is still in-flight -> keep backup!
            host.StopSync();
            Assert.True(store.Exists);
            Assert.Equal("UserHomeHotspot", store.Load()!.Ssid);

            releaseStart.SetResult((false, "Aborted"));
            cts.Cancel();
            try
            {
                var r = await startTask.WaitAsync(TimeSpan.FromSeconds(5));
                if (r.Handle is not null) await r.Handle.DisposeAsync();
            }
            catch (OperationCanceledException) { }
            await host.WaitForHardwareIdleAsync().WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Null(WindowsWifiHardwareLease.CurrentOwner);
            Assert.True(store.Exists);
        }
    }

    [Fact]
    public async Task CancelDuringHotspotStartWaitsBrieflyForCleanupAndCapsWaitWhenHung()
    {
        // Case 1: Cancelled after Configure+Start completed (during bind) and cleanup finishes before 1s cancel grace
        // -> StartAsync waits for cleanup, restores config, clears backup, and releases lease cleanly.
        {
            var delay = new ControlledDelay();
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "cancel-grace-fast"));
            var originalConfig = new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 2);
            var manager = new FakeHotspotTetheringManager(originalConfig);

            var bindEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var cleanupEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var allowCleanupFinish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            manager.OnConfigureAsync = async (config, _) =>
            {
                if (config.Ssid == originalConfig.Ssid)
                {
                    cleanupEntered.TrySetResult();
                    await allowCleanupFinish.Task.ConfigureAwait(false);
                }
            };

            var platform = new FakeWindowsWifiPlatform(manager)
            {
                OnBindAsync = async ct =>
                {
                    bindEntered.TrySetResult();
                    var cancelled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                    using var reg = ct.Register(() => cancelled.TrySetCanceled(ct));
                    await cancelled.Task.ConfigureAwait(false);
                },
            };
            var host = new WindowsWifiTransferHost(
                _ => { },
                store,
                platform: platform,
                delayAsync: delay.DelayAsync,
                fallbackDelay: TimeSpan.Zero);

            using var cts = new CancellationTokenSource();
            var startTask = host.StartAsync(MakeCredentials("DIRECT-cp-CNCL0001", "TempPassCncl0001"), cts.Token);
            await bindEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

            cts.Cancel();
            await cleanupEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            _ = await delay.WaitForRequestedDelayAsync(WindowsWifiTransferHost.StartCancelWaitTimeout)
                .WaitAsync(TimeSpan.FromSeconds(5));
            Assert.False(startTask.IsCompleted);

            // Cleanup completes -> StartAsync finishes without waiting for the 1s timer to expire.
            allowCleanupFinish.SetResult();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => startTask.WaitAsync(TimeSpan.FromSeconds(5)));
            Assert.Equal(originalConfig, manager.CurrentConfig);
            Assert.False(manager.IsOn);
            Assert.False(store.Exists);
            Assert.Null(WindowsWifiHardwareLease.CurrentOwner);
        }

        // Case 2: Cancelled while StartTetheringAsync is in-flight and cleanup hangs ->
        // StartAsync stops waiting after StartCancelWaitTimeout (1s), keeps lease until cleanup ends,
        // and preserves backup because StartTetheringAsync was in-flight during teardown.
        {
            var delay = new ControlledDelay();
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "cancel-grace-hung"));
            var originalConfig = new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 2);
            var manager = new FakeHotspotTetheringManager(originalConfig);

            var startEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var cleanupEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var allowCleanupFinish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            manager.OnStartAsync = _ =>
            {
                startEntered.TrySetResult();
                return new TaskCompletionSource<(bool, string)>(TaskCreationOptions.RunContinuationsAsynchronously).Task;
            };
            manager.OnConfigureAsync = async (config, _) =>
            {
                if (config.Ssid == originalConfig.Ssid)
                {
                    cleanupEntered.TrySetResult();
                    await allowCleanupFinish.Task.ConfigureAwait(false);
                }
            };

            var platform = new FakeWindowsWifiPlatform(manager);
            var host = new WindowsWifiTransferHost(
                _ => { },
                store,
                platform: platform,
                delayAsync: delay.DelayAsync,
                fallbackDelay: TimeSpan.Zero);

            using var cts = new CancellationTokenSource();
            var startTask = host.StartAsync(MakeCredentials("DIRECT-cp-CNCL0002", "TempPassCncl0002"), cts.Token);
            await startEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

            cts.Cancel();
            await cleanupEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var graceWait = await delay.WaitForRequestedDelayAsync(WindowsWifiTransferHost.StartCancelWaitTimeout)
                .WaitAsync(TimeSpan.FromSeconds(5));
            graceWait.Trigger();

            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => startTask.WaitAsync(TimeSpan.FromSeconds(5)));
            Assert.True(store.Exists);
            Assert.Equal("production", WindowsWifiHardwareLease.CurrentOwner);

            allowCleanupFinish.SetResult();
            await host.WaitForHardwareIdleAsync().WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Null(WindowsWifiHardwareLease.CurrentOwner);
            // StartTetheringAsync was still in-flight during teardown, so backup stays preserved for next startup!
            Assert.True(store.Exists);
        }
    }

    [Fact]
    public async Task BandQueryAndFiveGhzConfigureTimeoutsOrFailuresContinueWithHotspotAuto()
    {
        var originalConfig = new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 2);
        var autoBand = (int)WindowsWifiApController.ToWinRtBand(WifiProbeBand.Auto);
        var fiveBand = (int)WindowsWifiApController.ToWinRtBand(WifiProbeBand.FiveGHz);

        // 1. Band query timeout -> continues with HotspotAuto instead of falling back to Wi-Fi Direct.
        {
            var delay = new ControlledDelay();
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "band-query-timeout"));
            var manager = new FakeHotspotTetheringManager(originalConfig);
            var queryEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            manager.OnQueryBandsAsync = (_, _) =>
            {
                queryEntered.TrySetResult();
                return new TaskCompletionSource<IReadOnlyList<WifiProbeBand>>(TaskCreationOptions.RunContinuationsAsynchronously).Task;
            };
            var platform = new FakeWindowsWifiPlatform(manager);
            var logs = new ConcurrentQueue<string>();
            var host = new WindowsWifiTransferHost(logs.Enqueue, store, platform: platform, delayAsync: delay.DelayAsync, fallbackDelay: TimeSpan.Zero);

            var startTask = host.StartAsync(MakeCredentials("DIRECT-cp-AUTO0001", "TempPassAuto0001"), CancellationToken.None);
            await queryEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var bandTimeout = await delay.WaitForRequestedDelayAsync(WindowsWifiTransferHost.HotspotBandQueryTimeout)
                .WaitAsync(TimeSpan.FromSeconds(5));
            bandTimeout.Trigger();

            var result = await startTask.WaitAsync(TimeSpan.FromSeconds(5));
            try
            {
                Assert.True(result.Succeeded);
                Assert.Equal(WifiApMode.HotspotAuto, result.Handle!.Mode);
                Assert.Equal(0, platform.WifiDirectCallCount);
                Assert.Equal([autoBand], manager.ConfiguredHistory.Select(c => c.Band).ToArray());
                Assert.Contains(logs, l => l == "wifi transfer hotspot band query error=hotspot_band_timeout");
            }
            finally
            {
                if (result.Handle is not null) await result.Handle.DisposeAsync();
            }
        }

        // 2. Band query exception -> continues with HotspotAuto.
        {
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "band-query-error"));
            var manager = new FakeHotspotTetheringManager(originalConfig)
            {
                OnQueryBandsAsync = (_, _) => throw new InvalidOperationException("query boom"),
            };
            var platform = new FakeWindowsWifiPlatform(manager);
            var logs = new ConcurrentQueue<string>();
            var host = new WindowsWifiTransferHost(logs.Enqueue, store, platform: platform, fallbackDelay: TimeSpan.Zero);

            var result = await host.StartAsync(MakeCredentials("DIRECT-cp-AUTO0002", "TempPassAuto0002"), CancellationToken.None);
            try
            {
                Assert.True(result.Succeeded);
                Assert.Equal(WifiApMode.HotspotAuto, result.Handle!.Mode);
                Assert.Equal(0, platform.WifiDirectCallCount);
                Assert.Equal([autoBand], manager.ConfiguredHistory.Select(c => c.Band).ToArray());
                Assert.Contains(logs, l => l == "wifi transfer hotspot band query error=InvalidOperationException");
            }
            finally
            {
                if (result.Handle is not null) await result.Handle.DisposeAsync();
            }
        }

        // 3. 5GHz configure timeout -> retries with HotspotAuto instead of falling back to Wi-Fi Direct.
        {
            var delay = new ControlledDelay();
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "fiveghz-config-timeout"));
            var manager = new FakeHotspotTetheringManager(originalConfig);
            var fiveEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var hungFive = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            manager.OnConfigureAsync = (config, _) =>
            {
                if (config.Band == fiveBand && config.Ssid == "DIRECT-cp-AUTO0003")
                {
                    fiveEntered.TrySetResult();
                    return hungFive.Task;
                }
                return Task.CompletedTask;
            };
            var platform = new FakeWindowsWifiPlatform(manager);
            var logs = new ConcurrentQueue<string>();
            var host = new WindowsWifiTransferHost(logs.Enqueue, store, platform: platform, delayAsync: delay.DelayAsync, fallbackDelay: TimeSpan.Zero);

            var startTask = host.StartAsync(MakeCredentials("DIRECT-cp-AUTO0003", "TempPassAuto0003"), CancellationToken.None);
            await fiveEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var cfgTimeout = await delay.WaitForRequestedDelayAsync(WindowsWifiTransferHost.HotspotConfigureTimeout)
                .WaitAsync(TimeSpan.FromSeconds(5));
            cfgTimeout.Trigger();

            var result = await startTask.WaitAsync(TimeSpan.FromSeconds(5));
            try
            {
                Assert.True(result.Succeeded);
                Assert.Equal(WifiApMode.HotspotAuto, result.Handle!.Mode);
                Assert.Equal(0, platform.WifiDirectCallCount);
                Assert.Equal([fiveBand, autoBand], manager.ConfiguredHistory.Select(c => c.Band).ToArray());
                Assert.Contains(logs, l => l == "wifi transfer hotspot5 config error=hotspot_config_timeout");
            }
            finally
            {
                hungFive.TrySetResult();
                if (result.Handle is not null) await result.Handle.DisposeAsync();
            }
        }

        // 4. 5GHz configure exception -> retries with HotspotAuto.
        {
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "fiveghz-config-error"));
            var manager = new FakeHotspotTetheringManager(originalConfig)
            {
                OnConfigureAsync = (config, _) =>
                    config.Band == fiveBand && config.Ssid == "DIRECT-cp-AUTO0004"
                        ? Task.FromException(new InvalidOperationException("5ghz rejected"))
                        : Task.CompletedTask,
            };
            var platform = new FakeWindowsWifiPlatform(manager);
            var logs = new ConcurrentQueue<string>();
            var host = new WindowsWifiTransferHost(logs.Enqueue, store, platform: platform, fallbackDelay: TimeSpan.Zero);

            var result = await host.StartAsync(MakeCredentials("DIRECT-cp-AUTO0004", "TempPassAuto0004"), CancellationToken.None);
            try
            {
                Assert.True(result.Succeeded);
                Assert.Equal(WifiApMode.HotspotAuto, result.Handle!.Mode);
                Assert.Equal(0, platform.WifiDirectCallCount);
                Assert.Equal([fiveBand, autoBand], manager.ConfiguredHistory.Select(c => c.Band).ToArray());
                Assert.Contains(logs, l => l == "wifi transfer hotspot5 config error=InvalidOperationException");
            }
            finally
            {
                if (result.Handle is not null) await result.Handle.DisposeAsync();
            }
        }
    }

    [Fact]
    public async Task StartupRestoreWaitDoesNotConsumePrimaryAttempt7SecondBudget()
    {
        var delay = new ControlledDelay();
        var store = new HotspotConfigBackupStore(tempDir);
        var originalConfig = new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: 2);
        var manager = new FakeHotspotTetheringManager(originalConfig);
        var platform = new FakeWindowsWifiPlatform(manager);
        var logs = new ConcurrentQueue<string>();
        var startupRestoreGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var startEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var allowStart = new TaskCompletionSource<(bool, string)>(TaskCreationOptions.RunContinuationsAsynchronously);
        manager.OnStartAsync = _ =>
        {
            startEntered.TrySetResult();
            return allowStart.Task;
        };

        var host = new WindowsWifiTransferHost(
            logs.Enqueue,
            store,
            startupRestoreTask: startupRestoreGate.Task,
            platform: platform,
            delayAsync: delay.DelayAsync,
            fallbackDelay: TimeSpan.Zero);

        var startTask = host.StartAsync(MakeCredentials("DIRECT-cp-BUDG0001", "TempPassBudg0001"), CancellationToken.None);

        // While startup restore is running, only the startup-restore wait budget (5s) is active;
        // the 7-second primary attempt budget has NOT started yet.
        _ = await delay.WaitForRequestedDelayAsync(WindowsWifiTransferHost.HotspotStartupRestoreWaitTimeout)
            .WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(delay.HasRequestedDelay(WifiApStarter.DefaultPrimaryAttemptTimeout));

        // Startup restore finishes -> NOW the full 7-second primary attempt budget begins fresh.
        startupRestoreGate.SetResult();
        await startEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        _ = await delay.WaitForRequestedDelayAsync(WifiApStarter.DefaultPrimaryAttemptTimeout)
            .WaitAsync(TimeSpan.FromSeconds(5));

        allowStart.SetResult((true, "Success"));
        var result = await startTask.WaitAsync(TimeSpan.FromSeconds(5));
        try
        {
            Assert.True(result.Succeeded);
            Assert.Equal(WifiApMode.Hotspot5GHz, result.Handle!.Mode);
        }
        finally
        {
            if (result.Handle is not null)
                await result.Handle.DisposeAsync();
        }
    }

    [Fact]
    public async Task CorruptBackupIsQuarantinedAndTemporaryCurrentSsidRefusesHotspotAndFallsBackToWifiDirect()
    {
        // Verify temporary SSID shape detection matches generated credentials and rejects user SSIDs.
        Assert.True(WifiTransferCredentials.IsTemporarySsid(WifiTransferCredentials.CreateRandom().Ssid));
        Assert.True(WifiTransferCredentials.IsTemporarySsid(WifiProbeCredentials.CreateRandom().Ssid));
        Assert.True(WifiTransferCredentials.IsTemporarySsid("DIRECT-cp-OLD00001"));
        Assert.False(WifiTransferCredentials.IsTemporarySsid("UserHomeHotspot"));
        Assert.False(WifiTransferCredentials.IsTemporarySsid("DIRECT-cp-"));
        Assert.False(WifiTransferCredentials.IsTemporarySsid("DIRECT-cp-short"));
        Assert.False(WifiTransferCredentials.IsTemporarySsid("DIRECT-cp-123456789"));
        Assert.False(WifiTransferCredentials.IsTemporarySsid("DIRECT-cp-1234!678"));
        Assert.False(WifiTransferCredentials.IsTemporarySsid(null));

        // 1. Corrupt DPAPI backup file + current Windows hotspot stuck on temporary SSID:
        //    corrupt file is preserved under another name, temp SSID is NOT saved as "original",
        //    hotspot is NOT modified, and transfer falls back to Wi-Fi Direct.
        {
            var dir = Path.Combine(tempDir, "corrupt-temp-ssid");
            Directory.CreateDirectory(dir);
            byte[] unreadableEncrypted = [0x10, 0x20, 0x30, 0x40, 0x50];
            File.WriteAllBytes(Path.Combine(dir, "hotspot-restore.dat"), unreadableEncrypted);

            var store = new HotspotConfigBackupStore(dir);
            var manager = new FakeHotspotTetheringManager(
                new HotspotAccessPointConfig("DIRECT-cp-STUCK001", "StuckTempPass123", Band: 2));
            var platform = new FakeWindowsWifiPlatform(manager);
            var logs = new ConcurrentQueue<string>();
            var host = new WindowsWifiTransferHost(logs.Enqueue, store, platform: platform, fallbackDelay: TimeSpan.Zero);

            var creds = MakeCredentials("DIRECT-cp-NEXT0099", "NextTempPass0099");
            var result = await host.StartAsync(creds, CancellationToken.None);
            try
            {
                Assert.True(result.Succeeded);
                Assert.Equal(WifiApMode.WifiDirect, result.Handle!.Mode);
                Assert.Equal(0, manager.ConfigureCallCount);
                Assert.Equal(0, manager.StartCallCount);
                Assert.False(store.Exists);

                // Corrupt file was preserved under a separate filename with identical bytes.
                var quarantined = Assert.Single(Directory.GetFiles(dir, "hotspot-restore.corrupt.*.dat"));
                Assert.Equal(unreadableEncrypted, File.ReadAllBytes(quarantined));

                Assert.Contains(logs, l => l == "wifi hotspot backup quarantined");
                Assert.Contains(logs, l => l == "wifi hotspot prepare refused reason=hotspot_current_is_temporary");
                Assert.Contains(logs, l => l == "wifi ap primary failed mode=hotspot reason=hotspot_current_is_temporary");
                AssertNoSecretOrPathInLogs(logs, dir, "hotspot-restore", "DIRECT-cp-STUCK001", "StuckTempPass123", creds.Ssid, creds.Passphrase);
            }
            finally
            {
                if (result.Handle is not null)
                    await result.Handle.DisposeAsync();
            }
        }

        // 2. DPAPI-valid but invalid/unrestorable JSON backup is also quarantined (not deleted).
        {
            var dir = Path.Combine(tempDir, "unrestorable-json");
            Directory.CreateDirectory(dir);
            var invalidJsonBytes = Encoding.UTF8.GetBytes("""{"Ssid":"","Passphrase":"short","Band":2,"TempSsid":"DIRECT-cp-BAD00001"}""");
            var encrypted = System.Security.Cryptography.ProtectedData.Protect(
                invalidJsonBytes,
                null,
                System.Security.Cryptography.DataProtectionScope.CurrentUser);
            File.WriteAllBytes(Path.Combine(dir, "hotspot-restore.dat"), encrypted);

            var logs = new List<string>();
            var store = new HotspotConfigBackupStore(dir);
            Assert.Null(store.Load(logs.Add));
            Assert.False(store.Exists);
            var quarantined = Assert.Single(Directory.GetFiles(dir, "hotspot-restore.corrupt.*.dat"));
            Assert.Equal(encrypted, File.ReadAllBytes(quarantined));
            Assert.Contains(logs, l => l == "wifi hotspot backup load error=InvalidRecord");
            Assert.Contains(logs, l => l == "wifi hotspot backup quarantined");
            AssertNoSecretOrPathInLogs(logs, dir, "hotspot-restore", "DIRECT-cp-BAD00001");
        }
    }

    [Fact]
    public async Task RestoreFailureWithSavedBandRetriesWithoutBandInAsyncSyncAndStartupPaths()
    {
        var originalWithBand = new HotspotBackupRecord("UserHomeHotspot", "OriginalUserPass123", Band: 3, TempSsid: "DIRECT-cp-BAND0001");
        var expectedBandless = new HotspotAccessPointConfig("UserHomeHotspot", "OriginalUserPass123", Band: null);

        // 1. Async teardown path (StopHotspotAndRestoreAsync)
        {
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "band-retry-async"));
            store.Save(originalWithBand);
            var manager = new FakeHotspotTetheringManager(new HotspotAccessPointConfig("DIRECT-cp-BAND0001", "TempPassBand0001", Band: 2))
            {
                IsOn = true,
                OnConfigureAsync = (config, _) =>
                    config.Band is not null
                        ? Task.FromException(new InvalidOperationException("saved band unsupported"))
                        : Task.CompletedTask,
            };
            var logs = new ConcurrentQueue<string>();
            var state = new ActiveHotspotState(manager, originalWithBand, hadPendingRestore: false, store);
            Assert.True(state.TryMarkConfigModified());

            await WindowsWifiApController.StopHotspotAndRestoreAsync(state, logs.Enqueue, "wifi transfer");

            Assert.Equal([3, null], manager.ConfiguredHistory.Select(c => c.Band).ToArray());
            Assert.Equal(expectedBandless, manager.CurrentConfig);
            Assert.False(manager.IsOn);
            Assert.False(store.Exists);
            Assert.Contains(logs, l => l == "wifi transfer hotspot restore band retry error=InvalidOperationException");
            AssertNoSecretOrPathInLogs(logs, tempDir, "UserHomeHotspot", "OriginalUserPass123", "DIRECT-cp-BAND0001");
        }

        // 2. Sync teardown path (StopHotspotAndRestoreSync)
        {
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "band-retry-sync"));
            var syncRecord = originalWithBand with { TempSsid = "DIRECT-cp-BAND0002" };
            store.Save(syncRecord);
            var manager = new FakeHotspotTetheringManager(new HotspotAccessPointConfig("DIRECT-cp-BAND0002", "TempPassBand0002", Band: 2))
            {
                IsOn = true,
                OnConfigureAsync = (config, _) =>
                    config.Band is not null
                        ? Task.FromException(new InvalidOperationException("saved band unsupported"))
                        : Task.CompletedTask,
            };
            var state = new ActiveHotspotState(manager, syncRecord, hadPendingRestore: false, store);
            Assert.True(state.TryMarkConfigModified());

            WindowsWifiApController.StopHotspotAndRestoreSync(state);

            Assert.Equal([3, null], manager.ConfiguredHistory.Select(c => c.Band).ToArray());
            Assert.Equal(expectedBandless, manager.CurrentConfig);
            Assert.False(manager.IsOn);
            Assert.False(store.Exists);
        }

        // 3. Startup restore path (TryRestorePendingHotspotConfigAsync)
        {
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "band-retry-startup"));
            var startupRecord = originalWithBand with { TempSsid = "DIRECT-cp-BAND0003" };
            store.Save(startupRecord);
            var manager = new FakeHotspotTetheringManager(new HotspotAccessPointConfig("DIRECT-cp-BAND0003", "TempPassBand0003", Band: 2))
            {
                IsOn = true,
                OnConfigureAsync = (config, _) =>
                    config.Band is not null
                        ? Task.FromException(new InvalidOperationException("saved band unsupported"))
                        : Task.CompletedTask,
            };
            var logs = new ConcurrentQueue<string>();

            await WindowsWifiApController.TryRestorePendingHotspotConfigAsync(store, () => manager, logs.Enqueue);

            Assert.Equal([3, null], manager.ConfiguredHistory.Select(c => c.Band).ToArray());
            Assert.Equal(expectedBandless, manager.CurrentConfig);
            Assert.False(manager.IsOn);
            Assert.False(store.Exists);
            Assert.Contains(logs, l => l == "wifi hotspot restore band retry error=InvalidOperationException");
            Assert.Contains(logs, l => l == "wifi hotspot config restored from previous run");
        }

        // 4. If bandless retry ALSO fails, backup MUST remain preserved.
        {
            var store = new HotspotConfigBackupStore(Path.Combine(tempDir, "band-retry-both-fail"));
            var failRecord = originalWithBand with { TempSsid = "DIRECT-cp-BAND0004" };
            store.Save(failRecord);
            var manager = new FakeHotspotTetheringManager(new HotspotAccessPointConfig("DIRECT-cp-BAND0004", "TempPassBand0004", Band: 2))
            {
                OnConfigureAsync = (_, _) => Task.FromException(new InvalidOperationException("configure always fails")),
            };
            var state = new ActiveHotspotState(manager, failRecord, hadPendingRestore: false, store);
            Assert.True(state.TryMarkConfigModified());

            await WindowsWifiApController.StopHotspotAndRestoreAsync(state, _ => { }, "wifi transfer");

            Assert.Equal([3, null], manager.ConfiguredHistory.Select(c => c.Band).ToArray());
            Assert.True(store.Exists);
        }
    }

    private static WifiTransferCredentials MakeCredentials(string ssid, string passphrase) =>
        new(Guid.NewGuid(), ssid, passphrase, new byte[32]);

    private static void AssertNoSecretOrPathInLogs(IEnumerable<string> logs, params string[] forbidden)
    {
        foreach (var line in logs)
        {
            foreach (var secret in forbidden)
            {
                if (!string.IsNullOrEmpty(secret))
                    Assert.DoesNotContain(secret, line, StringComparison.OrdinalIgnoreCase);
            }
        }
    }

    private sealed class ControlledDelay
    {
        public sealed class PendingWait(TimeSpan duration)
        {
            public TimeSpan Duration { get; } = duration;
            private readonly TaskCompletionSource tcs = new(TaskCreationOptions.RunContinuationsAsynchronously);
            public Task Task => tcs.Task;
            public void Trigger() => tcs.TrySetResult();
            public void Cancel(CancellationToken ct) => tcs.TrySetCanceled(ct);
        }

        private readonly object gate = new();
        private readonly List<PendingWait> waits = [];
        private readonly List<(TimeSpan Expected, TaskCompletionSource<PendingWait> Waiter)> waiters = [];

        public Task DelayAsync(TimeSpan duration, CancellationToken ct)
        {
            if (ct.IsCancellationRequested) return Task.FromCanceled(ct);
            var pending = new PendingWait(duration);
            ct.Register(() => pending.Cancel(ct));
            lock (gate)
            {
                waits.Add(pending);
                for (var i = waiters.Count - 1; i >= 0; i--)
                {
                    if (waiters[i].Expected == duration)
                    {
                        waiters[i].Waiter.TrySetResult(pending);
                        waiters.RemoveAt(i);
                    }
                }
            }
            return pending.Task;
        }

        public bool HasRequestedDelay(TimeSpan expected)
        {
            lock (gate)
                return waits.Any(w => w.Duration == expected);
        }

        public Task<PendingWait> WaitForRequestedDelayAsync(TimeSpan expected)
        {
            lock (gate)
            {
                var existing = waits.LastOrDefault(w => w.Duration == expected && !w.Task.IsCompleted);
                if (existing is not null)
                    return Task.FromResult(existing);
                var tcs = new TaskCompletionSource<PendingWait>(TaskCreationOptions.RunContinuationsAsynchronously);
                waiters.Add((expected, tcs));
                return tcs.Task;
            }
        }
    }

    private sealed class FakeHotspotTetheringManager(HotspotAccessPointConfig? initialConfig) : IHotspotTetheringManager
    {
        public HotspotAccessPointConfig? CurrentConfig { get; set; } = initialConfig;
        public bool IsOn { get; set; }
        public int GetCurrentCallCount { get; private set; }
        public int ConfigureCallCount { get; private set; }
        public int StartCallCount { get; private set; }
        public int StopCallCount { get; private set; }
        public List<HotspotAccessPointConfig> ConfiguredHistory { get; } = [];
        public Func<HotspotAccessPointConfig?>? OnGetCurrent { get; set; }
        public Func<HotspotAccessPointConfig, CancellationToken, Task>? OnConfigureAsync { get; set; }
        public Func<CancellationToken, Task<(bool Succeeded, string StatusName)>>? OnStartAsync { get; set; }
        public Func<CancellationToken, Task>? OnStopAsync { get; set; }
        public Func<HotspotAccessPointConfig, CancellationToken, Task<IReadOnlyList<WifiProbeBand>>>? OnQueryBandsAsync { get; set; }

        public HotspotAccessPointConfig? GetCurrentConfiguration()
        {
            GetCurrentCallCount++;
            return OnGetCurrent is not null ? OnGetCurrent() : CurrentConfig;
        }

        public async Task ConfigureAccessPointAsync(HotspotAccessPointConfig config, CancellationToken ct, bool ignoreBandErrors = false)
        {
            ConfigureCallCount++;
            ConfiguredHistory.Add(config);
            if (OnConfigureAsync is not null)
                await OnConfigureAsync(config, ct).ConfigureAwait(false);
            CurrentConfig = config;
        }

        public async Task<(bool Succeeded, string StatusName)> StartTetheringAsync(CancellationToken ct)
        {
            StartCallCount++;
            if (OnStartAsync is not null)
            {
                var res = await OnStartAsync(ct).ConfigureAwait(false);
                if (res.Succeeded) IsOn = true;
                return res;
            }
            IsOn = true;
            return (true, "Success");
        }

        public async Task StopTetheringAsync(CancellationToken ct)
        {
            StopCallCount++;
            if (OnStopAsync is not null)
                await OnStopAsync(ct).ConfigureAwait(false);
            IsOn = false;
        }

        public Task<IReadOnlyList<WifiProbeBand>> QuerySupportedBandsAsync(HotspotAccessPointConfig config, CancellationToken ct)
        {
            if (OnQueryBandsAsync is not null)
                return OnQueryBandsAsync(config, ct);
            IReadOnlyList<WifiProbeBand> bands = [WifiProbeBand.TwoPointFourGHz, WifiProbeBand.FiveGHz];
            return Task.FromResult(bands);
        }
    }

    private sealed class FakeDirectHandle(string ssid) : IWifiTransferSessionHandle
    {
        public WifiApMode Mode => WifiApMode.WifiDirect;
        public string ActualSsid { get; } = ssid;
        public string Ip => "192.168.137.1";
        public int Port => 45678;
        public Task<WifiAcceptedConnection> AcceptAsync(CancellationToken cancellationToken) =>
            Task.FromCanceled<WifiAcceptedConnection>(new CancellationToken(true));
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        public void StopSync() { }
    }

    private sealed class FakeWindowsWifiPlatform(IHotspotTetheringManager manager) : IWindowsWifiPlatform
    {
        public bool Online { get; set; } = true;
        public bool BandApiSupported { get; set; } = true;
        public Func<bool>? OnIsHotspotBandApiSupported { get; set; }
        public Func<CancellationToken, Task>? OnBindAsync { get; set; }
        public Func<WifiTransferCredentials, CancellationToken, Task<WifiApAttemptResult>>? OnTryStartWifiDirect { get; set; }
        public int HasInternetCallCount { get; private set; }
        public int AcquireHotspotCallCount { get; private set; }
        public int WifiDirectCallCount { get; private set; }

        public bool HasInternetConnection()
        {
            HasInternetCallCount++;
            return Online;
        }

        public bool IsHotspotBandApiSupported() =>
            OnIsHotspotBandApiSupported is not null ? OnIsHotspotBandApiSupported() : BandApiSupported;

        public HotspotManagerAcquireResult TryAcquireHotspotManager()
        {
            AcquireHotspotCallCount++;
            return manager.IsOn
                ? HotspotManagerAcquireResult.Failure("hotspot_already_on")
                : HotspotManagerAcquireResult.Success(manager);
        }

        public async Task<(TcpListener Listener, IPAddress Address)> BindVirtualAdapterListenerAsync(
            TimeSpan waitTimeout,
            Action<string> log,
            string logPrefix,
            bool requireProtocolValidLocalIpv4,
            CancellationToken ct)
        {
            if (OnBindAsync is not null)
                await OnBindAsync(ct).ConfigureAwait(false);
            var tcp = new TcpListener(IPAddress.Loopback, 0);
            tcp.Start(1);
            return (tcp, IPAddress.Loopback);
        }

        public Task<WifiApAttemptResult>? TryStartWifiDirectOverride(WifiTransferCredentials credentials, CancellationToken ct)
        {
            WifiDirectCallCount++;
            if (OnTryStartWifiDirect is not null)
                return OnTryStartWifiDirect(credentials, ct);
            return Task.FromResult(WifiApAttemptResult.Success(new FakeDirectHandle(credentials.Ssid)));
        }
    }

    private sealed class FailingSaveBackupStore(HotspotBackupRecord? existing) : IHotspotConfigBackupStore
    {
        private HotspotBackupRecord? record = existing;
        public bool Exists => record is not null;
        public void Save(HotspotBackupRecord value) => throw new IOException("disk full");
        public HotspotBackupRecord? Load(Action<string>? log = null) => record;
        public HotspotBackupPrepareOutcome PrepareForSession(HotspotAccessPointConfig? currentConfig, string tempSsid, Action<string>? log = null)
        {
            log?.Invoke("wifi hotspot backup save error=IOException");
            return HotspotBackupPrepareOutcome.Failure("hotspot_backup_save_failed");
        }
        public bool ClearIfTempSsidMatches(string expectedTempSsid)
        {
            if (record is null || !string.Equals(record.TempSsid, expectedTempSsid, StringComparison.Ordinal))
                return false;
            record = null;
            return true;
        }
        public void Clear() => record = null;
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
