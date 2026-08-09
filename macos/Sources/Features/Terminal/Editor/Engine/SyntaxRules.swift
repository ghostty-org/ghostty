import Foundation

/// The patterns for one language, one per token kind.
///
/// A kind gets a single pattern — alternate inside it rather than adding a
/// second entry — because the highlighter compiles these into one regex
/// with a named group per kind, and a name can only appear once.
struct SyntaxRules {
    var comment: String?
    var string: String?
    var number: String?
    var keyword: String?
    var type: String?
    var function: String?
    var attribute: String?

    /// `\b(?:a|b|c)\b` from a word list.
    static func words(_ list: [String]) -> String {
        "\\b(?:" + list.joined(separator: "|") + ")\\b"
    }

    /// A double- or single-quoted run that ends at the closing quote and
    /// **survives escapes**: `"he said \"hi\""` is one string, not two.
    /// `(?:[^"\\]|\\.)*` is what does it — any character that isn't a quote
    /// or a backslash, or a backslash followed by anything at all.
    static let cStyleString =
        #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`"#

    static let cStyleComment = #"//[^\n]*|/\*[\s\S]*?\*/"#

    static let hashComment = #"#[^\n]*"#

    /// Decimals, hex, binary, floats and exponents, with `_` separators.
    static let number =
        #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?)\b"#

    /// Capitalized identifiers. A heuristic, not a type checker — it is
    /// right often enough to help and never wrong in a way that misleads,
    /// and PR 3's semantic tokens replace it with the truth.
    static let capitalizedType = #"\b[A-Z][A-Za-z0-9_]*\b"#

    /// An identifier immediately before `(`.
    static let callBeforeParen = #"\b[a-z_][A-Za-z0-9_]*(?=\s*\()"#

