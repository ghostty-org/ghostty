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
    let ghostty: Ghostty.AppState
    
    /// The currently focused surface.
    var focusedSurface: Ghostty.SurfaceView? = nil

    /// The surface tree for this window.
    @Published var surfaceTree: Ghostty.SplitNode? = nil {
        didSet {
            // If our surface tree becomes nil then ensure all surfaces
            // in the old tree have closed and then close the window.
            if (surfaceTree == nil) {
                oldValue?.close()
                lastSurfaceDidClose()
            }
        }
    }
    
    /// Fullscreen state management.
    private let fullscreenHandler = FullScreenHandler()
    
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
    
    init(_ ghostty: Ghostty.AppState, withBaseConfig base: Ghostty.SurfaceConfiguration? = nil) {
        self.ghostty = ghostty
        super.init(window: nil)
        
        // Initialize our initial surface.
        guard let ghostty_app = ghostty.app else { preconditionFailure("app must be loaded") }
        self.surfaceTree = .leaf(.init(ghostty_app, base))
        
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

    /// Update the accessory view of each tab according to the keyboard
    /// shortcut that activates it (if any). This is called when the key window
    /// changes and when a window is closed.
    func relabelTabs() {
        // Reset this to false. It'll be set back to true later.
        tabListenForFrame = false
        
        guard let windows = self.window?.tabbedWindows else { return }
        guard let cfg = ghostty.config else { return }

        // We only listen for frame changes if we have more than 1 window,
        // otherwise the accessory view doesn't matter.
        tabListenForFrame = windows.count > 1
        
        for (index, window) in windows.enumerated().prefix(9) {
            let action = "goto_tab:\(index + 1)"
            let trigger = ghostty_config_trigger(cfg, action, UInt(action.count))
            guard let equiv = Ghostty.keyEquivalentLabel(key: trigger.key, mods: trigger.mods) else {
                continue
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.labelFont(ofSize: 0),
                .foregroundColor: window.isKeyWindow ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            let attributedString = NSAttributedString(string: " \(equiv) ", attributes: attributes)
            let text = NSTextField(labelWithAttributedString: attributedString)
            text.setContentCompressionResistancePriority(.windowSizeStayPut, for: .horizontal)
            text.postsFrameChangedNotifications = true
            window.tab.accessoryView = text
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

    //MARK: - NSWindowController
    
    override func windowWillLoad() {
        // We do NOT want to cascade because we handle this manually from the manager.
        shouldCascadeWindows = false
    }
    
    override func windowDidLoad() {
        guard let window = window else { return }

        // If window decorations are disabled, remove our title
        if (!ghostty.windowDecorations) { window.styleMask.remove(.titled) }
        
        // Terminals typically operate in sRGB color space and macOS defaults
        // to "native" which is typically P3. There is a lot more resources
        // covered in thie GitHub issue: https://github.com/mitchellh/ghostty/pull/376
        window.colorSpace = NSColorSpace.sRGB
        
        // Center the window to start, we'll move the window frame automatically
        // when cascading.
        window.center()
        
        // Initialize our content view to the SwiftUI root
        window.contentView = NSHostingView(rootView: TerminalView(
            ghostty: self.ghostty,
            viewModel: self,
            delegate: self
        ))
        
        // If the user tabbing preference is always, then macOS automatically tabs
        // all new windows. Ghostty handles its own tabbing so we DONT want this behavior.
        // This detects this scenario and undoes it.
        //
        // We don't run this logic in fullscreen because in fullscreen this will end up
        // removing the window and putting it into its own dedicated fullscreen, which is not
        // the expected or desired behavior of anyone I've found.
        if (NSWindow.userTabbingPreference == .always &&
            !window.styleMask.contains(.fullScreen)) {
            // If we have more than 1 window in our tab group we know we're a new window.
            // Since Ghostty manages tabbing manually this will never be more than one
            // at this point in the AppKit lifecycle (we add to the group after this).
            if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
                window.tabGroup?.removeWindow(window)
            }
        }
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
        self.window?.performClose(sender)
    }
    
    @IBAction func splitHorizontally(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_RIGHT)
    }
    
    @IBAction func splitVertically(_ sender: Any) {
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
        self.window?.title = to
    }
    
    func cellSizeDidChange(to: NSSize) {
        guard ghostty.windowStepResize else { return }
        self.window?.contentResizeIncrements = to
    }
    
    func lastSurfaceDidClose() {
        self.window?.close()
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

            Ghostty.AppState.completeClipboardRequest(cc.surface, data: str, state: cc.state, confirmed: true)
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
                finalIndex = selectedIndex - 1
            } else if (tabIndex == GHOSTTY_TAB_NEXT.rawValue) {
                finalIndex = selectedIndex + 1
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
            Ghostty.AppState.completeClipboardRequest(surface, data: "", state: state, confirmed: true)
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
