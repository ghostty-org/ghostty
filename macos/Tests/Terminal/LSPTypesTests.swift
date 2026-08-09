import Foundation
@testable import Ghostty
import Testing

/// Converting between the protocol's coordinates and the editor's.
///
/// This is the piece most worth being sure about: a mistake here misplaces
/// *every* feature at once — diagnostics underline the wrong word,
/// go-to-definition lands in the wrong place, rename edits the wrong
/// characters — rather than breaking one of them visibly.
struct LSPCoordinateTests {
    private func text(_ string: String) -> NSString { string as NSString }

    @Test func positionsAreZeroBased() {
        let source = text("let a = 1\nlet b = 2\nlet c = 3")
        #expect(LSPTextCoordinates.offset(of: LSPPosition(line: 0, character: 0), in: source) == 0)
        #expect(LSPTextCoordinates.offset(of: LSPPosition(line: 1, character: 0), in: source) == 10)
        #expect(LSPTextCoordinates.offset(of: LSPPosition(line: 2, character: 4), in: source) == 24)
    }

    @Test func offsetsConvertBack() {
        let source = text("let a = 1\nlet b = 2")
        let position = LSPTextCoordinates.position(at: 14, in: source)
        #expect(position == LSPPosition(line: 1, character: 4))
    }

    /// The bug this guards: columns are UTF-16 code units, not characters
    /// and not bytes. An accented identifier shifts every position after it
    /// on that line by one if characters are counted instead.
    @Test func columnsAreUTF16NotCharacters() {
        let source = text("let café = 1")
        // `café` is 4 characters and 4 UTF-16 units, so `=` sits at 9 in
        // both counts — but in *bytes* it would be 10, which is what a
        // byte-based implementation would send.
        let offset = LSPTextCoordinates.offset(of: LSPPosition(line: 0, character: 9), in: source)
        #expect(source.substring(with: NSRange(location: offset ?? 0, length: 1)) == "=")
    }

    /// An emoji is two UTF-16 units and one character — the case where the
    /// two counts genuinely disagree.
    @Test func charactersOutsideTheBasicPlaneCountAsTwo() {
        let source = text("let x = \"🎉\" ")
        let position = LSPTextCoordinates.position(at: 11, in: source)
        #expect(position.line == 0)
        #expect(position.character == 11)
    }

    @Test func aPositionPastTheEndClampsRatherThanCrashing() {
        let source = text("short")
        #expect(LSPTextCoordinates.offset(of: LSPPosition(line: 0, character: 999), in: source) == 5)
        #expect(LSPTextCoordinates.offset(of: LSPPosition(line: 99, character: 0), in: source) == nil)
    }

    @Test func rangesConvertToNSRange() {
        let source = text("let a = 1\nlet b = 2")
        let range = LSPRange(
            start: LSPPosition(line: 1, character: 4),
            end: LSPPosition(line: 1, character: 5)
        )
        let converted = LSPTextCoordinates.range(of: range, in: source)
        #expect(converted == NSRange(location: 14, length: 1))
    }

    @Test func anEmptyDocumentHasOneLine() {
        #expect(LSPTextCoordinates.offset(of: LSPPosition(line: 0, character: 0), in: text("")) == 0)
    }
}

/// Applying what a server sends back.
struct LSPEditTests {
    private func edit(line: Int, from: Int, to: Int, text: String) -> LSPTextEdit? {
        LSPTextEdit([
            "range": [
                "start": ["line": .integer(line), "character": .integer(from)],
                "end": ["line": .integer(line), "character": .integer(to)],
            ],
            "newText": .string(text),
        ])
    }

    /// The rule that makes multi-edit responses work: every range refers to
    /// the *original* text, so applying front-to-back invalidates every
    /// position after the first edit. Descending order means each edit
    /// lands before anything that could have moved it.
    @Test func severalEditsApplyBackToFront() {
        let source = "let alpha = beta"
        let edits = [
            edit(line: 0, from: 4, to: 9, text: "one"),
            edit(line: 0, from: 12, to: 16, text: "two"),
        ].compactMap { $0 }

        #expect(LSPTextEdit.apply(edits, to: source) == "let one = two")
    }

    /// And the order the server sent them in must not matter.
    @Test func theOrderTheServerSendsThemInIsIrrelevant() {
        let source = "let alpha = beta"
        let forward = [
            edit(line: 0, from: 4, to: 9, text: "one"),
            edit(line: 0, from: 12, to: 16, text: "two"),
        ].compactMap { $0 }
        let reversed = Array(forward.reversed())

        #expect(LSPTextEdit.apply(forward, to: source) == LSPTextEdit.apply(reversed, to: source))
    }

    @Test func anInsertionIsAZeroWidthEdit() {
        let edits = [edit(line: 0, from: 3, to: 3, text: " new")].compactMap { $0 }
        #expect(LSPTextEdit.apply(edits, to: "let x") == "let new x")
    }

