using System.Runtime.InteropServices.WindowsRuntime;
using System.Windows.Threading;
using ClipboardPlus.Windows.Core;
using global::Windows.Devices.Bluetooth;
using global::Windows.Devices.Bluetooth.GenericAttributeProfile;
using global::Windows.Devices.Radios;
using global::Windows.Foundation;
using global::Windows.Foundation.Metadata;

namespace ClipboardPlus.Windows.Infrastructure;

internal sealed class BleServer : IAsyncDisposable
{
    private static readonly Guid ServiceId = new("E8DB89CB-2BBF-48DD-8D0A-FB868C9A1472");
    private static readonly Guid ToPcId = new("F4508CC7-393F-4288-8B72-A4A9A09D1D4D");
    private static readonly Guid ToPadId = new("3A7ADCFC-CD62-4AF8-BF09-2C73023C5B83");
    private readonly SyncCoordinator coordinator;
    private readonly Action<string> log;
    private readonly Dispatcher? dispatcher;
    private readonly WriteAdmission writes = new();
    private readonly BleWritePipeline pipeline;
    private readonly CancellationTokenSource stop = new();
    private readonly Dictionary<string, Peer> peers = [];
    private int peerCount;
    private volatile bool adapterReady;
    private Task? polling;
    private GattServiceProvider? provider;
    private GattLocalCharacteristic? inbound, outbound;
    private string? lastStatus;
    private volatile bool stopping;
    public event Action<string>? StatusChanged;

    public BleServer(SyncCoordinator coordinator, Action<string> log, Dispatcher? dispatcher = null)
    {
        this.coordinator = coordinator;
        this.log = log;
        this.dispatcher = dispatcher;
        pipeline = new BleWritePipeline(
            writes,
            log,
            UpdateSubscriptionsAsync,
            DeliverPacketAsync,
            peer => coordinator.DisconnectAsync((Peer)peer),
            peer => ((Peer)peer).Reject());
    }

    public void Start() => polling = Task.Run(async () =>
    {
        while (!stop.IsCancellationRequested)
        {
            try
            {
                var offStatus = await ProbeRadioAsync();
                if (offStatus is not null)
                {
                    await Queue(async () =>
                    {
                        await StopProviderAsync();
                        Status(offStatus);
                    });
                }
                else if (!adapterReady || Volatile.Read(ref peerCount) > 0)
                {
                    await Queue(async () =>
                    {
                        if (!adapterReady) await EnsureProviderAsync();
                        await UpdateSubscriptionsAsync();
                    });
                }
            }
            catch (UnauthorizedAccessException)
            {
                await Queue(async () =>
                {
                    await StopProviderAsync();
                    Status("Bluetoothへのアクセスが許可されていません");
                });
            }
            catch (Exception e)
            {
                await Queue(async () =>
                {
                    await StopProviderAsync();
                    log($"adapter error={e.GetType().Name}");
                    Status("Bluetoothを開始できません。再試行しています");
                });
            }
            try { await coordinator.TickAsync(DateTimeOffset.UtcNow); }
            catch (Exception e) { log($"tick error={e.GetType().Name}"); }
            try { await Task.Delay(3000, stop.Token); }
            catch (OperationCanceledException) { break; }
        }
    });

    private Task Queue(Func<Task> action) => pipeline.QueueWork(action);

    private void Status(string value)
    {
        if (lastStatus == value) return;
        lastStatus = value; log($"bluetooth status={value}"); StatusChanged?.Invoke(value);
    }

    private static async Task<string?> ProbeRadioAsync()
    {
        var adapter = await BluetoothAdapter.GetDefaultAsync();
        if (adapter is null || !adapter.IsLowEnergySupported || !adapter.IsPeripheralRoleSupported)
        {
            var radios = await Radio.GetRadiosAsync();
            var bluetooth = radios.FirstOrDefault(r => r.Kind == RadioKind.Bluetooth);
            return adapter is null && bluetooth is not null && bluetooth.State != RadioState.On
                ? "Bluetoothがオフです" : "このPCのBluetoothは対応していません";
        }
        var radio = await adapter.GetRadioAsync();
        if (radio is null || radio.State != RadioState.On)
            return radio?.State == RadioState.Disabled ? "Bluetoothが無効になっています" : "Bluetoothがオフです";
        return null;
    }

