import AppKit
@testable import Ghostty
import Testing

/// The hover fetch's own lifecycle, independent of whether a card ever gets
/// drawn on screen.
///
/// Every `hoverProvider` here returns an **empty** `CodeHoverInfo`. That is
/// deliberate, not incidental: `mouseMoved`'s guard —
/// `guard !Task.isCancelled, let info, !info.isEmpty else { return }` — reads
/// it as "nothing to show" and returns before ever calling `showHover`, which
/// is what calls into `CodeHoverPanel.present` and, through it, `orderFront`.
/// Asking the real window server to display a window from this test host —
/// which has no running `NSApplication` event loop to pump its replies —
/// hangs that call forever rather than returning, and hangs the whole suite
/// with it. Returning empty info lets these tests observe everything that
/// happens *before* that line — which is exactly where the regression below
/// lived — without ever reaching it.
///
/// Driving `mouseMoved`/`mouseExited` directly, rather than through a real
/// tracking area, is safe here for the same reason `isJumpClick` was split
/// out to be tested apart from `mouseDown`: the documented hazard is
/// specifically `mouseDown`'s superclass implementation, which runs an
/// event-tracking loop waiting for a mouse-up that never comes outside a
/// live window. `mouseMoved` and `mouseExited` carry no such loop.
@MainActor
struct CodeHoverPersistenceTests {
    /// A real, never-shown window: enough for TextKit to lay out real
    /// glyphs and for `characterIndexForInsertion(at:)` to resolve to a real
    /// offset, without putting anything on the developer's actual display.
    private func makeHoveredTextView(text: String) -> (window: NSWindow, textView: CodeNSTextView) {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        let textView = CodeNSTextView(frame: frame)
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = textView
        return (window, textView)
    }

    /// `location` for a synthesized `.mouseMoved` event is in the window's
    /// own base coordinates — the same space `locationInWindow` reports —
    /// so no real window number is needed for it to resolve correctly.
    private func moveEvent(x: CGFloat, y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: x, y: y),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
    }

    /// Regresses the actual bug: a dismissal scheduled 400ms out was
    /// cancelling the *lookup* task it was scheduled alongside — not just
    /// the window — and that lookup answers at 450ms. Every hover was
    /// killed 50ms before its fetch could complete, which read as "the card
    /// doesn't open" when the real defect was "the fetch is never given the
    /// chance to answer". The fix separates "close the window" from
    /// "abandon the fetch"; this proves the fetch itself now survives.
    @Test func aFetchSurvivesItsOwnScheduledDismissal() async throws {
        let (window, textView) = makeHoveredTextView(text: "let x = 1")
        defer { window.contentView = nil }

        var callCount = 0
        textView.hoverProvider = { _ in
            callCount += 1
            return CodeHoverInfo() // empty — see the file comment
        }

        textView.mouseMoved(with: moveEvent(x: 10, y: 190))

        // Past both the 400ms dismissal schedule and the 450ms fetch, with
        // margin for scheduler jitter — comfortably past either without
        // depending on their exact ordering.
        try await Task.sleep(for: .milliseconds(700))

        #expect(callCount == 1, "the fetch should have run despite the dismissal scheduled alongside it")
    }

    /// The complementary case, so the fix above didn't overcorrect into
    /// "nothing is ever cancelled": a pointer that keeps moving abandons the
    /// stale request for the word it left, not just the one it is on now.
    /// This behaviour predates this session's change and must survive it.
    @Test func aStaleFetchIsAbandonedForANewerHover() async throws {
        let (window, textView) = makeHoveredTextView(text: "let x = 1234567890")
        defer { window.contentView = nil }

        var offsets: [Int] = []
        textView.hoverProvider = { offset in
            offsets.append(offset)
            return CodeHoverInfo()
        }

        textView.mouseMoved(with: moveEvent(x: 10, y: 190))
        // Well inside the 450ms fetch delay, so the first request is still
        // pending when the pointer moves on.
        try await Task.sleep(for: .milliseconds(100))
        textView.mouseMoved(with: moveEvent(x: 300, y: 190))

        try await Task.sleep(for: .milliseconds(700))
        #expect(offsets.count == 1, "only the latest hover's fetch should have run")
    }
}
