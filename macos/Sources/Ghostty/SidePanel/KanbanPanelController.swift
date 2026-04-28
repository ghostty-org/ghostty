import Cocoa
import SwiftUI

/// Pushes the native tab bar to the right using a transparent spacer as
/// a titlebar accessory. This frees the left side of the titlebar so the
/// inline sidebar (which uses `.ignoresSafeArea(.all)`) is visible there.
@MainActor
class KanbanSidebarController {
    static let shared = KanbanSidebarController()
    private static var hasInstalled = false

    /// Install a transparent spacer into the titlebar to push tabs right.
    /// Only needs to be called once per window, but we re-apply on tab
    /// switches because each window has separate titlebar accessories.
    static func installSpacer(in window: NSWindow, width: CGFloat) {
        // Remove our old spacer if present
        if let first = window.titlebarAccessoryViewControllers.first,
           first.view is KanbanTitlebarSpacer {
            window.removeTitlebarAccessoryViewController(at: 0)
        }

        let spacer = KanbanTitlebarSpacer(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        spacer.wantsLayer = true
        spacer.layer?.backgroundColor = .clear
        let acc = NSTitlebarAccessoryViewController()
        acc.view = spacer
        acc.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(acc)
    }
}

/// An empty transparent view used as a spacing element in the titlebar.
private class KanbanTitlebarSpacer: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
