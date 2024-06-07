import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

/// The terminal controller is an NSWindowController that maps 1:1 to a terminal window.
class TerminalController: NSWindowController, NSWindowDelegate, 
                          TerminalViewDelegate, TerminalViewModel,
                          ClipboardConfirmationViewDelegate
{
    override var windowNibName: NSNib.Name? { "Terminal" }
    
    /// The app instance that this terminal view will represent.
    let ghostty: Ghostty.App
    
    /// The currently focused surface.
    var focusedSurface: Ghostty.SurfaceView? = nil {
        didSet {
            syncFocusToSurfaceTree()
        }
    }
    
    /// The surface tree for this window.
    @Published var surfaceTree: Ghostty.SplitNode? = nil {
        didSet {
            // If our surface tree becomes nil then ensure all surfaces
            // in the old tree have closed and then close the window.
            if (surfaceTree == nil) {
                oldValue?.close()
                focusedSurface = nil
                lastSurfaceDidClose()
            }
        }
    }
    
    /// Fullscreen state management.
    let fullscreenHandler = FullScreenHandler()
    
    /// True when an alert is active so we don't overlap multiple.
    private var alert: NSAlert? = nil
    
    /// The clipboard confirmation window, if shown.
    private var clipboardConfirmation: ClipboardConfirmationController? = nil
    
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

    init(_ ghostty: Ghostty.App,
         withBaseConfig base: Ghostty.SurfaceConfiguration? = nil,
         withSurfaceTree tree: Ghostty.SplitNode? = nil
    ) {
        self.ghostty = ghostty
        
        // The window we manage is not restorable if we've specified a command
        // to execute. We do this because the restored window is meaningless at the
        // time of writing this: it'd just restore to a shell in the same directory
        // as the script. We may want to revisit this behavior when we have scrollback
        // restoration.
        self.restorable = (base?.command ?? "") == ""
        
        super.init(window: nil)
        
        // Initialize our initial surface.
        guard let ghostty_app = ghostty.app else { preconditionFailure("app must be loaded") }
        self.surfaceTree = tree ?? .leaf(.init(ghostty_app, baseConfig: base))
        
        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen),
            name: Ghostty.Notification.ghosttyToggleFullscreen,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoTab),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onConfirmClipboardRequest),
            name: Ghostty.Notification.confirmClipboard,
            object: nil)
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
    
    //MARK: - Methods
    
    func configDidReload() {
        syncAppearance()
    }
    
    /// Update the accessory view of each tab according to the keyboard
    /// shortcut that activates it (if any). This is called when the key window
    /// changes and when a window is closed.
    func relabelTabs() {
        // Reset this to false. It'll be set back to true later.
        tabListenForFrame = false

        guard let windows = self.window?.tabbedWindows as? [TerminalWindow] else { return }

        // We only listen for frame changes if we have more than 1 window,
        // otherwise the accessory view doesn't matter.
        tabListenForFrame = windows.count > 1

        for (index, window) in windows.enumerated().prefix(9) {
            let action = "goto_tab:\(index + 1)"

            if let equiv = ghostty.config.keyEquivalent(for: action) {
                window.keyEquivalent = "\(equiv)"
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
    
    private func syncAppearance() {
        guard let window = self.window as? TerminalWindow else { return }
        
        // Set the font for the window and tab titles.
        if let titleFontName = ghostty.config.windowTitleFontFamily {
            window.titlebarFont = NSFont(name: titleFontName, size: NSFont.systemFontSize)
        } else {
            window.titlebarFont = nil
        }
        
        guard window.hasStyledTabs else { return }

        // The titlebar is always updated. We don't need to worry about opacity
        // because we handle it here.
        let backgroundColor = OSColor(ghostty.config.backgroundColor)
        window.titlebarColor = backgroundColor.withAlphaComponent(ghostty.config.backgroundOpacity)
        
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
    
    /// Update all surfaces with the focus state. This ensures that libghostty has an accurate view about
    /// what surface is focused. This must be called whenever a surface OR window changes focus.
    private func syncFocusToSurfaceTree() {
        guard let tree = self.surfaceTree else { return }

        for leaf in tree {
            // Our focus state requires that this window is key and our currently
            // focused surface is the surface in this leaf.
            let focused: Bool = (window?.isKeyWindow ?? false) &&
                focusedSurface != nil &&
                leaf.surface == focusedSurface!
            leaf.surface.focusDidChange(focused)
        }
    }

    //MARK: - NSWindowController
    
    override func windowWillLoad() {
        // We do NOT want to cascade because we handle this manually from the manager.
        shouldCascadeWindows = false
    }
    
    override func windowDidLoad() {
        guard let window = window as? TerminalWindow else { return }
        
        // Setting all three of these is required for restoration to work.
        window.isRestorable = restorable
        if (restorable) {
            window.restorationClass = TerminalWindowRestoration.self
            window.identifier = .init(String(describing: TerminalWindowRestoration.self))
        }
        
        // If window decorations are disabled, remove our title
        if (!ghostty.config.windowDecorations) { window.styleMask.remove(.titled) }
        
        // Terminals typically operate in sRGB color space and macOS defaults
        // to "native" which is typically P3. There is a lot more resources
        // covered in thie GitHub issue: https://github.com/mitchellh/ghostty/pull/376
        // Ghostty defaults to sRGB but this can be overridden.
        switch (ghostty.config.windowColorspace) {
        case "display-p3":
            window.colorSpace = .displayP3
        case "srgb":
            fallthrough
        default:
            window.colorSpace = .sRGB
        }
        
        // If we have only a single surface (no splits) and that surface requested
        // an initial size then we set it here now.
        if case let .leaf(leaf) = surfaceTree {
            if let initialSize = leaf.surface.initialSize {
                // Setup our frame. We need to first subtract the views frame so that we can
                // just get the chrome frame so that we only affect the surface view size.
                var frame = window.frame
                frame.size.width -= leaf.surface.frame.size.width
                frame.size.height -= leaf.surface.frame.size.height
                frame.size.width += initialSize.width
                frame.size.height += initialSize.height
                
                // We have no tabs and we are not a split, so set the initial size of the window.
                window.setFrame(frame, display: true)
            }
        }
        
        // Center the window to start, we'll move the window frame automatically
        // when cascading.
        window.center()

        // Make sure our theme is set on the window so styling is correct.
        if let windowTheme = ghostty.config.windowTheme {
            window.windowTheme = .init(rawValue: windowTheme)
        }
        
        window.titleBarLuminanceCheck = ghostty.config.titleBarLuminanceCheck

        // Handle titlebar tabs config option. Something about what we do while setting up the
        // titlebar tabs interferes with the window restore process unless window.tabbingMode
        // is set to .preferred, so we set it, and switch back to automatic as soon as we can.
        if (ghostty.config.macosTitlebarTabs) {
            window.tabbingMode = .preferred
            window.titlebarTabs = true
            DispatchQueue.main.async {
                window.tabbingMode = .automatic
            }
        }
        
        if window.hasStyledTabs {
            // Set the background color of the window
            let backgroundColor = NSColor(ghostty.config.backgroundColor)
            window.backgroundColor = backgroundColor

            // This makes sure our titlebar renders correctly when there is a transparent background
            window.titlebarColor = backgroundColor.withAlphaComponent(ghostty.config.backgroundOpacity)
        }

        // Initialize our content view to the SwiftUI root
        window.contentView = NSHostingView(rootView: TerminalView(
            ghostty: self.ghostty,
            viewModel: self,
            delegate: self
        ))
        
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

        // Apply any additional appearance-related properties to the new window.
        syncAppearance()
    }
    
    // Shows the "+" button in the tab bar, responds to that click.
    override func newWindowForTab(_ sender: Any?) {
        // Trigger the ghostty core event logic for a new tab.
        guard let surface = self.focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    //MARK: - NSWindowDelegate
    
    // This is called when performClose is called on a window (NOT when close()
    // is called directly). performClose is called primarily when UI elements such
    // as the "red X" are pressed.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // We must have a window. Is it even possible not to?
        guard let window = self.window else { return true }
        
        // If we have no surfaces, close.
        guard let node = self.surfaceTree else { return true }
        
        // If we already have an alert, continue with it
        guard alert == nil else { return false }
        
        // If our surfaces don't require confirmation, close.
        if (!node.needsConfirmQuit()) { return true }
        
        // We require confirmation, so show an alert as long as we aren't already.
        let alert = NSAlert()
        alert.messageText = "Close Terminal?"
        alert.informativeText = "The terminal still has a running process. If you close the " +
        "terminal the process will be killed."
        alert.addButton(withTitle: "Close the Terminal")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window, completionHandler: { response in
            self.alert = nil
            switch (response) {
            case .alertFirstButtonReturn:
                window.close()
                
            default:
                break
            }
        })
        
        self.alert = alert
        
        return false
    }
    
    func windowWillClose(_ notification: Notification) {
        // I don't know if this is required anymore. We previously had a ref cycle between
        // the view and the window so we had to nil this out to break it but I think this
        // may now be resolved. We should verify that no memory leaks and we can remove this.
        self.window?.contentView = nil
        
        self.relabelTabs()
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        self.relabelTabs()
        self.fixTabBar()
        
        // Becoming/losing key means we have to notify our surface(s) that we have focus
        // so things like cursors blink, pty events are sent, etc.
        self.syncFocusToSurfaceTree()
    }
    
    func windowDidResignKey(_ notification: Notification) {
        // Becoming/losing key means we have to notify our surface(s) that we have focus
        // so things like cursors blink, pty events are sent, etc.
        self.syncFocusToSurfaceTree()
    }
    
    func windowDidMove(_ notification: Notification) {
        self.fixTabBar()
    }
    
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let surfaceTree = self.surfaceTree else { return }
        let visible = self.window?.occlusionState.contains(.visible) ?? false
        for leaf in surfaceTree {
            if let surface = leaf.surface.surface {
                ghostty_surface_set_occlusion(surface, visible)
            }
        }
    }

    // Called when the window will be encoded. We handle the data encoding here in the
    // window controller.
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        let data = TerminalRestorableState(from: self)
        data.encode(with: state)
    }
    
    //MARK: - First Responder
    
    @IBAction func newWindow(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newWindow(surface: surface)
    }
    
    @IBAction func newTab(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }
    
    @IBAction func close(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.requestClose(surface: surface)
    }
    
    @IBAction func closeWindow(_ sender: Any) {
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
        var needsConfirm: Bool = false
        for tabWindow in tabGroup.windows {
            guard let c = tabWindow.windowController as? TerminalController else { continue }
            if (c.surfaceTree?.needsConfirmQuit() ?? false) {
                needsConfirm = true
                break
            }
        }
        
        // If none need confirmation then we can just close all the windows.
        if (!needsConfirm) {
            for tabWindow in tabGroup.windows {
                tabWindow.close()
            }
            
            return
        }
        
        // If we need confirmation by any, show one confirmation for all windows
        // in the tab group.
        let alert = NSAlert()
        alert.messageText = "Close Window?"
        alert.informativeText = "All terminal sessions in this window will be terminated."
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window, completionHandler: { response in
            if (response == .alertFirstButtonReturn) {
                for tabWindow in tabGroup.windows {
                    tabWindow.close()
                }
            }
        })
    }
    
    @IBAction func splitRight(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_RIGHT)
    }
    
    @IBAction func splitDown(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DOWN)
    }
    
    @IBAction func splitZoom(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitToggleZoom(surface: surface)
    }
    
    @IBAction func splitMoveFocusPrevious(_ sender: Any) {
        splitMoveFocus(direction: .previous)
    }
    
    @IBAction func splitMoveFocusNext(_ sender: Any) {
        splitMoveFocus(direction: .next)
    }
    
    @IBAction func splitMoveFocusAbove(_ sender: Any) {
        splitMoveFocus(direction: .top)
    }
    
    @IBAction func splitMoveFocusBelow(_ sender: Any) {
        splitMoveFocus(direction: .bottom)
    }
    
    @IBAction func splitMoveFocusLeft(_ sender: Any) {
        splitMoveFocus(direction: .left)
    }
    
    @IBAction func splitMoveFocusRight(_ sender: Any) {
        splitMoveFocus(direction: .right)
    }

    @IBAction func equalizeSplits(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitEqualize(surface: surface)
    }

    @IBAction func moveSplitDividerUp(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .up, amount: 10)
    }

    @IBAction func moveSplitDividerDown(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .down, amount: 10)
    }

    @IBAction func moveSplitDividerLeft(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .left, amount: 10)
    }

    @IBAction func moveSplitDividerRight(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .right, amount: 10)
    }

    private func splitMoveFocus(direction: Ghostty.SplitFocusDirection) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitMoveFocus(surface: surface, direction: direction)
    }
    
    @IBAction func toggleGhosttyFullScreen(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleFullscreen(surface: surface)
    }
    
    @IBAction func increaseFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .increase(1))
    }

    @IBAction func decreaseFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .decrease(1))
    }

    @IBAction func resetFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .reset)
    }
    
    @IBAction func toggleTerminalInspector(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleTerminalInspector(surface: surface)
    }
    
    //MARK: - TerminalViewDelegate
    
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        self.focusedSurface = to
    }
    
    func titleDidChange(to: String) {
        guard let window = window as? TerminalWindow else { return }
        
        // Set the main window title
        window.title = to
        
        // Custom toolbar-based title used when titlebar tabs are enabled.
        if let toolbar = window.toolbar as? TerminalToolbar {
            toolbar.titleText = to
        }
    }
    
    func cellSizeDidChange(to: NSSize) {
        guard ghostty.config.windowStepResize else { return }
        self.window?.contentResizeIncrements = to
    }
    
    func lastSurfaceDidClose() {
        self.window?.close()
    }
    
    func surfaceTreeDidChange() {
        // Whenever our surface tree changes in any way (new split, close split, etc.)
        // we want to invalidate our state.
        invalidateRestorableState()
    }

    func zoomStateDidChange(to: Bool) {
        guard let window = window as? TerminalWindow else { return }
        window.surfaceIsZoomed = to
    }

    //MARK: - Clipboard Confirmation
    
    func clipboardConfirmationComplete(_ action: ClipboardConfirmationView.Action, _ request: Ghostty.ClipboardRequest) {
        // End our clipboard confirmation no matter what
        guard let cc = self.clipboardConfirmation else { return }
        self.clipboardConfirmation = nil

        // Close the sheet
        if let ccWindow = cc.window {
            window?.endSheet(ccWindow)
        }

        switch (request) {
        case .osc_52_write:
            guard case .confirm = action else { break }
            let pb = NSPasteboard.general
            pb.declareTypes([.string], owner: nil)
            pb.setString(cc.contents, forType: .string)
        case .osc_52_read, .paste:
            let str: String
            switch (action) {
            case .cancel:
                str = ""

            case .confirm:
                str = cc.contents
            }

            Ghostty.App.completeClipboardRequest(cc.surface, data: str, state: cc.state, confirmed: true)
        }
    }
    
    //MARK: - Notifications
    
    @objc private func onGotoTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }
        
        // Get the tab index from the notification
        guard let tabIndexAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabIndex = tabIndexAny as? Int32 else { return }
        
        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        let tabbedWindows = tabGroup.windows
        
        // This will be the index we want to actual go to
        let finalIndex: Int
        
        // An index that is invalid is used to signal some special values.
        if (tabIndex <= 0) {
            guard let selectedWindow = tabGroup.selectedWindow else { return }
            guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }
            
            if (tabIndex == GHOSTTY_TAB_PREVIOUS.rawValue) {
                if (selectedIndex == 0) {
                    finalIndex = tabbedWindows.count - 1
                } else {
                    finalIndex = selectedIndex - 1
                }
            } else if (tabIndex == GHOSTTY_TAB_NEXT.rawValue) {
                if (selectedIndex == tabbedWindows.count - 1) {
                    finalIndex = 0
                } else {
                    finalIndex = selectedIndex + 1
                }
            } else {
                return
            }
        } else {
            // Tabs are 0-indexed here, so we subtract one from the key the user hit.
            finalIndex = Int(tabIndex - 1)
        }
        
        guard finalIndex >= 0 && finalIndex < tabbedWindows.count else { return }
        let targetWindow = tabbedWindows[finalIndex]
        targetWindow.makeKeyAndOrderFront(nil)
    }

    
    @objc private func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        
        // We need a window to fullscreen
        guard let window = self.window else { return }
        
        // Check whether we use non-native fullscreen
        guard let useNonNativeFullscreenAny = notification.userInfo?[Ghostty.Notification.NonNativeFullscreenKey] else { return }
        guard let useNonNativeFullscreen = useNonNativeFullscreenAny as? ghostty_non_native_fullscreen_e else { return }
        self.fullscreenHandler.toggleFullscreen(window: window, nonNativeFullscreen: useNonNativeFullscreen)
        
        // For some reason focus always gets lost when we toggle fullscreen, so we set it back.
        if let focusedSurface {
            Ghostty.moveFocus(to: focusedSurface)
        }
    }
    
    @objc private func onConfirmClipboardRequest(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let surface = target.surface else { return }
        
        // We need a window
        guard let window = self.window else { return }
        
        // Check whether we use non-native fullscreen
        guard let str = notification.userInfo?[Ghostty.Notification.ConfirmClipboardStrKey] as? String else { return }
        guard let state = notification.userInfo?[Ghostty.Notification.ConfirmClipboardStateKey] as? UnsafeMutableRawPointer? else { return }
        guard let request = notification.userInfo?[Ghostty.Notification.ConfirmClipboardRequestKey] as? Ghostty.ClipboardRequest else { return }
        
        // If we already have a clipboard confirmation view up, we ignore this request.
        // This shouldn't be possible...
        guard self.clipboardConfirmation == nil else {
            Ghostty.App.completeClipboardRequest(surface, data: "", state: state, confirmed: true)
            return
        }
        
        // Show our paste confirmation
        self.clipboardConfirmation = ClipboardConfirmationController(
            surface: surface,
            contents: str,
            request: request,
            state: state,
            delegate: self
        )
        window.beginSheet(self.clipboardConfirmation!.window!)
    }
}
