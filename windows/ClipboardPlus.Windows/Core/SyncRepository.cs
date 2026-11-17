using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ClipboardPlus.Sync;

namespace ClipboardPlus.Windows.Core;

public sealed record ClipboardContent(string Kind, string? Text = null, string? Filename = null,
    byte[]? Data = null, string Type = "public.data");
public sealed record HistoryItem(Guid Id, string Kind, string? Text, string? Filename, string? Path,
    int Size, long At, string Source, string Hash, string Type)
{
    public SyncOffer Offer => new(Id, At, "pc", Kind, Size, Hash,
        Convert.ToBase64String(Encoding.UTF8.GetBytes(Filename ?? "")), Type);
}
public sealed record KnownDevice(Guid Id, string Kind, DateTimeOffset LastConnected);
public sealed record DeviceStatus(Guid Id, string Kind, bool Connected, DateTimeOffset LastConnected, int Pending);
public sealed record TransferProgress(Guid DeviceId, string Direction, Guid ItemId, int ItemNumber, int ItemCount, long Bytes, long TotalBytes);

/// <summary>Atomic metadata, separate immutable bodies. Call from the coordinator's serialized gate.</summary>
public sealed class SyncRepository
{
    public sealed record Recent(string Hash, Guid? Device, DateTimeOffset At);
    public sealed record Partial(Guid Device, SyncOffer Offer, DateTimeOffset Created);
    public sealed class State
    {
        public Guid PairId { get; set; }
        public List<KnownDevice> Devices { get; set; } = [];
        public Dictionary<Guid, List<HistoryItem>> Pending { get; set; } = [];
        public List<HistoryItem> History { get; set; } = [];
        public List<string> Seen { get; set; } = [];
        public List<Recent> Recent { get; set; } = [];
        public List<Partial> Partials { get; set; } = [];
    }
    private readonly string root;
    private State state;
    private byte[] durable;
    public SyncRepository(string root, Guid pairId)
    {
        this.root = System.IO.Path.GetFullPath(root);
        Directory.CreateDirectory(root);
        var file = System.IO.Path.Combine(root, "sync-state.json");
        state = File.Exists(file) ? JsonSerializer.Deserialize<State>(File.ReadAllBytes(file)) ?? throw new IOException("State invalid") : new();
        durable = JsonSerializer.SerializeToUtf8Bytes(state);
        if (state.PairId != pairId)
        {
            state.PairId = pairId; state.Devices.Clear(); state.Pending.Clear(); state.Seen.Clear(); state.Recent.Clear(); state.Partials.Clear();
        }
        Prune(DateTimeOffset.UtcNow);
    }
    public IReadOnlyList<KnownDevice> Devices => state.Devices.ToArray();
    public IReadOnlyList<HistoryItem> List(string? search = null) => state.History
        .Where(i => string.IsNullOrEmpty(search) || (i.Text ?? i.Filename ?? "").Contains(search, StringComparison.OrdinalIgnoreCase))
        .OrderByDescending(i => i.At).ToArray();
    public List<HistoryItem> Pending(Guid id) => state.Pending.GetValueOrDefault(id) ?? [];
    public int PendingCount => state.Pending.Values.Sum(q => q.Count);
    public void Register(Guid id, string? kind, DateTimeOffset now)
    {
        var old = state.Devices.FirstOrDefault(d => d.Id == id);
        state.Devices.RemoveAll(d => d.Id == id);
        state.Devices.Add(new(id, kind ?? old?.Kind ?? "pad", now));
        state.Pending.TryAdd(id, []); Save();
    }
    public void Enqueue(HistoryItem item, DateTimeOffset now)
    {
        foreach (var queue in state.Pending.Values) queue.Add(item);
        Remember(item, null, now); Prune(now);
    }
    public void AddAndEnqueue(HistoryItem item, DateTimeOffset now)
    {
        Upsert(item);
        foreach (var queue in state.Pending.Values) queue.Add(item);
        Remember(item, null, now); Prune(now);
    }
    public void Ack(Guid device, IReadOnlySet<Guid> ids)
    { Pending(device).RemoveAll(i => ids.Contains(i.Id)); Save(); CleanupBodies(); }
    public bool Seen(Guid device, Guid id) => state.Seen.Contains($"{device:N}/{id:N}");
    public bool Duplicate(HistoryItem item, Guid device, DateTimeOffset now) => state.Recent.Any(r =>
        r.Hash == ContentKey(item) && r.Device != device && now - r.At <= SyncProtocol.DuplicateWindow);
    private void RecordSeen(Guid device, Guid id)
    {
        var key = $"{device:N}/{id:N}";
        state.Seen.Remove(key); state.Seen.Add(key);
        var prefix = $"{device:N}/";
        var expired = state.Seen.Where(k => k.StartsWith(prefix, StringComparison.Ordinal)).Reverse().Skip(500).ToHashSet();
        state.Seen.RemoveAll(expired.Contains);
    }
    public void CommitReceived(HistoryItem item, Guid device, DateTimeOffset now, bool duplicate)
    {
        RecordSeen(device, item.Id);
        if (!duplicate) { Upsert(item); Remember(item, device, now); }
        Save(); CleanupBodies();
    }
    public void CommitRejected(Guid device, Guid id)
    {
        RecordSeen(device, id);
        Save(); CleanupBodies();
    }
    private static string ContentKey(HistoryItem item) => item.Kind + ":" + item.Hash;
    private void Remember(HistoryItem item, Guid? device, DateTimeOffset now)
    {
        state.Recent.RemoveAll(r => now - r.At > SyncProtocol.DuplicateWindow || (r.Hash == ContentKey(item) && r.Device == device));
        state.Recent.Add(new(ContentKey(item), device, now));
    }
    public void AddHistory(HistoryItem item) { Upsert(item); Save(); CleanupBodies(); }
    private void Upsert(HistoryItem item)
    {
        var old = state.History.FirstOrDefault(i => ContentKey(i) == ContentKey(item));
        if (old is not null && old.At > item.At) return;
        state.History.RemoveAll(i => ContentKey(i) == ContentKey(item));
        state.History.Insert(0, old is null ? item : item with { Id = old.Id });
        state.History = state.History.OrderByDescending(i => i.At).Take(SyncProtocol.MaxHistory).ToList();
    }
    public void Delete(Guid id)
    {
        var item = state.History.FirstOrDefault(i => i.Id == id);
        state.History.RemoveAll(i => i.Id == id);
        if (item is not null) foreach (var queue in state.Pending.Values) queue.RemoveAll(i => ContentKey(i) == ContentKey(item));
        Save(); CleanupBodies();
    }
    public void ClearHistory()
    { state.History.Clear(); foreach (var queue in state.Pending.Values) queue.Clear(); Save(); CleanupBodies(); }
    public HistoryItem Create(ClipboardContent content, long at, string source, Guid? id = null)
    {
        var bytes = content.Kind == "text" ? Encoding.UTF8.GetBytes(content.Text ?? "") : content.Data ?? throw new IOException("Body missing");
        if (bytes.Length > SyncProtocol.MaxItemBytes) throw new SyncProtocolException(SyncError.Limit);
        var hash = Convert.ToHexStringLower(SHA256.HashData(bytes));
        string? path = null;
        if (content.Kind != "text")
        {
            path = System.IO.Path.Combine(root, "bodies", hash);
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
            if (!File.Exists(path) || new FileInfo(path).Length != bytes.Length) AtomicWrite(path, bytes);
        }
        return new(id ?? Guid.NewGuid(), content.Kind, content.Text, content.Filename, path, bytes.Length, at, source, hash, content.Type);
    }
    private static bool ValidBody(HistoryItem item) =>
        item.Kind == "text" || (!string.IsNullOrEmpty(item.Path) && File.Exists(item.Path) && new FileInfo(item.Path).Length == item.Size);
    private bool ValidPartial(Partial partial)
    {
        var path = PartialPath(partial.Device, partial.Offer.Id);
        return File.Exists(path) && new FileInfo(path).Length <= partial.Offer.Size;
    }
    public void Prune(DateTimeOffset now)
    {
        var cutoff = now.Subtract(SyncProtocol.PendingLifetime).ToUnixTimeMilliseconds();
        foreach (var id in state.Pending.Keys.ToArray())
            state.Pending[id] = state.Pending[id].Where(i => i.At >= cutoff && ValidBody(i)).OrderBy(i => i.At).TakeLast(SyncProtocol.MaxPending).ToList();
        state.Partials.RemoveAll(p => now - p.Created > SyncProtocol.PendingLifetime || !ValidPartial(p));
        state.Recent.RemoveAll(p => now - p.At > SyncProtocol.DuplicateWindow);
        Save(); CleanupBodies();
    }
    public string PartialPath(Guid device, Guid id) => System.IO.Path.Combine(root, "partial", $"{device:N}-{id:N}.part");
    public int Begin(Guid device, SyncOffer offer, DateTimeOffset now)
    {
        SyncMessageCodec.ValidateOffer(offer);
        var previous = state.Partials.FirstOrDefault(p => p.Device == device && p.Offer.Id == offer.Id);
        if (previous is not null && previous.Offer != offer) throw new SyncProtocolException(SyncError.Format);
        if (previous is null)
        {
            var evicted = new List<string>();
            while (state.Partials.Count(p => p.Device == device) >= SyncProtocol.MaxPending)
            {
                var oldest = state.Partials.Where(p => p.Device == device).OrderBy(p => p.Created).First();
                state.Partials.Remove(oldest);
                evicted.Add(PartialPath(oldest.Device, oldest.Offer.Id));
            }
            var path = PartialPath(device, offer.Id); Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
            AtomicWrite(path, []); state.Partials.Add(new(device, offer, now));
            try { Save(); }
            catch { try { File.Delete(path); } catch { } throw; }
            foreach (var oldPath in evicted) File.Delete(oldPath);
        }
        var length = new FileInfo(PartialPath(device, offer.Id)).Length;
        if (length > offer.Size) throw new SyncProtocolException(SyncError.Limit);
        return (int)length;
    }
    public SyncOffer? Incoming(Guid device, Guid id) => state.Partials.FirstOrDefault(p => p.Device == device && p.Offer.Id == id)?.Offer;
    public int Append(Guid device, SyncChunk chunk)
    {
        var offer = Incoming(device, chunk.Id) ?? throw new SyncProtocolException(SyncError.State);
        using var file = new FileStream(PartialPath(device, chunk.Id), FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        if (chunk.Offset != file.Length || chunk.Data.Length > offer.Size - file.Length) throw new SyncProtocolException(SyncError.Format);
        file.Position = file.Length; file.Write(chunk.Data); file.Flush(true); return checked((int)file.Length);
    }
    public HistoryItem Complete(Guid device, SyncOffer offer, string source)
    {
        var path = PartialPath(device, offer.Id);
        bool valid;
        using (var file = File.OpenRead(path))
        {
            valid = file.Length == offer.Size && Convert.ToHexStringLower(SHA256.HashData(file)) == offer.Sha256;
        }
        if (!valid) { DiscardPartial(device, offer.Id); throw new SyncProtocolException(SyncError.Authentication); }
        var target = System.IO.Path.Combine(root, "bodies", offer.Sha256);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(target)!);
        if (!File.Exists(target) || new FileInfo(target).Length != offer.Size)
        {
            var temp = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                using (var src = File.OpenRead(path))
                using (var dst = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    src.CopyTo(dst);
                    dst.Flush(true);
                }
                File.Move(temp, target, true);
            }
            catch
            {
                try { File.Delete(temp); } catch { }
                throw;
            }
        }
        return new(offer.Id, offer.Kind, null, offer.Filename, target, offer.Size, offer.At, source, offer.Sha256, offer.Type);
    }
    public void MarkSent(HistoryItem item, DateTimeOffset now) { Remember(item, null, now); Save(); }
    public void DiscardPartial(Guid device, Guid id)
    {
        if (state.Partials.RemoveAll(p => p.Device == device && p.Offer.Id == id) > 0)
        {
            Save();
            CleanupBodies();
        }
        File.Delete(PartialPath(device, id));
    }
    public static string SafeFilename(string name)
    {
        var invalid = System.IO.Path.GetInvalidFileNameChars();
        var value = new string(name.Select(c =>
            invalid.Contains(c) || c is '/' or '\\' or ':' or '*' or '?' or '"' or '<' or '>' or '|' ||
            char.IsControl(c) || IsBidiControl(c) ? '_' : c).Take(120).ToArray()).TrimEnd(' ', '.');
        if (value.Length > 0 && char.IsHighSurrogate(value[^1])) value = value[..^1].TrimEnd(' ', '.');
        return string.IsNullOrWhiteSpace(value) ? "file" : value;
    }
    private static bool IsBidiControl(char c) =>
        c is '\u061C' or '\u200E' or '\u200F' or (>= '\u202A' and <= '\u202E') or (>= '\u2066' and <= '\u2069');
    private void Save()
    {
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(state);
            AtomicWrite(System.IO.Path.Combine(root, "sync-state.json"), bytes); durable = bytes;
        }
        catch { state = JsonSerializer.Deserialize<State>(durable)!; throw; }
    }
    private static void AtomicWrite(string path, byte[] bytes)
    {
        using (var file = new FileStream(path + ".tmp", FileMode.Create, FileAccess.Write, FileShare.None)) { file.Write(bytes); file.Flush(true); }
        File.Move(path + ".tmp", path, true);
    }
    private void CleanupBodies()
    {
        var keep = state.History.Concat(state.Pending.Values.SelectMany(q => q)).Select(i => i.Path).Where(p => p is not null).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var bodies = System.IO.Path.Combine(root, "bodies");
        if (Directory.Exists(bodies)) foreach (var path in Directory.EnumerateFiles(bodies)) if (!keep.Contains(path)) File.Delete(path);
        var partials = state.Partials.Select(p => PartialPath(p.Device, p.Offer.Id)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var folder = System.IO.Path.Combine(root, "partial");
        if (Directory.Exists(folder)) foreach (var path in Directory.EnumerateFiles(folder)) if (!partials.Contains(path)) File.Delete(path);
    }
}
