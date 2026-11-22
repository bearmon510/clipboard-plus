using System.Net;
using System.Net.Sockets;
using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using global::Windows.Devices.WiFiDirect;
using global::Windows.Networking.Connectivity;
using global::Windows.Networking.NetworkOperators;
using global::Windows.Security.Credentials;

namespace ClipboardPlus.Windows.Infrastructure;

internal sealed record HotspotManagerAcquireResult(
    IHotspotTetheringManager? Manager,
    string? FailureCode)
{
    public static HotspotManagerAcquireResult Success(IHotspotTetheringManager manager) => new(manager, null);
    public static HotspotManagerAcquireResult Failure(string code) => new(null, code);
}

internal interface IWindowsWifiPlatform
{
    bool HasInternetConnection();
    bool IsHotspotBandApiSupported();
    HotspotManagerAcquireResult TryAcquireHotspotManager();
    Task<(TcpListener Listener, IPAddress Address)> BindVirtualAdapterListenerAsync(
        TimeSpan waitTimeout,
        Action<string> log,
        string logPrefix,
        bool requireProtocolValidLocalIpv4,
        CancellationToken ct);
    Task<WifiApAttemptResult>? TryStartWifiDirectOverride(
        WifiTransferCredentials credentials,
        CancellationToken ct) => null;
}

internal sealed class ProductionWindowsWifiPlatform : IWindowsWifiPlatform
{
    public static readonly ProductionWindowsWifiPlatform Instance = new();

    public bool HasInternetConnection() => WindowsWifiApController.HasInternetConnection();

    public bool IsHotspotBandApiSupported() => WindowsWifiApController.IsHotspotBandApiSupported();

    public HotspotManagerAcquireResult TryAcquireHotspotManager()
    {
        var profile = NetworkInformation.GetInternetConnectionProfile();
        if (profile is null)
            return HotspotManagerAcquireResult.Failure("no_internet_profile");

        var capability = NetworkOperatorTetheringManager.GetTetheringCapabilityFromConnectionProfile(profile);
        if (capability != TetheringCapability.Enabled)
            return HotspotManagerAcquireResult.Failure($"capability_{capability}");

        var manager = NetworkOperatorTetheringManager.CreateFromConnectionProfile(profile);
        if (manager.TetheringOperationalState == TetheringOperationalState.On)
            return HotspotManagerAcquireResult.Failure("hotspot_already_on");

        return HotspotManagerAcquireResult.Success(new WinRtHotspotTetheringManager(manager));
    }

    public Task<(TcpListener Listener, IPAddress Address)> BindVirtualAdapterListenerAsync(
        TimeSpan waitTimeout,
        Action<string> log,
        string logPrefix,
        bool requireProtocolValidLocalIpv4,
        CancellationToken ct) =>
        WindowsWifiApController.BindVirtualAdapterListenerAsync(
            waitTimeout,
            log,
            logPrefix,
            requireProtocolValidLocalIpv4,
            ct);
}

