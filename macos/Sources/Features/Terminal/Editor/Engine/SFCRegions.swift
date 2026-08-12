import Foundation

/// Splits a single-file component into the languages it is actually made of.
///
/// A `.vue` file is not one language. Lexing the whole thing as JavaScript —
/// which is what happens when the extension maps straight to it — colours
/// `class` in the template as a JavaScript keyword, leaves every HTML tag
/// plain, and does nothing at all with the stylesheet. Three regions, three
/// rule sets.
///
/// **The boundary rule: an SFC's blocks start at column zero.** That is how
/// the splitter tells the file's own `<template>` from a `<template #slot>`
/// nested inside it — the nested one is indented, always, because it is
/// inside something. It is a convention rather than a parse, so the failure
/// mode is worth stating: a nested block written flush to the left margin
/// would end the outer one early. Every formatter in this ecosystem indents
/// it, and the alternative is carrying a real HTML parser to colour text.
enum SFCRegions {
    struct Region: Equatable {
        let range: NSRange
        let language: CodeLanguage
    }

    /// The block names an SFC can have, and what is inside them.
    ///
    /// `<script>` covers `<script setup>` and `<script lang="ts">` alike:
    /// the attributes change what the compiler does, not how the body is
    /// lexed. `<style>` covers `lang="scss"` for the same reason — the CSS
    /// rules already understand nesting and `//` comments.
    private static let blocks: [(name: String, language: CodeLanguage)] = [
        ("template", .html),
        ("script", .javascript),
        ("style", .css),
    ]

    /// Finds each top-level block, in the order they appear.
    ///
    /// Text between or around blocks is left out rather than guessed at: it
    /// is whitespace in every real file, and claiming it for a language
    /// would mean colouring something on the strength of where it sits.
    static func regions(in text: String) -> [Region] {
        let ns = text as NSString
        var found: [Region] = []

        for block in blocks {
            guard let pattern = try? NSRegularExpression(
                // Anchored to the start of a line, and the opening tag may
                // carry attributes — `setup`, `lang`, `scoped`, `module`.
                pattern: "^<\(block.name)(?:\\s[^>]*)?>([\\s\\S]*?)^</\(block.name)>",
                options: [.anchorsMatchLines]
            ) else { continue }

            pattern.enumerateMatches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: ns.length)
            ) { match, _, _ in
                guard let match else { return }
                // Group 1 is the body: the tags themselves belong to the
                // markup around them, not to the language inside.
                let body = match.range(at: 1)
                guard body.location != NSNotFound, body.length > 0 else { return }
                found.append(Region(range: body, language: block.language))
            }
        }

        return found.sorted { $0.range.location < $1.range.location }
    }

    /// Which language a given offset falls in, or nil for the markup that
    /// holds the blocks together.
    static func language(at offset: Int, in text: String) -> CodeLanguage? {
        regions(in: text)
            .first { NSLocationInRange(offset, $0.range) }?
            .language
    }
}