    private async Task EnsureProviderAsync()
    {
        if (stopping) return;
        if (provider?.AdvertisementStatus is GattServiceProviderAdvertisementStatus.Started or GattServiceProviderAdvertisementStatus.StartedWithoutAllAdvertisementData)
        {
            adapterReady = true;
            return;
        }
        await StopProviderAsync();
        var result = await GattServiceProvider.CreateAsync(ServiceId);
        if (result.Error != BluetoothError.Success)
        {
            log($"service create error={result.Error}");
            Status("Bluetoothの待ち受けを開始できません。再試行しています"); return;
        }
        provider = result.ServiceProvider;
        var writeResult = await provider.Service.CreateCharacteristicAsync(ToPcId, new()
        {
            CharacteristicProperties = GattCharacteristicProperties.Write | GattCharacteristicProperties.WriteWithoutResponse,
            WriteProtectionLevel = GattProtectionLevel.Plain
        });
        var notifyResult = await provider.Service.CreateCharacteristicAsync(ToPadId, new()
        {
            CharacteristicProperties = GattCharacteristicProperties.Notify,
            ReadProtectionLevel = GattProtectionLevel.Plain,
            WriteProtectionLevel = GattProtectionLevel.Plain
        });
        if (writeResult.Error != BluetoothError.Success || notifyResult.Error != BluetoothError.Success)
            throw new InvalidOperationException("Cannot create GATT characteristics");
        inbound = writeResult.Characteristic; outbound = notifyResult.Characteristic;
        pipeline.SetActiveCharacteristic(inbound);
        inbound.WriteRequested += WriteRequested;
        outbound.SubscribedClientsChanged += SubscriptionsChanged;
        provider.AdvertisementStatusChanged += AdvertisementChanged;
        provider.StartAdvertising(new() { IsDiscoverable = true, IsConnectable = true });
        Status("Bluetoothの待ち受けを開始しています");
    }

    private void AdvertisementChanged(GattServiceProvider sender, GattServiceProviderAdvertisementStatusChangedEventArgs args) =>
        _ = Queue(() =>
        {
            if (sender == provider)
            {
                var started = args.Status is GattServiceProviderAdvertisementStatus.Started or GattServiceProviderAdvertisementStatus.StartedWithoutAllAdvertisementData;
                adapterReady = started;
                log($"advertising status={args.Status} error={args.Error}");
                Status(started ? "iPhone・iPadを待っています" : "Bluetoothの待ち受けを再開しています");
            }
            return Task.CompletedTask;
        });

    private void SubscriptionsChanged(GattLocalCharacteristic sender, object args) =>
        _ = Queue(async () => { if (sender == outbound) await UpdateSubscriptionsAsync(); });

    private async Task UpdateSubscriptionsAsync()
    {
        if (outbound is null || inbound is null) return;
        var clients = outbound.SubscribedClients.ToArray();
        foreach (var old in peers.Values.ToArray())
            if (old.Session.SessionStatus == GattSessionStatus.Closed ||
                !clients.Any(c => c.Session.DeviceId.Id == old.Id)) await RemovePeerAsync(old);
        foreach (var client in clients)
        {
            var id = client.Session.DeviceId.Id;
            if (peers.TryGetValue(id, out var existing)) { existing.Client = client; continue; }
            if (peers.Count >= 8) continue;
            var peer = new Peer(client, outbound, log, () => stopping, stop.Token, dispatcher, pipeline.RetireSlot);
            var slot = pipeline.BindPeer(inbound, id, peer);
            peer.Slot = slot;
            peer.StatusHandler = (session, args) => _ = Queue(async () =>
            {
                if (args.Status == GattSessionStatus.Closed && peers.GetValueOrDefault(peer.Id) == peer)
                    await RemovePeerAsync(peer);
            });
            peer.MtuHandler = (session, args) => log($"mtu pdu={session.MaxPduSize}");
            peer.Session.SessionStatusChanged += peer.StatusHandler;
            peer.Session.MaxPduSizeChanged += peer.MtuHandler;
            peers.Add(id, peer);
            Volatile.Write(ref peerCount, peers.Count);
            log($"subscribed mtu={client.Session.MaxPduSize}");
            if (slot.Rejected) peer.Reject();
            else await coordinator.ConnectAsync(peer);
        }
    }

