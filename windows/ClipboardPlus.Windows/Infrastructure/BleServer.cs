using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Channels;
using ClipboardPlus.Windows.Core;
using global::Windows.Devices.Bluetooth;
using global::Windows.Devices.Bluetooth.GenericAttributeProfile;
using global::Windows.Devices.Radios;
using global::Windows.Foundation;
using global::Windows.Storage.Streams;
using WinRT;

namespace ClipboardPlus.Windows.Infrastructure;

internal sealed class BleServer : IAsyncDisposable
{
    private static readonly Guid ServiceId = new("E8DB89CB-2BBF-48DD-8D0A-FB868C9A1472");
    private static readonly Guid ToPcId = new("F4508CC7-393F-4288-8B72-A4A9A09D1D4D");
    private static readonly Guid ToPadId = new("3A7ADCFC-CD62-4AF8-BF09-2C73023C5B83");
    private sealed record PendingWrite(GattLocalCharacteristic Sender, string Id, GattWriteRequestedEventArgs Args, Deferral Deferral, IDisposable Lease);
    private readonly SyncCoordinator coordinator;
    private readonly Action<string> log;
    private readonly Channel<Func<Task>> work = Channel.CreateBounded<Func<Task>>(new BoundedChannelOptions(1024)
        { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
    private readonly Channel<PendingWrite> ingest = Channel.CreateBounded<PendingWrite>(new BoundedChannelOptions(1024)
        { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
    private readonly WriteAdmission writes = new(globalLimit: 512, peerLimit: 256);
    private readonly CancellationTokenSource stop = new();
    private readonly Task worker;
    private readonly Task ingestWorker;
    private readonly Dictionary<string, Peer> peers = [];
    private int peerCount;
    private volatile bool adapterReady;
    private Task? polling;
    private GattServiceProvider? provider;
    private GattLocalCharacteristic? inbound, outbound;
    private string? lastStatus;
    private volatile bool stopping;
    public event Action<string>? StatusChanged;

    public BleServer(SyncCoordinator coordinator, Action<string> log)
    {
        this.coordinator = coordinator; this.log = log;
        worker = Task.Run(async () =>
        {
            await foreach (var action in work.Reader.ReadAllAsync())
                try { await action(); }
                catch (Exception e) { log($"bluetooth operation error={e.GetType().Name}"); }
        });
        ingestWorker = Task.Run(IngestLoopAsync);
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

    private Task Queue(Func<Task> action)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!work.Writer.TryWrite(async () =>
        {
            try { await action(); done.SetResult(); }
            catch (Exception e) { log($"bluetooth operation error={e.GetType().Name}"); done.SetResult(); }
        })) done.SetResult();
        return done.Task;
    }

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
        if (outbound is null) return;
        var clients = outbound.SubscribedClients.ToArray();
        foreach (var old in peers.Values.ToArray())
            if (old.Session.SessionStatus == GattSessionStatus.Closed ||
                !clients.Any(c => c.Session.DeviceId.Id == old.Id)) await RemovePeerAsync(old);
        foreach (var client in clients)
        {
            var id = client.Session.DeviceId.Id;
            if (peers.TryGetValue(id, out var existing)) { existing.Client = client; continue; }
            if (peers.Count >= 8) continue;
            var peer = new Peer(client, outbound, log, () => stopping, stop.Token);
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
            await coordinator.ConnectAsync(peer);
        }
    }

    private void WriteRequested(GattLocalCharacteristic sender, GattWriteRequestedEventArgs args)
    {
        var id = args.Session.DeviceId.Id;
        var deferral = args.GetDeferral();
        // Acquire deferral and admission synchronously, and enqueue before awaiting GetRequestAsync,
        // so write-without-response packets cannot overtake each other.
        var lease = !stopping ? writes.TryEnter(id) : null;
        if (lease is null || !ingest.Writer.TryWrite(new(sender, id, args, deferral, lease)))
        {
            try { RejectWrite(args); }
            finally { try { deferral.Complete(); } finally { lease?.Dispose(); } }
        }
    }

    private async Task IngestLoopAsync()
    {
        await foreach (var item in ingest.Reader.ReadAllAsync())
        {
            GattWriteRequest? request = null;
            var handedOff = false;
            var deferralCompleted = false;
            try
            {
                using var requestTimeout = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                requestTimeout.CancelAfter(TimeSpan.FromSeconds(10));
                request = await item.Args.GetRequestAsync().AsTask(requestTimeout.Token);
                if (request is null || stopping || item.Sender != inbound)
                {
                    if (request?.Option == GattWriteOption.WriteWithResponse) TryRespondError(request, 0x0E);
                    continue;
                }
                var offset = request.Offset;
                var option = request.Option;
                var bytes = request.Value.ToArray();
                if (option == GattWriteOption.WriteWithoutResponse)
                {
                    // Release the WinRT deferral immediately after copying the payload in order
                    // so downstream disk I/O or gate contention never stalls BLE packet reception.
                    item.Deferral.Complete();
                    deferralCompleted = true;
                    handedOff = work.Writer.TryWrite(() => ProcessWriteAsync(item.Id, offset, bytes, null, null, item.Lease));
                }
                else
                {
                    handedOff = work.Writer.TryWrite(() => ProcessWriteAsync(item.Id, offset, bytes, request, item.Deferral, item.Lease));
                }
                if (!handedOff && option == GattWriteOption.WriteWithResponse)
                    TryRespondError(request, 0x11);
            }
            catch (Exception e)
            {
                log($"write request error={e.GetType().Name}");
                if (request?.Option == GattWriteOption.WriteWithResponse) TryRespondError(request, 0x0E);
            }
            finally
            {
                if (!handedOff)
                {
                    try { if (!deferralCompleted) item.Deferral.Complete(); }
                    finally { item.Lease.Dispose(); }
                }
            }
        }
    }

    private async Task ProcessWriteAsync(string id, uint offset, byte[] bytes, GattWriteRequest? request, Deferral? deferral, IDisposable lease)
    {
        try
        {
            var ok = false;
            if (!stopping)
            {
                if (!peers.TryGetValue(id, out var existing) || existing.Rejected)
                    await UpdateSubscriptionsAsync();
                if (peers.TryGetValue(id, out var peer) && !peer.Rejected)
                {
                    if (offset == 0 && bytes.Length <= 512)
                        ok = await coordinator.ReceiveAsync(peer, bytes);
                    else
                        await coordinator.DisconnectAsync(peer);
                }
            }
            if (request is not null)
            {
                if (ok) request.Respond();
                else request.RespondWithProtocolError(0x0E); // ATT Unlikely Error
            }
        }
        catch (Exception e)
        {
            log($"write request error={e.GetType().Name}");
            if (peers.TryGetValue(id, out var peer)) await coordinator.DisconnectAsync(peer);
            if (request is not null) TryRespondError(request, 0x0E);
        }
        finally
        {
            try { deferral?.Complete(); }
            finally { lease.Dispose(); }
        }
    }

    private static void TryRespondError(GattWriteRequest request, byte error)
    {
        try { request.RespondWithProtocolError(error); }
        catch (Exception) { /* Request may already have expired. */ }
    }

    private void RejectWrite(GattWriteRequestedEventArgs args)
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
        peer.Session.SessionStatusChanged -= peer.StatusHandler;
        peer.Session.MaxPduSizeChanged -= peer.MtuHandler;
        peer.Dispose();
        await coordinator.DisconnectAsync(peer);
    }

    private async Task StopProviderAsync()
    {
        adapterReady = false;
        foreach (var peer in peers.Values.ToArray()) await RemovePeerAsync(peer);
        if (inbound is not null) inbound.WriteRequested -= WriteRequested;
        if (outbound is not null) outbound.SubscribedClientsChanged -= SubscriptionsChanged;
        if (provider is not null)
        {
            provider.AdvertisementStatusChanged -= AdvertisementChanged;
            try { provider.StopAdvertising(); }
            catch (Exception e) { log($"advertising stop error={e.GetType().Name}"); }
        }
        provider = null; inbound = null; outbound = null;
    }

    public async ValueTask DisposeAsync()
    {
        stopping = true; stop.Cancel();
        if (polling is not null) await polling;
        ingest.Writer.TryComplete(); await ingestWorker;
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await work.Writer.WriteAsync(async () =>
        {
            try { await StopProviderAsync(); }
            finally { stopped.SetResult(); }
        });
        await stopped.Task;
        work.Writer.TryComplete(); await worker;
        stop.Dispose();
    }

    private sealed class Peer(GattSubscribedClient client, GattLocalCharacteristic characteristic, Action<string> log, Func<bool> isStopping, CancellationToken stopToken) : ISyncPeer, IDisposable
    {
        public GattSubscribedClient Client = client;
        public readonly GattSession Session = client.Session;
        public string Id => Session.DeviceId.Id;
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
        private nint throughputRequest;
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
            SetHighThroughput(false);
            log("subscription retired; waiting for reconnect");
        }
        public void SetHighThroughput(bool enabled)
        {
            lock (connGate)
            {
                if (disposed || connParamsUnavailable) return;
                if (enabled && (Rejected || isStopping())) return;
                if (desiredHighThroughput == enabled && (!enabled || throughputRequest != 0)) return;
                desiredHighThroughput = enabled;
                if (connUpdateRunning) return;
                connUpdateRunning = true;
            }
            _ = ReconcileConnectionTuningAsync();
        }
        public void Dispose()
        {
            lock (connGate)
            {
                if (disposed) return;
                disposed = true;
                desiredHighThroughput = false;
                peerCts.Cancel();
                if (connUpdateRunning) return;
                if (throughputRequest == 0 && bleDevice is null)
                {
                    peerCts.Dispose();
                    return;
                }
                connUpdateRunning = true;
            }
            _ = ReconcileConnectionTuningAsync();
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
                if (target && throughputRequest == 0)
                {
                    try
                    {
                        if (bleDevice is null)
                        {
                            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(peerCts.Token);
                            timeout.CancelAfter(TimeSpan.FromSeconds(5));
                            bleDevice = await BluetoothLEDevice.FromIdAsync(Id).AsTask(timeout.Token);
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
                                if (Win11ConnectionParams.TryGetConnectionParameters(bleDevice, out var intervalMs, out var latency, out var timeoutMs))
                                    log($"conn params current intervalMs={intervalMs:F2} latency={latency} timeoutMs={timeoutMs}");
                            }
                            var (status, requestPtr) = Win11ConnectionParams.TryRequestThroughputOptimized(bleDevice);
                            if (status == 1 && requestPtr != 0)
                            {
                                bool keep;
                                lock (connGate)
                                    keep = !disposed && !Rejected && !isStopping() && desiredHighThroughput;
                                if (keep)
                                {
                                    throughputRequest = requestPtr;
                                    log("conn params throughput status=Success");
                                }
                                else
                                {
                                    Win11ConnectionParams.CloseAndReleaseRequest(requestPtr);
                                }
                            }
                            else
                            {
                                if (requestPtr != 0) Win11ConnectionParams.CloseAndReleaseRequest(requestPtr);
                                connParamsUnavailable = true;
                                log($"conn params throughput status={Win11ConnectionParams.StatusLabel(status)}");
                            }
                        }
                    }
                    catch (Exception e)
                    {
                        connParamsUnavailable = true;
                        log($"conn params error={e.GetType().Name}");
                    }
                }
                else if (!target && throughputRequest != 0)
                {
                    Win11ConnectionParams.CloseAndReleaseRequest(throughputRequest);
                    throughputRequest = 0;
                    if (!isDisposed) log("conn params throughput released");
                }
                if (isDisposed)
                {
                    if (throughputRequest != 0)
                    {
                        Win11ConnectionParams.CloseAndReleaseRequest(throughputRequest);
                        throughputRequest = 0;
                    }
                    bleDevice?.Dispose();
                    bleDevice = null;
                    peerCts.Dispose();
                    lock (connGate) { connUpdateRunning = false; }
                    return;
                }
                lock (connGate)
                {
                    var nextTarget = !disposed && !Rejected && !isStopping() && !connParamsUnavailable && desiredHighThroughput;
                    if (!disposed && ((nextTarget && throughputRequest != 0) || (!nextTarget && throughputRequest == 0) || connParamsUnavailable))
                    {
                        connUpdateRunning = false;
                        return;
                    }
                }
            }
        }
    }

    private static class Win11ConnectionParams
    {
        private static readonly Guid IidDevice6 = new("ca7190ef-0cae-573c-a1ca-e1fc5bfc39e2");
        private static readonly Guid IidConnectionParameters = new("33cb0771-8da9-508f-a366-1ca388c929ab");
        private static readonly Guid IidPrefStatics = new("0e3e8edc-2751-55aa-a838-8faeee818d72");
        private static readonly Guid IidPrefRequest = new("8a375276-a528-5266-b661-cce6a5ff9739");
        private static readonly Guid IidClosable = new("30d5a829-7fa4-4026-83bb-d75bae4ea99e");

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetPtrFn(nint self, out nint value);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int RequestPreferredFn(nint self, nint preferredParams, out nint request);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetUShortFn(nint self, out ushort value);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetIntFn(nint self, out int value);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int CloseFn(nint self);

        public static string StatusLabel(int status) => status switch
        {
            0 => "Unspecified",
            1 => "Success",
            2 => "DeviceNotAvailable",
            3 => "AccessDenied",
            -1 => "Unsupported",
            _ => $"Code({status})"
        };

        private static ObjectReference<WinRT.Interop.IUnknownVftbl>? TryGetDevice6(BluetoothLEDevice device) =>
            ((IWinRTObject)device).NativeObject.TryAs<WinRT.Interop.IUnknownVftbl>(IidDevice6, out var dev6Ref) == 0
                ? dev6Ref
                : null;

        public static bool TryGetConnectionParameters(BluetoothLEDevice device, out double intervalMs, out ushort latency, out int timeoutMs)
        {
            intervalMs = 0; latency = 0; timeoutMs = 0;
            using var dev6Ref = TryGetDevice6(device);
            if (dev6Ref is null) return false;
            var vtbl = Marshal.ReadIntPtr(dev6Ref.ThisPtr);
            var getConnParams = Marshal.GetDelegateForFunctionPointer<GetPtrFn>(Marshal.ReadIntPtr(vtbl, 6 * IntPtr.Size));
            if (getConnParams(dev6Ref.ThisPtr, out var pRaw) != 0 || pRaw == 0) return false;
            try
            {
                if (Marshal.QueryInterface(pRaw, in IidConnectionParameters, out var pConn) != 0 || pConn == 0) return false;
                try
                {
                    var cvtbl = Marshal.ReadIntPtr(pConn);
                    var getTimeout = Marshal.GetDelegateForFunctionPointer<GetUShortFn>(Marshal.ReadIntPtr(cvtbl, 6 * IntPtr.Size));
                    var getLatency = Marshal.GetDelegateForFunctionPointer<GetUShortFn>(Marshal.ReadIntPtr(cvtbl, 7 * IntPtr.Size));
                    var getInterval = Marshal.GetDelegateForFunctionPointer<GetUShortFn>(Marshal.ReadIntPtr(cvtbl, 8 * IntPtr.Size));
                    if (getTimeout(pConn, out var rawTimeout) != 0 ||
                        getLatency(pConn, out latency) != 0 ||
                        getInterval(pConn, out var rawInterval) != 0)
                        return false;
                    intervalMs = rawInterval * 1.25;
                    timeoutMs = rawTimeout * 10;
                    return true;
                }
                finally { Marshal.Release(pConn); }
            }
            finally { Marshal.Release(pRaw); }
        }

        public static (int status, nint requestPtr) TryRequestThroughputOptimized(BluetoothLEDevice device)
        {
            using var dev6Ref = TryGetDevice6(device);
            if (dev6Ref is null) return (-1, 0);
            const string className = "Windows.Devices.Bluetooth.BluetoothLEPreferredConnectionParameters";
            if (WindowsCreateString(className, className.Length, out var hstr) != 0) return (-1, 0);
            try
            {
                if (RoGetActivationFactory(hstr, in IidPrefStatics, out var pStatics) != 0 || pStatics == 0) return (-1, 0);
                try
                {
                    var svtbl = Marshal.ReadIntPtr(pStatics);
                    var getThroughput = Marshal.GetDelegateForFunctionPointer<GetPtrFn>(Marshal.ReadIntPtr(svtbl, 7 * IntPtr.Size));
                    if (getThroughput(pStatics, out var pParams) != 0 || pParams == 0) return (-1, 0);
                    try
                    {
                        var dvtbl = Marshal.ReadIntPtr(dev6Ref.ThisPtr);
                        var requestFn = Marshal.GetDelegateForFunctionPointer<RequestPreferredFn>(Marshal.ReadIntPtr(dvtbl, 8 * IntPtr.Size));
                        if (requestFn(dev6Ref.ThisPtr, pParams, out var pRequest) != 0 || pRequest == 0) return (-1, 0);
                        if (Marshal.QueryInterface(pRequest, in IidPrefRequest, out var pTyped) != 0 || pTyped == 0)
                        {
                            Marshal.Release(pRequest);
                            return (-1, 0);
                        }
                        try
                        {
                            var rvtbl = Marshal.ReadIntPtr(pTyped);
                            var getStatus = Marshal.GetDelegateForFunctionPointer<GetIntFn>(Marshal.ReadIntPtr(rvtbl, 6 * IntPtr.Size));
                            return getStatus(pTyped, out var status) == 0 ? (status, pRequest) : (-1, pRequest);
                        }
                        finally { Marshal.Release(pTyped); }
                    }
                    finally { Marshal.Release(pParams); }
                }
                finally { Marshal.Release(pStatics); }
            }
            finally { WindowsDeleteString(hstr); }
        }

        public static void CloseAndReleaseRequest(nint requestPtr)
        {
            if (requestPtr == 0) return;
            try
            {
                if (Marshal.QueryInterface(requestPtr, in IidClosable, out var pClosable) == 0 && pClosable != 0)
                {
                    try
                    {
                        var cvtbl = Marshal.ReadIntPtr(pClosable);
                        var close = Marshal.GetDelegateForFunctionPointer<CloseFn>(Marshal.ReadIntPtr(cvtbl, 6 * IntPtr.Size));
                        _ = close(pClosable);
                    }
                    finally { Marshal.Release(pClosable); }
                }
            }
            catch (Exception) { }
            finally { Marshal.Release(requestPtr); }
        }

        [DllImport("combase.dll")]
        private static extern int RoGetActivationFactory(nint activatableClassId, in Guid iid, out nint factory);
        [DllImport("combase.dll", CharSet = CharSet.Unicode)]
        private static extern int WindowsCreateString(string sourceString, int length, out nint hstring);
        [DllImport("combase.dll")]
        private static extern int WindowsDeleteString(nint hstring);
    }
}
