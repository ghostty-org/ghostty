import Foundation

/// A language the highlighter knows, resolved from a file's name.
///
/// Grouped by how they are *lexed*, not by how they differ as languages:
/// TypeScript, JavaScript and Vue share one entry because at this level —
/// keywords, strings, comments, numbers — they are the same, and splitting
/// them would mean three copies of one rule set to keep in step.
enum CodeLanguage: String, CaseIterable, Equatable, Sendable {
    case javascript
    case swift
    case kotlin
    case rust
    case go
    case python
    case ruby
    case shell
    case json
    case yaml
    case markdown
    case html
    case css
    case sql
    case zig
    case c
    case plain

    /// Extensions are matched longest-first, so `component.spec.ts` can be
    /// told from `.ts` if that ever matters — the same rule the file icon
    /// theme already uses.
    private static let byExtension: [String: CodeLanguage] = [
        "ts": .javascript, "tsx": .javascript, "mts": .javascript, "cts": .javascript,
        "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
        "vue": .javascript, "svelte": .javascript,
        "swift": .swift,
        // A module's public interface, which is what go-to-definition lands
        // in when the symbol lives in a framework rather than in your code.
        // It is Swift, and without this line it arrived as plain text.
        "swiftinterface": .swift,
        "kt": .kotlin, "kts": .kotlin, "java": .kotlin,
        "rs": .rust,
        "go": .go,
        "py": .python, "pyi": .python,
        "rb": .ruby,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell,
        "json": .json, "jsonc": .json,
        "yml": .yaml, "yaml": .yaml,
        "md": .markdown, "markdown": .markdown, "mdx": .markdown,
        "html": .html, "htm": .html, "xml": .html, "svg": .html,
        "css": .css, "scss": .css, "sass": .css, "less": .css,
        "sql": .sql,
        "zig": .zig, "zon": .zig,
        "c": .c, "h": .c, "cpp": .c, "hpp": .c, "cc": .c, "m": .c, "mm": .c,
    ]

    /// Files whose name carries the language, with no extension to read.
    private static let byName: [String: CodeLanguage] = [
        "Makefile": .shell,
        "Dockerfile": .shell,
        ".zshrc": .shell,
        ".bashrc": .shell,
        ".zshenv": .shell,
        ".gitignore": .plain,
        ".env": .shell,
    ]

    static func resolve(fileName: String) -> CodeLanguage {
        if let byName = byName[fileName] { return byName }

        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .plain }
        return byExtension[ext] ?? .plain
    }

    /// The comment syntax, used both by the highlighter and by a
    /// comment-toggling command.
    var lineComment: String? {
        switch self {
        case .javascript, .swift, .kotlin, .rust, .go, .zig, .c, .css: return "//"
        case .python, .ruby, .shell, .yaml: return "#"
        case .sql: return "--"
        case .json, .markdown, .html, .plain: return nil
        }
    }

    var blockComment: (open: String, close: String)? {
        switch self {
        case .javascript, .swift, .kotlin, .rust, .go, .c, .css: return ("/*", "*/")
        case .html: return ("<!--", "-->")
        case .python, .ruby, .shell, .yaml, .sql, .json, .markdown, .zig, .plain: return nil
        }
    }
}
