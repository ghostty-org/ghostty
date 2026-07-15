import AppKit
import Testing
@testable import Ghostty

@Suite
struct TerminalControllerTests {
    @MainActor
    @Test func showWindowSyncsAppearanceAfterWindowIsVisible() throws {
        let appDelegate = try #require(NSApp.delegate as? AppDelegate)
        let controller = AppearanceSyncTerminalController(appDelegate.ghostty)
        let window = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        controller.window = window
        defer { window.close() }

        #expect(!window.isVisible)
        controller.appearanceSyncVisibility.removeAll()

        controller.showWindow(nil)

        #expect(controller.appearanceSyncVisibility == [true])
    }
}

@MainActor
private final class AppearanceSyncTerminalController: TerminalController {
    var appearanceSyncVisibility: [Bool] = []

    override func syncAppearance() {
        appearanceSyncVisibility.append(window?.isVisible ?? false)
    }
}
