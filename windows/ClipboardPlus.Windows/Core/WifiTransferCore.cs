using System.Globalization;
using System.Security.Cryptography;
using ClipboardPlus.Sync;

namespace ClipboardPlus.Windows.Core;

public enum WifiApMode
{
    Hotspot5GHz,
    HotspotAuto,
    WifiDirect,
}

public sealed record WifiTransferCredentials(
    Guid Session,
    string Ssid,
    string Passphrase,
    byte[] Token)
{
    private const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

    public static WifiTransferCredentials CreateRandom()
    {
        var session = Guid.NewGuid();
        var ssid = "DIRECT-cp-" + RandomText(8);
        var passphrase = RandomText(SyncProtocol.WifiMinPassphraseBytes);
        var token = RandomNumberGenerator.GetBytes(32);
        return new WifiTransferCredentials(session, ssid, passphrase, token);
    }

    private static string RandomText(int length)
    {
        Span<char> chars = stackalloc char[length];
        for (var i = 0; i < length; i++)
            chars[i] = Alphabet[RandomNumberGenerator.GetInt32(Alphabet.Length)];
        return new string(chars);
    }

    // Never expose session, SSID, passphrase, or one-time token in logs or formatting.
    public override string ToString() => "WifiTransferCredentials { Redacted = true }";
}

public sealed record WifiTransferOptions(
    int TtlSeconds = 90,
    TimeSpan? PreAuthReadTimeout = null,
    TimeSpan? PostAuthIdleTimeout = null,
    TimeSpan? PostDoneCloseGrace = null,
    Func<TimeSpan, CancellationToken, Task>? DelayAsync = null,
    Func<WifiTransferCredentials>? CredentialsFactory = null)
{
    public static readonly WifiTransferOptions Default = new();

    public TimeSpan EffectivePreAuthReadTimeout => PreAuthReadTimeout ?? TimeSpan.FromSeconds(5);
    public TimeSpan EffectivePostAuthIdleTimeout => PostAuthIdleTimeout ?? TimeSpan.FromSeconds(10);
    public TimeSpan EffectivePostDoneCloseGrace => PostDoneCloseGrace ?? TimeSpan.FromSeconds(2);
    public Func<TimeSpan, CancellationToken, Task> EffectiveDelayAsync => DelayAsync ?? Task.Delay;
}

public sealed class WifiAcceptedConnection(
    Stream stream,
    Action? shutdownSend = null,
    IAsyncDisposable? owner = null) : IAsyncDisposable
{
    public Stream Stream { get; } = stream ?? throw new ArgumentNullException(nameof(stream));

    public void ShutdownSend() => shutdownSend?.Invoke();

    public async ValueTask DisposeAsync()
    {
        try { await Stream.DisposeAsync().ConfigureAwait(false); }
        catch { }
        if (owner is not null)
        {
            try { await owner.DisposeAsync().ConfigureAwait(false); }
            catch { }
        }
    }
}

public interface IWifiTransferSessionHandle : IAsyncDisposable
{
    WifiApMode Mode { get; }
    string ActualSsid { get; }
    string Ip { get; }
    int Port { get; }
    Task<WifiAcceptedConnection> AcceptAsync(CancellationToken cancellationToken);
    void StopSync();
}

public sealed record WifiHostStartResult(
    bool Succeeded,
    IWifiTransferSessionHandle? Handle,
    WifiUnavailableReason FailureReason = WifiUnavailableReason.StartFailed)
{
    public static WifiHostStartResult Success(IWifiTransferSessionHandle handle) =>
        new(true, handle, WifiUnavailableReason.StartFailed);

    public static WifiHostStartResult Failure(WifiUnavailableReason reason) =>
        new(false, null, reason);
}

public interface IWifiTransferHost
{
    Task<WifiHostStartResult> StartAsync(WifiTransferCredentials credentials, CancellationToken cancellationToken);
    void StopSync();
}

public sealed record WifiApAttemptResult(
    bool Succeeded,
    IWifiTransferSessionHandle? Handle,
    string? ErrorCode = null,
    WifiUnavailableReason? TerminalReason = null)
{
    public static WifiApAttemptResult Success(IWifiTransferSessionHandle handle) => new(true, handle);

    public static WifiApAttemptResult Failure(string errorCode, WifiUnavailableReason? terminalReason = null) =>
        new(false, null, errorCode, terminalReason);
}

public interface IWifiApBackend
{
    bool HasInternetConnection();
    Task<WifiApAttemptResult> TryStartHotspotAsync(WifiTransferCredentials credentials, CancellationToken cancellationToken);
    Task<WifiApAttemptResult> TryStartWifiDirectAsync(WifiTransferCredentials credentials, CancellationToken cancellationToken);
}

/// <summary>
/// Selects the primary Windows AP mode (5GHz Mobile Hotspot when online, Wi-Fi Direct Legacy when offline)
/// and falls back to the alternate mode after a brief settle delay when the primary fails.
/// </summary>
public static class WifiApStarter
{
    public static readonly TimeSpan DefaultFallbackDelay = TimeSpan.FromMilliseconds(800);

