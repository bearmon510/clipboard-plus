namespace ClipboardPlus.Windows.Core;

public readonly record struct ScreenBounds(int Left, int Top, int Right, int Bottom, double Scale)
{
    public int Width => Math.Max(0, Right - Left);
    public int Height => Math.Max(0, Bottom - Top);
}

public readonly record struct WindowPlacement(int Left, int Top, double Width, double Height, double? Scale = null);

public readonly record struct WindowPixelRect(int Left, int Top, int Width, int Height, double TargetScale);

/// <summary>
/// Pure placement, screen clamping, DPI scaling, resize hit-testing, and drag threshold logic
/// for the history window, kept apart from WPF so it can be unit tested.
/// </summary>
public static class HistoryWindowPlacement
{
    public const double DefaultWidth = 360;
    public const double DefaultHeight = 460;
    public const double MinWidth = 300;
    public const double MinHeight = 320;
    public const double MaxLogicalWidth = 2400;
    public const double MaxLogicalHeight = 2400;
    public const int MinCoordinate = -65536;
    public const int MaxCoordinate = 65536;
    public const double CaretLineHeight = 32;

    public const int HitNone = 0;
    public const int HitLeft = 10;
    public const int HitRight = 11;
    public const int HitTop = 12;
    public const int HitTopLeft = 13;
    public const int HitTopRight = 14;
    public const int HitBottom = 15;
    public const int HitBottomLeft = 16;
    public const int HitBottomRight = 17;

    public static double NormalizeScale(double scale) =>
        double.IsFinite(scale) && scale > 0 ? Math.Clamp(scale, 0.5, 6.0) : 1.0;

    public static bool TryNormalize(int? left, int? top, double? width, double? height, out WindowPlacement placement) =>
        TryNormalize(left, top, width, height, null, out placement);

    public static bool TryNormalize(int? left, int? top, double? width, double? height, double? scale, out WindowPlacement placement)
    {
        placement = default;
        if (left is not int x || top is not int y || width is not double w || height is not double h)
            return false;
        if (x < MinCoordinate || x > MaxCoordinate || y < MinCoordinate || y > MaxCoordinate)
            return false;
        if (!double.IsFinite(w) || !double.IsFinite(h) || w <= 0 || h <= 0)
            return false;

        double? normalizedScale = scale is double s && double.IsFinite(s) && s > 0
            ? NormalizeScale(s)
            : null;

        placement = new WindowPlacement(
            x,
            y,
            Math.Clamp(w, MinWidth, MaxLogicalWidth),
            Math.Clamp(h, MinHeight, MaxLogicalHeight),
            normalizedScale);
        return true;
    }

    public static WindowPlacement? Normalize(int left, int top, double width, double height, double? scale = null) =>
        TryNormalize(left, top, width, height, scale, out var placement) ? placement : null;

    public static bool AreSame(WindowPlacement? current, WindowPlacement candidate)
    {
        if (current is not { } existing) return false;
        if (existing.Left != candidate.Left || existing.Top != candidate.Top) return false;
        if (Math.Abs(existing.Width - candidate.Width) > 1e-6 ||
            Math.Abs(existing.Height - candidate.Height) > 1e-6)
            return false;
        if (existing.Scale is null || candidate.Scale is null)
            return existing.Scale == candidate.Scale;
        return Math.Abs(existing.Scale.Value - candidate.Scale.Value) <= 1e-6;
    }

    /// <summary>
    /// Places a previously saved window inside the current screens.
    /// When the saved position is partially or completely off-screen, it is moved back into the nearest screen
    /// and sized using that screen's DPI scale.
    /// </summary>
    public static WindowPixelRect ResolveSaved(WindowPlacement saved, IReadOnlyList<ScreenBounds> screens)
    {
        if (screens.Count == 0)
        {
            var fallbackW = (int)Math.Round(Math.Clamp(saved.Width, MinWidth, MaxLogicalWidth));
            var fallbackH = (int)Math.Round(Math.Clamp(saved.Height, MinHeight, MaxLogicalHeight));
            return new WindowPixelRect(saved.Left, saved.Top, fallbackW, fallbackH, 1.0);
        }

        var target = PickScreenForSaved(saved, screens);
        var scale = NormalizeScale(target.Scale);
        var (physW, physH) = FitSizeToScreen(saved.Width, saved.Height, target);
        var left = ClampPosition(saved.Left, target.Left, target.Right, physW);
        var top = ClampPosition(saved.Top, target.Top, target.Bottom, physH);
        return new WindowPixelRect(left, top, physW, physH, scale);
    }

