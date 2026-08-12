import AppKit

/// What to say when the pointer rests on a symbol.
///
/// A plain value, for the same reason as `CodeTheme`: the engine draws this
/// and knows nothing about where it came from. The host fills it from a
/// language server and from whatever diagnostics it is holding, and the
/// engine never learns that either exists.
struct CodeHoverInfo: Equatable {
    /// A problem reported at the hovered position.
    struct Problem: Equatable {
        let message: String

        /// Which tool said it — `swiftc`, `pylint`, `ts`. Worth showing
        /// because the same line can carry a compiler error and a linter's
        /// opinion, and those are not equally binding.
        let source: String?
        let color: NSColor
    }

    var problems: [Problem] = []

    /// The declaration, as the server wrote it inside a fenced code block.
    var signature: String?

    /// The prose that followed the declaration.
    var documentation: String?

    var isEmpty: Bool {
        problems.isEmpty && signature == nil && documentation == nil
    }

    /// Splits a language server's hover payload into declaration and prose.
    ///
    /// Servers answer in markdown and lead with the declaration inside a
    /// fenced code block — `sourcekit-lsp`, `typescript-language-server` and
    /// `pylsp` all do. Keeping the two apart is what lets the declaration be
    /// drawn in the editor's own font and colours while the prose stays
    /// ordinary readable text. Rendered as one blob it is either all code or
    /// all prose, and both are worse than the split.
    ///
    /// A later fenced block — a `@see` example, a second overload — keeps its
    /// content and loses its fences: the text is still worth reading and the
    /// markers are not.
    /// Documentation is also **reflowed**: a doc comment arrives wrapped to
    /// whatever column its author's editor used, and wrapping it again at the
    /// card's width leaves a ragged alternation of short and long lines.
    /// Markdown's own rule is that a single newline is a space and only a
    /// blank line starts a paragraph, so honouring it is both more correct and
    /// what makes the card read as prose. List items and fenced examples keep
    /// their line breaks, because there the break is the meaning.
    static func split(markdown: String) -> (signature: String?, documentation: String?) {
        var signature: [String] = []
        var blocks: [ProseBlock] = []
        var paragraph: [String] = []
        var isInFence = false
        var tookSignature = false

        func endParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(ProseBlock(kind: .paragraph, text: paragraph.joined(separator: " ")))
            paragraph = []
        }

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                isInFence.toggle()
                // The block that just closed was the declaration, so no
                // later one can be.
                if !isInFence, !signature.isEmpty { tookSignature = true }
                endParagraph()
                continue
            }

            if isInFence {
                if tookSignature {
                    blocks.append(ProseBlock(kind: .verbatim, text: line))
                } else {
                    signature.append(line)
                }
                continue
            }

            if trimmed.isEmpty {
                endParagraph()
                continue
            }

            // A horizontal rule is how most servers separate the declaration
            // from its documentation. As text it is a row of dashes, which
            // carries nothing once the two are already apart.
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" }) {
                endParagraph()
                continue
            }

            if Self.isListItem(trimmed) {
                endParagraph()
                blocks.append(ProseBlock(kind: .listItem, text: trimmed))
                continue
            }

            paragraph.append(trimmed)
        }
        endParagraph()

        return (trimmed(signature), assemble(blocks))
    }

    /// A run of prose that has to stay together.
    private struct ProseBlock {
        enum Kind { case paragraph, listItem, verbatim }
        let kind: Kind
        let text: String
    }

    /// Whether a line is a bullet or a numbered item, and so owns its line.
    private static func isListItem(_ line: String) -> Bool {
        if let first = line.first, "-*+•".contains(first) {
            return line.dropFirst().first == " "
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return false }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")" else { return false }
        return rest.dropFirst().first == " "
    }

    /// Joins the blocks back up: a blank line between paragraphs, a single
    /// newline inside a list or a code example.
    private static func assemble(_ blocks: [ProseBlock]) -> String? {
        var result = ""
        var previous: ProseBlock.Kind?

        for block in blocks {
            if !result.isEmpty {
                let tight = previous == block.kind && block.kind != .paragraph
                result += tight ? "\n" : "\n\n"
            }
            result += block.text
            previous = block.kind
        }

        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Drops the blank lines around a block and joins what is left.
    private static func trimmed(_ lines: [String]) -> String? {
        var lines = lines
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
