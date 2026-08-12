import AppKit
@testable import Ghostty
import Testing

/// Which TextKit the editor is running on.
///
/// The gutter draws by walking `textLayoutManager`'s fragments, so it needs
/// TextKit 2 — and the downgrade to TextKit 1 is *silent*: text keeps
/// rendering, only the things that ask for the new layout manager go blank.
/// That is exactly the shape of "the line numbers disappeared while the code
/// still showed".
@MainActor
struct TextKitDowngradeTests {
    @Test func aFreshViewIsOnTextKit2() {
        #expect(CodeNSTextView().isUsingTextKit2)
    }

    /// The suspect: `isHorizontallyResizable` is TextKit 1-era API, and it was
    /// added to make long lines scroll sideways.
    @Test func horizontalResizabilityDoesNotDowngrade() {
        let textView = CodeNSTextView()
        textView.isHorizontallyResizable = true
        #expect(
            textView.isUsingTextKit2,
            "setting isHorizontallyResizable dropped the view to TextKit 1"
        )
    }

    /// The configuration that actually ships: no wrapping, which is what turns
    /// horizontal scrolling on.
    @Test func theUnwrappedConfigurationStaysOnTextKit2() {
        let textView = CodeNSTextView()
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        #expect(textView.isUsingTextKit2)
    }
}
