import AppKit
import Testing

@testable import Ghostty

/// Covers how keyDown turns what the text input system did with a key
/// (handleEvent result, insertText and doCommand calls, marked text) into
/// what is sent to the terminal.
///
/// Each test describes the sequence AppKit and the input method produce for
/// a scenario that was reported in an issue or discussion.
@MainActor
struct SurfaceViewKeyDownOutputsTests {
    /// What reaches the terminal.
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
    /// - Returns: The keys and texts sent to the terminal, in order.
    private func sent(
        handled: Bool = true,
        inserted: [String] = [],
        command: Bool = false,
        markedBefore: Bool = false,
        markedAfter: Bool = false,
        key: String? = nil,
    ) -> [Sent] {
        _ = (handled, command)
        // A temporary copy of `SurfaceView.shouldReplayCommittedPreeditKey`
        let keysAllowedToReplay: [String?] = [
            .character(for: .arrowDown),
            .character(for: .arrowRight),
            .character(for: .arrowUp),
        ]
        let outputs = Ghostty.SurfaceView.keyDownOutputs(
            .init(
                insertedTexts: inserted,
                markedTextBefore: markedBefore,
                markedTextAfter: markedAfter,
                keyCharacters: key,
                replaysAfterCommit: keysAllowedToReplay.contains(key),
            )
        )

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
        #expect(
            sent(
                inserted: [.character(for: .l) ?? ""],
                key: .character(for: .l)
            ) == [.key]
        )
    }

    @Test func controlKeyAsCommandEncodesTheKey() {
        // ctrl+letter or ctrl+esc mapped to a key binding command
        // (moveToBeginningOfParagraph:, cancel:) must still reach the
        // terminal as the key (#7000).
        #expect(sent(command: true, key: .character(for: .a)) == [.key])
    }

    // MARK: Dead keys (#7121)

    @Test func deadKeySendsNothing() {
        // US International "'" enters the dead key state as marked text.
        #expect(sent(markedAfter: true, key: "'").isEmpty)
    }

    @Test func deadKeyCompositionIsSentAsText() {
        // "'" then "e" commits "é".
        #expect(
            sent(inserted: ["é"], markedBefore: true, key: "e") == [.text("é")]
        )
    }

    // MARK: Input method consumes the key

    @Test func consumedKeySendsNothing() {
        // An input method that consumes a key without inserting text,
        // issuing a command or changing marked text, e.g. AquaSKK mode keys
        // (#4539, #2628).
        withKnownIssue("AquaSKK switch keys are consumed by terminal") {
            #expect(sent(key: "l").isEmpty)
            #expect(sent(key: .character(for: .j, modifiers: .control)).isEmpty)
        }
    }

    @Test func startingCompositionSendsNothing() {
        // Korean 2-set "d" starts composing "ㅇ" (#766).
        #expect(sent(markedAfter: true, key: "d").isEmpty)
    }

    @Test func koreanBackspaceEditsOnlyThePreedit() {
        // Korean 2-set "gksr" composes "한ㄱ" with "ㄱ" in preedit.
        // Backspace should remove "ㄱ" (#1638).
        withKnownIssue("Backspace ends Korean composition and clear") {
            #expect(
                sent(
                    inserted: ["ㄱ"],
                    command: true,
                    markedBefore: true,
                    key: .character(for: .backspace)
                ) == [.text("ㄱ"), .key]
            )
        }
    }

    @Test func pinyinBackspaceEditsOnlyThePreedit() {
        // "你好" committed, then "ni h" composing. Backspace edits the
        // composition and must not delete "好" (#7225).
        #expect(
            sent(
                markedBefore: true,
                markedAfter: true,
                key: .character(for: .backspace)
            ).isEmpty
        )
    }

    @Test func japaneseCandidateCyclingSendsNothing() {
        // Ctrl+F or arrows cycle candidates while composing (#7121).
        #expect(
            sent(
                markedBefore: true,
                markedAfter: true,
                key: .character(for: .f, modifiers: .control)
            ).isEmpty
        )
    }

    @Test func cancellingCompositionSendsNothing() {
        // Backspace or ctrl+h that clears the preedit without committing
        // must not delete the text before the composition (#7225).
        #expect(
            sent(markedBefore: true, key: .character(for: .backspace)).isEmpty
        )
    }

    // MARK: Input method text

    @Test func koreanSyllablesAreSentAsText() {
        // Korean 2-set "gks" then "r": "한" + "ㄱ" commits "한" and starts
        // composing "ㄱ", so the terminal gets "한" rather than jamo (#766).
        #expect(
            sent(
                inserted: ["한"],
                markedBefore: true,
                markedAfter: true,
                key: "r"
            ) == [.text("한")]
        )
    }

    @Test func koreanSpaceAfterCompositionIsNotEaten() {
        // Space while composing "한" commits it and inserts the space (#766).
        #expect(
            sent(inserted: ["한", " "], markedBefore: true, key: " ") == [
                .text("한"), .text(" "),
            ]
        )
    }

    @Test func japaneseEnterOnlyCommits() {
        // Enter confirms the conversion. The input method consumes it, so
        // no newline is sent (#7121).
        #expect(
            sent(
                inserted: ["日本語"],
                markedBefore: true,
                key: .character(for: .enter)
            ) == [.text("日本語")]
        )
    }

    @Test(arguments: [Ghostty.Input.Key.f6, .f7])
    func japaneseCommitsOnFunctionKey(_ key: Ghostty.Input.Key) {
        // F6/7 should commit preedit text with azooKey IME
        // (#11560).
        #expect(
            sent(
                inserted: ["こんにちま"],
                markedBefore: true,
                key: .character(for: key)
            ) == [.text("こんにちま")]
        )
    }

    @Test func commitWithoutCommandSendsOnlyText() {
        // A Japanese ctrl+j that commits the preedit must not also send
        // ctrl+j (LF) (#10460).
        #expect(
            sent(
                inserted: ["日本"],
                markedBefore: true,
                key: .character(for: .j, modifiers: .control)
            ) == [.text("日本")]
        )
    }

    @Test(arguments: [Ghostty.Input.Key.h, .j, .m, .n])
    func controlTextWhileComposingIsDropped(key: Ghostty.Input.Key) {
        // Japanese ctrl+h/j/m/n act on the composition. A bare C0 control
        // character inserted while composing with ctrl held belongs to the
        // input method (#10460, #9826).
        #expect(
            sent(
                inserted: [],
                markedBefore: true,
                key: .character(for: key, modifiers: .control)
            ).isEmpty
        )
        #expect(
            sent(
                inserted: [],
                markedBefore: true,
                markedAfter: true,
                key: .character(for: key, modifiers: .control)
            ).isEmpty
        )
    }

    @Test func koreanReturnAfterSwitchingTabsCommits() {
        // After switching tabs and back while composing, KIM_Extension would
        // drop previous marked text, return after switching will only commit
        // a return character.
        // (#15105).
        withKnownIssue("Return is dropped as control text while composing") {
            #expect(
                sent(
                    inserted: [.character(for: .enter) ?? ""],
                    markedBefore: true,
                    key: .character(for: .enter)
                ) == [.text(.character(for: .enter) ?? "")]
            )
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
                sent(
                    inserted: ["ㅇ"],
                    command: true,
                    markedBefore: true,
                    key: .character(for: .backspace)
                ) == [.text("ㅇ"), .key]
            )
        }
    }

    @Test func koreanEnterCommitsThenSendsReturn() {
        // Enter while composing "안" commits it and then issues
        // insertNewline:, same as in a text view.
        // #15108
        withKnownIssue("Only the commit is sent, without the newline") {
            #expect(
                sent(
                    inserted: ["안"],
                    command: true,
                    markedBefore: true,
                    key: .character(for: .enter)
                ) == [.text("안"), .key]
            )
        }
    }

    @Test func koreanEscapeCommitsThenSendsEscape() {
        // vim: "한글" then Esc must commit "글" and leave insert mode with a
        // single Esc (#1663, #1638, #13750).
        withKnownIssue("Esc is dropped after commit") {
            #expect(
                sent(
                    inserted: ["글"],
                    command: true,
                    markedBefore: true,
                    key: .character(for: .escape)
                ) == [.text("글"), .key]
            )
        }
    }

    @Test(arguments: [
        NSEvent.ModifierFlags.shift,
        .control,
        .option,
        .command,
        [],
    ])
    func koreanModifiedArrowCommitsThenSendsArrow(
        modifiers: NSEvent.ModifierFlags
    ) {
        // A (modified) arrow while composing commits and the arrow must still reach the terminal.
        // (Related: #11461).
        for arrow in [
            Ghostty.Input.Key.arrowUp, .arrowDown, .arrowRight, .arrowLeft,
        ] {
            // Committing issue is fixed in #12447
            #expect(
                sent(
                    inserted: ["한"],
                    command: true,
                    markedBefore: true,
                    key: .character(for: arrow, modifiers: modifiers)
                ).contains(.text("한"))
            )
            if arrow != .arrowLeft {
                #expect(
                    sent(
                        inserted: ["한"],
                        command: true,
                        markedBefore: true,
                        key: .character(for: arrow, modifiers: modifiers),
                    ) == [.text("한"), .key]
                )
            } else {
                withKnownIssue("Arrow left are dropped and after commit") {
                    #expect(
                        sent(
                            inserted: ["한"],
                            command: true,
                            markedBefore: true,
                            key: .character(for: .arrowLeft, modifiers: modifiers),
                        ) == [.text("한"), .key]
                    )
                }
            }
        }
    }
}

extension String {
    @MainActor
    fileprivate static func character(
        for key: Ghostty.Input.Key,
        modifiers: NSEvent.ModifierFlags = []
    ) -> String? {
        guard
            let keyCode = key.keyCode,
            let char = KeyboardLayout.character(
                for: keyCode,
                modifiers: modifiers
            )
        else {
            return nil
        }
        return String(char)
    }
}
