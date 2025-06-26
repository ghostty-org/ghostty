import Cocoa

enum QuickTerminalPosition : String {
    case top
    case bottom
    case left
    case right
    case center

    /// Set the loaded state for a window.
    func setLoaded(_ window: NSWindow, size: QuickTerminalSize) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let dimensions = size.calculate(position: self, screenDimensions: screen.frame.size)
        window.setFrame(.init(
            origin: window.frame.origin,
            size: .init(
                width: dimensions.width,
                height: dimensions.height)
        ), display: false)
    }

    /// Set the initial state for a window for animating out of this position.
    func setInitial(in window: NSWindow, on screen: NSScreen, terminalSize: QuickTerminalSize, preserveSize: NSSize? = nil) {
        // We always start invisible
        window.alphaValue = 0

        // Position depends
        window.setFrame(.init(
            origin: initialOrigin(for: window, on: screen),
            size: configuredFrameSize(on: screen, terminalSize: terminalSize, preserveExisting: preserveSize)
        ), display: false)
    }

    /// Set the final state for a window in this position.
    func setFinal(in window: NSWindow, on screen: NSScreen, terminalSize: QuickTerminalSize, preserveSize: NSSize? = nil) {
        // We always end visible
        window.alphaValue = 1

        // Position depends
        window.setFrame(.init(
            origin: finalOrigin(for: window, on: screen),
            size: configuredFrameSize(on: screen, terminalSize: terminalSize, preserveExisting: preserveSize)
        ), display: true)
    }

    /// Get the configured frame size for initial positioning and animations.
    func configuredFrameSize(on screen: NSScreen, terminalSize: QuickTerminalSize, preserveExisting: NSSize? = nil) -> NSSize {
        // If we have existing dimensions from manual resizing, preserve them
        if let existing = preserveExisting, existing.width > 0 && existing.height > 0 {
            return existing
        }
        
        let dimensions = terminalSize.calculate(position: self, screenDimensions: screen.frame.size)
        return NSSize(width: dimensions.width, height: dimensions.height)
    }

    /// The initial point origin for this position.
    func initialOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        switch (self) {
        case .top:
            return .init(x: round(screen.frame.origin.x + (screen.frame.width - window.frame.width) / 2), y: screen.frame.maxY)

        case .bottom:
            return .init(x: round(screen.frame.origin.x + (screen.frame.width - window.frame.width) / 2), y: -window.frame.height)

        case .left:
            return .init(x: screen.frame.minX-window.frame.width, y: round(screen.frame.origin.y + (screen.frame.height - window.frame.height) / 2))

        case .right:
            return .init(x: screen.frame.maxX, y: round(screen.frame.origin.y + (screen.frame.height - window.frame.height) / 2))

        case .center:
            return .init(x: round(screen.visibleFrame.origin.x + (screen.visibleFrame.width - window.frame.width) / 2), y:  screen.visibleFrame.height - window.frame.width)
        }
    }

    /// The final point origin for this position.
    func finalOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        switch (self) {
        case .top:
            return .init(x: round(screen.frame.origin.x + (screen.frame.width - window.frame.width) / 2), y: screen.visibleFrame.maxY - window.frame.height)

        case .bottom:
            return .init(x: round(screen.frame.origin.x + (screen.frame.width - window.frame.width) / 2), y: screen.frame.minY)

        case .left:
            return .init(x: screen.frame.minX, y: round(screen.frame.origin.y + (screen.frame.height - window.frame.height) / 2))

        case .right:
            return .init(x: screen.visibleFrame.maxX - window.frame.width, y: round(screen.frame.origin.y + (screen.frame.height - window.frame.height) / 2))

        case .center:
            return .init(x: round(screen.visibleFrame.origin.x + (screen.visibleFrame.width - window.frame.width) / 2), y: round(screen.visibleFrame.origin.y + (screen.visibleFrame.height - window.frame.height) / 2))
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
        return switch (orientation) {
        case .top: self == .top || self == .left || self == .right
        case .bottom: self == .bottom || self == .left || self == .right
        case .left: self == .top || self == .bottom
        case .right: self == .top || self == .bottom
        }
    }

    /// Calculate the centered origin for a window, keeping it properly positioned after manual resizing
    func centeredOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        switch self {
        case .top:
            return CGPoint(
                x: round(screen.frame.origin.x + (screen.frame.width - window.frame.width) / 2),
                y: window.frame.origin.y // Keep the same Y position
            )
            
        case .bottom:
            return CGPoint(
                x: round(screen.frame.origin.x + (screen.frame.width - window.frame.width) / 2),
                y: window.frame.origin.y // Keep the same Y position
            )
            
        case .center:
            return CGPoint(
                x: round(screen.visibleFrame.origin.x + (screen.visibleFrame.width - window.frame.width) / 2),
                y: round(screen.visibleFrame.origin.y + (screen.visibleFrame.height - window.frame.height) / 2)
            )
            
        case .left, .right:
            // For left/right positions, only adjust horizontal centering if needed
            return window.frame.origin
        }
    }
    
    /// Calculate the vertically centered origin for side-positioned windows
    func verticallyCenteredOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        switch self {
        case .left:
            return CGPoint(
                x: window.frame.origin.x, // Keep the same X position
                y: round(screen.frame.origin.y + (screen.frame.height - window.frame.height) / 2)
            )
            
        case .right:
            return CGPoint(
                x: window.frame.origin.x, // Keep the same X position
                y: round(screen.frame.origin.y + (screen.frame.height - window.frame.height) / 2)
            )
            
        case .top, .bottom, .center:
            // These positions don't need vertical recentering during resize
            return window.frame.origin
        }
    }
}
