using System.Globalization;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using ClipboardPlus.Windows.Core;
using Xunit;

namespace ClipboardPlus.Windows.Tests;

public sealed class WifiProbeTests
{
    [Fact]
    public void QrPayloadRoundTripsAndDistinguishesPrefix()
    {
        var payload = new WifiProbeQrPayload(
            Ssid: "DIRECT-cp-ABCD1234",
            Passphrase: "TestPassword1234",
            Ip: "192.168.137.1",
            Port: 54321,
            Token: "token_value_1234567890");

        var qr = payload.ToQrString();
        Assert.StartsWith(WifiProbeQrPayload.Prefix, qr, StringComparison.Ordinal);

        var parsed = WifiProbeQrPayload.Parse(qr);
        Assert.Equal(payload, parsed);
    }

    [Fact]
    public void QrParserRejectsPairingQrAndInvalidInputs()
    {
        var pairingEx = Assert.Throws<FormatException>(() =>
            WifiProbeQrPayload.Parse("clipboardplus-pair:1:abc:def:PC"));
        Assert.Contains("組にする用", pairingEx.Message);

        Assert.Throws<FormatException>(() => WifiProbeQrPayload.Parse(""));
        Assert.Throws<FormatException>(() => WifiProbeQrPayload.Parse("https://example.com"));
        Assert.Throws<FormatException>(() => WifiProbeQrPayload.Parse(WifiProbeQrPayload.Prefix + "{not-json"));

        // Invalid passphrase (<8 chars)
        Assert.Throws<FormatException>(() => WifiProbeQrPayload.Parse(
            WifiProbeQrPayload.Prefix + """{"ssid":"DIRECT-cp-1","passphrase":"short","ip":"192.168.137.1","port":5000,"token":"token_value_12345678"}"""));

        // Loopback / zero / leading-zero IPv4 rejected
        Assert.Throws<FormatException>(() => WifiProbeQrPayload.Parse(
            WifiProbeQrPayload.Prefix + """{"ssid":"DIRECT-cp-1","passphrase":"TestPassword1234","ip":"127.0.0.1","port":5000,"token":"token_value_12345678"}"""));
        Assert.Throws<FormatException>(() => WifiProbeQrPayload.Parse(
            WifiProbeQrPayload.Prefix + """{"ssid":"DIRECT-cp-1","passphrase":"TestPassword1234","ip":"0.0.0.0","port":5000,"token":"token_value_12345678"}"""));
        Assert.Throws<FormatException>(() => WifiProbeQrPayload.Parse(
            WifiProbeQrPayload.Prefix + """{"ssid":"DIRECT-cp-1","passphrase":"TestPassword1234","ip":"192.168.01.1","port":5000,"token":"token_value_12345678"}"""));

        // Port out of range
        Assert.Throws<FormatException>(() => WifiProbeQrPayload.Parse(
            WifiProbeQrPayload.Prefix + """{"ssid":"DIRECT-cp-1","passphrase":"TestPassword1234","ip":"192.168.137.1","port":70000,"token":"token_value_12345678"}"""));
    }

    [Fact]
    public void RandomCredentialsGenerateValidDistinctValues()
    {
        var first = WifiProbeCredentials.CreateRandom();
        var second = WifiProbeCredentials.CreateRandom();

        Assert.StartsWith("DIRECT-cp-", first.Ssid, StringComparison.Ordinal);
        Assert.NotEqual(first.Ssid, second.Ssid);
        Assert.NotEqual(first.Passphrase, second.Passphrase);
        Assert.NotEqual(first.Token, second.Token);

        var qr = new WifiProbeQrPayload(first.Ssid, first.Passphrase, "192.168.137.1", 51234, first.Token).ToQrString();
        Assert.Equal(first.Ssid, WifiProbeQrPayload.Parse(qr).Ssid);
    }

