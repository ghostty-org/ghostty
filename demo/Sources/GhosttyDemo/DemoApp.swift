import AppKit
import SwiftUI
import GhosttyKit
import GhosttyRuntime

// Create the Ghostty app instance (shared across the demo)
var ghosttyApp: GhosttyApp!

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ghostty_init must be called before creating Ghostty.App
        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if initResult != GHOSTTY_SUCCESS {
            fputs("ghostty_init failed\n", stderr)
            exit(1)
        }
        ghostty_cli_try_action()

        ghosttyApp = GhosttyApp()

        let contentView = ContentView()
            .environmentObject(ghosttyApp)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1350, height: 900)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1350, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ghostty Demo"
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
