import CoreGraphics
import Testing
@testable import Ghostty

private func approxEqual(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.001) -> Bool {
    abs(a - b) < tolerance
}

private func approxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.001) -> Bool {
    approxEqual(a.minX, b.minX, tolerance: tolerance) &&
        approxEqual(a.minY, b.minY, tolerance: tolerance) &&
        approxEqual(a.width, b.width, tolerance: tolerance) &&
        approxEqual(a.height, b.height, tolerance: tolerance)
}

struct AdaptiveLayoutEngineTests {
    private typealias Node = AdaptiveLayout.TreeNode<Int>

    // MARK: - No-op cases

    @Test func nilTreeProducesNoSlots() {
        let slots = AdaptiveLayout.layout(tree: Node?.none, activeID: nil, bounds: CGSize(width: 800, height: 600))
        #expect(slots.isEmpty)
    }

    @Test func singleLeafProducesNoSlots() {
        let slots = AdaptiveLayout.layout(tree: Node.leaf(1), activeID: 1, bounds: CGSize(width: 800, height: 600))
        #expect(slots.isEmpty)
    }

    @Test func zeroSizedBoundsProducesNoSlots() {
        let tree: Node = .split(direction: .horizontal, ratio: 0.5, left: .leaf(1), right: .leaf(2))
        let slots = AdaptiveLayout.layout(tree: tree, activeID: 1, bounds: .zero)
        #expect(slots.isEmpty)
    }

    // MARK: - Active pane selection

    @Test func missingActiveIDFallsBackToLeftmostLeaf() {
        let tree: Node = .split(direction: .horizontal, ratio: 0.5, left: .leaf(1), right: .leaf(2))
        let slots = AdaptiveLayout.layout(tree: tree, activeID: 99, bounds: CGSize(width: 900, height: 600))
        let active = slots.first { $0.tier == .active }
        #expect(active?.id == 1)
    }

    @Test func nilActiveIDFallsBackToLeftmostLeaf() {
        let tree: Node = .split(direction: .horizontal, ratio: 0.5, left: .leaf(1), right: .leaf(2))
        let slots = AdaptiveLayout.layout(tree: tree, activeID: nil, bounds: CGSize(width: 900, height: 600))
        let active = slots.first { $0.tier == .active }
        #expect(active?.id == 1)
    }

    // MARK: - Worked examples from the user's hand-drawn reference (IMG_5960)
    //
    // These pin down the "run" semantics: the focused leaf gets a flat
    // 2/3 of each axis it shares siblings on, and *every* branch off that
    // axis evenly shares the remaining 1/3 — regardless of how deep in
    // the tree it split off. This is what distinguishes the algorithm
    // from a naive per-split recursive bias (which would compound
    // fractions with depth instead of staying flat).

    @Test func singleSplitGivesTwoThirdsOneThird() {
        // "it will be 2/3 and 1/3, this is easy."
        let tree: Node = .split(direction: .horizontal, ratio: 0.5, left: .leaf(1), right: .leaf(2))
        let bounds = CGSize(width: 900, height: 600)
        let slots = AdaptiveLayout.layout(tree: tree, activeID: 1, bounds: bounds)

        let active = slots.first { $0.id == 1 }!
        let other = slots.first { $0.id == 2 }!
        #expect(approxEqual(active.rect, CGRect(x: 0, y: 0, width: 600, height: 600)))
        #expect(approxEqual(other.rect, CGRect(x: 600, y: 0, width: 300, height: 600)))
    }

