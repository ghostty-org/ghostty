import AppKit
@testable import Ghostty
import Testing

/// The hover card's own behaviour: whether a point counts as "on the card",
/// and what the card does with the text it is given.
///
/// Neither of these ever orders a window onto the screen. `NSWindow.isVisible`
/// only becomes true by actually asking the window server to display
/// something, and doing that from this test host — which has no running
/// `NSApplication` event loop pumping window-server replies — hangs the
/// call forever instead of returning. `CodeHoverPanel.contains(point:in:
/// isVisible:)` and `.label(_:width:)` exist specifically so this file never
/// has to find that out again.
@MainActor
struct CodeHoverPanelTests {
    // MARK: - contains(point:in:isVisible:)

    /// The geometry `mouseExited` relies on to tell "reaching for the card"
    /// apart from "leaving for good".
    @Test func aPointInsideAVisibleFrameIsContained() {
        let frame = NSRect(x: 100, y: 100, width: 200, height: 100)
        #expect(CodeHoverPanel.contains(point: NSPoint(x: 150, y: 150), in: frame, isVisible: true))
    }

    @Test func aPointOutsideTheFrameIsNotContained() {
        let frame = NSRect(x: 100, y: 100, width: 200, height: 100)
        #expect(!CodeHoverPanel.contains(point: NSPoint(x: 10, y: 10), in: frame, isVisible: true))
    }

    /// Regresses dropping the `isVisible` half of the check: a dismissed
    /// panel still has a frame sitting wherever it was last shown, and a
    /// coincidental cursor position there must not be read as "contained".
    @Test func aPointInsideAnInvisibleFrameIsNotContained() {
        let frame = NSRect(x: 100, y: 100, width: 200, height: 100)
        #expect(!CodeHoverPanel.contains(point: NSPoint(x: 150, y: 150), in: frame, isVisible: false))
    }

    @Test func aPointExactlyOnTheEdgeIsContained() {
        let frame = NSRect(x: 100, y: 100, width: 200, height: 100)
        #expect(CodeHoverPanel.contains(point: NSPoint(x: 100, y: 100), in: frame, isVisible: true))
    }

    // MARK: - Presented labels

    /// Regresses two things reported from the same screenshot: a copy
    /// button that had no reason to exist once the text itself could be
    /// selected, and — the actual bug — selecting that text discarding its
    /// syntax colours and shrinking to a different font. A selectable
    /// `NSTextField` still routes clicks through the shared field editor,
    /// and that editor draws from `stringValue` plus the control's own
    /// font/colour unless told otherwise — which is exactly the flat,
    /// recoloured, differently-sized text that appeared the moment a
    /// selection started.
    @Test func aLabelStaysSelectableAndKeepsItsAttributesOnClick() {
        let colored = NSMutableAttributedString(string: "let x", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.systemPurple,
        ])

        let field = CodeHoverPanel.label(colored, width: 200)

        #expect(field.isSelectable, "the card's text must stay selectable so it can be copied by hand")
        #expect(
            field.allowsEditingTextAttributes,
            "without this, clicking into the text for selection drops its syntax colours and font"
        )
        #expect(field.isEditable == false, "selectable is not the same as editable — this is still a label")
    }
}
