using System.Buffers.Binary;
using System.Globalization;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ClipboardPlus.Windows.Core;

public enum WifiProbeMode
{
    WifiDirectLegacy,
    MobileHotspot,
}

public sealed record WifiProbeCredentials(string Ssid, string Passphrase, string Token)
{
    private const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

    public static WifiProbeCredentials CreateRandom()
    {
        var ssid = "DIRECT-cp-" + RandomText(8);
        var passphrase = RandomText(20);
        var tokenBytes = RandomNumberGenerator.GetBytes(24);
        var token = Convert.ToBase64String(tokenBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        return new WifiProbeCredentials(ssid, passphrase, token);
    }

    private static string RandomText(int length)
    {
        Span<char> chars = stackalloc char[length];
        for (var i = 0; i < length; i++)
            chars[i] = Alphabet[RandomNumberGenerator.GetInt32(Alphabet.Length)];
        return new string(chars);
    }
}

public sealed record WifiProbeQrPayload(
    [property: JsonPropertyName("ssid")] string Ssid,
    [property: JsonPropertyName("passphrase")] string Passphrase,
    [property: JsonPropertyName("ip")] string Ip,
    [property: JsonPropertyName("port")] int Port,
    [property: JsonPropertyName("token")] string Token)
{
    public const string Prefix = "clipboardplus-wifi-probe:1:";
    public const string PairingPrefix = "clipboardplus-pair:";
    private const int MaxQrBytes = 1024;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false,
    };

    public string ToQrString()
    {
        Validate(this);
        return Prefix + JsonSerializer.Serialize(this, JsonOptions);
    }

    public static WifiProbeQrPayload Parse(string text)
    {
        if (string.IsNullOrWhiteSpace(text) || Encoding.UTF8.GetByteCount(text) > MaxQrBytes)
            throw new FormatException("QRコードの内容が長すぎるか空です。");
        if (text.StartsWith(PairingPrefix, StringComparison.Ordinal))
            throw new FormatException("組にする用のQRコードです。「Wi-Fi 転送の試験」のQRコードを読んでください。");
        if (!text.StartsWith(Prefix, StringComparison.Ordinal))
            throw new FormatException("Wi-Fi転送の試験用のQRコードではありません。");

        var json = text[Prefix.Length..];
        WifiProbeQrPayload? parsed;
        try
        {
            parsed = JsonSerializer.Deserialize<WifiProbeQrPayload>(json, JsonOptions);
        }
        catch (JsonException)
        {
            throw new FormatException("QRコードのJSON形式が正しくありません。");
        }
        if (parsed is null)
            throw new FormatException("QRコードの内容が正しくありません。");

        Validate(parsed);
        return parsed;
    }

    private static void Validate(WifiProbeQrPayload value)
    {
        if (!IsValidText(value.Ssid, 1, 32))
            throw new FormatException("SSIDの形式が正しくありません。");
        if (!IsValidText(value.Passphrase, 8, 63))
            throw new FormatException("パスフレーズの形式が正しくありません。");
        if (!IsValidProbeIpv4(value.Ip))
            throw new FormatException("IPアドレスの形式が正しくありません。");
        if (value.Port is < 1 or > 65535)
            throw new FormatException("ポート番号が範囲外です。");
        if (!IsValidToken(value.Token))
            throw new FormatException("合言葉の形式が正しくありません。");
    }

    private static bool IsValidText(string? value, int minBytes, int maxBytes)
    {
        if (string.IsNullOrEmpty(value)) return false;
        var bytes = Encoding.UTF8.GetByteCount(value);
        return bytes >= minBytes && bytes <= maxBytes && !value.Any(c => c < 32 || c == 127);
    }

    private static bool IsValidToken(string? value)
    {
        if (string.IsNullOrEmpty(value)) return false;
        var bytes = Encoding.UTF8.GetByteCount(value);
        return bytes is >= 16 and <= 128 && value.All(c => c is >= (char)0x21 and <= (char)0x7E);
    }

