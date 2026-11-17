namespace ClipboardPlus.Windows.Core;

internal static class BleLimits
{
    public static int NotificationBytes(int maxPduSize) => Math.Clamp(maxPduSize - 3, 20, 512);
}

// Counts queued AND executing writes. Admission happens before retaining event args.
internal sealed class WriteAdmission(int globalLimit = 64, int peerLimit = 16)
{
    private readonly object gate = new();
    private readonly Dictionary<string, int> counts = [];
    private int total;

    public void Dispatch(System.Threading.Channels.ChannelWriter<Func<Task>> writer, string peer,
        Func<Task> process, Action reject, Action complete, bool accepting = true)
    {
        var lease = accepting ? TryEnter(peer) : null;
        if (lease is not null && writer.TryWrite(async () =>
        {
            try { await process(); }
            finally { try { complete(); } finally { lease.Dispose(); } }
        })) return;
        try { reject(); }
        finally { try { complete(); } finally { lease?.Dispose(); } }
    }

    public IDisposable? TryEnter(string peer)
    {
        lock (gate)
        {
            var count = counts.GetValueOrDefault(peer);
            if (total >= globalLimit || count >= peerLimit) return null;
            counts[peer] = count + 1; total++;
            return new Lease(this, peer);
        }
    }

    private sealed class Lease(WriteAdmission owner, string peer) : IDisposable
    {
        private int disposed;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            lock (owner.gate)
            {
                if (--owner.counts[peer] == 0) owner.counts.Remove(peer);
                owner.total--;
            }
        }
    }
}
