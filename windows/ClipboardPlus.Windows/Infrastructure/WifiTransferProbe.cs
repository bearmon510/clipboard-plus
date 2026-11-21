using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Windows.Threading;
using ClipboardPlus.Windows.Core;
using global::Windows.Devices.WiFiDirect;
using global::Windows.Networking.Connectivity;
using global::Windows.Networking.NetworkOperators;
using global::Windows.Security.Credentials;

namespace ClipboardPlus.Windows.Infrastructure;

internal sealed class WifiTransferProbe : IAsyncDisposable
{
    private readonly Action<string> log;
    private readonly Dispatcher? dispatcher;
    private readonly SemaphoreSlim lifecycleGate = new(1, 1);
    private readonly object stateLock = new();

    private CancellationTokenSource? sessionCts;
    private WiFiDirectAdvertisementPublisher? publisher;
    private NetworkOperatorTetheringManager? tetheringManager;
    private NetworkOperatorTetheringAccessPointConfiguration? previousTetheringConfig;
    private TcpListener? listener;
    private Task? acceptLoop;
    private WifiProbeSnapshot snapshot;
    private volatile bool disposed;

    public event Action<WifiProbeSnapshot>? SnapshotChanged;

    public WifiTransferProbe(Action<string> log, Dispatcher? dispatcher = null)
    {
        this.log = log;
        this.dispatcher = dispatcher;
        snapshot = new WifiProbeSnapshot(
            IsRunning: false,
            Mode: WifiProbeMode.WifiDirectLegacy,
            StatusMessage: "まだ始めていません。",
            ErrorMessage: null,
            QrPayload: null,
            ApStartingAt: null,
            ApReadyAt: null,
            ApStartDuration: null,
            ConnectedAt: null,
            PayloadBytes: null,
            ReceivedAt: null,
            UploadDuration: null,
            SentAt: null,
            DownloadDuration: null,
            CompletedRuns: 0);
    }

    public WifiProbeSnapshot CurrentSnapshot
    {
        get { lock (stateLock) return snapshot; }
    }

    public async Task StartAsync(WifiProbeMode mode)
    {
        await lifecycleGate.WaitAsync();
        try
        {
            await StopInternalAsync(preserveResult: false);

            var cts = new CancellationTokenSource();
            sessionCts = cts;
            var credentials = WifiProbeCredentials.CreateRandom();
            var startingAt = DateTimeOffset.Now;
            var startClock = Stopwatch.StartNew();

            UpdateSnapshot(_ => new WifiProbeSnapshot(
                IsRunning: true,
                Mode: mode,
                StatusMessage: $"{WifiProbeText.ModeName(mode)} で小さなWi-Fiを作っています…",
                ErrorMessage: null,
                QrPayload: null,
                ApStartingAt: startingAt,
                ApReadyAt: null,
                ApStartDuration: null,
                ConnectedAt: null,
                PayloadBytes: null,
                ReceivedAt: null,
                UploadDuration: null,
                SentAt: null,
                DownloadDuration: null,
                CompletedRuns: 0));
            log($"wifi probe starting mode={mode}");

            try
            {
                var actualSsid = mode == WifiProbeMode.WifiDirectLegacy
                    ? await StartWifiDirectLegacyAsync(credentials, cts.Token)
                    : await StartMobileHotspotAsync(credentials, cts.Token);

                var (boundListener, virtualIp) = await BindVirtualAdapterListenerAsync(cts.Token);
                listener = boundListener;
                var port = ((IPEndPoint)boundListener.LocalEndpoint).Port;

                startClock.Stop();
                var readyAt = DateTimeOffset.Now;
                var qr = new WifiProbeQrPayload(actualSsid, credentials.Passphrase, virtualIp.ToString(), port, credentials.Token);

                log(string.Create(
                    CultureInfo.InvariantCulture,
                    $"wifi probe ap ready mode={mode} elapsedMs={(long)startClock.Elapsed.TotalMilliseconds} ipKind={WifiProbeIpSelector.ClassifySubnet(virtualIp)}"));

                UpdateSnapshot(s => s with
                {
                    StatusMessage = $"待機中（{virtualIp}:{port}）。iPhone・iPadでQRコードを読んでください。",
                    QrPayload = qr,
                    ApReadyAt = readyAt,
                    ApStartDuration = startClock.Elapsed,
                });

                acceptLoop = Task.Run(() => AcceptLoopAsync(boundListener, credentials.Token, cts.Token));
            }
            catch (OperationCanceledException)
            {
                await CleanupHardwareAsync();
                UpdateSnapshot(s => s with
                {
                    IsRunning = false,
                    QrPayload = null,
                    StatusMessage = "試験を止めました。",
                });
            }
            catch (Exception ex)
            {
                var message = ex is ProbeException pe
                    ? pe.Message
                    : $"小さなWi-Fiを作れませんでした（{ex.GetType().Name}）。";
                log($"wifi probe error stage=start mode={mode} reason={ex.GetType().Name}");
                await CleanupHardwareAsync();
                UpdateSnapshot(s => s with
                {
                    IsRunning = false,
                    QrPayload = null,
                    StatusMessage = "開始できませんでした。",
                    ErrorMessage = message,
                });
            }
        }
        finally
        {
            lifecycleGate.Release();
        }
    }