    public static async Task<WifiHostStartResult> StartWithFallbackAsync(
        IWifiApBackend backend,
        WifiTransferCredentials credentials,
        Action<string> log,
        TimeSpan? fallbackDelay = null,
        Func<TimeSpan, CancellationToken, Task>? delayAsync = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(backend);
        ArgumentNullException.ThrowIfNull(credentials);
        ArgumentNullException.ThrowIfNull(log);

        var online = backend.HasInternetConnection();
        var primaryName = online ? "hotspot" : "wifiDirect";
        var fallbackName = online ? "wifiDirect" : "hotspot";

        var primary = online
            ? await backend.TryStartHotspotAsync(credentials, cancellationToken).ConfigureAwait(false)
            : await backend.TryStartWifiDirectAsync(credentials, cancellationToken).ConfigureAwait(false);

        if (primary.Succeeded && primary.Handle is not null)
            return WifiHostStartResult.Success(primary.Handle);

        if (primary.TerminalReason is { } terminal)
            return WifiHostStartResult.Failure(terminal);

        cancellationToken.ThrowIfCancellationRequested();
        log($"wifi ap primary failed mode={primaryName} reason={primary.ErrorCode ?? "unknown"}");

        var wait = fallbackDelay ?? DefaultFallbackDelay;
        if (wait > TimeSpan.Zero)
        {
            var delay = delayAsync ?? Task.Delay;
            await delay(wait, cancellationToken).ConfigureAwait(false);
        }

        var secondary = online
            ? await backend.TryStartWifiDirectAsync(credentials, cancellationToken).ConfigureAwait(false)
            : await backend.TryStartHotspotAsync(credentials, cancellationToken).ConfigureAwait(false);

        if (secondary.Succeeded && secondary.Handle is not null)
            return WifiHostStartResult.Success(secondary.Handle);

        if (secondary.TerminalReason is { } secondaryTerminal)
            return WifiHostStartResult.Failure(secondaryTerminal);

        log($"wifi ap fallback failed mode={fallbackName} reason={secondary.ErrorCode ?? "unknown"}");
        return WifiHostStartResult.Failure(WifiUnavailableReason.StartFailed);
    }
}

public sealed record HotspotBackupRecord(
    string Ssid,
    string Passphrase,
    int? Band,
    string TempSsid)
{
    public bool IsRestorable =>
        !string.IsNullOrEmpty(Ssid) &&
        !string.IsNullOrEmpty(Passphrase) &&
        Passphrase.Length >= 8;

    public bool ShouldRestoreForCurrentSsid(string? currentSsid) =>
        IsRestorable &&
        !string.IsNullOrEmpty(TempSsid) &&
        string.Equals(currentSsid, TempSsid, StringComparison.Ordinal);

    // Never expose SSID or passphrase in logs/formatting.
    public override string ToString() => "HotspotBackupRecord { Redacted = true }";
}

/// <summary>
/// Wraps an underlying duplex stream with switchable per-read / per-write inactivity timeouts
/// using an injectable delay delegate so timeouts can be driven deterministically in tests.
/// </summary>
public sealed class IdleTimeoutStream : Stream
{
    private readonly Stream inner;
    private readonly Func<TimeSpan, CancellationToken, Task> delayAsync;
    private readonly Action? onTimeout;
    private long timeoutTicks;

    public IdleTimeoutStream(
        Stream inner,
        TimeSpan initialTimeout,
        Func<TimeSpan, CancellationToken, Task>? delayAsync = null,
        Action? onTimeout = null)
    {
        this.inner = inner ?? throw new ArgumentNullException(nameof(inner));
        this.delayAsync = delayAsync ?? Task.Delay;
        this.onTimeout = onTimeout;
        Timeout = initialTimeout;
    }

    public TimeSpan Timeout
    {
        get => TimeSpan.FromTicks(Volatile.Read(ref timeoutTicks));
        set
        {
            if (value <= TimeSpan.Zero)
                throw new ArgumentOutOfRangeException(nameof(value));
            Volatile.Write(ref timeoutTicks, value.Ticks);
        }
    }

