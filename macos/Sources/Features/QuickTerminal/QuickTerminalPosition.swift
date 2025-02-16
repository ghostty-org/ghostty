import Cocoa

enum QuickTerminalPosition : String {
    case top
    case bottom
    case left
    case right
    case center

    /// Set the loaded state for a window.
    func setLoaded(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        switch (self) {
        case .top, .bottom:
            window.setFrame(.init(
                origin: window.frame.origin,
                size: .init(
                    width: screen.frame.width,
                    height: screen.frame.height / 4)
            ), display: false)

        case .left, .right:
            window.setFrame(.init(
                origin: window.frame.origin,
                size: .init(
                    width: screen.frame.width / 4,
                    height: screen.frame.height)
            ), display: false)

        case .center:
            window.setFrame(.init(
                origin: window.frame.origin,
                size: .init(
                    width: screen.frame.width / 2,
                    height: screen.frame.height / 3)
            ), display: false)
        }
    }

    /// Set the initial state for a window for animating out of this position.
    func setInitial(in window: NSWindow, on screen: NSScreen) {
        // We always start invisible
        window.alphaValue = 0

        // Position depends
        window.setFrame(.init(
            origin: initialOrigin(for: window, on: screen),
            size: restrictFrameSize(window.frame.size, on: screen)
        ), display: false)
    }

    /// Set the final state for a window in this position.
    func setFinal(in window: NSWindow, on screen: NSScreen) {
        // We always end visible
        window.alphaValue = 1

        // Position depends
        window.setFrame(.init(
            origin: finalOrigin(for: window, on: screen),
            size: restrictFrameSize(window.frame.size, on: screen)
        ), display: true)
    }

    /// Restrict the frame size during resizing.
    func restrictFrameSize(_ size: NSSize, on screen: NSScreen) -> NSSize {
        var finalSize = size
        switch (self) {
        case .top, .bottom:
            finalSize.width = screen.frame.width

        case .left, .right:
            finalSize.height = screen.visibleFrame.height

        case .center:
            finalSize.width = screen.frame.width / 2
            finalSize.height = screen.frame.height / 3
        }

        return finalSize
    }

    /// The initial point origin for this position.
    func initialOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        switch (self) {
        case .top:
            return .init(x: screen.frame.minX, y: screen.frame.maxY)

        case .bottom:
            return .init(x: screen.frame.minX, y: -window.frame.height)

        case .left:
            return .init(x: screen.frame.minX-window.frame.width, y: 0)

        case .right:
            return .init(x: screen.frame.maxX, y: 0)

        case .center:
            return .init(x: screen.visibleFrame.origin.x + (screen.visibleFrame.width - window.frame.width) / 2, y:  screen.visibleFrame.height - window.frame.width)
        }
    }

    /// The final point origin for this position.
    func finalOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        switch (self) {
        case .top:
            return .init(x: screen.frame.minX, y: screen.visibleFrame.maxY - window.frame.height)

        case .bottom:
            return .init(x: screen.frame.minX, y: screen.frame.minY)

        case .left:
            return .init(x: screen.frame.minX, y: window.frame.origin.y)

        case .right:
            return .init(x: screen.visibleFrame.maxX - window.frame.width, y: window.frame.origin.y)

        case .center:
            return .init(x: screen.visibleFrame.origin.x + (screen.visibleFrame.width - window.frame.width) / 2, y: screen.visibleFrame.origin.y + (screen.visibleFrame.height - window.frame.height) / 2)
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
}
