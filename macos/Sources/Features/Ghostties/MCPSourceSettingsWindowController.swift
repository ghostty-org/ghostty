import AppKit
import SwiftUI

/// Hosts `MCPSourceSettingsView` in a standalone AppKit window so it can be
/// shown from the menu bar without replacing the existing config-file-based
/// Preferences action. Single shared instance — re-opening brings the window
/// forward rather than spawning a second one.
final class MCPSourceSettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MCPSourceSettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MCP Sources"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MCPSourceSettingsView())
        window.center()
        window.setFrameAutosaveName("MCPSourceSettingsWindow")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
