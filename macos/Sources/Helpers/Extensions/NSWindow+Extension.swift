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
}
