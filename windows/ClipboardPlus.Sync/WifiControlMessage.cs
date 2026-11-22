using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;

namespace ClipboardPlus.Sync;

public enum WifiTransferDirection
{
    Send,
    Receive,
    Both,
}

public enum WifiUnavailableReason
{
    Unsupported,
    Busy,
    Conflict,
    StartFailed,
    Disabled,
}

public enum WifiJoinStatus
{
    Joined,
    UserDenied,
    NotForeground,
    JoinFailed,
    Timeout,
}

public enum WifiCancelReason
{
    UserCancelled,
    Timeout,
    TcpFailed,
    ProtocolError,
    Completed,
    Superseded,
}

public abstract record WifiControlMessage;

public sealed record WifiRequest(WifiTransferDirection Direction, IReadOnlyList<Guid> Ids) : WifiControlMessage
{
    public bool Equals(WifiRequest? other) =>
        other is not null && Direction == other.Direction && Ids.SequenceEqual(other.Ids);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(Direction);
        foreach (var id in Ids) hash.Add(id);
        return hash.ToHashCode();
    }

    public override string ToString() => $"WifiRequest {{ Direction = {Direction}, Count = {Ids.Count} }}";
}

public sealed record WifiReady(Guid Session, string Ssid, string Passphrase, string Ip, int Port, byte[] Token, int TtlSeconds) : WifiControlMessage
{
    public bool Equals(WifiReady? other) =>
        other is not null &&
        Session == other.Session &&
        string.Equals(Ssid, other.Ssid, StringComparison.Ordinal) &&
        string.Equals(Passphrase, other.Passphrase, StringComparison.Ordinal) &&
        string.Equals(Ip, other.Ip, StringComparison.Ordinal) &&
        Port == other.Port &&
        Token is not null && other.Token is not null &&
        Token.Length == other.Token.Length &&
        CryptographicOperations.FixedTimeEquals(Token, other.Token) &&
        TtlSeconds == other.TtlSeconds;

    public override int GetHashCode() => HashCode.Combine(Session, Port, TtlSeconds, Token?.Length ?? 0);

    // Never expose SSID, passphrase, IP, session, or one-time token in string formatting/logs.
    public override string ToString() => $"WifiReady {{ Port = {Port}, TtlSeconds = {TtlSeconds}, Redacted = true }}";
}

public sealed record WifiUnavailable(WifiUnavailableReason Reason) : WifiControlMessage
{
    public override string ToString() => $"WifiUnavailable {{ Reason = {Reason} }}";
}

public sealed record WifiJoinResult(Guid Session, WifiJoinStatus Status) : WifiControlMessage
{
    public override string ToString() => $"WifiJoinResult {{ Status = {Status} }}";
}

public sealed record WifiCancel(Guid Session, WifiCancelReason Reason) : WifiControlMessage
{
    public override string ToString() => $"WifiCancel {{ Reason = {Reason} }}";
}

