@testable import Ghostty
import Testing

/// Covers how keyDown turns what the text input system did with a key
/// (handleEvent result, insertText and doCommand calls, marked text) into
/// what is sent to the terminal.
///
/// Each test describes the sequence AppKit and the input method produce for
/// a scenario, with the issue or PR that reported it where there is one.
struct SurfaceViewKeyDownOutputsTests {
    /// What reaches the terminal. The encoder drops non-modifier keys that
    /// are marked composing, so those count as nothing sent.
    enum Sent: Equatable {
        case key
        case text(String)
    }

    private static let arrowsReplayedAfterCommit: Set<String> = [
        "\u{F700}", // up
        "\u{F701}", // down
        "\u{F703}", // right
    ]

    private func sent(
        handled: Bool = true,
        inserted: [String] = [],
        command: Bool = false,
        markedBefore: Bool = false,
        markedAfter: Bool = false,
        key: String? = nil
    ) -> [Sent] {
        // keyDown does not consult the handleEvent result or doCommand
        // calls. The scenarios still describe them.
        _ = (handled, command)

        let outputs = Ghostty.SurfaceView.keyDownOutputs(.init(
            insertedTexts: inserted,
            markedTextBefore: markedBefore,
            markedTextAfter: markedAfter,
            keyCharacters: key,
            replaysAfterCommit: Self.arrowsReplayedAfterCommit.contains(key ?? "")
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
        #expect(sent(inserted: ["\u{000C}"], key: "\u{000C}") == [.key])
    }

    @Test func controlKeyAsCommandEncodesTheKey() {
        // ctrl+letter or ctrl+esc mapped to a key binding command
        // (moveToBeginningOfParagraph:, cancel:) must still reach the
        // terminal as the key (#7000).
        #expect(sent(command: true, key: "\u{0001}") == [.key])
    }

    @Test func commandKeyEncodesTheKey() {
        // Arrows, return, backspace: AppKit issues moveLeft:, insertNewline:,
        // deleteBackward: instead of inserting text.
        #expect(sent(command: true, key: "\r") == [.key])
    }

    @Test func unhandledKeyEncodesTheKey() {
        // No input context, or the text input system didn't handle the key.
        #expect(sent(handled: false, key: "a") == [.key])
    }

    @Test func loneLeadSurrogateSendsNothing() {
        // insertText with a lead surrogate accumulates an empty string. The
        // key was handled, so it must not be encoded on its own.
        withKnownIssue("The key is encoded with no text") {
            #expect(sent(inserted: [""], key: "a").isEmpty)
        }
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

    @Test func deadKeyFollowedByNonCombiningLetterIsSentAsText() {
        // "'" then "s" commits the accent and the letter.
        #expect(
            sent(inserted: ["'", "s"], markedBefore: true, key: "s") ==
                [.text("'"), .text("s")]
        )
    }

    // MARK: Input method consumes the key

    @Test func consumedKeySendsNothing() {
        // An input method that consumes a key without inserting text,
        // issuing a command or changing marked text, e.g. AquaSKK mode keys
        // (#4539).
        withKnownIssue("Only caught when the key also changes the keyboard layout ID") {
            #expect(sent(key: "l").isEmpty)
        }
    }

    @Test func startingCompositionSendsNothing() {
        // Korean 2-set "d" starts composing "ㅇ".
        #expect(sent(markedAfter: true, key: "d").isEmpty)
    }

    @Test func koreanBackspaceEditsOnlyThePreedit() {
        // Korean 2-set "gksr" composes "한ㄱ" with "ㄱ" in preedit.
        // Backspace should remove "ㄱ" (#1638).
        withKnownIssue("The preedit text is not cleared when deleting with Backspace") {
            #expect(sent(inserted: ["한"], markedAfter: true, key: "\u{7F}") == [.text("한")])
        }
    }

    @Test func pinyinBackspaceEditsOnlyThePreedit() {
        // "你好" committed, then "ni h" composing. Backspace edits the
        // composition and must not delete "好" (#7225).
        #expect(sent(markedBefore: true, markedAfter: true, key: "\u{7F}").isEmpty)
    }

    @Test func japaneseCandidateCyclingSendsNothing() {
        // Ctrl+F or arrows cycle candidates while composing (#7121).
        #expect(sent(markedBefore: true, markedAfter: true, key: "\u{0006}").isEmpty)
    }

    @Test func cancellingCompositionSendsNothing() {
        // Backspace or ctrl+h that clears the preedit without committing
        // must not delete the text before the composition (#7225).
        #expect(sent(markedBefore: true, key: "\u{7F}").isEmpty)
    }

    @Test func cancellingCompositionWithCommandSendsNothing() {
        // Same, when the input method still passes the key on after
        // clearing the preedit without a commit (#7225).
        #expect(sent(command: true, markedBefore: true, key: "\u{7F}").isEmpty)
    }

    @Test func commandWhilePreeditRemainsSendsNothing() {
        #expect(
            sent(command: true, markedBefore: true, markedAfter: true, key: "\u{7F}").isEmpty
        )
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

    @Test func fullWidthPunctuationIsSentAsText() {
        // Pinyin turns "," into "，". That text has no relation to the
        // comma key, so it must not be encoded as the key.
        withKnownIssue("The text is encoded as the comma key") {
            #expect(sent(inserted: ["，"], key: ",") == [.text("，")])
        }
    }

    @Test func japaneseEnterOnlyCommits() {
        // Enter confirms the conversion. The input method consumes it, so
        // no newline is sent (#7121).
        #expect(sent(inserted: ["日本語"], markedBefore: true, key: "\r") == [.text("日本語")])
    }

    @Test func commitWithoutCommandSendsOnlyText() {
        // A Japanese ctrl+j that commits the preedit must not also send
        // ctrl+j (LF) (d60a16c14).
        #expect(
            sent(inserted: ["日本"], markedBefore: true, key: "\u{000A}") ==
                [.text("日本")]
        )
    }

    @Test func commitMatchingTheKeyIsStillText() {
        // After a composition, committed text goes out as text even if it
        // equals what the key types on its own.
        #expect(sent(inserted: ["a"], markedBefore: true, key: "a") == [.text("a")])
    }

    @Test(arguments: ["\u{0008}", "\u{000A}", "\u{000D}", "\u{000E}"])
    func controlTextWhileComposingIsDropped(text: String) {
        // Japanese ctrl+h/j/m/n act on the composition. A bare C0 control
        // character inserted while composing belongs to the input method
        // (a43cc02eb).
        #expect(sent(inserted: [text], markedBefore: true, key: text).isEmpty)
    }

    @Test func koreanEscapeOnLoneJamoSendsEscape() {
        // vim: Esc while composing a lone jamo such as "ㄱ". The input method
        // discards the jamo and inserts Esc as text instead of issuing
        // cancelOperation:. The Esc must still reach the terminal to leave
        // insert mode (#1638).
        withKnownIssue("Esc is dropped as control text while composing") {
            #expect(sent(inserted: ["\u{1B}"], markedBefore: true, key: "\u{1B}") == [.key])
        }
    }

    // MARK: Commit followed by a command

    @Test func koreanBackspaceOnLastJamoDeletesIt() {
        // Korean 2-set "dks" then backspace x3: the third backspace commits
        // "ㅇ" and then issues deleteBackward:. The backspace must reach the
        // terminal so it erases the committed "ㅇ".
        withKnownIssue("The backspace is dropped, leaving \"ㅇ\"") {
            #expect(
                sent(inserted: ["ㅇ"], command: true, markedBefore: true, key: "\u{7F}") ==
                    [.text("ㅇ"), .key]
            )
        }
    }

