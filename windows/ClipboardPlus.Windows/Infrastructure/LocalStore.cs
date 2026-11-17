using System.IO;
using System.Security.Cryptography;
using System.Text;
using ClipboardPlus.Sync;
using Microsoft.Win32;

namespace ClipboardPlus.Windows.Infrastructure;

internal static class LocalStore
{
    public static string Root => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "clipboardplus");
    public static string Logs => Path.Combine(Root, "logs");
    private static string PairFile => Path.Combine(Root, "pairing.dat");

    public static SyncPairing LoadOrCreate()
    {
        if (!File.Exists(PairFile)) return CreatePairing();
        var encrypted = File.ReadAllBytes(PairFile);
        var bytes = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
        try { return SyncPairing.Parse(Encoding.UTF8.GetString(bytes)); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    public static SyncPairing CreatePairing()
    {
        var pairing = SyncPairing.Create(Environment.MachineName);
        Directory.CreateDirectory(Root);
        var bytes = Encoding.UTF8.GetBytes(pairing.ToQrString());
        try
        {
            var encrypted = ProtectedData.Protect(bytes, null, DataProtectionScope.CurrentUser);
            var temp = PairFile + ".tmp";
            File.WriteAllBytes(temp, encrypted);
            File.Move(temp, PairFile, overwrite: true);
        }
        finally { CryptographicOperations.ZeroMemory(bytes); }
        return pairing;
    }

    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunName = "ClipboardPlusForWindows";
    public static bool StartupEnabled
    {
        get { using var key = Registry.CurrentUser.OpenSubKey(RunKey); return key?.GetValue(RunName) is string; }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue(RunName, $"\"{Environment.ProcessPath}\" --background");
            else key.DeleteValue(RunName, throwOnMissingValue: false);
        }
    }
}

internal sealed class AppLog
{
    private readonly object gate = new();
    public AppLog() { Directory.CreateDirectory(LocalStore.Logs); }

    public void Write(string entry)
    {
        lock (gate)
        {
            try
            {
                // Five rolling files of at most ~1 MiB, independent of event frequency.
                var file = Path.Combine(LocalStore.Logs, "sync.log");
                if (File.Exists(file) && new FileInfo(file).Length >= 1024 * 1024)
                {
                    File.Delete(file + ".4");
                    for (var i = 3; i >= 1; i--)
                        if (File.Exists(file + "." + i)) File.Move(file + "." + i, file + "." + (i + 1), true);
                    File.Move(file, file + ".1", true);
                }
                File.AppendAllText(file, $"{DateTimeOffset.Now:O} {entry}{Environment.NewLine}", Encoding.UTF8);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