    @Test func threeInARowSameDirectionSplitsTwoThirdsAndTwoSixths() {
        // "did the split again, at the same direction. The focus one gets
        // 2/3, the other two gets 1/6 of the space." Tree:
        // horizontal(focus=1, horizontal(2, 3)) — focus stays at the root,
        // so this is really a single-step run (root split), with the
        // *entire* (2,3) subtree as one off-path branch rendered at its
        // own stored ratio (default 0.5) inside the remaining 1/3.
        let tree: Node = .split(
            direction: .horizontal, ratio: 0.5,
            left: .leaf(1),
            right: .split(direction: .horizontal, ratio: 0.5, left: .leaf(2), right: .leaf(3)))
        let bounds = CGSize(width: 900, height: 600)
        let slots = AdaptiveLayout.layout(tree: tree, activeID: 1, bounds: bounds)

        let s1 = slots.first { $0.id == 1 }!
        let s2 = slots.first { $0.id == 2 }!
        let s3 = slots.first { $0.id == 3 }!
        #expect(s1.tier == .active)
        #expect(approxEqual(s1.rect, CGRect(x: 0, y: 0, width: 600, height: 600)))
        #expect(approxEqual(s2.rect, CGRect(x: 600, y: 0, width: 150, height: 600)))
        #expect(approxEqual(s3.rect, CGRect(x: 750, y: 0, width: 150, height: 600)))
    }

    @Test func focusTwoLevelsDeepInARunStillGetsFlatTwoThirds() {
        // "move focus" to the 1/3 pane, then split again from there.
        // Tree: horizontal(1, horizontal(focus=2, 3)) — focus is now two
        // steps deep (root: go right; inner: go left), but both steps are
        // the *same direction*, forming one run. Expected: 1/6, 2/3(focus),
        // 1/6 — NOT the compounding result a naive per-node recursive bias
        // would give (which would put focus around 4/9 here, not 2/3).
        let tree: Node = .split(
            direction: .horizontal, ratio: 0.5,
            left: .leaf(1),
            right: .split(direction: .horizontal, ratio: 0.5, left: .leaf(2), right: .leaf(3)))
        let bounds = CGSize(width: 900, height: 600)
        let slots = AdaptiveLayout.layout(tree: tree, activeID: 2, bounds: bounds)

        let s1 = slots.first { $0.id == 1 }!
        let s2 = slots.first { $0.id == 2 }!
        let s3 = slots.first { $0.id == 3 }!
        #expect(s2.tier == .active)
        #expect(approxEqual(s1.rect, CGRect(x: 0, y: 0, width: 150, height: 600)))
        #expect(approxEqual(s2.rect, CGRect(x: 150, y: 0, width: 600, height: 600)))
        #expect(approxEqual(s3.rect, CGRect(x: 750, y: 0, width: 150, height: 600)))
    }

    @Test func perpendicularSplitOffFocusStartsANewIndependentRun() {
        // Continuing from the 1/6, 2/3(focus), 1/6 layout, split focus (2)
        // vertically to add a 4th pane below it. This is a *direction
        // change*, so it starts a new run: within focus's own column,
        // focus keeps 2/3 height and the new pane gets 1/3 height —
        // independent of the horizontal run's 1/6/2/3/1/6 split, which is
        // untouched.
        let tree: Node = .split(
            direction: .horizontal, ratio: 0.5,
            left: .leaf(1),
            right: .split(
                direction: .horizontal, ratio: 0.5,
                left: .split(direction: .vertical, ratio: 0.5, left: .leaf(2), right: .leaf(4)),
                right: .leaf(3)))
        let bounds = CGSize(width: 900, height: 600)
        let slots = AdaptiveLayout.layout(tree: tree, activeID: 2, bounds: bounds)

        let s1 = slots.first { $0.id == 1 }!
        let s2 = slots.first { $0.id == 2 }!
        let s3 = slots.first { $0.id == 3 }!
        let s4 = slots.first { $0.id == 4 }!

        // Horizontal run unchanged: 1/6, [2/3 column], 1/6.
        #expect(approxEqual(s1.rect.width, 150))
        #expect(approxEqual(s3.rect.width, 150))
        let column = CGRect(x: 150, y: 0, width: 600, height: 600)
        #expect(approxEqual(s2.rect.minX, column.minX))
        #expect(approxEqual(s2.rect.width, column.width))
        #expect(approxEqual(s4.rect.minX, column.minX))
        #expect(approxEqual(s4.rect.width, column.width))

        // Vertical run within that column: focus (top) = 2/3 height, new pane (bottom) = 1/3.
        #expect(s2.tier == .active)
        #expect(approxEqual(s2.rect.height, 400)) // 600 * 2/3
        #expect(approxEqual(s2.rect.minY, 0))
        #expect(approxEqual(s4.rect.height, 200)) // 600 * 1/3
        #expect(approxEqual(s4.rect.minY, 400))
    }

