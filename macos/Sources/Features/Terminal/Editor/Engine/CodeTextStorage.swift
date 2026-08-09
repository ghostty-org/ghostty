import AppKit

/// The document, and the coloring applied to it.
///
/// Highlighting runs over a **range**, never the whole file, and the caller
/// passes the visible one. That is the difference between an editor that
/// stays responsive in a 2MB file and one that recolors a megabyte on every
/// keystroke.
///
/// It also holds the invalidation rule, which is subtler than it looks: an
/// edit can change how text *earlier and later* in the file is colored — type
/// `/*` and everything below it becomes a comment — so a repaint has to
/// cover more than the characters that changed.
final class CodeTextStorage {
    private(set) var language: CodeLanguage
    private var highlighter: SyntaxHighlighter
    var theme: CodeTheme
    var configuration: CodeEditorConfiguration

    init(
        language: CodeLanguage,
        theme: CodeTheme,
        configuration: CodeEditorConfiguration
    ) {
        self.language = language
        self.highlighter = SyntaxHighlighter(language: language)
        self.theme = theme
        self.configuration = configuration
    }

    func setLanguage(_ language: CodeLanguage) {
        guard language != self.language else { return }
        self.language = language
        self.highlighter = SyntaxHighlighter(language: language)
    }

    /// Applies colors to `range` of `storage`.
    ///
    /// Everything in range is reset to the plain foreground first. Without
    /// that, deleting the closing `*/` of a comment would leave the text
    /// grey: the tokens for it simply stop being produced, and attributes
    /// nobody clears are attributes that stay.
    func highlight(_ storage: NSTextStorage, in range: NSRange) {
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard safe.length > 0 else { return }

        storage.beginEditing()
        storage.setAttributes(
            [
                .font: configuration.font,
                .foregroundColor: theme.foreground,
            ],
            range: safe
        )

        let text = storage.string
        for token in highlighter.tokens(in: text, range: safe) {
            let clipped = NSIntersectionRange(token.range, safe)
            guard clipped.length > 0 else { continue }
            storage.addAttribute(
                .foregroundColor,
                value: theme.color(for: token.kind),
                range: clipped
            )
        }
        storage.endEditing()
    }

    /// The range to recolor after an edit.
    ///
    /// Grown to whole lines and then padded by a screenful either side. A
    /// tighter range is wrong for exactly the reasons that make this hard:
    /// typing `/*` recolors everything after it, and typing `*/` recolors
    /// everything before. The padding doesn't make that correct in general —
    /// only a reparse does — but it covers what the reader can actually see,
    /// and the viewport pass fixes the rest as they scroll.
    static func invalidationRange(
        for edited: NSRange,
        in text: NSString,
        padding: Int = 4096
    ) -> NSRange {
        let lines = text.lineRange(for: NSIntersectionRange(
            edited,
            NSRange(location: 0, length: text.length)
        ))
        let start = max(0, lines.location - padding)
        let end = min(text.length, lines.location + lines.length + padding)
        return NSRange(location: start, length: end - start)
    }
}
