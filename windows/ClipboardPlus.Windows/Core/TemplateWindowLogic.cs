using ClipboardPlus.Sync;

namespace ClipboardPlus.Windows.Core;

public enum HistoryWindowTab
{
    History,
    Templates,
}

public enum TemplateSyncRunStatus
{
    Completed,
    NoConnectedDevices,
    PeerUpdateRequired,
    Disconnected,
    TimedOut,
    LimitExceeded,
    AlreadyInProgress,
    Stopped,
}

public sealed record TemplateSyncRunResult(
    TemplateSyncRunStatus Status,
    int TargetDevices = 0,
    int SucceededDevices = 0,
    int FailedDevices = 0,
    bool PcSaved = false,
    int PcAdded = 0,
    int PcUpdated = 0,
    int PcDeleted = 0,
    int RemoteChangesTotal = 0,
    int ConflictCopyCount = 0,
    long? ClockSkewSeconds = null)
{
    public static TemplateSyncRunResult NoConnectedDevicesResult() => new(TemplateSyncRunStatus.NoConnectedDevices);
    public static TemplateSyncRunResult PeerUpdateRequiredResult() => new(TemplateSyncRunStatus.PeerUpdateRequired);
    public static TemplateSyncRunResult AlreadyInProgressResult() => new(TemplateSyncRunStatus.AlreadyInProgress);
    public static TemplateSyncRunResult StoppedResult() => new(TemplateSyncRunStatus.Stopped);
    public static TemplateSyncRunResult LimitExceededResult() => new(TemplateSyncRunStatus.LimitExceeded);
}

public readonly record struct TemplateSyncNotice(string Message, bool IsWarning);

public sealed record TemplateListEntry(
    bool IsHeader,
    TemplateGroupView Group,
    TemplateSyncItem? Item,
    bool IsExpanded,
    int IndexInGroup,
    int GroupCount);

public enum TemplateActivationAction
{
    None,
    ToggleGroup,
    SelectItem,
}

public readonly record struct TemplateActivationDecision(
    TemplateActivationAction Action,
    HistorySelectionDecision Selection = default);

/// <summary>
/// Pure tab, group-collapse, selection, and notice formatting logic for the templates tab
/// in HistoryWindow, kept apart from WPF so it can be unit tested.
/// </summary>
public static class TemplateWindowLogic
{
    public static HistoryWindowTab InitialTab() => HistoryWindowTab.History;

    public static HistoryWindowTab ToggleTab(HistoryWindowTab current) =>
        current == HistoryWindowTab.History ? HistoryWindowTab.Templates : HistoryWindowTab.History;

    public static string SearchHint(HistoryWindowTab tab) =>
        tab == HistoryWindowTab.Templates ? "テンプレートを検索" : "履歴を検索";

    public static string TitleModeLabel(HistoryWindowTab tab) =>
        tab == HistoryWindowTab.Templates ? "テンプレート" : "履歴";

    public static string FooterHint(HistoryWindowTab tab) =>
        tab == HistoryWindowTab.Templates
            ? "Enter 貼り付け　Alt+↑↓ 並替　Ctrl+Tab 切替"
            : "Enter 貼り付け　Ctrl+Enter コピー　Delete 削除";

    public static string TemplateEmptyTitle(string? search) =>
        string.IsNullOrWhiteSpace(search) ? "テンプレートはまだありません" : "見つかりませんでした";

    public static string TemplateEmptyDetail(string? search) =>
        string.IsNullOrWhiteSpace(search)
            ? "「＋」で定型文を追加したり、履歴のメニューから移動したりできます。"
            : "検索語を変えるか、検索をクリアしてください。";

    public static string GroupKey(string? tag) => tag ?? "";

    public static bool StartsExpanded(int groupCount, string? search) =>
        groupCount == 1 || !string.IsNullOrWhiteSpace(search);

    public static bool IsGroupExpanded(
        string? tag,
        int groupCount,
        string? search,
        IReadOnlySet<string> openTags,
        IReadOnlySet<string> closedTags)
    {
        var key = GroupKey(tag);
        return StartsExpanded(groupCount, search)
            ? !closedTags.Contains(key)
            : openTags.Contains(key);
    }

    public static void ToggleGroupExpansion(
        string? tag,
        int groupCount,
        string? search,
        ISet<string> openTags,
        ISet<string> closedTags)
    {
        var key = GroupKey(tag);
        if (StartsExpanded(groupCount, search))
        {
            if (!closedTags.Remove(key))
                closedTags.Add(key);
        }
        else
        {
            if (!openTags.Remove(key))
                openTags.Add(key);
        }
    }

    public static void TransferGroupExpansionOnRename(
        string? oldTag,
        string? newTag,
        ISet<string> openTags,
        ISet<string> closedTags)
    {
        var oldKey = GroupKey(oldTag);
        var newKey = GroupKey(newTag);
        if (string.Equals(oldKey, newKey, StringComparison.Ordinal)) return;
        if (openTags.Remove(oldKey)) openTags.Add(newKey);
        if (closedTags.Remove(oldKey)) closedTags.Add(newKey);
    }

