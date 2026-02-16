import AppKit
import Testing
@testable import Ghostty

struct SplitTreeTests {
    // MARK: - Empty and Non-Empty

    /// An empty tree is empty.
    @Test func emptyTreeIsEmpty() {
        let tree = SplitTree<MockView>()
        #expect(tree.isEmpty)
    }

    /// A non-empty tree is not empty.
    @Test func nonEmptyTreeIsNotEmpty() {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        #expect(!tree.isEmpty)
    }

    /// A tree with a single view is not split.
    @Test func isNotSplit() {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        #expect(!tree.isSplit)
    }

    /// A tree with an inserted view is split.
    @Test func isSplit() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        #expect(tree.isSplit)
    }

    // MARK: - Contains and Find

    /// A tree with a view contains that view.
    @Test func treeContainsView() {
        let view = MockView()
        let tree = SplitTree<MockView>(view: view)
        #expect(tree.contains(.leaf(view: view)))
    }

    /// A tree without a view does not contain that view.
    @Test func treeDoesNotContainView() {
        let view = MockView()
        let tree = SplitTree<MockView>()
        #expect(!tree.contains(.leaf(view: view)))
    }

    /// Finding a view in a tree returns the view.
    @Test func findsInsertedView() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        #expect((tree.find(id: view1.id) != nil))
    }

    /// Finding a view that hasn't been inserted in a tree returns nil.
    @Test func doesNotFindUninsertedView() {
        let view1 = MockView()
        let view2 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        #expect((tree.find(id: view2.id) == nil))
    }

    /// A tree with an inserted view contains that view.
    @Test func treeContainsInsertedView() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        #expect(tree.contains(.leaf(view: view2)))
    }

    /// A tree that never inserts a view does not contain that view.
    @Test func treeDoesNotContainUninsertedView() {
        let view1 = MockView()
        let view2 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        #expect(!tree.contains(.leaf(view: view2)))
    }

    // MARK: - Removing and Replacing

    /// A tree with a removed view does not contain that view.
    @Test func treeDoesNotContainRemovedView() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = tree.removing(.leaf(view: view1))
        #expect(!tree.contains(.leaf(view: view1)))
        #expect(tree.contains(.leaf(view: view2)))
    }

    /// Attempting to remove a view from a tree that doesn't contain it has no effect
    @Test func removingNonexistentNodeLeavesTreeUnchanged() {
        let view1 = MockView()
        let view2 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        let result = tree.removing(.leaf(view: view2))
        #expect(result.contains(.leaf(view: view1)))
        #expect(!result.isEmpty)
    }

    /// Replacing a view should effectively remove and insert a view
    @Test func replacingViewShouldRemoveAndInsertView() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        #expect(tree.contains(.leaf(view: view2)))
        let result = try tree.replacing(node: .leaf(view: view2), with: .leaf(view: view3))
        #expect(result.contains(.leaf(view: view1)))
        #expect(!result.contains(.leaf(view: view2)))
        #expect(result.contains(.leaf(view: view3)))
    }

    /// Replacing a view with itself should work
    @Test func replacingViewWithItselfShouldBeAValidOperation() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        let result = try tree.replacing(node: .leaf(view: view2), with: .leaf(view: view2))
        #expect(result.contains(.leaf(view: view1)))
        #expect(result.contains(.leaf(view: view2)))
    }

    // MARK: - Focus Target

    /// focusTarget should find the next view to focus based on the current focused node and direction
    @Test func focusTargetOnEmptyTreeReturnsNil() {
        let tree = SplitTree<MockView>()
        let view = MockView()
        let target = tree.focusTarget(for: .next, from: .leaf(view: view))
        #expect(target == nil)
    }

    /// focusTarget should find the next view to focus based on the current focused node and direction
    @Test func focusTargetShouldFindNextFocusedNode() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        let target = tree.focusTarget(for: .next, from: .leaf(view: view1))
        #expect(target === view2)
    }

    /// focusTarget should find itself when it's the only view
    @Test func focusTargetShouldFindItselfWhenOnlyView() throws {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)

        let target = tree.focusTarget(for: .next, from: .leaf(view: view1))
        #expect(target === view1)
    }

    /// focusTarget should handle the case when there's no next view by wrapping
    @Test func focusTargetShouldHandleWrappingForNextNode() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        let target = tree.focusTarget(for: .next, from: .leaf(view: view2))
        #expect(target === view1)
    }

    /// focusTarget should find the previous view to focus based on the current focused node and direction
    @Test func focusTargetShouldFindPreviousFocusedNode() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        let target = tree.focusTarget(for: .previous, from: .leaf(view: view2))
        #expect(target === view1)
    }

    /// focusTarget with spatial direction should navigate to the adjacent view
    @Test func focusTargetShouldFindSpatialFocusedNode() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        let target = tree.focusTarget(for: .spatial(.left), from: .leaf(view: view2))
        #expect(target === view1)
    }

    // MARK: - Equalized

    /// equalize an uneven tree (3 views where one side has 2 leaves and the other has 1)
    @Test func equalizedAdjustsRatioByLeafCount() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view2, direction: .right)

        // splitting always results in 0.5 ratio, and now left has 2 leaves, right has 1 leaf
        guard case .split(let before) = tree.root else {
         Issue.record("unexpected node type")
         return
        }
        #expect(abs(before.ratio - 0.5) < 0.001)

        // after equalized(), the ratio should be 0.33 between each leaf
        let equalized = tree.equalized()

        if case .split(let s) = equalized.root {
            #expect(abs(s.ratio - 1.0/3.0) < 0.001)
        }
    }

    // MARK: - Resizing

    /// resizing a view will change its ratio appropriately
    @Test func resizingAdjustsRatio() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        // initial container is 1000px wide, each view is 1/2 width, or 0.5 * 1000
        // resize view1's split boundary 100px to the right
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let resized = try tree.resizing(node: .leaf(view: view1), by: 100, in: .right, with: bounds)

        // new ratio: (500px + 100px) / 1000px = 0.6
        guard case .split(let s) = resized.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(abs(s.ratio - 0.6) < 0.001)
    }

    /// resizing left views will change its ratio appropriately
    @Test func resizingLeftAdjustsRatio() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        // initial container is 1000px wide, each view is 1/2 width, or 0.5 * 1000
        // resize view1's split boundary 50px to the left
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let resized = try tree.resizing(node: .leaf(view: view1), by: 50, in: .left, with: bounds)

        // new ratio: (500px - 50px) / 1000px = 0.45
        guard case .split(let s) = resized.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(abs(s.ratio - 0.45) < 0.001)
    }

    /// resizing vertical views will change its ratio appropriately
    @Test func resizingVerticallyAdjustsRatio() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .down)

        // initial container is 1000px tall, each view is 1/2 width, or 0.5 * 1000
        // resize view1's split boundary 200px downward
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 1000)
        let resized = try tree.resizing(node: .leaf(view: view1), by: 200, in: .down, with: bounds)

        // new ratio: (500px + 200px) / 1000px = 0.7
        guard case .split(let s) = resized.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(abs(s.ratio - 0.7) < 0.001)
    }

    /// resizing up views will change its ratio appropriately
    @Test func resizingUpAdjustsRatio() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .down)

        // initial container is 1000px tall, each view is 1/2 width, or 0.5 * 1000
        // resize view1's split boundary 100px upward
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 1000)
        let resized = try tree.resizing(node: .leaf(view: view1), by: 50, in: .up, with: bounds)

        // new ratio: (500px - 50px) / 1000px = 0.45
        guard case .split(let s) = resized.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(abs(s.ratio - 0.45) < 0.001)
    }

    // MARK: - Codable

    /// trees can be encoded and decoded and preserve structure
    @Test func encodingAndDecodingPreservesTree() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(SplitTree<MockView>.self, from: data)
        #expect(decoded.find(id: view1.id) != nil)
        #expect(decoded.find(id: view2.id) != nil)
        #expect(decoded.isSplit)
    }

    /// encoding and decoding preserves zoomed path
    @Test func encodingAndDecodingPreservesZoomedPath() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        let treeWithZoomed = SplitTree<MockView>(root: tree.root, zoomed: .leaf(view: view2))

        let data = try JSONEncoder().encode(treeWithZoomed)
        let decoded = try JSONDecoder().decode(SplitTree<MockView>.self, from: data)

        #expect(decoded.zoomed != nil)
        if case .leaf(let zoomedView) = decoded.zoomed! {
            #expect(zoomedView.id == view2.id)
        } else {
            Issue.record("unexpected node type")
        }
    }

    // MARK: - Collection Conformance

    /// trees should conform to Collection, meaning indexed access and iterations over leaves
    @Test func treeIteratesLeavesInOrder() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view2, direction: .right)

        // validate collection properties
        #expect(tree.startIndex == 0)
        #expect(tree.endIndex == 3)
        #expect(tree.index(after: 0) == 1)

        // validate access
        #expect(tree[0] === view1)
        #expect(tree[1] === view2)
        #expect(tree[2] === view3)

        // test makeIterator
        var ids: [UUID] = []
        for view in tree {
            ids.append(view.id)
        }
        #expect(ids == [view1.id, view2.id, view3.id])
    }

    /// Iterating over an empty tree yields no elements.
    @Test func emptyTreeCollectionProperties() {
        let tree = SplitTree<MockView>()

        #expect(tree.startIndex == 0)
        #expect(tree.endIndex == 0)

        var count = 0
        for _ in tree {
            count += 1
        }
        #expect(count == 0)
    }

    // MARK: - Structural Identity

    /// structuralIdentity of a tree should be equal to its own identity
    @Test func structuralIdentityIsReflexive() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        #expect(tree.structuralIdentity == tree.structuralIdentity)
    }

    /// resizing a tree should not change structuralIdentity
    @Test func structuralIdentityComparesShapeNotRatio() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        // resized trees have the same structure
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let resized = try tree.resizing(node: .leaf(view: view1), by: 100, in: .right, with: bounds)
        #expect(tree.structuralIdentity == resized.structuralIdentity)
    }

    /// adding views change structuralIdentity
    @Test func structuralIdentityForDifferentStructures() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        // adding a view changes its structure
        let expanded = try tree.inserting(view: view3, at: view2, direction: .down)
        #expect(tree.structuralIdentity != expanded.structuralIdentity)
    }

    /// different views in the same shape have different structuralIdentity
    @Test func structuralIdentityIdentifiesDifferentOrdersShapes() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        // same organization of views, but different ones are not structurally equal
        let view3 = MockView()
        let view4 = MockView()
        var otherTree = SplitTree<MockView>(view: view3)
        otherTree = try otherTree.inserting(view: view4, at: view3, direction: .right)
        #expect(tree.structuralIdentity != otherTree.structuralIdentity)
    }

    // MARK: - View Bounds

    /// viewBounds returns the size of a single leaf view's bounds
    @Test func viewBoundsReturnsLeafViewSize() {
        let view1 = MockView()
        view1.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let tree = SplitTree<MockView>(view: view1)

        let bounds = tree.viewBounds()
        #expect(bounds.width == 500)
        #expect(bounds.height == 300)
    }

    /// viewBounds returns .zero for an empty tree
    @Test func viewBoundsReturnsZeroForEmptyTree() {
        let tree = SplitTree<MockView>()
        let bounds = tree.viewBounds()

        // empty tree has no height and width
        #expect(bounds.width == 0)
        #expect(bounds.height == 0)
    }

    /// viewBounds for horizontal split sums width and takes max height
    @Test func viewBoundsHorizontalSplit() throws {
        let view1 = MockView()
        let view2 = MockView()
        view1.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view2.frame = NSRect(x: 0, y: 0, width: 200, height: 500)
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        let bounds = tree.viewBounds()
        // width is sum of the widths of the views (400 + 200)
        #expect(bounds.width == 600)
        // height is the max of the heights of the views (max(300, 500))
        #expect(bounds.height == 500)
    }

    /// viewBounds for vertical split takes max width and sums height
    @Test func viewBoundsVerticalSplit() throws {
        let view1 = MockView()
        let view2 = MockView()
        view1.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        view2.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .down)

        let bounds = tree.viewBounds()
        // width is the max of the widths of the views (max(300, 500))
        #expect(bounds.width == 500)
        // height is the sum of the heights of the views (200 + 400)
        #expect(bounds.height == 600)
    }

    // MARK: - Node

    /// node finds the node in a single-leaf tree
    @Test func nodeFindsLeaf() {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)

        let node = tree.root?.node(view: view1)
        #expect(node != nil)
        #expect(node == .leaf(view: view1))
    }

    /// node finds both leaves in a split tree
    @Test func nodeFindsLeavesInSplitTree() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)

        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        #expect(tree.root?.node(view: view1) == .leaf(view: view1))
        #expect(tree.root?.node(view: view2) == .leaf(view: view2))
    }

    /// node does not find the node when the view is not in the tree
    @Test func nodeReturnsNilForMissingView() {
        let view1 = MockView()
        let view2 = MockView()

        let tree = SplitTree<MockView>(view: view1)
        #expect(tree.root?.node(view: view2) == nil)
    }

    /// node resizing updates a split node's ratio
    @Test func resizingUpdatesRatio() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        guard case .split(let s) = tree.root else {
            Issue.record("unexpected node type")
            return
        }

        // resizing a split node updates its ratio
        let resized = SplitTree<MockView>.Node.split(s).resizing(to: 0.7)
        guard case .split(let resizedSplit) = resized else {
            Issue.record("unexpected node type")
            return
        }
        #expect(abs(resizedSplit.ratio - 0.7) < 0.001)
    }

    /// resizing on a leaf returns it unchanged
    @Test func resizingLeavesLeafUnchanged() {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)

        guard let root = tree.root else {
            Issue.record("expected non-empty tree")
            return
        }
        // leaf nodes have no ratio so resizing is a no-op
        let resized = root.resizing(to: 0.7)
        #expect(resized == root)
    }

    // MARK: - Spatial

    /// doesBorder returns true when a node touches the left edge
    @Test func doesBorderLeftEdge() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        // view1 touches the left edge, view2 does not
        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 500))
        #expect(spatial.doesBorder(side: .left, from: .leaf(view: view1)))
        #expect(!spatial.doesBorder(side: .left, from: .leaf(view: view2)))
    }

    /// doesBorder returns true when a node touches the right edge
    @Test func doesBorderRightEdge() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        // view1 touches the right edge, view2 does not
        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 500))
        #expect(spatial.doesBorder(side: .right, from: .leaf(view: view2)))
        #expect(!spatial.doesBorder(side: .right, from: .leaf(view: view1)))
    }

    /// doesBorder returns true when a node touches the top edge
    @Test func doesBorderTopEdge() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .down)

        // view1 touches the top edge, view2 does not
        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 500))
        #expect(spatial.doesBorder(side: .up, from: .leaf(view: view1)))
        #expect(!spatial.doesBorder(side: .up, from: .leaf(view: view2)))
    }

    /// doesBorder returns true when a node touches the bottom edge
    @Test func doesBorderBottomEdge() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .down)

        // view1 touches the bottom edge, view2 does not
        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 500))
        #expect(spatial.doesBorder(side: .down, from: .leaf(view: view2)))
        #expect(!spatial.doesBorder(side: .down, from: .leaf(view: view1)))
    }

    // MARK: - Calculate View Bounds

    /// calculateViewBounds returns the leaf's bounds for a single-view tree
    @Test func calculatesViewBoundsForSingleLeaf() {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)

        guard let root = tree.root else {
            Issue.record("expected non-empty tree")
            return
        }

        // container is 1000px wide, 500px tall, contains the single leaf view
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let result = root.calculateViewBounds(in: bounds)
        #expect(result.count == 1)
        #expect(result[0].view === view1)
        #expect(result[0].bounds == bounds)
    }

    /// calculateViewBounds splits horizontally by ratio
    @Test func calculatesViewBoundsHorizontalSplit() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        guard let root = tree.root else {
            Issue.record("expected non-empty tree")
            return
        }

        // container is 1000px wide, 500px tall, horizontal split
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let result = root.calculateViewBounds(in: bounds)
        #expect(result.count == 2)

        // ratio 0.5: left from 0-500px, right from 500-1000px
        let leftBounds = result.first { $0.view === view1 }!.bounds
        let rightBounds = result.first { $0.view === view2 }!.bounds
        #expect(leftBounds == CGRect(x: 0, y: 0, width: 500, height: 500))
        #expect(rightBounds == CGRect(x: 500, y: 0, width: 500, height: 500))
    }

    /// calculateViewBounds splits vertically by ratio
    @Test func calculatesViewBoundsVerticalSplit() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .down)

        guard let root = tree.root else {
            Issue.record("expected non-empty tree")
            return
        }

        // container is 500px wide, 1000px tall, vertical split
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 1000)
        let result = root.calculateViewBounds(in: bounds)
        #expect(result.count == 2)

        // ratio 0.5: bottom from 0–500px, top from 500–1000px
        let topBounds = result.first { $0.view === view1 }!.bounds
        let bottomBounds = result.first { $0.view === view2 }!.bounds
        #expect(topBounds == CGRect(x: 0, y: 500, width: 500, height: 500))
        #expect(bottomBounds == CGRect(x: 0, y: 0, width: 500, height: 500))
    }

    /// calculateViewBounds respects custom split ratio
    @Test func calculateViewBoundsCustomRatio() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        guard case .split(let s) = tree.root else {
            Issue.record("unexpected node type")
            return
        }

        // resize the root node to a custom ratio
        let resizedRoot = SplitTree<MockView>.Node.split(s).resizing(to: 0.3)
        let container = CGRect(x: 0, y: 0, width: 1000, height: 400)
        let result = resizedRoot.calculateViewBounds(in: container)
        #expect(result.count == 2)

        // ratio 0.3: left from 0-300px, right from 300-1000px
        let leftBounds = result.first { $0.view === view1 }!.bounds
        let rightBounds = result.first { $0.view === view2 }!.bounds
        #expect(leftBounds.width == 300)   // 0.3 * 1000
        #expect(rightBounds.width == 700)   // 0.7 * 1000
        #expect(rightBounds.minX == 300)
    }

    /// calculateViewBounds for 2x2 grid
    @Test func calculateViewBoundsGrid() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        let view4 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view1, direction: .down)
        tree = try tree.inserting(view: view4, at: view2, direction: .down)
        guard let root = tree.root else {
            Issue.record("expected non-empty tree")
            return
        }
        let container = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let result = root.calculateViewBounds(in: container)
        #expect(result.count == 4)
        // Horizontal 0.5, vertical 0.5 each: view1 top-left, view2 top-right, view3 bottom-left, view4 bottom-right
        let b1 = result.first { $0.view === view1 }!.bounds
        let b2 = result.first { $0.view === view2 }!.bounds
        let b3 = result.first { $0.view === view3 }!.bounds
        let b4 = result.first { $0.view === view4 }!.bounds
        #expect(b1 == CGRect(x: 0, y: 400, width: 500, height: 400))   // top-left
        #expect(b2 == CGRect(x: 500, y: 400, width: 500, height: 400)) // top-right
        #expect(b3 == CGRect(x: 0, y: 0, width: 500, height: 400))     // bottom-left
        #expect(b4 == CGRect(x: 500, y: 0, width: 500, height: 400))   // bottom-right
    }

    /// slots should return nodes to the right, sorted by distance
    @Test func slotsRightFromNode() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        // use a 1000x500 container to test the spatial representation
        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 500))
        let slots = spatial.slots(in: .right, from: .leaf(view: view1))
        #expect(slots.count == 1)
        #expect(slots[0].node == .leaf(view: view2))
    }

    /// slots should return nodes to the left, sorted by distance
    @Test func slotsLeftFromNode() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        // use a 1000x500 container to test the spatial representation
        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 500))
        let slots = spatial.slots(in: .left, from: .leaf(view: view2))
        #expect(slots.count == 1)
        #expect(slots[0].node == .leaf(view: view1))
    }

    /// slots should return nodes below, sorted by distance
    @Test func slotsDownFromNode() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .down)

        // use a 1000x500 container to test the spatial representation
        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 500))
        let slots = spatial.slots(in: .down, from: .leaf(view: view1))
        #expect(slots.count == 1)
        #expect(slots[0].node == .leaf(view: view2))
    }

    /// slots should return nodes above, sorted by distance
    @Test func slotsUpFromNode() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .down)

        // use a 1000x500 container to test the spatial representation
        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 500))
        let slots = spatial.slots(in: .up, from: .leaf(view: view2))
        #expect(slots.count == 1)
        #expect(slots[0].node == .leaf(view: view1))
    }

    /// slots in 2x2 grid: from top-left, right and down include the expected leaf nodes
    @Test func slotsGridFromTopLeft() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        let view4 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view1, direction: .down)
        tree = try tree.inserting(view: view4, at: view2, direction: .down)
        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 800))
        let rightSlots = spatial.slots(in: .right, from: .leaf(view: view1))
        let downSlots = spatial.slots(in: .down, from: .leaf(view: view1))
        // slots() returns both split nodes and leaves; split nodes can tie on distance
        #expect(rightSlots.contains { $0.node == .leaf(view: view2) })
        #expect(downSlots.contains { $0.node == .leaf(view: view3) })
    }

    /// slots in 2x2 grid: from bottom-right, left and up include the expected leaf nodes
    @Test func slotsGridFromBottomRight() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        let view4 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view1, direction: .down)
        tree = try tree.inserting(view: view4, at: view2, direction: .down)
        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 800))
        let leftSlots = spatial.slots(in: .left, from: .leaf(view: view4))
        let upSlots = spatial.slots(in: .up, from: .leaf(view: view4))
        #expect(leftSlots.contains { $0.node == .leaf(view: view3) })
        #expect(upSlots.contains { $0.node == .leaf(view: view2) })
    }

    /// slots should return empty when there are no nodes in that direction
    @Test func slotsReturnsEmptyWhenNoNodesInDirection() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        // use a 1000x500 container to test the spatial representation
        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 500))
        #expect(spatial.slots(in: .left, from: .leaf(view: view1)).isEmpty)
        #expect(spatial.slots(in: .right, from: .leaf(view: view2)).isEmpty)
        #expect(spatial.slots(in: .up, from: .leaf(view: view1)).isEmpty)
        #expect(spatial.slots(in: .down, from: .leaf(view: view2)).isEmpty)
    }

    /// a StructuralIdentity can be used in a Set
    @Test func structuralIdentityInSet() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        // create a set of structural identities and add the tree's identity to it
        var seen: Set<SplitTree<MockView>.StructuralIdentity> = []
        seen.insert(tree.structuralIdentity)
        seen.insert(tree.structuralIdentity)
        #expect(seen.count == 1)
    }

    /// StructuralIdentity distinguishes different trees in a Set
    @Test func structuralIdentitySetDistinguishesTrees() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        var tree1 = SplitTree<MockView>(view: view1)
        var tree2 = SplitTree<MockView>(view: view1)
        tree1 = try tree1.inserting(view: view2, at: view1, direction: .right)
        tree2 = try tree2.inserting(view: view3, at: view1, direction: .right)

        // create a set of structural identities and add the trees' identities to it
        var seen: Set<SplitTree<MockView>.StructuralIdentity> = []
        seen.insert(tree1.structuralIdentity)
        seen.insert(tree2.structuralIdentity)
        #expect(seen.count == 2)
    }

    /// StructuralIdentity works as Dictionary key
    @Test func structuralIdentityAsDictionaryKey() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        // create a dictionary of structural identities and add the tree's identity to it
        var cache: [SplitTree<MockView>.StructuralIdentity: String] = [:]
        cache[tree.structuralIdentity] = "two-pane"
        #expect(cache[tree.structuralIdentity] == "two-pane")
    }

    /// Node.StructuralIdentity can be used in a Set
    @Test func nodeStructuralIdentityInSet() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        guard case .split(let s) = tree.root else {
            Issue.record("unexpected node type")
            return
        }
        var nodeIds: Set<SplitTree<MockView>.Node.StructuralIdentity> = []
        nodeIds.insert(tree.root!.structuralIdentity)
        nodeIds.insert(s.left.structuralIdentity)
        nodeIds.insert(s.right.structuralIdentity)
        #expect(nodeIds.count == 3)
    }

    /// Node.StructuralIdentity distinguishes different leaf nodes
    @Test func nodeStructuralIdentityDistinguishesLeaves() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        guard case .split(let s) = tree.root else {
            Issue.record("unexpected node type")
            return
        }
        var nodeIds: Set<SplitTree<MockView>.Node.StructuralIdentity> = []
        nodeIds.insert(s.left.structuralIdentity)
        nodeIds.insert(s.right.structuralIdentity)
        #expect(nodeIds.count == 2)
    }
}
