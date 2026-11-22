using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;

namespace ClipboardPlus.Sync;

public abstract record WifiStreamMessage;

public sealed record WifiStreamOffer(SyncOffer Offer) : WifiStreamMessage;

public sealed record WifiStreamResume(Guid Id, int Offset) : WifiStreamMessage;

public sealed record WifiStreamChunk(Guid Id, int Offset, byte[] Data) : WifiStreamMessage
{
    public bool Equals(WifiStreamChunk? other) =>
        other is not null && Id == other.Id && Offset == other.Offset && Data.AsSpan().SequenceEqual(other.Data);

    public override int GetHashCode() => HashCode.Combine(Id, Offset, Data.Length);
}

public sealed record WifiStreamAck(Guid Id) : WifiStreamMessage;

public sealed record WifiStreamDone : WifiStreamMessage;

public static class WifiStreamMessageCodec
{
    public static byte[] Encode(WifiStreamMessage message)
    {
        SyncProtocol.Require(message is not null);
        var sink = new BoundedUtf8Sink(SyncProtocol.MaxHeaderBytes, writeBytes: true);
        ReadOnlySpan<byte> body = ReadOnlySpan<byte>.Empty;
        sink.WriteByte((byte)'{');
        switch (message)
        {
            case WifiStreamOffer offerMessage:
                SyncProtocol.Require(offerMessage.Offer is not null);
                var o = offerMessage.Offer;
                SyncMessageCodec.ValidateOffer(o, maxSize: SyncProtocol.MaxWifiItemBytes);
                sink.WriteAscii("\"at\":"u8);
                sink.WriteInt64(o.At);
                sink.WriteAscii(",\"from\":"u8);
                sink.WriteEscapedJsonString(o.From);
                sink.WriteAscii(",\"id\":"u8);
                sink.WriteEscapedJsonString(SyncProtocol.Id(o.Id));
                sink.WriteAscii(",\"kind\":"u8);
                sink.WriteEscapedJsonString(o.Kind);
                sink.WriteAscii(",\"name64\":"u8);
                sink.WriteEscapedJsonString(o.Name64);
                sink.WriteAscii(",\"sha256\":"u8);
                sink.WriteEscapedJsonString(o.Sha256);
                sink.WriteAscii(",\"size\":"u8);
                sink.WriteInt64(o.Size);
                sink.WriteAscii(",\"t\":\"offer\",\"type\":"u8);
                sink.WriteEscapedJsonString(o.Type);
                break;

            case WifiStreamResume resume:
                SyncProtocol.Require(resume.Offset >= 0);
                SyncProtocol.Require(resume.Offset <= SyncProtocol.MaxWifiItemBytes, SyncError.Limit);
                sink.WriteAscii("\"id\":"u8);
                sink.WriteEscapedJsonString(SyncProtocol.Id(resume.Id));
                sink.WriteAscii(",\"offset\":"u8);
                sink.WriteInt64(resume.Offset);
                sink.WriteAscii(",\"t\":\"resume\""u8);
                break;

            case WifiStreamChunk chunk:
                SyncProtocol.Require(chunk.Data is not null && chunk.Offset >= 0 && chunk.Data.Length > 0);
                SyncProtocol.Require(chunk.Data.Length <= SyncProtocol.MaxWifiChunkBytes, SyncError.Limit);
                SyncProtocol.Require(chunk.Offset <= SyncProtocol.MaxWifiItemBytes - chunk.Data.Length, SyncError.Limit);
                sink.WriteAscii("\"id\":"u8);
                sink.WriteEscapedJsonString(SyncProtocol.Id(chunk.Id));
                sink.WriteAscii(",\"offset\":"u8);
                sink.WriteInt64(chunk.Offset);
                sink.WriteAscii(",\"t\":\"chunk\""u8);
                body = chunk.Data;
                break;

            case WifiStreamAck ack:
                sink.WriteAscii("\"id\":"u8);
                sink.WriteEscapedJsonString(SyncProtocol.Id(ack.Id));
                sink.WriteAscii(",\"t\":\"ack\""u8);
                break;

            case WifiStreamDone:
                sink.WriteAscii("\"t\":\"done\""u8);
                break;

            default:
                throw new SyncProtocolException(SyncError.Format);
        }
        sink.WriteByte((byte)'}');
        var headerBytes = sink.ToArray();
        SyncProtocol.Require(headerBytes.Length <= SyncProtocol.MaxHeaderBytes, SyncError.Limit);
        SyncProtocol.Require(2 + headerBytes.Length + body.Length <= SyncProtocol.MaxWifiPlaintextBytes, SyncError.Limit);
        var result = new byte[2 + headerBytes.Length + body.Length];
        BinaryPrimitives.WriteUInt16BigEndian(result, (ushort)headerBytes.Length);
        headerBytes.CopyTo(result, 2);
        body.CopyTo(result.AsSpan(2 + headerBytes.Length));
        return result;
    }

