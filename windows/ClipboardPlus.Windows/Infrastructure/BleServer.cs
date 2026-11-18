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
    private readonly object endpointGate = new();
    private readonly BlePeerRegistry<Peer> peerRegistry = new();
    private readonly TimeSpan shutdownTimeout = TimeSpan.FromSeconds(5);
    private volatile bool adapterReady;
    private Task? polling;
    // Write-rate diagnostics, logged from the polling loop while writes arrive (counts only).
    private int writesInFlight, writesInFlightMax, writesSinceReport;
    private readonly System.Diagnostics.Stopwatch writeReportClock = System.Diagnostics.Stopwatch.StartNew();
    private static void InterlockedMax(ref int target, int value)
    {
        int current;
        while (value > (current = Volatile.Read(ref target)) && Interlocked.CompareExchange(ref target, value, current) != current) { }
    }
    private void ReportWriteRate()
    {
        var seconds = writeReportClock.Elapsed.TotalSeconds;
        writeReportClock.Restart();
        var count = Interlocked.Exchange(ref writesSinceReport, 0);
        var max = Interlocked.Exchange(ref writesInFlightMax, Volatile.Read(ref writesInFlight));
        if (count > 0) log($"writes count={count} perSecond={count / Math.Max(seconds, 0.001):F1} inFlightMax={max}");
    }
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
            peer => ((Peer)peer).Reject(),
            applySubscriptionsAsync: ApplySubscriptionSnapshotAsync,
            shutdownTimeout: shutdownTimeout,
            rehandshakePeerAsync: RehandshakePeerAsync,
            sameSession: SameSession);
    }

    public void Start() => polling = Task.Run(async () =>
    {
        while (!stop.IsCancellationRequested)
        {
            ReportWriteRate();
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
                else if (!adapterReady || peerRegistry.Count > 0)
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
        GattServiceProvider? currentProvider;
        lock (endpointGate) currentProvider = provider;
        if (currentProvider?.AdvertisementStatus is GattServiceProviderAdvertisementStatus.Started or GattServiceProviderAdvertisementStatus.StartedWithoutAllAdvertisementData)
        {
            adapterReady = true;
            return;
        }
        await StopProviderAsync();
        if (stopping) return;
        var result = await GattServiceProvider.CreateAsync(ServiceId);
        if (result.Error != BluetoothError.Success)
        {
            log($"service create error={result.Error}");
            Status("Bluetoothの待ち受けを開始できません。再試行しています"); return;
        }
        if (stopping) return;
        var createdProvider = result.ServiceProvider;
        var writeResult = await createdProvider.Service.CreateCharacteristicAsync(ToPcId, new()
        {
            CharacteristicProperties = GattCharacteristicProperties.Write | GattCharacteristicProperties.WriteWithoutResponse,
            WriteProtectionLevel = GattProtectionLevel.Plain
        });
        if (stopping) return;
        var notifyResult = await createdProvider.Service.CreateCharacteristicAsync(ToPadId, new()
        {
            CharacteristicProperties = GattCharacteristicProperties.Notify,
            ReadProtectionLevel = GattProtectionLevel.Plain,
            WriteProtectionLevel = GattProtectionLevel.Plain
        });
        if (writeResult.Error != BluetoothError.Success || notifyResult.Error != BluetoothError.Success)
            throw new InvalidOperationException("Cannot create GATT characteristics");
        var createdInbound = writeResult.Characteristic;
        var createdOutbound = notifyResult.Characteristic;
        lock (endpointGate)
        {
            if (stopping) return;
            provider = createdProvider;
            inbound = createdInbound;
            outbound = createdOutbound;
        }
        pipeline.SetActiveCharacteristic(createdInbound, createdOutbound);
        createdInbound.WriteRequested += WriteRequested;
        createdOutbound.SubscribedClientsChanged += SubscriptionsChanged;
        createdProvider.AdvertisementStatusChanged += AdvertisementChanged;
        createdProvider.StartAdvertising(new() { IsDiscoverable = true, IsConnectable = true });
        if (stopping)
        {
            try { createdInbound.WriteRequested -= WriteRequested; }
            catch (Exception) { }
            try { createdOutbound.SubscribedClientsChanged -= SubscriptionsChanged; }
            catch (Exception) { }
            try { createdProvider.AdvertisementStatusChanged -= AdvertisementChanged; }
            catch (Exception) { }
            try { createdProvider.StopAdvertising(); }
            catch (Exception) { }
            StopEndpoint();
            return;
        }
        Status("Bluetoothの待ち受けを開始しています");
    }

    private void AdvertisementChanged(GattServiceProvider sender, GattServiceProviderAdvertisementStatusChangedEventArgs args) =>
        _ = Queue(() =>
        {
            GattServiceProvider? currentProvider;
            lock (endpointGate) currentProvider = provider;
            if (!stopping && Equals(sender, currentProvider))
            {
                var started = args.Status is GattServiceProviderAdvertisementStatus.Started or GattServiceProviderAdvertisementStatus.StartedWithoutAllAdvertisementData;
                adapterReady = started;
                log($"advertising status={args.Status} error={args.Error}");
                Status(started ? "iPhone・iPadを待っています" : "Bluetoothの待ち受けを再開しています");
            }
            return Task.CompletedTask;
        });

    private void SubscriptionsChanged(GattLocalCharacteristic sender, object args) =>
        pipeline.CaptureSubscriptionsChanged(sender, () => ReadSubscribedClients(sender));

    private static BleSubscribedClient[] ReadSubscribedClients(GattLocalCharacteristic characteristic) =>
        characteristic.SubscribedClients
            .Where(c => c.Session.SessionStatus != GattSessionStatus.Closed)
            .Select(c => new BleSubscribedClient(c.Session.DeviceId.Id, c.Session, c))
            .ToArray();

    private async Task UpdateSubscriptionsAsync()
    {
        await pipeline.DrainPendingSubscriptionsAsync();
        GattLocalCharacteristic? currentOutbound;
        GattLocalCharacteristic? currentInbound;
        lock (endpointGate)
        {
            currentOutbound = outbound;
            currentInbound = inbound;
        }
        if (stopping || currentOutbound is null || currentInbound is null) return;
        pipeline.CaptureSubscriptionsChanged(currentOutbound, () => ReadSubscribedClients(currentOutbound), enqueueDrain: false);
        await pipeline.DrainPendingSubscriptionsAsync();
    }

    private async Task ApplySubscriptionSnapshotAsync(BleSubscribedClient[] clients, long subscriptionGeneration)
    {
        GattLocalCharacteristic? currentOutbound;
        GattLocalCharacteristic? currentInbound;
        lock (endpointGate)
        {
            currentOutbound = outbound;
            currentInbound = inbound;
        }
        if (stopping || peerRegistry.IsClosed || currentOutbound is null || currentInbound is null) return;

        foreach (var old in peerRegistry.Snapshot())
        {
            if (pipeline.ShouldKeepPeerForSnapshot(old.Id, old.Slot, subscriptionGeneration))
                continue;
            var oldSubGen = old.Slot?.SubscriptionGeneration ?? 0;
            var stillSubscribed = old.Session.SessionStatus != GattSessionStatus.Closed
                && !(old.Slot?.Invalidated ?? false)
                && clients.Any(c => c.PeerId == old.Id && SameSession(c.Session, old.Session) && c.SubscriptionGeneration == oldSubGen);
            if (!stillSubscribed)
                await RemovePeerAsync(old);
        }

        foreach (var item in clients)
        {
            if (stopping || peerRegistry.IsClosed) return;
            var client = (GattSubscribedClient)item.Client;
            if (client.Session.SessionStatus == GattSessionStatus.Closed) continue;
            var id = item.PeerId;
            if (!pipeline.IsCurrentSubscription(id, client.Session, item.SubscriptionGeneration))
                continue;
            var existing = peerRegistry.GetValueOrDefault(id);
            if (existing is not null)
            {
                if (SameSession(existing.Session, client.Session)
                    && existing.Slot?.SubscriptionGeneration == item.SubscriptionGeneration
                    && !(existing.Slot?.Invalidated ?? false))
                {
                    existing.Client = client;
                    continue;
                }
                await RemovePeerAsync(existing);
            }
            if (peerRegistry.Count >= 8) continue;
            if (stopping || peerRegistry.IsClosed) return;
            if (!pipeline.IsCurrentSubscription(id, client.Session, item.SubscriptionGeneration))
                continue;

            var peer = new Peer(client, currentOutbound, log, () => stopping, stop.Token, dispatcher, pipeline.RetireSlot);
            var slot = pipeline.BindPeer(currentInbound, id, client.Session, peer, item.SubscriptionGeneration);
            if (slot is null)
            {
                await peer.DisposeAsync();
                continue;
            }
            await RegisterAndConnectPeerAsync(peer, client, slot);
        }
    }

    private async Task<object?> RehandshakePeerAsync(object oldPeerObj, BleSubscriptionSlot newSlot)
    {
        var oldPeer = (Peer)oldPeerObj;
        GattLocalCharacteristic? currentOutbound;
        lock (endpointGate) currentOutbound = outbound;
        if (stopping || peerRegistry.IsClosed || currentOutbound is null)
        {
            pipeline.InvalidateSlot(newSlot);
            return null;
        }
        var client = ReadSubscribedClients(currentOutbound)
            .Where(c => c.PeerId == oldPeer.Id && SameSession(c.Session, oldPeer.Session))
            .Select(c => (GattSubscribedClient)c.Client)
            .FirstOrDefault() ?? oldPeer.Client;
        await RemovePeerAsync(oldPeer);
        if (stopping || peerRegistry.IsClosed)
        {
            pipeline.InvalidateSlot(newSlot);
            return null;
        }
        var newPeer = new Peer(client, currentOutbound, log, () => stopping, stop.Token, dispatcher, pipeline.RetireSlot);
        if (!pipeline.TryAttachPeerToSlot(newSlot, newPeer))
        {
            await newPeer.DisposeAsync();
            return null;
        }
        return await RegisterAndConnectPeerAsync(newPeer, client, newSlot) ? newPeer : null;
    }

    private async Task<bool> RegisterAndConnectPeerAsync(Peer peer, GattSubscribedClient client, BleSubscriptionSlot slot)
    {
        peer.Slot = slot;
        peer.StatusHandler = (session, args) =>
        {
            if (args.Status == GattSessionStatus.Closed && peer.Slot is { } closedSlot)
                pipeline.InvalidateSlot(closedSlot);
            _ = Queue(async () =>
            {
                var tracked = peerRegistry.GetValueOrDefault(peer.Id);
                if (args.Status == GattSessionStatus.Closed && ReferenceEquals(tracked, peer))
                    await RemovePeerAsync(peer);
            });
        };
        peer.MtuHandler = (session, args) => log($"mtu pdu={session.MaxPduSize}");
        peer.Session.SessionStatusChanged += peer.StatusHandler;
        peer.Session.MaxPduSizeChanged += peer.MtuHandler;
        if (!peerRegistry.TryAdd(peer.Id, peer))
        {
            await DisposeRemovedPeerAsync(peer);
            return false;
        }
        if (slot.Rejected || slot.Invalidated) peer.Reject();
        log($"subscribed mtu={client.Session.MaxPduSize}");
        if (!peer.Rejected)
            await coordinator.ConnectAsync(peer);
        return !peer.Rejected;
    }

    private void WriteRequested(GattLocalCharacteristic sender, GattWriteRequestedEventArgs args)
    {
        var session = args.Session;
        var id = session.DeviceId.Id;
        var estimatedBytes = BleLimits.NotificationBytes(session.MaxPduSize);
        var sessionClosed = session.SessionStatus == GattSessionStatus.Closed;
        var deferral = args.GetDeferral();
        var inFlight = Interlocked.Increment(ref writesInFlight);
        Interlocked.Increment(ref writesSinceReport);
        InterlockedMax(ref writesInFlightMax, inFlight);
        // Start fetching the request now, so each packet's round trip overlaps the next one
        // instead of running one after another in the ingest loop (about 39 ms per packet).
        var requestTask = args.GetRequestAsync().AsTask();
        // Acquire deferral, subscription slot, session, and byte admission synchronously before awaiting GetRequestAsync.
        pipeline.EnqueueWrite(
            sender,
            id,
            session,
            estimatedBytes,
            sessionClosed,
            async ct =>
            {
                var request = await requestTask.WaitAsync(ct);
                if (request is null) return null;
                var length = (long)(request.Value?.Length ?? 0);
                return new BleWriteRequestData(
                    request.Offset,
                    length,
                    () => request.Value is null ? [] : request.Value.ToArray(),
                    request.Option == GattWriteOption.WriteWithResponse,
                    () => request.Respond(),
                    error => request.RespondWithProtocolError(error));
            },
            () => { Interlocked.Decrement(ref writesInFlight); deferral.Complete(); },
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

    // The write event and SubscribedClients can return different GattSession objects for the same
    // link, so reference equality silently dropped every write (build 34 never got past HELLO).
    // A session is identified by its device; subscription generations tell reconnects apart.
    private static bool SameSession(object a, object b)
    {
        if (ReferenceEquals(a, b)) return true;
        if (a is not GattSession x || b is not GattSession y) return Equals(a, b);
        try { return string.Equals(x.DeviceId.Id, y.DeviceId.Id, StringComparison.Ordinal); }
        catch (Exception) { return false; }
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
        peerRegistry.Remove(peer.Id, peer);
        await DisposeRemovedPeerAsync(peer);
    }

    private async Task DisposeRemovedPeerAsync(Peer peer)
    {
        if (peer.Slot is { } slot) pipeline.InvalidateSlot(slot);
        if (peer.StatusHandler is { } statusHandler)
            try { peer.Session.SessionStatusChanged -= statusHandler; } catch (Exception) { }
        if (peer.MtuHandler is { } mtuHandler)
            try { peer.Session.MaxPduSizeChanged -= mtuHandler; } catch (Exception) { }
        peer.Reject();
        await peer.DisposeAsync();
        await coordinator.DisconnectAsync(peer);
    }

    private void StopEndpoint()
    {
        GattLocalCharacteristic? oldInbound;
        GattLocalCharacteristic? oldOutbound;
        GattServiceProvider? oldProvider;
        lock (endpointGate)
        {
            adapterReady = false;
            oldInbound = inbound;
            oldOutbound = outbound;
            oldProvider = provider;
            inbound = null;
            outbound = null;
            provider = null;
        }
        pipeline.SetActiveCharacteristic(null);
        if (oldInbound is not null)
        {
            try { oldInbound.WriteRequested -= WriteRequested; }
            catch (Exception e) { log($"write unsubscribe error={e.GetType().Name}"); }
        }
        if (oldOutbound is not null)
        {
            try { oldOutbound.SubscribedClientsChanged -= SubscriptionsChanged; }
            catch (Exception e) { log($"subscription unsubscribe error={e.GetType().Name}"); }
        }
        if (oldProvider is not null)
        {
            try { oldProvider.AdvertisementStatusChanged -= AdvertisementChanged; }
            catch (Exception) { }
            try { oldProvider.StopAdvertising(); }
            catch (Exception e) { log($"advertising stop error={e.GetType().Name}"); }
        }
    }

    private async Task StopProviderAsync()
    {
        var snapshot = peerRegistry.Drain(close: stopping);
        var disposePeers = snapshot
            .Select(peer => (Func<Task>)(() => DisposeRemovedPeerAsync(peer)))
            .ToArray();
        await BleEndpointCleanup.StopEndpointBeforePeersAsync(
            StopEndpoint,
            disposePeers,
            stopping ? shutdownTimeout : Timeout.InfiniteTimeSpan,
            log);
    }

    public async ValueTask DisposeAsync()
    {
        stopping = true;
        peerRegistry.Close();
        stop.Cancel();
        StopEndpoint();
        if (polling is not null)
        {
            try { await polling.WaitAsync(shutdownTimeout); }
            catch (TimeoutException) { log("polling shutdown timeout"); }
            catch (Exception e) { log($"polling error={e.GetType().Name}"); }
        }
        await pipeline.ShutdownAsync(StopProviderAsync, StopEndpoint);
        if ((polling is null || polling.IsCompleted) && pipeline.IsStopped) stop.Dispose();
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
        private volatile GattSubscribedClient currentClient = client;
        private volatile BleSubscriptionSlot? currentSlot;
        public GattSubscribedClient Client { get => currentClient; set => currentClient = value; }
        public readonly GattSession Session = client.Session;
        public string Id => Session.DeviceId.Id;
        public BleSubscriptionSlot? Slot { get => currentSlot; set => currentSlot = value; }
        private volatile bool rejected;
        private int rejectedFlag;
        public bool Rejected => rejected || (currentSlot is { } s && (s.Rejected || s.Invalidated));
        public bool IsRejected => Rejected;
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
            if (Interlocked.Exchange(ref rejectedFlag, 1) != 0) return;
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
                                    _ = ConnectionTuningRequest.Acquire(
                                        () => bleDevice.RequestPreferredConnectionParameters(
                                            BluetoothLEPreferredConnectionParameters.ThroughputOptimized),
                                        request => request.Status == BluetoothLEPreferredConnectionParametersRequestStatus.Success,
                                        request => request.Status.ToString(),
                                        request =>
                                        {
                                            lock (connGate)
                                            {
                                                if (disposed || Rejected || isStopping() || !desiredHighThroughput)
                                                    return false;
                                                throughputRequest = request;
                                                return true;
                                            }
                                        },
                                        log,
                                        out var unavailable);
                                    if (unavailable) connParamsUnavailable = true;
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