    /// <summary>
    /// Places the window near the caret or cursor on first open, kept inside that screen's work area.
    /// </summary>
    public static WindowPixelRect PlaceNearAnchor(
        int anchorX,
        int anchorY,
        bool caretKnown,
        double preferredWidthDip,
        double preferredHeightDip,
        IReadOnlyList<ScreenBounds> screens)
    {
        if (screens.Count == 0)
        {
            var w = (int)Math.Round(Math.Clamp(preferredWidthDip, MinWidth, MaxLogicalWidth));
            var h = (int)Math.Round(Math.Clamp(preferredHeightDip, MinHeight, MaxLogicalHeight));
            return new WindowPixelRect(anchorX, anchorY + (caretKnown ? 6 : 8), w, h, 1.0);
        }

        var target = PickScreenForPoint(anchorX, anchorY, screens);
        var scale = NormalizeScale(target.Scale);
        var (physW, physH) = FitSizeToScreen(preferredWidthDip, preferredHeightDip, target);

        var belowGap = (int)Math.Round((caretKnown ? 6 : 8) * scale);
        var aboveGap = (int)Math.Round((caretKnown ? CaretLineHeight : 8) * scale);
        var y = anchorY + belowGap;
        if (y + physH > target.Bottom)
            y = anchorY - physH - aboveGap;

        var left = ClampPosition(anchorX, target.Left, target.Right, physW);
        var top = ClampPosition(y, target.Top, target.Bottom, physH);
        return new WindowPixelRect(left, top, physW, physH, scale);
    }

    public static bool IsDragDistanceReached(double deltaX, double deltaY, double minHorizontalDistance, double minVerticalDistance)
    {
        if (!double.IsFinite(deltaX) || !double.IsFinite(deltaY) ||
            !double.IsFinite(minHorizontalDistance) || !double.IsFinite(minVerticalDistance))
            return false;

        return Math.Abs(deltaX) >= Math.Max(0, minHorizontalDistance) ||
               Math.Abs(deltaY) >= Math.Max(0, minVerticalDistance);
    }

    /// <summary>Computes a Win32 WM_NCHITTEST resize code for a window edge/corner, or HitNone for client area.</summary>
    public static int ComputeResizeHit(
        int cursorX,
        int cursorY,
        int winLeft,
        int winTop,
        int winRight,
        int winBottom,
        int borderX,
        int borderY)
    {
        if (borderX <= 0 || borderY <= 0 || winRight <= winLeft || winBottom <= winTop)
            return HitNone;
        if (cursorX < winLeft || cursorX >= winRight || cursorY < winTop || cursorY >= winBottom)
            return HitNone;

        var bx = Math.Min(borderX, Math.Max(1, (winRight - winLeft) / 3));
        var by = Math.Min(borderY, Math.Max(1, (winBottom - winTop) / 3));

        var left = cursorX < winLeft + bx;
        var right = cursorX >= winRight - bx;
        var top = cursorY < winTop + by;
        var bottom = cursorY >= winBottom - by;

        if (top && left) return HitTopLeft;
        if (top && right) return HitTopRight;
        if (bottom && left) return HitBottomLeft;
        if (bottom && right) return HitBottomRight;
        if (left) return HitLeft;
        if (right) return HitRight;
        if (top) return HitTop;
        if (bottom) return HitBottom;
        return HitNone;
    }

    private static ScreenBounds PickScreenForSaved(WindowPlacement saved, IReadOnlyList<ScreenBounds> screens)
    {
        var best = screens[0];
        var bestFraction = -1.0;
        var bestContainsCenter = false;
        var bestContainsOrigin = false;
        var bestDistSq = long.MaxValue;

        var hasSavedScale = saved.Scale is double rawScale && double.IsFinite(rawScale) && rawScale > 0;
        var savedScale = hasSavedScale ? NormalizeScale(saved.Scale!.Value) : 0;

        foreach (var screen in screens)
        {
            if (screen.Width <= 0 || screen.Height <= 0) continue;

            var (w, h) = hasSavedScale
                ? ScaleSize(saved.Width, saved.Height, savedScale)
                : FitSizeToScreen(saved.Width, saved.Height, screen);
            var right = (long)saved.Left + w;
            var bottom = (long)saved.Top + h;

            var ixLeft = Math.Max((long)saved.Left, screen.Left);
            var ixTop = Math.Max((long)saved.Top, screen.Top);
            var ixRight = Math.Min(right, screen.Right);
            var ixBottom = Math.Min(bottom, screen.Bottom);

            var overlapArea = ixRight > ixLeft && ixBottom > ixTop
                ? (ixRight - ixLeft) * (ixBottom - ixTop)
                : 0L;
            var area = Math.Max(1L, (long)w * h);
            var fraction = (double)overlapArea / area;
            var centerX = (int)Math.Clamp((long)saved.Left + w / 2, int.MinValue, int.MaxValue);
            var centerY = (int)Math.Clamp((long)saved.Top + h / 2, int.MinValue, int.MaxValue);
            var containsCenter = Contains(screen, centerX, centerY);
            var containsOrigin = Contains(screen, saved.Left, saved.Top);
            var distSq = RectDistanceSq(saved.Left, saved.Top, right, bottom, screen);

            var better = overlapArea > 0
                ? fraction > bestFraction + 1e-9 ||
                  (Math.Abs(fraction - bestFraction) <= 1e-9 &&
                   ((containsCenter && !bestContainsCenter) ||
                    (containsCenter == bestContainsCenter &&
                     ((containsOrigin && !bestContainsOrigin) || (containsOrigin == bestContainsOrigin && distSq < bestDistSq)))))
                : bestFraction <= 0 && distSq < bestDistSq;

            if (better)
            {
                best = screen;
                bestFraction = fraction;
                bestContainsCenter = containsCenter;
                bestContainsOrigin = containsOrigin;
                bestDistSq = distSq;
            }
        }

        return best;
    }