    @Test func koreanEnterCommitsThenSendsReturn() {
        // Enter while composing "안" commits it and then issues
        // insertNewline:, same as in a text view.
        withKnownIssue("Only the commit is sent, without the newline") {
            #expect(
                sent(inserted: ["안"], command: true, markedBefore: true, key: "\r") ==
                    [.text("안"), .key]
            )
        }
    }

    @Test func koreanEscapeCommitsThenSendsEscape() {
        // vim: "한글" then Esc must commit "글" and leave insert mode with a
        // single Esc (#1663, #1638).
        withKnownIssue("Only the commit is sent, so vim needs a second Esc") {
            #expect(
                sent(inserted: ["글"], command: true, markedBefore: true, key: "\u{1B}") ==
                    [.text("글"), .key]
            )
        }
    }

    @Test(arguments: ["\u{F700}", "\u{F701}", "\u{F703}"])
    func koreanArrowCommitsThenSendsArrow(arrow: String) {
        // Up, down and right while composing commit and then issue a
        // move command (fa141a726).
        #expect(
            sent(inserted: ["한"], command: true, markedBefore: true, key: arrow) ==
                [.text("한"), .key]
        )
    }

    @Test func koreanPlainLeftArrowOnlyCommits() {
        // Plain left while composing commits and leaves the caret after the
        // committed text, so no arrow is sent (fa141a726).
        #expect(sent(inserted: ["한"], markedBefore: true, key: "\u{F702}") == [.text("한")])
    }
}