    public static bool IsValidProbeIpv4(string? value)
    {
        if (string.IsNullOrEmpty(value)) return false;
        var parts = value.Split('.');
        if (parts.Length != 4) return false;
        Span<byte> octets = stackalloc byte[4];
        for (var i = 0; i < 4; i++)
        {
            var part = parts[i];
            if (part.Length == 0 || (part.Length > 1 && part[0] == '0') || !part.All(char.IsAsciiDigit))
                return false;
            if (!byte.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out octets[i]))
                return false;
        }
        return !octets.SequenceEqual(stackalloc byte[] { 0, 0, 0, 0 }) && octets[0] != 127;
    }
}

public static class WifiProbeWire
{
    public static ReadOnlySpan<byte> Magic => "CPW1"u8;
    public const byte AckOk = 0x00;
    public const byte AckAuthFailed = 0x01;
    public const byte AckInvalidSize = 0x02;
    public const long MaxPayloadBytes = 64L * 1024 * 1024;
    private const int ChunkBytes = 64 * 1024;

    public static byte[] EncodeHeader(string token, long payloadBytes)
    {
        if (payloadBytes is < 1 or > MaxPayloadBytes)
            throw new ArgumentOutOfRangeException(nameof(payloadBytes));
        var tokenBytes = Encoding.UTF8.GetBytes(token);
        if (tokenBytes.Length is < 1 or > 256)
            throw new ArgumentOutOfRangeException(nameof(token));

        var packet = new byte[4 + 2 + tokenBytes.Length + 8];
        Magic.CopyTo(packet);
        BinaryPrimitives.WriteUInt16BigEndian(packet.AsSpan(4, 2), (ushort)tokenBytes.Length);
        tokenBytes.CopyTo(packet, 6);
        BinaryPrimitives.WriteUInt64BigEndian(packet.AsSpan(6 + tokenBytes.Length, 8), (ulong)payloadBytes);
        return packet;
    }

    public static async Task<(bool Ok, byte StatusCode, long PayloadBytes)> ReadHeaderAsync(
        Stream stream,
        string expectedToken,
        CancellationToken cancellationToken)
    {
        var prefix = new byte[6];
        await ReadExactAsync(stream, prefix, cancellationToken);
        if (!prefix.AsSpan(0, 4).SequenceEqual(Magic))
            return (false, AckInvalidSize, 0);

        var tokenLength = BinaryPrimitives.ReadUInt16BigEndian(prefix.AsSpan(4, 2));
        if (tokenLength is < 1 or > 256)
            return (false, AckAuthFailed, 0);

        var tokenAndSize = new byte[tokenLength + 8];
        await ReadExactAsync(stream, tokenAndSize, cancellationToken);

        var expectedBytes = Encoding.UTF8.GetBytes(expectedToken);
        var receivedToken = tokenAndSize.AsSpan(0, tokenLength);
        if (receivedToken.Length != expectedBytes.Length ||
            !CryptographicOperations.FixedTimeEquals(receivedToken, expectedBytes))
            return (false, AckAuthFailed, 0);

        var rawSize = BinaryPrimitives.ReadUInt64BigEndian(tokenAndSize.AsSpan(tokenLength, 8));
        if (rawSize is < 1 or > (ulong)MaxPayloadBytes)
            return (false, AckInvalidSize, 0);

        return (true, AckOk, (long)rawSize);
    }

