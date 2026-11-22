using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace ClipboardPlus.Sync;

public enum WifiStreamDirection : byte
{
    PadToPc = SyncProtocol.WifiDirectionPadToPc,
    PcToPad = SyncProtocol.WifiDirectionPcToPad,
}

public sealed class WifiTrafficKeys
{
    private readonly byte[] padToPc, pcToPad;
    public byte[] PadToPc => padToPc.ToArray();
    public byte[] PcToPad => pcToPad.ToArray();

    internal WifiTrafficKeys(byte[] padToPc, byte[] pcToPad)
    {
        this.padToPc = padToPc;
        this.pcToPad = pcToPad;
    }

    public override string ToString() => "WifiTrafficKeys { Redacted = true }";
}

/// <summary>
/// One-time per-transfer Wi-Fi keys derived from the BLE session's Wi-Fi base key,
/// the per-transfer 32-byte random token, and the 16-byte session UUID.
/// BLE traffic keys are never used on TCP.
/// </summary>
public sealed class WifiTransferKeys
{
    private readonly byte[] transferKey;
    private readonly byte[] authKey;

    public Guid Session { get; }
    public byte[] TransferKey => transferKey.ToArray();
    public byte[] AuthKey => authKey.ToArray();

    private WifiTransferKeys(Guid session, byte[] transferKey, byte[] authKey)
    {
        Session = session;
        this.transferKey = transferKey;
        this.authKey = authKey;
    }

    public static WifiTransferKeys Derive(SyncSessionKeys bleKeys, ReadOnlySpan<byte> token, Guid session)
    {
        SyncProtocol.Require(bleKeys is not null && bleKeys.SupportsWifiTransfer && bleKeys.WifiBaseKey is not null, SyncError.State);
        return Derive(bleKeys.WifiBaseKey, token, session);
    }

    public static WifiTransferKeys Derive(ReadOnlySpan<byte> bleWifiBaseKey, ReadOnlySpan<byte> token, Guid session)
    {
        var baseKey = SyncProtocol.Fixed(bleWifiBaseKey, 32);
        var oneTimeToken = SyncProtocol.Fixed(token, 32);
        var sessionBytes = SyncProtocol.IdBytes(session);
        byte[] ikm = [.. baseKey, .. oneTimeToken];
        var derivedTransferKey = HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, 32, sessionBytes, "clipboardplus wifi v1 key"u8.ToArray());
        var derivedAuthKey = HKDF.DeriveKey(HashAlgorithmName.SHA256, derivedTransferKey, 32, sessionBytes, "clipboardplus wifi v1 auth"u8.ToArray());
        return new WifiTransferKeys(session, derivedTransferKey, derivedAuthKey);
    }

    internal WifiTrafficKeys DeriveTrafficKeys(ReadOnlySpan<byte> padNonce, ReadOnlySpan<byte> pcNonce)
    {
        var nPad = SyncProtocol.Fixed(padNonce, 32);
        var nPc = SyncProtocol.Fixed(pcNonce, 32);
        byte[] salt = [.. nPad, .. nPc];
        var padToPc = HKDF.DeriveKey(HashAlgorithmName.SHA256, transferKey, 32, salt, "clipboardplus wifi v1 pad->pc"u8.ToArray());
        var pcToPad = HKDF.DeriveKey(HashAlgorithmName.SHA256, transferKey, 32, salt, "clipboardplus wifi v1 pc->pad"u8.ToArray());
        return new WifiTrafficKeys(padToPc, pcToPad);
    }

    public override string ToString() => "WifiTransferKeys { Redacted = true }";
}

/// <summary>
/// Tracks already-authenticated Wi-Fi transfer sessions so a session is consumed upon mutual authentication and cannot be replayed.
/// </summary>
public sealed class WifiSessionReplayGuard
{
    private readonly object gate = new();
    private readonly int maxTracked;
    private readonly HashSet<Guid> consumed = [];
    private readonly Queue<Guid> order = new();

    public WifiSessionReplayGuard(int maxTracked = 256)
    {
        SyncProtocol.Require(maxTracked >= 1, SyncError.Limit);
        this.maxTracked = maxTracked;
    }

    public bool IsConsumed(Guid session)
    {
        lock (gate) return consumed.Contains(session);
    }

    public void RequireNotConsumed(Guid session)
    {
        lock (gate) SyncProtocol.Require(!consumed.Contains(session), SyncError.State);
    }

    public bool TryConsume(Guid session)
    {
        lock (gate)
        {
            if (!consumed.Add(session)) return false;
            order.Enqueue(session);
            while (order.Count > maxTracked)
                consumed.Remove(order.Dequeue());
            return true;
        }
    }

