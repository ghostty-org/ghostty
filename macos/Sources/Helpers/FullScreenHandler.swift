import SwiftUI
import GhosttyKit

class FullScreenHandler {
    var previousTabGroup: NSWindowTabGroup?
    var previousTabGroupIndex: Int?
    var previousContentFrame: NSRect?
    var previousStyleMask: NSWindow.StyleMask? = nil

    // We keep track of whether we entered non-native fullscreen in case
    // a user goes to fullscreen, changes the config to disable non-native fullscreen
    // and then wants to toggle it off
    var isInNonNativeFullscreen: Bool = false
    var isInFullscreen: Bool = false

    func toggleFullscreen(window: NSWindow, mode: ghostty_action_fullscreen_e) {
        let useNonNativeFullscreen = switch (mode) {
        case GHOSTTY_FULLSCREEN_NATIVE:
            false

        case GHOSTTY_FULLSCREEN_NON_NATIVE, GHOSTTY_FULLSCREEN_NON_NATIVE_VISIBLE_MENU:
            true

        default:
            false
        }

        if isInFullscreen {
            if useNonNativeFullscreen || isInNonNativeFullscreen {
                leaveFullscreen(window: window)
                isInNonNativeFullscreen = false
            } else {
                // Restore titlebar separator style. See below for explanation.
                window.titlebarSeparatorStyle = .automatic
                window.toggleFullScreen(nil)
            }
            isInFullscreen = false
        } else {
            if useNonNativeFullscreen {
                let hideMenu = mode != GHOSTTY_FULLSCREEN_NON_NATIVE_VISIBLE_MENU
                enterFullscreen(window: window, hideMenu: hideMenu)
                isInNonNativeFullscreen = true
            } else {
                // The titlebar separator shows up erroneously in fullscreen if the tab bar
                // is made to appear and then disappear by opening and then closing a tab.
                // We get rid of the separator while in fullscreen to prevent this.
                window.titlebarSeparatorStyle = .none
                window.toggleFullScreen(nil)
            }
            isInFullscreen = true
        }
    }

