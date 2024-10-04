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
    private var previousApp: NSRunningApplication? = nil

    init(_ ghostty: Ghostty.App,
         position: QuickTerminalPosition = .top,
         baseConfig base: Ghostty.SurfaceConfiguration? = nil,
         surfaceTree tree: Ghostty.SplitNode? = nil
    ) {
        self.position = position
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
            selector: #selector(ghosttyDidReloadConfig),
            name: Ghostty.Notification.ghosttyDidReloadConfig,
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

    // MARK: NSWindowController

    override func windowDidLoad() {
        guard let window = self.window else { return }

        // The controller is the window delegate so we can detect events such as
        // window close so we can animate out.
        window.delegate = self

        // The quick window is not restorable (yet!). "Yet" because in theory we can
        // make this restorable, but it isn't currently implemented.
        window.isRestorable = false

        // Setup our configured appearance that we support.
        syncAppearance()

        // Setup our initial size based on our configured position
        position.setLoaded(window, size: ghostty.config.quickTerminalSize)

        // Setup our content
        window.contentView = NSHostingView(rootView: TerminalView(
            ghostty: self.ghostty,
            viewModel: self,
            delegate: self
        ))

        // Animate the window in
        animateIn()
    }

    // MARK: NSWindowDelegate

    override func windowDidResignKey(_ notification: Notification) {
        super.windowDidResignKey(notification)

        // If we're not visible then we don't want to run any of the logic below
        // because things like resetting our previous app assume we're visible.
        // windowDidResignKey will also get called after animateOut so this
        // ensures we don't run logic twice.
        guard visible else { return }

        // We don't animate out if there is a modal sheet being shown currently.
        // This lets us show alerts without causing the window to disappear.
        guard window?.attachedSheet == nil else { return }

        // If our app is still active, then it means that we're switching
        // to another window within our app, so we remove the previous app
        // so we don't restore it.
        if NSApp.isActive {
            self.previousApp = nil
        }

        animateOut()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // We use the actual screen the window is on for this, since it should
        // be on the proper screen.
        guard let screen = window?.screen ?? NSScreen.main else { return frameSize }
        return position.restrictFrameSize(frameSize, on: screen)
    }

    // MARK: Base Controller Overrides

    override func surfaceTreeDidChange(from: Ghostty.SplitNode?, to: Ghostty.SplitNode?) {
        super.surfaceTreeDidChange(from: from, to: to)

        // If our surface tree is nil then we animate the window out.
        if (to == nil) {
            animateOut()
        }
    }

    // MARK: Methods

    func toggle() {
        if (visible) {
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

        // If we have a previously focused application and it isn't us, then
        // we want to store it so we can restore state later.
        if !NSApp.isActive {
            if let previousApp = NSWorkspace.shared.frontmostApplication,
               previousApp.bundleIdentifier != Bundle.main.bundleIdentifier
            {
                self.previousApp = previousApp
            }
        }

        // Animate the window in
        animateWindowIn(window: window, from: position)

        // If our surface tree is nil then we initialize a new terminal. The surface
        // tree can be nil if for example we run "eixt" in the terminal and force
        // animate out.
        if (surfaceTree == nil) {
            let leaf: Ghostty.SplitNode.Leaf = .init(ghostty.app!, baseConfig: nil)
            surfaceTree = .leaf(leaf)
            focusedSurface = leaf.surface
        }
    }

    func animateOut() {
        guard let window = self.window else { return }

        // Set our visibility state
        guard visible else { return }
        visible = false

        animateWindowOut(window: window, to: position)
    }

    private func animateWindowIn(window: NSWindow, from position: QuickTerminalPosition) {
        guard let screen = ghostty.config.quickTerminalScreen.screen else { return }

        // Move our window off screen to the top
        position.setInitial(in: window, on: screen)

        // Move it to the visible position since animation requires this
        window.makeKeyAndOrderFront(nil)

        // Run the animation that moves our window into the proper place and makes
        // it visible.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = .init(name: .easeIn)
            position.setFinal(in: window.animator(), on: screen)
        }, completionHandler: {
            // There is a very minor delay here so waiting at least an event loop tick
            // keeps us safe from the view not being on the window.
            DispatchQueue.main.async {
                // If we canceled our animation in we do nothing
                guard self.visible else { return }

                // If our focused view is somehow not connected to this window then the
                // function calls below do nothing. I don't think this is possible but
                // we should guard against it because it is a Cocoa assertion.
                guard let focusedView = self.focusedSurface,
                      focusedView.window == window else { return }

                // The window must become top-level
                window.makeKeyAndOrderFront(nil)

                // The view must gain our keyboard focus
                window.makeFirstResponder(focusedView)

                // If our application is not active, then we grab focus. Its important
                // we do this AFTER our window is animated in and focused because
                // otherwise macOS will bring forward another window.
                if !NSApp.isActive {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        })
    }

    private func animateWindowOut(window: NSWindow, to position: QuickTerminalPosition) {
        // We always animate out to whatever screen the window is actually on.
        guard let screen = window.screen ?? NSScreen.main else { return }

        // If we are in fullscreen, then we exit fullscreen.
        if let fullscreenStyle, fullscreenStyle.isFullscreen {
            fullscreenStyle.exit()
        }

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

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = .init(name: .easeIn)
            position.setInitial(in: window.animator(), on: screen)
        }, completionHandler: {
            // This causes the window to be removed from the screen list and macOS
            // handles what should be focused next.
            window.orderOut(self)
        })
    }

    private func syncAppearance() {
        guard let window else { return }

        // If we have window transparency then set it transparent. Otherwise set it opaque.
        if (ghostty.config.backgroundOpacity < 1) {
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
    }

    // MARK: First Responder

    @IBAction override func closeWindow(_ sender: Any) {
        // Instead of closing the window, we animate it out.
        animateOut()
    }

    @IBAction func newTab(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Cannot Create New Tab"
        alert.informativeText = "Tabs aren't supported in the Quick Terminal."
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    @IBAction func toggleGhosttyFullScreen(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleFullscreen(surface: surface)
    }

    // MARK: Notifications

    @objc private func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // We ignore the requested mode and always use non-native for the quick terminal
        toggleFullscreen(mode: .nonNative)
    }

    @objc private func ghosttyDidReloadConfig(notification: SwiftUI.Notification) {
        syncAppearance()
    }
}
