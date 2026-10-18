import AppKit
@testable import Ghostty
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

    /// Marked text with the given underline styles; each run is
    /// (UTF-16 location, UTF-16 length, NSUnderlineStyle raw value).
    private func marked(_ text: String, _ runs: [(Int, Int, Int)]) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text)
        for (loc, len, style) in runs {
            s.addAttribute(.underlineStyle, value: style, range: NSRange(location: loc, length: len))
        }
        return s
    }

    @Test(arguments: [
        // No underline, or a thin one only (e.g. kana being typed).
        ("今日は", [], 0..<0),
        ("今日は", [(0, 3, 0x1)], 0..<0),
        // Thick over all of the text (Apple's input method while typing kana).
        ("きょうは", [(0, 4, 0x2)], 0..<0),
        // A clause in the middle, at the start and at the end.
        ("今日はいい天気です", [(0, 3, 0x1), (3, 2, 0x2), (5, 4, 0x1)], 9..<15),
        ("今日はいい天気です", [(0, 3, 0x2), (3, 6, 0x1)], 0..<9),
        ("今日はいい天気です", [(0, 5, 0x1), (5, 4, 0x2)], 15..<27),
        // ASCII and an emoji (two UTF-16 units, four UTF-8 bytes) before it.
        ("a😀いい", [(0, 3, 0x1), (3, 2, 0x2)], 5..<11),
        // Thick with a pattern, double is not thick, the first thick wins.
        ("いい天気", [(0, 2, 0x2 | 0x100), (2, 2, 0x1)], 0..<6),
        ("いい天気", [(0, 2, 0x9), (2, 2, 0x1)], 0..<0),
        ("いい天気", [(0, 1, 0x2), (1, 1, 0x1), (2, 1, 0x2), (3, 1, 0x1)], 0..<3),
    ])
    func findsSelectedClauseUTF8Range(
        text: String,
        runs: [(Int, Int, Int)],
        expected: Range<Int>
    ) {
        #expect(
            Ghostty.SurfaceView.selectedClauseUTF8Range(marked(text, runs)) == expected
        )
    }
}
