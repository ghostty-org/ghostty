import AppKit
import Testing
@testable import Ghostty

@MainActor struct NSWindowTitlebarTests {
    /// A window with its content at (100, 100) to (500, 400) in screen
    /// coordinates and, when titled, its titlebar above that.
    private func window(_ styleMask: NSWindow.StyleMask) -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: styleMask,
            backing: .buffered,
            defer: true)
    }

    @Test func fullSizeContentView() {
        let window = window([.titled, .fullSizeContentView])
        let titlebar = window.titlebarFrame
        #expect(titlebar.maxY == window.frame.maxY)
        #expect(titlebar.height > 0)
        #expect(!titlebar.contains(NSPoint(x: 300, y: 250)))
    }

    @Test func borderless() {
        let window = window([.borderless])
        #expect(window.titlebarFrame.isEmpty)
        #expect(!window.titlebarFrame.contains(NSPoint(x: 300, y: 399)))
    }
}
