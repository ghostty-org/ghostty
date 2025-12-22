import AppKit

extension NSWindow {
    /// Get the CGWindowID type for the window (used for low level CoreGraphics APIs).
    var cgWindowId: CGWindowID? {
        // "If the window doesn’t have a window device, the value of this
        // property is equal to or less than 0." - Docs. In practice I've
        // found this is true if a window is not visible.
        guard windowNumber > 0 else { return nil }
        return CGWindowID(windowNumber)
    }

    /// True if this is the first window in the tab group.
    var isFirstWindowInTabGroup: Bool {
        guard let firstWindow = tabGroup?.windows.first else { return true }
        return firstWindow === self
    }

    /// Adjusts the window frame if necessary to ensure the window remains visible on screen.
    /// This constrains both the size (to not exceed the screen) and the origin (to keep the window on screen).
    func constrainToScreen() {
        guard let screen = screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        var windowFrame = frame

        windowFrame.size.width = min(windowFrame.size.width, visibleFrame.size.width)
        windowFrame.size.height = min(windowFrame.size.height, visibleFrame.size.height)

        windowFrame.origin.x = max(visibleFrame.minX,
            min(windowFrame.origin.x, visibleFrame.maxX - windowFrame.width))
        windowFrame.origin.y = max(visibleFrame.minY,
            min(windowFrame.origin.y, visibleFrame.maxY - windowFrame.height))

        if windowFrame != frame {
            setFrame(windowFrame, display: true)
        }
    }
}