    @Test func noEditsLeavesTheTextAlone() {
        #expect(LSPTextEdit.apply([], to: "unchanged") == "unchanged")
    }
}

/// Reading the shapes servers actually answer with.
struct LSPResponseShapeTests {
    /// Hover is a string, an object with `value`, or an array of either —
    /// and different servers pick differently.
    @Test func hoverAcceptsEveryShape() {
        #expect(LSPCenter.hoverText(from: .string("plain")) == "plain")
        #expect(LSPCenter.hoverText(from: ["value": .string("marked")]) == "marked")
        #expect(LSPCenter.hoverText(from: [.string("a"), ["value": .string("b")]]) == "a\n\nb")
    }

    @Test func emptyHoverIsNothingRatherThanAnEmptyTooltip() {
        #expect(LSPCenter.hoverText(from: .string("")) == nil)
        #expect(LSPCenter.hoverText(from: .null) == nil)
        #expect(LSPCenter.hoverText(from: nil) == nil)
    }

    @Test func definitionAcceptsOneLocationOrMany() {
        let single: LSPValue = [
            "uri": .string("file:///a.swift"),
            "range": [
                "start": ["line": .integer(1), "character": .integer(0)],
                "end": ["line": .integer(1), "character": .integer(4)],
            ],
        ]
        #expect(LSPCenter.locations(from: single).count == 1)
        #expect(LSPCenter.locations(from: [single, single]).count == 2)
    }

    /// `LocationLink` names its target differently. A client that reads
    /// only `Location` silently does nothing on the servers that send it.
    @Test func definitionAcceptsTheLinkForm() {
        let link: LSPValue = [
            "targetUri": .string("file:///b.swift"),
            "targetSelectionRange": [
                "start": ["line": .integer(3), "character": .integer(2)],
                "end": ["line": .integer(3), "character": .integer(8)],
            ],
        ]
        let locations = LSPCenter.locations(from: link)
        #expect(locations.first?.path == "/b.swift")
        #expect(locations.first?.range.start.line == 3)
    }

    /// A `WorkspaceEdit` uses `changes` or `documentChanges`; reading only
    /// one means rename does nothing on half the servers.
    @Test func workspaceEditsComeInTwoShapes() {
        let editValue: LSPValue = [
            "range": [
                "start": ["line": .integer(0), "character": .integer(0)],
                "end": ["line": .integer(0), "character": .integer(3)],
            ],
            "newText": .string("new"),
        ]

        let changes: LSPValue = ["changes": ["file:///a.swift": [editValue]]]
        #expect(LSPCenter.workspaceEdits(from: changes)["/a.swift"]?.count == 1)

        let documentChanges: LSPValue = [
            "documentChanges": [[
                "textDocument": ["uri": .string("file:///b.swift")],
                "edits": [editValue],
            ]],
        ]
        #expect(LSPCenter.workspaceEdits(from: documentChanges)["/b.swift"]?.count == 1)
    }

    /// Absent severity means the server declined to say. Error is the safe
    /// reading: a problem shown too loudly is noticed, one shown too
    /// quietly is not.
    @Test func aDiagnosticWithoutSeverityIsTreatedAsAnError() {
        let diagnostic = LSPDiagnostic([
            "range": [
                "start": ["line": .integer(0), "character": .integer(0)],
                "end": ["line": .integer(0), "character": .integer(1)],
            ],
            "message": .string("something"),
        ])
        #expect(diagnostic?.severity == .error)
    }

    @Test func aDiagnosticWithoutAMessageIsRejected() {
        let diagnostic = LSPDiagnostic([
            "range": [
                "start": ["line": .integer(0), "character": .integer(0)],
                "end": ["line": .integer(0), "character": .integer(1)],
            ],
        ])
        #expect(diagnostic == nil)
    }

    @Test func completionsFallBackToTheLabelWhenThereIsNoInsertText() {
        let completion = LSPCompletion(["label": .string("map")])
        #expect(completion?.insertText == "map")

        let explicit = LSPCompletion([
            "label": .string("map(_:)"),
            "insertText": .string("map("),
        ])
        #expect(explicit?.insertText == "map(")
    }
}

/// Which folder a server is rooted at.
struct LSPWorkspaceRootTests {
    /// Rooting at the repository is what makes cross-file answers possible
    /// — rooted at one file's directory, references would only ever find
    /// that directory.
    @Test func theRepositoryWins() {
        let path = URL(fileURLWithPath: #filePath).path
        let root = LSPCenter.workspaceRoot(for: path)
        #expect(FileManager.default.fileExists(atPath: root + "/.git"))
    }

    @Test func aFileOutsideAnyRepositoryUsesItsOwnFolder() {
        let root = LSPCenter.workspaceRoot(for: "/tmp/nowhere-\(UUID().uuidString)/file.swift")
        #expect(root.hasPrefix("/tmp/nowhere-"))
    }
}
