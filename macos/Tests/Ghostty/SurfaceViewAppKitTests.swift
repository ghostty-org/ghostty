@testable import Ghostty
import Testing

struct SurfaceViewAppKitTests {
    @Test(arguments: [
        ("", "x", 0, "x"),
        ("a", "â", 1, "â"),
        ("tie", "tiê", 1, "ê"),
        ("tiê", "tiế", 1, "ế"),
        ("tiếng", "tiế", 2, ""),
        ("xin", "", 3, ""),
        ("ế", "e\u{0302}\u{0301}", 0, ""),
    ])
    func calculatesStreamedPreeditDelta(
        oldValue: String,
        newValue: String,
        deleteCount: Int,
        insertText: String
    ) {
        #expect(
            Ghostty.SurfaceView.preeditDelta(
                from: oldValue,
                to: newValue
            ) == .init(
                deleteCount: deleteCount,
                insertText: insertText
            )
        )
    }

    @Test(arguments: [
        (
            "com.apple.inputmethod.VietnameseSimpleTelex",
            [String](),
            KeyboardLayout.PreeditStrategy.streamToTerminal
        ),
        (
            "third.party.input",
            ["vi"],
            KeyboardLayout.PreeditStrategy.streamToTerminal
        ),
        (
            "third.party.input",
            ["vi-VN"],
            KeyboardLayout.PreeditStrategy.streamToTerminal
        ),
        (
            "com.apple.keylayout.US",
            ["en"],
            KeyboardLayout.PreeditStrategy.native
        ),
        (
            nil,
            [String](),
            KeyboardLayout.PreeditStrategy.native
        ),
    ])
    func selectsPreeditStrategy(
        id: String?,
        languages: [String],
        expected: KeyboardLayout.PreeditStrategy
    ) {
        #expect(
            KeyboardLayout.preeditStrategy(
                id: id,
                languages: languages
            ) == expected
        )
    }

    @Test(arguments: [
        (Ghostty.Input.Key.space, " ", "tiếng", true),
        (Ghostty.Input.Key.enter, "\r", "tiếng", true),
        (Ghostty.Input.Key.arrowLeft, nil, "tiếng", true),
        (Ghostty.Input.Key.slash, "/", "tiếng", true),
        (Ghostty.Input.Key.s, "s", "tiếng", false),
        (Ghostty.Input.Key.space, " ", "tiếng ", false),
    ])
    func replaysOnlyStreamedPreeditCommitDelimiter(
        key: Ghostty.Input.Key,
        text: String?,
        committedText: String,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.shouldReplayStreamedPreeditCommitKey(
                key,
                text: text,
                committedText: committedText
            ) == expected
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
