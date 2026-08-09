import AppKit

/// The line-number gutter.
///
/// Drawn as one view rather than a label per line, which is the only shape
/// that survives a large file: a hundred thousand subviews is a hundred
/// thousand things for AppKit to lay out, and the reader can see forty of
/// them.
///
/// It draws from the layout manager's own fragments, so a wrapped line
/// gets exactly one number no matter how many screen rows it occupies —
/// which is what makes the numbers line up with the text instead of
/// drifting apart the moment wrapping is switched on.
final class CodeLineNumberView: NSRulerView {
    var theme: CodeTheme {
        didSet { needsDisplay = true }
    }

    var font: NSFont {
        didSet {
            invalidateWidth()
            needsDisplay = true
        }
    }

    private weak var textView: NSTextView?

    init(textView: NSTextView, theme: CodeTheme, font: NSFont) {
        self.theme = theme
        self.font = font
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)

        clientView = textView
        ruleThickness = 40
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Sized from the digit count so the gutter grows once when a file
    /// passes a thousand lines, instead of clipping.
    private func invalidateWidth() {
        guard let textView, let storage = textView.textStorage else { return }
        let lines = max(1, storage.string.reduce(into: 1) { count, char in
            if char == "\n" { count += 1 }
        })
        let digits = String(lines).count
        let sample = String(repeating: "8", count: max(3, digits)) as NSString
        let width = sample.size(withAttributes: [.font: font]).width
        ruleThickness = ceil(width) + 16
    }

    func reloadLineNumbers() {
        invalidateWidth()
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager
        else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.lineNumber,
        ]

        let inset = textView.textContainerInset.height
        let visible = textView.visibleRect

        var lineNumber = 1
        let text = textView.string as NSString

        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame

            guard frame.maxY >= visible.minY else {
                lineNumber += Self.newlines(
                    in: text,
                    range: Self.characterRange(of: fragment, in: contentManager)
                )
                return true
            }
            guard frame.minY <= visible.maxY else { return false }

            let label = String(lineNumber) as NSString
            let size = label.size(withAttributes: attributes)
            let y = frame.minY + inset - visible.minY + (frame.height - size.height) / 2

            label.draw(
                at: NSPoint(x: ruleThickness - size.width - 8, y: y),
                withAttributes: attributes
            )

            lineNumber += Self.newlines(
                in: text,
                range: Self.characterRange(of: fragment, in: contentManager)
            )
            return true
        }
    }

    private static func characterRange(
        of fragment: NSTextLayoutFragment,
        in contentManager: NSTextContentManager
    ) -> NSRange {
        let range = fragment.rangeInElement
        let location = contentManager.offset(
            from: contentManager.documentRange.location,
            to: range.location
        )
        let length = contentManager.offset(from: range.location, to: range.endLocation)
        return NSRange(location: location, length: length)
    }

    /// How many lines a fragment covers. A wrapped line is one fragment
    /// with no newline in it, so this returns zero and the number doesn't
    /// advance — which is the whole point.
    private static func newlines(in text: NSString, range: NSRange) -> Int {
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        guard safe.length > 0 else { return 0 }

        var count = 0
        text.enumerateSubstrings(in: safe, options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return max(count, 0)
    }
}