    public void ConsumeOrThrow(Guid session)
    {
        SyncProtocol.Require(TryConsume(session), SyncError.State);
    }
}

internal static class WifiTcpHandshakeWire
{
    internal static ReadOnlySpan<byte> Magic => "CPW2"u8;

    internal static byte[] Mac(byte[] authKey, string label, Guid session, byte[] padNonce, byte[] pcNonce)
    {
        byte[] data =
        [
            .. Magic.ToArray(),
            SyncProtocol.WifiTcpVersion,
            .. Encoding.ASCII.GetBytes(label),
            .. SyncProtocol.IdBytes(session),
            .. padNonce,
            .. pcNonce,
        ];
        return HMACSHA256.HashData(authKey, data);
    }

    internal static void CheckEnvelope(ReadOnlySpan<byte> frame, int expectedLength, byte expectedType)
    {
        SyncProtocol.Require(frame.Length == expectedLength);
        SyncProtocol.Require(frame[..4].SequenceEqual(Magic));
        SyncProtocol.Require(frame[4] == SyncProtocol.WifiTcpVersion, SyncError.Version);
        SyncProtocol.Require(frame[5] == expectedType);
    }
}

public sealed record WifiTcpPadAuthentication(byte[] Auth, WifiTrafficKeys Keys);

/// <summary>
/// Single-use per TCP connection (iOS / client side). Nonce injection is internal and ONLY for test vectors.
/// </summary>
public sealed class WifiTcpPadHandshake
{
    private readonly WifiTransferKeys transferKeys;
    private readonly byte[] authKey;
    private readonly byte[] padNonce;
    private int state;

    public WifiTcpPadHandshake(WifiTransferKeys transferKeys)
        : this(transferKeys, testNonce: null)
    {
    }

    internal WifiTcpPadHandshake(WifiTransferKeys transferKeys, byte[]? testNonce)
    {
        SyncProtocol.Require(transferKeys is not null);
        this.transferKeys = transferKeys;
        authKey = transferKeys.AuthKey;
        padNonce = testNonce is null ? RandomNumberGenerator.GetBytes(32) : SyncProtocol.Fixed(testNonce, 32);
    }

    public byte[] CreateHello()
    {
        var previous = state; state = -1;
        SyncProtocol.Require(previous == 0, SyncError.State);
        state = 1;
        return [.. WifiTcpHandshakeWire.Magic.ToArray(), SyncProtocol.WifiTcpVersion, 1, .. SyncProtocol.IdBytes(transferKeys.Session), .. padNonce];
    }

    public WifiTcpPadAuthentication AcceptWelcome(ReadOnlySpan<byte> frame)
    {
        var previous = state; state = -1;
        SyncProtocol.Require(previous == 1, SyncError.State);
        WifiTcpHandshakeWire.CheckEnvelope(frame, SyncProtocol.WifiTcpWelcomeBytes, expectedType: 2);
        var peerSession = new Guid(frame.Slice(6, 16), bigEndian: true);
        SyncProtocol.Require(peerSession == transferKeys.Session, SyncError.Identity);
        var pcNonce = frame.Slice(22, 32).ToArray();
        var expectedPcHmac = WifiTcpHandshakeWire.Mac(authKey, "pc", transferKeys.Session, padNonce, pcNonce);
        SyncProtocol.Require(CryptographicOperations.FixedTimeEquals(frame.Slice(54, 32), expectedPcHmac), SyncError.Authentication);
        var padHmac = WifiTcpHandshakeWire.Mac(authKey, "pad", transferKeys.Session, padNonce, pcNonce);
        byte[] auth = [.. WifiTcpHandshakeWire.Magic.ToArray(), SyncProtocol.WifiTcpVersion, 3, .. padHmac];
        var trafficKeys = transferKeys.DeriveTrafficKeys(padNonce, pcNonce);
        state = 2;
        return new WifiTcpPadAuthentication(auth, trafficKeys);
    }
}

/// <summary>
/// Single-use per TCP connection (PC / server side). Nonce injection is internal and ONLY for test vectors.
/// </summary>
public sealed class WifiTcpPcHandshake
{
    private readonly WifiTransferKeys transferKeys;
    private readonly byte[] authKey;
    private readonly byte[] pcNonce;
    private byte[]? padNonce;
    private int state;

    public bool IsAuthenticated => state == 2;

    public WifiTcpPcHandshake(WifiTransferKeys transferKeys)
        : this(transferKeys, testNonce: null)
    {
    }

