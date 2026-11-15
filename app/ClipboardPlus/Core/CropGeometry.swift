import CoreGraphics
import Foundation

/// What a capture produces once a part of the screen is chosen.
enum CaptureMode: String, CaseIterable, Identifiable {
    case text, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "文字"
        case .image: return "画像"
        }
    }

    var symbolName: String {
        switch self {
        case .text: return "text.viewfinder"
        case .image: return "crop"
        }
    }

    var hint: String {
        switch self {
        case .text: return "ドラッグで範囲を選ぶと、文字を読み取ってコピーします"
        case .image: return "ドラッグで範囲を選ぶと、画像としてコピーします"
        }
    }
}

/// Geometry for choosing a part of a picture by dragging. All functions are pure.
/// A "unit" rectangle is in the picture's own space, 0...1 on both axes, origin top-left.
enum CropGeometry {
    /// A drag shorter than this, in points on screen, is a stray tap rather than a choice.
    static let minimumDragDistance: CGFloat = 10
    /// The smallest part of the picture worth acting on, in picture pixels. A single line of
    /// text shrunk into a narrow window is only a few points tall on screen, so the size is
    /// judged on the picture, not on the screen.
    static let minimumSelectionPixels: CGFloat = 6

    /// Where an aspect-fit picture sits inside a container.
    static func fittedFrame(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The rectangle spanned by two points, kept inside `bounds`.
    static func rect(from a: CGPoint, to b: CGPoint, within bounds: CGRect) -> CGRect {
        let first = clamp(a, to: bounds)
        let second = clamp(b, to: bounds)
        return CGRect(x: min(first.x, second.x), y: min(first.y, second.y),
                      width: abs(first.x - second.x), height: abs(first.y - second.y))
    }

    /// Whether a drag from `start` to `end` is a real choice rather than a slip of the finger.
    static func isDeliberateDrag(from start: CGPoint, to end: CGPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) >= minimumDragDistance
    }

    /// Whether a chosen part, in unit space, covers enough of the picture to act on.
    static func isMeaningful(_ unit: CGRect, imageWidth: Int, imageHeight: Int) -> Bool {
        unit.width * CGFloat(imageWidth) >= minimumSelectionPixels
            && unit.height * CGFloat(imageHeight) >= minimumSelectionPixels
    }

    static func unit(_ rect: CGRect, in frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - frame.minX) / frame.width, y: (rect.minY - frame.minY) / frame.height,
                      width: rect.width / frame.width, height: rect.height / frame.height)
    }

    static func viewRect(_ unit: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + unit.minX * frame.width, y: frame.minY + unit.minY * frame.height,
               width: unit.width * frame.width, height: unit.height * frame.height)
    }

    /// Whole pixels covered by a unit rectangle, at least one pixel and never outside the picture.
    static func pixelRect(_ unit: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let width = CGFloat(max(1, imageWidth)), height = CGFloat(max(1, imageHeight))
        let minX = min(max(0, (unit.minX * width).rounded(.down)), width - 1)
        let minY = min(max(0, (unit.minY * height).rounded(.down)), height - 1)
        let maxX = min(width, max(minX + 1, (unit.maxX * width).rounded(.up)))
        let maxY = min(height, max(minY + 1, (unit.maxY * height).rounded(.up)))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Magnifier

    /// Where the magnifier sits for a touch: above the finger, or below it near the top edge,
    /// and never past the left or right edge of the container.
    static func magnifierCenter(for touch: CGPoint, in container: CGSize, diameter: CGFloat, gap: CGFloat) -> CGPoint {
        let radius = diameter / 2
        let above = touch.y - gap - radius
        let y = above - radius >= 0 ? above : touch.y + gap + radius
        let x = min(max(touch.x, radius), max(radius, container.width - radius))
        return CGPoint(x: x, y: y)
    }

    /// How much the magnifier enlarges the picture as shown. At least `minimum`, and enough to
    /// show the screen at its real size when the picture is shrunk to fit a narrow window.
    static func magnification(displayedWidth: CGFloat, imagePointWidth: CGFloat,
                              minimum: CGFloat = 2, maximum: CGFloat = 4) -> CGFloat {
        guard displayedWidth > 0, imagePointWidth > 0 else { return minimum }
        return min(maximum, max(minimum, imagePointWidth / displayedWidth))
    }

    /// Where the enlarged picture's top-left corner goes, relative to the magnifier's top-left
    /// corner, so that the touched point appears in the middle of the magnifier.
    static func magnifiedOrigin(touch: CGPoint, frame: CGRect, magnification: CGFloat, diameter: CGFloat) -> CGPoint {
        CGPoint(x: diameter / 2 - (touch.x - frame.minX) * magnification,
                y: diameter / 2 - (touch.y - frame.minY) * magnification)
    }

    private static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }
}
