import CoreGraphics

/// Pure layout math for the adaptive (Google-Meet-style) split layout.
///
/// The focused leaf always gets `activeFraction` (default 2/3) of *each
/// axis it shares siblings on* — not a fraction that compounds with tree
/// depth. Concretely: walk the path from the root to the focused leaf, and
/// group consecutive same-direction steps into "runs" (a run is what a
/// user would think of as one row or one column, even if it was built as
/// several nested splits). Within a run, the focused leaf's side always
/// gets `activeFraction` of that run's axis-length; *every* branch that
/// splits off anywhere along that run evenly shares the remaining
/// `1 - activeFraction`, regardless of how deep in the run it branched
/// off. A direction change starts a new run (its own independent
/// 2/3-vs-evenly-shared-1/3 split). Subtrees that aren't on the path to
/// focus at all keep rendering with their own stored ratios, untouched —
/// this is what preserves spatial relationships (a pane that was
/// top-right of the tree stays in the top-right region as it shrinks).
/// (See ADAPTIVE_LAYOUT_PLAN.md for the hand-drawn UX reference this
/// models, and the worked examples that pinned down the run semantics.)
///
/// Deliberately free of SwiftUI/AppKit/SplitTree types so it can be unit
/// tested directly — `TreeNode` mirrors `SplitTree.Node`'s shape (and the
/// left/right-for-vertical convention that `SplitView.swift` actually
/// renders and `SplitTree.Node.spatialSlots` actually navigates by — see
/// `splitRect`) without requiring an `NSView`-backed leaf type.
enum AdaptiveLayout {
    enum Direction {
        case horizontal
        case vertical
    }

    /// Mirrors `SplitTree.Node` structurally, generic over any `Hashable`
    /// leaf ID instead of requiring an `NSView`-backed view type.
    indirect enum TreeNode<ID: Hashable> {
        case leaf(ID)
        case split(direction: Direction, ratio: Double, left: TreeNode<ID>, right: TreeNode<ID>)
    }

    enum Tier: Equatable {
        /// The focused pane — rendered full size, full legibility.
        case active
        /// A condensed pane still large enough to render live and scaled.
        case scaled
        /// Too small to be worth rendering live; shows a title-only pill.
        case pill
    }

    struct Slot<ID: Hashable>: Equatable {
        let id: ID
        let rect: CGRect
        let tier: Tier
    }

    struct Params: Equatable {
        /// Fraction of a run's axis-length the focused side gets. Every
        /// other branch off that run evenly shares the remainder.
        var activeFraction: Double = 2.0 / 3.0
        var condenseThreshold: CGFloat = 80

        static let `default` = Params()
    }

    /// One step on the path from the root to the focused leaf.
    private struct PathStep<ID: Hashable> {
        let direction: Direction
        /// True if the split's left side continues toward focus (so the
        /// right side is the branch that split off here).
        let focusGoesLeft: Bool
        /// The subtree that branched off at this step (not on the path).
        let offPathSubtree: TreeNode<ID>
    }

    /// Computes slots for every leaf in `tree`. Returns an empty array for
    /// a single-leaf tree (nil `tree`, or `.leaf`) — with nothing to
    /// split, adaptive layout has nothing meaningful to do; the caller
    /// should fall back to rendering the leaf directly.
    static func layout<ID: Hashable>(
        tree: TreeNode<ID>?,
        activeID: ID?,
        bounds: CGSize,
        params: Params = .default
    ) -> [Slot<ID>] {
        guard let tree, case .split = tree, bounds.width > 0, bounds.height > 0 else { return [] }

        let resolvedActiveID = (activeID.flatMap { pathSteps(to: $0, in: tree) != nil ? $0 : nil })
            ?? leftmostLeafID(tree)
        guard let steps = pathSteps(to: resolvedActiveID, in: tree), !steps.isEmpty else { return [] }

        var slots: [Slot<ID>] = []
        var rect = CGRect(origin: .zero, size: bounds)

        for run in groupIntoRuns(steps) {
            let direction = run[0].direction

            // Branches that split off toward the "left" (west/top) side of
            // the run vs the "right" (east/bottom) side. Shallower steps
            // are peeled off the outer edge first, so appending in path
            // order already gives correct left-to-right/top-to-bottom
            // order for the left queue; the right queue needs reversing
            // since its deepest (closest-to-focus) step should render
            // first, right after the continuation.
            var leftQueue: [TreeNode<ID>] = []
            var rightQueue: [TreeNode<ID>] = []
            for step in run {
                if step.focusGoesLeft {
                    rightQueue.append(step.offPathSubtree)
                } else {
                    leftQueue.append(step.offPathSubtree)
                }
            }
            rightQueue.reverse()

            let totalOff = leftQueue.count + rightQueue.count
            let axisLength = direction == .horizontal ? rect.width : rect.height
            let offShare = (1 - params.activeFraction) / Double(totalOff) * axisLength
            let continuationShare = params.activeFraction * axisLength

            var cursor = direction == .horizontal ? rect.minX : rect.minY
            for subtree in leftQueue {
                let slotRect = makeRect(rect, direction: direction, start: cursor, length: offShare)
                slots += renderNatural(subtree, in: slotRect, params: params)
                cursor += offShare
            }
            let continuationRect = makeRect(rect, direction: direction, start: cursor, length: continuationShare)
            cursor += continuationShare
            for subtree in rightQueue {
                let slotRect = makeRect(rect, direction: direction, start: cursor, length: offShare)
                slots += renderNatural(subtree, in: slotRect, params: params)
                cursor += offShare
            }

            rect = continuationRect
        }

        slots.append(Slot(id: resolvedActiveID, rect: rect, tier: .active))
        return slots
    }

