using ClipboardPlus.Windows.Core;
using Xunit;

namespace ClipboardPlus.Sync.Tests;

public sealed class HistoryWindowPlacementTests
{
    private static readonly ScreenBounds Primary100 = new(0, 0, 1920, 1040, 1.0);
    private static readonly ScreenBounds Right200 = new(1920, 0, 5760, 2120, 2.0);
    private static readonly ScreenBounds Left150 = new(-1920, 0, 0, 1040, 1.5);

    [Fact]
    public void TryNormalizeRejectsMissingOutOfRangeOrNonFiniteValuesAndClampsMinimumSize()
    {
        Assert.False(HistoryWindowPlacement.TryNormalize(null, 0, 360, 460, out _));
        Assert.False(HistoryWindowPlacement.TryNormalize(0, null, 360, 460, out _));
        Assert.False(HistoryWindowPlacement.TryNormalize(0, 0, null, 460, out _));
        Assert.False(HistoryWindowPlacement.TryNormalize(0, 0, 360, null, out _));
        Assert.False(HistoryWindowPlacement.TryNormalize(0, 0, 0, 460, out _));
        Assert.False(HistoryWindowPlacement.TryNormalize(0, 0, 360, -10, out _));
        Assert.False(HistoryWindowPlacement.TryNormalize(0, 0, double.NaN, 460, out _));
        Assert.False(HistoryWindowPlacement.TryNormalize(0, 0, 360, double.PositiveInfinity, out _));
        Assert.False(HistoryWindowPlacement.TryNormalize(100_000, 0, 360, 460, out _));
        Assert.False(HistoryWindowPlacement.TryNormalize(0, -100_000, 360, 460, out _));

        Assert.True(HistoryWindowPlacement.TryNormalize(-200, 50, 120, 200, out var clamped));
        Assert.Equal(new WindowPlacement(-200, 50, HistoryWindowPlacement.MinWidth, HistoryWindowPlacement.MinHeight), clamped);

        Assert.True(HistoryWindowPlacement.TryNormalize(100, 200, 5000, 4000, out var maxClamped));
        Assert.Equal(HistoryWindowPlacement.MaxLogicalWidth, maxClamped.Width);
        Assert.Equal(HistoryWindowPlacement.MaxLogicalHeight, maxClamped.Height);
    }

    [Fact]
    public void ResolveSavedPreservesInBoundsPositionAcrossDpiMonitors()
    {
        var saved = new WindowPlacement(2300, 120, 420, 520);
        var resolved = HistoryWindowPlacement.ResolveSaved(saved, [Primary100, Right200]);

        Assert.Equal(2300, resolved.Left);
        Assert.Equal(120, resolved.Top);
        Assert.Equal(840, resolved.Width);
        Assert.Equal(1040, resolved.Height);
        Assert.Equal(2.0, resolved.TargetScale);
    }

    [Fact]
    public void ResolveSavedMovesDisconnectedMonitorWindowBackToRemainingScreenWithProperLogicalSize()
    {
        // Previously saved on the 200% secondary monitor at x=2300 with 400x500 logical DIPs.
        var saved = new WindowPlacement(2300, 120, 400, 500);
        var resolved = HistoryWindowPlacement.ResolveSaved(saved, [Primary100]);

        Assert.Equal(1920 - 400, resolved.Left);
        Assert.Equal(120, resolved.Top);
        Assert.Equal(400, resolved.Width);
        Assert.Equal(500, resolved.Height);
        Assert.Equal(1.0, resolved.TargetScale);
    }

    [Fact]
    public void ResolveSavedClampsPartiallyOffScreenWindowIntoWorkArea()
    {
        var saved = new WindowPlacement(1800, 900, 360, 460);
        var resolved = HistoryWindowPlacement.ResolveSaved(saved, [Primary100]);

        Assert.Equal(1920 - 360, resolved.Left);
        Assert.Equal(1040 - 460, resolved.Top);
        Assert.Equal(360, resolved.Width);
        Assert.Equal(460, resolved.Height);
    }

