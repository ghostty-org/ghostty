import AppKit

/// The document at a glance, beside the text.
///
/// Drawn as coloured bars, not as tiny text. A second text view scaled down
/// is what a naive minimap does, and it costs a second full layout of the
/// document — the exact expense this editor is built to avoid. Bars carry
/// the only information anyone reads at that size anyway: how long lines
/// are, where the blank ones fall, and roughly what kind of code it is.
final class CodeMinimapView: NSView {
    /// One line, reduced to what survives at two pixels tall.
    struct Row: Equatable {
        let indent: Int
        let length: Int
        let kind: TokenKind
    }

    var theme: CodeTheme {
        didSet { needsDisplay = true }
    }

    private var rows: [Row] = []
    private var visibleLines: ClosedRange<Int>?

    /// Height of one line in the map. Two points is the smallest that
    /// still reads as separate lines on a Retina display.
    private static let rowHeight: CGFloat = 2

    /// Characters past this don't widen a bar any further — one very long
    /// line would otherwise squash every other line to nothing.
    private static let maxColumns = 120

    /// Clicking jumps the text there.
    var onSelectLine: ((Int) -> Void)?

    init(theme: CodeTheme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func setRows(_ rows: [Row]) {
        guard rows != self.rows else { return }
        self.rows = rows
        needsDisplay = true
    }

    func setVisibleLines(_ range: ClosedRange<Int>?) {
        guard range != visibleLines else { return }
        visibleLines = range
        needsDisplay = true
    }

    /// Reduces a document to one row per line.
    ///
    /// Pure and `static` so the reduction — which is the only part with a
    /// decision in it — can be tested without a view.
    static func rows(for text: String, tokens: [SyntaxHighlighter.Token]) -> [Row] {
        let ns = text as NSString
        var byLocation: [Int: TokenKind] = [:]
        for token in tokens {
            byLocation[token.range.location] = token.kind
        }

        var rows: [Row] = []
        var index = 0
        // Strictly less than the length: `lineRange` at the very end
        // returns an empty range, which would add a phantom line to every
        // document and put the minimap one row out of step with the text.
        while index < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: min(index, ns.length), length: 0))
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            let indent = line.prefix { $0 == " " || $0 == "\t" }.count

            // The first token starting on this line stands in for the whole
            // of it: at two pixels tall a line is one colour, and the thing
            // it should be is whatever it begins as — a comment line reads
            // as a comment, a string continuation as a string.
            let kind = (lineRange.location..<lineRange.location + lineRange.length)
                .compactMap { byLocation[$0] }
                .first ?? .plain

            rows.append(Row(indent: indent, length: trimmed.count, kind: kind))

            let next = lineRange.location + lineRange.length
            if next <= index { break }
            index = next
        }
        return rows
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }

        let scale = min(1, bounds.width / CGFloat(Self.maxColumns))
        let totalHeight = CGFloat(rows.count) * Self.rowHeight
        // Compressed to fit when the file is longer than the map is tall,
        // so the whole document is always represented.
        let rowHeight = totalHeight > bounds.height
            ? bounds.height / CGFloat(rows.count)
            : Self.rowHeight

        if let visibleLines {
            let top = CGFloat(visibleLines.lowerBound - 1) * rowHeight
            let height = CGFloat(visibleLines.count) * rowHeight
            theme.foreground.withAlphaComponent(0.10).setFill()
            NSRect(x: 0, y: top, width: bounds.width, height: height).fill()
        }

        for (index, row) in rows.enumerated() where row.length > 0 {
            let x = CGFloat(min(row.indent, Self.maxColumns)) * scale
            let width = CGFloat(min(row.length, Self.maxColumns)) * scale
            let y = CGFloat(index) * rowHeight

            theme.color(for: row.kind).withAlphaComponent(0.55).setFill()
            NSRect(x: x, y: y, width: max(width, 1), height: max(rowHeight - 0.5, 0.5)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !rows.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)

        let totalHeight = CGFloat(rows.count) * Self.rowHeight
        let rowHeight = totalHeight > bounds.height
            ? bounds.height / CGFloat(rows.count)
            : Self.rowHeight

        let line = Int(point.y / rowHeight) + 1
        onSelectLine?(max(1, min(line, rows.count)))
    }
}