    [Fact]
    public void VirtualAdapterSelectorIgnoresRegularInterfacesAndRespectsFallbackFlags()
    {
        var adapters = new List<NetworkAdapterSnapshot>
        {
            new("Intel(R) Wi-Fi 6 AX200", "Wi-Fi", OperationalStatus.Up, NetworkInterfaceType.Wireless80211,
                [IPAddress.Parse("192.168.1.50")]),
            new("Microsoft Wi-Fi Direct Virtual Adapter #2", "ローカル エリア接続* 10", OperationalStatus.Up, NetworkInterfaceType.Wireless80211,
                [IPAddress.Parse("169.254.10.20")]),
        };

        Assert.Null(WifiProbeIpSelector.SelectIp(adapters, allowApipa: false, allowNonUp: false));
        Assert.Equal(IPAddress.Parse("169.254.10.20"), WifiProbeIpSelector.SelectIp(adapters, allowApipa: true, allowNonUp: false));

        var withIcs = new List<NetworkAdapterSnapshot>(adapters)
        {
            new("Microsoft Wi-Fi Direct Virtual Adapter #3", "ローカル エリア接続* 11", OperationalStatus.Up, NetworkInterfaceType.Wireless80211,
                [IPAddress.Parse("192.168.137.1")]),
        };
        Assert.Equal(IPAddress.Parse("192.168.137.1"), WifiProbeIpSelector.SelectIp(withIcs, allowApipa: true, allowNonUp: false));

        var downOnly = new List<NetworkAdapterSnapshot>
        {
            new("Microsoft Wi-Fi Direct Virtual Adapter", "ローカル エリア接続* 9", OperationalStatus.Down, NetworkInterfaceType.Wireless80211,
                [IPAddress.Parse("192.168.137.1")]),
        };
        Assert.Null(WifiProbeIpSelector.SelectIp(downOnly, allowApipa: true, allowNonUp: false));
        Assert.Equal(IPAddress.Parse("192.168.137.1"), WifiProbeIpSelector.SelectIp(downOnly, allowApipa: true, allowNonUp: true));

        Assert.Equal("ics_192_168_137", WifiProbeIpSelector.ClassifySubnet(IPAddress.Parse("192.168.137.1")));
        Assert.Equal("apipa_169_254", WifiProbeIpSelector.ClassifySubnet(IPAddress.Parse("169.254.5.6")));
    }

    [Fact]
    public void SpeedAndTimelineFormattingUseInvariantDecimalsAndIncludeAllStages()
    {
        var culture = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = new CultureInfo("de-DE");
            var speed = WifiProbeText.SpeedMBPerSecond(10L * 1024 * 1024, TimeSpan.FromSeconds(2));
            Assert.Equal(5.0, speed);
            Assert.Equal("5.00 MB/秒", WifiProbeText.FormatSpeed(speed));
            Assert.Null(WifiProbeText.SpeedMBPerSecond(0, TimeSpan.FromSeconds(1)));
            Assert.Null(WifiProbeText.SpeedMBPerSecond(1024, TimeSpan.Zero));
            Assert.Equal("-", WifiProbeText.FormatSpeed(null));
        }
        finally
        {
            CultureInfo.CurrentCulture = culture;
        }

        var t0 = new DateTimeOffset(2026, 11, 18, 10, 0, 0, TimeSpan.Zero);
        var timeline = WifiProbeText.FormatTimeline(new WifiProbeSnapshot(
            IsRunning: true,
            Mode: WifiProbeMode.WifiDirectLegacy,
            StatusMessage: "完了",
            ErrorMessage: null,
            QrPayload: null,
            ApStartingAt: t0,
            ApReadyAt: t0.AddSeconds(1.25),
            ApStartDuration: TimeSpan.FromSeconds(1.25),
            ConnectedAt: t0.AddSeconds(5),
            PayloadBytes: 2L * 1024 * 1024,
            ReceivedAt: t0.AddSeconds(5.2),
            UploadDuration: TimeSpan.FromSeconds(0.2),
            SentAt: t0.AddSeconds(5.4),
            DownloadDuration: TimeSpan.FromSeconds(0.2),
            CompletedRuns: 1));