/// <summary>
/// Production Windows Wi-Fi transfer host: selects 5GHz Mobile Hotspot (falling back to Auto if 5GHz
/// cannot be selected) when online, Wi-Fi Direct Legacy when offline, retries with the alternate mode
/// after a short settle delay on failure, binds TcpListener strictly to the virtual adapter IP,
/// and always restores Windows' Mobile Hotspot settings on teardown or next startup.
/// </summary>
internal sealed class WindowsWifiTransferHost(
    Action<string> log,
    IHotspotConfigBackupStore? backupStore = null,
    Task? startupRestoreTask = null,
    IWindowsWifiPlatform? platform = null,
    Func<TimeSpan, CancellationToken, Task>? delayAsync = null,
    Func<Task, TimeSpan, bool>? waitSync = null,
    TimeSpan? fallbackDelay = null,
    TimeSpan? totalStartTimeout = null,
    TimeSpan? primaryAttemptTimeout = null) : IWifiTransferHost, IWifiApBackend
{
    private const string HardwareLeaseOwner = "production";
    internal static readonly TimeSpan HotspotStartupRestoreWaitTimeout = TimeSpan.FromSeconds(5);
    internal static readonly TimeSpan StartCancelWaitTimeout = TimeSpan.FromSeconds(1);
    internal static readonly TimeSpan HotspotBandQueryTimeout = TimeSpan.FromSeconds(2);
    internal static readonly TimeSpan HotspotConfigureTimeout = TimeSpan.FromSeconds(2);
    internal static readonly TimeSpan HotspotStartTimeout = TimeSpan.FromSeconds(4);
    internal static readonly TimeSpan HotspotCleanupOnStartFailureTimeout = TimeSpan.FromSeconds(2);
    internal static readonly TimeSpan VirtualIpBindTimeout = TimeSpan.FromSeconds(3);
    internal static readonly TimeSpan DirectStartTimeout = TimeSpan.FromSeconds(3);

    private readonly IHotspotConfigBackupStore backups = backupStore ?? new HotspotConfigBackupStore();
    private readonly IWindowsWifiPlatform wifiPlatform = platform ?? ProductionWindowsWifiPlatform.Instance;
    private readonly object activeGate = new();
    private IWifiTransferSessionHandle? activeHandle;
    private ActiveHotspotState? pendingHotspot;
    private bool holdsHardwareLease;
    private int leaseRefCount;
    private int inFlightAttempts;
    private TaskCompletionSource? attemptsIdleTcs;
    private TaskCompletionSource? leaseIdleTcs;

    internal Task WaitForHardwareIdleAsync()
    {
        lock (activeGate)
        {
            if (!holdsHardwareLease && leaseRefCount == 0 && inFlightAttempts == 0)
                return Task.CompletedTask;
            leaseIdleTcs ??= new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            return leaseIdleTcs.Task;
        }
    }

    public async Task<WifiHostStartResult> StartAsync(WifiTransferCredentials credentials, CancellationToken cancellationToken)
    {
        if (!TryAcquireStartLease())
            return WifiHostStartResult.Failure(WifiUnavailableReason.Busy);

        try
        {
            var result = await WifiApStarter.StartWithFallbackAsync(
                this,
                credentials,
                log,
                fallbackDelay: fallbackDelay,
                delayAsync: delayAsync,
                cancellationToken: cancellationToken,
                totalTimeout: totalStartTimeout,
                primaryTimeout: primaryAttemptTimeout).ConfigureAwait(false);

            if (result.Succeeded && result.Handle is not null)
            {
                if (result.Handle is WindowsWifiSessionHandle winHandle)
                {
                    bool alreadyTearingDown;
                    lock (activeGate)
                    {
                        alreadyTearingDown = winHandle.IsHotspotTeardownStarted;
                        if (!alreadyTearingDown)
                        {
                            activeHandle = winHandle;
                            if (winHandle.HotspotState is not null && ReferenceEquals(pendingHotspot, winHandle.HotspotState))
                                pendingHotspot = null;
                        }
                    }
                    if (alreadyTearingDown)
                    {
                        await winHandle.DisposeAsync().ConfigureAwait(false);
                        return WifiHostStartResult.Failure(WifiUnavailableReason.StartFailed);
                    }
                }
                else
                {
                    lock (activeGate) activeHandle = result.Handle;
                }
            }
            return result;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            await WaitForInFlightAttemptsAsync(StartCancelWaitTimeout).ConfigureAwait(false);
            throw;
        }
        finally
        {
            ReleaseLeaseRef();
        }
    }

    public void StopSync() => StopSync(stepTimeout: null);

    internal void StopSync(TimeSpan? stepTimeout)
    {
        IWifiTransferSessionHandle? handle;
        ActiveHotspotState? pending;
        lock (activeGate)
        {
            handle = activeHandle;
            activeHandle = null;
            pending = pendingHotspot;
            pendingHotspot = null;
        }

        if (handle is WindowsWifiSessionHandle winHandle)
            winHandle.StopSync(stepTimeout);
        else
            handle?.StopSync();

        if (pending is not null)
            WindowsWifiApController.StopHotspotAndRestoreSync(pending, stepTimeout, waitSync);
    }

    bool IWifiApBackend.HasInternetConnection() => wifiPlatform.HasInternetConnection();

    async Task<WifiApAttemptResult?> IWifiApBackend.PrepareHotspotAsync(CancellationToken cancellationToken)
    {
        if (startupRestoreTask is null || startupRestoreTask.IsCompleted)
            return null;

        try
        {
            await WifiStepTimeout.RunAsync(
                stepCt => startupRestoreTask.WaitAsync(stepCt),
                HotspotStartupRestoreWaitTimeout,
                "hotspot_startup_restore_timeout",
                cancellationToken,
                delayAsync).ConfigureAwait(false);
            return null;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (WifiStepTimeoutException ex)
        {
            return WifiApAttemptResult.Failure(ex.Code);
        }
        catch (Exception ex)
        {
            log($"wifi hotspot startup restore wait error={ex.GetType().Name}");
            return null;
        }
    }

    private bool TryAcquireStartLease()
    {
        lock (activeGate)
        {
            if (holdsHardwareLease)
                return false;
            if (!WindowsWifiHardwareLease.TryAcquire(HardwareLeaseOwner))
                return false;
            holdsHardwareLease = true;
            leaseRefCount = 1;
            return true;
        }
    }

    private void AddLeaseRef()
    {
        lock (activeGate)
        {
            if (!holdsHardwareLease)
                return;
            leaseRefCount++;
        }
    }

    private void ReleaseLeaseRef()
    {
        bool shouldRelease;
        TaskCompletionSource? idleToSignal = null;
        lock (activeGate)
        {
            if (!holdsHardwareLease || leaseRefCount <= 0)
                return;
            leaseRefCount--;
            shouldRelease = leaseRefCount == 0;
            if (shouldRelease)
            {
                holdsHardwareLease = false;
                idleToSignal = leaseIdleTcs;
                leaseIdleTcs = null;
            }
        }
        if (shouldRelease)
        {
            WindowsWifiHardwareLease.Release(HardwareLeaseOwner);
            idleToSignal?.TrySetResult();
        }
    }

    private void BeginAttempt()
    {
        lock (activeGate)
        {
            if (holdsHardwareLease)
                leaseRefCount++;
            inFlightAttempts++;
        }
    }

    private void EndAttempt()
    {
        TaskCompletionSource? toSignal = null;
        TaskCompletionSource? idleToSignal = null;
        bool shouldRelease;
        lock (activeGate)
        {
            if (inFlightAttempts > 0)
                inFlightAttempts--;
            if (inFlightAttempts == 0 && attemptsIdleTcs is not null)
            {
                toSignal = attemptsIdleTcs;
                attemptsIdleTcs = null;
            }

            shouldRelease = false;
            if (holdsHardwareLease && leaseRefCount > 0)
            {
                leaseRefCount--;
                shouldRelease = leaseRefCount == 0;
                if (shouldRelease)
                {
                    holdsHardwareLease = false;
                    idleToSignal = leaseIdleTcs;
                    leaseIdleTcs = null;
                }
            }
        }
        toSignal?.TrySetResult();
        if (shouldRelease)
        {
            WindowsWifiHardwareLease.Release(HardwareLeaseOwner);
            idleToSignal?.TrySetResult();
        }
    }

    private async Task WaitForInFlightAttemptsAsync(TimeSpan timeout)
    {
        Task waitTask;
        lock (activeGate)
        {
            if (inFlightAttempts == 0)
                return;
            attemptsIdleTcs ??= new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            waitTask = attemptsIdleTcs.Task;
        }

        if (timeout <= TimeSpan.Zero)
            return;

        var delay = delayAsync ?? Task.Delay;
        using var timerCts = new CancellationTokenSource();
        var delayTask = delay(timeout, timerCts.Token);
        var winner = await Task.WhenAny(waitTask, delayTask).ConfigureAwait(false);
        if (ReferenceEquals(winner, waitTask))
        {
            try { timerCts.Cancel(); } catch { }
            WifiStepTimeout.ObserveSilently(delayTask);
        }
    }

    private async Task ConfigureHotspotStepAsync(
        ActiveHotspotState hotspotState,
        HotspotAccessPointConfig config,
        CancellationToken cancellationToken)
    {
        await WifiStepTimeout.RunAsync(
            stepCt =>
            {
                if (!hotspotState.TryStartConfigure(config, stepCt, out var opTask))
                    throw new HostStoppedException();
                return opTask;
            },
            HotspotConfigureTimeout,
            "hotspot_config_timeout",
            cancellationToken,
            delayAsync).ConfigureAwait(false);
    }

    private async Task CleanupPendingHotspotAsync(ActiveHotspotState state, TimeSpan timeout)
    {
        lock (activeGate)
        {
            if (ReferenceEquals(pendingHotspot, state))
                pendingHotspot = null;
        }
        await WindowsWifiApController.StopHotspotAndRestoreAsync(
            state,
            log,
            "wifi transfer",
            timeout,
            delayAsync).ConfigureAwait(false);
    }

    async Task<WifiApAttemptResult> IWifiApBackend.TryStartHotspotAsync(
        WifiTransferCredentials credentials,
        CancellationToken cancellationToken)
    {
        BeginAttempt();
        ActiveHotspotState? hotspotState = null;
        TcpListener? listener = null;
        try
        {
            if (startupRestoreTask is { IsCompleted: false })
                return WifiApAttemptResult.Failure("hotspot_startup_restore_timeout");

            var acquire = wifiPlatform.TryAcquireHotspotManager();
            if (acquire.Manager is null)
                return WifiApAttemptResult.Failure(acquire.FailureCode ?? "hotspot_unavailable");
            var manager = acquire.Manager;

            HotspotAccessPointConfig? currentConfig;
            try
            {
                currentConfig = manager.GetCurrentConfiguration();
            }
            catch (Exception ex)
            {
                log($"wifi hotspot config read error={ex.GetType().Name}");
                return WifiApAttemptResult.Failure("hotspot_config_unreadable");
            }

            var backupPrep = backups.PrepareForSession(currentConfig, credentials.Ssid, log);
            if (!backupPrep.Succeeded || backupPrep.Record is null)
                return WifiApAttemptResult.Failure(backupPrep.FailureCode ?? "hotspot_backup_save_failed");

            hotspotState = new ActiveHotspotState(
                manager,
                backupPrep.Record,
                hadPendingRestore: backupPrep.PreservedExistingBackup,
                backups);
            lock (activeGate) pendingHotspot = hotspotState;

            var baseConfig = new HotspotAccessPointConfig(credentials.Ssid, credentials.Passphrase, Band: null);

            var mode = WifiApMode.HotspotAuto;
            if (wifiPlatform.IsHotspotBandApiSupported())
            {
                var useFiveGHz = false;
                try
                {
                    var supported = await WifiStepTimeout.RunAsync(
                        stepCt => manager.QuerySupportedBandsAsync(baseConfig, stepCt),
                        HotspotBandQueryTimeout,
                        "hotspot_band_timeout",
                        cancellationToken,
                        delayAsync).ConfigureAwait(false);
                    useFiveGHz = supported.Contains(WifiProbeBand.FiveGHz);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                catch (WifiStepTimeoutException ex)
                {
                    log($"wifi transfer hotspot band query error={ex.Code}");
                    useFiveGHz = false;
                }
                catch (Exception ex)
                {
                    log($"wifi transfer hotspot band query error={ex.GetType().Name}");
                    useFiveGHz = false;
                }

                if (useFiveGHz)
                {
                    try
                    {
                        var config5 = baseConfig with { Band = (int)WindowsWifiApController.ToWinRtBand(WifiProbeBand.FiveGHz) };
                        await ConfigureHotspotStepAsync(hotspotState, config5, cancellationToken).ConfigureAwait(false);
                        mode = WifiApMode.Hotspot5GHz;
                    }
                    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                    {
                        throw;
                    }
                    catch (HostStoppedException)
                    {
                        throw;
                    }
                    catch (WifiStepTimeoutException ex)
                    {
                        log($"wifi transfer hotspot5 config error={ex.Code}");
                        var configAuto = baseConfig with { Band = (int)WindowsWifiApController.ToWinRtBand(WifiProbeBand.Auto) };
                        await ConfigureHotspotStepAsync(hotspotState, configAuto, cancellationToken).ConfigureAwait(false);
                        mode = WifiApMode.HotspotAuto;
                    }
                    catch (Exception ex)
                    {
                        log($"wifi transfer hotspot5 config error={ex.GetType().Name}");
                        var configAuto = baseConfig with { Band = (int)WindowsWifiApController.ToWinRtBand(WifiProbeBand.Auto) };
                        await ConfigureHotspotStepAsync(hotspotState, configAuto, cancellationToken).ConfigureAwait(false);
                        mode = WifiApMode.HotspotAuto;
                    }
                }
                else
                {
                    var configAuto = baseConfig with { Band = (int)WindowsWifiApController.ToWinRtBand(WifiProbeBand.Auto) };
                    await ConfigureHotspotStepAsync(hotspotState, configAuto, cancellationToken).ConfigureAwait(false);
                    mode = WifiApMode.HotspotAuto;
                }
            }
            else
            {
                await ConfigureHotspotStepAsync(hotspotState, baseConfig, cancellationToken).ConfigureAwait(false);
            }

            var startResult = await WifiStepTimeout.RunAsync(
                stepCt =>
                {
                    if (!hotspotState.TryStartTethering(stepCt, out var opTask))
                        throw new HostStoppedException();
                    return opTask;
                },
                HotspotStartTimeout,
                "hotspot_start_timeout",
                cancellationToken,
                delayAsync).ConfigureAwait(false);
            if (!startResult.Succeeded)
            {
                await CleanupPendingHotspotAsync(hotspotState, HotspotCleanupOnStartFailureTimeout).ConfigureAwait(false);
                hotspotState = null;
                return WifiApAttemptResult.Failure(startResult.StatusName);
            }

            var (boundListener, virtualIp) = await wifiPlatform.BindVirtualAdapterListenerAsync(
                VirtualIpBindTimeout,
                log,
                "wifi transfer",
                requireProtocolValidLocalIpv4: true,
                cancellationToken).ConfigureAwait(false);
            listener = boundListener;
            if (hotspotState.IsTeardownStarted)
                throw new HostStoppedException();
            var port = ((IPEndPoint)boundListener.LocalEndpoint).Port;

            var handle = new WindowsWifiSessionHandle(
                mode,
                credentials.Ssid,
                virtualIp.ToString(),
                port,
                boundListener,
                publisher: null,
                hotspotState,
                log,
                ReleaseHandle,
                delayAsync,
                waitSync);
            AddLeaseRef();
            listener = null;
            hotspotState = null;
            return WifiApAttemptResult.Success(handle);
        }
        catch (HostStoppedException)
        {
            try { listener?.Stop(); } catch { }
            if (hotspotState is not null)
                await CleanupPendingHotspotAsync(hotspotState, HotspotCleanupOnStartFailureTimeout).ConfigureAwait(false);
            return WifiApAttemptResult.Failure("host_stopped");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            try { listener?.Stop(); } catch { }
            if (hotspotState is not null)
                await CleanupPendingHotspotAsync(hotspotState, HotspotCleanupOnStartFailureTimeout).ConfigureAwait(false);
            throw;
        }
        catch (WifiStepTimeoutException ex)
        {
            try { listener?.Stop(); } catch { }
            if (hotspotState is not null)
                await CleanupPendingHotspotAsync(hotspotState, HotspotCleanupOnStartFailureTimeout).ConfigureAwait(false);
            return WifiApAttemptResult.Failure(ex.Code);
        }
        catch (Exception ex)
        {
            try { listener?.Stop(); } catch { }
            if (hotspotState is not null)
                await CleanupPendingHotspotAsync(hotspotState, HotspotCleanupOnStartFailureTimeout).ConfigureAwait(false);
            return WifiApAttemptResult.Failure(ex.GetType().Name);
        }
        finally
        {
            EndAttempt();
        }
    }

    async Task<WifiApAttemptResult> IWifiApBackend.TryStartWifiDirectAsync(
        WifiTransferCredentials credentials,
        CancellationToken cancellationToken)
    {
        BeginAttempt();
        WiFiDirectAdvertisementPublisher? pub = null;
        TcpListener? listener = null;
        try
        {
            if (wifiPlatform.TryStartWifiDirectOverride(credentials, cancellationToken) is { } overrideTask)
            {
                var overrideResult = await overrideTask.ConfigureAwait(false);
                if (overrideResult.Succeeded && overrideResult.Handle is not null)
                {
                    var tracked = new TrackedExternalSessionHandle(overrideResult.Handle, ReleaseHandle);
                    AddLeaseRef();
                    return WifiApAttemptResult.Success(tracked);
                }
                return overrideResult;
            }

            pub = new WiFiDirectAdvertisementPublisher();
            pub.Advertisement.IsAutonomousGroupOwnerEnabled = true;
            pub.Advertisement.LegacySettings.IsEnabled = true;
            pub.Advertisement.LegacySettings.Ssid = credentials.Ssid;
            pub.Advertisement.LegacySettings.Passphrase = new PasswordCredential
            {
                Password = credentials.Passphrase,
            };

            var tcs = new TaskCompletionSource<(WiFiDirectAdvertisementPublisherStatus Status, WiFiDirectError Error)>(
                TaskCreationOptions.RunContinuationsAsynchronously);

            void OnInitialStatus(WiFiDirectAdvertisementPublisher sender, WiFiDirectAdvertisementPublisherStatusChangedEventArgs args)
            {
                if (args.Status is WiFiDirectAdvertisementPublisherStatus.Started or WiFiDirectAdvertisementPublisherStatus.Aborted or WiFiDirectAdvertisementPublisherStatus.Stopped)
                    tcs.TrySetResult((args.Status, args.Error));
            }

            pub.StatusChanged += OnInitialStatus;
            try
            {
                pub.Start();
                using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeoutCts.CancelAfter(DirectStartTimeout);
                using var reg = timeoutCts.Token.Register(() => tcs.TrySetCanceled(timeoutCts.Token));

                var (status, error) = await tcs.Task.ConfigureAwait(false);
                if (status != WiFiDirectAdvertisementPublisherStatus.Started)
                {
                    try { pub.Stop(); } catch { }
                    return WifiApAttemptResult.Failure(error.ToString());
                }
            }
            finally
            {
                pub.StatusChanged -= OnInitialStatus;
            }

            var actualSsid = pub.Advertisement.LegacySettings.Ssid;
            if (string.IsNullOrWhiteSpace(actualSsid))
                actualSsid = credentials.Ssid;

            var (boundListener, virtualIp) = await wifiPlatform.BindVirtualAdapterListenerAsync(
                VirtualIpBindTimeout,
                log,
                "wifi transfer",
                requireProtocolValidLocalIpv4: true,
                cancellationToken).ConfigureAwait(false);
            listener = boundListener;
            var port = ((IPEndPoint)boundListener.LocalEndpoint).Port;

            var handle = new WindowsWifiSessionHandle(
                WifiApMode.WifiDirect,
                actualSsid,
                virtualIp.ToString(),
                port,
                boundListener,
                pub,
                hotspotState: null,
                log,
                ReleaseHandle,
                delayAsync,
                waitSync);
            AddLeaseRef();
            listener = null;
            pub = null;
            return WifiApAttemptResult.Success(handle);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            try { listener?.Stop(); } catch { }
            try { pub?.Stop(); } catch { }
            throw;
        }
        catch (OperationCanceledException)
        {
            try { listener?.Stop(); } catch { }
            try { pub?.Stop(); } catch { }
            return WifiApAttemptResult.Failure("direct_start_timeout");
        }
        catch (Exception ex)
        {
            try { listener?.Stop(); } catch { }
            try { pub?.Stop(); } catch { }
            return WifiApAttemptResult.Failure(ex.GetType().Name);
        }
        finally
        {
            EndAttempt();
        }
    }

    private void ReleaseHandle(IWifiTransferSessionHandle handle)
    {
        lock (activeGate)
        {
            if (handle is WindowsWifiSessionHandle winHandle &&
                winHandle.HotspotState is not null &&
                ReferenceEquals(pendingHotspot, winHandle.HotspotState))
            {
                pendingHotspot = null;
            }
            if (ReferenceEquals(activeHandle, handle))
                activeHandle = null;
        }
        ReleaseLeaseRef();
    }

    private sealed class HostStoppedException : Exception;

    private sealed class TrackedExternalSessionHandle(
        IWifiTransferSessionHandle inner,
        Action<IWifiTransferSessionHandle> onReleased) : IWifiTransferSessionHandle
    {
        private int disposedFlag;
        public WifiApMode Mode => inner.Mode;
        public string ActualSsid => inner.ActualSsid;
        public string Ip => inner.Ip;
        public int Port => inner.Port;
        public Task<WifiAcceptedConnection> AcceptAsync(CancellationToken cancellationToken) =>
            inner.AcceptAsync(cancellationToken);

        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref disposedFlag, 1) != 0)
                return;
            try { await inner.DisposeAsync().ConfigureAwait(false); }
            finally { onReleased(this); }
        }

        public void StopSync()
        {
            if (Interlocked.Exchange(ref disposedFlag, 1) != 0)
                return;
            try { inner.StopSync(); }
            finally { onReleased(this); }
        }
    }

    private sealed class TcpClientOwner(TcpClient client) : IAsyncDisposable
    {
        public ValueTask DisposeAsync()
        {
            try { client.Dispose(); } catch { }
            return ValueTask.CompletedTask;
        }
    }

    private sealed class WindowsWifiSessionHandle : IWifiTransferSessionHandle
    {
        private readonly Action<string> log;
        private readonly Action<IWifiTransferSessionHandle> onReleased;
        private readonly Func<TimeSpan, CancellationToken, Task>? delayAsync;
        private readonly Func<Task, TimeSpan, bool>? waitSync;
        private readonly CancellationTokenSource apAbortedCts = new();
        private TcpListener? listener;
        private WiFiDirectAdvertisementPublisher? publisher;
        private ActiveHotspotState? hotspotState;
        private int disposedFlag;

        public WifiApMode Mode { get; }
        public string ActualSsid { get; }
        public string Ip { get; }
        public int Port { get; }
        public ActiveHotspotState? HotspotState => Volatile.Read(ref hotspotState);
        public bool IsHotspotTeardownStarted => HotspotState?.IsTeardownStarted == true;

        public WindowsWifiSessionHandle(
            WifiApMode mode,
            string actualSsid,
            string ip,
            int port,
            TcpListener listener,
            WiFiDirectAdvertisementPublisher? publisher,
            ActiveHotspotState? hotspotState,
            Action<string> log,
            Action<IWifiTransferSessionHandle> onReleased,
            Func<TimeSpan, CancellationToken, Task>? delayAsync = null,
            Func<Task, TimeSpan, bool>? waitSync = null)
        {
            Mode = mode;
            ActualSsid = actualSsid;
            Ip = ip;
            Port = port;
            this.listener = listener;
            this.publisher = publisher;
            this.hotspotState = hotspotState;
            this.log = log;
            this.onReleased = onReleased;
            this.delayAsync = delayAsync;
            this.waitSync = waitSync;

            if (this.publisher is not null)
                this.publisher.StatusChanged += OnPublisherStatusChanged;
        }

        private void OnPublisherStatusChanged(
            WiFiDirectAdvertisementPublisher sender,
            WiFiDirectAdvertisementPublisherStatusChangedEventArgs args)
        {
            if (args.Status == WiFiDirectAdvertisementPublisherStatus.Aborted)
            {
                log($"wifi transfer direct aborted error={args.Error}");
                try { apAbortedCts.Cancel(); } catch { }
            }
        }

        public async Task<WifiAcceptedConnection> AcceptAsync(CancellationToken cancellationToken)
        {
            var activeListener = listener ?? throw new ObjectDisposedException(nameof(WindowsWifiSessionHandle));
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, apAbortedCts.Token);
            TcpClient client;
            try
            {
                client = await activeListener.AcceptTcpClientAsync(linked.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (apAbortedCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                throw new IOException("Wi-Fi Direct AP aborted before TCP connection arrived.");
            }

            // Single-connection listener: stop accepting immediately once the client connects.
            var toStop = Interlocked.Exchange(ref listener, null);
            if (toStop is not null)
            {
                try { toStop.Stop(); } catch { }
            }

            // Keep default SendBufferSize so Windows TCP auto-tuning stays active.
            client.NoDelay = true;
            var stream = client.GetStream();
            return new WifiAcceptedConnection(
                stream,
                shutdownSend: () =>
                {
                    try { client.Client.Shutdown(SocketShutdown.Send); } catch { }
                },
                owner: new TcpClientOwner(client));
        }

        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref disposedFlag, 1) != 0)
                return;

            try { apAbortedCts.Cancel(); } catch { }

            var activeListener = Interlocked.Exchange(ref listener, null);
            if (activeListener is not null)
            {
                try { activeListener.Stop(); } catch { }
            }

            var activePublisher = Interlocked.Exchange(ref publisher, null);
            if (activePublisher is not null)
            {
                activePublisher.StatusChanged -= OnPublisherStatusChanged;
                try { activePublisher.Stop(); } catch { }
            }

            var activeHotspot = Interlocked.Exchange(ref hotspotState, null);
            if (activeHotspot is not null)
            {
                await WindowsWifiApController.StopHotspotAndRestoreAsync(
                    activeHotspot,
                    log,
                    "wifi transfer",
                    delayAsync: delayAsync).ConfigureAwait(false);
            }

            apAbortedCts.Dispose();
            onReleased(this);
        }

        public void StopSync() => StopSync(stepTimeout: null);

        public void StopSync(TimeSpan? stepTimeout)
        {
            if (Interlocked.Exchange(ref disposedFlag, 1) != 0)
                return;

            try { apAbortedCts.Cancel(); } catch { }

            var activeListener = Interlocked.Exchange(ref listener, null);
            if (activeListener is not null)
            {
                try { activeListener.Stop(); } catch { }
            }

            var activePublisher = Interlocked.Exchange(ref publisher, null);
            if (activePublisher is not null)
            {
                activePublisher.StatusChanged -= OnPublisherStatusChanged;
                try { activePublisher.Stop(); } catch { }
            }

            var activeHotspot = Interlocked.Exchange(ref hotspotState, null);
            if (activeHotspot is not null)
            {
                WindowsWifiApController.StopHotspotAndRestoreSync(activeHotspot, stepTimeout, waitSync);
            }

            apAbortedCts.Dispose();
            onReleased(this);
        }
    }
}
