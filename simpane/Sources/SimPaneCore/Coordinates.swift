//  View geometry -> normalized device coordinates.
//
//  Pure functions, no AppKit state, so they can be unit-tested without a
//  simulator. Indigo wants 0...1 from the TOP-LEFT of the device screen.

import CoreGraphics

public enum Coordinates {

    /// The aspect-fit rect the device screen occupies inside `bounds`. Whatever
    /// is left over is letterbox and must not be treated as screen.
    public static func contentRect(bounds: CGRect, devicePixels: CGSize) -> CGRect {
        guard devicePixels.width > 0, devicePixels.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }

        let scale = min(bounds.width / devicePixels.width, bounds.height / devicePixels.height)
        let size = CGSize(width: devicePixels.width * scale, height: devicePixels.height * scale)
        return CGRect(
            x: bounds.minX + (bounds.width - size.width) / 2,
            y: bounds.minY + (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height)
    }

    /// Normalized device coordinates for a point in view space, or nil when the
    /// point is in the letterbox.
    ///
    /// `viewIsFlipped` describes the incoming point's origin: AppKit views are
    /// bottom-left by default, while Indigo is top-left.
    public static func normalized(
        viewPoint: CGPoint,
        bounds: CGRect,
        devicePixels: CGSize,
        viewIsFlipped: Bool
    ) -> CGPoint? {
        let content = contentRect(bounds: bounds, devicePixels: devicePixels)
        guard content.width > 0, content.height > 0 else { return nil }
        guard content.contains(viewPoint) else { return nil }

        let x = (viewPoint.x - content.minX) / content.width
        let yFromTop = viewIsFlipped
            ? (viewPoint.y - content.minY) / content.height
            : (content.maxY - viewPoint.y) / content.height
        return CGPoint(x: x, y: yFromTop)
    }

    /// Same mapping but clamped rather than rejected. Used mid-drag, where a
    /// finger that slides past the edge should track the edge instead of
    /// dropping the gesture.
    public static func normalizedClamped(
        viewPoint: CGPoint,
        bounds: CGRect,
        devicePixels: CGSize,
        viewIsFlipped: Bool
    ) -> CGPoint {
        let content = contentRect(bounds: bounds, devicePixels: devicePixels)
        guard content.width > 0, content.height > 0 else { return .zero }

        let x = (viewPoint.x - content.minX) / content.width
        let yFromTop = viewIsFlipped
            ? (viewPoint.y - content.minY) / content.height
            : (content.maxY - viewPoint.y) / content.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(yFromTop, 0), 1))
    }
}