    public static IReadOnlyList<TemplateListEntry> BuildVisibleEntries(
        IReadOnlyList<TemplateGroupView> groups,
        string? search,
        IReadOnlySet<string> openTags,
        IReadOnlySet<string> closedTags)
    {
        if (groups.Count == 0) return [];
        var result = new List<TemplateListEntry>();
        foreach (var group in groups)
        {
            var expanded = IsGroupExpanded(group.Tag, groups.Count, search, openTags, closedTags);
            result.Add(new TemplateListEntry(
                IsHeader: true,
                Group: group,
                Item: null,
                IsExpanded: expanded,
                IndexInGroup: -1,
                GroupCount: group.Items.Count));

            if (!expanded) continue;
            for (var i = 0; i < group.Items.Count; i++)
            {
                result.Add(new TemplateListEntry(
                    IsHeader: false,
                    Group: group,
                    Item: group.Items[i],
                    IsExpanded: true,
                    IndexInGroup: i,
                    GroupCount: group.Items.Count));
            }
        }
        return result;
    }

    public static bool CanMoveInGroup(TemplateListEntry? entry, int delta)
    {
        if (entry is null || entry.IsHeader || delta == 0) return false;
        var next = entry.IndexInGroup + delta;
        return next >= 0 && next < entry.GroupCount;
    }

    public static TemplateActivationDecision DecideTemplateActivation(
        bool isHeader,
        bool pasteOnSelect,
        bool ctrlPressed,
        bool? explicitPaste,
        bool hasValidExternalTarget)
    {
        if (isHeader)
            return new TemplateActivationDecision(TemplateActivationAction.ToggleGroup);
        return new TemplateActivationDecision(
            TemplateActivationAction.SelectItem,
            HistoryWindowPlacement.DecideSelection(pasteOnSelect, ctrlPressed, explicitPaste, hasValidExternalTarget));
    }

    public static TemplateSyncNotice? FormatSyncNotice(TemplateSyncRunResult result)
    {
        switch (result.Status)
        {
            case TemplateSyncRunStatus.AlreadyInProgress:
                return null;
            case TemplateSyncRunStatus.NoConnectedDevices:
                return new TemplateSyncNotice("つながっているiPhone・iPadがありません", IsWarning: true);
            case TemplateSyncRunStatus.PeerUpdateRequired:
                return new TemplateSyncNotice("iPhone・iPadのアプリを更新してください", IsWarning: true);
            case TemplateSyncRunStatus.Stopped:
                return new TemplateSyncNotice("いまは同期できません", IsWarning: true);
            case TemplateSyncRunStatus.LimitExceeded:
                return new TemplateSyncNotice("テンプレートが300件の上限を超えるため同期できませんでした", IsWarning: true);
            case TemplateSyncRunStatus.Disconnected:
                return new TemplateSyncNotice(
                    result.PcSaved
                        ? "PCへ保存しましたが、端末との接続が途中で切れました"
                        : "端末との接続が途中で切れました",
                    IsWarning: true);
            case TemplateSyncRunStatus.TimedOut:
                return new TemplateSyncNotice(
                    result.PcSaved
                        ? "PCへ保存しましたが、端末からの応答が時間切れになりました"
                        : "端末からの応答が時間切れになりました",
                    IsWarning: true);
            case TemplateSyncRunStatus.Completed:
                break;
            default:
                return new TemplateSyncNotice("テンプレートを同期できませんでした", IsWarning: true);
        }

        string main;
        var pcTotal = result.PcAdded + result.PcUpdated + result.PcDeleted;
        if (pcTotal > 0)
        {
            var parts = new List<string>(3);
            if (result.PcAdded > 0) parts.Add($"追加 {result.PcAdded}件");
            if (result.PcUpdated > 0) parts.Add($"更新 {result.PcUpdated}件");
            if (result.PcDeleted > 0) parts.Add($"削除 {result.PcDeleted}件");
            main = $"テンプレートを同期しました（{string.Join("・", parts)}）";
        }
        else if (result.RemoteChangesTotal > 0)
        {
            main = result.SucceededDevices > 1
                ? $"{result.SucceededDevices}台の端末へ反映しました"
                : $"端末へ反映しました（{result.RemoteChangesTotal}件）";
        }
        else
        {
            main = "テンプレートは同じ状態です";
        }

        var suffixes = new List<string>();
        if (result.ConflictCopyCount > 0)
            suffixes.Add($"別端末の編集 {result.ConflictCopyCount}件を「その他」へ");
        if (result.FailedDevices > 0)
            suffixes.Add($"（{result.SucceededDevices}台完了・{result.FailedDevices}台は未完了）");
        if (result.ClockSkewSeconds is not null)
            suffixes.Add("※端末の時計がずれています");

        var message = suffixes.Count == 0
            ? main
            : $"{main}　{string.Join("　", suffixes)}";
        var isWarning = result.FailedDevices > 0 || result.ClockSkewSeconds is not null;
        return new TemplateSyncNotice(message, isWarning);
    }
}