    func enterFullscreen(window: NSWindow, hideMenu: Bool) {
        guard let screen = window.screen else { return }
        guard let contentView = window.contentView else { return }

        previousTabGroup = window.tabGroup
        previousTabGroupIndex = window.tabGroup?.windows.firstIndex(of: window)

        // Save previous contentViewFrame and screen
        previousContentFrame = window.convertToScreen(contentView.frame)

        // Change presentation style to hide menu bar and dock if needed
        // It's important to do this in two calls, because setting them in a single call guarantees
        // that the menu bar will also be hidden on any additional displays (why? nobody knows!)
        // When these options are set separately, the menu bar hiding problem will only occur in
        // specific scenarios. More investigation is needed to pin these scenarios down precisely,
        // but it seems to have something to do with which app had focus last.
        // Furthermore, it's much easier to figure out which screen the dock is on if the menubar
        // has not yet been hidden, so the order matters here!
        if (shouldHideDock(screen: screen)) {
            self.hideDock()

            // Ensure that we always hide the dock bar for this window, but not for non fullscreen ones
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(FullScreenHandler.hideDock),
                name: NSWindow.didBecomeMainNotification,
                object: window)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(FullScreenHandler.unHideDock),
                name: NSWindow.didResignMainNotification,
                object: window)
        }
        if (hideMenu) {
            self.hideMenu()

            // Ensure that we always hide the menu bar for this window, but not for non fullscreen ones
            // This is not the best way to do this, not least because it causes the menu to stay visible
            // for a brief moment before being hidden in some cases (e.g. when switching spaces).
            // If we end up adding a NSWindowDelegate to PrimaryWindow, then we may be better off
            // handling this there.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(FullScreenHandler.hideMenu),
                name: NSWindow.didBecomeMainNotification,
                object: window)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(FullScreenHandler.onDidResignMain),
                name: NSWindow.didResignMainNotification,
                object: window)
        }

        // This is important: it gives us the full screen, including the
        // notch area on MacBooks.
        self.previousStyleMask = window.styleMask
        window.styleMask.remove(.titled)

        // Set frame to screen size, accounting for the menu bar if needed
        let windowHasTabs = previousTabGroup?.windows.isEmpty == false
        let frame = calculateFullscreenFrame(screen: screen, subtractMenu: !hideMenu, windowHasTabs: windowHasTabs)
        window.setFrame(frame, display: true)

        // Focus window
        window.makeKeyAndOrderFront(nil)
    }

    @objc func hideMenu() {
        NSApp.presentationOptions.insert(.autoHideMenuBar)
    }

    @objc func onDidResignMain(_ notification: Notification) {
        guard let resigningWindow = notification.object as? NSWindow else { return }
        guard let mainWindow = NSApplication.shared.mainWindow else { return }

        // We're only unhiding the menu bar, if the focus shifted within our application.
        // In that case, `mainWindow` is the window of our application the focus shifted
        // to.
        if !resigningWindow.isEqual(mainWindow) {
            NSApp.presentationOptions.remove(.autoHideMenuBar)
        }
    }

    @objc func hideDock() {
        NSApp.presentationOptions.insert(.autoHideDock)
    }

    @objc func unHideDock() {
        NSApp.presentationOptions.remove(.autoHideDock)
    }

    func calculateFullscreenFrame(screen: NSScreen, subtractMenu: Bool, windowHasTabs: Bool)->NSRect {
        let hasNotch = screen.safeAreaInsets.top > 0

        if (subtractMenu) {
            if let menuHeight = NSApp.mainMenu?.menuBarHeight {
                var padding: CGFloat = 0

                // Detect the notch. If there is a safe area on top it includes the
                // menu height as a safe area so we also subtract that from it.
                if (hasNotch) {
                    padding = screen.safeAreaInsets.top - menuHeight;
                }

                return NSMakeRect(
                    screen.frame.minX,
                    screen.frame.minY,
                    screen.frame.width,
                    screen.frame.height - (menuHeight + padding)
                )
            }
        }

        if (windowHasTabs && !hasNotch) {
            // TODO: Figure out a proper way to get to the tabBarHeight
            let tabBarHeight: CGFloat = 28;
            return NSMakeRect(
                screen.frame.minX,
                screen.frame.minY - tabBarHeight,
                screen.frame.width,
                screen.frame.height
            )
        }
        return screen.frame
    }

    func leaveFullscreen(window: NSWindow) {
        guard let previousFrame = previousContentFrame else { return }

        // Restore the style mask
        window.styleMask = self.previousStyleMask!

        // Restore previous presentation options
        NSApp.presentationOptions = []

        // Stop handling any window focus notifications
        // that we use to manage menu bar visibility
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: window)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignMainNotification, object: window)

        // Restore frame
        window.setFrame(window.frameRect(forContentRect: previousFrame), display: true)

        // Have titlebar tabs set itself up again, since removing the titlebar when fullscreen breaks its constraints.
        if let window = window as? TerminalWindow, window.titlebarTabs {
            window.titlebarTabs = true
        }

        // If the window was previously in a tab group that isn't empty now, we re-add it
        if let group = previousTabGroup, let tabIndex = previousTabGroupIndex, !group.windows.isEmpty {
            var tabWindow: NSWindow?
            var order: NSWindow.OrderingMode = .below

            // Index of the window before `window`
            let tabIndexBefore = tabIndex-1
            if tabIndexBefore < 0 {
                // If we were the first tab, we add the window *before* (.below) the first one.
                tabWindow = group.windows.first
            } else if tabIndexBefore < group.windows.count {
                // If we weren't the first tab in the group, we add our window after
                // the tab that was before it.
                tabWindow = group.windows[tabIndexBefore]
                order = .above
            } else {
                // If index is after group, add it after last window
                tabWindow = group.windows.last
            }

            // Add the window
            tabWindow?.addTabbedWindow(window, ordered: order)
        }

        // Focus window
        window.makeKeyAndOrderFront(nil)
    }

    // We only want to hide the dock if it's not already going to be hidden automatically, and if
    // it's on the same display as the ghostty window that we want to make fullscreen.
    func shouldHideDock(screen: NSScreen) -> Bool {
        if let dockAutohide = UserDefaults.standard.persistentDomain(forName: "com.apple.dock")?["autohide"] as? Bool {
            if (dockAutohide) { return false }
        }

        // There is no public API to directly ask about dock visibility, so we have to figure it out
        // by comparing the sizes of visibleFrame (the currently usable area of the screen) and
        // frame (the full screen size). We also need to account for the menubar, any inset caused
        // by the notch on macbooks, and a little extra padding to compensate for the boundary area
        // which triggers showing the dock.
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuHeight = NSApp.mainMenu?.menuBarHeight ?? 0
        var notchInset = 0.0
        if #available(macOS 12, *) {
            notchInset = screen.safeAreaInsets.top
        }
        let boundaryAreaPadding = 5.0

        return visibleFrame.height < (frame.height - max(menuHeight, notchInset) - boundaryAreaPadding) || visibleFrame.width < frame.width
    }
}