    public async Task StopAsync()
    {
        await lifecycleGate.WaitAsync();
        try
        {
            await StopInternalAsync(preserveResult: true);
        }
        finally
        {
            lifecycleGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        disposed = true;
        await StopAsync();
        lifecycleGate.Dispose();
    }

    public void StopSync()
    {
        try { sessionCts?.Cancel(); } catch { }
        try { listener?.Stop(); } catch { }
        try { publisher?.Stop(); } catch { }
        var manager = tetheringManager;
        tetheringManager = null;
        if (manager is not null)
        {
            try
            {
                if (manager.TetheringOperationalState == TetheringOperationalState.On)
                    manager.StopTetheringAsync().AsTask().Wait(TimeSpan.FromSeconds(1.5));
            }
            catch { }
        }
    }

    private async Task StopInternalAsync(bool preserveResult)
    {
        var hadActive = sessionCts is not null || publisher is not null || tetheringManager is not null || listener is not null;
        await CleanupHardwareAsync();
        if (hadActive)
            log("wifi probe stopped");

        if (preserveResult && hadActive)
        {
            UpdateSnapshot(s => s with
            {
                IsRunning = false,
                QrPayload = null,
                StatusMessage = "試験を終えました。",
            });
        }
    }

    private async Task CleanupHardwareAsync()
    {
        var cts = sessionCts;
        sessionCts = null;
        if (cts is not null)
        {
            try { cts.Cancel(); } catch { }
        }

        var activeListener = listener;
        listener = null;
        if (activeListener is not null)
        {
            try { activeListener.Stop(); } catch { }
        }

        var loop = acceptLoop;
        acceptLoop = null;
        if (loop is not null)
        {
            try { await loop.WaitAsync(TimeSpan.FromSeconds(2)); } catch { }
        }

        var activePublisher = publisher;
        publisher = null;
        if (activePublisher is not null)
        {
            activePublisher.StatusChanged -= OnPublisherStatusChanged;
            try { activePublisher.Stop(); } catch { }
        }

        var activeTethering = tetheringManager;
        var prevConfig = previousTetheringConfig;
        tetheringManager = null;
        previousTetheringConfig = null;
        if (activeTethering is not null)
        {
            try
            {
                using var stopTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(4));
                if (activeTethering.TetheringOperationalState == TetheringOperationalState.On)
                    await activeTethering.StopTetheringAsync().AsTask(stopTimeout.Token);
                if (prevConfig is not null &&
                    !string.IsNullOrEmpty(prevConfig.Ssid) &&
                    !string.IsNullOrEmpty(prevConfig.Passphrase) &&
                    prevConfig.Passphrase.Length >= 8)
                {
                    await activeTethering.ConfigureAccessPointAsync(prevConfig).AsTask(stopTimeout.Token);
                }
            }
            catch (Exception ex)
            {
                log($"wifi probe tethering cleanup error={ex.GetType().Name}");
            }
        }

        cts?.Dispose();
    }

    private async Task<string> StartWifiDirectLegacyAsync(WifiProbeCredentials credentials, CancellationToken ct)
    {
        var pub = new WiFiDirectAdvertisementPublisher();
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
        publisher = pub;
        try
        {
            pub.Start();
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeoutCts.CancelAfter(TimeSpan.FromSeconds(10));
            using var reg = timeoutCts.Token.Register(() => tcs.TrySetCanceled(timeoutCts.Token));

            var (status, error) = await tcs.Task;
            if (status != WiFiDirectAdvertisementPublisherStatus.Started)
            {
                log($"wifi probe direct aborted error={error}");
                throw new ProbeException(DescribeWiFiDirectError(error));
            }

            pub.StatusChanged += OnPublisherStatusChanged;
            var actualSsid = pub.Advertisement.LegacySettings.Ssid;
            return string.IsNullOrWhiteSpace(actualSsid) ? credentials.Ssid : actualSsid;
        }
        catch (ProbeException)
        {
            throw;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new ProbeException("Wi-Fi Direct の開始が時間切れになりました。Wi-Fi がオンになっているか確認してください。");
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            log($"wifi probe direct exception={ex.GetType().Name} hr=0x{ex.HResult:X8}");
            throw new ProbeException("Wi-Fi Direct を開始できませんでした。PCのWi-Fiがオンか、対応アダプタか確認してください。");
        }
        finally
        {
            pub.StatusChanged -= OnInitialStatus;
        }
    }

