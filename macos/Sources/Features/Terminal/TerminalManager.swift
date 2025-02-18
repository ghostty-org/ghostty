import Cocoa
import SwiftUI
import GhosttyKit
import Combine

/// Manages a set of terminal windows. This is effectively an array of TerminalControllers.
/// This abstraction helps manage tabs and multi-window scenarios.
class TerminalManager {
    struct Window {
        let controller: TerminalController
        let closePublisher: AnyCancellable
    }

    let ghostty: Ghostty.App

    /// The currently focused surface of the main window.
    var focusedSurface: Ghostty.SurfaceView? { mainWindow?.controller.focusedSurface }

    /// The set of windows we currently have.
    var windows: [Window] = []

    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    private static var lastCascadePoint = NSPoint(x: 0, y: 0)

    /// Returns the main window of the managed window stack. If there is no window
    /// then an arbitrary window will be chosen.
    private var mainWindow: Window? {
        for window in windows {
            if (window.controller.window?.isMainWindow ?? false) {
                return window
            }
        }

        // If we have no main window, just use the last window.
        return windows.last
    }

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private var derivedConfig: DerivedConfig

    init(_ ghostty: Ghostty.App) {
        self.ghostty = ghostty
        self.derivedConfig = DerivedConfig(ghostty.config)

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onNewTab),
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onNewWindow),
            name: Ghostty.Notification.ghosttyNewWindow,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil)
    }

    deinit {
        let center = NotificationCenter.default
        center.removeObserver(self)
    }

    // MARK: - Window Management

    /// Create a new terminal window.
    func newWindow(withBaseConfig base: Ghostty.SurfaceConfiguration? = nil) {
        let c = createWindow(withBaseConfig: base)
        let window = c.window!

        // If the previous focused window was native fullscreen, the new window also
        // becomes native fullscreen.
        if let parent = focusedSurface?.window,
            parent.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else if derivedConfig.windowFullscreen {
            switch (derivedConfig.windowFullscreenMode) {
            case .native:
                // Native has to be done immediately so that our stylemask contains
                // fullscreen for the logic later in this method.
                c.toggleFullscreen(mode: .native)

            case .nonNative, .nonNativeVisibleMenu, .nonNativePaddedNotch:
                // If we're non-native then we have to do it on a later loop
                // so that the content view is setup.
                DispatchQueue.main.async {
                    c.toggleFullscreen(mode: self.derivedConfig.windowFullscreenMode)
                }
            }
        }

        // If our app isn't active, we make it active. All new_window actions
        // force our app to be active.
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        // We're dispatching this async because otherwise the lastCascadePoint doesn't
        // take effect. Our best theory is there is some next-event-loop-tick logic
        // that Cocoa is doing that we need to be after.
        DispatchQueue.main.async {
            // Only cascade if we aren't fullscreen.
            if (!window.styleMask.contains(.fullScreen)) {
                Self.lastCascadePoint = window.cascadeTopLeft(from: Self.lastCascadePoint)
            }

            c.showWindow(self)
        }
    }

    /// Creates a new tab in the current main window. If there are no windows, a window
    /// is created.
    func newTab(withBaseConfig base: Ghostty.SurfaceConfiguration? = nil) {
        // If there is no main window, just create a new window
        guard let parent = mainWindow?.controller.window else {
            newWindow(withBaseConfig: base)
            return
        }

        // Create a new window and add it to the parent
        newTab(to: parent, withBaseConfig: base)
    }

    private func newTab(to parent: NSWindow, withBaseConfig base: Ghostty.SurfaceConfiguration?) {
        // If our parent is in non-native fullscreen, then new tabs do not work.
        // See: https://github.com/mitchellh/ghostty/issues/392
        if let controller = parent.windowController as? TerminalController,
           let fullscreenStyle = controller.fullscreenStyle,
           fullscreenStyle.isFullscreen && !fullscreenStyle.supportsTabs {
            let alert = NSAlert()
            alert.messageText = "Cannot Create New Tab"
            alert.informativeText = "New tabs are unsupported while in non-native fullscreen. Exit fullscreen and try again."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .warning
            alert.beginSheetModal(for: parent)
            return
        }

        // Create a new window and add it to the parent
        let controller = createWindow(withBaseConfig: base)
        let window = controller.window!

        // If the parent is miniaturized, then macOS exhibits really strange behaviors
        // so we have to bring it back out.
        if (parent.isMiniaturized) { parent.deminiaturize(self) }

        // If our parent tab group already has this window, macOS added it and
        // we need to remove it so we can set the correct order in the next line.
        // If we don't do this, macOS gets really confused and the tabbedWindows
        // state becomes incorrect.
        //
        // At the time of writing this code, the only known case this happens
        // is when the "+" button is clicked in the tab bar.
        if let tg = parent.tabGroup, tg.windows.firstIndex(of: window) != nil {
            tg.removeWindow(window)
        }

        // Our windows start out invisible. We need to make it visible. If we
        // don't do this then various features such as window blur won't work because
        // the macOS APIs only work on a visible window.
        controller.showWindow(self)

        // If we have the "hidden" titlebar style we want to create new
        // tabs as windows instead, so just skip adding it to the parent.
        if (derivedConfig.macosTitlebarStyle != "hidden") {
            // Add the window to the tab group and show it.
            switch derivedConfig.windowNewTabPosition {
            case "end":
                // If we already have a tab group and we want the new tab to open at the end,
                // then we use the last window in the tab group as the parent.
                if let last = parent.tabGroup?.windows.last {
                    last.addTabbedWindow(window, ordered: .above)
                } else {
                    fallthrough
                }
            case "current": fallthrough
            default:
                parent.addTabbedWindow(window, ordered: .above)

            }
        }

        window.makeKeyAndOrderFront(self)

        // It takes an event loop cycle until the macOS tabGroup state becomes
        // consistent which causes our tab labeling to be off when the "+" button
        // is used in the tab bar. This fixes that. If we can find a more robust
        // solution we should do that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { controller.relabelTabs() }
    }

    /// Creates a window controller, adds it to our managed list, and returns it.
    func createWindow(withBaseConfig base: Ghostty.SurfaceConfiguration? = nil,
                      withSurfaceTree tree: Ghostty.SplitNode? = nil) -> TerminalController {
        // Initialize our controller to load the window
        let c = TerminalController(ghostty, withBaseConfig: base, withSurfaceTree: tree)

        // Create a listener for when the window is closed so we can remove it.
        let pubClose = NotificationCenter.default.publisher(
            for: NSWindow.willCloseNotification,
            object: c.window!
        ).sink { notification in
            guard let window = notification.object as? NSWindow else { return }
            guard let c = window.windowController as? TerminalController else { return }
            self.removeWindow(c)
        }

        // Keep track of every window we manage
        windows.append(Window(
            controller: c,
            closePublisher: pubClose
        ))

        return c
    }

    func removeWindow(_ controller: TerminalController) {
        // Remove it from our managed set
        guard let idx = self.windows.firstIndex(where: { $0.controller == controller }) else { return }
        let w = self.windows[idx]
        self.windows.remove(at: idx)

        // Ensure any publishers we have are cancelled
        w.closePublisher.cancel()

        // If we remove a window, we reset the cascade point to the key window so that
        // the next window cascade's from that one.
        if let focusedWindow = NSApplication.shared.keyWindow {
            // If we are NOT the focused window, then we are a tabbed window. If we
            // are closing a tabbed window, we want to set the cascade point to be
            // the next cascade point from this window.
            if focusedWindow != controller.window {
                // The cascadeTopLeft call below should NOT move the window. Starting with
                // macOS 15, we found that specifically when used with the new window snapping
                // features of macOS 15, this WOULD move the frame. So we keep track of the
                // old frame and restore it if necessary. Issue:
                // https://github.com/ghostty-org/ghostty/issues/2565
                let oldFrame = focusedWindow.frame

                Self.lastCascadePoint = focusedWindow.cascadeTopLeft(from: NSZeroPoint)

                if focusedWindow.frame != oldFrame {
                    focusedWindow.setFrame(oldFrame, display: true)
                }

                return
            }

            // If we are the focused window, then we set the last cascade point to
            // our own frame so that it shows up in the same spot.
            let frame = focusedWindow.frame
            Self.lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        }

        // I don't think we strictly have to do this but if a window is
        // closed I want to make sure that the app state is invalided so
        // we don't reopen closed windows.
        NSApplication.shared.invalidateRestorableState()
    }

    /// Close all windows, asking for confirmation if necessary.
    func closeAllWindows() {
        var needsConfirm: Bool = false
        for w in self.windows {
            if (w.controller.surfaceTree?.needsConfirmQuit() ?? false) {
                needsConfirm = true
                break
            }
        }

        if (!needsConfirm) {
            for w in self.windows {
                w.controller.close()
            }

            return
        }

        // If we don't have a main window, we just close all windows because
        // we have no window to show the modal on top of. I'm sure there's a way
        // to do an app-level alert but I don't know how and this case should never
        // really happen.
        guard let alertWindow = mainWindow?.controller.window else {
            for w in self.windows {
                w.controller.close()
            }

            return
        }

        // If we need confirmation by any, show one confirmation for all windows
        let alert = NSAlert()
        alert.messageText = "Close All Windows?"
        alert.informativeText = "All terminal sessions will be terminated."
        alert.addButton(withTitle: "Close All Windows")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: alertWindow, completionHandler: { response in
            if (response == .alertFirstButtonReturn) {
                for w in self.windows {
                    w.controller.close()
                }
            }
        })
    }

    /// Relabels all the tabs with the proper keyboard shortcut.
    func relabelAllTabs() {
        for w in windows {
            w.controller.relabelTabs()
        }
    }

    // MARK: - Notifications

    @objc private func onNewWindow(notification: SwiftUI.Notification) {
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration
        self.newWindow(withBaseConfig: config)
    }

    @objc private func onNewTab(notification: SwiftUI.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard let window = surfaceView.window else { return }

        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration

        self.newTab(to: window, withBaseConfig: config)
    }

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        // We only care if the configuration is a global configuration, not a
        // surface-specific one.
        guard notification.object == nil else { return }

        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        // Update our derived config
        self.derivedConfig = DerivedConfig(config)
    }

    private struct DerivedConfig {
        let windowFullscreen: Bool
        let windowFullscreenMode: FullscreenMode
        let macosTitlebarStyle: String
        let windowNewTabPosition: String

        init() {
            self.windowFullscreen = false
            self.windowFullscreenMode = .native
            self.macosTitlebarStyle = "transparent"
            self.windowNewTabPosition = ""
        }

        init(_ config: Ghostty.Config) {
            self.windowFullscreen = config.windowFullscreen
            self.windowFullscreenMode = config.windowFullscreenMode
            self.macosTitlebarStyle = config.macosTitlebarStyle
            self.windowNewTabPosition = config.windowNewTabPosition
        }
    }
}
