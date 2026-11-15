import CoreGraphics
import Foundation

/// Geometry for choosing a part of a picture by dragging. All functions are pure.
/// A "unit" rectangle is in the picture's own space, 0...1 on both axes, origin top-left.
enum CropGeometry {
    enum DragMode: Equatable {
        /// Start a new selection from the touched point.
        case new
        /// Move the existing selection.
        case move
        /// Resize the existing selection, keeping the opposite corner in place.
        case resize(anchor: CGPoint)
    }

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

    /// `rect` shifted by `translation`, stopped at the edges of `bounds` without changing its size.
    static func moved(_ rect: CGRect, by translation: CGSize, within bounds: CGRect) -> CGRect {
        var result = rect.offsetBy(dx: translation.width, dy: translation.height)
        result.origin.x = min(max(result.origin.x, bounds.minX), max(bounds.minX, bounds.maxX - result.width))
        result.origin.y = min(max(result.origin.y, bounds.minY), max(bounds.minY, bounds.maxY - result.height))
        return result
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

    /// What a drag that starts at `point` should do, given the current selection in view coordinates.
    static func dragMode(at point: CGPoint, selection: CGRect?, handleRadius: CGFloat = 28) -> DragMode {
        guard let selection, selection.width > 0, selection.height > 0 else { return .new }
        let corners = [
            (CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.maxY)),
            (CGPoint(x: selection.maxX, y: selection.minY), CGPoint(x: selection.minX, y: selection.maxY)),
            (CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.minY)),
            (CGPoint(x: selection.maxX, y: selection.maxY), CGPoint(x: selection.minX, y: selection.minY)),
        ]
        var nearest: (distance: CGFloat, anchor: CGPoint)?
        for (corner, opposite) in corners {
            let distance = hypot(point.x - corner.x, point.y - corner.y)
            if distance <= handleRadius, distance < (nearest?.distance ?? .greatestFiniteMagnitude) {
                nearest = (distance, opposite)
            }
        }
        if let nearest { return .resize(anchor: nearest.anchor) }
        return selection.contains(point) ? .move : .new
    }

    private static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }
}
