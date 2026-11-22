using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using global::Windows.Devices.WiFiDirect;
using global::Windows.Foundation.Metadata;
using global::Windows.Networking.Connectivity;
using global::Windows.Networking.NetworkOperators;
using global::Windows.Security.Credentials;

namespace ClipboardPlus.Windows.Infrastructure;

internal sealed record HotspotAccessPointConfig(
    string Ssid,
    string Passphrase,
    int? Band)
{
    public bool IsRestorable =>
        !string.IsNullOrEmpty(Ssid) &&
        !string.IsNullOrEmpty(Passphrase) &&
        Passphrase.Length >= 8;

    // Never expose SSID or passphrase in logs/formatting.
    public override string ToString() => "HotspotAccessPointConfig { Redacted = true }";
}

internal sealed record HotspotBackupPrepareOutcome(
    bool Succeeded,
    HotspotBackupRecord? Record,
    bool PreservedExistingBackup,
    string? FailureCode)
{
    public static HotspotBackupPrepareOutcome Success(HotspotBackupRecord record, bool preservedExistingBackup) =>
        new(true, record, preservedExistingBackup, null);

    public static HotspotBackupPrepareOutcome Failure(string failureCode) =>
        new(false, null, false, failureCode);
}

internal interface IHotspotConfigBackupStore
{
    bool Exists { get; }
    void Save(HotspotBackupRecord record);
    HotspotBackupRecord? Load(Action<string>? log = null);
    HotspotBackupPrepareOutcome PrepareForSession(
        HotspotAccessPointConfig? currentConfig,
        string tempSsid,
        Action<string>? log = null);
    bool ClearIfTempSsidMatches(string expectedTempSsid);
    void Clear();
}

internal interface IHotspotTetheringManager
{
    bool IsOn { get; }
    HotspotAccessPointConfig? GetCurrentConfiguration();
    Task ConfigureAccessPointAsync(HotspotAccessPointConfig config, CancellationToken ct, bool ignoreBandErrors = false);
    Task<(bool Succeeded, string StatusName)> StartTetheringAsync(CancellationToken ct);
    Task StopTetheringAsync(CancellationToken ct);
    Task<IReadOnlyList<WifiProbeBand>> QuerySupportedBandsAsync(HotspotAccessPointConfig config, CancellationToken ct);
}

internal sealed class WinRtHotspotTetheringManager(NetworkOperatorTetheringManager manager) : IHotspotTetheringManager
{
    public bool IsOn => manager.TetheringOperationalState == TetheringOperationalState.On;

    public HotspotAccessPointConfig? GetCurrentConfiguration()
    {
        var current = manager.GetCurrentAccessPointConfiguration();
        if (current is null)
            return null;

        int? band = null;
        if (WindowsWifiApController.IsHotspotBandApiSupported())
        {
            try { band = (int)current.Band; }
            catch { band = null; }
        }
        return new HotspotAccessPointConfig(current.Ssid ?? "", current.Passphrase ?? "", band);
    }

    public Task ConfigureAccessPointAsync(HotspotAccessPointConfig config, CancellationToken ct, bool ignoreBandErrors = false)
    {
        var winrt = ToWinRtConfig(config, ignoreBandErrors);
        return manager.ConfigureAccessPointAsync(winrt).AsTask(ct);
    }

    public async Task<(bool Succeeded, string StatusName)> StartTetheringAsync(CancellationToken ct)
    {
        var result = await manager.StartTetheringAsync().AsTask(ct).ConfigureAwait(false);
        if (result.Status == TetheringOperationStatus.Success)
            return (true, nameof(TetheringOperationStatus.Success));
        var statusName = WifiProbeText.FormatTetheringOperationStatus((int)result.Status, result.Status.ToString());
        return (false, statusName);
    }

    public Task StopTetheringAsync(CancellationToken ct) =>
        manager.StopTetheringAsync().AsTask(ct);

    public Task<IReadOnlyList<WifiProbeBand>> QuerySupportedBandsAsync(HotspotAccessPointConfig config, CancellationToken ct)
    {
        var winrt = ToWinRtConfig(config, ignoreBandErrors: true);
        return WindowsWifiApController.QuerySupportedHotspotBandsAsync(winrt, ct);
    }

