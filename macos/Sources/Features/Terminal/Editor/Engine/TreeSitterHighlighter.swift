import Foundation
import SwiftTreeSitter

/// Syntax highlighting from a real parse tree.
///
/// The regex highlighter next door is an approximation that gets the
/// common cases right; this gets them right *because it parsed the code*.
/// The difference shows up wherever structure matters — a Vue single-file
/// component is HTML, TypeScript and CSS in one file, and no amount of
/// pattern matching turns that into three languages.
///
/// Captures come from the grammar's own `highlights.scm`, whose names are
/// a loose community convention (`@keyword`, `@string`, `@function.call`).
/// Mapping them onto this project's small `TokenKind` set is deliberate:
/// the palette behind it is a terminal theme with sixteen colors, so
/// finer distinctions would be thrown away one layer later.
struct TreeSitterHighlighter {
    /// A capture name to token kind. Prefix-matched, longest first, so
    /// `function.call` finds `function` without needing an entry of its
    /// own — grammars invent sub-captures freely and an exact table would
    /// silently drop them.
    private static let captureMap: [(prefix: String, kind: TokenKind)] = [
        ("keyword", .keyword),
        ("conditional", .keyword),
        ("repeat", .keyword),
        ("include", .keyword),
        ("operator", .keyword),
        ("string", .string),
        ("character", .string),
        ("comment", .comment),
        ("number", .number),
        ("float", .number),
        ("boolean", .number),
        ("constant", .number),
        ("type", .type),
        ("constructor", .type),
        ("namespace", .type),
        ("function", .function),
        ("method", .function),
        ("attribute", .attribute),
        ("annotation", .attribute),
        ("tag", .attribute),
        ("property", .attribute),
        ("variable", .plain),
        ("punctuation", .punctuation),
    ]

    /// Resolves a grammar capture to a kind, or nil when it is one this
    /// palette has no color for — which is the common case and must be
    /// cheap.
    static func kind(forCapture name: String) -> TokenKind? {
        for entry in captureMap where name == entry.prefix
            || name.hasPrefix(entry.prefix + ".") {
            return entry.kind
        }
        return nil
    }
}
