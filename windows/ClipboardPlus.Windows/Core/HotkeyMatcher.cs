namespace ClipboardPlus.Windows.Core;

public enum HotkeyAction
{
    Pass,
    Swallow,
    SwallowAndTrigger,
}

public readonly record struct HotkeyMatchResult(
    HotkeyAction Action,
    bool NeedsMenuMask = false,
    HotkeyChord? RecordedChord = null,
    bool RecordingCancelled = false);

/// <summary>Pure keyboard-event matcher and chord recorder for WH_KEYBOARD_LL.</summary>
public sealed class HotkeyMatcher
{
    private const int EscapeVirtualKey = 0x1B;

    private readonly object gate = new();
    private readonly Dictionary<int, HotkeyModifier> heldModifiers = [];
    private readonly Dictionary<int, HotkeyModifier> recordingModifiers = [];
    private readonly HashSet<int> swallowedKeys = [];
    private HotkeyChord? target;
    private bool recording;

    public HotkeyMatcher(HotkeyChord? target = null)
    {
        if (target is { } chord)
        {
            if (!chord.IsValid) throw new ArgumentException("Invalid hotkey chord.", nameof(target));
            this.target = chord;
        }
    }

    public HotkeyChord? Target
    {
        get { lock (gate) return target; }
        set
        {
            if (value is { } chord && !chord.IsValid)
                throw new ArgumentException("Invalid hotkey chord.", nameof(value));
            lock (gate) target = value;
        }
    }

    public bool IsRecording
    {
        get { lock (gate) return recording; }
    }

    public void StartRecording()
    {
        lock (gate)
        {
            recording = true;
            recordingModifiers.Clear();
        }
    }

    public void CancelRecording()
    {
        lock (gate)
        {
            recording = false;
            recordingModifiers.Clear();
        }
    }

    public void Reset()
    {
        lock (gate)
        {
            heldModifiers.Clear();
            recordingModifiers.Clear();
            swallowedKeys.Clear();
            recording = false;
        }
    }

    /// <summary>Drops tracked keys whose key-up was missed (e.g., on lock screen or UAC).</summary>
    public void PruneReleasedKeys(Func<int, bool> isKeyDown)
    {
        ArgumentNullException.ThrowIfNull(isKeyDown);
        lock (gate)
        {
            PruneDictionary(heldModifiers, isKeyDown);
            PruneDictionary(recordingModifiers, isKeyDown);
            swallowedKeys.RemoveWhere(vk => !isKeyDown(vk));
        }
    }

    public HotkeyMatchResult Process(int virtualKey, bool isKeyDown, bool isInjected)
    {
        if (isInjected)
            return new HotkeyMatchResult(HotkeyAction.Pass);

        lock (gate)
        {
            return recording
                ? ProcessRecordingLocked(virtualKey, isKeyDown)
                : ProcessNormalLocked(virtualKey, isKeyDown);
        }
    }

    private HotkeyMatchResult ProcessRecordingLocked(int virtualKey, bool isKeyDown)
    {
        if (!isKeyDown)
        {
            recordingModifiers.Remove(virtualKey);
            swallowedKeys.Remove(virtualKey);
            heldModifiers.Remove(virtualKey);
            return new HotkeyMatchResult(HotkeyAction.Swallow);
        }

        swallowedKeys.Add(virtualKey);

        if (HotkeyChord.TryGetModifier(virtualKey, out var modifier))
        {
            recordingModifiers[virtualKey] = modifier;
            return new HotkeyMatchResult(HotkeyAction.Swallow);
        }

        HotkeyModifier? singleModifier = null;
        var multipleModifiers = false;
        foreach (var mod in recordingModifiers.Values)
        {
            if (singleModifier is null) singleModifier = mod;
            else if (singleModifier.Value != mod) { multipleModifiers = true; break; }
        }

        if (singleModifier is null && virtualKey == EscapeVirtualKey)
        {
            recording = false;
            recordingModifiers.Clear();
            return new HotkeyMatchResult(HotkeyAction.Swallow, RecordingCancelled: true);
        }

        if (!multipleModifiers && singleModifier is { } chosen && HotkeyChord.IsValidTriggerKey(virtualKey))
        {
            recording = false;
            recordingModifiers.Clear();
            return new HotkeyMatchResult(HotkeyAction.Swallow, RecordedChord: new HotkeyChord(chosen, virtualKey));
        }

        return new HotkeyMatchResult(HotkeyAction.Swallow);
    }

    private HotkeyMatchResult ProcessNormalLocked(int virtualKey, bool isKeyDown)
    {
        if (!isKeyDown)
        {
            heldModifiers.Remove(virtualKey);
            return swallowedKeys.Remove(virtualKey)
                ? new HotkeyMatchResult(HotkeyAction.Swallow)
                : new HotkeyMatchResult(HotkeyAction.Pass);
        }

        if (HotkeyChord.TryGetModifier(virtualKey, out var modifier))
        {
            if (swallowedKeys.Contains(virtualKey))
                return new HotkeyMatchResult(HotkeyAction.Swallow);
            heldModifiers[virtualKey] = modifier;
            return new HotkeyMatchResult(HotkeyAction.Pass);
        }

        if (swallowedKeys.Contains(virtualKey))
            return new HotkeyMatchResult(HotkeyAction.Swallow);

        if (target is { } active &&
            virtualKey == active.VirtualKey &&
            HasOnlyModifier(active.Modifier))
        {
            swallowedKeys.Add(virtualKey);
            return new HotkeyMatchResult(HotkeyAction.SwallowAndTrigger, NeedsMenuMask: active.Modifier == HotkeyModifier.Win);
        }

        return new HotkeyMatchResult(HotkeyAction.Pass);
    }

    private bool HasOnlyModifier(HotkeyModifier required)
    {
        if (heldModifiers.Count == 0) return false;
        foreach (var mod in heldModifiers.Values)
        {
            if (mod != required) return false;
        }
        return true;
    }

    private static void PruneDictionary(Dictionary<int, HotkeyModifier> map, Func<int, bool> isKeyDown)
    {
        if (map.Count == 0) return;
        List<int>? stale = null;
        foreach (var vk in map.Keys)
        {
            if (!isKeyDown(vk)) (stale ??= []).Add(vk);
        }
        if (stale is not null)
        {
            foreach (var vk in stale) map.Remove(vk);
        }
    }
}
