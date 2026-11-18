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
    public const byte Version = 3;
    public const int MaxItemBytes = 10 * 1024 * 1024;
    public const int ChunkBytes = 32 * 1024;
    public const int MaxPending = 100;
    public const int MaxHistory = 300;
    public const int MaxFilesPerCopy = 10;
    public const long MaxImagePixels = 40_000_000;
    public static readonly TimeSpan PendingLifetime = TimeSpan.FromHours(24);
    public static readonly TimeSpan DuplicateWindow = TimeSpan.FromMinutes(10);
    public const int MaxTemplates = 300;
    public const int MaxTemplateTombstones = 1000;
    public static readonly TimeSpan TemplateTombstoneLifetime = TimeSpan.FromDays(180);
    public const long TemplateTombstoneLifetimeMillis = 180L * 24 * 60 * 60 * 1000;
    public const int MaxTemplateTextBytes = 64 * 1024;
    public const int MaxTemplateTitleCharacters = 100;
    public const int MaxTemplateTitleBytes = 400;
    public const int MaxTemplateTagCharacters = 30;
    public const int MaxTemplateTagBytes = 120;
    public const int MaxTemplatePageBodyBytes = 256 * 1024;
    public const int MaxTemplatePages = 80;
    public const int MaxTemplateTotalBytes = 20 * 1024 * 1024;
    public const long TemplateClockSkewWarningMillis = 5L * 60 * 1000;
    public const long TemplateFutureTimestampCapMillis = 365L * 24 * 60 * 60 * 1000;
    public const int MaxFrameBytes = 4 * 1024 * 1024;
    public const int MaxPlaintextBytes = MaxFrameBytes - 9 - 16;
    public const int MaxHeaderBytes = ushort.MaxValue;
    public const int MaxAckIds = 1024;
    public const long MaxTimestamp = 9_007_199_254_740_991;
    internal static readonly UTF8Encoding Utf8 = new(false, true);
    internal static bool IsControlOrNewline(char c) => char.IsControl(c) || c is '\u2028' or '\u2029';
    internal static bool IsLowerHex64(string? value) =>
        value is { Length: 64 } && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
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
        Require(value is { Length: 36 } && IsStandardUuid(value));
        Require(Guid.TryParseExact(value, "D", out var result) &&
            string.Equals(result.ToString("D"), value, StringComparison.OrdinalIgnoreCase));
        return result;
    }
    private static bool IsStandardUuid(string value)
    {
        for (var i = 0; i < 36; i++)
        {
            var c = value[i];
            if (i is 8 or 13 or 18 or 23) { if (c != '-') return false; }
            else if (c is not ((>= '0' and <= '9') or (>= 'a' and <= 'f') or (>= 'A' and <= 'F'))) return false;
        }
        return true;
    }
    internal static byte[] IdBytes(Guid id) => id.ToByteArray(bigEndian: true);
    internal static byte[] Number(ulong sequence)
    {
        var result = new byte[8];
        BinaryPrimitives.WriteUInt64BigEndian(result, sequence);
        return result;
    }
}
