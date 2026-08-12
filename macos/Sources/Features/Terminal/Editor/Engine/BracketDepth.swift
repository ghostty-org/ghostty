import Foundation

/// Brackets, paired by how deeply they are nested.
///
/// A separate pass, and it has to be: nesting depth is *counted*, and a
/// single regex cannot count. The highlighter compiles one expression with a
/// named group per token kind — which is what makes precedence work — and
/// there is no way to express "this brace is three deep" in it. So this walks
/// the text once instead.
///
/// It is given the tokens the highlighter already produced, to **skip
/// brackets inside strings and comments**. Without that, `const a = "{"`
/// opens a level that never closes and every colour after it in the file is
/// wrong — which is worse than no colours at all, because it looks
/// deliberate.
enum BracketDepth {
    struct Span: Equatable {
        let range: NSRange

        /// Zero-based nesting level. Both halves of a pair carry the depth
        /// of the pair itself, so `{` and its `}` match in colour.
        let depth: Int
    }

    private static let openers: Set<Character> = ["{", "[", "("]
    private static let closers: [Character: Character] = ["}": "{", "]": "[", ")": "("]

    /// How many colours the cycle has before it repeats.
    ///
    /// Three, like every editor that does this. More would mean colours too
    /// close to tell apart; fewer and a pair would share with its own child.
    static let colorCount = 3

    /// The colour slot for a depth.
    static func slot(for depth: Int) -> Int {
        guard depth >= 0 else { return 0 }
        return depth % colorCount
    }

    /// Finds the brackets in `range`, each with the depth of its pair.
    ///
    /// Depth is counted from the **start of the document**, not from the
    /// start of the range: a viewport in the middle of a file has to agree
    /// with the one above it, or scrolling would recolour everything.
    static func spans(
        in text: NSString,
        range: NSRange,
        skipping skipped: [NSRange]
    ) -> [Span] {
        let sorted = skipped.sorted { $0.location < $1.location }
        var skipIndex = 0
        var depth = 0
        var spans: [Span] = []

        // Unmatched closers are the normal state of a file being typed, so
        // they must not throw the count negative and poison the rest.
        var index = 0
        let limit = min(NSMaxRange(range), text.length)

        while index < limit {
            // Advance past any string or comment covering this offset.
            while skipIndex < sorted.count, NSMaxRange(sorted[skipIndex]) <= index {
                skipIndex += 1
            }
            if skipIndex < sorted.count, NSLocationInRange(index, sorted[skipIndex]) {
                index = NSMaxRange(sorted[skipIndex])
                continue
            }

            let character = Character(UnicodeScalar(text.character(at: index)) ?? " ")

            if openers.contains(character) {
                if index >= range.location {
                    spans.append(Span(range: NSRange(location: index, length: 1), depth: depth))
                }
                depth += 1
            } else if closers[character] != nil {
                depth = max(0, depth - 1)
                if index >= range.location {
                    spans.append(Span(range: NSRange(location: index, length: 1), depth: depth))
                }
            }

            index += 1
        }

        return spans
    }
}