    public static WifiStreamMessage Decode(ReadOnlySpan<byte> plaintext)
    {
        SyncProtocol.Require(plaintext.Length <= SyncProtocol.MaxWifiPlaintextBytes, SyncError.Limit);
        SyncProtocol.Require(plaintext.Length >= 2);
        var headerLen = BinaryPrimitives.ReadUInt16BigEndian(plaintext);
        SyncProtocol.Require(headerLen > 0 && headerLen <= plaintext.Length - 2);
        var header = plaintext.Slice(2, headerLen).ToArray();
        SyncProtocol.Require(header.All(b => b < 128));
        var body = plaintext[(2 + headerLen)..];

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
                case "offer":
                {
                    Keys("at", "from", "id", "kind", "name64", "sha256", "size", "t", "type");
                    SyncProtocol.Require(body.IsEmpty);
                    var sizeLong = SyncMessageCodec.Integer(root, "size");
                    SyncProtocol.Require(sizeLong >= 0);
                    SyncProtocol.Require(sizeLong <= SyncProtocol.MaxWifiItemBytes, SyncError.Limit);
                    var offer = new SyncOffer(
                        SyncProtocol.ParseId(SyncMessageCodec.String(root, "id")),
                        SyncMessageCodec.Integer(root, "at"),
                        SyncMessageCodec.String(root, "from"),
                        SyncMessageCodec.String(root, "kind"),
                        (int)sizeLong,
                        SyncMessageCodec.String(root, "sha256"),
                        SyncMessageCodec.String(root, "name64"),
                        SyncMessageCodec.String(root, "type"));
                    SyncMessageCodec.ValidateOffer(offer, maxSize: SyncProtocol.MaxWifiItemBytes);
                    return new WifiStreamOffer(offer);
                }

                case "resume":
                {
                    Keys("id", "offset", "t");
                    SyncProtocol.Require(body.IsEmpty);
                    var offsetLong = SyncMessageCodec.Integer(root, "offset");
                    SyncProtocol.Require(offsetLong >= 0);
                    SyncProtocol.Require(offsetLong <= SyncProtocol.MaxWifiItemBytes, SyncError.Limit);
                    return new WifiStreamResume(SyncProtocol.ParseId(SyncMessageCodec.String(root, "id")), (int)offsetLong);
                }

                case "chunk":
                {
                    Keys("id", "offset", "t");
                    var offsetLong = SyncMessageCodec.Integer(root, "offset");
                    SyncProtocol.Require(offsetLong >= 0);
                    SyncProtocol.Require(body.Length > 0);
                    SyncProtocol.Require(body.Length <= SyncProtocol.MaxWifiChunkBytes, SyncError.Limit);
                    SyncProtocol.Require(offsetLong <= SyncProtocol.MaxWifiItemBytes - body.Length, SyncError.Limit);
                    return new WifiStreamChunk(SyncProtocol.ParseId(SyncMessageCodec.String(root, "id")), (int)offsetLong, body.ToArray());
                }

                case "ack":
                    Keys("id", "t");
                    SyncProtocol.Require(body.IsEmpty);
                    return new WifiStreamAck(SyncProtocol.ParseId(SyncMessageCodec.String(root, "id")));

                case "done":
                    Keys("t");
                    SyncProtocol.Require(body.IsEmpty);
                    return new WifiStreamDone();

                default:
                    throw new SyncProtocolException(SyncError.Format);
            }
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or OverflowException)
        {
            throw new SyncProtocolException(SyncError.Format);
        }
    }
}

