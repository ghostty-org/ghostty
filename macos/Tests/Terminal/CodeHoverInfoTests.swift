import AppKit
@testable import Ghostty
import Testing

/// Splitting a language server's hover payload into declaration and prose.
///
/// The payloads here are the real shapes: `sourcekit-lsp`,
/// `typescript-language-server` and `pylsp` each answer in markdown, and each
/// does it slightly differently. Getting the split wrong shows the reader
/// either backtick-fenced noise or a declaration set in body text.
struct CodeHoverInfoTests {
    @Test func theFirstFencedBlockIsTheDeclaration() {
        let (signature, documentation) = CodeHoverInfo.split(markdown: """
        ```swift
        func save() throws
        ```

        Writes the buffer to disk.
        """)

        #expect(signature == "func save() throws")
        #expect(documentation == "Writes the buffer to disk.")
    }

    /// The rule between the two carries nothing once they are apart, and left
    /// in it reads as a stray row of dashes at the top of the prose.
    @Test func theHorizontalRuleBetweenThemIsDropped() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        ```typescript
        (property) SetupWorker.start: (options?: StartOptions) => StartReturnType
        ```

        ---

        Registers and activates the mock Service Worker.
        """)

        #expect(documentation == "Registers and activates the mock Service Worker.")
    }

    /// A dashed line is only a rule when that is all it is — a sentence that
    /// happens to open with a dash is prose.
    @Test func aDashedListItemIsNotMistakenForARule() {
        let (_, documentation) = CodeHoverInfo.split(markdown: "- sep: the separator")
        #expect(documentation == "- sep: the separator")
    }

    /// A `@see` example, or a second overload: worth reading, and the fence
    /// markers are not.
    @Test func laterFencedBlocksKeepTheirContentAndLoseTheirFences() {
        let (signature, documentation) = CodeHoverInfo.split(markdown: """
        ```swift
        func start()
        ```

        See also:

        ```swift
        worker.start()
        ```
        """)

        #expect(signature == "func start()")
        #expect(documentation == "See also:\n\nworker.start()")
    }

    /// Plenty of servers answer in plain text. It is documentation, not a
    /// declaration, and calling it one would set a paragraph in the code font.
    @Test func aPayloadWithNoFenceIsAllProse() {
        let (signature, documentation) = CodeHoverInfo.split(markdown: "The current value.")

        #expect(signature == nil)
        #expect(documentation == "The current value.")
    }

    /// A multi-line declaration is one block, not the first line of one.
    @Test func aDeclarationSpanningLinesIsKeptWhole() {
        let (signature, _) = CodeHoverInfo.split(markdown: """
        ```swift
        func apply(
            theme: CodeTheme
        )
        ```
        """)

        #expect(signature == "func apply(\n    theme: CodeTheme\n)")
    }

    /// Nothing to say is different from an empty card: the engine checks
    /// `isEmpty` before opening a window, and a blank card floating over the
    /// code is what happens when it lies.
    @Test func emptinessCountsProblemsAsWellAsText() {
        #expect(CodeHoverInfo().isEmpty)
        #expect(CodeHoverInfo(signature: "func f()").isEmpty == false)
        #expect(CodeHoverInfo(
            problems: [.init(message: "unresolved", source: nil, color: .systemRed)]
        ).isEmpty == false)
    }

    /// A doc comment arrives wrapped to the column its author's editor used.
    /// Wrapping it again at the card's width is what produced the ragged
    /// "short line, long line" prose — markdown says a single newline is a
    /// space, and reading it that way is what makes the card read as text.
    @Test func hardWrappedProseIsRejoined() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        A plan file is plain markdown: no front matter,
        no working directory, no session id.
        """)

        #expect(documentation == "A plan file is plain markdown: no front matter, no working directory, no session id.")
    }

    /// A blank line is the one break markdown does keep, and paragraphs are
    /// worth keeping apart.
    @Test func blankLinesStayParagraphBreaks() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        First paragraph
        continues here.

        Second paragraph.
        """)

        #expect(documentation == "First paragraph continues here.\n\nSecond paragraph.")
    }

    /// In a list the break *is* the meaning, so rejoining would run the items
    /// together into one sentence.
    @Test func listItemsKeepTheirOwnLines() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        Options:

        - sep: the separator
        - end: the terminator
        """)

        #expect(documentation == "Options:\n\n- sep: the separator\n- end: the terminator")
    }

    /// Same for a fenced example: its line breaks are code, not wrapping.
    @Test func fencedExamplesAreNotReflowed() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        ```swift
        func f()
        ```

        Example:

        ```swift
        let a = 1
        let b = 2
        ```
        """)

        #expect(documentation == "Example:\n\nlet a = 1\nlet b = 2")
    }

    /// What the copy button puts on the clipboard: the problem, the
    /// declaration and the prose, in the order they are read.
    @Test func copyingTakesEverythingOnTheCard() {
        let info = CodeHoverInfo(
            problems: [.init(message: "unresolved", source: "SourceKit", color: .systemRed)],
            signature: "func f()",
            documentation: "Does nothing."
        )

        #expect(info.plainText == "[SourceKit] unresolved\n\nfunc f()\n\nDoes nothing.")
    }

    /// A server that names no source still has a message worth copying.
    @Test func copyingOmitsAnAbsentSource() {
        let info = CodeHoverInfo(
            problems: [.init(message: "unresolved", source: nil, color: .systemRed)]
        )

        #expect(info.plainText == "unresolved")
    }

    /// Whitespace-only payloads are the empty case, not a card with a blank
    /// line in it.
    @Test func blankPayloadsProduceNothing() {
        let (signature, documentation) = CodeHoverInfo.split(markdown: "\n  \n")

        #expect(signature == nil)
        #expect(documentation == nil)
    }
}