        Assert.Contains("Wi-Fi Direct（レガシー）", timeline);
        Assert.Contains("Wi-Fi作り始め:", timeline);
        Assert.Contains("Wi-Fi作れた:", timeline);
        Assert.Contains("つながった:", timeline);
        Assert.Contains("受け取り終えた:", timeline);
        Assert.Contains("送り終えた:", timeline);
        Assert.Contains("10.00 MB/秒", timeline);
    }

    [Fact]
    public async Task EchoProtocolVerifiesTokenAndEchoesRandomPayload()
    {
        using var server = new TcpListener(IPAddress.Loopback, 0);
        server.Start(1);
        var port = ((IPEndPoint)server.LocalEndpoint).Port;
        const string token = "test_token_1234567890";
        const int payloadBytes = 256 * 1024;

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));

        // 1. Valid transfer
        var acceptTask = server.AcceptTcpClientAsync(cts.Token).AsTask();
        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, port, cts.Token);
        using var serverClient = await acceptTask;
        await using var clientStream = client.GetStream();
        await using var serverStream = serverClient.GetStream();

        var serverTask = WifiProbeWire.RunEchoServerSessionAsync(serverStream, token, cancellationToken: cts.Token);

        var header = WifiProbeWire.EncodeHeader(token, payloadBytes);
        await clientStream.WriteAsync(header, cts.Token);
        var authAck = new byte[1];
        await WifiProbeWire.ReadExactAsync(clientStream, authAck, cts.Token);
        Assert.Equal(WifiProbeWire.AckOk, authAck[0]);

        var outgoing = new byte[payloadBytes];
        Random.Shared.NextBytes(outgoing);
        await clientStream.WriteAsync(outgoing, cts.Token);
        await clientStream.FlushAsync(cts.Token);

        var uploadAck = new byte[1];
        await WifiProbeWire.ReadExactAsync(clientStream, uploadAck, cts.Token);
        Assert.Equal(WifiProbeWire.AckOk, uploadAck[0]);

        var echoed = new byte[payloadBytes];
        await WifiProbeWire.ReadExactAsync(clientStream, echoed, cts.Token);
        await clientStream.WriteAsync(new[] { WifiProbeWire.AckOk }, cts.Token);
        await clientStream.FlushAsync(cts.Token);

        var outcome = await serverTask;
        Assert.True(outcome.Accepted);
        Assert.Equal(payloadBytes, outcome.PayloadBytes);

        // 2. Wrong token rejected immediately
        var badAcceptTask = server.AcceptTcpClientAsync(cts.Token).AsTask();
        using var badClient = new TcpClient();
        await badClient.ConnectAsync(IPAddress.Loopback, port, cts.Token);
        using var badServerClient = await badAcceptTask;
        await using var badClientStream = badClient.GetStream();
        await using var badServerStream = badServerClient.GetStream();

        var badServerTask = WifiProbeWire.RunEchoServerSessionAsync(badServerStream, token, cancellationToken: cts.Token);
        await badClientStream.WriteAsync(WifiProbeWire.EncodeHeader("wrong_token_12345678", payloadBytes), cts.Token);
        var badAck = new byte[1];
        await WifiProbeWire.ReadExactAsync(badClientStream, badAck, cts.Token);
        Assert.Equal(WifiProbeWire.AckAuthFailed, badAck[0]);

        var badOutcome = await badServerTask;
        Assert.False(badOutcome.Accepted);
        Assert.Equal(WifiProbeWire.AckAuthFailed, badOutcome.StatusCode);
    }

    [Fact]
    public void SentLogFormattingIncludesTimingBreakdownAndInvariantDecimals()
    {
        var culture = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = new CultureInfo("de-DE");
            var metrics = new WifiProbeSentMetrics(
                PayloadBytes: 10L * 1024 * 1024,
                TotalElapsed: TimeSpan.FromMilliseconds(1250),
                WriteElapsed: TimeSpan.FromMilliseconds(1100),
                AckWaitElapsed: TimeSpan.FromMilliseconds(150),
                AckTimedOut: false);

            var line = WifiProbeText.FormatSentLog(metrics);
            Assert.Equal(
                "wifi probe sent bytes=10485760 elapsedMs=1250 writeMs=1100 ackWaitMs=150 ackTimedOut=false speedMBps=8.00",
                line);

            var timedOutLine = WifiProbeText.FormatSentLog(metrics with { AckTimedOut = true });
            Assert.Contains("ackTimedOut=true", timedOutLine, StringComparison.Ordinal);
        }
        finally
        {
            CultureInfo.CurrentCulture = culture;
        }
    }

    [Fact]
    public async Task EchoProtocolWrites256KiBChunksAndTracksAckWaitAndTimeout()
    {
        Assert.Equal(256 * 1024, WifiProbeWire.SendChunkBytes);

        using var server = new TcpListener(IPAddress.Loopback, 0);
        server.Start(1);
        var port = ((IPEndPoint)server.LocalEndpoint).Port;
        const string token = "test_token_1234567890";
        const int payloadBytes = 600 * 1024;

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));

        // 1. Verify 256 KiB write unit, reused dummy buffer, and AckTimedOut = false
        var acceptTask = server.AcceptTcpClientAsync(cts.Token).AsTask();
        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, port, cts.Token);
        using var serverClient = await acceptTask;
        await using var clientStream = client.GetStream();
        await using var rawServerStream = serverClient.GetStream();
        await using var recordingStream = new RecordingWriteStream(rawServerStream);

        WifiProbeSentMetrics? sentMetrics = null;
        var serverTask = WifiProbeWire.RunEchoServerSessionAsync(
            recordingStream,
            token,
            onSent: metrics => sentMetrics = metrics,
            ackTimeout: TimeSpan.FromSeconds(2),
            cancellationToken: cts.Token);

        await clientStream.WriteAsync(WifiProbeWire.EncodeHeader(token, payloadBytes), cts.Token);
        var ack = new byte[1];
        await WifiProbeWire.ReadExactAsync(clientStream, ack, cts.Token);
        Assert.Equal(WifiProbeWire.AckOk, ack[0]);

        var outgoing = new byte[payloadBytes];
        Random.Shared.NextBytes(outgoing);
        await clientStream.WriteAsync(outgoing, cts.Token);
        await clientStream.FlushAsync(cts.Token);

        await WifiProbeWire.ReadExactAsync(clientStream, ack, cts.Token);
        Assert.Equal(WifiProbeWire.AckOk, ack[0]);

        var echoed = new byte[payloadBytes];
        await WifiProbeWire.ReadExactAsync(clientStream, echoed, cts.Token);
        await clientStream.WriteAsync(new[] { WifiProbeWire.AckOk }, cts.Token);
        await clientStream.FlushAsync(cts.Token);

        var outcome = await serverTask;
        Assert.True(outcome.Accepted);
        Assert.False(outcome.AckTimedOut);
        Assert.NotNull(sentMetrics);
        Assert.False(sentMetrics!.AckTimedOut);
        Assert.Equal(payloadBytes, sentMetrics.PayloadBytes);

        // First two 1-byte writes are auth ack and upload ack; the remaining writes are the echoed payload.
        Assert.Equal([1, 1, 262_144, 262_144, 90_112], recordingStream.WriteSizes);
        Assert.True(echoed.AsSpan(0, 262_144).IndexOfAnyExcept((byte)0) >= 0);
        Assert.True(echoed.AsSpan(0, 262_144).SequenceEqual(echoed.AsSpan(262_144, 262_144)));
        Assert.True(echoed.AsSpan(0, 90_112).SequenceEqual(echoed.AsSpan(524_288, 90_112)));

        // 2. Verify AckTimedOut = true when client does not send final 1-byte ack
        var timeoutAcceptTask = server.AcceptTcpClientAsync(cts.Token).AsTask();
        using var silentClient = new TcpClient();
        await silentClient.ConnectAsync(IPAddress.Loopback, port, cts.Token);
        using var timeoutServerClient = await timeoutAcceptTask;
        await using var silentClientStream = silentClient.GetStream();
        await using var timeoutServerStream = timeoutServerClient.GetStream();

        WifiProbeSentMetrics? timeoutMetrics = null;
        var timeoutServerTask = WifiProbeWire.RunEchoServerSessionAsync(
            timeoutServerStream,
            token,
            onSent: metrics => timeoutMetrics = metrics,
            ackTimeout: TimeSpan.FromMilliseconds(50),
            cancellationToken: cts.Token);

        await silentClientStream.WriteAsync(WifiProbeWire.EncodeHeader(token, 1024), cts.Token);
        await WifiProbeWire.ReadExactAsync(silentClientStream, ack, cts.Token);
        await silentClientStream.WriteAsync(new byte[1024], cts.Token);
        await silentClientStream.FlushAsync(cts.Token);
        await WifiProbeWire.ReadExactAsync(silentClientStream, ack, cts.Token);
        await WifiProbeWire.ReadExactAsync(silentClientStream, new byte[1024], cts.Token);

        var timeoutOutcome = await timeoutServerTask;
        Assert.True(timeoutOutcome.Accepted);
        Assert.True(timeoutOutcome.AckTimedOut);
        Assert.NotNull(timeoutMetrics);
        Assert.True(timeoutMetrics!.AckTimedOut);
        Assert.True(timeoutOutcome.AckWaitElapsed >= TimeSpan.FromMilliseconds(25));
    }

    private sealed class RecordingWriteStream(Stream inner) : Stream
    {
        public List<int> WriteSizes { get; } = [];

        public override bool CanRead => inner.CanRead;
        public override bool CanSeek => inner.CanSeek;
        public override bool CanWrite => inner.CanWrite;
        public override long Length => inner.Length;
        public override long Position
        {
            get => inner.Position;
            set => inner.Position = value;
        }

        public override void Flush() => inner.Flush();
        public override Task FlushAsync(CancellationToken cancellationToken) => inner.FlushAsync(cancellationToken);
        public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            inner.ReadAsync(buffer, offset, count, cancellationToken);
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) =>
            inner.ReadAsync(buffer, cancellationToken);
        public override long Seek(long offset, SeekOrigin origin) => inner.Seek(offset, origin);
        public override void SetLength(long value) => inner.SetLength(value);
        public override void Write(byte[] buffer, int offset, int count)
        {
            WriteSizes.Add(count);
            inner.Write(buffer, offset, count);
        }

        public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
        {
            WriteSizes.Add(count);
            return inner.WriteAsync(buffer, offset, count, cancellationToken);
        }

        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
        {
            WriteSizes.Add(buffer.Length);
            return inner.WriteAsync(buffer, cancellationToken);
        }
    }
}
