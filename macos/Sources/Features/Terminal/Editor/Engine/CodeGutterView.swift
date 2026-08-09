import AppKit

/// The line-number column.
///
/// A view **beside** the text, not on top of it. An `NSRulerView` shares
/// the scroll view's area and leaves it to the ruler to stay out of the
/// text's way — which it does not reliably do once the ruler draws its own
/// background, and the numbers ended up printed over the first characters
/// of every line. Two views side by side cannot overlap by construction:
/// the text starts where this ends, and the scroll view clips its own
/// content the way it always did.
///
/// It is drawn as one view rather than a label per line, which is the only
/// shape that survives a large file — a hundred thousand subviews is a
/// hundred thousand things to lay out, and forty of them are visible.
final class CodeGutterView: NSView {
    var theme: CodeTheme {
        didSet { needsDisplay = true }
    }

    var font: NSFont {
        didSet {
            invalidateWidth()
            needsDisplay = true
        }
    }

    /// Top-left origin, like the text view it sits beside.
    ///
    /// `NSView` is bottom-left by default while `NSTextView` is flipped, so
    /// without this the two disagree about which way `y` grows — and the
    /// line numbers came out counting *down* the file, ending at 1 on the
    /// last visible row.
    override var isFlipped: Bool { true }

    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?

    /// The width the numbers need, which grows once when a file passes a
    /// thousand lines instead of clipping.
    private(set) var preferredWidth: CGFloat = 40

    var onWidthChange: ((CGFloat) -> Void)?

    init(textView: NSTextView, scrollView: NSScrollView, theme: CodeTheme, font: NSFont) {
        self.theme = theme
        self.font = font
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)

        // Redrawn as the text scrolls: this view doesn't move with the
        // content, so it has to repaint with the new first visible line.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func scrolled() {
        needsDisplay = true
    }

    func reload() {
        invalidateWidth()
        needsDisplay = true
    }

    private func invalidateWidth() {
        guard let textView else { return }
        let lines = max(1, textView.string.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        })
        let sample = String(repeating: "8", count: max(3, String(lines).count)) as NSString
        let width = ceil(sample.size(withAttributes: [.font: font]).width) + 16

        guard width != preferredWidth else { return }
        preferredWidth = width
        onWidthChange?(width)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let scrollView
        else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.lineNumber,
        ]

        let visible = scrollView.contentView.bounds
        let inset = textView.textContainerInset.height
        let text = textView.string as NSString

        var lineNumber = 1

        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            let lines = Self.lineCount(
                in: text,
                range: Self.characterRange(of: fragment, in: contentManager)
            )

            guard frame.maxY + inset >= visible.minY else {
                lineNumber += lines
                return true
            }
            guard frame.minY + inset <= visible.maxY else { return false }

            let label = String(lineNumber) as NSString
            let size = label.size(withAttributes: attributes)
            let y = frame.minY + inset - visible.minY + (frame.height - size.height) / 2

            label.draw(
                at: NSPoint(x: bounds.width - size.width - 8, y: y),
                withAttributes: attributes
            )

            lineNumber += lines
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
    /// advance — which is what keeps the numbers aligned with the text
    /// rather than counting screen rows.
    private static func lineCount(in text: NSString, range: NSRange) -> Int {
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        guard safe.length > 0 else { return 0 }

        var count = 0
        text.enumerateSubstrings(
            in: safe,
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }
}
