using System.Security.Cryptography;
using System.Text;

namespace ClipboardPlus.Sync;

public sealed class SyncPairing
{
    private readonly byte[] key;
    public Guid PcId { get; }
    public string Name { get; }
    public byte[] Key => key.ToArray();

    public SyncPairing(Guid pcId, ReadOnlySpan<byte> key, string name)
    {
        PcId = pcId;
        this.key = SyncProtocol.Fixed(key, 32);
        ValidateName(name);
        Name = name;
    }

    public static SyncPairing Create(string name) => new(Guid.NewGuid(), RandomNumberGenerator.GetBytes(32), name);
    private static bool Unreserved(byte b) => b is >= 65 and <= 90 or >= 97 and <= 122 or >= 48 and <= 57 or 45 or 46 or 95 or 126;
    private static string Base64Url(byte[] value) => Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private static void ValidateName(string name)
    {
        try
        {
            SyncProtocol.Require(SyncProtocol.Utf8.GetByteCount(name) is >= 1 and <= 255 && !name.Any(c => c < 32 || c == 127));
        }
        catch (EncoderFallbackException) { throw new SyncProtocolException(SyncError.Format); }
    }
    public string ToQrString()
    {
        var name = string.Concat(SyncProtocol.Utf8.GetBytes(Name).Select(b => Unreserved(b) ? ((char)b).ToString() : $"%{b:X2}"));
        return $"clipboardplus-pair:1:{Base64Url(SyncProtocol.IdBytes(PcId))}:{Base64Url(key)}:{name}";
    }
    public static SyncPairing Parse(string text)
    {
        SyncProtocol.Require(text.Length <= 853);
        var parts = text.Split(':');
        SyncProtocol.Require(parts.Length == 5 && parts[0] == "clipboardplus-pair" && parts[1] == "1");
        static byte[] Decode(string value, int count)
        {
            SyncProtocol.Require(value.Length == (count * 8 + 5) / 6 && value.All(c => c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_'));
            var result = Convert.FromBase64String(value.Replace('-', '+').Replace('_', '/') + new string('=', (4 - value.Length % 4) % 4));
            SyncProtocol.Require(result.Length == count && Base64Url(result) == value);
            return result;
        }
        var id = new Guid(Decode(parts[2], 16), bigEndian: true);
        var key = Decode(parts[3], 32);
        var nameBytes = new List<byte>();
        for (var i = 0; i < parts[4].Length; i++)
        {
            var c = parts[4][i];
            if (c < 128 && Unreserved((byte)c)) nameBytes.Add((byte)c);
            else
            {
                SyncProtocol.Require(c == '%' && i + 2 < parts[4].Length);
                SyncProtocol.Require(byte.TryParse(parts[4].AsSpan(i + 1, 2), System.Globalization.NumberStyles.AllowHexSpecifier, null, out var b));
                nameBytes.Add(b); i += 2;
            }
        }
        try { return new SyncPairing(id, key, SyncProtocol.Utf8.GetString(nameBytes.ToArray())); }
        catch (DecoderFallbackException) { throw new SyncProtocolException(SyncError.Format); }
    }
}
