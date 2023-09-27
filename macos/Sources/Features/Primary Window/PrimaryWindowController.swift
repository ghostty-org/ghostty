import Cocoa

class PrimaryWindowController: NSWindowController, NSWindowDelegate {
    // This is used to programmatically control tabs.
    weak var windowManager: PrimaryWindowManager?
    
    // This is required for the "+" button to show up in the tab bar to add a
    // new tab.
    override func newWindowForTab(_ sender: Any?) {
        guard let window = self.window as? PrimaryWindow else { preconditionFailure("Expected window to be loaded") }
        guard let manager = self.windowManager else { return }
        manager.triggerNewTab(for: window)
    }
    
    deinit {
        // I don't know if this is the right place, but because of WindowAccessor in our
        // SwiftUI hierarchy, we have a reference cycle between view and window and windows
        // are never freed. When the window is closed, the window controller is deinitialized,
        // so we can use this opportunity detach the view from the window and break the cycle.
        if let window = self.window {
            window.contentView = nil
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        self.windowManager?.indexTabs()
    }

    func windowWillClose(_ notification: Notification) {
        self.windowManager?.indexTabs()
    }
}
