using System.Text.Json;
using System.Text.Json.Serialization;
using ClipboardPlus.Windows.Core;

namespace ClipboardPlus.Windows.Infrastructure;

/// <summary>Persists user settings atomically in settings.json with safe defaults.</summary>
internal sealed class AppSettings
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
    };

    private sealed class WindowBoundsData
    {
        public int? Left { get; set; }
        public int? Top { get; set; }
        public double? Width { get; set; }
        public double? Height { get; set; }
    }

    private sealed class SettingsData
    {
        public bool? HotkeyEnabled { get; set; }
        public string? Hotkey { get; set; }
        public bool? PasteOnSelect { get; set; }
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public WindowBoundsData? HistoryWindow { get; set; }
    }

    private readonly string directory;
    private readonly string filePath;
    private readonly Action<string>? log;
    private readonly object gate = new();

    public bool HotkeyEnabled { get; set; } = true;
    public string Hotkey { get; set; } = HotkeyChord.Default.ToString();
    public bool PasteOnSelect { get; set; } = true;
    public WindowPlacement? HistoryWindow { get; set; }

    public HotkeyChord ParsedHotkey => HotkeyChord.TryParse(Hotkey, out var chord) ? chord : HotkeyChord.Default;

    public AppSettings(string? directory = null, Action<string>? log = null, bool load = true)
    {
        this.directory = string.IsNullOrWhiteSpace(directory) ? LocalStore.Root : Path.GetFullPath(directory);
        filePath = Path.Combine(this.directory, "settings.json");
        this.log = log;
        if (load) Load();
    }

    public void Load()
    {
        lock (gate)
        {
            ApplyDefaults();
            if (!File.Exists(filePath)) return;

            try
            {
                var bytes = File.ReadAllBytes(filePath);
                ReadOnlySpan<byte> span = bytes;
                if (span is [0xEF, 0xBB, 0xBF, ..])
                    span = span[3..];
                var data = JsonSerializer.Deserialize<SettingsData>(span, JsonOptions);
                if (data is null)
                {
                    log?.Invoke("settings load failed reason=null");
                    return;
                }

                HotkeyEnabled = data.HotkeyEnabled ?? true;
                PasteOnSelect = data.PasteOnSelect ?? true;

                if (data.Hotkey is null)
                {
                    Hotkey = HotkeyChord.Default.ToString();
                }
                else if (HotkeyChord.TryParse(data.Hotkey, out var parsed))
                {
                    Hotkey = parsed.ToString();
                }
                else
                {
                    Hotkey = HotkeyChord.Default.ToString();
                    log?.Invoke("settings invalid hotkey");
                }

                if (data.HistoryWindow is { } bounds)
                {
                    if (HistoryWindowPlacement.TryNormalize(bounds.Left, bounds.Top, bounds.Width, bounds.Height, out var placement))
                        HistoryWindow = placement;
                    else
                    {
                        HistoryWindow = null;
                        log?.Invoke("settings invalid history window");
                    }
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or NotSupportedException)
            {
                ApplyDefaults();
                log?.Invoke($"settings load failed error={ex.GetType().Name}");
            }
        }
    }

    public void Save()
    {
        lock (gate)
        {
            var chord = ParsedHotkey;
            Hotkey = chord.ToString();

            WindowBoundsData? historyBounds = null;
            if (HistoryWindow is { } current &&
                HistoryWindowPlacement.TryNormalize(current.Left, current.Top, current.Width, current.Height, out var normalized))
            {
                HistoryWindow = normalized;
                historyBounds = new WindowBoundsData
                {
                    Left = normalized.Left,
                    Top = normalized.Top,
                    Width = normalized.Width,
                    Height = normalized.Height,
                };
            }
            else
            {
                HistoryWindow = null;
            }

            var data = new SettingsData
            {
                HotkeyEnabled = HotkeyEnabled,
                Hotkey = Hotkey,
                PasteOnSelect = PasteOnSelect,
                HistoryWindow = historyBounds,
            };

            Directory.CreateDirectory(directory);
            var bytes = JsonSerializer.SerializeToUtf8Bytes(data, JsonOptions);
            var tempPath = Path.Combine(directory, $"settings.{Guid.NewGuid():N}.tmp");
            try
            {
                using (var stream = new FileStream(tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    stream.Write(bytes);
                    stream.Flush(true);
                }
                File.Move(tempPath, filePath, overwrite: true);
            }
            catch
            {
                try { File.Delete(tempPath); } catch { }
                throw;
            }
        }
    }

    private void ApplyDefaults()
    {
        HotkeyEnabled = true;
        Hotkey = HotkeyChord.Default.ToString();
        PasteOnSelect = true;
        HistoryWindow = null;
    }
}
