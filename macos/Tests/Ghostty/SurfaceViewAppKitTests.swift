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
}

/// Tests for `preeditCommit`, which decides what keyDown sends after an
/// input method committed preedit text. Unless noted as hypothetical, the
/// callback sequences below were recorded with a minimal NSTextInputClient
/// from the built-in 2-Set Korean input method on macOS 26, or taken from
/// the Gureum trace in #14773.
@MainActor
struct SurfaceViewPreeditCommitTests {
    typealias Commit = Ghostty.SurfaceView.PreeditCommit

    struct Case: CustomTestStringConvertible {
        let name: String
        var before: String = ""
        var after: String = ""
        var committed: [String] = []
        var commands: [String] = []
        var keyboardChanged = false
        var expected: Commit?

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        // Keys that end a Korean composition: the input method commits the
        // syllable with insertText and hands the key back as a command.
        Case(name: "Enter after 가",
             before: "가", committed: ["가"], commands: ["insertNewline:"],
             expected: Commit(texts: ["가"], replaysKey: true)),
        Case(name: "Tab after 가",
             before: "가", committed: ["가"], commands: ["insertTab:"],
             expected: Commit(texts: ["가"], replaysKey: true)),
        Case(name: "Escape after 가",
             before: "가", committed: ["가"], commands: ["cancelOperation:"],
             expected: Commit(texts: ["가"], replaysKey: true)),
        Case(name: "Ctrl+Y after 가 (unbound key arrives as noop:)",
             before: "가", committed: ["가"], commands: ["noop:"],
             expected: Commit(texts: ["가"], replaysKey: true)),
        Case(name: "Ctrl+C after 가",
             before: "가", committed: ["가"], commands: ["noop:"],
             expected: Commit(texts: ["가"], replaysKey: true)),
        Case(name: "Ctrl+Y after 가 with Gureum (yank:)",
             before: "가", committed: ["가"], commands: ["yank:"],
             expected: Commit(texts: ["가"], replaysKey: true)),
        Case(name: "Right arrow after 가",
             before: "가", committed: ["가"], commands: ["moveRight:"],
             expected: Commit(texts: ["가"], replaysKey: true)),
        Case(name: "Left arrow after 가",
             before: "가", committed: ["가"], commands: ["moveLeft:"],
             expected: Commit(texts: ["가"], replaysKey: true)),
        Case(name: "Option+Left after 가",
             before: "가", committed: ["가"], commands: ["moveWordLeft:"],
             expected: Commit(texts: ["가"], replaysKey: true)),
        Case(name: "Cmd+Left after 가",
             before: "가", committed: ["가"], commands: ["moveToLeftEndOfLine:"],
             expected: Commit(texts: ["가"], replaysKey: true)),

        // Keys the input method consumed: committed text only.
        Case(name: "Space after 가 is committed as part of the text",
             before: "가", committed: ["가 "],
             expected: Commit(texts: ["가 "], replaysKey: false)),
        Case(name: "Japanese Enter confirms the conversion (hypothetical)",
             before: "かん", committed: ["感"],
             expected: Commit(texts: ["感"], replaysKey: false)),
        Case(name: "two commits in one key (hypothetical)",
             before: "か", committed: ["か", "。"],
             expected: Commit(texts: ["か", "。"], replaysKey: false)),
        Case(name: "input source switched to ABC mid-composition, then a",
             before: "가", committed: ["a"],
             expected: Commit(texts: ["a"], replaysKey: false)),

        // A new syllable starts: the previous one is committed while the
        // composition continues with the new one.
        Case(name: "하+ㄴ+ㅏ commits 하 and keeps composing 나",
             before: "한", after: "나", committed: ["하"],
             expected: Commit(texts: ["하"], replaysKey: false)),

        // Backspace on the last remaining jamo: the input method commits the
        // jamo and hands Backspace back to delete it again. Nothing to send.
        Case(name: "Backspace on lone ㅇ",
             before: "ㅇ", committed: ["ㅇ"], commands: ["deleteBackward:"],
             expected: Commit(texts: [], replaysKey: false)),
        Case(name: "Backspace committing something else (hypothetical)",
             before: "ㅌ", committed: ["x"], commands: ["deleteBackward:"],
             expected: Commit(texts: ["x"], replaysKey: true)),

        // A key that switched the input source is not sent even if the input
        // method committed the preedit on its way out (hypothetical).
        Case(name: "input source switch key commits 가",
             before: "가", committed: ["가"], commands: ["noop:"], keyboardChanged: true,
             expected: Commit(texts: ["가"], replaysKey: false)),

        // A command while the composition continues is not a handed-back
        // key (hypothetical).
        Case(name: "command while still composing",
             before: "가", after: "가", committed: ["가"], commands: ["noop:"],
             expected: Commit(texts: ["가"], replaysKey: false)),

        // Not a commit at all: normal key handling applies.
        Case(name: "plain typing without an input method",
             committed: ["a"]),
        Case(name: "Enter without marked text",
             commands: ["insertNewline:"]),
        Case(name: "Backspace decomposing 안 into 아",
             before: "안", after: "아"),
        Case(name: "composition continues",
             before: "ㄱ", after: "가"),
    ]

    @Test(arguments: cases)
    func preeditCommit(_ c: Case) {
        let result = Ghostty.SurfaceView.preeditCommit(
            markedTextBefore: c.before,
            markedTextAfter: c.after,
            committedText: c.committed,
            commands: c.commands.map { Selector($0) },
            keyboardChanged: c.keyboardChanged
        )
        #expect(result == c.expected)
    }
}