    internal WifiTcpPcHandshake(WifiTransferKeys transferKeys, byte[]? testNonce)
    {
        SyncProtocol.Require(transferKeys is not null);
        this.transferKeys = transferKeys;
        authKey = transferKeys.AuthKey;
        pcNonce = testNonce is null ? RandomNumberGenerator.GetBytes(32) : SyncProtocol.Fixed(testNonce, 32);
    }

    public byte[] AcceptHello(ReadOnlySpan<byte> frame)
    {
        var previous = state; state = -1;
        SyncProtocol.Require(previous == 0, SyncError.State);
        WifiTcpHandshakeWire.CheckEnvelope(frame, SyncProtocol.WifiTcpHelloBytes, expectedType: 1);
        var peerSession = new Guid(frame.Slice(6, 16), bigEndian: true);
        SyncProtocol.Require(peerSession == transferKeys.Session, SyncError.Identity);
        padNonce = frame.Slice(22, 32).ToArray();
        var pcHmac = WifiTcpHandshakeWire.Mac(authKey, "pc", transferKeys.Session, padNonce, pcNonce);
        byte[] welcome =
        [
            .. WifiTcpHandshakeWire.Magic.ToArray(),
            SyncProtocol.WifiTcpVersion,
            2,
            .. SyncProtocol.IdBytes(transferKeys.Session),
            .. pcNonce,
            .. pcHmac,
        ];
        state = 1;
        return welcome;
    }

    public WifiTrafficKeys AcceptAuth(ReadOnlySpan<byte> frame)
    {
        var previous = state; state = -1;
        SyncProtocol.Require(previous == 1, SyncError.State);
        WifiTcpHandshakeWire.CheckEnvelope(frame, SyncProtocol.WifiTcpAuthBytes, expectedType: 3);
        var expectedPadHmac = WifiTcpHandshakeWire.Mac(authKey, "pad", transferKeys.Session, padNonce!, pcNonce);
        SyncProtocol.Require(CryptographicOperations.FixedTimeEquals(frame.Slice(6, 32), expectedPadHmac), SyncError.Authentication);
        var trafficKeys = transferKeys.DeriveTrafficKeys(padNonce!, pcNonce);
        state = 2;
        return trafficKeys;
    }
}

/// <summary>
/// Continuous AES-256-GCM frame sealer for Wi-Fi TCP streams.
/// Wire layout (<= 256 KiB total): type(1)=0x20 | dir(1) | payloadLen(4 BE) | seq(8 BE) | ciphertext(N) | tag(16).
/// Nonce: dir(1) | 0x00, 0x00, 0x00 | seq(8 BE). AAD: first 14 bytes.
/// </summary>
public sealed class WifiStreamFrameSender
{
    private readonly byte[] key;
    private readonly byte direction;
    private ulong next;
    private bool exhausted;

    public WifiStreamFrameSender(ReadOnlySpan<byte> key, WifiStreamDirection direction)
    {
        this.key = SyncProtocol.Fixed(key, 32);
        SyncProtocol.Require(direction is WifiStreamDirection.PadToPc or WifiStreamDirection.PcToPad);
        this.direction = (byte)direction;
    }

    public byte[] Seal(ReadOnlySpan<byte> plaintext)
    {
        SyncProtocol.Require(!exhausted, SyncError.Sequence);
        SyncProtocol.Require(plaintext.Length is >= 2 and <= SyncProtocol.MaxWifiPlaintextBytes, SyncError.Limit);

        var frame = new byte[SyncProtocol.WifiFrameHeaderBytes + plaintext.Length + SyncProtocol.WifiFrameTagBytes];
        var aad = frame.AsSpan(0, SyncProtocol.WifiFrameHeaderBytes);
        aad[0] = SyncProtocol.WifiFrameType;
        aad[1] = direction;
        BinaryPrimitives.WriteUInt32BigEndian(aad.Slice(2, 4), (uint)plaintext.Length);
        BinaryPrimitives.WriteUInt64BigEndian(aad.Slice(6, 8), next);

        Span<byte> nonce = stackalloc byte[12];
        nonce[0] = direction;
        nonce[1] = 0;
        nonce[2] = 0;
        nonce[3] = 0;
        aad.Slice(6, 8).CopyTo(nonce.Slice(4, 8));

        using var aes = new AesGcm(key, SyncProtocol.WifiFrameTagBytes);
        aes.Encrypt(
            nonce,
            plaintext,
            frame.AsSpan(SyncProtocol.WifiFrameHeaderBytes, plaintext.Length),
            frame.AsSpan(SyncProtocol.WifiFrameHeaderBytes + plaintext.Length, SyncProtocol.WifiFrameTagBytes),
            aad);

        if (next == ulong.MaxValue) exhausted = true;
        else next++;
        return frame;
    }
}

