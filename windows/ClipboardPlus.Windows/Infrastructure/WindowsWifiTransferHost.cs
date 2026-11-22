using System.Net;
using System.Net.Sockets;
using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using global::Windows.Devices.WiFiDirect;
using global::Windows.Networking.Connectivity;
using global::Windows.Networking.NetworkOperators;
using global::Windows.Security.Credentials;

namespace ClipboardPlus.Windows.Infrastructure;

/// <summary>
/// Production Windows Wi-Fi transfer host: selects 5GHz Mobile Hotspot (falling back to Auto if 5GHz
/// cannot be selected) when online, Wi-Fi Direct Legacy when offline, retries with the alternate mode
/// after a short settle delay on failure, binds TcpListener strictly to the virtual adapter IP,
/// and always restores Windows' Mobile Hotspot settings on teardown or next startup.
/// </summary>
internal sealed class WindowsWifiTransferHost(
    Action<string> log,
    HotspotConfigBackupStore? backupStore = null) : IWifiTransferHost, IWifiApBackend
{
    private const string HardwareLeaseOwner = "production";
    internal static readonly TimeSpan HotspotBandQueryTimeout = TimeSpan.FromSeconds(2);
    internal static readonly TimeSpan HotspotConfigureTimeout = TimeSpan.FromSeconds(2);
    internal static readonly TimeSpan HotspotStartTimeout = TimeSpan.FromSeconds(4);
    internal static readonly TimeSpan HotspotCleanupOnStartFailureTimeout = TimeSpan.FromSeconds(2);
    internal static readonly TimeSpan VirtualIpBindTimeout = TimeSpan.FromSeconds(3);
    internal static readonly TimeSpan DirectStartTimeout = TimeSpan.FromSeconds(3);

    private readonly HotspotConfigBackupStore backups = backupStore ?? new HotspotConfigBackupStore();
    private readonly object activeGate = new();
    private WindowsWifiSessionHandle? activeHandle;

    public async Task<WifiHostStartResult> StartAsync(WifiTransferCredentials credentials, CancellationToken cancellationToken)
    {
        if (!WindowsWifiHardwareLease.TryAcquire(HardwareLeaseOwner))
            return WifiHostStartResult.Failure(WifiUnavailableReason.Busy);

        var transferredOwnership = false;
        try
        {
            var result = await WifiApStarter.StartWithFallbackAsync(
                this,
                credentials,
                log,
                cancellationToken: cancellationToken).ConfigureAwait(false);

            if (result.Succeeded && result.Handle is WindowsWifiSessionHandle handle)
            {
                lock (activeGate) activeHandle = handle;
                transferredOwnership = true;
            }
            return result;
        }
        finally
        {
            if (!transferredOwnership)
                WindowsWifiHardwareLease.Release(HardwareLeaseOwner);
        }
    }

    public void StopSync()
    {
        WindowsWifiSessionHandle? handle;
        lock (activeGate)
        {
            handle = activeHandle;
            activeHandle = null;
        }
        handle?.StopSync();
    }

    bool IWifiApBackend.HasInternetConnection() => WindowsWifiApController.HasInternetConnection();

    async Task<WifiApAttemptResult> IWifiApBackend.TryStartHotspotAsync(
        WifiTransferCredentials credentials,
        CancellationToken cancellationToken)
    {
        ActiveHotspotState? hotspotState = null;
        TcpListener? listener = null;
        try
        {
            var profile = NetworkInformation.GetInternetConnectionProfile();
            if (profile is null)
                return WifiApAttemptResult.Failure("no_internet_profile");

            var capability = NetworkOperatorTetheringManager.GetTetheringCapabilityFromConnectionProfile(profile);
            if (capability != TetheringCapability.Enabled)
                return WifiApAttemptResult.Failure($"capability_{capability}");

            var manager = NetworkOperatorTetheringManager.CreateFromConnectionProfile(profile);
            if (manager.TetheringOperationalState == TetheringOperationalState.On)
                return WifiApAttemptResult.Failure("hotspot_already_on");

            NetworkOperatorTetheringAccessPointConfiguration? previousConfig = null;
            try { previousConfig = manager.GetCurrentAccessPointConfiguration(); }
            catch { previousConfig = null; }

            hotspotState = new ActiveHotspotState(manager, previousConfig, configModified: false, backups);

            var backupRecord = WindowsWifiApController.CreateBackupRecord(previousConfig, credentials.Ssid);
            if (backupRecord is not null)
            {
                try { backups.Save(backupRecord); }
                catch (Exception ex) { log($"wifi hotspot backup save error={ex.GetType().Name}"); }
            }

            var config = new NetworkOperatorTetheringAccessPointConfiguration
            {
                Ssid = credentials.Ssid,
                Passphrase = credentials.Passphrase,
            };

            var mode = WifiApMode.HotspotAuto;
            if (WindowsWifiApController.IsHotspotBandApiSupported())
            {
                var supported = await WifiStepTimeout.RunAsync(
                    stepCt => WindowsWifiApController.QuerySupportedHotspotBandsAsync(config, stepCt),
                    HotspotBandQueryTimeout,
                    "hotspot_band_timeout",
                    cancellationToken).ConfigureAwait(false);
                var useFiveGHz = supported.Contains(WifiProbeBand.FiveGHz);
                if (useFiveGHz)
                {
                    try
                    {
                        config.Band = WindowsWifiApController.ToWinRtBand(WifiProbeBand.FiveGHz);
                        hotspotState.ConfigModified = true;
                        await WifiStepTimeout.RunAsync(
                            stepCt => manager.ConfigureAccessPointAsync(config).AsTask(stepCt),
                            HotspotConfigureTimeout,
                            "hotspot_config_timeout",
                            cancellationToken).ConfigureAwait(false);
                        mode = WifiApMode.Hotspot5GHz;
                    }
                    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                    {
                        throw;
                    }
                    catch (WifiStepTimeoutException)
                    {
                        throw;
                    }
                    catch (Exception ex)
                    {
                        log($"wifi transfer hotspot5 config error={ex.GetType().Name}");
                        config.Band = WindowsWifiApController.ToWinRtBand(WifiProbeBand.Auto);
                        hotspotState.ConfigModified = true;
                        await WifiStepTimeout.RunAsync(
                            stepCt => manager.ConfigureAccessPointAsync(config).AsTask(stepCt),
                            HotspotConfigureTimeout,
                            "hotspot_config_timeout",
                            cancellationToken).ConfigureAwait(false);
                        mode = WifiApMode.HotspotAuto;
                    }
                }
                else
                {
                    config.Band = WindowsWifiApController.ToWinRtBand(WifiProbeBand.Auto);
                    hotspotState.ConfigModified = true;
                    await WifiStepTimeout.RunAsync(
                        stepCt => manager.ConfigureAccessPointAsync(config).AsTask(stepCt),
                        HotspotConfigureTimeout,
                        "hotspot_config_timeout",
                        cancellationToken).ConfigureAwait(false);
                    mode = WifiApMode.HotspotAuto;
                }
            }
            else
            {
                hotspotState.ConfigModified = true;
                await WifiStepTimeout.RunAsync(
                    stepCt => manager.ConfigureAccessPointAsync(config).AsTask(stepCt),
                    HotspotConfigureTimeout,
                    "hotspot_config_timeout",
                    cancellationToken).ConfigureAwait(false);
            }

            var startResult = await WifiStepTimeout.RunAsync(
                stepCt => manager.StartTetheringAsync().AsTask(stepCt),
                HotspotStartTimeout,
                "hotspot_start_timeout",
                cancellationToken).ConfigureAwait(false);
            if (startResult.Status != TetheringOperationStatus.Success)
            {
                var statusName = WifiProbeText.FormatTetheringOperationStatus((int)startResult.Status, startResult.Status.ToString());
                await WindowsWifiApController.StopHotspotAndRestoreAsync(
                    hotspotState,
                    log,
                    "wifi transfer",
                    HotspotCleanupOnStartFailureTimeout).ConfigureAwait(false);
                hotspotState = null;
                return WifiApAttemptResult.Failure(statusName);
            }

            var (boundListener, virtualIp) = await WindowsWifiApController.BindVirtualAdapterListenerAsync(
                VirtualIpBindTimeout,
                log,
                "wifi transfer",
                requireProtocolValidLocalIpv4: true,
                cancellationToken).ConfigureAwait(false);
            listener = boundListener;
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
                ReleaseHandle);
            listener = null;
            hotspotState = null;
            return WifiApAttemptResult.Success(handle);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            try { listener?.Stop(); } catch { }
            if (hotspotState is not null)
                await WindowsWifiApController.StopHotspotAndRestoreAsync(
                    hotspotState,
                    log,
                    "wifi transfer",
                    HotspotCleanupOnStartFailureTimeout).ConfigureAwait(false);
            throw;
        }
        catch (WifiStepTimeoutException ex)
        {
            try { listener?.Stop(); } catch { }
            if (hotspotState is not null)
                await WindowsWifiApController.StopHotspotAndRestoreAsync(
                    hotspotState,
                    log,
                    "wifi transfer",
                    HotspotCleanupOnStartFailureTimeout).ConfigureAwait(false);
            return WifiApAttemptResult.Failure(ex.Code);
        }
        catch (Exception ex)
        {
            try { listener?.Stop(); } catch { }
            if (hotspotState is not null)
                await WindowsWifiApController.StopHotspotAndRestoreAsync(
                    hotspotState,
                    log,
                    "wifi transfer",
                    HotspotCleanupOnStartFailureTimeout).ConfigureAwait(false);
            return WifiApAttemptResult.Failure(ex.GetType().Name);
        }
    }

    async Task<WifiApAttemptResult> IWifiApBackend.TryStartWifiDirectAsync(
        WifiTransferCredentials credentials,
        CancellationToken cancellationToken)
    {
        WiFiDirectAdvertisementPublisher? pub = null;
        TcpListener? listener = null;
        try
        {
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

            var (boundListener, virtualIp) = await WindowsWifiApController.BindVirtualAdapterListenerAsync(
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
                ReleaseHandle);
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
    }

    private void ReleaseHandle(WindowsWifiSessionHandle handle)
    {
        bool owned;
        lock (activeGate)
        {
            owned = ReferenceEquals(activeHandle, handle);
            if (owned)
                activeHandle = null;
        }
        if (owned)
            WindowsWifiHardwareLease.Release(HardwareLeaseOwner);
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
        private readonly Action<WindowsWifiSessionHandle> onReleased;
        private readonly CancellationTokenSource apAbortedCts = new();
        private TcpListener? listener;
        private WiFiDirectAdvertisementPublisher? publisher;
        private ActiveHotspotState? hotspotState;
        private int disposedFlag;

        public WifiApMode Mode { get; }
        public string ActualSsid { get; }
        public string Ip { get; }
        public int Port { get; }

        public WindowsWifiSessionHandle(
            WifiApMode mode,
            string actualSsid,
            string ip,
            int port,
            TcpListener listener,
            WiFiDirectAdvertisementPublisher? publisher,
            ActiveHotspotState? hotspotState,
            Action<string> log,
            Action<WindowsWifiSessionHandle> onReleased)
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
                await WindowsWifiApController.StopHotspotAndRestoreAsync(activeHotspot, log, "wifi transfer").ConfigureAwait(false);
            }

            apAbortedCts.Dispose();
            onReleased(this);
        }

        public void StopSync()
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
                WindowsWifiApController.StopHotspotAndRestoreSync(activeHotspot);
            }

            apAbortedCts.Dispose();
            onReleased(this);
        }
    }
}
