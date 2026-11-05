@testable import Ghostty
import Testing
import AppKit

/// Covers how keyDown turns what the text input system did with a key
/// (handleEvent result, insertText and doCommand calls, marked text) into
/// what is sent to the terminal.
///
/// Each test describes the sequence AppKit and the input method produce for
/// a scenario that was reported in an issue or discussion.
struct SurfaceViewKeyDownOutputsTests {
    /// What reaches the terminal. The encoder drops non-modifier keys that
    /// are marked composing, so those count as nothing sent.
    enum Sent: Equatable {
        case key
        case text(String)
    }

    /// Runs one keyDown scenario through `keyDownOutputs` and returns what
    /// reaches the terminal.
    ///
    /// The parameters describe what AppKit and the input method did with
    /// the key during `interpretKeyEvents`.
    ///
    /// - Parameters:
    ///   - handled: The `NSTextInputContext.handleEvent` result. Not
    ///     consulted by keyDown at the moment, only documents the scenario.
    ///   - inserted: Texts passed to `insertText`, in order.
    ///   - command: Whether the input method issued a `doCommand`, e.g.
    ///     `insertNewline:`. Not consulted by keyDown at the moment, only
    ///     documents the scenario.
    ///   - markedBefore: Whether there was marked text before the key.
    ///   - markedAfter: Whether there is marked text after the key.
    ///   - key: The event's `characters`, e.g. `.ctrl("h")` or `.backspace`.
    ///   - physicalKey: The key from the event's `keyCode`. Only used to
    ///     decide whether the key is replayed after the input method commits
    ///     marked text, which currently only happens for arrow keys.
    ///   - modifiers: The event's modifier flags. Used with `physicalKey`
    ///     for the replay decision.
    /// - Returns: The keys and texts sent to the terminal, in order. A key
    ///   encoded as composing counts as nothing sent.
    private func sent(
        handled: Bool = true,
        inserted: [String] = [],
        command: Bool = false,
        markedBefore: Bool = false,
        markedAfter: Bool = false,
        key: String? = nil,
        physicalKey: Ghostty.Input.Key? = nil,
        modifiers: NSEvent.ModifierFlags = []
    ) -> [Sent] {
        _ = (handled, command)

        let outputs = Ghostty.SurfaceView.keyDownOutputs(.init(
            insertedTexts: inserted,
            markedTextBefore: markedBefore,
            markedTextAfter: markedAfter,
            keyCharacters: key,
            replaysAfterCommit: Ghostty.SurfaceView.shouldReplayCommittedPreeditKey(
                physicalKey,
                modifiers: modifiers
            )
        ))

        return outputs.compactMap { output in
            switch output {
            case .keyWithText(_, let composing): composing ? nil : .key
            case .text(let text): .text(text)
            }
        }
    }

    // MARK: Plain and control input (#7121)

    @Test func plainTypingEncodesTheKey() {
        // Dvorak "s" key types "o": the inserted text matches the event's
        // characters even though it differs from the US key.
        #expect(sent(inserted: ["o"], key: "o") == [.key])
        // non latin layout
        #expect(sent(inserted: ["👻"], key: "👻") == [.key])
    }

    @Test func controlCharacterTextEncodesTheKey() {
        // ctrl+letter inserted as its control character, on US, Dvorak or
        // Ergo-L (#5448).
        #expect(sent(inserted: [.ctrl("l")], key: .ctrl("l")) == [.key])
    }

    @Test func controlKeyAsCommandEncodesTheKey() {
        // ctrl+letter or ctrl+esc mapped to a key binding command
        // (moveToBeginningOfParagraph:, cancel:) must still reach the
        // terminal as the key (#7000).
        #expect(sent(command: true, key: .ctrl("a")) == [.key])
    }

    // MARK: Dead keys (#7121)

    @Test func deadKeySendsNothing() {
        // US International "'" enters the dead key state as marked text.
        #expect(sent(markedAfter: true, key: "'").isEmpty)
    }

    @Test func deadKeyCompositionIsSentAsText() {
        // "'" then "e" commits "é".
        #expect(sent(inserted: ["é"], markedBefore: true, key: "e") == [.text("é")])
    }

    // MARK: Input method consumes the key

