import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct NonNativeFullscreenFocusTests {
    private final class FocusView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class Window: NSWindow {
        var detachedFocusAttempts = 0
        var styleChanged: (() -> Void)?

        override var styleMask: NSWindow.StyleMask {
            didSet { styleChanged?() }
        }

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            if let view = responder as? NSView, view.window !== self {
                detachedFocusAttempts += 1
                return false
            }
            return super.makeFirstResponder(responder)
        }
    }

    @Test func deferredEntryDoesNotRestoreFocusToAMovedView() async throws {
        let window = Window(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = FocusView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        try #require(window.makeFirstResponder(view))
        let fullscreen = try #require(NonNativeFullscreen(window))
        fullscreen.enter()
        try #require(fullscreen.isFullscreen)
        view.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.detachedFocusAttempts == 0)
        fullscreen.exit()
    }

    @Test func exitDoesNotRestoreFocusAfterStyleChangesDetachTheView() async throws {
        let window = Window(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = FocusView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        let fullscreen = try #require(NonNativeFullscreen(window))
        fullscreen.enter()
        try await Task.sleep(for: .milliseconds(100))
        try #require(window.makeFirstResponder(view))
        window.styleChanged = { view.removeFromSuperview() }
        fullscreen.exit()
        #expect(window.detachedFocusAttempts == 0)
    }
}