    private void OnPublisherStatusChanged(WiFiDirectAdvertisementPublisher sender, WiFiDirectAdvertisementPublisherStatusChangedEventArgs args)
    {
        if (!ReferenceEquals(sender, publisher)) return;
        if (args.Status == WiFiDirectAdvertisementPublisherStatus.Aborted)
        {
            log($"wifi probe direct interrupted error={args.Error}");
            UpdateSnapshot(s => s with
            {
                IsRunning = false,
                QrPayload = null,
                StatusMessage = "Wi-Fi Direct が中断されました。",
                ErrorMessage = DescribeWiFiDirectError(args.Error),
            });
            _ = Task.Run(StopAsync);
        }
    }

    private async Task<string> StartMobileHotspotAsync(WifiProbeCredentials credentials, CancellationToken ct)
    {
        var profile = NetworkInformation.GetInternetConnectionProfile();
        if (profile is null)
            throw new ProbeException("PCがインターネットにつながっていないため、モバイルホットスポットを開始できません。「Wi-Fi Direct（レガシー）」を試してください。");

        var capability = NetworkOperatorTetheringManager.GetTetheringCapabilityFromConnectionProfile(profile);
        if (capability != TetheringCapability.Enabled)
        {
            log($"wifi probe tethering capability={capability}");
            throw new ProbeException(DescribeTetheringCapability(capability));
        }

        NetworkOperatorTetheringManager manager;
        try
        {
            manager = NetworkOperatorTetheringManager.CreateFromConnectionProfile(profile);
        }
        catch (Exception ex)
        {
            log($"wifi probe tethering create error={ex.GetType().Name}");
            throw new ProbeException("モバイルホットスポットを作成できませんでした。");
        }

        if (manager.TetheringOperationalState == TetheringOperationalState.On)
            throw new ProbeException("すでにWindowsのモバイルホットスポットがオンです。設定を壊さないよう、いったんオフにしてから試してください。");

        tetheringManager = manager;
        try { previousTetheringConfig = manager.GetCurrentAccessPointConfiguration(); }
        catch { previousTetheringConfig = null; }

        var config = new NetworkOperatorTetheringAccessPointConfiguration
        {
            Ssid = credentials.Ssid,
            Passphrase = credentials.Passphrase,
        };
        await manager.ConfigureAccessPointAsync(config).AsTask(ct);

        var result = await manager.StartTetheringAsync().AsTask(ct);
        if (result.Status != TetheringOperationStatus.Success)
        {
            log($"wifi probe tethering start status={result.Status}");
            throw new ProbeException($"モバイルホットスポットを開始できませんでした（{result.Status}）。");
        }

        return credentials.Ssid;
    }

    private async Task<(TcpListener Listener, IPAddress Address)> BindVirtualAdapterListenerAsync(CancellationToken ct)
    {
        var waitClock = Stopwatch.StartNew();
        while (waitClock.Elapsed < TimeSpan.FromSeconds(8))
        {
            ct.ThrowIfCancellationRequested();
            var allowApipa = waitClock.Elapsed >= TimeSpan.FromSeconds(2);
            var allowNonUp = waitClock.Elapsed >= TimeSpan.FromSeconds(3.5);
            var adapters = NetworkAdapterSnapshot.CaptureSystem();
            var ip = WifiProbeIpSelector.SelectIp(adapters, allowApipa: allowApipa, allowNonUp: allowNonUp);
            if (ip is not null)
            {
                try
                {
                    var tcp = new TcpListener(ip, 0);
                    tcp.Start(1);
                    return (tcp, ip);
                }
                catch (SocketException ex)
                {
                    log($"wifi probe bind retry socketError={ex.SocketErrorCode}");
                }
            }
            await Task.Delay(150, ct);
        }

        log("wifi probe error stage=bind reason=VirtualAdapterIpNotFound");
        throw new ProbeException(
            "仮想アダプタの IPv4 アドレスが見つかりませんでした。Wi-Fi がオンか確認するか、別の方式（モバイルホットスポット等）を切り替えて試してください。");
    }

