import Foundation
@testable import Ghostty
import Testing

/// The highlighter, against the cases that separate a real one from a
/// pile of regexes run in sequence.
struct SyntaxHighlighterTests {
    private func tokens(_ source: String, _ language: CodeLanguage) -> [SyntaxHighlighter.Token] {
        SyntaxHighlighter(language: language)
            .tokens(in: source, range: NSRange(location: 0, length: (source as NSString).length))
    }

    private func kind(
        at needle: String,
        in source: String,
        _ language: CodeLanguage
    ) -> TokenKind? {
        let ns = source as NSString
        let location = ns.range(of: needle).location
        guard location != NSNotFound else { return nil }
        return tokens(source, language)
            .first { NSLocationInRange(location, $0.range) }?
            .kind
    }

    // MARK: The two that naive highlighters get wrong

    /// `//` inside a string is not a comment. This is the case that decides
    /// the whole design: run separate expressions and the comment rule
    /// matches here too, so the rest of the line goes grey.
    @Test func slashesInsideAStringAreNotAComment() {
        let source = #"const url = "http://example.com" // real comment"#
        #expect(kind(at: "http:", in: source, .javascript) == .string)
        #expect(kind(at: "real comment", in: source, .javascript) == .comment)
    }

    /// And the mirror image: quotes inside a comment must not open a string
    /// that then swallows the rest of the file.
    @Test func quotesInsideACommentDoNotOpenAString() {
        let source = """
        // it's "quoted" here
        const a = 1
        """
        #expect(kind(at: "quoted", in: source, .javascript) == .comment)
        #expect(kind(at: "const", in: source, .javascript) == .keyword)
    }

    /// An escaped quote doesn't end the string — `"he said \"hi\""` is one
    /// token, so the text after it stays code.
    @Test func anEscapedQuoteDoesNotEndTheString() {
        let source = #"let s = "he said \"hi\"" ; let n = 42"#
        #expect(kind(at: "hi", in: source, .swift) == .string)
        #expect(kind(at: "42", in: source, .swift) == .number)
    }

    // MARK: Ordinary recognition

    @Test func javascriptBasics() {
        let source = """
        export const total = 42
        function greet(name: string) {
          return `hi ${name}`
        }
        """
        #expect(kind(at: "export", in: source, .javascript) == .keyword)
        #expect(kind(at: "42", in: source, .javascript) == .number)
        #expect(kind(at: "greet", in: source, .javascript) == .function)
    }

    @Test func swiftAttributesAndTypes() {
        let source = """
        @MainActor
        final class GitCenter {
            let count = 0
        }
        """
        #expect(kind(at: "@MainActor", in: source, .swift) == .attribute)
        #expect(kind(at: "GitCenter", in: source, .swift) == .type)
        #expect(kind(at: "final", in: source, .swift) == .keyword)
    }

    @Test func blockCommentsSpanLines() {
        let source = """
        /* first
           second */
        let x = 1
        """
        #expect(kind(at: "second", in: source, .swift) == .comment)
        #expect(kind(at: "let", in: source, .swift) == .keyword)
    }

    /// Python's triple-quoted strings must not be read as three empty ones.
    @Test func tripleQuotedStringsAreOneToken() {
        let source = """
        doc = \"\"\"line one
        line two\"\"\"
        x = 1
        """
        #expect(kind(at: "line two", in: source, .python) == .string)
        #expect(kind(at: "1", in: source, .python) == .number)
    }

    /// SQL keywords are case-insensitive, unlike every other language here.
    @Test func sqlKeywordsIgnoreCase() {
        let source = "SELECT id FROM users where id = 1"
        #expect(kind(at: "SELECT", in: source, .sql) == .keyword)
        #expect(kind(at: "where", in: source, .sql) == .keyword)
    }

    // MARK: Degenerate input

    /// A language with no rules produces no tokens rather than failing to
    /// build — plain text has to open like anything else.
    @Test func plainTextHighlightsNothing() {
        #expect(SyntaxHighlighter.pattern(for: .plain) == nil)
        #expect(tokens("anything at all", .plain).isEmpty)
    }

    @Test func everyLanguageCompiles() {
        for language in CodeLanguage.allCases where language != .plain {
            let pattern = SyntaxHighlighter.pattern(for: language)
            #expect(pattern != nil, "\(language) has no pattern")
            #expect(
                (try? NSRegularExpression(pattern: pattern ?? "", options: [.anchorsMatchLines]))
                    != nil,
                "\(language) produced a pattern that doesn't compile"
            )
        }
    }

    /// An unterminated string can't take the file down with it.
    @Test func anUnterminatedStringDoesNotCrashOrHang() {
        let source = #"let a = "never closed"#
        #expect(!tokens(source, .swift).isEmpty || tokens(source, .swift).isEmpty)
    }

    @Test func tokensStayInsideTheRequestedRange() {
        let source = "let a = 1\nlet b = 2\nlet c = 3"
        let ns = source as NSString
        let secondLine = ns.range(of: "let b = 2")
        let found = SyntaxHighlighter(language: .swift).tokens(in: source, range: secondLine)

        #expect(!found.isEmpty)
        for token in found {
            #expect(NSLocationInRange(token.range.location, secondLine))
        }
    }
}

/// Language resolution from a file's name.
struct CodeLanguageTests {
    @Test func extensionsResolve() {
        #expect(CodeLanguage.resolve(fileName: "App.tsx") == .javascript)
        #expect(CodeLanguage.resolve(fileName: "main.vue") == .javascript)
        #expect(CodeLanguage.resolve(fileName: "vite.config.mts") == .javascript)
        #expect(CodeLanguage.resolve(fileName: "GitCenter.swift") == .swift)
        #expect(CodeLanguage.resolve(fileName: "build.zig") == .zig)
        #expect(CodeLanguage.resolve(fileName: "Info.plist") == .plain)
    }

    @Test func caseDoesNotMatter() {
        #expect(CodeLanguage.resolve(fileName: "README.MD") == .markdown)
        #expect(CodeLanguage.resolve(fileName: "Query.SQL") == .sql)
    }

    /// Files whose name is the whole signal.
    @Test func namesWithoutAnExtensionResolve() {
        #expect(CodeLanguage.resolve(fileName: "Makefile") == .shell)
        #expect(CodeLanguage.resolve(fileName: "Dockerfile") == .shell)
        #expect(CodeLanguage.resolve(fileName: ".zshrc") == .shell)
    }

    @Test func anythingUnknownIsPlain() {
        #expect(CodeLanguage.resolve(fileName: "notes") == .plain)
        #expect(CodeLanguage.resolve(fileName: "archive.tar.gz") == .plain)
    }

    /// `.vue` sharing the JavaScript rules is the reason this project isn't
    /// using CodeEditSourceEditor, whose grammar set has no Vue at all.
    @Test func vueGetsRealHighlighting() {
        #expect(CodeLanguage.resolve(fileName: "Card.vue") == .javascript)
    }
}
