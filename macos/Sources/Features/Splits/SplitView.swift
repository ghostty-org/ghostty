import SwiftUI

/// A split view shows a left and right (or top and bottom) view with a divider in the middle to do resizing.
/// The terminlogy "left" and "right" is always used but for vertical splits "left" is "top" and "right" is "bottom".
///
/// This view is purpose built for our use case and I imagine we'll continue to make it more configurable
/// as time goes on. For example, the splitter divider size and styling is all hardcoded.
struct SplitView<L: View, R: View>: View {
    /// Direction of the split
    let direction: SplitViewDirection

    /// Divider color
    let dividerColor: Color

    /// Minimum increment (in points) that this split can be resized by, in
    /// each direction. Both `height` and `width` should be whole numbers
    /// greater than or equal to 1.0
    let resizeIncrements: NSSize

    /// The left and right views to render.
    let left: L
    let right: R

    /// Called when the divider is double-tapped to equalize splits.
    let onEqualize: () -> Void

    /// The minimum size (in points) of a split
    let minSize: CGFloat = 10

    /// The current fractional width of the split view. 0.5 means L/R are equally sized, for example.
    @Binding var split: CGFloat

    /// The visible size of the splitter, in points. The invisible size is a transparent hitbox that can still
    /// be used for getting a resize handle. The total width/height of the splitter is the sum of both.
    private let splitterVisibleSize: CGFloat
    private let splitterInvisibleSize: CGFloat = 6

    @State private var dragStartRatio: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let layout = SplitViewGeometry(size: geo.size, direction: direction, ratio: split,
                                           gap: splitterVisibleSize, increments: resizeIncrements)
            let leftRect = layout.leading
            let rightRect = layout.trailing
            let splitterPoint = layout.dividerCenter

            ZStack(alignment: .topLeading) {
                left
                    .frame(width: leftRect.size.width, height: leftRect.size.height)
                    .offset(x: leftRect.origin.x, y: leftRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(leftPaneLabel)
                right
                    .frame(width: rightRect.size.width, height: rightRect.size.height)
                    .offset(x: rightRect.origin.x, y: rightRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(rightPaneLabel)
                Divider(direction: direction,
                        visibleSize: splitterVisibleSize,
                        invisibleSize: splitterInvisibleSize,
                        color: dividerColor,
                        split: $split)
                    .position(splitterPoint)
                    .gesture(dragGesture(geo.size))
                    .onTapGesture(count: 2) {
                        onEqualize()
                    }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(splitViewLabel)
        }
    }

    /// Initialize a split view that can be resized by manually dragging the divider.
    init(
        _ direction: SplitViewDirection,
        _ split: Binding<CGFloat>,
        dividerColor: Color,
        dividerSize: CGFloat = 1,
        resizeIncrements: NSSize = .init(width: 1, height: 1),
        @ViewBuilder left: (() -> L),
        @ViewBuilder right: (() -> R),
        onEqualize: @escaping () -> Void
    ) {
        self.direction = direction
        self._split = split
        self.dividerColor = dividerColor
        self.splitterVisibleSize = dividerSize
        self.resizeIncrements = resizeIncrements
        self.left = left()
        self.right = right()
        self.onEqualize = onEqualize
    }

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { gesture in
                let start = dragStartRatio ?? split
                dragStartRatio = start
                let horizontal = direction == .horizontal
                split = SplitViewGeometry.resizedRatio(
                    from: start,
                    translation: horizontal ? gesture.translation.width : gesture.translation.height,
                    extent: horizontal ? size.width : size.height,
                    gap: splitterVisibleSize,
                    minimumPane: minSize)
            }
            .onEnded { _ in dragStartRatio = nil }
    }

    // MARK: Accessibility

    private var splitViewLabel: String {
        switch direction {
        case .horizontal:
            return "Horizontal split view"
        case .vertical:
            return "Vertical split view"
        }
    }

    private var leftPaneLabel: String {
        switch direction {
        case .horizontal:
            return "Left pane"
        case .vertical:
            return "Top pane"
        }
    }

    private var rightPaneLabel: String {
        switch direction {
        case .horizontal:
            return "Right pane"
        case .vertical:
            return "Bottom pane"
        }
    }
}

enum SplitViewDirection: Codable {
    case horizontal, vertical
}

/// Both panes share one layout calculation so rounding cannot create overlaps or uneven gutters.
struct SplitViewGeometry {
    let leading: CGRect
    let trailing: CGRect
    let dividerCenter: CGPoint

    static func resizedRatio(from ratio: CGFloat, translation: CGFloat, extent: CGFloat,
                             gap: CGFloat, minimumPane: CGFloat) -> CGFloat {
        let available = max(0, extent - max(gap, 0))
        guard available > 0 else { return 0.5 }
        let minimum = min(max(minimumPane, 0), available / 2)
        let proposed = available * ratio + translation
        return min(max(proposed, minimum), available - minimum) / available
    }

    init(size: CGSize, direction: SplitViewDirection, ratio: CGFloat, gap: CGFloat, increments: NSSize) {
        let width = max(0, size.width)
        let height = max(0, size.height)
        let horizontal = direction == .horizontal
        let extent = horizontal ? width : height
        let gap = min(max(gap.isFinite ? gap : 0, 0), extent)
        let fraction = ratio.isFinite ? min(max(ratio, 0), 1) : 0.5
        let increment = horizontal ? increments.width : increments.height
        let step = increment.isFinite ? max(increment, 1) : 1
        let available = extent - gap
        let first = floor(available * fraction / step) * step
        let secondStart = first + gap
        if horizontal {
            leading = CGRect(x: 0, y: 0, width: first, height: height)
            trailing = CGRect(x: secondStart, y: 0, width: extent - secondStart, height: height)
            dividerCenter = CGPoint(x: first + gap / 2, y: height / 2)
        } else {
            leading = CGRect(x: 0, y: 0, width: width, height: first)
            trailing = CGRect(x: 0, y: secondStart, width: width, height: extent - secondStart)
            dividerCenter = CGPoint(x: width / 2, y: first + gap / 2)
        }
    }
}