public sealed class WifiEncryptedStream
{
    private readonly Stream stream;
    private readonly WifiStreamFrameSender sender;
    private readonly WifiStreamFrameReceiver receiver;

    public WifiEncryptedStream(Stream stream, WifiStreamFrameSender sender, WifiStreamFrameReceiver receiver)
    {
        this.stream = stream ?? throw new ArgumentNullException(nameof(stream));
        this.sender = sender ?? throw new ArgumentNullException(nameof(sender));
        this.receiver = receiver ?? throw new ArgumentNullException(nameof(receiver));
    }

    public static Task<WifiEncryptedStream> ConnectAsPadAsync(
        Stream stream,
        WifiTransferKeys keys,
        CancellationToken cancellationToken = default) =>
        ConnectAsPadAsync(stream, keys, testNonce: null, cancellationToken);

    internal static async Task<WifiEncryptedStream> ConnectAsPadAsync(
        Stream stream,
        WifiTransferKeys keys,
        byte[]? testNonce,
        CancellationToken cancellationToken = default)
    {
        var handshake = new WifiTcpPadHandshake(keys, testNonce);
        var hello = handshake.CreateHello();
        await stream.WriteAsync(hello, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);

        var welcome = await ReadExactOrThrowAsync(stream, SyncProtocol.WifiTcpWelcomeBytes, cancellationToken).ConfigureAwait(false);
        var auth = handshake.AcceptWelcome(welcome);

        await stream.WriteAsync(auth.Auth, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);

        return new WifiEncryptedStream(
            stream,
            new WifiStreamFrameSender(auth.Keys.PadToPc, WifiStreamDirection.PadToPc),
            new WifiStreamFrameReceiver(auth.Keys.PcToPad, WifiStreamDirection.PcToPad));
    }

    public static Task<WifiEncryptedStream> AcceptAsPcAsync(
        Stream stream,
        WifiTransferKeys keys,
        WifiSessionReplayGuard replayGuard,
        CancellationToken cancellationToken = default) =>
        AcceptAsPcAsync(stream, keys, replayGuard, testNonce: null, cancellationToken);

    internal static async Task<WifiEncryptedStream> AcceptAsPcAsync(
        Stream stream,
        WifiTransferKeys keys,
        WifiSessionReplayGuard replayGuard,
        byte[]? testNonce,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(replayGuard);
        replayGuard.RequireNotConsumed(keys.Session);
        var handshake = new WifiTcpPcHandshake(keys, testNonce);
        var hello = await ReadExactOrThrowAsync(stream, SyncProtocol.WifiTcpHelloBytes, cancellationToken).ConfigureAwait(false);
        var welcome = handshake.AcceptHello(hello);

        await stream.WriteAsync(welcome, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);

        var auth = await ReadExactOrThrowAsync(stream, SyncProtocol.WifiTcpAuthBytes, cancellationToken).ConfigureAwait(false);
        var trafficKeys = handshake.AcceptAuth(auth);
        replayGuard.ConsumeOrThrow(keys.Session);

        return new WifiEncryptedStream(
            stream,
            new WifiStreamFrameSender(trafficKeys.PcToPad, WifiStreamDirection.PcToPad),
            new WifiStreamFrameReceiver(trafficKeys.PadToPc, WifiStreamDirection.PadToPc));
    }