    static func rules(for language: CodeLanguage) -> SyntaxRules {
        switch language {
        case .javascript:
            return SyntaxRules(
                comment: cStyleComment,
                string: cStyleString,
                number: number,
                keyword: words([
                    "abstract", "as", "async", "await", "break", "case", "catch", "class",
                    "const", "continue", "debugger", "declare", "default", "delete", "do",
                    "else", "enum", "export", "extends", "finally", "for", "from", "function",
                    "get", "if", "implements", "import", "in", "instanceof", "interface", "is",
                    "keyof", "let", "namespace", "new", "of", "private", "protected", "public",
                    "readonly", "return", "satisfies", "set", "static", "super", "switch",
                    "this", "throw", "try", "type", "typeof", "var", "void", "while", "yield",
                    "true", "false", "null", "undefined",
                ]),
                type: capitalizedType,
                function: callBeforeParen,
                attribute: #"@[A-Za-z_][A-Za-z0-9_]*"#
            )

        case .swift:
            return SyntaxRules(
                comment: cStyleComment,
                string: #""""[\s\S]*?"""|"(?:[^"\\]|\\.)*""#,
                number: number,
                keyword: words([
                    "actor", "any", "as", "associatedtype", "async", "await", "break", "case",
                    "catch", "class", "consuming", "continue", "convenience", "default",
                    "defer", "deinit", "didSet", "do", "dynamic", "each", "else", "enum",
                    "extension", "fallthrough", "fileprivate", "final", "for", "func", "get",
                    "guard", "if", "import", "in", "indirect", "infix", "init", "inout",
                    "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated",
                    "nonmutating", "open", "operator", "optional", "override", "package",
                    "postfix", "precedencegroup", "prefix", "private", "protocol", "public",
                    "repeat", "required", "rethrows", "return", "self", "Self", "set", "some",
                    "static", "struct", "subscript", "super", "switch", "throw", "throws",
                    "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet",
                    "true", "false",
                ]),
                type: capitalizedType,
                function: callBeforeParen,
                attribute: #"@[A-Za-z_][A-Za-z0-9_]*"#
            )

        case .kotlin:
            return SyntaxRules(
                comment: cStyleComment,
                string: #""""[\s\S]*?"""|"(?:[^"\\]|\\.)*""#,
                number: number,
                keyword: words([
                    "abstract", "as", "break", "by", "catch", "class", "companion", "const",
                    "constructor", "continue", "data", "do", "else", "enum", "external",
                    "final", "finally", "for", "fun", "get", "if", "implements", "import",
                    "in", "infix", "init", "inline", "interface", "internal", "is", "lateinit",
                    "new", "object", "open", "operator", "override", "package", "private",
                    "protected", "public", "return", "sealed", "set", "super", "suspend",
                    "this", "throw", "try", "typealias", "val", "var", "vararg", "when",
                    "where", "while", "true", "false", "null",
                ]),
                type: capitalizedType,
                function: callBeforeParen,
                attribute: #"@[A-Za-z_][A-Za-z0-9_]*"#
            )

        case .rust:
            return SyntaxRules(
                comment: cStyleComment,
                string: cStyleString,
                number: number,
                keyword: words([
                    "as", "async", "await", "break", "const", "continue", "crate", "dyn",
                    "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let",
                    "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
                    "Self", "static", "struct", "super", "trait", "true", "type", "unsafe",
                    "use", "where", "while",
                ]),
                type: capitalizedType,
                function: callBeforeParen,
                attribute: #"#!?\[[^\]]*\]"#
            )

        case .go:
            return SyntaxRules(
                comment: cStyleComment,
                string: cStyleString,
                number: number,
                keyword: words([
                    "break", "case", "chan", "const", "continue", "default", "defer", "else",
                    "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
                    "map", "package", "range", "return", "select", "struct", "switch", "type",
                    "var", "nil", "true", "false",
                ]),
                type: capitalizedType,
                function: callBeforeParen
            )

        case .python:
            return SyntaxRules(
                comment: hashComment,
                string: #""""[\s\S]*?"""|'''[\s\S]*?'''|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#,
                number: number,
                keyword: words([
                    "and", "as", "assert", "async", "await", "break", "class", "continue",
                    "def", "del", "elif", "else", "except", "finally", "for", "from", "global",
                    "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass",
                    "raise", "return", "try", "while", "with", "yield", "True", "False", "None",
                ]),
                type: capitalizedType,
                function: callBeforeParen,
                attribute: #"@[A-Za-z_][A-Za-z0-9_.]*"#
            )

        case .ruby:
            return SyntaxRules(
                comment: hashComment,
                string: cStyleString,
                number: number,
                keyword: words([
                    "alias", "and", "begin", "break", "case", "class", "def", "do", "else",
                    "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next",
                    "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super",
                    "then", "true", "unless", "until", "when", "while", "yield",
                ]),
                type: capitalizedType,
                function: callBeforeParen,
                attribute: #"[@$][A-Za-z_][A-Za-z0-9_]*"#
            )

        case .shell:
            return SyntaxRules(
                comment: hashComment,
                string: cStyleString,
                number: number,
                keyword: words([
                    "if", "then", "else", "elif", "fi", "case", "esac", "for", "while",
                    "until", "do", "done", "function", "return", "export", "local",
                    "readonly", "source", "alias", "unset", "shift", "exit",
                ]),
                function: callBeforeParen,
                attribute: #"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#
            )

        case .json:
            return SyntaxRules(
                string: #""(?:[^"\\]|\\.)*""#,
                number: number,
                keyword: words(["true", "false", "null"])
            )

        case .yaml:
            return SyntaxRules(
                comment: hashComment,
                string: cStyleString,
                number: number,
                keyword: words(["true", "false", "null", "yes", "no", "on", "off"]),
                attribute: #"^\s*[-\w.]+(?=\s*:)"#
            )

        case .markdown:
            return SyntaxRules(
                comment: #"^>.*$"#,
                string: #"`[^`\n]*`|```[\s\S]*?```"#,
                keyword: #"^#{1,6}\s.*$"#,
                type: #"\[[^\]]*\]\([^)]*\)"#,
                attribute: #"\*\*[^*]+\*\*|__[^_]+__"#
            )

        case .html:
            return SyntaxRules(
                comment: #"<!--[\s\S]*?-->"#,
                string: #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#,
                keyword: #"</?[A-Za-z][A-Za-z0-9-]*"#,
                attribute: #"\b[A-Za-z_:@][-A-Za-z0-9_:.]*(?=\s*=)"#
            )

        case .css:
            return SyntaxRules(
                comment: #"/\*[\s\S]*?\*/"#,
                string: cStyleString,
                number: #"\b\d[\d_]*(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg)?\b"#,
                keyword: #"@[A-Za-z-]+"#,
                type: #"\.[A-Za-z_][-A-Za-z0-9_]*|#[A-Za-z_][-A-Za-z0-9_]*"#,
                attribute: #"\b[a-z-]+(?=\s*:)"#
            )

        case .sql:
            return SyntaxRules(
                comment: #"--[^\n]*|/\*[\s\S]*?\*/"#,
                string: #"'(?:[^'\\]|\\.)*'"#,
                number: number,
                keyword: #"(?i)"# + words([
                    "select", "from", "where", "insert", "into", "values", "update", "set",
                    "delete", "create", "table", "alter", "drop", "index", "join", "left",
                    "right", "inner", "outer", "on", "group", "by", "order", "having",
                    "limit", "offset", "as", "and", "or", "not", "null", "distinct", "union",
                    "with", "case", "when", "then", "else", "end",
                ])
            )

        case .zig:
            return SyntaxRules(
                comment: #"//[^\n]*"#,
                string: #""(?:[^"\\]|\\.)*"|\\\\[^\n]*"#,
                number: number,
                keyword: words([
                    "align", "allowzero", "and", "anyframe", "anytype", "asm", "async",
                    "await", "break", "catch", "comptime", "const", "continue", "defer",
                    "else", "enum", "errdefer", "error", "export", "extern", "fn", "for",
                    "if", "inline", "noalias", "nosuspend", "opaque", "or", "orelse",
                    "packed", "pub", "resume", "return", "struct", "suspend", "switch",
                    "test", "threadlocal", "try", "union", "unreachable", "usingnamespace",
                    "var", "volatile", "while", "true", "false", "null", "undefined",
                ]),
                type: capitalizedType,
                function: callBeforeParen
            )

        case .c:
            return SyntaxRules(
                comment: cStyleComment,
                string: #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#,
                number: number,
                keyword: words([
                    "auto", "break", "case", "char", "const", "continue", "default", "do",
                    "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline",
                    "int", "long", "register", "return", "short", "signed", "sizeof", "static",
                    "struct", "switch", "typedef", "union", "unsigned", "void", "volatile",
                    "while", "class", "namespace", "template", "public", "private", "protected",
                    "virtual", "true", "false", "nullptr",
                ]),
                type: capitalizedType,
                function: callBeforeParen,
                attribute: #"^\s*#\s*[a-z]+"#
            )

        case .plain:
            return SyntaxRules()
        }
    }
}