    private void WriteRequested(GattLocalCharacteristic sender, GattWriteRequestedEventArgs args)
    {
        var session = args.Session;
        var id = session.DeviceId.Id;
        var estimatedBytes = BleLimits.NotificationBytes(session.MaxPduSize);
        var sessionClosed = session.SessionStatus == GattSessionStatus.Closed;
        var deferral = args.GetDeferral();
        // Acquire deferral, subscription slot, and byte admission synchronously before awaiting GetRequestAsync.
        pipeline.EnqueueWrite(
            sender,
            id,
            estimatedBytes,
            sessionClosed,
            async ct =>
            {
                var request = await args.GetRequestAsync().AsTask(ct);
                if (request is null) return null;
                return new BleWriteRequestData(
                    request.Offset,
                    request.Value.ToArray(),
                    request.Option == GattWriteOption.WriteWithResponse,
                    () => request.Respond(),
                    error => request.RespondWithProtocolError(error));
            },
            () => deferral.Complete(),
            () => RejectWrite(args));
    }

    private async Task<bool> DeliverPacketAsync(object peerObj, uint offset, byte[] bytes)
    {
        var peer = (Peer)peerObj;
        if (stopping || peer.Rejected) return false;
        if (offset == 0 && bytes.Length <= 512)
            return await coordinator.ReceiveAsync(peer, bytes);
        await coordinator.DisconnectAsync(peer);
        return false;
    }

    private static void RejectWrite(GattWriteRequestedEventArgs args)
    {
        // Never enqueue or create an async rejection backlog. If device access has not
        // completed, abandon it and return the unhandled request to the GATT stack.
        // A materialized write-with-response gets an explicit ATT resource error.
        try
        {
            var operation = args.GetRequestAsync();
            if (operation.Status == AsyncStatus.Completed)
            {
                var request = operation.GetResults();
                if (request?.Option == GattWriteOption.WriteWithResponse)
                    request.RespondWithProtocolError(0x11); // ATT Insufficient Resources
            }
            else operation.Cancel();
        }
        catch (Exception) { /* Expired / inaccessible request; never report success. */ }
    }

    private async Task RemovePeerAsync(Peer peer)
    {
        peers.Remove(peer.Id);
        Volatile.Write(ref peerCount, peers.Count);
        if (peer.Slot is { } slot) pipeline.InvalidateSlot(slot);
        try { peer.Session.SessionStatusChanged -= peer.StatusHandler; } catch (Exception) { }
        try { peer.Session.MaxPduSizeChanged -= peer.MtuHandler; } catch (Exception) { }
        await peer.DisposeAsync();
        await coordinator.DisconnectAsync(peer);
    }

    private async Task StopProviderAsync()
    {
        adapterReady = false;
        pipeline.SetActiveCharacteristic(null);
        foreach (var peer in peers.Values.ToArray())
        {
            try { await RemovePeerAsync(peer); }
            catch (Exception e) { log($"peer remove error={e.GetType().Name}"); }
        }
        if (inbound is not null)
        {
            try { inbound.WriteRequested -= WriteRequested; }
            catch (Exception e) { log($"write unsubscribe error={e.GetType().Name}"); }
        }
        if (outbound is not null)
        {
            try { outbound.SubscribedClientsChanged -= SubscriptionsChanged; }
            catch (Exception e) { log($"subscription unsubscribe error={e.GetType().Name}"); }
        }
        if (provider is not null)
        {
            try { provider.AdvertisementStatusChanged -= AdvertisementChanged; }
            catch (Exception) { }
            try { provider.StopAdvertising(); }
            catch (Exception e) { log($"advertising stop error={e.GetType().Name}"); }
        }
        provider = null; inbound = null; outbound = null;
    }

    public async ValueTask DisposeAsync()
    {
        stopping = true; stop.Cancel();
        if (polling is not null)
        {
            try { await polling; }
            catch (Exception e) { log($"polling error={e.GetType().Name}"); }
        }
        await pipeline.ShutdownAsync(StopProviderAsync);
        stop.Dispose();
    }