    // MARK: - Off-path branches keep their own manual ratio

    @Test func offPathSplitPreservesItsStoredRatio() {
        // The split between 2 and 3 is off the path to focus (1) entirely,
        // so it renders at its own manually-set ratio (0.25) rather than
        // being forced to 0.5 or activeFraction.
        let tree: Node = .split(
            direction: .horizontal, ratio: 0.5,
            left: .leaf(1),
            right: .split(direction: .vertical, ratio: 0.25, left: .leaf(2), right: .leaf(3)))
        let bounds = CGSize(width: 900, height: 600)
        let slots = AdaptiveLayout.layout(tree: tree, activeID: 1, bounds: bounds)

        let s2 = slots.first { $0.id == 2 }!
        let s3 = slots.first { $0.id == 3 }!
        // vertical split convention: "left" (2, top) gets ratio*height, "right" (3, bottom) gets the rest.
        #expect(approxEqual(s2.rect.height, 600 * 0.25))
        #expect(approxEqual(s3.rect.height, 600 * 0.75))
    }

    @Test func offPathSiblingKeepsItsOwnPositionNotAStrip() {
        // Tree: horizontal(focus=1 | vertical(2 over 3)). Confirms 2 and 3
        // stay stacked vertically in the right column (preserving their
        // original relationship) rather than being flattened into a
        // single strip alongside each other.
        let tree: Node = .split(
            direction: .horizontal, ratio: 0.5,
            left: .leaf(1),
            right: .split(direction: .vertical, ratio: 0.5, left: .leaf(2), right: .leaf(3)))
        let bounds = CGSize(width: 900, height: 600)
        let slots = AdaptiveLayout.layout(tree: tree, activeID: 1, bounds: bounds)

        let s2 = slots.first { $0.id == 2 }!
        let s3 = slots.first { $0.id == 3 }!
        #expect(approxEqual(s2.rect.minX, s3.rect.minX))
        #expect(approxEqual(s2.rect.width, s3.rect.width))
        #expect(!approxEqual(s2.rect.minY, s3.rect.minY))
        #expect(approxEqual(s2.rect.width, 300)) // 900 * (1 - 2/3)
    }

    // MARK: - Tiering

    @Test func largeOffPathTilesAreScaledTier() {
        var params = AdaptiveLayout.Params.default
        params.activeFraction = 0.5
        params.condenseThreshold = 50
        let tree: Node = .split(direction: .horizontal, ratio: 0.5, left: .leaf(1), right: .leaf(2))
        let bounds = CGSize(width: 1000, height: 800)
        let slots = AdaptiveLayout.layout(tree: tree, activeID: 1, bounds: bounds, params: params)
        let other = slots.first { $0.id == 2 }!
        #expect(other.tier == .scaled)
    }

    @Test func tinyOffPathTilesArePillTier() {
        var params = AdaptiveLayout.Params.default
        params.activeFraction = 0.98
        params.condenseThreshold = 80
        let tree: Node = .split(direction: .horizontal, ratio: 0.5, left: .leaf(1), right: .leaf(2))
        let bounds = CGSize(width: 1000, height: 800)
        let slots = AdaptiveLayout.layout(tree: tree, activeID: 1, bounds: bounds, params: params)
        let other = slots.first { $0.id == 2 }!
        #expect(other.tier == .pill)
    }
}