    public override bool CanRead => inner.CanRead;
    public override bool CanSeek => false;
    public override bool CanWrite => inner.CanWrite;
    public override long Length => throw new NotSupportedException();
    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    public override void Flush() => inner.Flush();
    public override Task FlushAsync(CancellationToken cancellationToken) => inner.FlushAsync(cancellationToken);
    public override int Read(byte[] buffer, int offset, int count) =>
        ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) =>
        WriteAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var opCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);

        var readTask = inner.ReadAsync(buffer, opCts.Token).AsTask();
        var delayTask = delayAsync(Timeout, timeoutCts.Token);

        var winner = await Task.WhenAny(readTask, delayTask).ConfigureAwait(false);
        if (ReferenceEquals(winner, readTask))
        {
            timeoutCts.Cancel();
            ObserveSilently(delayTask);
            return await readTask.ConfigureAwait(false);
        }

        if (cancellationToken.IsCancellationRequested)
        {
            opCts.Cancel();
            ObserveSilently(readTask);
            cancellationToken.ThrowIfCancellationRequested();
        }

        if (readTask.IsCompleted)
            return await readTask.ConfigureAwait(false);

        opCts.Cancel();
        try { onTimeout?.Invoke(); } catch { }
        ObserveSilently(readTask);
        throw new TimeoutException("Wi-Fi transfer read timed out.");
    }

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var opCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);

        var writeTask = inner.WriteAsync(buffer, opCts.Token).AsTask();
        var delayTask = delayAsync(Timeout, timeoutCts.Token);

        var winner = await Task.WhenAny(writeTask, delayTask).ConfigureAwait(false);
        if (ReferenceEquals(winner, writeTask))
        {
            timeoutCts.Cancel();
            ObserveSilently(delayTask);
            await writeTask.ConfigureAwait(false);
            return;
        }

        if (cancellationToken.IsCancellationRequested)
        {
            opCts.Cancel();
            ObserveSilently(writeTask);
            cancellationToken.ThrowIfCancellationRequested();
        }

        if (writeTask.IsCompleted)
        {
            await writeTask.ConfigureAwait(false);
            return;
        }

        opCts.Cancel();
        try { onTimeout?.Invoke(); } catch { }
        ObserveSilently(writeTask);
        throw new TimeoutException("Wi-Fi transfer write timed out.");
    }

    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    private static void ObserveSilently(Task task)
    {
        if (task.IsCompleted)
        {
            _ = task.Exception;
            return;
        }
        _ = task.ContinueWith(static t => { _ = t.Exception; },
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }
}

public static class WifiTransferLogFormat
{
    public static string Mode(WifiApMode mode) => mode switch
    {
        WifiApMode.Hotspot5GHz => "hotspot5",
        WifiApMode.HotspotAuto => "hotspotAuto",
        WifiApMode.WifiDirect => "wifiDirect",
        _ => "unknown",
    };

    public static string Direction(WifiTransferDirection direction) => direction switch
    {
        WifiTransferDirection.Send => "send",
        WifiTransferDirection.Receive => "receive",
        WifiTransferDirection.Both => "both",
        _ => "unknown",
    };

    public static string UnavailableReason(WifiUnavailableReason reason) => reason switch
    {
        WifiUnavailableReason.Unsupported => "unsupported",
        WifiUnavailableReason.Busy => "busy",
        WifiUnavailableReason.Conflict => "conflict",
        WifiUnavailableReason.StartFailed => "start_failed",
        WifiUnavailableReason.Disabled => "disabled",
        _ => "unknown",
    };

    public static string JoinStatus(WifiJoinStatus status) => status switch
    {
        WifiJoinStatus.Joined => "joined",
        WifiJoinStatus.UserDenied => "user_denied",
        WifiJoinStatus.NotForeground => "not_foreground",
        WifiJoinStatus.JoinFailed => "join_failed",
        WifiJoinStatus.Timeout => "timeout",
        _ => "unknown",
    };

    public static string CancelReason(WifiCancelReason reason) => reason switch
    {
        WifiCancelReason.UserCancelled => "user_cancelled",
        WifiCancelReason.Timeout => "timeout",
        WifiCancelReason.TcpFailed => "tcp_failed",
        WifiCancelReason.ProtocolError => "protocol_error",
        WifiCancelReason.Completed => "completed",
        WifiCancelReason.Superseded => "superseded",
        _ => "unknown",
    };

    public static string Ready(WifiApMode mode, WifiTransferDirection direction, int requestedItems, long apElapsedMs) =>
        string.Create(
            CultureInfo.InvariantCulture,
            $"wifi transfer ready mode={Mode(mode)} direction={Direction(direction)} items={requestedItems} apMs={Math.Max(0, apElapsedMs)}");

    public static string Start(WifiApMode mode, int items, long bytes) =>
        string.Create(
            CultureInfo.InvariantCulture,
            $"wifi transfer start mode={Mode(mode)} items={items} bytes={Math.Max(0, bytes)}");

    public static string Done(WifiApMode mode, int receivedItems, int sentItems, long bytes, TimeSpan elapsed)
    {
        var elapsedMs = Math.Max(0L, (long)elapsed.TotalMilliseconds);
        var speed = WifiProbeText.SpeedMBPerSecond(bytes, elapsed) ?? 0.0;
        return string.Create(
            CultureInfo.InvariantCulture,
            $"wifi transfer done mode={Mode(mode)} received={receivedItems} sent={sentItems} items={receivedItems + sentItems} bytes={Math.Max(0, bytes)} elapsedMs={elapsedMs} speedMBps={speed:0.00}");
    }

    public static string Fallback(string reasonCode) =>
        $"wifi transfer fallback reason={reasonCode}";

    public static string Join(WifiJoinStatus status) =>
        $"wifi transfer join status={JoinStatus(status)}";
}