    public static async Task<WifiProbeTransferOutcome> RunEchoServerSessionAsync(
        Stream stream,
        string expectedToken,
        Action<long>? onAccepted = null,
        Action<long, TimeSpan>? onReceived = null,
        Action<long, TimeSpan>? onSent = null,
        CancellationToken cancellationToken = default)
    {
        var (ok, statusCode, payloadBytes) = await ReadHeaderAsync(stream, expectedToken, cancellationToken);
        await stream.WriteAsync(new[] { statusCode }, cancellationToken);
        await stream.FlushAsync(cancellationToken);
        if (!ok)
            return new WifiProbeTransferOutcome(false, statusCode, 0, TimeSpan.Zero, TimeSpan.Zero);

        onAccepted?.Invoke(payloadBytes);

        var buffer = new byte[ChunkBytes];
        var uploadClock = System.Diagnostics.Stopwatch.StartNew();
        long remaining = payloadBytes;
        while (remaining > 0)
        {
            var toRead = (int)Math.Min(remaining, buffer.Length);
            var read = await stream.ReadAsync(buffer.AsMemory(0, toRead), cancellationToken);
            if (read == 0)
                throw new EndOfStreamException("試験データの受信中に切断されました。");
            remaining -= read;
        }
        uploadClock.Stop();
        onReceived?.Invoke(payloadBytes, uploadClock.Elapsed);

        await stream.WriteAsync(new[] { AckOk }, cancellationToken);
        await stream.FlushAsync(cancellationToken);

        var downloadClock = System.Diagnostics.Stopwatch.StartNew();
        remaining = payloadBytes;
        while (remaining > 0)
        {
            var toWrite = (int)Math.Min(remaining, buffer.Length);
            RandomNumberGenerator.Fill(buffer.AsSpan(0, toWrite));
            await stream.WriteAsync(buffer.AsMemory(0, toWrite), cancellationToken);
            remaining -= toWrite;
        }
        await stream.FlushAsync(cancellationToken);

        // Wait briefly for the client's 1-byte completion ack so timing reflects real reception.
        using var ackTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        ackTimeout.CancelAfter(TimeSpan.FromSeconds(5));
        try
        {
            _ = await stream.ReadAsync(buffer.AsMemory(0, 1), ackTimeout.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
        }
        catch (IOException)
        {
        }

        downloadClock.Stop();
        onSent?.Invoke(payloadBytes, downloadClock.Elapsed);
        return new WifiProbeTransferOutcome(true, AckOk, payloadBytes, uploadClock.Elapsed, downloadClock.Elapsed);
    }

    public static async Task ReadExactAsync(Stream stream, byte[] destination, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < destination.Length)
        {
            var read = await stream.ReadAsync(destination.AsMemory(offset, destination.Length - offset), cancellationToken);
            if (read == 0)
                throw new EndOfStreamException("通信が途中で切れました。");
            offset += read;
        }
    }
}

public sealed record WifiProbeTransferOutcome(
    bool Accepted,
    byte StatusCode,
    long PayloadBytes,
    TimeSpan UploadElapsed,
    TimeSpan DownloadElapsed);

public sealed record NetworkAdapterSnapshot(
    string Description,
    string Name,
    OperationalStatus Status,
    NetworkInterfaceType Type,
    IReadOnlyList<IPAddress> IPv4Addresses)
{
    public static IReadOnlyList<NetworkAdapterSnapshot> CaptureSystem()
    {
        var result = new List<NetworkAdapterSnapshot>();
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            IReadOnlyList<IPAddress> ipv4;
            try
            {
                ipv4 = nic.GetIPProperties().UnicastAddresses
                    .Select(a => a.Address)
                    .Where(a => a.AddressFamily == AddressFamily.InterNetwork)
                    .ToList();
            }
            catch (NetworkInformationException)
            {
                continue;
            }
            result.Add(new NetworkAdapterSnapshot(nic.Description, nic.Name, nic.OperationalStatus, nic.NetworkInterfaceType, ipv4));
        }
        return result;
    }
}

public static class WifiProbeIpSelector
{
    public static bool IsVirtualApAdapter(string description, string name) =>
        description.Contains("Wi-Fi Direct", StringComparison.OrdinalIgnoreCase) ||
        name.Contains("Wi-Fi Direct", StringComparison.OrdinalIgnoreCase) ||
        description.Contains("Hosted Network", StringComparison.OrdinalIgnoreCase) ||
        name.Contains("Hosted Network", StringComparison.OrdinalIgnoreCase);