    @Test func consumedKeySendsNothing() {
        // An input method that consumes a key without inserting text,
        // issuing a command or changing marked text, e.g. AquaSKK mode keys
        // (#4539, #2628).
        withKnownIssue("Only caught when the key also changes the keyboard layout ID") {
            #expect(sent(key: "l").isEmpty)
        }
    }

    @Test func startingCompositionSendsNothing() {
        // Korean 2-set "d" starts composing "ㅇ" (#766).
        #expect(sent(markedAfter: true, key: "d").isEmpty)
    }

    @Test func koreanBackspaceEditsOnlyThePreedit() {
        // Korean 2-set "gksr" composes "한ㄱ" with "ㄱ" in preedit.
        // Backspace should remove "ㄱ" (#1638).
        withKnownIssue("The preedit text is not cleared when deleting with Backspace") {
            #expect(sent(inserted: ["한"], markedAfter: true, key: .backspace) == [.text("한")])
        }
    }

    @Test func pinyinBackspaceEditsOnlyThePreedit() {
        // "你好" committed, then "ni h" composing. Backspace edits the
        // composition and must not delete "好" (#7225).
        #expect(sent(markedBefore: true, markedAfter: true, key: .backspace).isEmpty)
    }

    @Test func japaneseCandidateCyclingSendsNothing() {
        // Ctrl+F or arrows cycle candidates while composing (#7121).
        #expect(sent(markedBefore: true, markedAfter: true, key: .ctrl("f")).isEmpty)
    }

    @Test func cancellingCompositionSendsNothing() {
        // Backspace or ctrl+h that clears the preedit without committing
        // must not delete the text before the composition (#7225).
        #expect(sent(markedBefore: true, key: .backspace).isEmpty)
    }

    // MARK: Input method text