public static class WifiControlMessageCodec
{
    public static byte[] Encode(WifiControlMessage message)
    {
        SyncProtocol.Require(message is not null);
        var sink = new BoundedUtf8Sink(SyncProtocol.MaxHeaderBytes, writeBytes: true);
        sink.WriteByte((byte)'{');
        switch (message)
        {
            case WifiRequest req:
                SyncProtocol.Require(req.Ids is not null);
                SyncProtocol.Require(req.Ids.Count <= SyncProtocol.MaxPending, SyncError.Limit);
                var seenIds = new HashSet<Guid>();
                foreach (var id in req.Ids) SyncProtocol.Require(seenIds.Add(id));
                sink.WriteAscii("\"direction\":"u8);
                sink.WriteEscapedJsonString(DirectionToWire(req.Direction));
                sink.WriteAscii(",\"ids\":["u8);
                for (var i = 0; i < req.Ids.Count; i++)
                {
                    if (i > 0) sink.WriteByte((byte)',');
                    sink.WriteEscapedJsonString(SyncProtocol.Id(req.Ids[i]));
                }
                sink.WriteAscii("],\"t\":\"wifi_request\""u8);
                break;

            case WifiReady ready:
                ValidateReady(ready);
                sink.WriteAscii("\"ip\":"u8);
                sink.WriteEscapedJsonString(ready.Ip);
                sink.WriteAscii(",\"passphrase\":"u8);
                sink.WriteEscapedJsonString(ready.Passphrase);
                sink.WriteAscii(",\"port\":"u8);
                sink.WriteInt64(ready.Port);
                sink.WriteAscii(",\"session\":"u8);
                sink.WriteEscapedJsonString(SyncProtocol.Id(ready.Session));
                sink.WriteAscii(",\"ssid\":"u8);
                sink.WriteEscapedJsonString(ready.Ssid);
                sink.WriteAscii(",\"t\":\"wifi_ready\",\"token\":"u8);
                sink.WriteEscapedJsonString(Convert.ToHexStringLower(ready.Token));
                sink.WriteAscii(",\"ttl\":"u8);
                sink.WriteInt64(ready.TtlSeconds);
                break;

            case WifiUnavailable unavailable:
                sink.WriteAscii("\"reason\":"u8);
                sink.WriteEscapedJsonString(UnavailableReasonToWire(unavailable.Reason));
                sink.WriteAscii(",\"t\":\"wifi_unavailable\""u8);
                break;

            case WifiJoinResult joinResult:
                sink.WriteAscii("\"session\":"u8);
                sink.WriteEscapedJsonString(SyncProtocol.Id(joinResult.Session));
                sink.WriteAscii(",\"status\":"u8);
                sink.WriteEscapedJsonString(JoinStatusToWire(joinResult.Status));
                sink.WriteAscii(",\"t\":\"wifi_join_result\""u8);
                break;

            case WifiCancel cancel:
                sink.WriteAscii("\"reason\":"u8);
                sink.WriteEscapedJsonString(CancelReasonToWire(cancel.Reason));
                sink.WriteAscii(",\"session\":"u8);
                sink.WriteEscapedJsonString(SyncProtocol.Id(cancel.Session));
                sink.WriteAscii(",\"t\":\"wifi_cancel\""u8);
                break;

            default:
                throw new SyncProtocolException(SyncError.Format);
        }
        sink.WriteByte((byte)'}');
        return SyncMessageCodec.FramePlaintext(sink.ToArray(), ReadOnlySpan<byte>.Empty);
    }

