using System.Buffers.Binary;
using System.Security.Cryptography;

namespace ClipboardPlus.Sync;

// Reference types prevent accidental copying/resetting of nonce counters.
// Use a single sender/receiver for each direction of one authenticated connection, serially.
public sealed class SyncFrameSender
{
    private readonly byte[] key;
    private ulong next;
    private bool exhausted;
    public SyncFrameSender(ReadOnlySpan<byte> key) => this.key = SyncProtocol.Fixed(key, 32);
    public byte[] Seal(ReadOnlySpan<byte> plaintext)
    {
        SyncProtocol.Require(!exhausted, SyncError.Sequence);
        SyncProtocol.Require(plaintext.Length is >= 2 and <= SyncProtocol.MaxPlaintextBytes, SyncError.Limit);
        byte[] aad = [0x10, .. SyncProtocol.Number(next)];
        byte[] nonce = [0, 0, 0, 0, .. aad.AsSpan(1).ToArray()];
        var frame = new byte[9 + plaintext.Length + 16]; aad.CopyTo(frame, 0);
        using var aes = new AesGcm(key, 16);
        aes.Encrypt(nonce, plaintext, frame.AsSpan(9, plaintext.Length), frame.AsSpan(9 + plaintext.Length, 16), aad);
        if (next == ulong.MaxValue) exhausted = true; else next++;
        return frame;
    }
}

public sealed class SyncFrameReceiver
{
    private readonly byte[] key;
    private ulong? last;
    private bool failed;
    public SyncFrameReceiver(ReadOnlySpan<byte> key) => this.key = SyncProtocol.Fixed(key, 32);
    public byte[] Open(ReadOnlySpan<byte> frame)
    {
        SyncProtocol.Require(!failed, SyncError.State);
        try
        {
            SyncProtocol.Require(frame.Length <= SyncProtocol.MaxFrameBytes, SyncError.Limit);
            SyncProtocol.Require(frame.Length >= 27 && frame[0] == 0x10);
            var sequence = BinaryPrimitives.ReadUInt64BigEndian(frame.Slice(1, 8));
            SyncProtocol.Require(last is null || sequence > last, SyncError.Sequence);
            byte[] nonce = [0, 0, 0, 0, .. frame.Slice(1, 8).ToArray()];
            var plaintext = new byte[frame.Length - 25];
            using var aes = new AesGcm(key, 16);
            aes.Decrypt(nonce, frame.Slice(9, plaintext.Length), frame[^16..], plaintext, frame[..9]);
            last = sequence;
            return plaintext;
        }
        catch (CryptographicException) { failed = true; throw new SyncProtocolException(SyncError.Authentication); }
        catch { failed = true; throw; }
    }
}