    public async Task SendMessageAsync(WifiStreamMessage message, CancellationToken cancellationToken = default)
    {
        var plaintext = WifiStreamMessageCodec.Encode(message);
        var frame = sender.Seal(plaintext);
        await stream.WriteAsync(frame, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task<WifiStreamMessage> ReceiveMessageAsync(CancellationToken cancellationToken = default)
    {
        var header = await ReadExactOrThrowAsync(stream, SyncProtocol.WifiFrameHeaderBytes, cancellationToken).ConfigureAwait(false);
        var (payloadLength, _) = receiver.ParseHeader(header);
        var bodyAndTag = await ReadExactOrThrowAsync(stream, payloadLength + SyncProtocol.WifiFrameTagBytes, cancellationToken).ConfigureAwait(false);
        var plaintext = receiver.Open(header, bodyAndTag);
        return WifiStreamMessageCodec.Decode(plaintext);
    }

    private static async Task<byte[]> ReadExactOrThrowAsync(Stream stream, int count, CancellationToken cancellationToken)
    {
        var buffer = new byte[count];
        var offset = 0;
        while (offset < count)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(offset, count - offset), cancellationToken).ConfigureAwait(false);
            if (read == 0) throw new SyncProtocolException(SyncError.Packet);
            offset += read;
        }
        return buffer;
    }
}

public readonly record struct WifiOfferDecision(bool IsAlreadyCompleted, int ResumeOffset)
{
    public static WifiOfferDecision AlreadyCompleted => new(true, 0);
    public static WifiOfferDecision Resume(int offset) => new(false, offset);
}

public interface IWifiTransferSource
{
    SyncOffer Offer { get; }
    Task<int> ReadChunkAsync(int offset, Memory<byte> buffer, CancellationToken cancellationToken = default);
}

public interface IWifiTransferSink
{
    Task<WifiOfferDecision> BeginOfferAsync(SyncOffer offer, CancellationToken cancellationToken = default);
    Task<int> AppendChunkAsync(Guid id, int offset, ReadOnlyMemory<byte> data, CancellationToken cancellationToken = default);
    Task VerifyAndCompleteAsync(SyncOffer offer, CancellationToken cancellationToken = default);
    Task DiscardPartialAsync(Guid id, CancellationToken cancellationToken = default);
}

public sealed record WifiSentItemResult(Guid Id, int TotalBytes, int TransferredBytes, bool AlreadyCompleted);
public sealed record WifiReceivedItemResult(SyncOffer Offer, int TransferredBytes, bool AlreadyCompleted);
public sealed record WifiSessionResult(IReadOnlyList<WifiSentItemResult> Sent, IReadOnlyList<WifiReceivedItemResult> Received);