    public static WifiControlMessage Decode(ReadOnlySpan<byte> plaintext)
    {
        var (header, bodyMemory) = SyncMessageCodec.SplitPlaintext(plaintext.ToArray());
        SyncProtocol.Require(bodyMemory.IsEmpty);
        try
        {
            using var doc = JsonDocument.Parse(header, new JsonDocumentOptions { MaxDepth = 8 });
            var root = doc.RootElement;
            SyncProtocol.Require(root.ValueKind == JsonValueKind.Object);
            SyncMessageCodec.CheckNoDuplicateKeys(root);
            SyncMessageCodec.CheckAsciiJson(root);

            var propCount = root.EnumerateObject().Count();
            void Keys(params string[] expected) =>
                SyncProtocol.Require(propCount == expected.Length && expected.All(k => root.TryGetProperty(k, out _)));

            var messageType = SyncMessageCodec.String(root, "t");
            switch (messageType)
            {
                case "wifi_request":
                {
                    Keys("direction", "ids", "t");
                    var direction = DirectionFromWire(SyncMessageCodec.String(root, "direction"));
                    var idsElem = root.GetProperty("ids");
                    SyncProtocol.Require(idsElem.ValueKind == JsonValueKind.Array);
                    SyncProtocol.Require(idsElem.GetArrayLength() <= SyncProtocol.MaxPending, SyncError.Limit);
                    var ids = new List<Guid>(idsElem.GetArrayLength());
                    var seen = new HashSet<Guid>();
                    foreach (var el in idsElem.EnumerateArray())
                    {
                        SyncProtocol.Require(el.ValueKind == JsonValueKind.String);
                        var parsed = SyncProtocol.ParseId(el.GetString());
                        SyncProtocol.Require(seen.Add(parsed));
                        ids.Add(parsed);
                    }
                    return new WifiRequest(direction, ids);
                }

                case "wifi_ready":
                {
                    Keys("ip", "passphrase", "port", "session", "ssid", "t", "token", "ttl");
                    var session = SyncProtocol.ParseId(SyncMessageCodec.String(root, "session"));
                    var ssid = SyncMessageCodec.String(root, "ssid");
                    var passphrase = SyncMessageCodec.String(root, "passphrase");
                    var ip = SyncMessageCodec.String(root, "ip");
                    var portLong = SyncMessageCodec.Integer(root, "port");
                    SyncProtocol.Require(portLong is >= 1 and <= ushort.MaxValue);
                    var tokenHex = SyncMessageCodec.String(root, "token");
                    SyncProtocol.Require(SyncProtocol.IsLowerHex64(tokenHex));
                    var ttlLong = SyncMessageCodec.Integer(root, "ttl");
                    SyncProtocol.Require(ttlLong is >= 1 and <= SyncProtocol.WifiMaxTtlSeconds);
                    var ready = new WifiReady(session, ssid, passphrase, ip, (int)portLong, Convert.FromHexString(tokenHex), (int)ttlLong);
                    ValidateReady(ready);
                    return ready;
                }

                case "wifi_unavailable":
                    Keys("reason", "t");
                    return new WifiUnavailable(UnavailableReasonFromWire(SyncMessageCodec.String(root, "reason")));

                case "wifi_join_result":
                    Keys("session", "status", "t");
                    return new WifiJoinResult(
                        SyncProtocol.ParseId(SyncMessageCodec.String(root, "session")),
                        JoinStatusFromWire(SyncMessageCodec.String(root, "status")));

                case "wifi_cancel":
                    Keys("reason", "session", "t");
                    return new WifiCancel(
                        SyncProtocol.ParseId(SyncMessageCodec.String(root, "session")),
                        CancelReasonFromWire(SyncMessageCodec.String(root, "reason")));

                default:
                    throw new SyncProtocolException(SyncError.Format);
            }
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or OverflowException)
        {
            throw new SyncProtocolException(SyncError.Format);
        }
    }

    public static void ValidateReady(WifiReady ready)
    {
        SyncProtocol.Require(ready is not null);
        SyncProtocol.Require(ready.Ssid is { Length: >= 1 and <= SyncProtocol.WifiMaxSsidBytes });
        SyncProtocol.Require(ready.Ssid.All(c => c is >= (char)0x20 and <= (char)0x7E) && !string.IsNullOrWhiteSpace(ready.Ssid));
        SyncProtocol.Require(ready.Passphrase is { Length: >= SyncProtocol.WifiMinPassphraseBytes and <= SyncProtocol.WifiMaxPassphraseBytes });
        SyncProtocol.Require(ready.Passphrase.All(c => c is >= (char)0x21 and <= (char)0x7E));
        SyncProtocol.Require(IsValidLocalIpv4(ready.Ip));
        SyncProtocol.Require(ready.Port is >= 1 and <= ushort.MaxValue);
        SyncProtocol.Require(ready.Token is { Length: 32 });
        SyncProtocol.Require(ready.TtlSeconds is >= 1 and <= SyncProtocol.WifiMaxTtlSeconds);
    }

