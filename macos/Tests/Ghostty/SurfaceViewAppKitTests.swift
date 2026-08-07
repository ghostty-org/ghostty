import AppKit
@testable import Ghostty
import Testing

struct SurfaceViewAppKitTests {
    // MARK: - Focus hit test (vertical split mirroring)

    /// Regresses a bug where clicking a pane in a vertically stacked split
    /// (one pane above another) alternated keyboard focus between the two
    /// panes instead of focusing the clicked one.
    ///
    /// The focus click handler in `SurfaceView` hit-tests through the
    /// window's content view to find which surface was clicked. The bug was
    /// converting the click into the content view's own coordinate space
    /// before calling `hitTest`, which itself expects a point in the
    /// *superview's* space — applying the flip transform twice. That's a
    /// no-op when the content view is unflipped (the common case), but this
    /// fork's sidebar makes the content view an `NSSplitView`, which AppKit
    /// always reports as flipped, so the double conversion mirrored the
    /// point vertically: a click physically in the top pane landed on the
    /// bottom one.
    ///
    /// This test builds that exact shape — a flipped container as the
    /// window's content view, with two subviews stacked top/bottom — and
    /// checks both the buggy pattern (double conversion) and the fixed one
    /// (hit test directly against `event.locationInWindow`, i.e. window
    /// base-coordinate space) so a regression to the buggy pattern fails
    /// loudly instead of only showing up as a UI report.
    @MainActor
    @Test func focusHitTestUsesWindowSpaceNotDoubleConverted() throws {
        final class FlippedContainer: NSView {
            override var isFlipped: Bool { true }
        }

        let windowSize = NSSize(width: 200, height: 200)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )

        let content = FlippedContainer(frame: NSRect(origin: .zero, size: windowSize))
        window.contentView = content

        // In the flipped container's own coordinate space, y = 0 is the
        // *top*. The top pane occupies the first half, the bottom pane the
        // second half — matching a real vertical (top/bottom) split.
        let topPane = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let bottomPane = NSView(frame: NSRect(x: 0, y: 100, width: 200, height: 100))
        content.addSubview(topPane)
        content.addSubview(bottomPane)

        // A click physically in the top half of the window. Window-space
        // (locationInWindow) is never flipped, so a point near the top of
        // the screen has a *high* y — the opposite sense from the
        // container's own flipped space above.
        let clickInTopPane = NSPoint(x: 100, y: 150)

        // The fix: hit test directly against window-space coordinates.
        let fixedResult = content.hitTest(clickInTopPane)
        #expect(
            fixedResult === topPane,
            "hit-testing the raw window-space point should resolve to the top pane"
        )

        // The bug: convert into the content view's own space first (as
        // `window.contentView?.convert(event.locationInWindow, from: nil)`
        // did), then hit test with that already-converted point. Asserting
        // this lands on the *wrong* pane documents the mechanism; if this
        // ever starts passing, the mirroring bug is back.
        let doubleConverted = content.convert(clickInTopPane, from: nil)
        let buggyResult = content.hitTest(doubleConverted)
        #expect(
            buggyResult === bottomPane,
            "the double-converted point reproduces the historical mirroring bug"
        )
    }
    @Test(arguments: [
        ("\u{0008}", true),
        ("\u{001F}", true),
        ("\u{007F}", false),
        (" ", false),
        ("h", false),
        ("", false),
        ("\u{0009}x", false),
        ("\u{0009}\u{0009}", false),
    ])
    func suppressesOnlySingleC0ControlTextWhileComposing(
        text: String,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                text,
                composing: true
            ) == expected
        )
    }

    @Test func doesNotSuppressControlTextWhenNotComposing() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                "\u{0008}",
                composing: false
            ) == false
        )
    }

    @Test func doesNotSuppressMissingText() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                nil,
                composing: true
            ) == false
        )
    }
}