    private static (int Width, int Height) ScaleSize(double logicalW, double logicalH, double scale)
    {
        var clampedDipW = double.IsFinite(logicalW) ? Math.Clamp(logicalW, MinWidth, MaxLogicalWidth) : DefaultWidth;
        var clampedDipH = double.IsFinite(logicalH) ? Math.Clamp(logicalH, MinHeight, MaxLogicalHeight) : DefaultHeight;
        return (Math.Max(1, (int)Math.Round(clampedDipW * scale)), Math.Max(1, (int)Math.Round(clampedDipH * scale)));
    }

    private static ScreenBounds PickScreenForPoint(int x, int y, IReadOnlyList<ScreenBounds> screens)
    {
        var best = screens[0];
        var bestDistSq = long.MaxValue;

        foreach (var screen in screens)
        {
            if (screen.Width <= 0 || screen.Height <= 0) continue;
            if (Contains(screen, x, y)) return screen;

            var distSq = PointDistanceSq(x, y, screen);
            if (distSq < bestDistSq)
            {
                bestDistSq = distSq;
                best = screen;
            }
        }

        return best;
    }

    private static (int Width, int Height) FitSizeToScreen(double logicalW, double logicalH, ScreenBounds screen)
    {
        var scale = NormalizeScale(screen.Scale);
        var maxW = Math.Max(1, screen.Width);
        var maxH = Math.Max(1, screen.Height);
        var minW = Math.Min(maxW, Math.Max(1, (int)Math.Round(MinWidth * scale)));
        var minH = Math.Min(maxH, Math.Max(1, (int)Math.Round(MinHeight * scale)));

        var clampedDipW = double.IsFinite(logicalW) ? Math.Clamp(logicalW, MinWidth, MaxLogicalWidth) : DefaultWidth;
        var clampedDipH = double.IsFinite(logicalH) ? Math.Clamp(logicalH, MinHeight, MaxLogicalHeight) : DefaultHeight;

        var targetW = (int)Math.Round(clampedDipW * scale);
        var targetH = (int)Math.Round(clampedDipH * scale);
        return (Math.Clamp(targetW, minW, maxW), Math.Clamp(targetH, minH, maxH));
    }

    private static int ClampPosition(int value, int min, int maxExclusive, int size)
    {
        var maxStart = Math.Max(min, maxExclusive - size);
        return Math.Clamp(value, min, maxStart);
    }

    private static bool Contains(ScreenBounds screen, int x, int y) =>
        x >= screen.Left && x < screen.Right && y >= screen.Top && y < screen.Bottom;

    private static long PointDistanceSq(int x, int y, ScreenBounds screen)
    {
        long dx = x < screen.Left ? screen.Left - x : (x >= screen.Right ? x - (screen.Right - 1) : 0);
        long dy = y < screen.Top ? screen.Top - y : (y >= screen.Bottom ? y - (screen.Bottom - 1) : 0);
        return dx * dx + dy * dy;
    }

    private static long RectDistanceSq(long left, long top, long right, long bottom, ScreenBounds screen)
    {
        long dx = right <= screen.Left ? screen.Left - right : (left >= screen.Right ? left - screen.Right : 0);
        long dy = bottom <= screen.Top ? screen.Top - bottom : (top >= screen.Bottom ? top - screen.Bottom : 0);
        return dx * dx + dy * dy;
    }
}
