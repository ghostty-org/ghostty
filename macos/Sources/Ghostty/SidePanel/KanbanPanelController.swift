import Cocoa
import SwiftUI

/// A single sidebar NSView added to the window's theme frame layer.
/// Persists across tab switches because the theme frame (contentView.superview)
/// is stable — only contentView changes when tabs switch.
/// NOT a separate window — no title bar, no move, no resize by drag.
@MainActor
class KanbanSidebarController {
    static let shared = KanbanSidebarController()

    private static var hasAutoShown = false
    private var sidebarView: NSHostingView<SidePanelView>?
    private var width: CGFloat = 300

    private var contentViewObserver: NSKeyValueObservation?

    private init() {
        let saved = UserDefaults.standard.double(forKey: "kanban_panel_width")
        if saved > 0 { width = saved }
    }

    /// Returns the theme frame (contentView.superview) which is the only
    /// view that persists across tab switches in native tabbed windows.
    private func themeFrame(for window: NSWindow) -> NSView? {
        window.contentView?.superview
    }

    /// Install the sidebar into the window's theme frame.
    private func install(into window: NSWindow) {
        guard let tf = themeFrame(for: window) else { return }
        ensureSidebarView()
        guard let sidebarView else { return }

        if sidebarView.superview !== tf {
            tf.addSubview(sidebarView)
        }

        // Observe subview changes (contentView swaps on tab switch)
        contentViewObserver = tf.observe(\.subviews, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, let w = tf.window else { return }
                self.position(in: w)
            }
        }

        position(in: window)
    }

    private func ensureSidebarView() {
        guard sidebarView == nil else { return }
        let view = NSHostingView(
            rootView: SidePanelView(viewModel: TerminalController.sharedSidebarViewModel)
        )
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        sidebarView = view
    }

    private func position(in window: NSWindow) {
        guard let cv = window.contentView,
              let tf = themeFrame(for: window),
              let sidebarView else { return }

        // contentView's frame in theme frame coordinates = the content
        // area below the title bar / toolbar.
        let contentFrame = cv.convert(cv.bounds, to: tf)
        sidebarView.frame = NSRect(
            x: contentFrame.minX,
            y: contentFrame.minY,
            width: width,
            height: contentFrame.height
        )
        sidebarView.isHidden = false
    }

    func show() {
        // Rebuild to pick up the latest viewModel
        let view = NSHostingView(
            rootView: SidePanelView(viewModel: TerminalController.sharedSidebarViewModel)
        )
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        sidebarView = view

        // Attach to the frontmost terminal window
        if let w = NSApp.keyWindow ?? NSApp.mainWindow {
            install(into: w)
        }

        // Track key-window changes to follow tab switches
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyWindowChanged),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResized),
            name: NSWindow.didResizeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResized),
            name: NSWindow.didMoveNotification,
            object: nil
        )
    }

    @objc private func keyWindowChanged(_ n: Notification) {
        guard let w = n.object as? NSWindow,
              w.windowController is TerminalController else {
            sidebarView?.removeFromSuperview()
            return
        }
        install(into: w)
    }

    @objc private func windowResized(_ n: Notification) {
        guard let w = n.object as? NSWindow,
              w.windowController is TerminalController else { return }
        position(in: w)
    }

    func hide() {
        sidebarView?.removeFromSuperview()
        sidebarView = nil
        contentViewObserver = nil
    }

    func toggle() {
        if sidebarView?.superview != nil {
            hide()
        } else {
            show()
        }
    }

    static func showOnceIfNeeded() {
        guard !hasAutoShown else { return }
        hasAutoShown = true
        shared.show()
    }
}
