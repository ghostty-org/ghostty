import AppKit
@testable import Ghostty
import Testing

/// Covers what insertText tells the input method when committed text ends a
/// composition.
@MainActor struct SurfaceViewInsertTextTests {
    /// Records the calls insertText makes on the input context.
    final class RecordingInputContext: NSTextInputContext {
        var discardCount = 0

        override func discardMarkedText() {
            discardCount += 1
        }
    }

    /// The minimal client an NSTextInputContext needs.
    final class StubClient: NSView, NSTextInputClient {
        func insertText(_ string: Any, replacementRange: NSRange) {}
        func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
        func unmarkText() {}
        func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
        func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
        func hasMarkedText() -> Bool { false }
        func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
        func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
        func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
        func characterIndex(for point: NSPoint) -> Int { 0 }
    }

    let inputContext = RecordingInputContext(client: StubClient())

    @Test func committingMarkedTextDiscardsTheComposition() {
        // Cangjie: "cc" composes "金金", then switch apps and back. The next
        // "c" commits "金" over the marked text. Unless the input method is
        // told to drop its composition, as NSTextView does, it keeps "金金"
        // in its buffer: each further key is committed right away and
        // switching input source flushes the buffer again (#15104).
        let markedText = NSMutableAttributedString(string: "金金")
        let hadMarkedText = Ghostty.SurfaceView.endCompositionForInsertedText(
            markedText: markedText,
            inputContext: inputContext
        )

        #expect(hadMarkedText)
        #expect(markedText.length == 0)
        withKnownIssue("The input method is not told to drop its composition") {
            #expect(inputContext.discardCount == 1)
        }
    }

    @Test func insertingWithoutMarkedTextLeavesTheInputMethodAlone() {
        // Plain typing, emoji picker or dictation: there is no composition
        // to end.
        let markedText = NSMutableAttributedString()
        let hadMarkedText = Ghostty.SurfaceView.endCompositionForInsertedText(
            markedText: markedText,
            inputContext: inputContext
        )

        #expect(!hadMarkedText)
        #expect(inputContext.discardCount == 0)
    }
}