    [Fact]
    public void ResolveSavedPicksNearestMonitorWhenMultipleMonitorsRemainAndSavedMonitorWasRemoved()
    {
        var saved = new WindowPlacement(2500, 100, 360, 460);
        var resolved = HistoryWindowPlacement.ResolveSaved(saved, [Left150, Primary100]);

        Assert.Equal(1920 - 360, resolved.Left);
        Assert.Equal(100, resolved.Top);
        Assert.Equal(1.0, resolved.TargetScale);
    }

    [Fact]
    public void ResolveSavedPicksScreenWithGreaterOverlapFractionAcrossDifferentDpis()
    {
        // Window starts at x=1640 on Primary100 (280px on Primary100 = 78% of 360px, vs 80px on Right200).
        var saved = new WindowPlacement(1640, 100, 360, 460);
        var resolved = HistoryWindowPlacement.ResolveSaved(saved, [Primary100, Right200]);

        Assert.Equal(1.0, resolved.TargetScale);
        Assert.Equal(1920 - 360, resolved.Left);
        Assert.Equal(360, resolved.Width);
    }

    [Fact]
    public void ResolveSavedClampsOversizedWindowToTinyScreen()
    {
        var tiny = new ScreenBounds(0, 0, 260, 280, 1.0);
        var saved = new WindowPlacement(10, 10, 500, 600);
        var resolved = HistoryWindowPlacement.ResolveSaved(saved, [tiny]);

        Assert.Equal(0, resolved.Left);
        Assert.Equal(0, resolved.Top);
        Assert.Equal(260, resolved.Width);
        Assert.Equal(280, resolved.Height);
    }

    [Fact]
    public void PlaceNearAnchorPositionsBelowAndFlipsAboveNearBottomScaledByMonitorDpi()
    {
        var below = HistoryWindowPlacement.PlaceNearAnchor(
            anchorX: 2200,
            anchorY: 200,
            caretKnown: true,
            preferredWidthDip: HistoryWindowPlacement.DefaultWidth,
            preferredHeightDip: HistoryWindowPlacement.DefaultHeight,
            screens: [Primary100, Right200]);

        Assert.Equal(2.0, below.TargetScale);
        Assert.Equal(720, below.Width);
        Assert.Equal(920, below.Height);
        Assert.Equal(2200, below.Left);
        Assert.Equal(200 + 12, below.Top);

        // Near bottom of Right200 (2120): must flip above caret leaving CaretLineHeight * 2.0 (64px).
        var above = HistoryWindowPlacement.PlaceNearAnchor(
            anchorX: 5500,
            anchorY: 1900,
            caretKnown: true,
            preferredWidthDip: HistoryWindowPlacement.DefaultWidth,
            preferredHeightDip: HistoryWindowPlacement.DefaultHeight,
            screens: [Primary100, Right200]);

        Assert.Equal(5760 - 720, above.Left);
        Assert.Equal(1900 - 920 - 64, above.Top);
    }

    [Fact]
    public void PlaceNearAnchorHandlesCursorOnTaskbarOutsideWorkArea()
    {
        // Cursor at y=1060 on taskbar just below Primary100 work area (Bottom=1040).
        var placed = HistoryWindowPlacement.PlaceNearAnchor(
            anchorX: 1850,
            anchorY: 1060,
            caretKnown: false,
            preferredWidthDip: HistoryWindowPlacement.DefaultWidth,
            preferredHeightDip: HistoryWindowPlacement.DefaultHeight,
            screens: [Primary100]);

        Assert.InRange(placed.Left, 0, 1920 - 360);
        Assert.InRange(placed.Top, 0, 1040 - 460);
    }

