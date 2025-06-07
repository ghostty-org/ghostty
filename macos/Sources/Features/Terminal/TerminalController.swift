import Foundation
import Cocoa
import SwiftUI
import Combine
import GhosttyKit

/// A classic, tabbed terminal experience.
class TerminalController: BaseTerminalController {
    override var windowNibName: NSNib.Name? { "Terminal" }

    /// This is set to true when we care about frame changes. This is a small optimization since
    /// this controller registers a listener for ALL frame change notifications and this lets us bail
    /// early if we don't care.
    private var tabListenForFrame: Bool = false

    /// This is the hash value of the last tabGroup.windows array. We use this to detect order
    /// changes in the list.
    private var tabWindowsHash: Int = 0

    /// This is set to false by init if the window managed by this controller should not be restorable.
    /// For example, terminals executing custom scripts are not restorable.
    private var restorable: Bool = true

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig

    /// The notification cancellable for focused surface property changes.
    private var surfaceAppearanceCancellables: Set<AnyCancellable> = []

    /// This will be set to the initial frame of the window from the xib on load.
    private var initialFrame: NSRect? = nil

    init(_ ghostty: Ghostty.App,
         withBaseConfig base: Ghostty.SurfaceConfiguration? = nil,
         withSurfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil,
         parent: NSWindow? = nil
    ) {
        // The window we manage is not restorable if we've specified a command
        // to execute. We do this because the restored window is meaningless at the
        // time of writing this: it'd just restore to a shell in the same directory
        // as the script. We may want to revisit this behavior when we have scrollback
        // restoration.
        self.restorable = (base?.command ?? "") == ""

        // Setup our initial derived config based on the current app config
        self.derivedConfig = DerivedConfig(ghostty.config)

        super.init(ghostty, baseConfig: base, surfaceTree: tree)

        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen),
            name: Ghostty.Notification.ghosttyToggleFullscreen,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onMoveTab),
            name: .ghosttyMoveTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoTab),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTab),
            name: .ghosttyCloseTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onResetWindowSize),
            name: .ghosttyResetWindowSize,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseWindow),
            name: .ghosttyCloseWindow,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        // Remove all of our notificationcenter subscriptions
        let center = NotificationCenter.default
        center.removeObserver(self)
    }

    // MARK: Base Controller Overrides

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)
        
        // Whenever our surface tree changes in any way (new split, close split, etc.)
        // we want to invalidate our state.
        invalidateRestorableState()

        // Update our zoom state
        if let window = window as? TerminalWindow {
            window.surfaceIsZoomed = to.zoomed != nil
        }

        // If our surface tree is now nil then we close our window.
        if (to.isEmpty) {
            self.window?.close()
        }
    }


    func fullscreenDidChange() {
        // When our fullscreen state changes, we resync our appearance because some
        // properties change when fullscreen or not.
        guard let focusedSurface else { return }
        if (!(fullscreenStyle?.isFullscreen ?? false) &&
           ghostty.config.macosTitlebarStyle == "hidden")
        {
            applyHiddenTitlebarStyle()
        }

        syncAppearance(focusedSurface.derivedConfig)
    }

    // MARK: Terminal Creation

    /// Returns all the available terminal controllers present in the app currently.
    static var all: [TerminalController] {
        return NSApplication.shared.windows.compactMap {
            $0.windowController as? TerminalController
        }
    }

    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    private static var lastCascadePoint = NSPoint(x: 0, y: 0)

    // The preferred parent terminal controller.
    private static var preferredParent: TerminalController? {
        all.first {
            $0.window?.isMainWindow ?? false
        } ?? all.last
    }

    /// The "new window" action.
    static func newWindow(
        _ ghostty: Ghostty.App,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil,
        withParent explicitParent: NSWindow? = nil
    ) -> TerminalController {
        let c = TerminalController.init(ghostty, withBaseConfig: baseConfig)

        // Get our parent. Our parent is the one explicitly given to us,
        // otherwise the focused terminal, otherwise an arbitrary one.
        let parent: NSWindow? = explicitParent ?? preferredParent?.window

        if let parent {
            if parent.styleMask.contains(.fullScreen) {
                parent.toggleFullScreen(nil)
            } else if ghostty.config.windowFullscreen {
                switch (ghostty.config.windowFullscreenMode) {
                case .native:
                    // Native has to be done immediately so that our stylemask contains
                    // fullscreen for the logic later in this method.
                    c.toggleFullscreen(mode: .native)

                case .nonNative, .nonNativeVisibleMenu, .nonNativePaddedNotch:
                    // If we're non-native then we have to do it on a later loop
                    // so that the content view is setup.
                    DispatchQueue.main.async {
                        c.toggleFullscreen(mode: ghostty.config.windowFullscreenMode)
                    }
                }
            }
        }

        // We're dispatching this async because otherwise the lastCascadePoint doesn't
        // take effect. Our best theory is there is some next-event-loop-tick logic
        // that Cocoa is doing that we need to be after.
        DispatchQueue.main.async {
            // Only cascade if we aren't fullscreen.
            if let window = c.window {
                if (!window.styleMask.contains(.fullScreen)) {
                    Self.lastCascadePoint = window.cascadeTopLeft(from: Self.lastCascadePoint)
                }
            }

            c.showWindow(self)
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                // Close the window when undoing
                undoManager.disableUndoRegistration {
                    target.closeWindow(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        withBaseConfig: baseConfig,
                        withParent: explicitParent)
                }
            }
        }

        return c
    }

    static func newTab(
        _ ghostty: Ghostty.App,
        from parent: NSWindow? = nil,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil
    ) -> TerminalController? {
        // Making sure that we're dealing with a TerminalController. If not,
        // then we just create a new window.
        guard let parent,
              let parentController = parent.windowController as? TerminalController else {
            return newWindow(ghostty, withBaseConfig: baseConfig, withParent: parent)
        }

        // If our parent is in non-native fullscreen, then new tabs do not work.
        // See: https://github.com/mitchellh/ghostty/issues/392
        if let fullscreenStyle = parentController.fullscreenStyle,
           fullscreenStyle.isFullscreen && !fullscreenStyle.supportsTabs {
            let alert = NSAlert()
            alert.messageText = "Cannot Create New Tab"
            alert.informativeText = "New tabs are unsupported while in non-native fullscreen. Exit fullscreen and try again."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .warning
            alert.beginSheetModal(for: parent)
            return nil
        }

        // Create a new window and add it to the parent
        let controller = TerminalController.init(ghostty, withBaseConfig: baseConfig)
        guard let window = controller.window else { return controller }

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
        if let tg = parent.tabGroup,
           tg.windows.firstIndex(of: window) != nil {
            tg.removeWindow(window)
        }

        // Our windows start out invisible. We need to make it visible. If we
        // don't do this then various features such as window blur won't work because
        // the macOS APIs only work on a visible window.
        controller.showWindow(self)

        // If we have the "hidden" titlebar style we want to create new
        // tabs as windows instead, so just skip adding it to the parent.
        if (ghostty.config.macosTitlebarStyle != "hidden") {
            // Add the window to the tab group and show it.
            switch ghostty.config.windowNewTabPosition {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            controller.relabelTabs()
        }

        // Setup our undo
        if let undoManager = parentController.undoManager {
            undoManager.setActionName("New Tab")
            undoManager.registerUndo(
                withTarget: controller,
                expiresAfter: controller.undoExpiration
            ) { target in
                // Close the tab when undoing
                undoManager.disableUndoRegistration {
                    target.closeTab(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newTab(
                        ghostty,
                        from: parent,
                        withBaseConfig: baseConfig)
                }
            }
        }

        return controller
    }

    //MARK: - Methods

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        // If this is an app-level config update then we update some things.
        if (notification.object == nil) {
            // Update our derived config
            self.derivedConfig = DerivedConfig(config)

            // If we have no surfaces in our window (is that possible?) then we update
            // our window appearance based on the root config. If we have surfaces, we
            // don't call this because focused surface changes will trigger appearance updates.
            if surfaceTree.isEmpty {
                syncAppearance(.init(config))
            }

            return
        }

        // This is a surface-level config update. If we have the surface, we
        // update our appearance based on it.
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(surfaceView) else { return }

        // We can't use surfaceView.derivedConfig because it may not be updated
        // yet since it also responds to notifications.
        syncAppearance(.init(config))
    }

    /// Update the accessory view of each tab according to the keyboard
    /// shortcut that activates it (if any). This is called when the key window
    /// changes, when a window is closed, and when tabs are reordered
    /// with the mouse.
    func relabelTabs() {
        // Reset this to false. It'll be set back to true later.
        tabListenForFrame = false

        guard let windows = self.window?.tabbedWindows as? [TerminalWindow] else { return }

        // We only listen for frame changes if we have more than 1 window,
        // otherwise the accessory view doesn't matter.
        tabListenForFrame = windows.count > 1

        for (tab, window) in zip(1..., windows) {
            // We need to clear any windows beyond this because they have had
            // a keyEquivalent set previously.
            guard tab <= 9 else {
                window.keyEquivalent = ""
                continue
            }

            let action = "goto_tab:\(tab)"
            if let equiv = ghostty.config.keyboardShortcut(for: action) {
                window.keyEquivalent = "\(equiv)"
            } else {
                window.keyEquivalent = ""
            }
        }
    }

    private func fixTabBar() {
        // We do this to make sure that the tab bar will always re-composite. If we don't,
        // then the it will "drag" pieces of the background with it when a transparent
        // window is moved around.
        //
        // There might be a better way to make the tab bar "un-lazy", but I can't find it.
        if let window = window, !window.isOpaque {
            window.isOpaque = true
            window.isOpaque = false
        }
    }

    @objc private func onFrameDidChange(_ notification: NSNotification) {
        // This is a huge hack to set the proper shortcut for tab selection
        // on tab reordering using the mouse. There is no event, delegate, etc.
        // as far as I can tell for when a tab is manually reordered with the
        // mouse in a macOS-native tab group, so the way we detect it is setting
        // the accessoryView "postsFrameChangedNotification" to true, listening
        // for the view frame to change, comparing the windows list, and
        // relabeling the tabs.
        guard tabListenForFrame else { return }
        guard let v = self.window?.tabbedWindows?.hashValue else { return }
        guard tabWindowsHash != v else { return }
        tabWindowsHash = v
        self.relabelTabs()
    }

    private func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        guard let window = self.window as? TerminalWindow else { return }

        // Set our explicit appearance if we need to based on the configuration.
        window.appearance = surfaceConfig.windowAppearance

        // Update our window light/darkness based on our updated background color
        window.isLightTheme = OSColor(surfaceConfig.backgroundColor).isLightColor

        // Sync our zoom state for splits
        window.surfaceIsZoomed = surfaceTree.zoomed != nil

        // If our window is not visible, then we do nothing. Some things such as blurring
        // have no effect if the window is not visible. Ultimately, we'll have this called
        // at some point when a surface becomes focused.
        guard window.isVisible else { return }

        // Set the font for the window and tab titles.
        if let titleFontName = surfaceConfig.windowTitleFontFamily {
            window.titlebarFont = NSFont(name: titleFontName, size: NSFont.systemFontSize)
        } else {
            window.titlebarFont = nil
        }

        // If we have window transparency then set it transparent. Otherwise set it opaque.

        // Window transparency only takes effect if our window is not native fullscreen.
        // In native fullscreen we disable transparency/opacity because the background
        // becomes gray and widgets show through.
        if (!window.styleMask.contains(.fullScreen) &&
            surfaceConfig.backgroundOpacity < 1
        ) {
            window.isOpaque = false

            // This is weird, but we don't use ".clear" because this creates a look that
            // matches Terminal.app much more closer. This lets users transition from
            // Terminal.app more easily.
            window.backgroundColor = .white.withAlphaComponent(0.001)

            ghostty_set_window_background_blur(ghostty.app, Unmanaged.passUnretained(window).toOpaque())
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }

        window.hasShadow = surfaceConfig.macosWindowShadow

        guard window.hasStyledTabs else { return }

        // Our background color depends on if our focused surface borders the top or not.
        // If it does, we match the focused surface. If it doesn't, we use the app
        // configuration.
        let backgroundColor: OSColor
        if !surfaceTree.isEmpty {
            if let focusedSurface = focusedSurface,
               let treeRoot = surfaceTree.root,
               let focusedNode = treeRoot.node(view: focusedSurface),
               treeRoot.spatial().doesBorder(side: .up, from: focusedNode) {
                // Similar to above, an alpha component of "0" causes compositor issues, so
                // we use 0.001. See: https://github.com/ghostty-org/ghostty/pull/4308
                backgroundColor = OSColor(focusedSurface.backgroundColor ?? surfaceConfig.backgroundColor).withAlphaComponent(0.001)
            } else {
                // We don't have a focused surface or our surface doesn't border the
                // top. We choose to match the color of the top-left most surface.
                let topLeftSurface = surfaceTree.root?.leftmostLeaf()
                backgroundColor = OSColor(topLeftSurface?.backgroundColor ?? derivedConfig.backgroundColor)
            }
        } else {
            backgroundColor = OSColor(self.derivedConfig.backgroundColor)
        }
        window.titlebarColor = backgroundColor.withAlphaComponent(surfaceConfig.backgroundOpacity)

        if (window.isOpaque) {
            // Bg color is only synced if we have no transparency. This is because
            // the transparency is handled at the surface level (window.backgroundColor
            // ignores alpha components)
            window.backgroundColor = backgroundColor

            // If there is transparency, calling this will make the titlebar opaque
            // so we only call this if we are opaque.
            window.updateTabBar()
        }
    }

    private func setInitialWindowPosition(x: Int16?, y: Int16?, windowDecorations: Bool) {
        guard let window else { return }

        // If we don't have an X/Y then we try to use the previously saved window pos.
        guard let x, let y else {
            if (!LastWindowPosition.shared.restore(window)) {
                window.center()
            }

            return
        }

        // Prefer the screen our window is being placed on otherwise our primary screen.
        guard let screen = window.screen ?? NSScreen.screens.first else {
            window.center()
            return
        }

        // Orient based on the top left of the primary monitor
        let frame = screen.visibleFrame
        window.setFrameOrigin(.init(
            x: frame.minX + CGFloat(x),
            y: frame.maxY - (CGFloat(y) + window.frame.height)))
    }

    /// Returns the default size of the window. This is contextual based on the focused surface because
    /// the focused surface may specify a different default size than others.
    private var defaultSize: NSRect? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }

        if derivedConfig.maximize {
            return screen.visibleFrame
        } else if let focusedSurface,
                  let initialSize = focusedSurface.initialSize {
            // Get the current frame of the window
            guard var frame = window?.frame else { return nil }

            // Calculate the chrome size (window size minus view size)
            let chromeWidth = frame.size.width - focusedSurface.frame.size.width
            let chromeHeight = frame.size.height - focusedSurface.frame.size.height

            // Calculate the new width and height, clamping to the screen's size
            let newWidth = min(initialSize.width + chromeWidth, screen.visibleFrame.width)
            let newHeight = min(initialSize.height + chromeHeight, screen.visibleFrame.height)

            // Update the frame size while keeping the window's position intact
            frame.size.width = newWidth
            frame.size.height = newHeight

            // Ensure the window doesn't go outside the screen boundaries
            frame.origin.x = max(screen.frame.origin.x, min(frame.origin.x, screen.frame.maxX - newWidth))
            frame.origin.y = max(screen.frame.origin.y, min(frame.origin.y, screen.frame.maxY - newHeight))

            return frame
        }

        guard let initialFrame else { return nil }
        guard var frame = window?.frame else { return nil }

        // Calculate the new width and height, clamping to the screen's size
        let newWidth = min(initialFrame.size.width, screen.visibleFrame.width)
        let newHeight = min(initialFrame.size.height, screen.visibleFrame.height)

        // Update the frame size while keeping the window's position intact
        frame.size.width = newWidth
        frame.size.height = newHeight

        // Ensure the window doesn't go outside the screen boundaries
        frame.origin.x = max(screen.frame.origin.x, min(frame.origin.x, screen.frame.maxX - newWidth))
        frame.origin.y = max(screen.frame.origin.y, min(frame.origin.y, screen.frame.maxY - newHeight))

        return frame
    }

    /// This is called anytime a node in the surface tree is being removed.
    override func closeSurfaceNode(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // If this isn't the root then we're dealing with a split closure.
        if surfaceTree.root != node {
            super.closeSurfaceNode(node, withConfirmation: withConfirmation)
            return
        }

        // More than 1 window means we have tabs and we're closing a tab
        if window?.tabGroup?.windows.count ?? 0 > 1 {
            closeTab(nil)
            return
        }

        // 1 window, closing the window
        closeWindow(nil)
    }

    private func closeTabImmediately() {
        guard let window = window else { return }
        guard let tabGroup = window.tabGroup,
                tabGroup.windows.count > 1 else {
            closeWindowImmediately()
            return
        }
        
        // Undo
        if let undoManager, let undoState {
            // Register undo action to restore the tab
            undoManager.setActionName("Close Tab")
            undoManager.registerUndo(
                withTarget: ghostty,
                expiresAfter: undoExpiration
            ) { ghostty in
                let newController = TerminalController(ghostty, with: undoState)
                
                // Register redo action
                undoManager.registerUndo(
                    withTarget: newController,
                    expiresAfter: newController.undoExpiration
                ) { target in
                    target.closeTabImmediately()
                }
            }
        }
        
        window.close()
    }

    /// Closes the current window (including any other tabs) immediately and without
    /// confirmation. This will setup proper undo state so the action can be undone.
    private func closeWindowImmediately() {
        guard let window = window else { return }

        // Regardless of tabs vs no tabs, what we want to do here is keep
        // track of the window frame to restore, the surface tree, and the
        // the focused surface. We want to restore that with undo even
        // if we end up closing.
        if let undoManager, let undoState {
            // Register undo action to restore the window
            undoManager.setActionName("Close Window")
            undoManager.registerUndo(
                withTarget: ghostty,
                expiresAfter: undoExpiration) { ghostty in
                // Restore the undo state
                let newController = TerminalController(ghostty, with: undoState)

                // Register redo action
                undoManager.registerUndo(
                    withTarget: newController,
                    expiresAfter: newController.undoExpiration) { target in
                    target.closeWindowImmediately()
                }
            }
        }

        guard let tabGroup = window.tabGroup else {
            // No tabs, no tab group, just perform a normal close.
            window.close()
            return
        }

        // If have one window then we just do a normal close
        if tabGroup.windows.count == 1 {
            window.close()
            return
        }


        tabGroup.windows.forEach { $0.close() }
    }

    /// Close all windows, asking for confirmation if necessary.
    static func closeAllWindows() {
        let needsConfirm: Bool = all.contains {
            $0.surfaceTree.contains { $0.needsConfirmQuit }
        }

        if (!needsConfirm) {
            closeAllWindowsImmediately()
            return
        }

        // If we don't have a main window, we just close all windows because
        // we have no window to show the modal on top of. I'm sure there's a way
        // to do an app-level alert but I don't know how and this case should never
        // really happen.
        guard let alertWindow = preferredParent?.window else {
            closeAllWindowsImmediately()
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
                closeAllWindowsImmediately()
            }
        })
    }

    static private func closeAllWindowsImmediately() {
        let undoManager = (NSApp.delegate as? AppDelegate)?.undoManager
        undoManager?.beginUndoGrouping()
        all.forEach { $0.closeWindowImmediately() }
        undoManager?.setActionName("Close All Windows")
        undoManager?.endUndoGrouping()
    }

    // MARK: Undo/Redo

    /// The state that we require to recreate a TerminalController from an undo.
    struct UndoState {
        let frame: NSRect
        let surfaceTree: SplitTree<Ghostty.SurfaceView>
        let focusedSurface: UUID?
        let tabIndex: Int?
        private(set) weak var tabGroup: NSWindowTabGroup?
    }

    convenience init(_ ghostty: Ghostty.App,
         with undoState: UndoState
    ) {
        self.init(ghostty, withSurfaceTree: undoState.surfaceTree)

        // Show the window and restore its frame
        showWindow(nil)
        if let window {
            window.setFrame(undoState.frame, display: true)

            // If we have a tab group and index, restore the tab to its original position
            if let tabGroup = undoState.tabGroup,
               let tabIndex = undoState.tabIndex {
                if tabIndex < tabGroup.windows.count {
                    // Find the window that is currently at that index
                    let currentWindow = tabGroup.windows[tabIndex]
                    currentWindow.addTabbedWindow(window, ordered: .below)
                } else {
                    tabGroup.windows.last?.addTabbedWindow(window, ordered: .above)
                }

                // Make it the key window
                window.makeKeyAndOrderFront(nil)
            }

            // Restore focus to the previously focused surface
            if let focusedUUID = undoState.focusedSurface,
               let focusTarget = surfaceTree.first(where: { $0.uuid == focusedUUID }) {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: focusTarget, from: nil)
                }
            }
        }
    }

    /// The current undo state for this controller
    var undoState: UndoState? {
        guard let window else { return nil }
        return .init(
            frame: window.frame,
            surfaceTree: surfaceTree,
            focusedSurface: focusedSurface?.uuid,
            tabIndex: window.tabGroup?.windows.firstIndex(of: window),
            tabGroup: window.tabGroup)
    }

    //MARK: - NSWindowController

    override func windowWillLoad() {
        // We do NOT want to cascade because we handle this manually from the manager.
        shouldCascadeWindows = false
    }

   fileprivate func hideWindowButtons() {
        guard let window else { return }

        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    fileprivate func applyHiddenTitlebarStyle() {
        guard let window else { return }

        window.styleMask = [
            // We need `titled` in the mask to get the normal window frame
            .titled,

            // Full size content view so we can extend
            // content in to the hidden titlebar's area
            .fullSizeContentView,

            .resizable,
            .closable,
            .miniaturizable,
        ]

        // Hide the title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        // Hide the traffic lights (window control buttons)
        hideWindowButtons()

        // Disallow tabbing if the titlebar is hidden, since that will (should) also hide the tab bar.
        window.tabbingMode = .disallowed

        // Nuke it from orbit -- hide the titlebar container entirely, just in case. There are
        // some operations that appear to bring back the titlebar visibility so this ensures
        // it is gone forever.
        if let themeFrame = window.contentView?.superview,
           let titleBarContainer = themeFrame.firstDescendant(withClassName: "NSTitlebarContainerView") {
            titleBarContainer.isHidden = true
        }
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window = window as? TerminalWindow else { return }

        // Store our initial frame so we can know our default later.
        initialFrame = window.frame

        // I copy this because we may change the source in the future but also because
        // I regularly audit our codebase for "ghostty.config" access because generally
        // you shouldn't use it. Its safe in this case because for a new window we should
        // use whatever the latest app-level config is.
        let config = ghostty.config

        // Setting all three of these is required for restoration to work.
        window.isRestorable = restorable
        if (restorable) {
            window.restorationClass = TerminalWindowRestoration.self
            window.identifier = .init(String(describing: TerminalWindowRestoration.self))
        }

        // If window decorations are disabled, remove our title
        if (!config.windowDecorations) { window.styleMask.remove(.titled) }

        // If we have only a single surface (no splits) and there is a default size then
        // we should resize to that default size.
        if case let .leaf(view) = surfaceTree.root {
            // If this is our first surface then our focused surface will be nil
            // so we force the focused surface to the leaf.
            focusedSurface = view

            if let defaultSize {
                window.setFrame(defaultSize, display: true)
            }
        }

        // Set our window positioning to coordinates if config value exists, otherwise
        // fallback to original centering behavior
        setInitialWindowPosition(
            x: config.windowPositionX,
            y: config.windowPositionY,
            windowDecorations: config.windowDecorations)

        if config.macosWindowButtons == .hidden {
            hideWindowButtons()
        }

        // Make sure our theme is set on the window so styling is correct.
        if let windowTheme = config.windowTheme {
            window.windowTheme = .init(rawValue: windowTheme)
        }

        // Handle titlebar tabs config option. Something about what we do while setting up the
        // titlebar tabs interferes with the window restore process unless window.tabbingMode
        // is set to .preferred, so we set it, and switch back to automatic as soon as we can.
        if (config.macosTitlebarStyle == "tabs") {
            window.tabbingMode = .preferred
            window.titlebarTabs = true
            DispatchQueue.main.async {
                window.tabbingMode = .automatic
            }
        } else if (config.macosTitlebarStyle == "transparent") {
            window.transparentTabs = true
        }

        if window.hasStyledTabs {
            // Set the background color of the window
            let backgroundColor = NSColor(config.backgroundColor)
            window.backgroundColor = backgroundColor

            // This makes sure our titlebar renders correctly when there is a transparent background
            window.titlebarColor = backgroundColor.withAlphaComponent(config.backgroundOpacity)
        }

        // Initialize our content view to the SwiftUI root
        window.contentView = NSHostingView(rootView: TerminalView(
            ghostty: self.ghostty,
            viewModel: self,
            delegate: self
        ))

        // If our titlebar style is "hidden" we adjust the style appropriately
        if (config.macosTitlebarStyle == "hidden") {
            applyHiddenTitlebarStyle()
        }

        // In various situations, macOS automatically tabs new windows. Ghostty handles
        // its own tabbing so we DONT want this behavior. This detects this scenario and undoes
        // it.
        //
        // Example scenarios where this happens:
        //   - When the system user tabbing preference is "always"
        //   - When the "+" button in the tab bar is clicked
        //
        // We don't run this logic in fullscreen because in fullscreen this will end up
        // removing the window and putting it into its own dedicated fullscreen, which is not
        // the expected or desired behavior of anyone I've found.
        if (!window.styleMask.contains(.fullScreen)) {
            // If we have more than 1 window in our tab group we know we're a new window.
            // Since Ghostty manages tabbing manually this will never be more than one
            // at this point in the AppKit lifecycle (we add to the group after this).
            if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
                window.tabGroup?.removeWindow(window)
            }
        }

        // Apply any additional appearance-related properties to the new window. We
        // apply this based on the root config but change it later based on surface
        // config (see focused surface change callback).
        syncAppearance(.init(config))
    }

    // Shows the "+" button in the tab bar, responds to that click.
    override func newWindowForTab(_ sender: Any?) {
        // Trigger the ghostty core event logic for a new tab.
        guard let surface = self.focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    //MARK: - NSWindowDelegate

    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        self.relabelTabs()

        // If we remove a window, we reset the cascade point to the key window so that
        // the next window cascade's from that one.
        if let focusedWindow = NSApplication.shared.keyWindow {
            // If we are NOT the focused window, then we are a tabbed window. If we
            // are closing a tabbed window, we want to set the cascade point to be
            // the next cascade point from this window.
            if focusedWindow != window {
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
    }

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        self.relabelTabs()
        self.fixTabBar()
    }

    override func windowDidMove(_ notification: Notification) {
        super.windowDidMove(notification)
        self.fixTabBar()

        // Whenever we move save our last position for the next start.
        if let window {
            LastWindowPosition.shared.save(window)
        }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        // Whenever we get focused, use that as our last window position for
        // restart. This differs from Terminal.app but matches iTerm2 behavior
        // and I think its sensible.
        if let window {
            LastWindowPosition.shared.save(window)
        }
    }

    // Called when the window will be encoded. We handle the data encoding here in the
    // window controller.
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        let data = TerminalRestorableState(from: self)
        data.encode(with: state)
    }

    // MARK: First Responder

    @IBAction func newWindow(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newWindow(surface: surface)
    }

    @IBAction func newTab(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    @IBAction func closeTab(_ sender: Any?) {
        guard let window = window else { return }
        guard window.tabGroup?.windows.count ?? 0 > 1 else {
            closeWindow(sender)
            return
        }

        guard surfaceTree.contains(where: { $0.needsConfirmQuit }) else {
            closeTabImmediately()
            return
        }

        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabImmediately()
        }
    }

    @IBAction func returnToDefaultSize(_ sender: Any?) {
        guard let defaultSize else { return }
        window?.setFrame(defaultSize, display: true)
    }

    @IBAction override func closeWindow(_ sender: Any?) {
        guard let window = window else { return }
        guard let tabGroup = window.tabGroup else {
            // No tabs, no tab group, just perform a normal close.
            closeWindowImmediately()
            return
        }

        // If have one window then we just do a normal close
        if tabGroup.windows.count == 1 {
            closeWindowImmediately()
            return
        }

        // Check if any windows require close confirmation.
        let needsConfirm = tabGroup.windows.contains { tabWindow in
            guard let controller = tabWindow.windowController as? TerminalController else {
                return false
            }
            return controller.surfaceTree.contains(where: { $0.needsConfirmQuit })
        }

        // If none need confirmation then we can just close all the windows.
        if !needsConfirm {
            closeWindowImmediately()
            return
        }

        confirmClose(
            messageText: "Close Window?",
            informativeText: "All terminal sessions in this window will be terminated."
        ) {
            self.closeWindowImmediately()
        }
    }

    @IBAction func toggleGhosttyFullScreen(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleFullscreen(surface: surface)
    }

    @IBAction func toggleTerminalInspector(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleTerminalInspector(surface: surface)
    }

    //MARK: - TerminalViewDelegate

    override func titleDidChange(to: String) {
        super.titleDidChange(to: to)

        guard let window = window as? TerminalWindow else { return }

        // Custom toolbar-based title used when titlebar tabs are enabled.
        if let toolbar = window.toolbar as? TerminalToolbar {
            if (window.titlebarTabs || derivedConfig.macosTitlebarStyle == "hidden") {
                // Updating the title text as above automatically reveals the
                // native title view in macOS 15.0 and above. Since we're using
                // a custom view instead, we need to re-hide it.
                window.titleVisibility = .hidden
            }
            toolbar.titleText = to
        }
    }
    
    override func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: to)

        // We always cancel our event listener
        surfaceAppearanceCancellables.removeAll()

        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)

        // We also want to get notified of certain changes to update our appearance.
        focusedSurface.$derivedConfig
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
        focusedSurface.$backgroundColor
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
    }

    private func syncAppearanceOnPropertyChange(_ surface: Ghostty.SurfaceView?) {
        guard let surface else { return }
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let surface else { return }
            guard let self else { return }
            guard self.focusedSurface == surface else { return }
            self.syncAppearance(surface.derivedConfig)
        }
    }

    //MARK: - Notifications

    @objc private func onMoveTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }

        // Get the move action
        guard let action = notification.userInfo?[Notification.Name.GhosttyMoveTabKey] as? Ghostty.Action.MoveTab else { return }
        guard action.amount != 0 else { return }

        // Determine our current selected index
        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        guard let selectedWindow = tabGroup.selectedWindow else { return }
        let tabbedWindows = tabGroup.windows
        guard tabbedWindows.count > 0 else { return }
        guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }

        // Determine the final index we want to insert our tab
        let finalIndex: Int
        if action.amount < 0 {
            finalIndex = selectedIndex - min(selectedIndex, -action.amount)
        } else {
            let remaining: Int = tabbedWindows.count - 1 - selectedIndex
            finalIndex = selectedIndex + min(remaining, action.amount)
        }

        // If our index is the same we do nothing
        guard finalIndex != selectedIndex else { return }

        // Get our target window
        let targetWindow = tabbedWindows[finalIndex]

        // Begin a group of window operations to minimize visual updates
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        // Remove and re-add the window in the correct position
        tabGroup.removeWindow(selectedWindow)
        targetWindow.addTabbedWindow(selectedWindow, ordered: action.amount < 0 ? .below : .above)

        // Ensure our window remains selected
        selectedWindow.makeKey()

        NSAnimationContext.endGrouping()
    }

    @objc private func onGotoTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }

        // Get the tab index from the notification
        guard let tabEnumAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabEnum = tabEnumAny as? ghostty_action_goto_tab_e else { return }
        let tabIndex: Int32 = tabEnum.rawValue

        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        let tabbedWindows = tabGroup.windows

        // This will be the index we want to actual go to
        let finalIndex: Int

        // An index that is invalid is used to signal some special values.
        if (tabIndex <= 0) {
            guard let selectedWindow = tabGroup.selectedWindow else { return }
            guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }

            if (tabIndex == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue) {
                if (selectedIndex == 0) {
                    finalIndex = tabbedWindows.count - 1
                } else {
                    finalIndex = selectedIndex - 1
                }
            } else if (tabIndex == GHOSTTY_GOTO_TAB_NEXT.rawValue) {
                if (selectedIndex == tabbedWindows.count - 1) {
                    finalIndex = 0
                } else {
                    finalIndex = selectedIndex + 1
                }
            } else if (tabIndex == GHOSTTY_GOTO_TAB_LAST.rawValue) {
                finalIndex = tabbedWindows.count - 1
            } else {
                return
            }
        } else {
            // The configured value is 1-indexed.
            guard tabIndex >= 1 else { return }

            // If our index is outside our boundary then we use the max
            finalIndex = min(Int(tabIndex - 1), tabbedWindows.count - 1)
        }

        guard finalIndex >= 0 else { return }
        let targetWindow = tabbedWindows[finalIndex]
        targetWindow.makeKeyAndOrderFront(nil)
    }

    @objc private func onCloseTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTab(self)
    }

    @objc private func onCloseWindow(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeWindow(self)
    }

    @objc private func onResetWindowSize(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        returnToDefaultSize(nil)
    }

    @objc private func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the fullscreen mode we want to toggle
        let fullscreenMode: FullscreenMode
        if let any = notification.userInfo?[Ghostty.Notification.FullscreenModeKey],
           let mode = any as? FullscreenMode {
            fullscreenMode = mode
        } else {
            Ghostty.logger.warning("no fullscreen mode specified or invalid mode, doing nothing")
            return
        }

        toggleFullscreen(mode: fullscreenMode)
    }

    struct DerivedConfig {
        let backgroundColor: Color
        let macosWindowButtons: Ghostty.MacOSWindowButtons
        let macosTitlebarStyle: String
        let maximize: Bool

        init() {
            self.backgroundColor = Color(NSColor.windowBackgroundColor)
            self.macosWindowButtons = .visible
            self.macosTitlebarStyle = "system"
            self.maximize = false
        }

        init(_ config: Ghostty.Config) {
            self.backgroundColor = config.backgroundColor
            self.macosWindowButtons = config.macosWindowButtons
            self.macosTitlebarStyle = config.macosTitlebarStyle
            self.maximize = config.maximize
        }
    }
}

// MARK: NSMenuItemValidation

extension TerminalController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(returnToDefaultSize):
            guard let window else { return false }

            // Native fullscreen windows can't revert to default size.
            if window.styleMask.contains(.fullScreen) {
                return false
            }

            // If we're fullscreen at all then we can't change size
            if fullscreenStyle?.isFullscreen ?? false {
                return false
            }

            // If our window is already the default size or we don't have a
            // default size, then disable.
            guard let defaultSize,
                  window.frame.size != .init(
                    width: defaultSize.size.width,
                    height: defaultSize.size.height
                  )
            else {
                return false
            }

            return true

        default:
            return true
        }
    }
}

