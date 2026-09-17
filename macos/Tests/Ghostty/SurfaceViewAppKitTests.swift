@testable import Ghostty
import AppKit
import Testing

struct SurfaceViewAppKitTests {
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

    @Test func matchesOnlyTheCommandForTheKeyItself() {
        let cases: [(Selector, Ghostty.Input.Key, Bool)] = [
            (#selector(NSStandardKeyBindingResponding.insertNewline(_:)), .enter, true),
            (#selector(NSStandardKeyBindingResponding.insertNewline(_:)), .numpadEnter, true),
            (#selector(NSStandardKeyBindingResponding.insertLineBreak(_:)), .enter, true),
            (#selector(NSStandardKeyBindingResponding.insertNewlineIgnoringFieldEditor(_:)), .enter, true),
            (#selector(NSStandardKeyBindingResponding.insertTab(_:)), .tab, true),
            (#selector(NSStandardKeyBindingResponding.insertBacktab(_:)), .tab, true),
            (#selector(NSStandardKeyBindingResponding.cancelOperation(_:)), .escape, true),
            (NSSelectorFromString("cancel:"), .escape, true),

            // A command for some other key must not replay this one.
            (#selector(NSStandardKeyBindingResponding.insertNewline(_:)), .tab, false),
            (#selector(NSStandardKeyBindingResponding.insertTab(_:)), .enter, false),
            (#selector(NSStandardKeyBindingResponding.cancelOperation(_:)), .enter, false),

            // Keys we never replay from a command, so preedit-committing
            // shortcuts like ctrl+j aren't encoded a second time.
            (#selector(NSStandardKeyBindingResponding.insertLineBreak(_:)), .j, false),
            (#selector(NSStandardKeyBindingResponding.moveLeft(_:)), .arrowLeft, false),
            (#selector(NSStandardKeyBindingResponding.deleteBackward(_:)), .backspace, false),
        ]

        for (selector, key, expected) in cases {
            #expect(
                Ghostty.SurfaceView.isCommandSelector(selector, for: key) == expected,
                "\(selector) for \(key)"
            )
        }
    }

    @Test func noCommandSelectorMatchesNothing() {
        #expect(Ghostty.SurfaceView.isCommandSelector(nil, for: .enter) == false)
    }
}
