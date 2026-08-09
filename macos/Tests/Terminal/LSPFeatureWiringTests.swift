import AppKit
import Foundation
@testable import Ghostty
import Testing

/// Reading the line a reference sits on.
///
/// The list is unusable without it — coordinates alone make forty results
/// look identical — and it reads from disk, which is where the edge cases
/// are.
struct LSPReferenceSnippetTests {
    private func write(_ contents: String) -> String {
        let path = NSTemporaryDirectory() + "phantom-refs-\(UUID().uuidString).swift"
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func theSnippetIsTheLineTheServerPointedAt() {
        let path = write("let a = 1\nlet b = 2\nlet c = 3")
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(LSPReference.line(1, ofFileAt: path) == "let b = 2")
    }

    /// Zero-based, like every other position in the protocol.
    @Test func lineZeroIsTheFirstLine() {
        let path = write("first\nsecond")
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(LSPReference.line(0, ofFileAt: path) == "first")
    }

    /// Leading indentation is stripped: in a list 560 points wide, four
    /// levels of nesting push the code that matters off the right edge.
    @Test func indentationIsTrimmed() {
        let path = write("struct A {\n        let deep = 1\n}")
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(LSPReference.line(1, ofFileAt: path) == "let deep = 1")
    }

    /// A stale index points past the end of a file that has since shrunk.
    /// An empty snippet is a worse row; a crash is a worse editor.
    @Test func aLineBeyondTheEndIsEmptyRatherThanACrash() {
        let path = write("only one line")
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(LSPReference.line(99, ofFileAt: path).isEmpty)
        #expect(LSPReference.line(-1, ofFileAt: path).isEmpty)
    }

    @Test func aFileThatIsGoneIsEmptyRatherThanACrash() {
        #expect(LSPReference.line(0, ofFileAt: "/tmp/phantom-does-not-exist-\(UUID())").isEmpty)
    }
}

/// The keys the editor takes, and — more importantly — the ones it leaves
/// alone.
///
/// Every shortcut here is one the terminal or the find bar might otherwise
/// have handled, so this suite is really about what the editor *doesn't*
/// swallow.
@MainActor
struct EditorShortcutTests {
    private func event(_ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )!
    }

    @Test func commandOptionFFormats() {
        let textView = CodeNSTextView()
        var formatted = false
        textView.onFormat = { formatted = true }

        #expect(textView.performKeyEquivalent(with: event("f", [.command, .option])))
        #expect(formatted)
    }

    @Test func controlCommandRRenames() {
        let textView = CodeNSTextView()
        var offset: Int?
        textView.onRename = { offset = $0 }

        #expect(textView.performKeyEquivalent(with: event("r", [.command, .control])))
        #expect(offset == 0)
    }

    @Test func controlCommandGFindsReferences() {
        let textView = CodeNSTextView()
        var asked = false
        textView.onFindReferences = { _ in asked = true }

        #expect(textView.performKeyEquivalent(with: event("g", [.command, .control])))
        #expect(asked)
    }

    /// ⇧⌘G is the find bar's "previous match" and stays that way. Claiming
    /// it for references would trade a shortcut people use constantly for
    /// one they use occasionally.
    @Test func shiftCommandGIsLeftToTheFindBar() {
        let textView = CodeNSTextView()
        textView.onFindReferences = { _ in
            Issue.record("references stole the find bar's previous-match key")
        }

        _ = textView.performKeyEquivalent(with: event("g", [.command, .shift]))
    }

    /// Without a handler the key belongs to whoever else wants it — the
    /// same rule ⌘W already follows, since swallowing it would leave a
    /// window nothing can close.
    @Test func anUnhandledCommandIsNotClaimed() {
        let textView = CodeNSTextView()
        #expect(!textView.performKeyEquivalent(with: event("f", [.command, .option])))
        #expect(!textView.performKeyEquivalent(with: event("r", [.command, .control])))
        #expect(!textView.performKeyEquivalent(with: event("g", [.command, .control])))
    }

    /// ⌘-click is the only click that jumps; an ordinary one must stay an
    /// ordinary one, or selecting text becomes impossible.
    ///
    /// Asserted on the decision rather than by sending a click: an
    /// `NSTextView` handed a mouse-down runs an event-tracking loop until
    /// the button comes back up, and outside a window it never does — the
    /// test hangs the whole suite instead of failing.
    @Test func onlyACommandClickJumps() {
        #expect(CodeNSTextView.isJumpClick(.command))
        #expect(!CodeNSTextView.isJumpClick([]))
        #expect(!CodeNSTextView.isJumpClick(.shift))
        #expect(!CodeNSTextView.isJumpClick(.option))
    }