    [Fact]
    public void IsDragDistanceReachedChecksMinimumThresholds()
    {
        Assert.False(HistoryWindowPlacement.IsDragDistanceReached(3.9, 3.9, 4, 4));
        Assert.True(HistoryWindowPlacement.IsDragDistanceReached(4.0, 0, 4, 4));
        Assert.True(HistoryWindowPlacement.IsDragDistanceReached(0, -4.0, 4, 4));
        Assert.False(HistoryWindowPlacement.IsDragDistanceReached(double.NaN, 10, 4, 4));
    }

    [Fact]
    public void ComputeResizeHitDetectsAllEdgesCornersAndInteriorAcrossNegativeCoords()
    {
        const int left = -1000, top = -500, right = -640, bottom = -40, border = 5;

        Assert.Equal(HistoryWindowPlacement.HitTopLeft, HistoryWindowPlacement.ComputeResizeHit(-999, -499, left, top, right, bottom, border, border));
        Assert.Equal(HistoryWindowPlacement.HitTopRight, HistoryWindowPlacement.ComputeResizeHit(-642, -498, left, top, right, bottom, border, border));
        Assert.Equal(HistoryWindowPlacement.HitBottomLeft, HistoryWindowPlacement.ComputeResizeHit(-998, -42, left, top, right, bottom, border, border));
        Assert.Equal(HistoryWindowPlacement.HitBottomRight, HistoryWindowPlacement.ComputeResizeHit(-641, -41, left, top, right, bottom, border, border));
        Assert.Equal(HistoryWindowPlacement.HitLeft, HistoryWindowPlacement.ComputeResizeHit(-997, -250, left, top, right, bottom, border, border));
        Assert.Equal(HistoryWindowPlacement.HitRight, HistoryWindowPlacement.ComputeResizeHit(-643, -250, left, top, right, bottom, border, border));
        Assert.Equal(HistoryWindowPlacement.HitTop, HistoryWindowPlacement.ComputeResizeHit(-800, -497, left, top, right, bottom, border, border));
        Assert.Equal(HistoryWindowPlacement.HitBottom, HistoryWindowPlacement.ComputeResizeHit(-800, -43, left, top, right, bottom, border, border));
        Assert.Equal(HistoryWindowPlacement.HitNone, HistoryWindowPlacement.ComputeResizeHit(-800, -250, left, top, right, bottom, border, border));
        Assert.Equal(HistoryWindowPlacement.HitNone, HistoryWindowPlacement.ComputeResizeHit(-640, -250, left, top, right, bottom, border, border));
    }

    [Fact]
    public void ResolveSavedUsesSavedScaleAtDifferentDpiMonitorBoundary()
    {
        // Window is 360x460 DIP at 200% (720x920 px), placed at x=1660 (260px on Primary100, 460px + center on Right200).
        var saved = new WindowPlacement(1660, 100, 360, 460, Scale: 2.0);
        var resolved = HistoryWindowPlacement.ResolveSaved(saved, [Primary100, Right200]);

        Assert.Equal(2.0, resolved.TargetScale);
        Assert.Equal(1920, resolved.Left);
        Assert.Equal(720, resolved.Width);
        Assert.Equal(920, resolved.Height);
    }

    [Fact]
    public void AreSameDetectsChangesAndToleratesFloatingPointNoise()
    {
        var baseline = new WindowPlacement(100, 200, 360.5, 460.25, 1.5);
        Assert.False(HistoryWindowPlacement.AreSame(null, baseline));
        Assert.True(HistoryWindowPlacement.AreSame(baseline, baseline));
        Assert.True(HistoryWindowPlacement.AreSame(baseline, baseline with { Width = 360.5 + 1e-9 }));
        Assert.False(HistoryWindowPlacement.AreSame(baseline, baseline with { Left = 101 }));
        Assert.False(HistoryWindowPlacement.AreSame(baseline, baseline with { Top = 201 }));
        Assert.False(HistoryWindowPlacement.AreSame(baseline, baseline with { Width = 361 }));
        Assert.False(HistoryWindowPlacement.AreSame(baseline, baseline with { Height = 461 }));
        Assert.False(HistoryWindowPlacement.AreSame(baseline, baseline with { Scale = 2.0 }));
        Assert.False(HistoryWindowPlacement.AreSame(baseline with { Scale = null }, baseline));
    }

