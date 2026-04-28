import Cocoa
import SwiftUI

/// Positions the sidebar as a titlebar accessory so it sits BESIDE the
/// native tab bar (not below it). The view spans the full window height.
@MainActor
class KanbanSidebarController {
    static let shared = KanbanSidebarController()
    private static var hasAutoShown = false

    private var accessory: NSTitlebarAccessoryViewController?
    private var hostingView: NSHostingView<SidePanelView>?
    /// Persisted sidebar width (default 85px from the user's layout spec).
    private var sidebarWidth: CGFloat = 85
    private weak var activeWindow: NSWindow?

    private init() {
        let saved = UserDefaults.standard.double(forKey: "kanban_sidebar_width")
        if saved >= 60 { sidebarWidth = saved }
    }

    func show() {
        let view = SidePanelView(viewModel: TerminalController.sharedSidebarViewModel)
        hostingView = NSHostingView(rootView: view)
        hostingView?.wantsLayer = true

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        install(in: window)
    }

    private func install(in window: NSWindow) {
        guard let hostingView else { return }

        // Remove existing accessory first
        if let acc = accessory {
            window.removeTitlebarAccessoryViewController(at: window.titlebarAccessoryViewControllers.firstIndex(of: acc) ?? 0)
        }

        let acc = NSTitlebarAccessoryViewController()
        acc.view = hostingView
        acc.layoutAttribute = .leading

        window.addTitlebarAccessoryViewController(acc)
        accessory = acc
        activeWindow = window

        // Set the view to cover the content area height
        let containerHeight = window.contentLayoutRect.height
        hostingView.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: containerHeight)
        // Mark as full-height so it extends below the titlebar
        hostingView.autoresizingMask = NSAutoresizingMaskOptions(arrayLiteral: .height)

        // Observe resize to keep height in sync
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResized),
            name: NSWindow.didResizeNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResized),
            name: NSWindow.didMoveNotification, object: window
        )
        // Follow tab switches
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyWindowChanged),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )

        window.titlebarAppearsTransparent = true
    }

    @objc private func windowResized(_ n: Notification) {
        guard let w = n.object as? NSWindow,
              w == activeWindow || w.windowController is TerminalController else { return }
        let newHeight = w.contentLayoutRect.height
        hostingView?.frame.size.height = newHeight
    }

    @objc private func keyWindowChanged(_ n: Notification) {
        guard let w = n.object as? NSWindow,
              w.windowController is TerminalController else { return }
        if accessory == nil || hostingView?.superview == nil {
            install(in: w)
        } else {
            let newHeight = w.contentLayoutRect.height
            hostingView?.frame.size.height = newHeight
        }
    }

    func hide() {
        if let acc = accessory, let window = activeWindow {
            if let idx = window.titlebarAccessoryViewControllers.firstIndex(of: acc) {
                window.removeTitlebarAccessoryViewController(at: idx)
            }
        }
        accessory = nil
        hostingView = nil
        activeWindow = nil
    }

    func toggle() {
        if accessory != nil && hostingView?.superview != nil {
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
