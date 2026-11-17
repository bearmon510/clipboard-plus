using System.Globalization;

namespace ClipboardPlus.Windows.Core;

/// <summary>Wording for the main window, kept apart from WPF so it can be tested.</summary>
public static class SyncStatusText
{
    public const string NoDevices = "まだ組んでいるiPhone・iPadはありません";

    public static string DeviceName(string kind) => kind == "phone" ? "iPhone" : "iPad";

    /// <summary>"iPhoneとつながっています", or null when nothing is connected.</summary>
    public static string? Connected(SyncStatus state)
    {
        if (state.Connected == 0) return null;
        var kinds = (state.Devices ?? []).Where(d => d.Connected).Select(d => d.Kind).Distinct().ToList();
        if (kinds.Count == 0) return "iPhone・iPadとつながっています";
        return string.Join("と", kinds.OrderBy(KindOrder).Select(DeviceName)) + "とつながっています";
    }

    /// <summary>One line per paired device: iPhones first, then iPads, the most recent first.</summary>
    public static IReadOnlyList<string> Devices(SyncStatus state)
    {
        var devices = state.Devices ?? [];
        if (devices.Count == 0) return [NoDevices];
        // Several devices of the same kind are numbered so they can be told apart.
        var perKind = devices.GroupBy(d => d.Kind).ToDictionary(g => g.Key, g => g.Count());
        var numbered = new Dictionary<string, int>();
        var lines = new List<string>();
        foreach (var device in devices.OrderBy(d => KindOrder(d.Kind)).ThenByDescending(d => d.LastConnected))
        {
            var name = DeviceName(device.Kind);
            if (perKind[device.Kind] > 1)
            {
                numbered[device.Kind] = numbered.GetValueOrDefault(device.Kind) + 1;
                name += $" {numbered[device.Kind]}";
            }
            var link = device.Connected
                ? "つながっています"
                : "最後につながった " + device.LastConnected.ToLocalTime().ToString("MM/dd HH:mm", CultureInfo.InvariantCulture);
            var pending = device.Pending > 0 ? $"　送信待ち {device.Pending} 件" : "";
            lines.Add($"{name}　{link}{pending}");
        }
        return lines;
    }

    /// <summary>One line per transfer in progress, or none.</summary>
    public static IReadOnlyList<string> Transfers(SyncStatus state)
    {
        var lines = new List<string>();
        foreach (var transfer in state.Transfers ?? [])
        {
            var device = state.Devices?.FirstOrDefault(d => d.Id == transfer.DeviceId);
            var name = device is null ? "iPhone・iPad" : DeviceName(device.Kind);
            var verb = transfer.Direction == "send" ? $"{name}へ送っています" : $"{name}から受け取っています";
            var count = transfer.ItemCount > 1 ? $"（{transfer.ItemNumber}/{transfer.ItemCount}件目）" : "";
            lines.Add($"{verb}　{Bytes(transfer.Bytes)} / {Bytes(transfer.TotalBytes)}{count}");
        }
        return lines;
    }

    public static string PairingTitle(SyncStatus state) =>
        (state.Devices?.Count ?? 0) == 0 ? "iPhone・iPadと組にする" : "ほかのiPhone・iPadも組にする";

    public static string Bytes(long bytes) => bytes switch
    {
        < 1024 => FormattableString.Invariant($"{bytes} B"),
        < 1024 * 1024 => FormattableString.Invariant($"{bytes / 1024.0:0.#} KB"),
        _ => FormattableString.Invariant($"{bytes / (1024.0 * 1024.0):0.#} MB"),
    };

    private static int KindOrder(string kind) => kind == "phone" ? 0 : 1;
}
