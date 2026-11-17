using System.Globalization;
using ClipboardPlus.Windows.Core;
using Xunit;

namespace ClipboardPlus.Windows.Tests;

public sealed class SyncStatusTextTests
{
    private static readonly DateTimeOffset Earlier = new(2026, 11, 18, 0, 30, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset Later = new(2026, 11, 18, 3, 5, 0, TimeSpan.Zero);

    private static string Local(DateTimeOffset at) => at.ToLocalTime().ToString("MM/dd HH:mm", CultureInfo.InvariantCulture);

    [Fact]
    public void NoDevicesSaysSoAndOffersFirstPairing()
    {
        var state = new SyncStatus(0, 0, null, null, Devices: []);
        Assert.Equal([SyncStatusText.NoDevices], SyncStatusText.Devices(state));
        Assert.Null(SyncStatusText.Connected(state));
        Assert.Equal("iPhone・iPadと組にする", SyncStatusText.PairingTitle(state));
        Assert.Empty(SyncStatusText.Transfers(state));
    }

    [Fact]
    public void DevicesListPhonesFirstNumberSameKindsAndShowPendingOnlyWhenWaiting()
    {
        var phone = new DeviceStatus(Guid.NewGuid(), "phone", true, Later, 0);
        var oldPad = new DeviceStatus(Guid.NewGuid(), "pad", false, Earlier, 2);
        var newPad = new DeviceStatus(Guid.NewGuid(), "pad", false, Later, 0);
        var state = new SyncStatus(1, 2, null, null, Devices: [oldPad, phone, newPad]);

        Assert.Equal(
            [
                "iPhone　つながっています",
                $"iPad 1　最後につながった {Local(Later)}",
                $"iPad 2　最後につながった {Local(Earlier)}　送信待ち 2 件",
            ],
            SyncStatusText.Devices(state));
        Assert.Equal("iPhoneとつながっています", SyncStatusText.Connected(state));
        Assert.Equal("ほかのiPhone・iPadも組にする", SyncStatusText.PairingTitle(state));
    }

    [Fact]
    public void ConnectedNamesEachKindOnce()
    {
        var state = new SyncStatus(3, 0, null, null, Devices:
        [
            new(Guid.NewGuid(), "pad", true, Later, 0),
            new(Guid.NewGuid(), "phone", true, Later, 0),
            new(Guid.NewGuid(), "pad", true, Later, 0),
        ]);
        Assert.Equal("iPhoneとiPadとつながっています", SyncStatusText.Connected(state));
        // Before the devices are known, the count alone still says something is connected.
        Assert.Equal("iPhone・iPadとつながっています", SyncStatusText.Connected(new SyncStatus(1, 0, null, null)));
    }

    [Fact]
    public void TransfersNameTheDeviceDirectionSizeAndPosition()
    {
        var pad = new DeviceStatus(Guid.NewGuid(), "pad", true, Later, 4);
        var state = new SyncStatus(1, 4, null, null, Devices: [pad], Transfers:
        [
            new(pad.Id, "send", Guid.NewGuid(), 2, 5, 1_468_006, 3_774_873),
            new(Guid.NewGuid(), "receive", Guid.NewGuid(), 1, 1, 512, 512),
        ]);
        Assert.Equal(
            ["iPadへ送っています　1.4 MB / 3.6 MB（2/5件目）", "iPhone・iPadから受け取っています　512 B / 512 B"],
            SyncStatusText.Transfers(state));
    }

    [Theory]
    [InlineData(0, "0 B")]
    [InlineData(1023, "1023 B")]
    [InlineData(1536, "1.5 KB")]
    [InlineData(10_485_760, "10 MB")]
    public void BytesUseBinaryUnitsAndAPeriodInAnyCulture(long bytes, string expected)
    {
        var culture = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = new CultureInfo("de-DE");
            Assert.Equal(expected, SyncStatusText.Bytes(bytes));
        }
        finally { CultureInfo.CurrentCulture = culture; }
    }
}