    private sealed class Peer(
        GattSubscribedClient client,
        GattLocalCharacteristic characteristic,
        Action<string> log,
        Func<bool> isStopping,
        CancellationToken stopToken,
        Dispatcher? dispatcher,
        Action<BleSubscriptionSlot> retireSlot) : ISyncPeer, IAsyncDisposable
    {
        public GattSubscribedClient Client = client;
        public readonly GattSession Session = client.Session;
        public string Id => Session.DeviceId.Id;
        public BleSubscriptionSlot? Slot;
        private volatile bool rejected;
        public bool Rejected => rejected;
        public TypedEventHandler<GattSession, GattSessionStatusChangedEventArgs>? StatusHandler;
        public TypedEventHandler<GattSession, object>? MtuHandler;
        private readonly object connGate = new();
        private bool desiredHighThroughput;
        private bool connUpdateRunning;
        private bool connParamsUnavailable;
        private bool connParamsLoggedInitial;
        private BluetoothLEDevice? bleDevice;
        private BluetoothLEPreferredConnectionParametersRequest? throughputRequest;
        private Task connUpdateTask = Task.CompletedTask;
        private Task? disposeTask;
        private bool disposed;
        private readonly CancellationTokenSource peerCts = CancellationTokenSource.CreateLinkedTokenSource(stopToken);

        public int PacketLimit => BleLimits.NotificationBytes(Client.Session.MaxPduSize);
        public async Task SendPacketAsync(byte[] packet)
        {
            if (Rejected || isStopping()) throw new InvalidOperationException("Retired connection");
            var result = await characteristic.NotifyValueAsync(packet.AsBuffer(), Client);
            if (result.Status != GattCommunicationStatus.Success) throw new IOException("Notification failed");
        }
        public void Reject()
        {
            // Windows' local GATT API does not expose a force-disconnect operation.
            // Reject all subsequent writes on this subscription until it disappears.
            rejected = true;
            if (Slot is { } slot) retireSlot(slot);
            SetHighThroughput(false);
            log("subscription retired; waiting for reconnect");
        }
        public void SetHighThroughput(bool enabled)
        {
            lock (connGate)
            {
                if (disposed || connParamsUnavailable) return;
                if (enabled && (Rejected || isStopping())) return;
                if (desiredHighThroughput == enabled && (!enabled || throughputRequest is not null)) return;
                desiredHighThroughput = enabled;
                if (connUpdateRunning) return;
                connUpdateRunning = true;
                connUpdateTask = ReconcileConnectionTuningAsync();
            }
        }
        public ValueTask DisposeAsync()
        {
            lock (connGate)
            {
                if (disposeTask is not null) return new ValueTask(disposeTask);
                disposeTask = DisposeCoreAsync();
                return new ValueTask(disposeTask);
            }
        }

        private async Task DisposeCoreAsync()
        {
            Task pendingTask;
            lock (connGate)
            {
                disposed = true;
                desiredHighThroughput = false;
                peerCts.Cancel();
                if (!connUpdateRunning && (throughputRequest is not null || bleDevice is not null))
                {
                    connUpdateRunning = true;
                    connUpdateTask = ReconcileConnectionTuningAsync();
                }
                pendingTask = connUpdateTask;
            }
            try { await pendingTask; }
            catch (Exception e) { log($"conn params dispose error={e.GetType().Name}"); }
            peerCts.Dispose();
        }

        private async Task<BluetoothLEDevice?> OpenBleDeviceAsync(CancellationToken ct)
        {
            IAsyncOperation<BluetoothLEDevice> operation;
            if (dispatcher is null || dispatcher.CheckAccess())
            {
                operation = BluetoothLEDevice.FromIdAsync(Id);
            }
            else
            {
                if (dispatcher.HasShutdownStarted || dispatcher.HasShutdownFinished)
                    throw new OperationCanceledException(ct);
                operation = await dispatcher.InvokeAsync(() => BluetoothLEDevice.FromIdAsync(Id), DispatcherPriority.Normal, ct).Task.WaitAsync(ct);
            }
            return await operation.AsTask(ct);
        }

        private static bool IsThroughputApiSupported() =>
            OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) &&
            ApiInformation.IsTypePresent("Windows.Devices.Bluetooth.BluetoothLEPreferredConnectionParameters") &&
            ApiInformation.IsPropertyPresent("Windows.Devices.Bluetooth.BluetoothLEPreferredConnectionParameters", "ThroughputOptimized") &&
            ApiInformation.IsMethodPresent("Windows.Devices.Bluetooth.BluetoothLEDevice", "RequestPreferredConnectionParameters", 1);