    private static NetworkOperatorTetheringAccessPointConfiguration ToWinRtConfig(
        HotspotAccessPointConfig config,
        bool ignoreBandErrors)
    {
        var winrt = new NetworkOperatorTetheringAccessPointConfiguration
        {
            Ssid = config.Ssid,
            Passphrase = config.Passphrase,
        };
        if (config.Band is int band && WindowsWifiApController.IsHotspotBandApiSupported())
        {
            if (ignoreBandErrors)
            {
                try { winrt.Band = (TetheringWiFiBand)band; }
                catch { }
            }
            else
            {
                winrt.Band = (TetheringWiFiBand)band;
            }
        }
        return winrt;
    }
}

/// <summary>
/// Persists the user's previous Windows Mobile Hotspot configuration protected with DPAPI
/// so it can be restored even if the app crashes while a temporary hotspot is active.
/// </summary>
internal sealed class HotspotConfigBackupStore : IHotspotConfigBackupStore
{
    private const string FileName = "hotspot-restore.dat";
    private readonly string directory;
    private readonly string filePath;
    private readonly object gate = new();

    public HotspotConfigBackupStore(string? directory = null)
    {
        this.directory = string.IsNullOrWhiteSpace(directory) ? LocalStore.Root : Path.GetFullPath(directory);
        filePath = Path.Combine(this.directory, FileName);
    }

    public bool Exists
    {
        get { lock (gate) return File.Exists(filePath); }
    }

    public void Save(HotspotBackupRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);
        if (!record.IsRestorable) return;