    @Test func koreanSyllablesAreSentAsText() {
        // Korean 2-set "gks" then "r": "한" + "ㄱ" commits "한" and starts
        // composing "ㄱ", so the terminal gets "한" rather than jamo (#766).
        #expect(
            sent(inserted: ["한"], markedBefore: true, markedAfter: true, key: "r") ==
                [.text("한")]
        )
    }

    @Test func koreanSpaceAfterCompositionIsNotEaten() {
        // Space while composing "한" commits it and inserts the space (#766).
        #expect(
            sent(inserted: ["한", " "], markedBefore: true, key: " ") ==
                [.text("한"), .text(" ")]
        )
    }

    @Test func japaneseEnterOnlyCommits() {
        // Enter confirms the conversion. The input method consumes it, so
        // no newline is sent (#7121).
        #expect(sent(inserted: ["日本語"], markedBefore: true, key: .return) == [.text("日本語")])
    }

    @Test(arguments: [String.f6, .f7])
    func japaneseCommitsOnFunctionKey(_ key: String) {
        // F6/7 should commit preedit text with azooKey IME
        // (#11560).
        #expect(sent(inserted: ["こんにちま"], markedBefore: true, key: key) == [.text("こんにちま")])
    }

    @Test func commitWithoutCommandSendsOnlyText() {
        // A Japanese ctrl+j that commits the preedit must not also send
        // ctrl+j (LF) (#10460).
        #expect(
            sent(inserted: ["日本"], markedBefore: true, key: .ctrl("j")) ==
                [.text("日本")]
        )
    }

    @Test(arguments: [String.ctrl("h"), .ctrl("j"), .ctrl("m"), .ctrl("n")])
    func controlTextWhileComposingIsDropped(text: String) {
        // Japanese ctrl+h/j/m/n act on the composition. A bare C0 control
        // character inserted while composing with ctrl held belongs to the
        // input method (#10460, #9826).
        #expect(sent(inserted: [text], markedBefore: true, key: text, modifiers: .control).isEmpty)
    }

    @Test func koreanReturnAfterSwitchingTabsSendsReturn() {
        // After switching tabs and back while composing, Return with "ㄴ"
        // marked inserts a carriage return as text instead of committing
        // "ㄴ" and issuing insertNewline: as it does otherwise. No ctrl is
        // held, so unlike Japanese ctrl+m it must reach the terminal (#15105).
        withKnownIssue("Return is dropped as control text while composing") {
            #expect(sent(inserted: [.return], markedBefore: true, key: .return) == [.key])
        }
    }

    @Test func koreanEscapeOnLoneJamoSendsEscape() {
        // vim: Esc while composing a lone jamo such as "ㄱ". The input method
        // discards the jamo and inserts Esc as text instead of issuing
        // cancelOperation:. The Esc must still reach the terminal to leave
        // insert mode.
        // #1638
        withKnownIssue("Esc is dropped as control text while composing") {
            #expect(sent(inserted: [.escape], markedBefore: true, key: .escape) == [.key])
        }
    }

    // MARK: Commit followed by a command

    @Test func koreanBackspaceOnLastJamoDeletesIt() {
        // Korean 2-set "dks" then backspace x3: the third backspace commits
        // "ㅇ" and then issues deleteBackward:. The backspace must reach the
        // terminal so it erases the committed "ㅇ".
        // #14797, #13439
        withKnownIssue("The backspace is dropped, leaving \"ㅇ\"") {
            #expect(
                sent(inserted: ["ㅇ"], command: true, markedBefore: true, key: .backspace) ==
                    [.text("ㅇ"), .key]
            )
        }
    }

    @Test func koreanEnterCommitsThenSendsReturn() {
        // Enter while composing "안" commits it and then issues
        // insertNewline:, same as in a text view.
        // #15108
        withKnownIssue("Only the commit is sent, without the newline") {
            #expect(
                sent(inserted: ["안"], command: true, markedBefore: true, key: .return) ==
                    [.text("안"), .key]
            )
        }
    }

    @Test func koreanEscapeCommitsThenSendsEscape() {
        // vim: "한글" then Esc must commit "글" and leave insert mode with a
        // single Esc (#1663, #1638, #13750).
        withKnownIssue("Only the commit is sent, so vim needs a second Esc") {
            #expect(
                sent(inserted: ["글"], command: true, markedBefore: true, key: .escape) ==
                    [.text("글"), .key]
            )
        }
    }

    @Test(arguments: [Ghostty.Input.Key.arrowUp, .arrowDown, .arrowRight])
    func koreanArrowCommitsThenSendsArrow(arrow: Ghostty.Input.Key) {
        // Up, down and right while composing commit and then issue a
        // move command (#11461).
        #expect(
            sent(inserted: ["한"], command: true, markedBefore: true, physicalKey: arrow) ==
                [.text("한"), .key]
        )
    }

    @Test func koreanPlainLeftArrowOnlyCommits() {
        // Plain left while composing commits and leaves the caret after the
        // committed text, so no arrow is sent (#11461).
        #expect(
            sent(inserted: ["한"], markedBefore: true, physicalKey: .arrowLeft) ==
                [.text("한")]
        )
    }

    @Test(arguments: [
        NSEvent.ModifierFlags.shift,
        .control,
        .option,
        .command,
    ])
    func koreanModifiedLeftArrowCommitsThenSendsArrow(modifier: NSEvent.ModifierFlags) {
        // A modified left while composing, e.g. shift+left to select, commits
        // and the arrow must still reach the terminal (#11461).
        #expect(
            sent(
                inserted: ["한"],
                markedBefore: true,
                physicalKey: .arrowLeft,
                modifiers: modifier
            ) == [.text("한"), .key]
        )
    }

    @Test func koreanLeftArrowIgnoresArrowKeyFlags() {
        // AppKit sets .function and .numericPad on every arrow event, so
        // they must not count as modifiers.
        #expect(
            sent(
                inserted: ["한"],
                markedBefore: true,
                physicalKey: .arrowLeft,
                modifiers: [.function, .numericPad]
            ) == [.text("한")]
        )
    }
}

/// Characters AppKit reports for the keys in these scenarios.
private extension String {
    static let backspace = String(NSEvent.SpecialKey.delete.unicodeScalar)
    static let `return` = String(NSEvent.SpecialKey.carriageReturn.unicodeScalar)
    static let f6 = String(NSEvent.SpecialKey.f6.unicodeScalar)
    static let f7 = String(NSEvent.SpecialKey.f7.unicodeScalar)
    static let escape = "\u{1B}"

    /// The C0 control character for ctrl+letter, e.g. BS for ctrl+h.
    static func ctrl(_ letter: Character) -> String {
        guard let ascii = letter.asciiValue else {
            preconditionFailure("ctrl+\(letter) has no control character")
        }
        return String(UnicodeScalar(ascii & 0x1F))
    }
}
