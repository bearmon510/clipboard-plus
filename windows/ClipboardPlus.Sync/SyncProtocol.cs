using System.Buffers.Binary;
using System.Diagnostics.CodeAnalysis;
using System.Text;

namespace ClipboardPlus.Sync;

public enum SyncError { Format, Limit, Packet, State, Authentication, Identity, Sequence, Version }

public sealed class SyncProtocolException(SyncError code) : Exception($"Sync protocol: {code}")
{
    public SyncError Code { get; } = code;
}

public static class SyncProtocol
{
    public const byte Version = 2;
    public const int MaxItemBytes = 10 * 1024 * 1024;
    public const int ChunkBytes = 32 * 1024;
    public const int MaxPending = 100;
    public const int MaxHistory = 300;
    public const int MaxFilesPerCopy = 10;
    public const long MaxImagePixels = 40_000_000;
    public static readonly TimeSpan PendingLifetime = TimeSpan.FromHours(24);
    public static readonly TimeSpan DuplicateWindow = TimeSpan.FromMinutes(10);
    public const int MaxFrameBytes = 4 * 1024 * 1024;
    public const int MaxPlaintextBytes = MaxFrameBytes - 9 - 16;
    public const int MaxHeaderBytes = ushort.MaxValue;
    public const int MaxAckIds = 1024;
    public const long MaxTimestamp = 9_007_199_254_740_991;
    internal static readonly UTF8Encoding Utf8 = new(false, true);
    internal static void Require([DoesNotReturnIf(false)] bool condition, SyncError code = SyncError.Format)
    {
        if (!condition) throw new SyncProtocolException(code);
    }
    internal static byte[] Fixed(ReadOnlySpan<byte> bytes, int count)
    {
        Require(bytes.Length == count);
        return bytes.ToArray();
    }
    internal static string Id(Guid id) => id.ToString("D").ToUpperInvariant();
    internal static Guid ParseId(string? value)
    {
        Require(value is { Length: 36 } && Guid.TryParseExact(value, "D", out _));
        return Guid.ParseExact(value!, "D");
    }
    internal static byte[] IdBytes(Guid id) => id.ToByteArray(bigEndian: true);
    internal static byte[] Number(ulong sequence)
    {
        var result = new byte[8];
        BinaryPrimitives.WriteUInt64BigEndian(result, sequence);
        return result;
    }
}
