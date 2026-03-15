import Cocoa
import SwiftUI
import GhosttyKit

/// Per-instance lifecycle manager for a popup terminal.
///
/// Each PopupController owns one PopupWindow and (lazily) one Ghostty
/// terminal surface. It handles show/hide/toggle, window positioning,
/// and autohide-on-focus-loss.
class PopupController: BaseTerminalController {

    // MARK: - Types

    /// Lightweight value type holding the resolved configuration for one
    /// popup profile.  Defaults match a reasonable center-screen popup.
    struct PopupProfileConfig {
        /// Position values must match the Zig enum order in apprt/popup.zig:
        /// center=0, top=1, bottom=2, left=3, right=4
        enum Position: Int {
            case center = 0
            case top = 1
            case bottom = 2
            case left = 3
            case right = 4
        }
        var position: Position = .center
        var widthValue: UInt32 = 80
        var widthIsPercent: Bool = true
        var heightValue: UInt32 = 80
        var heightIsPercent: Bool = true
        var autohide: Bool = true
        var persist: Bool = true
        var command: String? = nil
        var cwd: String? = nil
        var opacity: Double? = nil  // nil means inherit global background-opacity
    }

    // MARK: - Properties

    let profileName: String
    let profileConfig: PopupProfileConfig
    private(set) var visible: Bool = false

    /// The previously running application when the popup was shown.
    /// Restored on hide so the user returns to what they were doing.
    private var previousApp: NSRunningApplication?

    // MARK: - Init

    init(
        name: String,
        config: PopupProfileConfig,
        ghosttyApp: Ghostty.App
    ) {
        self.profileName = name
        self.profileConfig = config

        // Start with an empty surface tree — the terminal process is
        // created lazily on first show(), same as QuickTerminalController.
        super.init(ghosttyApp, baseConfig: Ghostty.SurfaceConfiguration(), surfaceTree: .init())

        // Create the window programmatically (no XIB).
        let window = PopupWindow(
            profileName: name,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        self.window = window
        window.delegate = self
        window.isRestorable = false

        // Observe focus loss for autohide behavior.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onWindowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    func toggle() {
        if visible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard !visible else { return }

        // Remember the previously focused app so we can restore it on hide.
        if !NSApp.isActive {
            if let frontApp = NSWorkspace.shared.frontmostApplication,
               frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                previousApp = frontApp
            }
        }

        // Lazily create the terminal surface on first show.
        if surfaceTree.isEmpty, let app = ghostty.app {
            let view = Ghostty.SurfaceView(app, baseConfig: makeSurfaceConfig())
            surfaceTree = SplitTree(view: view)
            focusedSurface = view
        }

        guard let window = self.window else { return }
        visible = true

        // Set the SwiftUI content view if it hasn't been set yet.
        if window.contentView == nil || !(window.contentView is TerminalViewContainer) {
            window.contentView = TerminalViewContainer {
                TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
            }
        }

        positionWindow()
        window.makeKeyAndOrderFront(nil)

        // Activate the app and focus the terminal surface.
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if let focused = focusedSurface {
            window.makeFirstResponder(focused)
        }
    }

    func hide() {
        guard visible else { return }
        visible = false

        window?.orderOut(nil)

        // Restore the previously focused application.
        if let prev = previousApp {
            previousApp = nil
            if !prev.isTerminated {
                _ = prev.activate(options: [])
            }
        }

        // If the profile is non-persistent, tear down the surface to free
        // resources. It will be recreated on next show().
        if !profileConfig.persist {
            surfaceTree = .init()
        }
    }

    // MARK: - Base Controller Overrides

    override func surfaceTreeDidChange(
        from: SplitTree<Ghostty.SurfaceView>,
        to: SplitTree<Ghostty.SurfaceView>
    ) {
        super.surfaceTreeDidChange(from: from, to: to)

        // When the last surface closes (e.g. user typed "exit"), hide.
        if to.isEmpty && visible {
            hide()
        }
    }

    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // For a root leaf whose process has exited, empty the tree (triggers hide).
        if surfaceTree.root == node, case .leaf(let surface) = node, surface.processExited {
            surfaceTree = .init()
            return
        }

        // For a root leaf that's still running, just hide instead of closing.
        if surfaceTree.root == node, case .leaf = node {
            hide()
            return
        }

        // Otherwise, delegate to the base (handles splits).
        super.closeSurface(node, withConfirmation: withConfirmation)
    }

    // MARK: - First Responder

    @IBAction override func closeWindow(_ sender: Any) {
        hide()
    }

    // MARK: - Notifications

    @objc private func onWindowDidResignKey(_ notification: Notification) {
        guard visible else { return }

        // Don't autohide if a sheet (e.g. alert) is attached.
        guard window?.attachedSheet == nil else { return }

        // If focus moved to another window in our own app, clear previousApp
        // so we don't restore the wrong thing.
        if NSApp.isActive {
            previousApp = nil
        }

        if profileConfig.autohide {
            hide()
        }
    }

    // MARK: - Private Helpers

    /// Build the surface configuration used when lazily creating the terminal.
    private func makeSurfaceConfig() -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        config.environmentVariables["GHOSTTY_POPUP"] = profileName
        if profileName == PopupManager.quickProfileName {
            config.environmentVariables["GHOSTTY_QUICK_TERMINAL"] = "1"
        }
        if let cmd = profileConfig.command, !cmd.isEmpty {
            config.command = cmd
        }

        // Set working directory: explicit cwd > focused surface pwd > default
        if let cwd = profileConfig.cwd {
            config.workingDirectory = NSString(string: cwd).expandingTildeInPath
        } else {
            // Try to inherit from the currently focused surface
            if let controller = NSApp.keyWindow?.contentViewController as? BaseTerminalController,
               let surfaceView = controller.focusedSurface,
               let pwd = surfaceView.pwd {
                config.workingDirectory = pwd
            }
        }

        if let opacity = profileConfig.opacity {
            config.backgroundOpacity = max(0.0, min(1.0, opacity))
        }

        return config
    }

    // MARK: - Window Positioning

    private func positionWindow() {
        guard let window = self.window,
              let screen = NSScreen.main else { return }

        let frame = screen.visibleFrame
        let width: CGFloat
        let height: CGFloat

        if profileConfig.widthIsPercent {
            width = CGFloat(profileConfig.widthValue) / 100.0 * frame.width
        } else {
            width = CGFloat(profileConfig.widthValue)
        }

        if profileConfig.heightIsPercent {
            height = CGFloat(profileConfig.heightValue) / 100.0 * frame.height
        } else {
            height = CGFloat(profileConfig.heightValue)
        }

        var rect = NSRect(x: 0, y: 0, width: width, height: height)

        switch profileConfig.position {
        case .top:
            rect.origin.x = frame.origin.x + (frame.width - width) / 2
            rect.origin.y = frame.origin.y + frame.height - height
        case .bottom:
            rect.origin.x = frame.origin.x + (frame.width - width) / 2
            rect.origin.y = frame.origin.y
        case .left:
            rect.origin.x = frame.origin.x
            rect.origin.y = frame.origin.y + (frame.height - height) / 2
        case .right:
            rect.origin.x = frame.origin.x + frame.width - width
            rect.origin.y = frame.origin.y + (frame.height - height) / 2
        case .center:
            rect.origin.x = frame.origin.x + (frame.width - width) / 2
            rect.origin.y = frame.origin.y + (frame.height - height) / 2
        }

        window.setFrame(rect, display: true)
    }
}