    public static IPAddress? SelectIp(
        IReadOnlyList<NetworkAdapterSnapshot> adapters,
        bool allowApipa,
        bool allowNonUp)
    {
        var candidates = new List<(int Score, IPAddress Address)>();
        foreach (var adapter in adapters)
        {
            if (adapter.Type is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
                continue;
            if (!IsVirtualApAdapter(adapter.Description, adapter.Name))
                continue;
            var isUp = adapter.Status == OperationalStatus.Up;
            if (!isUp && !allowNonUp)
                continue;

            foreach (var ip in adapter.IPv4Addresses)
            {
                if (ip.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(ip) || ip.Equals(IPAddress.Any))
                    continue;

                var bytes = ip.GetAddressBytes();
                var isApipa = bytes[0] == 169 && bytes[1] == 254;
                if (isApipa && !allowApipa)
                    continue;
                if (!isUp && isApipa)
                    continue;

                var score = 0;
                if (isUp) score += 100;
                if (!isApipa) score += 50;
                if (bytes[0] == 192 && bytes[1] == 168 && bytes[2] == 137)
                    score += bytes[3] == 1 ? 30 : 20;
                if (adapter.Type == NetworkInterfaceType.Wireless80211)
                    score += 5;

                candidates.Add((score, ip));
            }
        }

        return candidates.OrderByDescending(c => c.Score).Select(c => c.Address).FirstOrDefault();
    }

    public static string ClassifySubnet(IPAddress ip)
    {
        var b = ip.GetAddressBytes();
        if (b[0] == 192 && b[1] == 168 && b[2] == 137) return "ics_192_168_137";
        if (b[0] == 169 && b[1] == 254) return "apipa_169_254";
        if (b[0] == 10 || (b[0] == 172 && b[1] is >= 16 and <= 31) || (b[0] == 192 && b[1] == 168))
            return "private";
        return "other";
    }
}

public sealed record WifiProbeSnapshot(
    bool IsRunning,
    WifiProbeMode Mode,
    string StatusMessage,
    string? ErrorMessage,
    WifiProbeQrPayload? QrPayload,
    DateTimeOffset? ApStartingAt,
    DateTimeOffset? ApReadyAt,
    TimeSpan? ApStartDuration,
    DateTimeOffset? ConnectedAt,
    long? PayloadBytes,
    DateTimeOffset? ReceivedAt,
    TimeSpan? UploadDuration,
    DateTimeOffset? SentAt,
    TimeSpan? DownloadDuration,
    int CompletedRuns);

public static class WifiProbeText
{
    public static double? SpeedMBPerSecond(long bytes, TimeSpan duration)
    {
        var seconds = duration.TotalSeconds;
        if (bytes <= 0 || seconds <= 0 || double.IsNaN(seconds) || double.IsInfinity(seconds))
            return null;
        return bytes / (1024.0 * 1024.0) / seconds;
    }

    public static string FormatSpeed(double? mbPerSecond) =>
        mbPerSecond is { } v
            ? string.Create(CultureInfo.InvariantCulture, $"{v:0.00} MB/秒")
            : "-";

    public static string FormatDuration(TimeSpan? duration) =>
        duration is { } d
            ? string.Create(CultureInfo.InvariantCulture, $"{d.TotalSeconds:0.00} 秒")
            : "-";

    public static string FormatTimestamp(DateTimeOffset? at) =>
        at is { } t
            ? t.ToLocalTime().ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture)
            : "-";

    public static string ModeName(WifiProbeMode mode) => mode switch
    {
        WifiProbeMode.WifiDirectLegacy => "Wi-Fi Direct（レガシー）",
        WifiProbeMode.MobileHotspot => "モバイルホットスポット",
        _ => mode.ToString(),
    };

    public static string FormatTimeline(WifiProbeSnapshot state)
    {
        var uploadSpeed = state.PayloadBytes is { } upBytes && state.UploadDuration is { } upDur
            ? SpeedMBPerSecond(upBytes, upDur)
            : null;
        var downloadSpeed = state.PayloadBytes is { } downBytes && state.DownloadDuration is { } downDur
            ? SpeedMBPerSecond(downBytes, downDur)
            : null;

        var sizeText = state.PayloadBytes is { } bytes ? SyncStatusText.Bytes(bytes) : "-";
        var lines = new List<string>
        {
            $"方式: {ModeName(state.Mode)}",
            $"Wi-Fi作り始め: {FormatTimestamp(state.ApStartingAt)}",
            $"Wi-Fi作れた: {FormatTimestamp(state.ApReadyAt)}（所要 {FormatDuration(state.ApStartDuration)}）",
            $"つながった: {FormatTimestamp(state.ConnectedAt)}（試験サイズ {sizeText}）",
            $"受け取り終えた: {FormatTimestamp(state.ReceivedAt)}（{FormatDuration(state.UploadDuration)} / {FormatSpeed(uploadSpeed)}）",
            $"送り終えた: {FormatTimestamp(state.SentAt)}（{FormatDuration(state.DownloadDuration)} / {FormatSpeed(downloadSpeed)}）",
        };
        if (state.CompletedRuns > 0)
            lines.Add($"この起動での完了回数: {state.CompletedRuns} 回");
        return string.Join(Environment.NewLine, lines);
    }
}
