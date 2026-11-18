using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using ClipboardPlus.Windows.Core;
using ClipboardPlus.Windows.Infrastructure;
using Xunit;

namespace ClipboardPlus.Windows.Tests;

public sealed class AppSettingsTests : IDisposable
{
    private readonly string tempDir = Path.Combine(Path.GetTempPath(), "clipboardplus-settings-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { if (Directory.Exists(tempDir)) Directory.Delete(tempDir, recursive: true); }
        catch { }
    }

    [Fact]
    public void MissingFileUsesDefaultsWithoutLogging()
    {
        var logs = new List<string>();
        var settings = new AppSettings(tempDir, logs.Add);

        Assert.True(settings.HotkeyEnabled);
        Assert.Equal("Win+V", settings.Hotkey);
        Assert.Equal(HotkeyChord.Default, settings.ParsedHotkey);
        Assert.True(settings.PasteOnSelect);
        Assert.Empty(logs);
    }

    [Fact]
    public void SaveAndReloadRoundTripsAndLeavesNoTemporaryFiles()
    {
        var logs = new List<string>();
        var settings = new AppSettings(tempDir, logs.Add)
        {
            HotkeyEnabled = false,
            Hotkey = "Ctrl+NonConvert",
            PasteOnSelect = false,
        };
        settings.Save();

        var files = Directory.GetFiles(tempDir);
        Assert.Equal([Path.Combine(tempDir, "settings.json")], files);

        var reloaded = new AppSettings(tempDir, logs.Add);
        Assert.False(reloaded.HotkeyEnabled);
        Assert.Equal("Ctrl+NonConvert", reloaded.Hotkey);
        Assert.Equal(new HotkeyChord(HotkeyModifier.Ctrl, 0x1D), reloaded.ParsedHotkey);
        Assert.False(reloaded.PasteOnSelect);
        Assert.Empty(logs);
    }

    [Theory]
    [InlineData("{broken json")]
    [InlineData("")]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("{\"HotkeyEnabled\": \"yes\"}")]
    public void CorruptFileFallsBackToDefaultsAndLogsWithoutPath(string content)
    {
        Directory.CreateDirectory(tempDir);
        File.WriteAllText(Path.Combine(tempDir, "settings.json"), content, new UTF8Encoding(false));

        var logs = new List<string>();
        var settings = new AppSettings(tempDir, logs.Add);

        Assert.True(settings.HotkeyEnabled);
        Assert.Equal("Win+V", settings.Hotkey);
        Assert.True(settings.PasteOnSelect);
        Assert.NotEmpty(logs);
        Assert.All(logs, entry => Assert.DoesNotContain(tempDir, entry, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void InvalidHotkeyFallsBackToDefaultWhilePreservingValidFlagsAndLogsReason()
    {
        Directory.CreateDirectory(tempDir);
        File.WriteAllText(
            Path.Combine(tempDir, "settings.json"),
            "{\"HotkeyEnabled\": false, \"Hotkey\": \"Win+Shift\", \"PasteOnSelect\": false}",
            new UTF8Encoding(false));

        var logs = new List<string>();
        var settings = new AppSettings(tempDir, logs.Add);

        Assert.False(settings.HotkeyEnabled);
        Assert.False(settings.PasteOnSelect);
        Assert.Equal("Win+V", settings.Hotkey);
        Assert.Equal(HotkeyChord.Default, settings.ParsedHotkey);
        Assert.Equal(["settings invalid hotkey"], logs);
    }

    [Fact]
    public void Utf8BomInSettingsJsonIsAccepted()
    {
        Directory.CreateDirectory(tempDir);
        File.WriteAllText(
            Path.Combine(tempDir, "settings.json"),
            "{\"HotkeyEnabled\": false, \"Hotkey\": \"Alt+F1\", \"PasteOnSelect\": false}",
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));

        var logs = new List<string>();
        var settings = new AppSettings(tempDir, logs.Add);

        Assert.False(settings.HotkeyEnabled);
        Assert.Equal("Alt+F1", settings.Hotkey);
        Assert.False(settings.PasteOnSelect);
        Assert.Empty(logs);
    }

    [Fact]
    public void UnreadableLockedFileFallsBackToDefaultsAndLogsReason()
    {
        Directory.CreateDirectory(tempDir);
        var path = Path.Combine(tempDir, "settings.json");
        File.WriteAllText(path, "{\"HotkeyEnabled\": false}", Encoding.UTF8);

        var logs = new List<string>();
        using var exclusive = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        var settings = new AppSettings(tempDir, logs.Add);

        Assert.True(settings.HotkeyEnabled);
        Assert.Equal("Win+V", settings.Hotkey);
        Assert.True(settings.PasteOnSelect);
        Assert.NotEmpty(logs);
        Assert.All(logs, entry => Assert.DoesNotContain(tempDir, entry, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void NativeInputStructSizeMatchesWin32SendInput()
    {
        var expected = IntPtr.Size == 8 ? 40 : 28;
        Assert.Equal(expected, Marshal.SizeOf<NativeInput.INPUT>());
    }

    [Fact]
    public void HistoryWindowBoundsRoundTripThroughSettings()
    {
        var logs = new List<string>();
        var settings = new AppSettings(tempDir, logs.Add);
        Assert.Null(settings.HistoryWindow);

        settings.HistoryWindow = new WindowPlacement(-420, 180, 440, 560);
        settings.Save();

        var reloaded = new AppSettings(tempDir, logs.Add);
        Assert.Equal(new WindowPlacement(-420, 180, 440, 560), reloaded.HistoryWindow);
        Assert.Empty(logs);
    }

    [Fact]
    public void InvalidHistoryWindowBoundsFallBackToNullWhilePreservingOtherSettings()
    {
        Directory.CreateDirectory(tempDir);
        File.WriteAllText(
            Path.Combine(tempDir, "settings.json"),
            """
            {
              "HotkeyEnabled": false,
              "Hotkey": "Ctrl+NonConvert",
              "PasteOnSelect": false,
              "HistoryWindow": { "Left": 100, "Top": 200, "Width": -50, "Height": 400 }
            }
            """,
            new UTF8Encoding(false));

        var logs = new List<string>();
        var settings = new AppSettings(tempDir, logs.Add);

        Assert.False(settings.HotkeyEnabled);
        Assert.Equal("Ctrl+NonConvert", settings.Hotkey);
        Assert.False(settings.PasteOnSelect);
        Assert.Null(settings.HistoryWindow);
        Assert.Equal(["settings invalid history window"], logs);
    }

    [Fact]
    public void UndersizedHistoryWindowBoundsClampToMinimumOnLoad()
    {
        Directory.CreateDirectory(tempDir);
        File.WriteAllText(
            Path.Combine(tempDir, "settings.json"),
            """{"HistoryWindow": { "Left": 80, "Top": 90, "Width": 120, "Height": 150 }}""",
            new UTF8Encoding(false));

        var logs = new List<string>();
        var settings = new AppSettings(tempDir, logs.Add);

        Assert.Equal(
            new WindowPlacement(80, 90, HistoryWindowPlacement.MinWidth, HistoryWindowPlacement.MinHeight),
            settings.HistoryWindow);
        Assert.Empty(logs);
    }
}
