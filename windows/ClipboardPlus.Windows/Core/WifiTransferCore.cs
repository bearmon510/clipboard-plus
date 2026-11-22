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
    Func<WifiTransferCredentials>? CredentialsFactory = null,
    TimeSpan? StartTimeout = null)
{
    public static readonly WifiTransferOptions Default = new();

    public TimeSpan EffectivePreAuthReadTimeout => PreAuthReadTimeout ?? TimeSpan.FromSeconds(5);
    public TimeSpan EffectivePostAuthIdleTimeout => PostAuthIdleTimeout ?? TimeSpan.FromSeconds(10);
    public TimeSpan EffectivePostDoneCloseGrace => PostDoneCloseGrace ?? TimeSpan.FromSeconds(2);
    public TimeSpan EffectiveStartTimeout => StartTimeout ?? WifiApStarter.DefaultTotalStartTimeout;
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

public sealed class WifiStepTimeoutException(string code) : TimeoutException($"Wi-Fi step timed out: {code}")
{
    public string Code { get; } = code;
}

public static class WifiStepTimeout
{
    public static async Task<T> RunAsync<T>(
        Func<CancellationToken, Task<T>> operation,
        TimeSpan timeout,
        string timeoutCode,
        CancellationToken cancellationToken,
        Func<TimeSpan, CancellationToken, Task>? delayAsync = null)
    {
        ArgumentNullException.ThrowIfNull(operation);
        if (timeout <= TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(timeout));
        cancellationToken.ThrowIfCancellationRequested();

        var delay = delayAsync ?? Task.Delay;
        using var stepCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        using var timerCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);

        var opTask = operation(stepCts.Token);
        var delayTask = delay(timeout, timerCts.Token);

        var winner = await Task.WhenAny(opTask, delayTask).ConfigureAwait(false);
        if (ReferenceEquals(winner, opTask))
        {
            timerCts.Cancel();
            ObserveSilently(delayTask);
            return await opTask.ConfigureAwait(false);
        }

        if (cancellationToken.IsCancellationRequested)
        {
            stepCts.Cancel();
            ObserveSilently(opTask);
            cancellationToken.ThrowIfCancellationRequested();
        }

        if (opTask.IsCompleted)
            return await opTask.ConfigureAwait(false);

        stepCts.Cancel();
        ObserveSilently(opTask);
        throw new WifiStepTimeoutException(timeoutCode);
    }

    public static async Task RunAsync(
        Func<CancellationToken, Task> operation,
        TimeSpan timeout,
        string timeoutCode,
        CancellationToken cancellationToken,
        Func<TimeSpan, CancellationToken, Task>? delayAsync = null)
    {
        await RunAsync(
            async ct =>
            {
                await operation(ct).ConfigureAwait(false);
                return true;
            },
            timeout,
            timeoutCode,
            cancellationToken,
            delayAsync).ConfigureAwait(false);
    }

    internal static void ObserveSilently(Task task)
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

/// <summary>
/// Selects the primary Windows AP mode (5GHz Mobile Hotspot when online, Wi-Fi Direct Legacy when offline)
/// and falls back to the alternate mode after a brief settle delay when the primary fails.
/// Enforces per-attempt and total startup time budgets so startup finishes within 15 seconds.
/// </summary>
public static class WifiApStarter
{
    public static readonly TimeSpan DefaultFallbackDelay = TimeSpan.FromMilliseconds(800);
    public static readonly TimeSpan DefaultTotalStartTimeout = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan DefaultPrimaryAttemptTimeout = TimeSpan.FromSeconds(7);

    public static async Task<WifiHostStartResult> StartWithFallbackAsync(
        IWifiApBackend backend,
        WifiTransferCredentials credentials,
        Action<string> log,
        TimeSpan? fallbackDelay = null,
        Func<TimeSpan, CancellationToken, Task>? delayAsync = null,
        CancellationToken cancellationToken = default,
        TimeSpan? totalTimeout = null,
        TimeSpan? primaryTimeout = null)
    {
        ArgumentNullException.ThrowIfNull(backend);
        ArgumentNullException.ThrowIfNull(credentials);
        ArgumentNullException.ThrowIfNull(log);
        cancellationToken.ThrowIfCancellationRequested();

        var delay = delayAsync ?? Task.Delay;
        var overallBudget = totalTimeout ?? DefaultTotalStartTimeout;
        if (overallBudget <= TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(totalTimeout));
        var primaryBudget = primaryTimeout ?? DefaultPrimaryAttemptTimeout;
        if (primaryBudget <= TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(primaryTimeout));
        if (primaryBudget > overallBudget)
            primaryBudget = overallBudget;

        var online = backend.HasInternetConnection();
        var primaryName = online ? "hotspot" : "wifiDirect";
        var fallbackName = online ? "wifiDirect" : "hotspot";

        using var overallCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        using var overallTimerCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var overallExpired = 0;
        var overallTimeoutTask = RunTimeoutSignalAsync(overallBudget, delay, overallTimerCts.Token, () =>
        {
            Volatile.Write(ref overallExpired, 1);
            try { overallCts.Cancel(); } catch { }
        });

        try
        {
            var primary = await RunAttemptAsync(
                ct => online
                    ? backend.TryStartHotspotAsync(credentials, ct)
                    : backend.TryStartWifiDirectAsync(credentials, ct),
                primaryBudget,
                delay,
                overallCts.Token,
                overallTimeoutTask,
                cancellationToken,
                () => Volatile.Read(ref overallExpired) != 0).ConfigureAwait(false);

            if (primary.Succeeded && primary.Handle is not null)
                return WifiHostStartResult.Success(primary.Handle);

            if (primary.TerminalReason is { } terminal)
            {
                if (string.Equals(primary.ErrorCode, "total_timeout", StringComparison.Ordinal))
                    log($"wifi ap primary failed mode={primaryName} reason=total_timeout");
                return WifiHostStartResult.Failure(terminal);
            }

            cancellationToken.ThrowIfCancellationRequested();
            log($"wifi ap primary failed mode={primaryName} reason={primary.ErrorCode ?? "unknown"}");

            if (Volatile.Read(ref overallExpired) != 0)
            {
                log($"wifi ap fallback failed mode={fallbackName} reason=total_timeout");
                return WifiHostStartResult.Failure(WifiUnavailableReason.StartFailed);
            }

            var wait = fallbackDelay ?? DefaultFallbackDelay;
            if (wait > TimeSpan.Zero)
            {
                try
                {
                    var settleTask = delay(wait, overallCts.Token);
                    var winner = await Task.WhenAny(settleTask, overallTimeoutTask).ConfigureAwait(false);
                    if (ReferenceEquals(winner, overallTimeoutTask))
                    {
                        WifiStepTimeout.ObserveSilently(settleTask);
                        cancellationToken.ThrowIfCancellationRequested();
                        log($"wifi ap fallback failed mode={fallbackName} reason=total_timeout");
                        return WifiHostStartResult.Failure(WifiUnavailableReason.StartFailed);
                    }
                    await settleTask.ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && Volatile.Read(ref overallExpired) != 0)
                {
                    log($"wifi ap fallback failed mode={fallbackName} reason=total_timeout");
                    return WifiHostStartResult.Failure(WifiUnavailableReason.StartFailed);
                }
            }

            if (Volatile.Read(ref overallExpired) != 0)
            {
                log($"wifi ap fallback failed mode={fallbackName} reason=total_timeout");
                return WifiHostStartResult.Failure(WifiUnavailableReason.StartFailed);
            }

            var secondary = await RunAttemptAsync(
                ct => online
                    ? backend.TryStartWifiDirectAsync(credentials, ct)
                    : backend.TryStartHotspotAsync(credentials, ct),
                attemptBudget: null,
                delay,
                overallCts.Token,
                overallTimeoutTask,
                cancellationToken,
                () => Volatile.Read(ref overallExpired) != 0).ConfigureAwait(false);

            if (secondary.Succeeded && secondary.Handle is not null)
                return WifiHostStartResult.Success(secondary.Handle);

            if (secondary.TerminalReason is { } secondaryTerminal)
            {
                if (string.Equals(secondary.ErrorCode, "total_timeout", StringComparison.Ordinal))
                    log($"wifi ap fallback failed mode={fallbackName} reason=total_timeout");
                return WifiHostStartResult.Failure(secondaryTerminal);
            }

            log($"wifi ap fallback failed mode={fallbackName} reason={secondary.ErrorCode ?? "unknown"}");
            return WifiHostStartResult.Failure(WifiUnavailableReason.StartFailed);
        }
        finally
        {
            try { overallTimerCts.Cancel(); } catch { }
            WifiStepTimeout.ObserveSilently(overallTimeoutTask);
        }
    }

    private static async Task RunTimeoutSignalAsync(
        TimeSpan duration,
        Func<TimeSpan, CancellationToken, Task> delay,
        CancellationToken ct,
        Action onExpired)
    {
        try
        {
            await delay(duration, ct).ConfigureAwait(false);
            if (!ct.IsCancellationRequested)
                onExpired();
        }
        catch (OperationCanceledException)
        {
        }
    }

    private static async Task<WifiApAttemptResult> RunAttemptAsync(
        Func<CancellationToken, Task<WifiApAttemptResult>> startAttempt,
        TimeSpan? attemptBudget,
        Func<TimeSpan, CancellationToken, Task> delay,
        CancellationToken overallToken,
        Task overallTimeoutTask,
        CancellationToken callerToken,
        Func<bool> isOverallExpired)
    {
        using var attemptCts = CancellationTokenSource.CreateLinkedTokenSource(overallToken);
        using var attemptTimerCts = CancellationTokenSource.CreateLinkedTokenSource(overallToken);

        var attemptTask = startAttempt(attemptCts.Token);
        Task? attemptTimeoutTask = attemptBudget is { } budget
            ? delay(budget, attemptTimerCts.Token)
            : null;

        var winner = attemptTimeoutTask is not null
            ? await Task.WhenAny(attemptTask, attemptTimeoutTask, overallTimeoutTask).ConfigureAwait(false)
            : await Task.WhenAny(attemptTask, overallTimeoutTask).ConfigureAwait(false);

        if (ReferenceEquals(winner, attemptTask))
        {
            try { attemptTimerCts.Cancel(); } catch { }
            if (attemptTimeoutTask is not null)
                WifiStepTimeout.ObserveSilently(attemptTimeoutTask);

            WifiApAttemptResult result;
            try
            {
                result = await attemptTask.ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (callerToken.IsCancellationRequested)
            {
                throw;
            }
            catch (OperationCanceledException)
            {
                return isOverallExpired()
                    ? WifiApAttemptResult.Failure("total_timeout", WifiUnavailableReason.StartFailed)
                    : WifiApAttemptResult.Failure("timeout");
            }

            if (result.Succeeded && result.Handle is not null && (callerToken.IsCancellationRequested || isOverallExpired()))
            {
                try { await result.Handle.DisposeAsync().ConfigureAwait(false); } catch { }
                callerToken.ThrowIfCancellationRequested();
                return WifiApAttemptResult.Failure("total_timeout", WifiUnavailableReason.StartFailed);
            }

            return result;
        }

        try { attemptCts.Cancel(); } catch { }
        try { attemptTimerCts.Cancel(); } catch { }
        if (attemptTimeoutTask is not null)
            WifiStepTimeout.ObserveSilently(attemptTimeoutTask);
        DisposeHandleIfLateSuccess(attemptTask);

        callerToken.ThrowIfCancellationRequested();
        return isOverallExpired()
            ? WifiApAttemptResult.Failure("total_timeout", WifiUnavailableReason.StartFailed)
            : WifiApAttemptResult.Failure("timeout");
    }

    private static void DisposeHandleIfLateSuccess(Task<WifiApAttemptResult> attemptTask)
    {
        _ = attemptTask.ContinueWith(
            static t =>
            {
                if (t.IsFaulted)
                {
                    _ = t.Exception;
                    return;
                }
                if (t.IsCompletedSuccessfully && t.Result.Succeeded && t.Result.Handle is { } lateHandle)
                {
                    _ = Task.Run(async () =>
                    {
                        try { await lateHandle.DisposeAsync().ConfigureAwait(false); }
                        catch { }
                    });
                }
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }
}

public sealed record HotspotBackupRecord(
    string Ssid,
    string Passphrase,
    int? Band,
    string TempSsid,
    IReadOnlyList<string>? PreviousTempSsids = null)
{
    public const int MaxTrackedTempSsids = 64;

    public bool IsRestorable =>
        !string.IsNullOrEmpty(Ssid) &&
        !string.IsNullOrEmpty(Passphrase) &&
        Passphrase.Length >= 8;

    public IEnumerable<string> AllTempSsids()
    {
        if (!string.IsNullOrEmpty(TempSsid))
            yield return TempSsid;
        if (PreviousTempSsids is not null)
        {
            foreach (var ssid in PreviousTempSsids)
            {
                if (!string.IsNullOrEmpty(ssid) &&
                    !string.Equals(ssid, TempSsid, StringComparison.Ordinal))
                {
                    yield return ssid;
                }
            }
        }
    }

    public bool MatchesTempSsid(string? currentSsid)
    {
        if (string.IsNullOrEmpty(currentSsid))
            return false;
        foreach (var temp in AllTempSsids())
        {
            if (string.Equals(currentSsid, temp, StringComparison.Ordinal))
                return true;
        }
        return false;
    }

    public bool ShouldRestoreForCurrentSsid(string? currentSsid) =>
        IsRestorable && MatchesTempSsid(currentSsid);

    public HotspotBackupRecord WithAdditionalTempSsid(string newTempSsid)
    {
        if (string.IsNullOrEmpty(newTempSsid))
            return this;
        if (string.Equals(TempSsid, newTempSsid, StringComparison.Ordinal))
            return this;

        var history = new List<string>();
        if (!string.IsNullOrEmpty(TempSsid))
            history.Add(TempSsid);
        if (PreviousTempSsids is not null)
        {
            foreach (var ssid in PreviousTempSsids)
            {
                if (!string.IsNullOrEmpty(ssid) &&
                    !string.Equals(ssid, newTempSsid, StringComparison.Ordinal) &&
                    !history.Contains(ssid, StringComparer.Ordinal))
                {
                    history.Add(ssid);
                }
            }
        }
        var maxPrevious = MaxTrackedTempSsids - 1;
        if (history.Count > maxPrevious)
            history.RemoveRange(maxPrevious, history.Count - maxPrevious);

        return new HotspotBackupRecord(
            Ssid,
            Passphrase,
            Band,
            newTempSsid,
            history.Count > 0 ? history : null);
    }

    public bool Equals(HotspotBackupRecord? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return string.Equals(Ssid, other.Ssid, StringComparison.Ordinal) &&
            string.Equals(Passphrase, other.Passphrase, StringComparison.Ordinal) &&
            Band == other.Band &&
            string.Equals(TempSsid, other.TempSsid, StringComparison.Ordinal) &&
            SequenceEquals(PreviousTempSsids, other.PreviousTempSsids);
    }

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(Ssid, StringComparer.Ordinal);
        hash.Add(Passphrase, StringComparer.Ordinal);
        hash.Add(Band);
        hash.Add(TempSsid, StringComparer.Ordinal);
        if (PreviousTempSsids is not null)
        {
            foreach (var ssid in PreviousTempSsids)
                hash.Add(ssid, StringComparer.Ordinal);
        }
        return hash.ToHashCode();
    }

    private static bool SequenceEquals(IReadOnlyList<string>? a, IReadOnlyList<string>? b)
    {
        var aCount = a?.Count ?? 0;
        var bCount = b?.Count ?? 0;
        if (aCount != bCount) return false;
        for (var i = 0; i < aCount; i++)
        {
            if (!string.Equals(a![i], b![i], StringComparison.Ordinal))
                return false;
        }
        return true;
    }

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
