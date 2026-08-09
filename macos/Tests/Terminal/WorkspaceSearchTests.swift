import Foundation
@testable import Ghostty
import Testing

/// Parsing what `ripgrep` and `grep` print.
struct WorkspaceSearchTests {
    @Test func ripgrepLinesCarryAColumn() {
        let hit = WorkspaceSearch.parse(
            line: "/Projects/app/src/main.ts:42:9:  const total = sum(items)",
            hasColumn: true
        )
        #expect(hit?.path == "/Projects/app/src/main.ts")
        #expect(hit?.line == 42)
        #expect(hit?.column == 9)
        #expect(hit?.text == "  const total = sum(items)")
    }

    @Test func grepLinesDoNot() {
        let hit = WorkspaceSearch.parse(
            line: "/Projects/app/src/main.ts:42:  const total = sum(items)",
            hasColumn: false
        )
        #expect(hit?.line == 42)
        #expect(hit?.column == 1)
        #expect(hit?.text == "  const total = sum(items)")
    }

    /// The reason this parses from the front instead of splitting on every
    /// colon: matched *text* contains colons constantly — a dictionary
    /// literal, a URL, a type annotation — and field-splitting truncates
    /// the result at the first one.
    @Test func colonsInTheMatchedTextSurvive() {
        let hit = WorkspaceSearch.parse(
            line: "/a/b.ts:7:3:const url = \"https://x.com:8080/path\"",
            hasColumn: true
        )
        #expect(hit?.text == "const url = \"https://x.com:8080/path\"")
        #expect(hit?.line == 7)
    }

    @Test func aLineWithNoMatchStructureIsSkipped() {
        #expect(WorkspaceSearch.parse(line: "not a result at all", hasColumn: true) == nil)
        #expect(WorkspaceSearch.parse(line: "", hasColumn: false) == nil)
        #expect(WorkspaceSearch.parse(line: "/a/b.ts:notanumber:x", hasColumn: false) == nil)
    }

    @Test func outputParsesToSeveralHits() {
        let output = """
        /a/one.ts:1:1:first
        /a/two.ts:9:4:second

        /a/three.ts:12:2:third
        """
        let hits = WorkspaceSearch.parse(output: output, hasColumn: true)
        #expect(hits.count == 3)
        #expect(hits.map(\.line) == [1, 9, 12])
    }

    // MARK: Arguments

    /// A query beginning with `-` is something people type by accident, and
    /// without `--` the tool reads it as a flag and fails in a way that
    /// looks like search itself is broken.
    @Test func theQueryIsSeparatedFromTheFlags() {
        // A query that looks like a flag but is not one of these tools'
        // own — searching for `--color` would find rg's real flag and
        // prove nothing.
        let query = "-fixme"

        for tool in [WorkspaceSearch.Tool.ripgrep("/rg"), .grep("/grep")] {
            let arguments = WorkspaceSearch.arguments(for: tool, query: query, root: "/root")
            guard let separator = arguments.firstIndex(of: "--") else {
                Issue.record("\(tool) has no -- separator")
                continue
            }
            // Immediately after the separator, which is the only position
            // where a leading dash is read as text rather than as a flag.
            #expect(arguments[separator + 1] == query, "\(tool) passes the query as a flag")
            #expect(arguments.last == "/root")
        }
    }

    /// Both tools search literally, not by regular expression: somebody
    /// looking for `items.map(` means those characters, and treating it as
    /// a pattern finds nothing and explains nothing.
    @Test func theSearchIsLiteralAndCaseInsensitive() {
        let rg = WorkspaceSearch.arguments(for: .ripgrep("/rg"), query: "x", root: "/r")
        #expect(rg.contains("--fixed-strings"))
        #expect(rg.contains("--ignore-case"))

        let grep = WorkspaceSearch.arguments(for: .grep("/grep"), query: "x", root: "/r")
        #expect(grep.contains("-F"))
        #expect(grep.contains("-i"))
    }

    /// grep has no `.gitignore`, so the directories that would otherwise
    /// bury every result have to be excluded by hand.
    @Test func grepSkipsTheNoiseRipgrepSkipsForFree() {
        let grep = WorkspaceSearch.arguments(for: .grep("/grep"), query: "x", root: "/r")
        #expect(grep.contains("--exclude-dir=.git"))
        #expect(grep.contains("--exclude-dir=node_modules"))
        #expect(grep.contains("-I"), "binary files would otherwise be searched")
    }

    // MARK: Presentation

    @Test func resultsShowARelativePath() {
        let hit = SearchHit(path: "/root/src/app/main.ts", line: 1, column: 1, text: "x")
        #expect(hit.relativePath(to: "/root") == "src/app/main.ts")
        #expect(hit.name == "main.ts")
    }

    @Test func aPathOutsideTheRootStaysAbsolute() {
        let hit = SearchHit(path: "/elsewhere/x.ts", line: 1, column: 1, text: "x")
        #expect(hit.relativePath(to: "/root") == "/elsewhere/x.ts")
    }

    /// Two matches on one line are different results.
    @Test func hitsOnTheSameLineHaveDistinctIdentities() {
        let first = SearchHit(path: "/a.ts", line: 3, column: 1, text: "x")
        let second = SearchHit(path: "/a.ts", line: 3, column: 20, text: "x")
        #expect(first.id != second.id)
    }
}

/// Reducing a document to the bars the minimap draws.
struct CodeMinimapTests {
    private func rows(_ source: String) -> [CodeMinimapView.Row] {
        let tokens = SyntaxHighlighter(language: .swift)
            .tokens(in: source, range: NSRange(location: 0, length: (source as NSString).length))
        return CodeMinimapView.rows(for: source, tokens: tokens)
    }

    @Test func oneRowPerLine() {
        let source = "let a = 1\nlet b = 2\nlet c = 3"
        #expect(rows(source).count == 3)
    }

    /// Blank lines are what give a minimap its shape — they have to be
    /// present and empty, not skipped.
    @Test func blankLinesAreKeptAndEmpty() {
        let source = "let a = 1\n\nlet c = 3"
        let result = rows(source)
        #expect(result.count == 3)
        #expect(result[1].length == 0)
    }

    /// Indentation is the other half of the shape.
    @Test func indentationIsMeasured() {
        let source = "func x() {\n    let a = 1\n}"
        let result = rows(source)
        #expect(result[0].indent == 0)
        #expect(result[1].indent == 4)
    }

    /// A line's colour is whatever it starts as, so a comment line reads as
    /// a comment at two pixels tall.
    @Test func aCommentLineIsColouredAsAComment() {
        let result = rows("// explanation\nlet a = 1")
        #expect(result[0].kind == .comment)
        #expect(result[1].kind == .keyword)
    }

    @Test func anEmptyDocumentProducesNothingToDraw() {
        #expect(rows("").allSatisfy { $0.length == 0 })
    }

    /// The length is of the *trimmed* line: trailing whitespace would
    /// otherwise draw a bar for a line that looks blank on screen.
    @Test func trailingWhitespaceDoesNotWidenABar() {
        let result = rows("let a = 1        \n")
        #expect(result[0].length == "let a = 1".count)
    }
}