public static class WifiTransferEngine
{
    public static async Task<IReadOnlyList<WifiSentItemResult>> SendItemsAsync(
        WifiEncryptedStream channel,
        IReadOnlyList<IWifiTransferSource> items,
        int chunkSize = SyncProtocol.MaxWifiChunkBytes,
        Action<Guid, int, int>? onProgress = null,
        CancellationToken cancellationToken = default)
    {
        SyncProtocol.Require(chunkSize is >= 1 and <= SyncProtocol.MaxWifiChunkBytes, SyncError.Limit);
        var results = new List<WifiSentItemResult>(items.Count);
        var buffer = new byte[chunkSize];

        foreach (var item in items)
        {
            var offer = item.Offer;
            SyncMessageCodec.ValidateOffer(offer, maxSize: SyncProtocol.MaxWifiItemBytes);
            await channel.SendMessageAsync(new WifiStreamOffer(offer), cancellationToken).ConfigureAwait(false);

            var reply = await channel.ReceiveMessageAsync(cancellationToken).ConfigureAwait(false);
            if (reply is WifiStreamAck immediateAck)
            {
                SyncProtocol.Require(immediateAck.Id == offer.Id, SyncError.State);
                onProgress?.Invoke(offer.Id, offer.Size, offer.Size);
                results.Add(new WifiSentItemResult(offer.Id, offer.Size, 0, AlreadyCompleted: true));
                continue;
            }

            if (reply is not WifiStreamResume resume || resume.Id != offer.Id)
                throw new SyncProtocolException(SyncError.State);

            SyncProtocol.Require(resume.Offset >= 0 && resume.Offset < offer.Size, SyncError.State);
            var cursor = resume.Offset;
            var transferred = 0;

            while (cursor < offer.Size)
            {
                var want = Math.Min(chunkSize, offer.Size - cursor);
                var read = await item.ReadChunkAsync(cursor, buffer.AsMemory(0, want), cancellationToken).ConfigureAwait(false);
                SyncProtocol.Require(read >= 1 && read <= want, SyncError.State);
                var chunkData = buffer.AsSpan(0, read).ToArray();
                await channel.SendMessageAsync(new WifiStreamChunk(offer.Id, cursor, chunkData), cancellationToken).ConfigureAwait(false);
                cursor += read;
                transferred += read;
                onProgress?.Invoke(offer.Id, cursor, offer.Size);
            }

            var finalReply = await channel.ReceiveMessageAsync(cancellationToken).ConfigureAwait(false);
            if (finalReply is not WifiStreamAck finalAck || finalAck.Id != offer.Id)
                throw new SyncProtocolException(SyncError.State);

            results.Add(new WifiSentItemResult(offer.Id, offer.Size, transferred, AlreadyCompleted: false));
        }

        await channel.SendMessageAsync(new WifiStreamDone(), cancellationToken).ConfigureAwait(false);
        return results;
    }

    public static async Task<IReadOnlyList<WifiReceivedItemResult>> ReceiveItemsAsync(
        WifiEncryptedStream channel,
        IWifiTransferSink sink,
        string expectedFrom,
        Action<Guid, int, int>? onProgress = null,
        CancellationToken cancellationToken = default)
    {
        SyncProtocol.Require(expectedFrom is "pc" or "pad");
        var results = new List<WifiReceivedItemResult>();

        while (true)
        {
            var message = await channel.ReceiveMessageAsync(cancellationToken).ConfigureAwait(false);
            if (message is WifiStreamDone)
                return results;

            if (message is not WifiStreamOffer offerMessage)
                throw new SyncProtocolException(SyncError.State);

            var offer = offerMessage.Offer;
            SyncProtocol.Require(offer.From == expectedFrom, SyncError.Format);
            SyncMessageCodec.ValidateOffer(offer, maxSize: SyncProtocol.MaxWifiItemBytes);

            var decision = await sink.BeginOfferAsync(offer, cancellationToken).ConfigureAwait(false);
            if (decision.IsAlreadyCompleted)
            {
                await channel.SendMessageAsync(new WifiStreamAck(offer.Id), cancellationToken).ConfigureAwait(false);
                onProgress?.Invoke(offer.Id, offer.Size, offer.Size);
                results.Add(new WifiReceivedItemResult(offer, 0, AlreadyCompleted: true));
                continue;
            }

            var startOffset = decision.ResumeOffset;
            SyncProtocol.Require(startOffset >= 0 && startOffset <= offer.Size, SyncError.State);

            if (startOffset == offer.Size)
            {
                await sink.VerifyAndCompleteAsync(offer, cancellationToken).ConfigureAwait(false);
                await channel.SendMessageAsync(new WifiStreamAck(offer.Id), cancellationToken).ConfigureAwait(false);
                onProgress?.Invoke(offer.Id, offer.Size, offer.Size);
                results.Add(new WifiReceivedItemResult(offer, 0, AlreadyCompleted: false));
                continue;
            }

            await channel.SendMessageAsync(new WifiStreamResume(offer.Id, startOffset), cancellationToken).ConfigureAwait(false);
            var cursor = startOffset;
            var transferred = 0;

            while (cursor < offer.Size)
            {
                var nextMessage = await channel.ReceiveMessageAsync(cancellationToken).ConfigureAwait(false);
                if (nextMessage is not WifiStreamChunk chunk)
                    throw new SyncProtocolException(SyncError.State);
                SyncProtocol.Require(chunk.Id == offer.Id, SyncError.State);
                SyncProtocol.Require(chunk.Offset == cursor, SyncError.Format);
                SyncProtocol.Require(chunk.Data.Length <= offer.Size - cursor, SyncError.Format);

                var saved = await sink.AppendChunkAsync(offer.Id, chunk.Offset, chunk.Data, cancellationToken).ConfigureAwait(false);
                SyncProtocol.Require(saved == cursor + chunk.Data.Length, SyncError.State);
                cursor = saved;
                transferred += chunk.Data.Length;
                onProgress?.Invoke(offer.Id, cursor, offer.Size);
            }

            await sink.VerifyAndCompleteAsync(offer, cancellationToken).ConfigureAwait(false);
            await channel.SendMessageAsync(new WifiStreamAck(offer.Id), cancellationToken).ConfigureAwait(false);
            results.Add(new WifiReceivedItemResult(offer, transferred, AlreadyCompleted: false));
        }
    }