        lock (gate)
        {
            // Never overwrite a pending backup's original config with one of its own temporary SSIDs.
            var existing = LoadLocked(log: null, out var loadIoFailed);
            if (loadIoFailed)
                throw new IOException("Existing hotspot backup could not be read.");
            var toSave = existing is not null && existing.ShouldRestoreForCurrentSsid(record.Ssid)
                ? existing.WithAdditionalTempSsid(record.TempSsid)
                : record;
            SaveLocked(toSave);
        }
    }

    public HotspotBackupPrepareOutcome PrepareForSession(
        HotspotAccessPointConfig? currentConfig,
        string tempSsid,
        Action<string>? log = null)
    {
        if (string.IsNullOrEmpty(tempSsid))
            throw new ArgumentException("Temporary SSID is required.", nameof(tempSsid));

        lock (gate)
        {
            var existing = LoadLocked(log, out var loadIoFailed);
            if (loadIoFailed)
                return HotspotBackupPrepareOutcome.Failure("hotspot_backup_save_failed");

            if (currentConfig is null || string.IsNullOrEmpty(currentConfig.Ssid))
                return HotspotBackupPrepareOutcome.Failure("hotspot_config_unreadable");

            HotspotBackupRecord recordToSave;
            bool preservedExisting;

            if (existing is not null && existing.ShouldRestoreForCurrentSsid(currentConfig.Ssid))
            {
                // Current hotspot SSID matches one of our recorded temporary SSIDs, not the user's setting.
                // Preserve the original user configuration and add the new temporary SSID.
                recordToSave = existing.WithAdditionalTempSsid(tempSsid);
                preservedExisting = true;
            }
            else
            {
                if (!currentConfig.IsRestorable)
                    return HotspotBackupPrepareOutcome.Failure("hotspot_config_unreadable");

                if (WifiTransferCredentials.IsTemporarySsid(currentConfig.Ssid))
                {
                    log?.Invoke("wifi hotspot prepare refused reason=hotspot_current_is_temporary");
                    return HotspotBackupPrepareOutcome.Failure("hotspot_current_is_temporary");
                }

                recordToSave = new HotspotBackupRecord(
                    currentConfig.Ssid,
                    currentConfig.Passphrase,
                    currentConfig.Band,
                    tempSsid);
                preservedExisting = false;
            }

            try
            {
                SaveLocked(recordToSave);
                return HotspotBackupPrepareOutcome.Success(recordToSave, preservedExisting);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CryptographicException or NotSupportedException)
            {
                log?.Invoke($"wifi hotspot backup save error={ex.GetType().Name}");
                return HotspotBackupPrepareOutcome.Failure("hotspot_backup_save_failed");
            }
        }
    }

    public HotspotBackupRecord? Load(Action<string>? log = null)
    {
        lock (gate) return LoadLocked(log, out _);
    }

    public bool ClearIfTempSsidMatches(string expectedTempSsid)
    {
        if (string.IsNullOrEmpty(expectedTempSsid))
            return false;

        lock (gate)
        {
            if (!File.Exists(filePath))
                return false;

            byte[]? plaintext = null;
            try
            {
                var encrypted = File.ReadAllBytes(filePath);
                plaintext = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
                var record = JsonSerializer.Deserialize<HotspotBackupRecord>(plaintext);
                if (record is null || !string.Equals(record.TempSsid, expectedTempSsid, StringComparison.Ordinal))
                    return false;

                ClearLocked();
                return true;
            }
            catch (Exception ex) when (ex is CryptographicException or JsonException or IOException or UnauthorizedAccessException)
            {
                return false;
            }
            finally
            {
                if (plaintext is not null)
                    CryptographicOperations.ZeroMemory(plaintext);
            }
        }
    }

    public void Clear()
    {
        lock (gate) ClearLocked();
    }

    private void SaveLocked(HotspotBackupRecord record)
    {
        Directory.CreateDirectory(directory);
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(record);
        try
        {
            var protectedBytes = ProtectedData.Protect(plaintext, null, DataProtectionScope.CurrentUser);
            var tempPath = Path.Combine(directory, $"hotspot-restore.{Guid.NewGuid():N}.tmp");
            try
            {
                using (var stream = new FileStream(tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    stream.Write(protectedBytes);
                    stream.Flush(true);
                }
                File.Move(tempPath, filePath, overwrite: true);
            }
            catch
            {
                try { File.Delete(tempPath); } catch { }
                throw;
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    private HotspotBackupRecord? LoadLocked(Action<string>? log, out bool ioFailed)
    {
        ioFailed = false;
        if (!File.Exists(filePath)) return null;
        byte[]? plaintext = null;
        try
        {
            var encrypted = File.ReadAllBytes(filePath);
            plaintext = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
            var record = JsonSerializer.Deserialize<HotspotBackupRecord>(plaintext);
            if (record is null || !record.IsRestorable)
            {
                log?.Invoke("wifi hotspot backup load error=InvalidRecord");
                if (!QuarantineCorruptLocked(log))
                    ioFailed = true;
                return null;
            }
            return record;
        }
        catch (Exception ex) when (ex is CryptographicException or JsonException)
        {
            log?.Invoke($"wifi hotspot backup load error={ex.GetType().Name}");
            if (!QuarantineCorruptLocked(log))
                ioFailed = true;
            return null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log?.Invoke($"wifi hotspot backup load error={ex.GetType().Name}");
            ioFailed = true;
            return null;
        }
        finally
        {
            if (plaintext is not null)
                CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    private bool QuarantineCorruptLocked(Action<string>? log)
    {
        if (!File.Exists(filePath))
            return true;
        try
        {
            var stamp = DateTimeOffset.UtcNow.ToString("yyyyMMddHHmmssfff", System.Globalization.CultureInfo.InvariantCulture);
            var quarantinePath = Path.Combine(directory, $"hotspot-restore.corrupt.{stamp}.{Guid.NewGuid():N}.dat");
            File.Move(filePath, quarantinePath, overwrite: false);
            log?.Invoke("wifi hotspot backup quarantined");
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log?.Invoke($"wifi hotspot backup quarantine error={ex.GetType().Name}");
            return false;
        }
    }

    private void ClearLocked()
    {
        try
        {
            if (File.Exists(filePath))
                File.Delete(filePath);
        }
        catch { }
    }
}

/// <summary>
/// Process-wide hardware slot ensuring production Wi-Fi transfers and the developer Stage A probe
/// never fight over Windows' single virtual AP interface at the same time.
/// </summary>
internal static class WindowsWifiHardwareLease
{
    private static string? activeOwner;

    public static bool TryAcquire(string owner) =>
        Interlocked.CompareExchange(ref activeOwner, owner, null) is null;

    public static void Release(string owner) =>
        Interlocked.CompareExchange(ref activeOwner, null, owner);

    public static string? CurrentOwner => Volatile.Read(ref activeOwner);
}

internal sealed class ActiveHotspotState(
    IHotspotTetheringManager manager,
    HotspotBackupRecord restoreRecord,
    bool hadPendingRestore,
    IHotspotConfigBackupStore backupStore)
{
    private readonly object gate = new();
    private bool configModified;
    private bool teardownStarted;
    private int inFlightMutations;

    public IHotspotTetheringManager Manager { get; } = manager;
    public HotspotBackupRecord RestoreRecord { get; } = restoreRecord;
    public bool HadPendingRestore { get; } = hadPendingRestore;
    public IHotspotConfigBackupStore BackupStore { get; } = backupStore;

    public bool ConfigModified
    {
        get { lock (gate) return configModified; }
    }

    public bool IsTeardownStarted
    {
        get { lock (gate) return teardownStarted; }
    }

    public bool HasInFlightMutation
    {
        get { lock (gate) return inFlightMutations > 0; }
    }

    public bool TryMarkConfigModified()
    {
        lock (gate)
        {
            if (teardownStarted)
                return false;
            configModified = true;
            return true;
        }
    }

    public bool TryStartConfigure(
        HotspotAccessPointConfig config,
        CancellationToken ct,
        out Task task,
        bool ignoreBandErrors = false)
    {
        lock (gate)
        {
            if (teardownStarted)
            {
                task = Task.CompletedTask;
                return false;
            }
            configModified = true;
            inFlightMutations++;
        }

        try
        {
            var op = Manager.ConfigureAccessPointAsync(config, ct, ignoreBandErrors);
            AttachMutationCompletion(op);
            task = op;
            return true;
        }
        catch
        {
            EndMutation();
            throw;
        }
    }

    public bool TryStartTethering(
        CancellationToken ct,
        out Task<(bool Succeeded, string StatusName)> task)
    {
        lock (gate)
        {
            if (teardownStarted)
            {
                task = Task.FromResult((false, "host_stopped"));
                return false;
            }
            inFlightMutations++;
        }

        try
        {
            var op = Manager.StartTetheringAsync(ct);
            AttachMutationCompletion(op);
            task = op;
            return true;
        }
        catch
        {
            EndMutation();
            throw;
        }
    }

    public bool TryBeginTeardown(out bool needsRestore, out bool hadInFlightMutation)
    {
        lock (gate)
        {
            if (teardownStarted)
            {
                needsRestore = false;
                hadInFlightMutation = false;
                return false;
            }
            teardownStarted = true;
            needsRestore = configModified || HadPendingRestore;
            hadInFlightMutation = inFlightMutations > 0;
            return true;
        }
    }

    private void AttachMutationCompletion(Task op)
    {
        if (op.IsCompleted)
        {
            EndMutation();
            return;
        }

        _ = op.ContinueWith(
            static (_, s) => ((ActiveHotspotState)s!).EndMutation(),
            this,
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private void EndMutation()
    {
        lock (gate)
        {
            if (inFlightMutations > 0)
                inFlightMutations--;
        }
    }
}

/// <summary>
/// Shared WinRT/WLAN primitives for creating and tearing down temporary Windows Wi-Fi APs
/// (Mobile Hotspot 5GHz/Auto and Wi-Fi Direct Legacy), querying station radio band/channel,
/// binding a TcpListener strictly to the virtual AP adapter IPv4, and safely restoring OS settings.
/// </summary>
internal static class WindowsWifiApController
{
    private const string TetheringConfigTypeName =
        "Windows.Networking.NetworkOperators.NetworkOperatorTetheringAccessPointConfiguration";
    private const string TetheringBandTypeName =
        "Windows.Networking.NetworkOperators.TetheringWiFiBand";
    // SixGigahertz (= 3) was added in UniversalApiContract v16 (Windows 11 23H2/24H2) and is not in the 22621 SDK enum.
    private const TetheringWiFiBand SixGigahertzBand = (TetheringWiFiBand)3;

    private const uint WlanInterfaceStateConnected = 1;
    private const uint WlanIntfOpcodeChannelNumber = 8;
    private const uint WlanIntfOpcodeRealtimeConnectionQuality = 19;
    private const int WlanInterfaceInfoListHeaderBytes = 8;
    private const int WlanInterfaceInfoBytes = 532;

    internal static bool IsHotspotBandApiSupported()
    {
        try
        {
            return OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041) &&
                ApiInformation.IsTypePresent(TetheringBandTypeName) &&
                ApiInformation.IsPropertyPresent(TetheringConfigTypeName, "Band") &&
                (ApiInformation.IsMethodPresent(TetheringConfigTypeName, "IsBandSupportedAsync", 1) ||
                 ApiInformation.IsMethodPresent(TetheringConfigTypeName, "IsBandSupported", 1));
        }
        catch
        {
            return false;
        }
    }

    internal static bool IsHotspotSixGigahertzSupported()
    {
        try
        {
            return IsHotspotBandApiSupported() &&
                ApiInformation.IsEnumNamedValuePresent(TetheringBandTypeName, "SixGigahertz");
        }
        catch
        {
            return false;
        }
    }

    internal static bool HasInternetConnection()
    {
        try
        {
            var profile = NetworkInformation.GetInternetConnectionProfile();
            return profile is not null &&
                profile.GetNetworkConnectivityLevel() == NetworkConnectivityLevel.InternetAccess;
        }
        catch
        {
            return false;
        }
    }

    internal static TetheringWiFiBand ToWinRtBand(WifiProbeBand band) => band switch
    {
        WifiProbeBand.Auto => TetheringWiFiBand.Auto,
        WifiProbeBand.TwoPointFourGHz => TetheringWiFiBand.TwoPointFourGigahertz,
        WifiProbeBand.FiveGHz => TetheringWiFiBand.FiveGigahertz,
        WifiProbeBand.SixGHz => SixGigahertzBand,
        _ => TetheringWiFiBand.Auto,
    };

    internal static async Task<IReadOnlyList<WifiProbeBand>> QuerySupportedHotspotBandsAsync(
        NetworkOperatorTetheringAccessPointConfiguration config,
        CancellationToken ct)
    {
        var candidates = new List<WifiProbeBand>
        {
            WifiProbeBand.TwoPointFourGHz,
            WifiProbeBand.FiveGHz,
        };
        if (IsHotspotSixGigahertzSupported())
            candidates.Add(WifiProbeBand.SixGHz);

        var hasAsync = ApiInformation.IsMethodPresent(TetheringConfigTypeName, "IsBandSupportedAsync", 1);
        var hasSync = ApiInformation.IsMethodPresent(TetheringConfigTypeName, "IsBandSupported", 1);
        var supported = new List<WifiProbeBand>(candidates.Count);

        foreach (var candidate in candidates)
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                var winrtBand = ToWinRtBand(candidate);
                var ok = hasAsync
                    ? await config.IsBandSupportedAsync(winrtBand).AsTask(ct).ConfigureAwait(false)
                    : hasSync && config.IsBandSupported(winrtBand);
                if (ok)
                    supported.Add(candidate);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch
            {
            }
        }

        return supported;
    }

    internal static readonly TimeSpan SyncStopDefaultStepTimeout = TimeSpan.FromSeconds(1.5);
    internal static readonly TimeSpan EmergencyStopStepTimeout = TimeSpan.FromMilliseconds(750);

    internal static bool CanRestoreAccessPointConfiguration(NetworkOperatorTetheringAccessPointConfiguration? config) =>
        config is not null &&
        !string.IsNullOrEmpty(config.Ssid) &&
        !string.IsNullOrEmpty(config.Passphrase) &&
        config.Passphrase.Length >= 8;

    internal static HotspotBackupRecord? CreateBackupRecord(
        NetworkOperatorTetheringAccessPointConfiguration? previousConfig,
        string tempSsid)
    {
        if (!CanRestoreAccessPointConfiguration(previousConfig))
            return null;

        int? previousBand = null;
        if (IsHotspotBandApiSupported())
        {
            try { previousBand = (int)previousConfig!.Band; }
            catch { previousBand = null; }
        }
        return new HotspotBackupRecord(previousConfig!.Ssid, previousConfig.Passphrase, previousBand, tempSsid);
    }

    private enum SyncConfigureOutcome { Succeeded, Failed, TimedOut }

    private static async Task RestoreAccessPointConfigurationAsync(
        IHotspotTetheringManager manager,
        HotspotBackupRecord record,
        Action<string> log,
        string logPrefix,
        CancellationToken ct)
    {
        var restoreConfig = new HotspotAccessPointConfig(record.Ssid, record.Passphrase, record.Band);
        try
        {
            await manager.ConfigureAccessPointAsync(restoreConfig, ct, ignoreBandErrors: true).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex) when (record.Band is not null)
        {
            log($"{logPrefix} hotspot restore band retry error={ex.GetType().Name}");
            await manager.ConfigureAccessPointAsync(restoreConfig with { Band = null }, ct, ignoreBandErrors: true).ConfigureAwait(false);
        }
    }

    private static SyncConfigureOutcome RunConfigureSync(
        IHotspotTetheringManager manager,
        HotspotAccessPointConfig config,
        TimeSpan budget,
        Func<Task, TimeSpan, bool> wait)
    {
        Task configTask;
        try
        {
            configTask = manager.ConfigureAccessPointAsync(config, CancellationToken.None, ignoreBandErrors: true);
        }
        catch
        {
            return SyncConfigureOutcome.Failed;
        }

        bool completed;
        try
        {
            completed = wait(configTask, budget);
        }
        catch
        {
            WifiStepTimeout.ObserveSilently(configTask);
            return SyncConfigureOutcome.Failed;
        }

        if (!completed)
        {
            WifiStepTimeout.ObserveSilently(configTask);
            return SyncConfigureOutcome.TimedOut;
        }

        if (configTask.IsCompletedSuccessfully)
            return SyncConfigureOutcome.Succeeded;

        WifiStepTimeout.ObserveSilently(configTask);
        return SyncConfigureOutcome.Failed;
    }

    internal static async Task StopHotspotAndRestoreAsync(
        ActiveHotspotState state,
        Action<string> log,
        string logPrefix,
        TimeSpan? timeout = null,
        Func<TimeSpan, CancellationToken, Task>? delayAsync = null)
    {
        if (!state.TryBeginTeardown(out var needsRestore, out var hadInFlightMutation))
            return;

        var restored = !needsRestore;
        try
        {
            var budget = timeout ?? TimeSpan.FromSeconds(4);
            var completedRestore = await WifiStepTimeout.RunAsync(
                async stepCt =>
                {
                    if (state.Manager.IsOn)
                        await state.Manager.StopTetheringAsync(stepCt).ConfigureAwait(false);

                    if (!needsRestore)
                        return true;

                    if (!state.RestoreRecord.IsRestorable)
                        return false;

                    await RestoreAccessPointConfigurationAsync(
                        state.Manager,
                        state.RestoreRecord,
                        log,
                        logPrefix,
                        stepCt).ConfigureAwait(false);
                    return true;
                },
                budget,
                "hotspot_cleanup_timeout",
                CancellationToken.None,
                delayAsync).ConfigureAwait(false);
            restored = completedRestore;
        }
        catch (Exception ex)
        {
            log($"{logPrefix} tethering cleanup error={ex.GetType().Name}");
        }
        finally
        {
            if (restored && !hadInFlightMutation && !state.HasInFlightMutation)
                state.BackupStore.ClearIfTempSsidMatches(state.RestoreRecord.TempSsid);
        }
    }

    internal static void StopHotspotAndRestoreSync(
        ActiveHotspotState state,
        TimeSpan? stepTimeout = null,
        Func<Task, TimeSpan, bool>? waitSync = null)
    {
        if (!state.TryBeginTeardown(out var needsRestore, out var hadInFlightMutation))
            return;

        var wait = waitSync ?? WaitTaskSync;
        var budget = stepTimeout ?? SyncStopDefaultStepTimeout;
        var restored = !needsRestore;
        try
        {
            if (state.Manager.IsOn)
            {
                var stopTask = state.Manager.StopTetheringAsync(CancellationToken.None);
                var stopped = wait(stopTask, budget);
                if (!stopped)
                {
                    WifiStepTimeout.ObserveSilently(stopTask);
                    return;
                }
                if (!stopTask.IsCompletedSuccessfully)
                {
                    WifiStepTimeout.ObserveSilently(stopTask);
                    return;
                }
            }

            if (needsRestore)
            {
                if (!state.RestoreRecord.IsRestorable)
                    return;

                var restoreConfig = new HotspotAccessPointConfig(
                    state.RestoreRecord.Ssid,
                    state.RestoreRecord.Passphrase,
                    state.RestoreRecord.Band);
                var outcome = RunConfigureSync(state.Manager, restoreConfig, budget, wait);
                if (outcome == SyncConfigureOutcome.Failed && restoreConfig.Band is not null)
                    outcome = RunConfigureSync(state.Manager, restoreConfig with { Band = null }, budget, wait);
                if (outcome == SyncConfigureOutcome.Succeeded)
                    restored = true;
            }
        }
        catch
        {
            restored = false;
        }
        finally
        {
            if (restored && !hadInFlightMutation && !state.HasInFlightMutation)
                state.BackupStore.ClearIfTempSsidMatches(state.RestoreRecord.TempSsid);
        }
    }

    private static bool WaitTaskSync(Task task, TimeSpan timeout) => task.Wait(timeout);

    /// <summary>
    /// Restores Windows Mobile Hotspot settings if a previous process crashed while a temporary hotspot was active.
    /// </summary>
    internal static Task TryRestorePendingHotspotConfigAsync(
        HotspotConfigBackupStore backupStore,
        Action<string> log,
        CancellationToken cancellationToken = default) =>
        TryRestorePendingHotspotConfigAsync(
            (IHotspotConfigBackupStore)backupStore,
            TryCreateAnyTetheringManager,
            log,
            delayAsync: null,
            timeout: null,
            cancellationToken);

    internal static async Task TryRestorePendingHotspotConfigAsync(
        IHotspotConfigBackupStore backupStore,
        Func<IHotspotTetheringManager?> createAnyManager,
        Action<string> log,
        Func<TimeSpan, CancellationToken, Task>? delayAsync = null,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        var backup = backupStore.Load(log);
        if (backup is null)
            return;

        IHotspotTetheringManager? manager;
        try
        {
            manager = createAnyManager();
        }
        catch (Exception ex)
        {
            log($"wifi hotspot restore error={ex.GetType().Name}");
            return;
        }
        if (manager is null)
            return; // Offline at startup; keep backup so a later online launch can restore it.

        try
        {
            var current = manager.GetCurrentConfiguration();
            if (current is null || string.IsNullOrEmpty(current.Ssid))
                return; // Current config unreadable; keep backup for a later attempt.

            if (!backup.ShouldRestoreForCurrentSsid(current.Ssid))
            {
                backupStore.ClearIfTempSsidMatches(backup.TempSsid);
                return;
            }

            var budget = timeout ?? TimeSpan.FromSeconds(5);
            await WifiStepTimeout.RunAsync(
                async stepCt =>
                {
                    if (manager.IsOn)
                        await manager.StopTetheringAsync(stepCt).ConfigureAwait(false);

                    await RestoreAccessPointConfigurationAsync(
                        manager,
                        backup,
                        log,
                        "wifi",
                        stepCt).ConfigureAwait(false);
                },
                budget,
                "hotspot_restore_timeout",
                cancellationToken,
                delayAsync).ConfigureAwait(false);

            backupStore.ClearIfTempSsidMatches(backup.TempSsid);
            log("wifi hotspot config restored from previous run");
        }
        catch (Exception ex)
        {
            log($"wifi hotspot restore error={ex.GetType().Name}");
        }
    }

    private static IHotspotTetheringManager? TryCreateAnyTetheringManager()
    {
        try
        {
            var internet = NetworkInformation.GetInternetConnectionProfile();
            if (internet is not null)
            {
                try { return new WinRtHotspotTetheringManager(NetworkOperatorTetheringManager.CreateFromConnectionProfile(internet)); }
                catch { }
            }
            foreach (var profile in NetworkInformation.GetConnectionProfiles())
            {
                try { return new WinRtHotspotTetheringManager(NetworkOperatorTetheringManager.CreateFromConnectionProfile(profile)); }
                catch { }
            }
        }
        catch { }
        return null;
    }

    internal static async Task<(TcpListener Listener, IPAddress Address)> BindVirtualAdapterListenerAsync(
        TimeSpan waitTimeout,
        Action<string> log,
        string logPrefix,
        bool requireProtocolValidLocalIpv4,
        CancellationToken ct)
    {
        var waitClock = Stopwatch.StartNew();
        var apipaThreshold = waitTimeout < TimeSpan.FromSeconds(4)
            ? TimeSpan.FromMilliseconds(waitTimeout.TotalMilliseconds * 0.5)
            : TimeSpan.FromSeconds(2);
        var nonUpThreshold = waitTimeout < TimeSpan.FromSeconds(5)
            ? TimeSpan.FromMilliseconds(waitTimeout.TotalMilliseconds * 0.75)
            : TimeSpan.FromSeconds(3.5);
        while (waitClock.Elapsed < waitTimeout)
        {
            ct.ThrowIfCancellationRequested();
            var allowApipa = waitClock.Elapsed >= apipaThreshold;
            var allowNonUp = waitClock.Elapsed >= nonUpThreshold;
            var adapters = NetworkAdapterSnapshot.CaptureSystem();
            var ip = WifiProbeIpSelector.SelectIp(adapters, allowApipa: allowApipa, allowNonUp: allowNonUp);
            if (ip is not null && (!requireProtocolValidLocalIpv4 || WifiControlMessageCodec.IsValidLocalIpv4(ip.ToString())))
            {
                try
                {
                    var tcp = new TcpListener(ip, 0);
                    tcp.Start(1);
                    return (tcp, ip);
                }
                catch (SocketException ex)
                {
                    log($"{logPrefix} bind retry socketError={ex.SocketErrorCode}");
                }
            }
            await Task.Delay(150, ct).ConfigureAwait(false);
        }

        throw new InvalidOperationException("VirtualAdapterIpNotFound");
    }

    internal static WifiStationRadioInfo QueryStationRadioInfo()
    {
        try
        {
            if (WlanOpenHandle(2, 0, out _, out var handle) != 0 || handle == 0)
                return WifiStationRadioInfo.Disconnected;

            try
            {
                if (WlanEnumInterfaces(handle, 0, out var listPtr) != 0 || listPtr == 0)
                    return WifiStationRadioInfo.Disconnected;

                try
                {
                    var count = unchecked((uint)Marshal.ReadInt32(listPtr, 0));
                    for (uint i = 0; i < count; i++)
                    {
                        var itemPtr = listPtr + WlanInterfaceInfoListHeaderBytes + (nint)(i * WlanInterfaceInfoBytes);
                        var info = Marshal.PtrToStructure<WlanInterfaceInfoRaw>(itemPtr);
                        if (info.State != WlanInterfaceStateConnected)
                            continue;

                        var guid = info.InterfaceGuid;
                        var channel = QueryWlanChannel(handle, ref guid);
                        var freqMhz = QueryWlanCenterFrequencyMhz(handle, ref guid);
                        return WifiStationRadioInfo.FromChannelAndFrequency(channel, freqMhz);
                    }
                    return WifiStationRadioInfo.Disconnected;
                }
                finally
                {
                    WlanFreeMemory(listPtr);
                }
            }
            finally
            {
                _ = WlanCloseHandle(handle, 0);
            }
        }
        catch
        {
            return WifiStationRadioInfo.Disconnected;
        }
    }

    private static int? QueryWlanChannel(nint handle, ref Guid interfaceGuid)
    {
        if (WlanQueryInterface(handle, ref interfaceGuid, WlanIntfOpcodeChannelNumber, 0, out var size, out var dataPtr, out _) != 0 ||
            dataPtr == 0)
            return null;

        try
        {
            if (size < sizeof(uint))
                return null;
            var raw = unchecked((uint)Marshal.ReadInt32(dataPtr, 0));
            return raw is > 0 and <= int.MaxValue ? (int)raw : null;
        }
        finally
        {
            WlanFreeMemory(dataPtr);
        }
    }

    private static int? QueryWlanCenterFrequencyMhz(nint handle, ref Guid interfaceGuid)
    {
        if (WlanQueryInterface(handle, ref interfaceGuid, WlanIntfOpcodeRealtimeConnectionQuality, 0, out var size, out var dataPtr, out _) != 0 ||
            dataPtr == 0)
            return null;

        try
        {
            if (size < (uint)Marshal.SizeOf<WlanRealtimeConnectionQualityHeader>())
                return null;
            var header = Marshal.PtrToStructure<WlanRealtimeConnectionQualityHeader>(dataPtr);
            if (header.NumLinks == 0)
                return null;
            var freq = header.ChannelCenterFrequencyMhz;
            return freq is > 0 and <= int.MaxValue ? (int)freq : null;
        }
        finally
        {
            WlanFreeMemory(dataPtr);
        }
    }

    [StructLayout(LayoutKind.Explicit, Size = WlanInterfaceInfoBytes)]
    private struct WlanInterfaceInfoRaw
    {
        [FieldOffset(0)] public Guid InterfaceGuid;
        [FieldOffset(528)] public uint State;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WlanRealtimeConnectionQualityHeader
    {
        public uint Dot11PhyType;
        public uint LinkQuality;
        public uint RxRate;
        public uint TxRate;
        public int IsMloConnection;
        public uint NumLinks;
        public byte LinkId;
        public uint ChannelCenterFrequencyMhz;
        public uint Bandwidth;
        public int Rssi;
    }

    [DllImport("wlanapi.dll")]
    private static extern uint WlanOpenHandle(
        uint dwClientVersion,
        nint pReserved,
        out uint pdwNegotiatedVersion,
        out nint phClientHandle);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanCloseHandle(nint hClientHandle, nint pReserved);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanEnumInterfaces(
        nint hClientHandle,
        nint pReserved,
        out nint ppInterfaceList);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanQueryInterface(
        nint hClientHandle,
        ref Guid pInterfaceGuid,
        uint opCode,
        nint pReserved,
        out uint pdwDataSize,
        out nint ppData,
        out uint pWlanOpcodeValueType);

    [DllImport("wlanapi.dll")]
    private static extern void WlanFreeMemory(nint pMemory);
}