/// <summary>
/// Continuous AES-256-GCM frame receiver for Wi-Fi TCP streams.
/// Enforces exact consecutive sequence numbers (0, 1, 2, ...), detecting reordering, missing frames,
/// duplicates/replays, wrong direction, oversize (> 256 KiB), truncation, and tampering.
/// Any error permanently invalidates the receiver.
/// </summary>
public sealed class WifiStreamFrameReceiver
{
    private readonly byte[] key;
    private readonly byte direction;
    private ulong expectedNext;
    private bool exhausted;
    private bool failed;

    public WifiStreamFrameReceiver(ReadOnlySpan<byte> key, WifiStreamDirection direction)
    {
        this.key = SyncProtocol.Fixed(key, 32);
        SyncProtocol.Require(direction is WifiStreamDirection.PadToPc or WifiStreamDirection.PcToPad);
        this.direction = (byte)direction;
    }

    public (int PayloadLength, ulong Sequence) ParseHeader(ReadOnlySpan<byte> header)
    {
        SyncProtocol.Require(!failed, SyncError.State);
        try
        {
            SyncProtocol.Require(!exhausted, SyncError.Sequence);
            SyncProtocol.Require(header.Length == SyncProtocol.WifiFrameHeaderBytes);
            SyncProtocol.Require(header[0] == SyncProtocol.WifiFrameType);
            SyncProtocol.Require(header[1] == direction, SyncError.Authentication);
            var payloadLen = BinaryPrimitives.ReadUInt32BigEndian(header.Slice(2, 4));
            SyncProtocol.Require(payloadLen <= SyncProtocol.MaxWifiPlaintextBytes, SyncError.Limit);
            SyncProtocol.Require(payloadLen >= 2);
            var sequence = BinaryPrimitives.ReadUInt64BigEndian(header.Slice(6, 8));
            SyncProtocol.Require(sequence == expectedNext, SyncError.Sequence);
            return ((int)payloadLen, sequence);
        }
        catch
        {
            failed = true;
            throw;
        }
    }

    public byte[] Open(ReadOnlySpan<byte> frame)
    {
        SyncProtocol.Require(!failed, SyncError.State);
        try
        {
            SyncProtocol.Require(frame.Length <= SyncProtocol.MaxWifiFrameBytes, SyncError.Limit);
            SyncProtocol.Require(frame.Length >= SyncProtocol.WifiFrameHeaderBytes, SyncError.Packet);
            var header = frame[..SyncProtocol.WifiFrameHeaderBytes];
            var (payloadLen, _) = ParseHeader(header);
            var expectedFrameLen = SyncProtocol.WifiFrameHeaderBytes + payloadLen + SyncProtocol.WifiFrameTagBytes;
            SyncProtocol.Require(frame.Length == expectedFrameLen, SyncError.Packet);
            return DecryptVerifiedHeader(header, frame[SyncProtocol.WifiFrameHeaderBytes..], payloadLen);
        }
        catch
        {
            failed = true;
            throw;
        }
    }

    public byte[] Open(ReadOnlySpan<byte> header, ReadOnlySpan<byte> bodyAndTag)
    {
        SyncProtocol.Require(!failed, SyncError.State);
        try
        {
            var (payloadLen, _) = ParseHeader(header);
            SyncProtocol.Require(bodyAndTag.Length == payloadLen + SyncProtocol.WifiFrameTagBytes, SyncError.Packet);
            return DecryptVerifiedHeader(header, bodyAndTag, payloadLen);
        }
        catch
        {
            failed = true;
            throw;
        }
    }

    private byte[] DecryptVerifiedHeader(ReadOnlySpan<byte> header, ReadOnlySpan<byte> bodyAndTag, int payloadLen)
    {
        Span<byte> nonce = stackalloc byte[12];
        nonce[0] = direction;
        nonce[1] = 0;
        nonce[2] = 0;
        nonce[3] = 0;
        header.Slice(6, 8).CopyTo(nonce.Slice(4, 8));

        var plaintext = new byte[payloadLen];
        try
        {
            using var aes = new AesGcm(key, SyncProtocol.WifiFrameTagBytes);
            aes.Decrypt(nonce, bodyAndTag[..payloadLen], bodyAndTag.Slice(payloadLen, SyncProtocol.WifiFrameTagBytes), plaintext, header);
        }
        catch (CryptographicException)
        {
            throw new SyncProtocolException(SyncError.Authentication);
        }

        if (expectedNext == ulong.MaxValue) exhausted = true;
        else expectedNext++;
        return plaintext;
    }
}