    public static Task<WifiSessionResult> RunPadSessionAsync(
        Stream stream,
        WifiTransferKeys keys,
        IReadOnlyList<IWifiTransferSource> outgoing,
        IWifiTransferSink sink,
        int chunkSize = SyncProtocol.MaxWifiChunkBytes,
        CancellationToken cancellationToken = default) =>
        RunPadSessionAsync(stream, keys, outgoing, sink, testNonce: null, chunkSize, cancellationToken);

    internal static async Task<WifiSessionResult> RunPadSessionAsync(
        Stream stream,
        WifiTransferKeys keys,
        IReadOnlyList<IWifiTransferSource> outgoing,
        IWifiTransferSink sink,
        byte[]? testNonce,
        int chunkSize = SyncProtocol.MaxWifiChunkBytes,
        CancellationToken cancellationToken = default)
    {
        var channel = await WifiEncryptedStream.ConnectAsPadAsync(stream, keys, testNonce, cancellationToken).ConfigureAwait(false);
        var sent = await SendItemsAsync(channel, outgoing, chunkSize, cancellationToken: cancellationToken).ConfigureAwait(false);
        var received = await ReceiveItemsAsync(channel, sink, expectedFrom: "pc", cancellationToken: cancellationToken).ConfigureAwait(false);
        return new WifiSessionResult(sent, received);
    }

    public static Task<WifiSessionResult> RunPcSessionAsync(
        Stream stream,
        WifiTransferKeys keys,
        IReadOnlyList<IWifiTransferSource> outgoing,
        IWifiTransferSink sink,
        WifiSessionReplayGuard replayGuard,
        int chunkSize = SyncProtocol.MaxWifiChunkBytes,
        CancellationToken cancellationToken = default) =>
        RunPcSessionAsync(stream, keys, outgoing, sink, replayGuard, testNonce: null, chunkSize, cancellationToken);

    internal static async Task<WifiSessionResult> RunPcSessionAsync(
        Stream stream,
        WifiTransferKeys keys,
        IReadOnlyList<IWifiTransferSource> outgoing,
        IWifiTransferSink sink,
        WifiSessionReplayGuard replayGuard,
        byte[]? testNonce,
        int chunkSize = SyncProtocol.MaxWifiChunkBytes,
        CancellationToken cancellationToken = default)
    {
        var channel = await WifiEncryptedStream.AcceptAsPcAsync(stream, keys, replayGuard, testNonce, cancellationToken).ConfigureAwait(false);
        var received = await ReceiveItemsAsync(channel, sink, expectedFrom: "pad", cancellationToken: cancellationToken).ConfigureAwait(false);
        var sent = await SendItemsAsync(channel, outgoing, chunkSize, cancellationToken: cancellationToken).ConfigureAwait(false);
        return new WifiSessionResult(sent, received);
    }
}

