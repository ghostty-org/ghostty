import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

/// Controller for the "quick" terminal.
class QuickTerminalController: BaseTerminalController {
    override var windowNibName: NSNib.Name? { "QuickTerminal" }

    /// The position for the quick terminal.
    let position: QuickTerminalPosition

    /// The current state of the quick terminal
    private(set) var visible: Bool = false

    /// The previously running application when the terminal is shown. This is NEVER Ghostty.
    /// If this is set then when the quick terminal is animated out then we will restore this
    /// application to the front.
    private var previousApp: NSRunningApplication?

    // The active space when the quick terminal was last shown.
    private var previousActiveSpace: CGSSpace?

    /// Cache for per-screen window state.
    let screenStateCache: QuickTerminalScreenStateCache

    /// Non-nil if we have hidden dock state.
    private var hiddenDock: HiddenDock?

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private var derivedConfig: DerivedConfig

    /// Tracks if we're currently handling a manual resize to prevent recursion
    private var isHandlingResize: Bool = false

    /// This is set to false by init if the window managed by this controller should not be restorable.
    /// For example, terminals executing custom scripts are not restorable.
    let restorable: Bool
    private var restorationState: QuickTerminalRestorableState?

    init(_ ghostty: Ghostty.App,
         position: QuickTerminalPosition = .top,
         baseConfig base: Ghostty.SurfaceConfiguration? = nil,
         restorationState: QuickTerminalRestorableState? = nil,
    ) {
        self.position = position
        self.derivedConfig = DerivedConfig(ghostty.config)
        // The window we manage is not restorable if we've specified a command
        // to execute. We do this because the restored window is meaningless at the
        // time of writing this: it'd just restore to a shell in the same directory
        // as the script. We may want to revisit this behavior when we have scrollback
        // restoration.
        restorable = (base?.command ?? "") == ""
        self.restorationState = restorationState
        self.screenStateCache = QuickTerminalScreenStateCache(stateByDisplay: restorationState?.screenStateEntries ?? [:])
        // Important detail here: we initialize with an empty surface tree so
        // that we don't start a terminal process. This gets started when the
        // first terminal is shown in `animateIn`.
        super.init(ghostty, baseConfig: base, surfaceTree: .init())

        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen(notification:)),
            name: Ghostty.Notification.ghosttyToggleFullscreen,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(closeWindow(_:)),
            name: .ghosttyCloseWindow,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onNewTab),
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        // Remove all of our notificationcenter subscriptions
        let center = NotificationCenter.default
        center.removeObserver(self)

        // Make sure we restore our hidden dock
        hiddenDock = nil
    }

    // MARK: NSWindowController

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window = self.window else { return }

        // The controller is the window delegate so we can detect events such as
        // window close so we can animate out.
        window.delegate = self

        // The quick window is restored by `screenStateCache`.
        // We disable this for better control
        window.isRestorable = false

        // Setup our configured appearance that we support.
        syncAppearance()

        // Setup our initial size based on our configured position
        position.setLoaded(window, size: derivedConfig.quickTerminalSize)

        // Upon first adding this Window to its host view, older SwiftUI
        // seems to have a "hiccup" and corrupts the frameRect,
        // sometimes setting the size to zero, sometimes corrupting it.
        // We pass the actual window's frame as "initial" frame directly
        // to the window, so it can use that instead of the frameworks
        // "interpretation"
        if let qtWindow = window as? QuickTerminalWindow {
            qtWindow.initialFrame = window.frame
        }

        // Setup our content
        window.contentView = TerminalViewContainer {
            TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
        }

        // Clear out our frame at this point, the fixup from above is complete.
        if let qtWindow = window as? QuickTerminalWindow {
            qtWindow.initialFrame = nil
        }

        // Animate the window in
        animateIn()
    }

    // MARK: NSWindowDelegate

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)

        // If we're not visible we don't care to run the logic below. It only
        // applies if we can be seen.
        guard visible else { return }

        terminalViewContainer?.updateGlassTintOverlay(isKeyWindow: true)

        // Re-hide the dock if we were hiding it before.
        hiddenDock?.hide()
    }

    override func windowDidResignKey(_ notification: Notification) {
        super.windowDidResignKey(notification)

        // If we're not visible then we don't want to run any of the logic below
        // because things like resetting our previous app assume we're visible.
        // windowDidResignKey will also get called after animateOut so this
        // ensures we don't run logic twice.
        guard visible else { return }

        terminalViewContainer?.updateGlassTintOverlay(isKeyWindow: false)

        // We don't animate out if there is a modal sheet being shown currently.
        // This lets us show alerts without causing the window to disappear.
        guard window?.attachedSheet == nil else { return }

        // If our app is still active, then it means that we're switching
        // to another window within our app, so we remove the previous app
        // so we don't restore it.
        if NSApp.isActive {
            self.previousApp = nil
        }

        // Regardless of autohide, we always want to bring the dock back
        // when we lose focus.
        hiddenDock?.restore()

        if derivedConfig.quickTerminalAutoHide {
            switch derivedConfig.quickTerminalSpaceBehavior {
            case .remain:
                // If we lose focus on the active space, then we can animate out
                animateOut()

            case .move:
                let currentActiveSpace = CGSSpace.active()
                if previousActiveSpace == currentActiveSpace {
                    // We haven't moved spaces. We lost focus to another app on the
                    // current space. Animate out.
                    animateOut()
                } else {
                    // We've moved to a different space.

                    // If we're fullscreen, we need to exit fullscreen because the visible
                    // bounds may have changed causing a new behavior.
                    if let fullscreenStyle, fullscreenStyle.isFullscreen {
                        fullscreenStyle.exit()
                        DispatchQueue.main.async {
                            self.onToggleFullscreen()
                        }
                    }

                    // Make the window visible again on this space
                    DispatchQueue.main.async {
                        self.window?.makeKeyAndOrderFront(nil)
                    }

                    self.previousActiveSpace = currentActiveSpace
                }
            }
        }
    }

    override func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == self.window,
              visible,
              !isHandlingResize else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }

        // Prevent recursive loops
        isHandlingResize = true
        defer { isHandlingResize = false }

        switch position {
        case .top, .bottom, .center:
            // For centered positions (top, bottom, center), we need to recenter the window
            // when it's manually resized to maintain proper positioning
            let newOrigin = position.centeredOrigin(for: window, on: screen)
            window.setFrameOrigin(newOrigin)
        case .left, .right:
            // For side positions, we may need to adjust vertical centering
            let newOrigin = position.verticallyCenteredOrigin(for: window, on: screen)
            window.setFrameOrigin(newOrigin)
        }
    }

    // MARK: Base Controller Overrides

    override func focusSurface(_ view: Ghostty.SurfaceView) {
        if visible {
            // If we're visible, we just focus the surface as normal.
            super.focusSurface(view)
            return
        }
        // Check if target surface belongs to this quick terminal
        guard surfaceTree.contains(view) else { return }
        // Set the target surface as focused
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: view)
        }
        // Animation completion handler will handle window/app activation
        animateIn()
    }

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)

        // If our surface tree is nil then we animate the window out. We
        // defer reinitializing the tree to save some memory here.
        if to.isEmpty {
            animateOut()
            return
        }

        // If we're not empty (e.g. this isn't the first set) and we're
        // not visible, then we animate in. This allows us to show the quick
        // terminal when things such as undo/redo are done.
        if !from.isEmpty && !visible {
            animateIn()
            return
        }
    }

    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // If this isn't the root then we're dealing with a split closure.
        if surfaceTree.root != node {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        // If this isn't a final leaf then we're dealing with a split closure
        guard case .leaf(let surface) = node else {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        // If its the root, we check if the process exited. If it did,
        // then we do empty the tree.
        if surface.processExited {
            surfaceTree = .init()
            return
        }

        // If its the root then we just animate out. We never actually allow
        // the surface to fully close.
        animateOut()
    }

    // MARK: Methods

    func toggle() {
        if visible {
            animateOut()
        } else {
            animateIn()
        }
    }

    func animateIn() {
        guard let window = self.window else { return }

        // Set our visibility state
        guard !visible else { return }
        visible = true

        // Notify the change
        NotificationCenter.default.post(
            name: .quickTerminalDidChangeVisibility,
            object: self
        )

        // If we have a previously focused application and it isn't us, then
        // we want to store it so we can restore state later.
        if !NSApp.isActive {
            if let previousApp = NSWorkspace.shared.frontmostApplication,
               previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.previousApp = previousApp
            }
        }

        // Set previous active space
        self.previousActiveSpace = CGSSpace.active()

        // If our surface tree is empty then we initialize a new terminal. The surface
        // tree can be empty if for example we run "exit" in the terminal and force
        // animate out.
        if surfaceTree.isEmpty,
           let ghostty_app = ghostty.app {
            if let tree = restorationState?.surfaceTree, !tree.isEmpty {
                surfaceTree = tree
                let view = tree.first(where: { $0.id.uuidString == restorationState?.focusedSurface }) ?? tree.first!
                focusedSurface = view
                // Add a short delay to check if the correct surface is focused.
                // Each SurfaceWrapper defaults its FocusedValue to itself; without this delay,
                // the tree often focuses the first surface instead of the intended one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if !view.focused {
                        self.focusedSurface = view
                        self.makeWindowKey(window)
                    }
                }
            } else {
                var config = Ghostty.SurfaceConfiguration()
                config.environmentVariables["GHOSTTY_QUICK_TERMINAL"] = "1"

                let view = Ghostty.SurfaceView(ghostty_app, baseConfig: config)
                surfaceTree = SplitTree(view: view)
                focusedSurface = view
            }
        }

        // Animate the window in
        animateWindowIn(window: window, from: position)
        // Clear the restoration state after first use
        restorationState = nil
    }

    func animateOut() {
        guard let window = self.window else { return }

        // Set our visibility state
        guard visible else { return }
        visible = false

        // Notify the change
        NotificationCenter.default.post(
            name: .quickTerminalDidChangeVisibility,
            object: self
        )

        animateWindowOut(window: window, to: position)
    }

    func saveScreenState(exitFullscreen: Bool) {
        // If we are in fullscreen, then we exit fullscreen. We do this immediately so
        // we have th correct window.frame for the save state below.
        if exitFullscreen, let fullscreenStyle, fullscreenStyle.isFullscreen {
            fullscreenStyle.exit()
        }
        guard let window else { return }
        // Save the current window frame before animating out. This preserves
        // the user's preferred window size and position for when the quick
        // terminal is reactivated with a new surface. Without this, SwiftUI
        // would reset the window to its minimum content size.
        if window.frame.width > 0 && window.frame.height > 0, let screen = window.screen {
            screenStateCache.save(frame: window.frame, for: screen)
        }
    }

    private func animateWindowIn(window: NSWindow, from position: QuickTerminalPosition) {
        guard let screen = derivedConfig.quickTerminalScreen.screen else { return }

        // Grab our last closed frame to use from the cache.
        let closedFrame = screenStateCache.frame(for: screen)

        // Move our window off screen to the initial animation position.
        position.setInitial(
            in: window,
            on: screen,
            terminalSize: derivedConfig.quickTerminalSize,
            closedFrame: closedFrame)

        // We need to set our window level to a high value. In testing, only
        // popUpMenu and above do what we want. This gets it above the menu bar
        // and lets us render off screen.
        window.level = .popUpMenu

        // Move it to the visible position since animation requires this
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
        }

        // If our dock position would conflict with our target location then
        // we autohide the dock.
        if position.conflictsWithDock(on: screen) {
            if hiddenDock == nil {
                hiddenDock = .init()
            }

            hiddenDock?.hide()
        } else {
            // Ensure we don't have any hidden dock if we don't conflict.
            // The deinit will restore.
            hiddenDock = nil
        }

        // Run the animation that moves our window into the proper place and makes
        // it visible.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = derivedConfig.quickTerminalAnimationDuration
            context.timingFunction = .init(name: .easeIn)
            position.setFinal(
                in: window.animator(),
                on: screen,
                terminalSize: derivedConfig.quickTerminalSize,
                closedFrame: closedFrame)
        }, completionHandler: {
            // There is a very minor delay here so waiting at least an event loop tick
            // keeps us safe from the view not being on the window.
            DispatchQueue.main.async {
                // If we canceled our animation clean up some state.
                guard self.visible else {
                    self.hiddenDock = nil
                    return
                }

                // After animating in, we reset the window level to a value that
                // is above other windows but not as high as popUpMenu. This allows
                // things like IME dropdowns to appear properly.
                window.level = .floating

                // Now that the window is visible, sync our appearance. This function
                // requires the window is visible.
                self.syncAppearance()

                // Once our animation is done, we must grab focus since we can't grab
                // focus of a non-visible window.
                self.makeWindowKey(window)

                // If our application is not active, then we grab focus. Its important
                // we do this AFTER our window is animated in and focused because
                // otherwise macOS will bring forward another window.
                if !NSApp.isActive {
                    NSApp.activate(ignoringOtherApps: true)

                    // This works around a really funky bug where if the terminal is
                    // shown on a screen that has no other Ghostty windows, it takes
                    // a few (variable) event loop ticks until we can actually focus it.
                    // https://github.com/ghostty-org/ghostty/issues/2409
                    //
                    // We wait one event loop tick to try it because under the happy
                    // path (we have windows on this screen) it takes one event loop
                    // tick for window.isKeyWindow to return true.
                    DispatchQueue.main.async {
                        guard !window.isKeyWindow else { return }
                        self.makeWindowKey(window, retries: 10)
                    }
                }
            }
        })
    }

    /// Attempt to make a window key, supporting retries if necessary. The retries will be attempted
    /// on a separate event loop tick.
    ///
    /// The window must contain the focused surface for this terminal controller.
    private func makeWindowKey(_ window: NSWindow, retries: UInt8 = 0) {
        // We must be visible
        guard visible else { return }

        // If our focused view is somehow not connected to this window then the
        // function calls below do nothing. I don't think this is possible but
        // we should guard against it because it is a Cocoa assertion.
        guard let focusedSurface, focusedSurface.window == window else { return }

        // The window must become top-level
        window.makeKeyAndOrderFront(nil)

        // The view must gain our keyboard focus
        window.makeFirstResponder(focusedSurface)

        // If our window is already key then we're done!
        guard !window.isKeyWindow else { return }

        // If we don't have retries then we're done
        guard retries > 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) {
            self.makeWindowKey(window, retries: retries - 1)
        }
    }

    private func animateWindowOut(window: NSWindow, to position: QuickTerminalPosition) {
        saveScreenState(exitFullscreen: true)

        // If we hid the dock then we unhide it.
        hiddenDock = nil

        // If the window isn't on our active space then we don't animate, we just
        // hide it.
        if !window.isOnActiveSpace {
            self.previousApp = nil
            window.orderOut(self)
            // If our application is hidden previously, we hide it again
            if (NSApp.delegate as? AppDelegate)?.hiddenState != nil {
                NSApp.hide(nil)
            }
            return
        }

        // We always animate out to whatever screen the window is actually on.
        guard let screen = window.screen ?? NSScreen.main else { return }

        // If we have a previously active application, restore focus to it. We
        // do this BEFORE the animation below because when the animation completes
        // macOS will bring forward another window.
        if let previousApp = self.previousApp {
            // Make sure we unset the state no matter what
            self.previousApp = nil

            if !previousApp.isTerminated {
                // Ignore the result, it doesn't change our behavior.
                _ = previousApp.activate(options: [])
            }
        }

        // We need to set our window level to a high value. In testing, only
        // popUpMenu and above do what we want. This gets it above the menu bar
        // and lets us render off screen.
        window.level = .popUpMenu

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = derivedConfig.quickTerminalAnimationDuration
            context.timingFunction = .init(name: .easeIn)
            position.setInitial(
                in: window.animator(),
                on: screen,
                terminalSize: derivedConfig.quickTerminalSize,
                closedFrame: window.frame)
        }, completionHandler: {
            // This causes the window to be removed from the screen list and macOS
            // handles what should be focused next.
            window.orderOut(self)
            // If our application is hidden previously, we hide it again
            if (NSApp.delegate as? AppDelegate)?.hiddenState != nil {
                NSApp.hide(nil)
            }
        })
    }

    override func syncAppearance() {
        guard let window else { return }

        defer { updateColorSchemeForSurfaceTree() }
        // Change the collection behavior of the window depending on the configuration.
        window.collectionBehavior = derivedConfig.quickTerminalSpaceBehavior.collectionBehavior

        // If our window is not visible, then no need to sync the appearance yet.
        // Some APIs such as window blur have no effect unless the window is visible.
        guard window.isVisible else { return }

        // If we have window transparency then set it transparent. Otherwise set it opaque.
        // Also check if the user has overridden transparency to be fully opaque.
        if !isBackgroundOpaque && (self.derivedConfig.backgroundOpacity < 1 || derivedConfig.backgroundBlur.isGlassStyle) {
            window.isOpaque = false

            // This is weird, but we don't use ".clear" because this creates a look that
            // matches Terminal.app much more closer. This lets users transition from
            // Terminal.app more easily.
            window.backgroundColor = .white.withAlphaComponent(0.001)

            if !derivedConfig.backgroundBlur.isGlassStyle {
                ghostty_set_window_background_blur(ghostty.app, Unmanaged.passUnretained(window).toOpaque())
            }
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }
    }

    private func showNoNewTabAlert() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Cannot Create New Tab"
        alert.informativeText = "Tabs aren't supported in the Quick Terminal."
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }
    // MARK: First Responder

    @IBAction override func closeWindow(_ sender: Any) {
        // Instead of closing the window, we animate it out.
        animateOut()
    }

    @IBAction func newTab(_ sender: Any?) {
        showNoNewTabAlert()
    }

    @IBAction func toggleGhosttyFullScreen(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleFullscreen(surface: surface)
    }

    @IBAction func toggleTerminalInspector(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleTerminalInspector(surface: surface)
    }

    // MARK: Notifications

    @objc private func applicationWillTerminate(_ notification: Notification) {
        // If the application is going to terminate we want to make sure we
        // restore any global dock state. I think deinit should be called which
        // would call this anyways but I can't be sure so I will do this too.
        hiddenDock = nil
    }

    @objc private func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        onToggleFullscreen()
    }

    private func onToggleFullscreen() {
        // We ignore the configured fullscreen style and always use non-native
        // because the way the quick terminal works doesn't support native.
        let mode: FullscreenMode
        if NSApp.isFrontmost {
            // If we're frontmost and we have a notch then we keep padding
            // so all lines of the terminal are visible.
            if window?.screen?.hasNotch ?? false {
                mode = .nonNativePaddedNotch
            } else {
                mode = .nonNative
            }
        } else {
            // An additional detail is that if the is NOT frontmost, then our
            // NSApp.presentationOptions will not take effect so we must always
            // do the visible menu mode since we can't get rid of the menu.
            mode = .nonNativeVisibleMenu
        }

        toggleFullscreen(mode: mode)
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

        syncAppearance()

        terminalViewContainer?.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
    }

    @objc private func onNewTab(notification: SwiftUI.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard let window = surfaceView.window else { return }
        guard window.windowController is QuickTerminalController else { return }
        // Tabs aren't supported with Quick Terminals or derivatives
        showNoNewTabAlert()
    }

    private struct DerivedConfig {
        let quickTerminalScreen: QuickTerminalScreen
        let quickTerminalAnimationDuration: Double
        let quickTerminalAutoHide: Bool
        let quickTerminalSpaceBehavior: QuickTerminalSpaceBehavior
        let quickTerminalSize: QuickTerminalSize
        let backgroundOpacity: Double
        let backgroundBlur: Ghostty.Config.BackgroundBlur

        init() {
            self.quickTerminalScreen = .main
            self.quickTerminalAnimationDuration = 0.2
            self.quickTerminalAutoHide = true
            self.quickTerminalSpaceBehavior = .move
            self.quickTerminalSize = QuickTerminalSize()
            self.backgroundOpacity = 1.0
            self.backgroundBlur = .disabled
        }

        init(_ config: Ghostty.Config) {
            self.quickTerminalScreen = config.quickTerminalScreen
            self.quickTerminalAnimationDuration = config.quickTerminalAnimationDuration
            self.quickTerminalAutoHide = config.quickTerminalAutoHide
            self.quickTerminalSpaceBehavior = config.quickTerminalSpaceBehavior
            self.quickTerminalSize = config.quickTerminalSize
            self.backgroundOpacity = config.backgroundOpacity
            self.backgroundBlur = config.backgroundBlur
        }
    }

    /// Hides the dock globally (not just NSApp). This is only used if the quick terminal is
    /// in a conflicting position with the dock.
    private class HiddenDock {
        let previousAutoHide: Bool
        private var hidden: Bool = false

        init() {
            previousAutoHide = Dock.autoHideEnabled
        }

        deinit {
            restore()
        }

        func hide() {
            guard !hidden else { return }
            NSApp.acquirePresentationOption(.autoHideDock)
            Dock.autoHideEnabled = true
            hidden = true
        }

        func restore() {
            guard hidden else { return }
            NSApp.releasePresentationOption(.autoHideDock)
            Dock.autoHideEnabled = previousAutoHide
            hidden = false
        }
    }
}

extension Notification.Name {
    /// The quick terminal did become hidden or visible.
    static let quickTerminalDidChangeVisibility = Notification.Name("QuickTerminalDidChangeVisibility")
}