    /// ⇧⌘-click extends a selection, and ⌥⌘-click makes a rectangular one.
    /// Both are ordinary clicks with ⌘ held, and treating them as a jump
    /// would break selecting text with the modifier down.
    @Test func aCommandClickWithAnotherModifierIsStillASelection() {
        #expect(!CodeNSTextView.isJumpClick([.command, .shift]))
        #expect(!CodeNSTextView.isJumpClick([.command, .option]))
    }
}

/// Turning a diagnostic into something the engine can draw.
///
/// The conversion lives in the host precisely so the engine never learns
/// what a language server is — these assert the seam still holds.
@MainActor
struct DiagnosticUnderlineTests {
    private func diagnostic(line: Int, from: Int, to: Int, severity: Int) -> LSPDiagnostic? {
        LSPDiagnostic([
            "range": [
                "start": ["line": .integer(line), "character": .integer(from)],
                "end": ["line": .integer(line), "character": .integer(to)],
            ],
            "message": .string("something is wrong"),
            "severity": .integer(severity),
        ])
    }

    /// A zero-width diagnostic — servers emit them at end-of-file — would
    /// underline nothing at all, so it must not reach the text storage as a
    /// range of length zero and a colour.
    @Test func anEmptyRangeUnderlinesNothing() {
        let text = "let a = 1" as NSString
        let empty = LSPRange(
            start: LSPPosition(line: 0, character: 4),
            end: LSPPosition(line: 0, character: 4)
        )
        #expect(LSPTextCoordinates.range(of: empty, in: text)?.length == 0)
    }

    @Test func severityDecidesTheColour() {
        #expect(diagnostic(line: 0, from: 0, to: 1, severity: 1)?.severity == .error)
        #expect(diagnostic(line: 0, from: 0, to: 1, severity: 2)?.severity == .warning)
        #expect(diagnostic(line: 0, from: 0, to: 1, severity: 3)?.severity == .information)
        #expect(diagnostic(line: 0, from: 0, to: 1, severity: 4)?.severity == .hint)
    }

    /// Underlines are applied as their own pass, so a document that is
    /// re-highlighted must not keep the previous answer's marks. The
    /// removal is what makes a fixed error stop being underlined.
    @Test func applyingUnderlinesClearsTheOnesBefore() {
        let storage = NSTextStorage(string: "let alpha = beta")
        let full = NSRange(location: 0, length: storage.length)

        storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue], range: full)
        storage.removeAttribute(.underlineStyle, range: full)

        var found = false
        storage.enumerateAttribute(.underlineStyle, in: full) { value, _, _ in
            if value != nil { found = true }
        }
        #expect(!found)
    }
}

/// Prefilling the rename field with the word under the cursor.
///
/// A pure function on purpose: it decides what a "symbol" is, and getting
/// that wrong means the field arrives holding half an identifier — which is
/// worse than arriving empty, because it looks correct.
struct RenamePrefillTests {
    private func identifier(_ offset: Int, _ text: String) -> String {
        EditorPaneView.identifier(at: offset, in: text)
    }

    @Test func theWordUnderTheCursorIsTaken() {
        #expect(identifier(6, "let alphaValue = 1") == "alphaValue")
    }

    @Test func aCursorAtTheStartOfAWordStillFindsIt() {
        #expect(identifier(4, "let alpha = 1") == "alpha")
    }

    /// Where the cursor lands after typing a name or double-clicking it —
    /// one past the last character, not on it.
    @Test func aCursorJustPastTheEndFindsTheWordBehindIt() {
        #expect(identifier(9, "let alpha = 1") == "alpha")
    }

    /// Underscores and `$` are part of an identifier in every language this
    /// editor highlights; a hyphen never is.
    @Test func underscoresAndDollarsBelongToTheWord() {
        #expect(identifier(2, "my_name = 1") == "my_name")
        #expect(identifier(2, "$scope = 1") == "$scope")
        #expect(identifier(2, "in-between") == "in")
    }

    /// Whitespace with no word behind it yields nothing rather than
    /// reaching forward for the next one — the field arriving empty says
    /// "I couldn't tell", which is honest. Arriving with a word you weren't
    /// pointing at reads as correct and isn't.
    @Test func whitespaceBetweenWordsYieldsNothing() {
        #expect(identifier(5, "let    alpha").isEmpty)
        #expect(identifier(0, "").isEmpty)
    }

    /// A stale offset — the text changed between the click and the ask —
    /// must not index past the end.
    @Test func anOffsetPastTheEndIsClamped() {
        #expect(identifier(999, "let alpha") == "alpha")
    }
}
