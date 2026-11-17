using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Channels;
using ClipboardPlus.Windows.Core;
using global::Windows.Devices.Bluetooth;
using global::Windows.Devices.Bluetooth.GenericAttributeProfile;
using global::Windows.Devices.Radios;
using global::Windows.Foundation;
using global::Windows.Storage.Streams;

namespace ClipboardPlus.Windows.Infrastructure;

internal sealed class BleServer : IAsyncDisposable
{
    private static readonly Guid ServiceId = new("E8DB89CB-2BBF-48DD-8D0A-FB868C9A1472");
    private static readonly Guid ToPcId = new("F4508CC7-393F-4288-8B72-A4A9A09D1D4D");
    private static readonly Guid ToPadId = new("3A7ADCFC-CD62-4AF8-BF09-2C73023C5B83");
    private readonly SyncCoordinator coordinator;
    private readonly Action<string> log;
    private readonly Channel<Func<Task>> work = Channel.CreateUnbounded<Func<Task>>(new() { SingleReader = true });
    private readonly CancellationTokenSource stop = new();
    private readonly Task worker;
    private readonly Dictionary<string, Peer> peers = [];
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
    }

    public void Start() => polling = Task.Run(async () =>
    {
        while (!stop.IsCancellationRequested)
        {
            await Queue(async () =>
            {
                try { await CheckAdapterAsync(); }
                catch (UnauthorizedAccessException)
                {
                    await StopProviderAsync();
                    Status("Bluetoothへのアクセスが許可されていません");
                }
                catch (Exception e)
                {
                    await StopProviderAsync();
                    log($"adapter error={e.GetType().Name}");
                    Status("Bluetoothを開始できません。再試行しています");
                }
                await coordinator.TickAsync(DateTimeOffset.UtcNow);
            });
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

    private async Task CheckAdapterAsync()
    {
        if (stopping) return;
        var adapter = await BluetoothAdapter.GetDefaultAsync();
        if (adapter is null || !adapter.IsLowEnergySupported || !adapter.IsPeripheralRoleSupported)
        {
            await StopProviderAsync();
            var radios = await Radio.GetRadiosAsync();
            var bluetooth = radios.FirstOrDefault(r => r.Kind == RadioKind.Bluetooth);
            Status(adapter is null && bluetooth is not null && bluetooth.State != RadioState.On
                ? "Bluetoothがオフです" : "このPCのBluetoothは対応していません"); return;
        }
        var radio = await adapter.GetRadioAsync();
        if (radio is null || radio.State != RadioState.On)
        {
            await StopProviderAsync();
            Status(radio?.State == RadioState.Disabled ? "Bluetoothが無効になっています" : "Bluetoothがオフです");
            return;
        }
        if (provider?.AdvertisementStatus is GattServiceProviderAdvertisementStatus.Started or GattServiceProviderAdvertisementStatus.StartedWithoutAllAdvertisementData)
            return;
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
                log($"advertising status={args.Status} error={args.Error}");
                Status(args.Status is GattServiceProviderAdvertisementStatus.Started or GattServiceProviderAdvertisementStatus.StartedWithoutAllAdvertisementData
                    ? "iPadを待っています" : "Bluetoothの待ち受けを再開しています");
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
            if (!clients.Any(c => c.Session.DeviceId.Id == old.Id)) await RemovePeerAsync(old);
        foreach (var client in clients)
        {
            var id = client.Session.DeviceId.Id;
            if (peers.TryGetValue(id, out var existing)) { existing.Client = client; continue; }
            var peer = new Peer(client, outbound, log, () => stopping);
            peer.StatusHandler = (session, args) => _ = Queue(async () =>
            {
                if (args.Status == GattSessionStatus.Closed && peers.GetValueOrDefault(peer.Id) == peer)
                    await RemovePeerAsync(peer);
            });
            peer.MtuHandler = (session, args) => log($"mtu pdu={session.MaxPduSize}");
            peer.Session.SessionStatusChanged += peer.StatusHandler;
            peer.Session.MaxPduSizeChanged += peer.MtuHandler;
            peers.Add(id, peer);
            log($"subscribed mtu={client.Session.MaxPduSize}");
            await coordinator.ConnectAsync(peer);
        }
    }

    private void WriteRequested(GattLocalCharacteristic sender, GattWriteRequestedEventArgs args)
    {
        var deferral = args.GetDeferral();
        // Acquire the deferral synchronously, and enqueue before awaiting GetRequestAsync,
        // so write-without-response packets cannot overtake each other.
        _ = Queue(async () =>
        {
            GattWriteRequest? request = null;
            try
            {
                request = await args.GetRequestAsync();
                if (request is null) return;
                var ok = false;
                if (sender == inbound && !stopping)
                {
                    await UpdateSubscriptionsAsync();
                    if (peers.TryGetValue(args.Session.DeviceId.Id, out var peer) && !peer.Rejected)
                    {
                        if (request.Offset == 0)
                            ok = await coordinator.ReceiveAsync(peer, request.Value.ToArray());
                        else await coordinator.DisconnectAsync(peer);
                    }
                }
                if (request.Option == GattWriteOption.WriteWithResponse)
                {
                    if (ok) request.Respond();
                    else request.RespondWithProtocolError(0x0E); // ATT Unlikely Error
                }
            }
            catch (Exception e)
            {
                log($"write request error={e.GetType().Name}");
                if (peers.TryGetValue(args.Session.DeviceId.Id, out var peer)) await coordinator.DisconnectAsync(peer);
                try { if (request?.Option == GattWriteOption.WriteWithResponse) request.RespondWithProtocolError(0x0E); }
                catch (Exception) { /* Request may already have expired. */ }
            }
            finally { deferral.Complete(); }
        });
    }

    private async Task RemovePeerAsync(Peer peer)
    {
        peers.Remove(peer.Id);
        peer.Session.SessionStatusChanged -= peer.StatusHandler;
        peer.Session.MaxPduSizeChanged -= peer.MtuHandler;
        await coordinator.DisconnectAsync(peer);
    }

    private async Task StopProviderAsync()
    {
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
        await Queue(StopProviderAsync);
        work.Writer.TryComplete(); await worker;
        stop.Dispose();
    }

    private sealed class Peer(GattSubscribedClient client, GattLocalCharacteristic characteristic, Action<string> log, Func<bool> isStopping) : ISyncPeer
    {
        public GattSubscribedClient Client = client;
        public readonly GattSession Session = client.Session;
        public string Id => Session.DeviceId.Id;
        public bool Rejected { get; private set; }
        public TypedEventHandler<GattSession, GattSessionStatusChangedEventArgs>? StatusHandler;
        public TypedEventHandler<GattSession, object>? MtuHandler;
        public int PacketLimit => Math.Max(20, Client.Session.MaxPduSize - 3);
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
            Rejected = true;
            log("subscription retired; waiting for reconnect");
        }
    }
}