public sealed class InMemoryWifiTransferSource : IWifiTransferSource
{
    private readonly ReadOnlyMemory<byte> payload;
    public SyncOffer Offer { get; }

    public InMemoryWifiTransferSource(SyncOffer offer, ReadOnlyMemory<byte> payload)
    {
        Offer = offer ?? throw new ArgumentNullException(nameof(offer));
        this.payload = payload;
    }

    public Task<int> ReadChunkAsync(int offset, Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        SyncProtocol.Require(offset >= 0 && offset <= payload.Length, SyncError.State);
        var count = Math.Min(buffer.Length, payload.Length - offset);
        payload.Span.Slice(offset, count).CopyTo(buffer.Span);
        return Task.FromResult(count);
    }
}

public sealed class InMemoryWifiTransferSink : IWifiTransferSink
{
    private sealed class PartialEntry(SyncOffer offer)
    {
        public readonly SyncOffer Offer = offer;
        public readonly MemoryStream Buffer = new();
    }

    private readonly Dictionary<Guid, PartialEntry> partials = [];
    private readonly Dictionary<Guid, (SyncOffer Offer, byte[] Data)> completed = [];

    public IReadOnlyDictionary<Guid, (SyncOffer Offer, byte[] Data)> Completed => completed;
    public bool HasPartial(Guid id) => partials.ContainsKey(id);
    public int PartialLength(Guid id) => partials.TryGetValue(id, out var p) ? checked((int)p.Buffer.Length) : 0;

    public void CorruptPartialByteForTest(Guid id, int index)
    {
        var entry = partials[id];
        var bytes = entry.Buffer.ToArray();
        bytes[index] ^= 0xFF;
        entry.Buffer.SetLength(0);
        entry.Buffer.Write(bytes);
    }

    public Task<WifiOfferDecision> BeginOfferAsync(SyncOffer offer, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        SyncMessageCodec.ValidateOffer(offer, maxSize: SyncProtocol.MaxWifiItemBytes);
        if (completed.ContainsKey(offer.Id))
            return Task.FromResult(WifiOfferDecision.AlreadyCompleted);

        if (partials.TryGetValue(offer.Id, out var existing))
        {
            SyncProtocol.Require(existing.Offer == offer, SyncError.Format);
            var len = checked((int)existing.Buffer.Length);
            SyncProtocol.Require(len <= offer.Size, SyncError.Limit);
            return Task.FromResult(WifiOfferDecision.Resume(len));
        }

        partials[offer.Id] = new PartialEntry(offer);
        return Task.FromResult(WifiOfferDecision.Resume(0));
    }

    public Task<int> AppendChunkAsync(Guid id, int offset, ReadOnlyMemory<byte> data, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!partials.TryGetValue(id, out var entry))
            throw new SyncProtocolException(SyncError.State);
        var current = checked((int)entry.Buffer.Length);
        SyncProtocol.Require(offset == current && data.Length <= entry.Offer.Size - current, SyncError.Format);
        entry.Buffer.Write(data.Span);
        return Task.FromResult(checked((int)entry.Buffer.Length));
    }

    public Task VerifyAndCompleteAsync(SyncOffer offer, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!partials.TryGetValue(offer.Id, out var entry) || entry.Offer != offer)
            throw new SyncProtocolException(SyncError.State);

        var bytes = entry.Buffer.ToArray();
        var hash = Convert.ToHexStringLower(SHA256.HashData(bytes));
        if (bytes.Length != offer.Size || !string.Equals(hash, offer.Sha256, StringComparison.Ordinal))
        {
            partials.Remove(offer.Id);
            throw new SyncProtocolException(SyncError.Authentication);
        }

        partials.Remove(offer.Id);
        completed[offer.Id] = (offer, bytes);
        return Task.CompletedTask;
    }

    public Task DiscardPartialAsync(Guid id, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        partials.Remove(id);
        return Task.CompletedTask;
    }
}
