import Cocoa

enum QuickTerminalPosition : String {
    case top
    case bottom
    case left
    case right
    case center

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
            finalSize.height = screen.frame.height
            
        case .center:
            break
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
            return .init(x: -window.frame.width, y: 0)

        case .right:
            return .init(x: screen.frame.maxX, y: 0)

        case .center:
            return .init(x: (screen.visibleFrame.maxX - window.frame.width) / 2, y: screen.visibleFrame.maxY - window.frame.width)
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
            return .init(x: (screen.visibleFrame.maxX - window.frame.width) / 2, y: (screen.visibleFrame.maxY - window.frame.height) / 2)
        }
    }
}
