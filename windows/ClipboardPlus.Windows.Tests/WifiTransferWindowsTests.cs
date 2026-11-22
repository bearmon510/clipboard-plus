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
        manager.OnQueryBandsAsync = (_, _) => throw new InvalidOperationException("band query failed");

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

        var platform = new FakeWindowsWifiPlatform(manager);
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
    public async Task HotspotSessionWaitsForHungStartupRestoreAndFallsBackToWifiDirectOnPrimaryTimeout()
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

        // Primary attempt times out while startup restore is still blocked -> falls back to Wi-Fi Direct without touching hotspot or backup.
        var primaryWait = await delay.WaitForRequestedDelayAsync(WifiApStarter.DefaultPrimaryAttemptTimeout).WaitAsync(TimeSpan.FromSeconds(5));
        primaryWait.Trigger();

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
        public int HasInternetCallCount { get; private set; }
        public int AcquireHotspotCallCount { get; private set; }
        public int WifiDirectCallCount { get; private set; }

        public bool HasInternetConnection()
        {
            HasInternetCallCount++;
            return Online;
        }

        public bool IsHotspotBandApiSupported() => BandApiSupported;

        public HotspotManagerAcquireResult TryAcquireHotspotManager()
        {
            AcquireHotspotCallCount++;
            return manager.IsOn
                ? HotspotManagerAcquireResult.Failure("hotspot_already_on")
                : HotspotManagerAcquireResult.Success(manager);
        }

        public Task<(TcpListener Listener, IPAddress Address)> BindVirtualAdapterListenerAsync(
            TimeSpan waitTimeout,
            Action<string> log,
            string logPrefix,
            bool requireProtocolValidLocalIpv4,
            CancellationToken ct)
        {
            var tcp = new TcpListener(IPAddress.Loopback, 0);
            tcp.Start(1);
            return Task.FromResult((tcp, IPAddress.Loopback));
        }

        public Task<WifiApAttemptResult>? TryStartWifiDirectOverride(WifiTransferCredentials credentials, CancellationToken ct)
        {
            WifiDirectCallCount++;
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
