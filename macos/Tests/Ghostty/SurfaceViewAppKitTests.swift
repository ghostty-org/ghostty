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

    @Test(arguments: [
        ("com.apple.inputmethod.Korean.2SetKorean", true),
        ("com.apple.inputmethod.Korean.3SetKorean", true),
        ("com.apple.inputmethod.Japanese", false),
        ("com.apple.inputmethod.TCIM.Cangjie", false),
        ("com.apple.inputmethod.SCIM.ITABC", false),
        ("com.apple.keylayout.ABC", false),
    ])
    func commitsPreeditOnFocusLossOnlyForKoreanInputSources(
        inputSource: String,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.inputSourceDropsPreeditOnFocusLoss(inputSource) == expected
        )
    }

    @Test func doesNotCommitPreeditOnFocusLossForUnknownInputSource() {
        #expect(Ghostty.SurfaceView.inputSourceDropsPreeditOnFocusLoss(nil) == false)
    }
}
