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

    init(_ ghostty: Ghostty.App,
         withBaseConfig base: Ghostty.SurfaceConfiguration? = nil,
         withSurfaceTree tree: Ghostty.SplitNode? = nil
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
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: nil)
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

    override func surfaceTreeDidChange(from: Ghostty.SplitNode?, to: Ghostty.SplitNode?) {
        super.surfaceTreeDidChange(from: from, to: to)

        // If our surface tree is now nil then we close our window.
        if (to == nil) {
            self.window?.close()
        }
    }


    override func fullscreenDidChange() {
        super.fullscreenDidChange()

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
            // don't call this because the TODO
            if surfaceTree == nil {
                syncAppearance(.init(config))
            }

            return
        }

        // This is a surface-level config update. If we have the surface, we
        // update our appearance based on it.
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree?.contains(view: surfaceView) ?? false else { return }

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
            if let equiv = ghostty.config.keyEquivalent(for: action) {
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
        if let surfaceTree {
            if let focusedSurface, surfaceTree.doesBorderTop(view: focusedSurface) {
                // Similar to above, an alpha component of "0" causes compositor issues, so
                // we use 0.001. See: https://github.com/ghostty-org/ghostty/pull/4308
                backgroundColor = OSColor(focusedSurface.backgroundColor ?? surfaceConfig.backgroundColor).withAlphaComponent(0.001)
            } else {
                // We don't have a focused surface or our surface doesn't border the
                // top. We choose to match the color of the top-left most surface.
                backgroundColor = OSColor(surfaceTree.topLeft().backgroundColor ?? derivedConfig.backgroundColor)
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

    //MARK: - NSWindowController

    override func windowWillLoad() {
        // We do NOT want to cascade because we handle this manually from the manager.
        shouldCascadeWindows = false
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
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

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

        // If we have only a single surface (no splits) and that surface requested
        // an initial size then we set it here now.
        if case let .leaf(leaf) = surfaceTree {
            if let initialSize = leaf.surface.initialSize,
               let screen = window.screen ?? NSScreen.main {
                // Get the current frame of the window
                var frame = window.frame

                // Calculate the chrome size (window size minus view size)
                let chromeWidth = frame.size.width - leaf.surface.frame.size.width
                let chromeHeight = frame.size.height - leaf.surface.frame.size.height

                // Calculate the new width and height, clamping to the screen's size
                let newWidth = min(initialSize.width + chromeWidth, screen.visibleFrame.width)
                let newHeight = min(initialSize.height + chromeHeight, screen.visibleFrame.height)

                // Update the frame size while keeping the window's position intact
                frame.size.width = newWidth
                frame.size.height = newHeight

                // Ensure the window doesn't go outside the screen boundaries
                frame.origin.x = max(screen.frame.origin.x, min(frame.origin.x, screen.frame.maxX - newWidth))
                frame.origin.y = max(screen.frame.origin.y, min(frame.origin.y, screen.frame.maxY - newHeight))

                // Set the updated frame to the window
                window.setFrame(frame, display: true)
            }
        }

        // Set our window positioning to coordinates if config value exists, otherwise
        // fallback to original centering behavior
        setInitialWindowPosition(
            x: config.windowPositionX,
            y: config.windowPositionY,
            windowDecorations: config.windowDecorations)

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

    private func confirmClose(
        window: NSWindow,
        messageText: String,
        informativeText: String,
        completion: @escaping () -> Void
    ) {
        // If we need confirmation by any, show one confirmation for all windows
        // in the tab group.
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                completion()
            }
        }
    }

    @IBAction func closeTab(_ sender: Any?) {
        guard let window = window else { return }
        guard window.tabGroup != nil else {
            // No tabs, no tab group, just perform a normal close.
            window.performClose(sender)
            return
        }

        if surfaceTree?.needsConfirmQuit() ?? false {
            confirmClose(
                window: window,
                messageText: "Close Tab?",
                informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
            ) {
                window.close()
            }
            return
        }

        window.close()
    }

    @IBAction override func closeWindow(_ sender: Any?) {
        guard let window = window else { return }
        guard let tabGroup = window.tabGroup else {
            // No tabs, no tab group, just perform a normal close.
            window.performClose(sender)
            return
        }

        // If have one window then we just do a normal close
        if tabGroup.windows.count == 1 {
            window.performClose(sender)
            return
        }

        // Check if any windows require close confirmation.
        let needsConfirm = tabGroup.windows.contains { tabWindow in
            guard let controller = tabWindow.windowController as? TerminalController else {
                return false
            }
            return controller.surfaceTree?.needsConfirmQuit() ?? false
        }

        // If none need confirmation then we can just close all the windows.
        if !needsConfirm {
            tabGroup.windows.forEach { $0.close() }
            return
        }

        confirmClose(
            window: window,
            messageText: "Close Window?",
            informativeText: "All terminal sessions in this window will be terminated."
        ) {
            tabGroup.windows.forEach { $0.close() }
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

    override func surfaceTreeDidChange() {
        // Whenever our surface tree changes in any way (new split, close split, etc.)
        // we want to invalidate our state.
        invalidateRestorableState()
    }

    override func zoomStateDidChange(to: Bool) {
        guard let window = window as? TerminalWindow else { return }
        window.surfaceIsZoomed = to
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
        guard surfaceTree?.contains(view: target) ?? false else { return }
        closeTab(self)
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
        let macosTitlebarStyle: String

        init() {
            self.backgroundColor = Color(NSColor.windowBackgroundColor)
            self.macosTitlebarStyle = "system"
        }

        init(_ config: Ghostty.Config) {
            self.backgroundColor = config.backgroundColor
            self.macosTitlebarStyle = config.macosTitlebarStyle
        }
    }
}
