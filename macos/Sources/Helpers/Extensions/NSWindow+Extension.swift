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

// MARK: Native Tabbing

extension NSWindow {
    /// True if this is the first window in the tab group.
    var isFirstWindowInTabGroup: Bool {
        guard let firstWindow = tabGroup?.windows.first else { return true }
        return firstWindow === self
    }

    /// Wraps `addTabbedWindow` with an Objective-C exception catcher because AppKit can
    /// throw NSExceptions in visual tab picker flows. Swift cannot safely recover from
    /// those exceptions, so we route through Obj-C and log a recoverable failure.
    @discardableResult
    func addTabbedWindowSafely(
        _ child: NSWindow,
        ordered: NSWindow.OrderingMode
    ) -> Bool {
        var error: NSError?
        let success = GhosttyAddTabbedWindowSafely(self, child, ordered.rawValue, &error)
        if let error {
            Ghostty.logger.error("addTabbedWindow failed: \(error.localizedDescription)")
        }

        return success
    }
}

/// Native tabbing private API usage. :(
extension NSWindow {
    var titlebarView: NSView? {
        // In normal window, `NSTabBar` typically appears as a subview of `NSTitlebarView` within `NSThemeFrame`.
        // In fullscreen, the system creates a dedicated fullscreen window and the view hierarchy changes;
        // in that case, the `titlebarView` is only accessible via a reference on `NSThemeFrame`.
        // ref: https://github.com/mozilla-firefox/firefox/blob/054e2b072785984455b3b59acad9444ba1eeffb4/widget/cocoa/nsCocoaWindow.mm#L7205
        guard let themeFrameView = contentView?.rootView else { return nil }
        guard themeFrameView.responds(to: Selector(("titlebarView"))) else { return nil }
        return themeFrameView.value(forKey: "titlebarView") as? NSView
    }

    /// Returns the [private] NSTabBar view, if it exists.
    var tabBarView: NSView? {
        titlebarView?.firstDescendant(withClassName: "NSTabBar")
    }

    /// Returns tab button views in visual order from left to right.
    func tabButtonsInVisualOrder() -> [NSView] {
        guard let tabBarView else { return [] }
        return tabBarView
            .descendants(withClassName: "NSTabButton")
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Returns the visual tab index and matching tab button at the given screen point.
    func tabButtonHit(atScreenPoint screenPoint: NSPoint) -> (index: Int, tabButton: NSView)? {
        guard let tabBarView else { return nil }
        let locationInWindow = convertPoint(fromScreen: screenPoint)
        let locationInTabBar = tabBarView.convert(locationInWindow, from: nil)
        guard tabBarView.bounds.contains(locationInTabBar) else { return nil }

        for (index, tabButton) in tabButtonsInVisualOrder().enumerated() {
            let locationInTabButton = tabButton.convert(locationInWindow, from: nil)
            if tabButton.bounds.contains(locationInTabButton) {
                return (index, tabButton)
            }
        }

        return nil
    }

    /// Returns the index of the tab button at the given screen point, if any.
    func tabIndex(atScreenPoint screenPoint: NSPoint) -> Int? {
        tabButtonHit(atScreenPoint: screenPoint)?.index
    }
}