    [Fact]
    public void ShouldCloseWindowOnlyClosesForCloseButtonActiveEscapeAndHotkeyToggle()
    {
        Assert.True(HistoryWindowPlacement.ShouldCloseWindow(HistoryWindowTrigger.CloseButton));
        Assert.True(HistoryWindowPlacement.ShouldCloseWindow(HistoryWindowTrigger.HotkeyWhileVisible));
        Assert.True(HistoryWindowPlacement.ShouldCloseWindow(HistoryWindowTrigger.EscapeKey, isWindowActive: true));
        Assert.False(HistoryWindowPlacement.ShouldCloseWindow(HistoryWindowTrigger.EscapeKey, isWindowActive: false));

        foreach (var keepOpenTrigger in new[]
        {
            HistoryWindowTrigger.SelectForPaste,
            HistoryWindowTrigger.SelectCopyOnly,
            HistoryWindowTrigger.CtrlEnter,
            HistoryWindowTrigger.MenuPaste,
            HistoryWindowTrigger.MenuCopyOnly,
            HistoryWindowTrigger.DragOut,
            HistoryWindowTrigger.Deactivate,
            HistoryWindowTrigger.DeleteItem,
            HistoryWindowTrigger.DropIn,
        })
        {
            Assert.False(HistoryWindowPlacement.ShouldCloseWindow(keepOpenTrigger, isWindowActive: true));
            Assert.False(HistoryWindowPlacement.ShouldCloseWindow(keepOpenTrigger, isWindowActive: false));
        }
    }

    [Fact]
    public void DecideSelectionNeverClosesAndHonorsPasteSettingCtrlAndMenuOverrides()
    {
        var clickPaste = HistoryWindowPlacement.DecideSelection(
            pasteOnSelect: true, ctrlPressed: false, explicitPaste: null, hasValidExternalTarget: true);
        Assert.Equal(new HistorySelectionDecision(ShouldCopy: true, ShouldPaste: true, ShouldClose: false), clickPaste);

        var ctrlEnter = HistoryWindowPlacement.DecideSelection(
            pasteOnSelect: true, ctrlPressed: true, explicitPaste: null, hasValidExternalTarget: true);
        Assert.Equal(new HistorySelectionDecision(ShouldCopy: true, ShouldPaste: false, ShouldClose: false), ctrlEnter);

        var pasteOff = HistoryWindowPlacement.DecideSelection(
            pasteOnSelect: false, ctrlPressed: false, explicitPaste: null, hasValidExternalTarget: true);
        Assert.Equal(new HistorySelectionDecision(ShouldCopy: true, ShouldPaste: false, ShouldClose: false), pasteOff);

        var menuPasteWithSettingOff = HistoryWindowPlacement.DecideSelection(
            pasteOnSelect: false, ctrlPressed: false, explicitPaste: true, hasValidExternalTarget: true);
        Assert.Equal(new HistorySelectionDecision(ShouldCopy: true, ShouldPaste: true, ShouldClose: false), menuPasteWithSettingOff);

        var menuCopyWithSettingOn = HistoryWindowPlacement.DecideSelection(
            pasteOnSelect: true, ctrlPressed: false, explicitPaste: false, hasValidExternalTarget: true);
        Assert.Equal(new HistorySelectionDecision(ShouldCopy: true, ShouldPaste: false, ShouldClose: false), menuCopyWithSettingOn);

        var noExternalTarget = HistoryWindowPlacement.DecideSelection(
            pasteOnSelect: true, ctrlPressed: false, explicitPaste: true, hasValidExternalTarget: false);
        Assert.Equal(new HistorySelectionDecision(ShouldCopy: true, ShouldPaste: false, ShouldClose: false), noExternalTarget);
    }
}
