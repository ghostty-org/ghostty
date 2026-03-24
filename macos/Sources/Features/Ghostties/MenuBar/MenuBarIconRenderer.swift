import AppKit

/// Renders the menu bar icon: a small ghost silhouette with an optional status dot.
///
/// The ghost is drawn as a template image (respects light/dark menu bar automatically).
/// The status dot is drawn with an explicit color so it stands out regardless of
/// the system appearance.
enum MenuBarIconRenderer {
    /// The size of the menu bar icon in points.
    static let iconSize = NSSize(width: 18, height: 18)

    /// Render a composite menu bar icon for the given aggregate indicator state.
    ///
    /// - Parameter state: The highest-priority indicator state across all sessions,
    ///   or `nil` if there are no active sessions.
    /// - Returns: An `NSImage` suitable for `NSStatusBarButton.image`.
    static func renderIcon(state: SessionIndicatorState?) -> NSImage {
        let image = NSImage(size: iconSize, flipped: false) { rect in
            // Draw the ghost silhouette as a template-compatible shape.
            drawGhostSilhouette(in: rect)

            // Draw the status dot overlay if there's a meaningful state.
            if let color = dotColor(for: state) {
                drawStatusDot(in: rect, color: color)
            }

            return true
        }

        // Mark as template so macOS tints the ghost shape for the menu bar.
        // The status dot uses explicit colors via drawStatusDot, which draws
        // into a non-template sub-layer (the NSImage drawing block handles both).
        image.isTemplate = false
        return image
    }

    /// Compute the aggregate indicator state from a dictionary of per-session states.
    ///
    /// Returns the highest-priority state (using `SessionIndicatorState`'s Comparable
    /// conformance), or `nil` if the dictionary is empty or all states are inactive.
    static func aggregateState(from states: [UUID: SessionIndicatorState]) -> SessionIndicatorState? {
        let active = states.values.filter { $0 != .inactive }
        guard let max = active.max() else { return nil }
        return max
    }

    // MARK: - Private

    /// Draw a simple ghost silhouette using NSBezierPath.
    ///
    /// The shape is a recognizable ghost: rounded dome top, straight sides,
    /// wavy bottom edge with three bumps, and two circular eyes.
    /// Drawn in the current graphics context fill color (black for template images).
    private static func drawGhostSilhouette(in rect: NSRect) {
        // Inset slightly to leave room for the status dot at bottom-right.
        let ghostRect = NSRect(x: rect.minX + 1, y: rect.minY + 2, width: 14, height: 15)
        let w = ghostRect.width
        let h = ghostRect.height
        let x = ghostRect.minX
        let y = ghostRect.minY

        let path = NSBezierPath()

        // Start at bottom-left, draw wavy bottom edge.
        path.move(to: NSPoint(x: x, y: y))

        // Three wave bumps along the bottom.
        let bumpW = w / 3
        path.curve(to: NSPoint(x: x + bumpW, y: y),
                   controlPoint1: NSPoint(x: x + bumpW * 0.25, y: y + h * 0.15),
                   controlPoint2: NSPoint(x: x + bumpW * 0.75, y: y + h * 0.15))

        path.curve(to: NSPoint(x: x + bumpW * 2, y: y),
                   controlPoint1: NSPoint(x: x + bumpW * 1.25, y: y - h * 0.08),
                   controlPoint2: NSPoint(x: x + bumpW * 1.75, y: y - h * 0.08))

        path.curve(to: NSPoint(x: x + w, y: y),
                   controlPoint1: NSPoint(x: x + bumpW * 2.25, y: y + h * 0.15),
                   controlPoint2: NSPoint(x: x + bumpW * 2.75, y: y + h * 0.15))

        // Right side straight up to the dome.
        path.line(to: NSPoint(x: x + w, y: y + h * 0.45))

        // Dome: semicircular top.
        path.curve(to: NSPoint(x: x, y: y + h * 0.45),
                   controlPoint1: NSPoint(x: x + w, y: y + h),
                   controlPoint2: NSPoint(x: x, y: y + h))

        // Left side back down to start.
        path.close()

        // Fill the ghost body. Use label color for menu bar visibility.
        NSColor.labelColor.setFill()
        path.fill()

        // Draw eyes as cutouts from the ghost body by filling with clear color
        // using .copy compositing, which replaces pixels instead of blending.
        let eyeRadius: CGFloat = 1.5
        let eyeY = y + h * 0.55
        let leftEyeX = x + w * 0.3
        let rightEyeX = x + w * 0.7

        let savedOperation = NSGraphicsContext.current?.compositingOperation
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.clear.setFill()

        let leftEye = NSBezierPath(ovalIn: NSRect(
            x: leftEyeX - eyeRadius,
            y: eyeY - eyeRadius,
            width: eyeRadius * 2,
            height: eyeRadius * 2
        ))
        leftEye.fill()

        let rightEye = NSBezierPath(ovalIn: NSRect(
            x: rightEyeX - eyeRadius,
            y: eyeY - eyeRadius,
            width: eyeRadius * 2,
            height: eyeRadius * 2
        ))
        rightEye.fill()

        // Restore previous compositing operation.
        if let savedOperation {
            NSGraphicsContext.current?.compositingOperation = savedOperation
        }
    }

    /// Draw a small filled circle at the bottom-right of the icon.
    private static func drawStatusDot(in rect: NSRect, color: NSColor) {
        let dotDiameter: CGFloat = 5
        let dotRect = NSRect(
            x: rect.maxX - dotDiameter - 0.5,
            y: rect.minY + 0.5,
            width: dotDiameter,
            height: dotDiameter
        )

        // White outline for contrast against any menu bar background.
        let outlinePath = NSBezierPath(ovalIn: dotRect.insetBy(dx: -0.5, dy: -0.5))
        NSColor.white.setFill()
        outlinePath.fill()

        // Colored dot.
        let dotPath = NSBezierPath(ovalIn: dotRect)
        color.setFill()
        dotPath.fill()
    }

    /// Map an indicator state to its dot color, or `nil` for no dot.
    private static func dotColor(for state: SessionIndicatorState?) -> NSColor? {
        guard let state else { return nil }
        switch state {
        case .error:          return .systemRed
        case .needsAttention: return NSColor(red: 0.659, green: 0.333, blue: 0.969, alpha: 1) // #A855F7
        case .waiting:        return NSColor(red: 0.788, green: 0.451, blue: 0.314, alpha: 1) // #C97350
        case .longRunning:    return .systemYellow
        case .processing:     return .systemGreen
        case .idle:           return NSColor.labelColor.withAlphaComponent(0.3)
        case .inactive:       return nil
        }
    }
}
