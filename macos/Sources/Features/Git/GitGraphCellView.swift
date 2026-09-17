import AppKit

final class GitGraphCellView: NSView {
    static let nodeDiameter: CGFloat = 7
    static let lineWidth: CGFloat = 1.6

    private static let palette: [NSColor] = [
        .systemBlue,
        .systemGreen,
        .systemOrange,
        .systemPurple,
        .systemPink,
        .systemTeal,
        .systemRed,
        .systemIndigo,
    ]

    private var row: GitGraphRow?
    private(set) var isHead = false
    enum Section { case commit, expandedCommit, continuation, expansionEnd }
    private(set) var section = Section.commit
    private var column: GitGraphColumnLayout?

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: column?.width ?? 10, height: NSView.noIntrinsicMetric)
    }

    func configure(row: GitGraphRow, isHead: Bool = false, layout: GitGraphColumnLayout? = nil, section: Section = .commit) {
        self.row = row
        self.isHead = isHead
        self.section = section
        column = layout ?? GitGraphColumnLayout(row: row)
        invalidateIntrinsicContentSize()
        needsDisplay = true
        toolTip = isHead ? GitL10n.format("Current HEAD · {0}", String(describing: row.commitID.shortSHA)) : row.commitID.shortSHA
        setAccessibilityLabel(toolTip)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let row else { return }

        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)

        if section == .commit {
            for segment in row.segments { draw(segment) }
            drawNode(row)
            return
        }
        // Keep the current lane and all passing lanes vertical through the
        // expanded block. Forks and lane compaction happen only at its end.
        let ending = section == .expansionEnd
        let bendY = ending ? max(0, bounds.height - 10) : bounds.height
        for segment in row.segments where segment.kind == .passthrough {
            let top = point(for: segment.from)
            let middleX = column?.middleX(lane: segment.from.lane, row: row) ?? top.x
            var points = [top]
            if section == .expandedCommit { points.append(NSPoint(x: middleX, y: min(GitHistoryRowMetrics.contentAxisY, bounds.midY))) }
            points.append(NSPoint(x: middleX, y: bendY))
            if ending { points.append(point(for: segment.to)) }
            stroke(points, colorIndex: segment.colorIndex, dashed: segment.isRemoteOnly)
        }
        let start = point(for: section == .expandedCommit ? .node(lane: row.nodeLane) : .top(lane: row.nodeLane))
        let bend = NSPoint(x: start.x, y: bendY)
        stroke([start, bend], colorIndex: row.nodeColorIndex, dashed: row.isRemoteOnly)
        if ending {
            for segment in row.segments where segment.kind == .parent {
                stroke([bend, point(for: segment.to)], colorIndex: segment.colorIndex, dashed: segment.isRemoteOnly)
            }
        }
        if section == .expandedCommit {
            for segment in row.segments where segment.kind == .incoming { draw(segment) }
            drawNode(row)
        }
    }

    private func stroke(_ points: [NSPoint], colorIndex: Int, dashed: Bool = false) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = Self.lineWidth
        if dashed { path.setLineDash([3.5, 2.5], count: 2, phase: 0) }
        path.move(to: first)
        var previous = first
        for point in points.dropFirst() {
            if point.x == previous.x {
                path.line(to: point)
            } else {
                let middleY = (previous.y + point.y) / 2
                path.curve(to: point, controlPoint1: NSPoint(x: previous.x, y: middleY),
                           controlPoint2: NSPoint(x: point.x, y: middleY))
            }
            previous = point
        }
        color(for: colorIndex).setStroke()
        path.stroke()
    }

    private func draw(_ segment: GitGraphSegment) {
        guard let row, let column else { return }
        let start = point(for: segment.from)
        let end = point(for: segment.to)
        var points = [start]
        switch segment.kind {
        case .incoming:
            points.append(NSPoint(x: start.x, y: max(start.y, end.y - 12)))
        case .parent:
            // Complete the lane change near the node, then continue vertically.
            points.append(NSPoint(x: end.x, y: min(end.y, start.y + 16)))
        case .passthrough:
            let x = column.middleX(lane: segment.from.lane, row: row)
            points.append(NSPoint(x: x, y: min(GitHistoryRowMetrics.contentAxisY, bounds.midY)))
            points.append(NSPoint(x: x, y: max(bounds.midY, bounds.height - 12)))
        }
        points.append(end)
        stroke(points, colorIndex: segment.colorIndex, dashed: segment.isRemoteOnly)
    }

    private func drawNode(_ row: GitGraphRow) {
        let center = point(for: .node(lane: row.nodeLane))
        let diameter = Self.nodeDiameter
        let radius = diameter / 2
        let rect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: diameter,
            height: diameter
        )

        if row.isRemoteOnly {
            // Unpulled (remote-only) commits stay hollow to match the dashed lane.
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            color(for: row.nodeColorIndex).setStroke()
            let ring = NSBezierPath(ovalIn: rect)
            ring.lineWidth = Self.lineWidth
            ring.stroke()
        } else {
            color(for: row.nodeColorIndex).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }

        NSColor.controlBackgroundColor.withAlphaComponent(0.85).setStroke()
        let outline = NSBezierPath(ovalIn: rect.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        outline.stroke()
        if isHead {
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
        }
    }

    private func point(for graphPoint: GitGraphPoint) -> NSPoint {
        guard let row, let column else { return .zero }
        let x: CGFloat
        switch graphPoint {
        case .node(let lane): x = column.middleX(lane: lane, row: row)
        case .top(let lane):
            x = section == .continuation || section == .expansionEnd
                ? column.middleX(lane: lane, row: row)
                : column.edgeX(lane: lane, count: row.topLanes.count)
        case .bottom(let lane):
            x = section == .expandedCommit || section == .continuation
                ? column.middleX(lane: lane, row: row)
                : column.edgeX(lane: lane, count: row.bottomLanes.count)
        }
        let y: CGFloat
        switch graphPoint {
        case .top:
            y = bounds.minY
        case .node:
            y = min(GitHistoryRowMetrics.contentAxisY, bounds.midY)
        case .bottom:
            y = bounds.maxY
        }
        return NSPoint(x: x, y: y)
    }

    private func color(for index: Int) -> NSColor {
        Self.palette[abs(index) % Self.palette.count]
    }
}