    private async Task AcceptLoopAsync(TcpListener tcpListener, string expectedToken, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient? client = null;
            try
            {
                client = await tcpListener.AcceptTcpClientAsync(ct);
                // Keep default SendBufferSize so Windows TCP auto-tuning stays active.
                client.NoDelay = true;
                client.ReceiveTimeout = 30_000;
                client.SendTimeout = 30_000;

                var connectedAt = DateTimeOffset.Now;
                using (client)
                await using (var stream = client.GetStream())
                {
                    using var sessionTimeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
                    sessionTimeout.CancelAfter(TimeSpan.FromMinutes(3));

                    var outcome = await WifiProbeWire.RunEchoServerSessionAsync(
                        stream,
                        expectedToken,
                        onAccepted: size =>
                        {
                            log($"wifi probe tcp connected bytes={size}");
                            UpdateSnapshot(s => s with
                            {
                                StatusMessage = $"{SyncStatusText.Bytes(size)} の試験データを受け取っています…",
                                ErrorMessage = null,
                                ConnectedAt = connectedAt,
                                PayloadBytes = size,
                                ReceivedAt = null,
                                UploadDuration = null,
                                SentAt = null,
                                DownloadDuration = null,
                            });
                        },
                        onReceived: (size, elapsed) =>
                        {
                            var receivedAt = DateTimeOffset.Now;
                            var speed = WifiProbeText.SpeedMBPerSecond(size, elapsed);
                            log(string.Create(
                                CultureInfo.InvariantCulture,
                                $"wifi probe received bytes={size} elapsedMs={(long)elapsed.TotalMilliseconds} speedMBps={speed ?? 0:0.00}"));
                            UpdateSnapshot(s => s with
                            {
                                StatusMessage = $"{SyncStatusText.Bytes(size)} を受け取り終えました。同じ大きさを送り返しています…",
                                ReceivedAt = receivedAt,
                                UploadDuration = elapsed,
                            });
                        },
                        onSent: metrics =>
                        {
                            var sentAt = DateTimeOffset.Now;
                            log(WifiProbeText.FormatSentLog(metrics));
                            UpdateSnapshot(s => s with
                            {
                                StatusMessage = $"1回の往復試験が終わりました（送信・返送とも完了）。続けて試すこともできます。",
                                SentAt = sentAt,
                                DownloadDuration = metrics.TotalElapsed,
                                CompletedRuns = s.CompletedRuns + 1,
                            });
                        },
                        cancellationToken: sessionTimeout.Token);

                    if (!outcome.Accepted)
                    {
                        log($"wifi probe auth rejected status={outcome.StatusCode}");
                        UpdateSnapshot(s => s with
                        {
                            ErrorMessage = outcome.StatusCode == WifiProbeWire.AckAuthFailed
                                ? "合言葉が一致しませんでした。表示中のQRコードを読み直してください。"
                                : "試験要求の形式または大きさが正しくありませんでした。",
                        });
                    }
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                log($"wifi probe tcp error={ex.GetType().Name}");
                UpdateSnapshot(s => s with
                {
                    ErrorMessage = $"通信中にエラーが起きました（{ex.GetType().Name}）。もう一度試すか、ファイアウォール設定を確認してください。",
                });
            }
            finally
            {
                client?.Dispose();
            }
        }
    }

    private void UpdateSnapshot(Func<WifiProbeSnapshot, WifiProbeSnapshot> transform)
    {
        WifiProbeSnapshot next;
        lock (stateLock)
        {
            snapshot = transform(snapshot);
            next = snapshot;
        }
        if (dispatcher is not null && !dispatcher.CheckAccess())
            _ = dispatcher.BeginInvoke(() => SnapshotChanged?.Invoke(next));
        else
            SnapshotChanged?.Invoke(next);
    }

    private static string DescribeWiFiDirectError(WiFiDirectError error) => error switch
    {
        WiFiDirectError.RadioNotAvailable => "Wi-Fi がオフか、このPCのアダプタが Wi-Fi Direct に対応していません。「モバイルホットスポット」も試してください。",
        WiFiDirectError.ResourceInUse => "別の機能（モバイルホットスポット等）が Wi-Fi Direct を使っているため開始できませんでした。",
        _ => $"Wi-Fi Direct を開始できませんでした（{error}）。",
    };

    private static string DescribeTetheringCapability(TetheringCapability capability) => capability switch
    {
        TetheringCapability.DisabledByGroupPolicy => "グループポリシーでモバイルホットスポットが禁止されています。",
        TetheringCapability.DisabledByHardwareLimitation => "このPCのネットワーク構成ではモバイルホットスポットを使えません。",
        TetheringCapability.DisabledBySystemCapability => "システムの権限でモバイルホットスポットが無効になっています。",
        TetheringCapability.DisabledByOperator => "通信事業者の制限でモバイルホットスポットを使えません。",
        _ => $"モバイルホットスポットを使えません（{capability}）。",
    };

    private sealed class ProbeException(string message) : Exception(message);
}
