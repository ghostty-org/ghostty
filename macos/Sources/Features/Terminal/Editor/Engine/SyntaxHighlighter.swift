import Foundation

/// Turns source text into colored ranges.
///
/// **One regex, not one per kind.** The rules are compiled into a single
/// pattern with a named group per token kind and scanned left to right, so
/// each match consumes its whole range and nothing inside it is looked at
/// again. That is what makes the two cases naive highlighters get wrong
/// come out right:
///
/// - `const url = "http://x"` — the string alternative starts at the quote,
///   which comes first, so it swallows the `//` and no comment appears
/// - `// see "quoted"` — the comment starts first and swallows the quotes,
///   so no unterminated string bleeds into the rest of the file
///
/// Applying separate expressions and letting later ones overwrite earlier
/// ones cannot do this: both would match, and which won would depend on
/// the order they happened to run in.
struct SyntaxHighlighter {
    struct Token: Equatable {
        let range: NSRange
        let kind: TokenKind
    }

    let language: CodeLanguage
    private let regex: NSRegularExpression?

    /// Order is the precedence used when two kinds could start at the same
    /// index. Comment and string lead because they are the ones that must
    /// win — everything else is a detail inside them.
    private static let precedence: [TokenKind] = [
        .comment, .string, .attribute, .number, .keyword, .type, .function,
    ]

    /// Compiled once per language: building an `NSRegularExpression` is far
    /// more expensive than running one, and the viewport highlights on
    /// every scroll.
    private static let cache = Cache()

    init(language: CodeLanguage) {
        self.language = language
        self.regex = Self.cache.regex(for: language)
    }

    /// Tokens inside `range`, which the caller keeps to the visible
    /// viewport — highlighting a whole file on every keystroke is the cost
    /// this design exists to avoid.
    func tokens(in text: String, range: NSRange) -> [Token] {
        // A single-file component has no rules of its own: it is split into
        // its blocks and each is lexed by the language it actually holds.
        // The sub-languages are never `.vue`, so this cannot recurse.
        if language == .vue {
            return SFCRegions.regions(in: text).flatMap { region -> [Token] in
                let clipped = NSIntersectionRange(region.range, range)
                guard clipped.length > 0 else { return [] }
                return SyntaxHighlighter(language: region.language)
                    .tokens(in: text, range: clipped)
            }
        }

        guard let regex else { return [] }

        var tokens: [Token] = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match else { return }
            for kind in Self.precedence {
                let group = match.range(withName: kind.rawValue)
                guard group.location != NSNotFound, group.length > 0 else { continue }
                tokens.append(Token(range: group, kind: kind))
                return
            }
        }
        return tokens
    }

    /// Builds the combined pattern. Exposed for the tests, which assert on
    /// the shape rather than only on results.
    static func pattern(for language: CodeLanguage) -> String? {
        let rules = SyntaxRules.rules(for: language)
        let byKind: [(TokenKind, String?)] = [
            (.comment, rules.comment),
            (.string, rules.string),
            (.attribute, rules.attribute),
            (.number, rules.number),
            (.keyword, rules.keyword),
            (.type, rules.type),
            (.function, rules.function),
        ]

        let groups = byKind.compactMap { kind, pattern -> String? in
            guard let pattern, !pattern.isEmpty else { return nil }
            return "(?<\(kind.rawValue)>\(pattern))"
        }
        return groups.isEmpty ? nil : groups.joined(separator: "|")
    }

    /// `NSRegularExpression` is safe to use from several threads once
    /// built, so instances are shared; only the building is serialized.
    private final class Cache: @unchecked Sendable {
        private var storage: [CodeLanguage: NSRegularExpression] = [:]
        private let lock = NSLock()

        func regex(for language: CodeLanguage) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }

            if let cached = storage[language] { return cached }
            guard let pattern = SyntaxHighlighter.pattern(for: language) else { return nil }
            guard let built = try? NSRegularExpression(
                pattern: pattern,
                options: [.anchorsMatchLines]
            ) else { return nil }

            storage[language] = built
            return built
        }
    }
}
