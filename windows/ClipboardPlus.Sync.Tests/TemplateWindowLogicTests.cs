using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class TemplateWindowLogicTests
{
    private static TemplateSyncItem Item(string text, string? title = null, string? tag = null, int order = 0) =>
        new(Guid.NewGuid(), TemplateSyncKind.Text, text, title, tag, order, 1_794_873_600_000);

    [Fact]
    public void InitialTabIsAlwaysHistoryAndToggleSwitchesTabs()
    {
        Assert.Equal(HistoryWindowTab.History, TemplateWindowLogic.InitialTab());
        Assert.Equal(HistoryWindowTab.Templates, TemplateWindowLogic.ToggleTab(HistoryWindowTab.History));
        Assert.Equal(HistoryWindowTab.History, TemplateWindowLogic.ToggleTab(HistoryWindowTab.Templates));

        Assert.Equal("履歴を検索", TemplateWindowLogic.SearchHint(HistoryWindowTab.History));
        Assert.Equal("テンプレートを検索", TemplateWindowLogic.SearchHint(HistoryWindowTab.Templates));
        Assert.Equal("履歴", TemplateWindowLogic.TitleModeLabel(HistoryWindowTab.History));
        Assert.Equal("テンプレート", TemplateWindowLogic.TitleModeLabel(HistoryWindowTab.Templates));
        Assert.Contains("Delete", TemplateWindowLogic.FooterHint(HistoryWindowTab.History));
        Assert.Contains("Ctrl+Tab", TemplateWindowLogic.FooterHint(HistoryWindowTab.Templates));
    }

    [Fact]
    public void EmptyStateDependsOnSearchQuery()
    {
        Assert.Equal("テンプレートはまだありません", TemplateWindowLogic.TemplateEmptyTitle(null));
        Assert.Equal("テンプレートはまだありません", TemplateWindowLogic.TemplateEmptyTitle("   "));
        Assert.Equal("見つかりませんでした", TemplateWindowLogic.TemplateEmptyTitle("abc"));
        Assert.Contains("「＋」", TemplateWindowLogic.TemplateEmptyDetail(null));
        Assert.Contains("検索をクリア", TemplateWindowLogic.TemplateEmptyDetail("abc"));
    }

    [Fact]
    public void GroupExpansionRulesFollowSingleGroupSearchToggleAndRenameTransfer()
    {
        var openTags = new HashSet<string>(StringComparer.Ordinal);
        var closedTags = new HashSet<string>(StringComparer.Ordinal);

        // Single group starts expanded even with empty search.
        Assert.True(TemplateWindowLogic.StartsExpanded(1, ""));
        Assert.True(TemplateWindowLogic.IsGroupExpanded("仕事", 1, "", openTags, closedTags));

        // Clicking header closes it via closedTags.
        TemplateWindowLogic.ToggleGroupExpansion("仕事", 1, "", openTags, closedTags);
        Assert.False(TemplateWindowLogic.IsGroupExpanded("仕事", 1, "", openTags, closedTags));

        // Multiple groups without search start collapsed unless present in openTags.
        Assert.False(TemplateWindowLogic.StartsExpanded(2, ""));
        Assert.False(TemplateWindowLogic.IsGroupExpanded("個人", 2, "", openTags, closedTags));
        TemplateWindowLogic.ToggleGroupExpansion("個人", 2, "", openTags, closedTags);
        Assert.True(TemplateWindowLogic.IsGroupExpanded("個人", 2, "", openTags, closedTags));

        // Non-empty search starts all groups expanded unless explicitly closed.
        Assert.True(TemplateWindowLogic.StartsExpanded(2, "検索"));
        Assert.True(TemplateWindowLogic.IsGroupExpanded("個人", 2, "検索", openTags, closedTags));
        Assert.False(TemplateWindowLogic.IsGroupExpanded("仕事", 2, "検索", openTags, closedTags)); // still in closedTags

        // Renaming transfers open/closed membership.
        TemplateWindowLogic.TransferGroupExpansionOnRename("個人", "連絡", openTags, closedTags);
        Assert.False(TemplateWindowLogic.IsGroupExpanded("個人", 2, "", openTags, closedTags));
        Assert.True(TemplateWindowLogic.IsGroupExpanded("連絡", 2, "", openTags, closedTags));

        TemplateWindowLogic.TransferGroupExpansionOnRename("仕事", null, openTags, closedTags);
        Assert.True(TemplateWindowLogic.IsGroupExpanded("仕事", 1, "", openTags, closedTags));
        Assert.False(TemplateWindowLogic.IsGroupExpanded(null, 1, "", openTags, closedTags));
    }

    [Fact]
    public void VisibleEntriesTrackGroupIndicesMoveBoundsAndActivationDecisions()
    {
        var a = Item("one", tag: "仕事", order: 0);
        var b = Item("two", tag: "仕事", order: 1);
        var c = Item("other", tag: null, order: 0);
        var groups = new List<TemplateGroupView>
        {
            new("仕事", "仕事", [a, b]),
            new(null, "その他", [c]),
        };

        var openTags = new HashSet<string>(StringComparer.Ordinal);
        var closedTags = new HashSet<string>(StringComparer.Ordinal);

        // Initially both collapsed -> 2 header rows only.
        var collapsed = TemplateWindowLogic.BuildVisibleEntries(groups, "", openTags, closedTags);
        Assert.Equal(2, collapsed.Count);
        Assert.All(collapsed, e => Assert.True(e.IsHeader));
        Assert.False(TemplateWindowLogic.CanMoveInGroup(collapsed[0], -1));
        Assert.False(TemplateWindowLogic.CanMoveInGroup(collapsed[0], 1));

        // Expand 仕事 -> header + a + b + header(その他).
        TemplateWindowLogic.ToggleGroupExpansion("仕事", 2, "", openTags, closedTags);
        var expanded = TemplateWindowLogic.BuildVisibleEntries(groups, "", openTags, closedTags);
        Assert.Equal(4, expanded.Count);
        Assert.True(expanded[0].IsHeader);
        Assert.Equal(a.Id, expanded[1].Item!.Id);
        Assert.Equal(b.Id, expanded[2].Item!.Id);
        Assert.True(expanded[3].IsHeader);

        // Move bounds within 仕事 group.
        Assert.False(TemplateWindowLogic.CanMoveInGroup(expanded[1], -1));
        Assert.True(TemplateWindowLogic.CanMoveInGroup(expanded[1], 1));
        Assert.True(TemplateWindowLogic.CanMoveInGroup(expanded[2], -1));
        Assert.False(TemplateWindowLogic.CanMoveInGroup(expanded[2], 1));

        // Activation decisions: header toggles without pasting/closing; item copies/pastes without closing.
        var headerAct = TemplateWindowLogic.DecideTemplateActivation(
            isHeader: true, pasteOnSelect: true, ctrlPressed: false, explicitPaste: null, hasValidExternalTarget: true);
        Assert.Equal(TemplateActivationAction.ToggleGroup, headerAct.Action);

        var itemPaste = TemplateWindowLogic.DecideTemplateActivation(
            isHeader: false, pasteOnSelect: true, ctrlPressed: false, explicitPaste: null, hasValidExternalTarget: true);
        Assert.Equal(TemplateActivationAction.SelectItem, itemPaste.Action);
        Assert.Equal(new HistorySelectionDecision(ShouldCopy: true, ShouldPaste: true, ShouldClose: false), itemPaste.Selection);

        var itemCtrlCopy = TemplateWindowLogic.DecideTemplateActivation(
            isHeader: false, pasteOnSelect: true, ctrlPressed: true, explicitPaste: null, hasValidExternalTarget: true);
        Assert.Equal(new HistorySelectionDecision(ShouldCopy: true, ShouldPaste: false, ShouldClose: false), itemCtrlCopy.Selection);
    }

    [Fact]
    public void FormatSyncNoticeCoversConnectedCountsErrorsConflictsPartialAndClockSkew()
    {
        static TemplateSyncNotice Notice(TemplateSyncRunResult res)
        {
            var notice = TemplateWindowLogic.FormatSyncNotice(res);
            Assert.NotNull(notice);
            return notice!.Value;
        }

        Assert.Null(TemplateWindowLogic.FormatSyncNotice(TemplateSyncRunResult.AlreadyInProgressResult()));

        var noDevices = Notice(TemplateSyncRunResult.NoConnectedDevicesResult());
        Assert.True(noDevices.IsWarning);
        Assert.Contains("つながっている", noDevices.Message);

        var v2 = Notice(TemplateSyncRunResult.PeerUpdateRequiredResult());
        Assert.True(v2.IsWarning);
        Assert.Contains("更新", v2.Message);

        var discUnsaved = Notice(new TemplateSyncRunResult(TemplateSyncRunStatus.Disconnected));
        Assert.True(discUnsaved.IsWarning);
        Assert.DoesNotContain("保存", discUnsaved.Message);

        var discSaved = Notice(new TemplateSyncRunResult(TemplateSyncRunStatus.Disconnected, PcSaved: true));
        Assert.True(discSaved.IsWarning);
        Assert.Contains("PCへ保存", discSaved.Message);

        var timeout = Notice(new TemplateSyncRunResult(TemplateSyncRunStatus.TimedOut));
        Assert.True(timeout.IsWarning);
        Assert.Contains("時間切れ", timeout.Message);

        var limit = Notice(TemplateSyncRunResult.LimitExceededResult());
        Assert.True(limit.IsWarning);
        Assert.Contains("300件", limit.Message);

        var identical = Notice(new TemplateSyncRunResult(TemplateSyncRunStatus.Completed, TargetDevices: 1, SucceededDevices: 1));
        Assert.False(identical.IsWarning);
        Assert.Equal("テンプレートは同じ状態です", identical.Message);

        var remoteOnly = Notice(new TemplateSyncRunResult(TemplateSyncRunStatus.Completed, TargetDevices: 1, SucceededDevices: 1, RemoteChangesTotal: 3));
        Assert.False(remoteOnly.IsWarning);
        Assert.Contains("3件", remoteOnly.Message);

        var multiRemote = Notice(new TemplateSyncRunResult(TemplateSyncRunStatus.Completed, TargetDevices: 2, SucceededDevices: 2, RemoteChangesTotal: 4));
        Assert.False(multiRemote.IsWarning);
        Assert.Contains("2台", multiRemote.Message);

        var pcChangedWithConflictAndPartial = Notice(new TemplateSyncRunResult(
            TemplateSyncRunStatus.Completed,
            TargetDevices: 2,
            SucceededDevices: 1,
            FailedDevices: 1,
            PcSaved: true,
            PcAdded: 2,
            PcUpdated: 1,
            PcDeleted: 0,
            ConflictCopyCount: 1,
            ClockSkewSeconds: 420));
        Assert.True(pcChangedWithConflictAndPartial.IsWarning);
        Assert.Contains("追加 2件・更新 1件", pcChangedWithConflictAndPartial.Message);
        Assert.DoesNotContain("削除", pcChangedWithConflictAndPartial.Message);
        Assert.Contains("別端末の編集 1件", pcChangedWithConflictAndPartial.Message);
        Assert.Contains("1台完了・1台は未完了", pcChangedWithConflictAndPartial.Message);
        Assert.Contains("時計がずれています", pcChangedWithConflictAndPartial.Message);

        var excludedNotice = Notice(new TemplateSyncRunResult(
            TemplateSyncRunStatus.Completed,
            TargetDevices: 1,
            SucceededDevices: 1,
            ExcludedTemplateCount: 4));
        Assert.True(excludedNotice.IsWarning);
        Assert.Contains("4件は対象外", excludedNotice.Message);

        var mixedCompleted = Notice(new TemplateSyncRunResult(
            TemplateSyncRunStatus.Completed,
            TargetDevices: 1,
            SucceededDevices: 1,
            RequiresPeerUpdate: true));
        Assert.True(mixedCompleted.IsWarning);
        Assert.Contains("更新が必要な端末があります", mixedCompleted.Message);

        var mixedDisconnected = Notice(new TemplateSyncRunResult(
            TemplateSyncRunStatus.Disconnected,
            RequiresPeerUpdate: true));
        Assert.True(mixedDisconnected.IsWarning);
        Assert.Contains("更新が必要な端末があります", mixedDisconnected.Message);

        var mixedTimedOut = Notice(new TemplateSyncRunResult(
            TemplateSyncRunStatus.TimedOut,
            RequiresPeerUpdate: true));
        Assert.True(mixedTimedOut.IsWarning);
        Assert.Contains("更新が必要な端末があります", mixedTimedOut.Message);
    }
}
