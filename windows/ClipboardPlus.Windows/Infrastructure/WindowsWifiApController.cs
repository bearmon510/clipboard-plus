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

/// <summary>
/// Persists the user's previous Windows Mobile Hotspot configuration protected with DPAPI
/// so it can be restored even if the app crashes while a temporary hotspot is active.
/// </summary>
internal sealed class HotspotConfigBackupStore
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
    }

    public HotspotBackupRecord? Load(Action<string>? log = null)
    {
        lock (gate)
        {
            if (!File.Exists(filePath)) return null;
            byte[]? plaintext = null;
            try
            {
                var encrypted = File.ReadAllBytes(filePath);
                plaintext = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
                var record = JsonSerializer.Deserialize<HotspotBackupRecord>(plaintext);
                if (record is null || !record.IsRestorable)
                {
                    ClearLocked();
                    return null;
                }
                return record;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CryptographicException or JsonException)
            {
                log?.Invoke($"wifi hotspot backup load error={ex.GetType().Name}");
                ClearLocked();
                return null;
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
    NetworkOperatorTetheringManager manager,
    NetworkOperatorTetheringAccessPointConfiguration? previousConfig,
    bool configModified,
    HotspotConfigBackupStore backupStore)
{
    public NetworkOperatorTetheringManager Manager { get; } = manager;
    public NetworkOperatorTetheringAccessPointConfiguration? PreviousConfig { get; } = previousConfig;
    public bool ConfigModified { get; set; } = configModified;
    public HotspotConfigBackupStore BackupStore { get; } = backupStore;
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

    internal static async Task StopHotspotAndRestoreAsync(ActiveHotspotState state, Action<string> log, string logPrefix)
    {
        var restored = !state.ConfigModified || !CanRestoreAccessPointConfiguration(state.PreviousConfig);
        try
        {
            using var stopTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(4));
            if (state.Manager.TetheringOperationalState == TetheringOperationalState.On)
                await state.Manager.StopTetheringAsync().AsTask(stopTimeout.Token).ConfigureAwait(false);
            if (state.ConfigModified && CanRestoreAccessPointConfiguration(state.PreviousConfig))
            {
                await state.Manager.ConfigureAccessPointAsync(state.PreviousConfig!).AsTask(stopTimeout.Token).ConfigureAwait(false);
                restored = true;
            }
        }
        catch (Exception ex)
        {
            log($"{logPrefix} tethering cleanup error={ex.GetType().Name}");
        }
        finally
        {
            if (restored)
                state.BackupStore.Clear();
        }
    }

    internal static void StopHotspotAndRestoreSync(ActiveHotspotState state)
    {
        var restored = !state.ConfigModified || !CanRestoreAccessPointConfiguration(state.PreviousConfig);
        try
        {
            if (state.Manager.TetheringOperationalState == TetheringOperationalState.On)
                state.Manager.StopTetheringAsync().AsTask().Wait(TimeSpan.FromSeconds(1.5));
            if (state.ConfigModified && CanRestoreAccessPointConfiguration(state.PreviousConfig))
            {
                state.Manager.ConfigureAccessPointAsync(state.PreviousConfig!).AsTask().Wait(TimeSpan.FromSeconds(1.5));
                restored = true;
            }
        }
        catch { }
        finally
        {
            if (restored)
                state.BackupStore.Clear();
        }
    }

    /// <summary>
    /// Restores Windows Mobile Hotspot settings if a previous process crashed while a temporary hotspot was active.
    /// </summary>
    internal static async Task TryRestorePendingHotspotConfigAsync(
        HotspotConfigBackupStore backupStore,
        Action<string> log,
        CancellationToken cancellationToken = default)
    {
        var backup = backupStore.Load(log);
        if (backup is null)
            return;

        NetworkOperatorTetheringManager? manager = TryCreateAnyTetheringManager();
        if (manager is null)
            return; // Offline at startup; keep backup so a later online launch can restore it.

        try
        {
            var current = manager.GetCurrentAccessPointConfiguration();
            if (!backup.ShouldRestoreForCurrentSsid(current?.Ssid))
            {
                backupStore.Clear();
                return;
            }

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(5));

            if (manager.TetheringOperationalState == TetheringOperationalState.On)
                await manager.StopTetheringAsync().AsTask(timeout.Token).ConfigureAwait(false);

            var restoredConfig = new NetworkOperatorTetheringAccessPointConfiguration
            {
                Ssid = backup.Ssid,
                Passphrase = backup.Passphrase,
            };
            if (backup.Band is int savedBand && IsHotspotBandApiSupported())
            {
                try { restoredConfig.Band = (TetheringWiFiBand)savedBand; }
                catch { }
            }

            await manager.ConfigureAccessPointAsync(restoredConfig).AsTask(timeout.Token).ConfigureAwait(false);
            backupStore.Clear();
            log("wifi hotspot config restored from previous run");
        }
        catch (Exception ex)
        {
            log($"wifi hotspot restore error={ex.GetType().Name}");
        }
    }

    private static NetworkOperatorTetheringManager? TryCreateAnyTetheringManager()
    {
        try
        {
            var internet = NetworkInformation.GetInternetConnectionProfile();
            if (internet is not null)
            {
                try { return NetworkOperatorTetheringManager.CreateFromConnectionProfile(internet); }
                catch { }
            }
            foreach (var profile in NetworkInformation.GetConnectionProfiles())
            {
                try { return NetworkOperatorTetheringManager.CreateFromConnectionProfile(profile); }
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
        while (waitClock.Elapsed < waitTimeout)
        {
            ct.ThrowIfCancellationRequested();
            var allowApipa = waitClock.Elapsed >= TimeSpan.FromSeconds(2);
            var allowNonUp = waitClock.Elapsed >= TimeSpan.FromSeconds(3.5);
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
