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

    /// Top-left origin, like the text view it sits beside.
    ///
    /// `NSView` is bottom-left by default while `NSTextView` is flipped, so
    /// without this the two disagree about which way `y` grows — and the
    /// line numbers came out counting *down* the file, ending at 1 on the
    /// last visible row.
    override var isFlipped: Bool { true }

    private var rows: [Row] = []
    private var visibleLines: ClosedRange<Int>?

    /// Height of one line in the map. Two points is the smallest that
    /// still reads as separate lines on a Retina display.
    private static let rowHeight: CGFloat = 2

    /// Characters past this don't widen a bar any further — one very long
    /// line would otherwise squash every other line to nothing.
    private static let maxColumns = 120

    /// Clicking or dragging scrolls the text there.
    ///
    /// Reported as a fraction of the document rather than a line number, and
    /// deliberately *not* as a selection: a minimap moves the viewport, and
    /// nothing else. Moving the insertion point as well meant scrubbing the
    /// map silently relocated the cursor, so the next thing typed landed
    /// wherever the reader had last been looking.
    var onScrollToFraction: ((CGFloat) -> Void)?

    private weak var scrollView: NSScrollView?

    init(theme: CodeTheme, scrollView: NSScrollView) {
        self.theme = theme
        self.scrollView = scrollView
        super.init(frame: .zero)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Recomputes which lines the viewport covers.
    ///
    /// Taken as a *fraction* of the document rather than by asking the
    /// layout manager which fragments are on screen. The map lays its rows
    /// out linearly, so a proportional reading is the one that agrees with
    /// what is drawn — a fragment-accurate answer would put the box
    /// somewhere the bars say is a different line.
    @objc private func scrolled() {
        guard let scrollView, !rows.isEmpty else { return }
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        guard documentHeight > 0 else { return }

        let visible = scrollView.contentView.bounds
        let total = CGFloat(rows.count)
        let first = Int((visible.minY / documentHeight) * total) + 1
        let count = max(1, Int((visible.height / documentHeight) * total))

        let lower = max(1, min(first, rows.count))
        let upper = max(lower, min(lower + count - 1, rows.count))
        setVisibleLines(lower...upper)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func setRows(_ rows: [Row]) {
        guard rows != self.rows else { return }
        self.rows = rows
        // Recomputed here as well as on scroll: opening a file produces no
        // scroll event, so the box would only appear once the reader moved
        // — which is exactly when they no longer need telling where they
        // are.
        scrolled()
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
        let rowHeight = Self.rowHeight
        let bucket = Self.bucketSize(for: rows.count, into: maxDrawableRows)
        let drawn = Self.compress(rows, into: maxDrawableRows)

        if let visibleLines {
            let top = CGFloat((visibleLines.lowerBound - 1) / bucket) * rowHeight
            let height = max(CGFloat(visibleLines.count) / CGFloat(bucket) * rowHeight, 8)
            let box = NSRect(x: 0, y: top, width: bounds.width, height: height)

            // Strong enough to find at a glance, light enough that the
            // bars underneath still read — it marks where you are, it is
            // not a selection.
            theme.foreground.withAlphaComponent(0.16).setFill()
            box.fill()
            theme.foreground.withAlphaComponent(0.38).setStroke()
            let outline = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }

        for (index, row) in drawn.enumerated() where row.length > 0 {
            let x = CGFloat(min(row.indent, Self.maxColumns)) * scale
            let width = CGFloat(min(row.length, Self.maxColumns)) * scale
            let y = CGFloat(index) * rowHeight

            theme.color(for: row.kind).withAlphaComponent(Self.alpha(for: row.kind)).setFill()
            NSRect(x: x, y: y, width: max(width, 1), height: max(rowHeight - 0.5, 0.5)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        jump(to: event)
    }

    /// Dragging scrubs continuously, which is the interaction people
    /// actually use a minimap for — clicking once is the degenerate case
    /// of it, not the point.
    override func mouseDragged(with event: NSEvent) {
        jump(to: event)
    }

    private func jump(to event: NSEvent) {
        guard !rows.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        onScrollToFraction?(Self.fraction(at: point.y, drawnHeight: drawnHeight))
    }

    /// How far down the document a point on the map is.
    ///
    /// Measured against the height the bars actually occupy, not the view's
    /// — a short file fills only the top of the map, and dividing by the
    /// full height would send a click near its end past the last line.
    static func fraction(at y: CGFloat, drawnHeight: CGFloat) -> CGFloat {
        guard drawnHeight > 0 else { return 0 }
        return min(1, max(0, y / drawnHeight))
    }

    /// The height the bars occupy.
    private var drawnHeight: CGFloat {
        let count = Self.compress(rows, into: maxDrawableRows).count
        return CGFloat(count) * Self.rowHeight
    }

    /// How strongly a row is drawn.
    ///
    /// Plain rows are the paper the map is printed on, not its content, and
    /// they take the foreground colour — so drawing them as boldly as a
    /// keyword turns a dense file into a solid white column. That is not
    /// theoretical: opening a `.swiftinterface`, whose extension maps to no
    /// language and therefore produces no tokens at all, made *every* line
    /// plain and the whole minimap a white block.
    static func alpha(for kind: TokenKind) -> CGFloat {
        kind == .plain ? 0.18 : 0.55
    }

    /// How many bars actually fit, at a height that can be seen.
    private var maxDrawableRows: Int {
        max(1, Int(bounds.height / Self.rowHeight))
    }

    /// How many lines each bar stands for.
    ///
    /// The bug this replaced: a document longer than the map is tall used to
    /// shrink the row height instead, and a fifty-thousand-line file gave
    /// each line 0.02 points — while every bar was still *drawn* half a
    /// point tall, because nothing thinner is visible. Twenty-five
    /// consecutive lines therefore painted on top of one another and the map
    /// saturated into a solid block. Standing one bar for many lines is the
    /// only way to keep the whole file represented and still draw it.
    static func bucketSize(for lines: Int, into maxRows: Int) -> Int {
        guard maxRows > 0, lines > maxRows else { return 1 }
        return Int((Double(lines) / Double(maxRows)).rounded(.up))
    }

    /// Reduces a document's rows to what can be drawn without overlap.
    ///
    /// Each bar takes the widest line in its group and the first kind that
    /// isn't plain — so a run of comments still reads as comments rather
    /// than being averaged away by the blank lines around it.
    static func compress(_ rows: [Row], into maxRows: Int) -> [Row] {
        let bucket = bucketSize(for: rows.count, into: maxRows)
        guard bucket > 1 else { return rows }

        var result: [Row] = []
        result.reserveCapacity((rows.count + bucket - 1) / bucket)

        var index = 0
        while index < rows.count {
            let group = rows[index..<min(index + bucket, rows.count)]
            result.append(Row(
                indent: group.map(\.indent).min() ?? 0,
                length: group.map(\.length).max() ?? 0,
                kind: group.first { $0.kind != .plain }?.kind ?? .plain
            ))
            index += bucket
        }
        return result
    }
}
