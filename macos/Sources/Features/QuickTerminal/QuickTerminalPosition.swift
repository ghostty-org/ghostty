import Cocoa

enum QuickTerminalPosition: String {
    case top
    case bottom
    case left
    case right
    case center

    /// Set the loaded state for a window. This should only be called when the window is first loaded,
    /// usually in `windowDidLoad` or in a similar callback. This is the initial state.
    func setLoaded(_ window: NSWindow, size: QuickTerminalSize, availableFrame: NSRect) {
        window.setFrame(.init(
            origin: window.frame.origin,
            size: size.calculate(position: self, screenDimensions: availableFrame.size)
        ), display: false)
    }

    /// Set the initial state for a window NOT yet into position (either before animating in or
    /// after animating out).
    func setInitial(
        in window: NSWindow,
        availableFrame: NSRect,
        terminalSize: QuickTerminalSize,
        closedFrame: NSRect? = nil
    ) {
        // Invisible
        window.alphaValue = 0

        // Position depends
        window.setFrame(.init(
            origin: initialOrigin(for: window, availableFrame: availableFrame),
            size: closedFrame?.size ?? configuredFrameSize(
                for: availableFrame,
                terminalSize: terminalSize)
        ), display: false)
    }

    /// Set the final state for a window in this position.
    func setFinal(
        in window: NSWindow,
        availableFrame: NSRect,
        terminalSize: QuickTerminalSize,
        closedFrame: NSRect? = nil
    ) {
        // We always end visible
        window.alphaValue = 1

        // Position depends
        window.setFrame(.init(
            origin: finalOrigin(for: window, availableFrame: availableFrame),
            size: closedFrame?.size ?? configuredFrameSize(
                for: availableFrame,
                terminalSize: terminalSize)
        ), display: true)
    }

    /// Get the configured frame size for initial positioning and animations.
    func configuredFrameSize(for availableFrame: NSRect, terminalSize: QuickTerminalSize) -> NSSize {
        let dimensions = terminalSize.calculate(position: self, screenDimensions: availableFrame.size)
        return NSSize(width: dimensions.width, height: dimensions.height)
    }

    /// The initial point origin for this position.
    func initialOrigin(for window: NSWindow, availableFrame: NSRect) -> CGPoint {
        switch self {
        case .top:
            return .init(
                x: round(availableFrame.origin.x + (availableFrame.width - window.frame.width) / 2),
                y: availableFrame.maxY)

        case .bottom:
            return .init(
                x: round(availableFrame.origin.x + (availableFrame.width - window.frame.width) / 2),
                y: -window.frame.height)

        case .left:
            return .init(
                x: availableFrame.minX - window.frame.width,
                y: round(availableFrame.origin.y + (availableFrame.height - window.frame.height) / 2))

        case .right:
            return .init(
                x: availableFrame.maxX,
                y: round(availableFrame.origin.y + (availableFrame.height - window.frame.height) / 2))

        case .center:
            return .init(x: round(availableFrame.origin.x + (availableFrame.width - window.frame.width) / 2), y: availableFrame.height - window.frame.width)
        }
    }

    /// The final point origin for this position.
    func finalOrigin(for window: NSWindow, availableFrame: NSRect) -> CGPoint {
        switch self {
        case .top:
            return .init(
                x: round(availableFrame.origin.x + (availableFrame.width - window.frame.width) / 2),
                y: availableFrame.maxY - window.frame.height)

        case .bottom:
            return .init(
                x: round(availableFrame.origin.x + (availableFrame.width - window.frame.width) / 2),
                y: availableFrame.minY)

        case .left:
            return .init(
                x: availableFrame.minX,
                y: round(availableFrame.origin.y + (availableFrame.height - window.frame.height) / 2))

        case .right:
            return .init(
                x: availableFrame.maxX - window.frame.width,
                y: round(availableFrame.origin.y + (availableFrame.height - window.frame.height) / 2))

        case .center:
            return .init(x: round(availableFrame.origin.x + (availableFrame.width - window.frame.width) / 2), y: round(availableFrame.origin.y + (availableFrame.height - window.frame.height) / 2))
        }
    }

    func conflictsWithDock(on screen: NSScreen) -> Bool {
        // Screen must have a dock for it to conflict
        guard screen.hasDock else { return false }

        // Get the dock orientation for this screen
        guard let orientation = Dock.orientation else { return false }

        // Depending on the orientation of the dock, we conflict if our quick terminal
        // would potentially "hit" the dock. In the future we should probably consider
        // the frame of the quick terminal.
        return switch orientation {
        case .top: self == .top || self == .left || self == .right
        case .bottom: self == .bottom || self == .left || self == .right
        case .left: self == .top || self == .bottom
        case .right: self == .top || self == .bottom
        }
    }

    /// Calculate the centered origin for a window, keeping it properly positioned after manual resizing
    func centeredOrigin(for window: NSWindow, availableFrame: NSRect) -> CGPoint {
        switch self {
        case .top:
            return CGPoint(
                x: round(availableFrame.origin.x + (availableFrame.width - window.frame.width) / 2),
                y: window.frame.origin.y // Keep the same Y position
            )

        case .bottom:
            return CGPoint(
                x: round(availableFrame.origin.x + (availableFrame.width - window.frame.width) / 2),
                y: window.frame.origin.y // Keep the same Y position
            )

        case .center:
            return CGPoint(
                x: round(availableFrame.origin.x + (availableFrame.width - window.frame.width) / 2),
                y: round(availableFrame.origin.y + (availableFrame.height - window.frame.height) / 2)
            )

        case .left, .right:
            // For left/right positions, only adjust horizontal centering if needed
            return window.frame.origin
        }
    }

    /// Calculate the vertically centered origin for side-positioned windows
    func verticallyCenteredOrigin(for window: NSWindow, availableFrame: NSRect) -> CGPoint {
        switch self {
        case .left:
            return CGPoint(
                x: window.frame.origin.x, // Keep the same X position
                y: round(availableFrame.origin.y + (availableFrame.height - window.frame.height) / 2)
            )

        case .right:
            return CGPoint(
                x: window.frame.origin.x, // Keep the same X position
                y: round(availableFrame.origin.y + (availableFrame.height - window.frame.height) / 2)
            )

        case .top, .bottom, .center:
            // These positions don't need vertical recentering during resize
            return window.frame.origin
        }
    }
}
