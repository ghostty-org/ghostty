import AppKit
import SwiftUI

/// The settings window: a single shared instance reused across opens,
/// shown in place of opening the raw config file in an editor.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var ghostty: Ghostty.App?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("GhosttySettings")
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(ghostty: Ghostty.App) {
        if self.ghostty !== ghostty || window?.contentView == nil {
            self.ghostty = ghostty
            window?.contentView = NSHostingView(rootView: SettingsRootView(ghostty: ghostty))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