        private static bool IsConnectionParametersApiSupported() =>
            OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) &&
            ApiInformation.IsMethodPresent("Windows.Devices.Bluetooth.BluetoothLEDevice", "GetConnectionParameters");

        private void DisposeThroughputRequest()
        {
            if (throughputRequest is null) return;
            try
            {
                if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
                    throughputRequest.Dispose();
            }
            catch (Exception) { }
            throughputRequest = null;
        }

        private async Task ReconcileConnectionTuningAsync()
        {
            while (true)
            {
                bool target;
                bool isDisposed;
                lock (connGate)
                {
                    isDisposed = disposed;
                    target = !isDisposed && !Rejected && !isStopping() && !connParamsUnavailable && desiredHighThroughput;
                }
                if (target && throughputRequest is null)
                {
                    try
                    {
                        if (!IsThroughputApiSupported())
                        {
                            connParamsUnavailable = true;
                            log("conn params throughput status=Unsupported");
                        }
                        else
                        {
                            if (bleDevice is null)
                            {
                                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(peerCts.Token);
                                timeout.CancelAfter(TimeSpan.FromSeconds(5));
                                bleDevice = await OpenBleDeviceAsync(timeout.Token);
                            }
                            if (bleDevice is null)
                            {
                                connParamsUnavailable = true;
                                log("conn params unavailable reason=no-device");
                            }
                            else
                            {
                                if (!connParamsLoggedInitial)
                                {
                                    connParamsLoggedInitial = true;
                                    if (IsConnectionParametersApiSupported())
                                    {
                                        var current = bleDevice.GetConnectionParameters();
                                        if (current is not null)
                                        {
                                            var intervalMs = current.ConnectionInterval * 1.25;
                                            var timeoutMs = current.LinkTimeout * 10;
                                            log($"conn params current intervalMs={intervalMs:F2} latency={current.ConnectionLatency} timeoutMs={timeoutMs}");
                                        }
                                    }
                                }
                                if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
                                {
                                    var request = bleDevice.RequestPreferredConnectionParameters(
                                        BluetoothLEPreferredConnectionParameters.ThroughputOptimized);
                                    if (request is not null && request.Status == BluetoothLEPreferredConnectionParametersRequestStatus.Success)
                                    {
                                        bool keep;
                                        lock (connGate)
                                            keep = !disposed && !Rejected && !isStopping() && desiredHighThroughput;
                                        if (keep)
                                        {
                                            throughputRequest = request;
                                            log("conn params throughput status=Success");
                                        }
                                        else
                                        {
                                            try { request.Dispose(); }
                                            catch (Exception) { }
                                        }
                                    }
                                    else
                                    {
                                        var statusLabel = request?.Status.ToString() ?? "Unsupported";
                                        try { request?.Dispose(); }
                                        catch (Exception) { }
                                        connParamsUnavailable = true;
                                        log($"conn params throughput status={statusLabel}");
                                    }
                                }
                            }
                        }
                    }
                    catch (Exception e)
                    {
                        connParamsUnavailable = true;
                        log($"conn params error={e.GetType().Name}");
                    }
                }
                else if (!target && throughputRequest is not null)
                {
                    DisposeThroughputRequest();
                    if (!isDisposed) log("conn params throughput released");
                }
                if (isDisposed)
                {
                    DisposeThroughputRequest();
                    if (bleDevice is not null)
                    {
                        try { bleDevice.Dispose(); }
                        catch (Exception) { }
                        bleDevice = null;
                    }
                    lock (connGate) { connUpdateRunning = false; }
                    return;
                }
                lock (connGate)
                {
                    var nextTarget = !disposed && !Rejected && !isStopping() && !connParamsUnavailable && desiredHighThroughput;
                    if (!disposed && ((nextTarget && throughputRequest is not null) || (!nextTarget && throughputRequest is null) || connParamsUnavailable))
                    {
                        connUpdateRunning = false;
                        return;
                    }
                }
            }
        }
    }
}