    /// <summary>
    /// Accepts canonical dotted-quad RFC 1918 private IPv4 and RFC 3927 link-local IPv4 addresses only.
    /// Rejects public, loopback, unspecified, multicast, broadcast, and non-canonical addresses.
    /// </summary>
    public static bool IsValidLocalIpv4(string? value)
    {
        if (string.IsNullOrEmpty(value)) return false;
        var parts = value.Split('.');
        if (parts.Length != 4) return false;
        Span<byte> o = stackalloc byte[4];
        for (var i = 0; i < 4; i++)
        {
            var part = parts[i];
            if (part.Length == 0 || (part.Length > 1 && part[0] == '0') || !part.All(char.IsAsciiDigit))
                return false;
            if (!byte.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out o[i]))
                return false;
        }
        if (o[0] == 10)
            return !(o[1] == 0 && o[2] == 0 && o[3] == 0) && !(o[1] == 255 && o[2] == 255 && o[3] == 255);
        if (o[0] == 172 && o[1] is >= 16 and <= 31)
            return !(o[1] == 16 && o[2] == 0 && o[3] == 0) && !(o[1] == 31 && o[2] == 255 && o[3] == 255);
        if (o[0] == 192 && o[1] == 168)
            return !(o[2] == 0 && o[3] == 0) && !(o[2] == 255 && o[3] == 255);
        // RFC 3927 Section 2.1: 169.254.0.0/24 and 169.254.255.0/24 are reserved.
        if (o[0] == 169 && o[1] == 254 && o[2] is >= 1 and <= 254)
            return true;
        return false;
    }

    private static string DirectionToWire(WifiTransferDirection direction) => direction switch
    {
        WifiTransferDirection.Send => "send",
        WifiTransferDirection.Receive => "receive",
        WifiTransferDirection.Both => "both",
        _ => throw new SyncProtocolException(SyncError.Format),
    };

    private static WifiTransferDirection DirectionFromWire(string value) => value switch
    {
        "send" => WifiTransferDirection.Send,
        "receive" => WifiTransferDirection.Receive,
        "both" => WifiTransferDirection.Both,
        _ => throw new SyncProtocolException(SyncError.Format),
    };

    private static string UnavailableReasonToWire(WifiUnavailableReason reason) => reason switch
    {
        WifiUnavailableReason.Unsupported => "unsupported",
        WifiUnavailableReason.Busy => "busy",
        WifiUnavailableReason.Conflict => "conflict",
        WifiUnavailableReason.StartFailed => "start_failed",
        WifiUnavailableReason.Disabled => "disabled",
        _ => throw new SyncProtocolException(SyncError.Format),
    };

    private static WifiUnavailableReason UnavailableReasonFromWire(string value) => value switch
    {
        "unsupported" => WifiUnavailableReason.Unsupported,
        "busy" => WifiUnavailableReason.Busy,
        "conflict" => WifiUnavailableReason.Conflict,
        "start_failed" => WifiUnavailableReason.StartFailed,
        "disabled" => WifiUnavailableReason.Disabled,
        _ => throw new SyncProtocolException(SyncError.Format),
    };

    private static string JoinStatusToWire(WifiJoinStatus status) => status switch
    {
        WifiJoinStatus.Joined => "joined",
        WifiJoinStatus.UserDenied => "user_denied",
        WifiJoinStatus.NotForeground => "not_foreground",
        WifiJoinStatus.JoinFailed => "join_failed",
        WifiJoinStatus.Timeout => "timeout",
        _ => throw new SyncProtocolException(SyncError.Format),
    };

    private static WifiJoinStatus JoinStatusFromWire(string value) => value switch
    {
        "joined" => WifiJoinStatus.Joined,
        "user_denied" => WifiJoinStatus.UserDenied,
        "not_foreground" => WifiJoinStatus.NotForeground,
        "join_failed" => WifiJoinStatus.JoinFailed,
        "timeout" => WifiJoinStatus.Timeout,
        _ => throw new SyncProtocolException(SyncError.Format),
    };

    private static string CancelReasonToWire(WifiCancelReason reason) => reason switch
    {
        WifiCancelReason.UserCancelled => "user_cancelled",
        WifiCancelReason.Timeout => "timeout",
        WifiCancelReason.TcpFailed => "tcp_failed",
        WifiCancelReason.ProtocolError => "protocol_error",
        WifiCancelReason.Completed => "completed",
        WifiCancelReason.Superseded => "superseded",
        _ => throw new SyncProtocolException(SyncError.Format),
    };

    private static WifiCancelReason CancelReasonFromWire(string value) => value switch
    {
        "user_cancelled" => WifiCancelReason.UserCancelled,
        "timeout" => WifiCancelReason.Timeout,
        "tcp_failed" => WifiCancelReason.TcpFailed,
        "protocol_error" => WifiCancelReason.ProtocolError,
        "completed" => WifiCancelReason.Completed,
        "superseded" => WifiCancelReason.Superseded,
        _ => throw new SyncProtocolException(SyncError.Format),
    };
}