    /// Renders a subtree that's off the path to focus using its own
    /// stored ratios — untouched by the adaptive bias, which is what
    /// preserves the user's manual proportions and spatial layout for
    /// everything not directly competing with focus for space.
    private static func renderNatural<ID: Hashable>(
        _ node: TreeNode<ID>,
        in rect: CGRect,
        params: Params
    ) -> [Slot<ID>] {
        switch node {
        case .leaf(let id):
            return [Slot(id: id, rect: rect, tier: tier(for: rect, threshold: params.condenseThreshold))]

        case .split(let direction, let ratio, let left, let right):
            let (leftRect, rightRect) = splitRect(rect, direction: direction, ratio: ratio)
            return renderNatural(left, in: leftRect, params: params)
                + renderNatural(right, in: rightRect, params: params)
        }
    }

    private static func tier(for rect: CGRect, threshold: CGFloat) -> Tier {
        min(rect.width, rect.height) < threshold ? .pill : .scaled
    }

    private static func makeRect(_ container: CGRect, direction: Direction, start: CGFloat, length: CGFloat) -> CGRect {
        switch direction {
        case .horizontal:
            return CGRect(x: start, y: container.minY, width: length, height: container.height)
        case .vertical:
            return CGRect(x: container.minX, y: start, width: container.width, height: length)
        }
    }

    /// Splits `rect` into (left, right) sub-rects using a *stored* ratio
    /// (not the adaptive bias). Matches `SplitView.swift`'s actual
    /// rendering convention — "for vertical splits, left is top and right
    /// is bottom" — and `SplitTree.Node`'s `spatialSlots` (what keyboard
    /// split-navigation actually uses), not the unused `calculateViewBounds`
    /// (which uses an inverted, Y-up-only convention with no real callers
    /// — don't copy that one).
    private static func splitRect(_ rect: CGRect, direction: Direction, ratio: Double) -> (left: CGRect, right: CGRect) {
        switch direction {
        case .horizontal:
            let splitX = rect.minX + rect.width * ratio
            let left = CGRect(x: rect.minX, y: rect.minY, width: rect.width * ratio, height: rect.height)
            let right = CGRect(x: splitX, y: rect.minY, width: rect.width * (1 - ratio), height: rect.height)
            return (left, right)

        case .vertical:
            let splitY = rect.minY + rect.height * ratio
            let left = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * ratio)
            let right = CGRect(x: rect.minX, y: splitY, width: rect.width, height: rect.height * (1 - ratio))
            return (left, right)
        }
    }

    /// Path from the root to the leaf with the given id, as a list of
    /// steps (direction, which side focus continues on, and the subtree
    /// that branched off at each step). `nil` if not found.
    private static func pathSteps<ID: Hashable>(to id: ID, in node: TreeNode<ID>) -> [PathStep<ID>]? {
        switch node {
        case .leaf(let leafID):
            return leafID == id ? [] : nil

        case .split(let direction, _, let left, let right):
            if let rest = pathSteps(to: id, in: left) {
                return [PathStep(direction: direction, focusGoesLeft: true, offPathSubtree: right)] + rest
            }
            if let rest = pathSteps(to: id, in: right) {
                return [PathStep(direction: direction, focusGoesLeft: false, offPathSubtree: left)] + rest
            }
            return nil
        }
    }

    /// Groups consecutive same-direction steps into runs — a run is what
    /// a user would think of as one row or one column, even if it was
    /// built as several nested same-direction splits.
    private static func groupIntoRuns<ID: Hashable>(_ steps: [PathStep<ID>]) -> [[PathStep<ID>]] {
        var runs: [[PathStep<ID>]] = []
        for step in steps {
            if let lastDirection = runs.last?.first?.direction, lastDirection == step.direction {
                runs[runs.count - 1].append(step)
            } else {
                runs.append([step])
            }
        }
        return runs
    }

    private static func leftmostLeafID<ID: Hashable>(_ node: TreeNode<ID>) -> ID {
        switch node {
        case .leaf(let id): return id
        case .split(_, _, let left, _): return leftmostLeafID(left)
        }
    }
}
