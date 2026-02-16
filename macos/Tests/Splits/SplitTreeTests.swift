import Testing
@testable import Ghostty

struct SplitTreeTests {
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
         #expect(Bool(false))
         return
        }
        #expect(abs(before.ratio - 0.5) < 0.001)

        // after equalized(), the ratio should be 0.33 between each leaf
        let equalized = tree.equalized()

        if case .split(let s) = equalized.root {
            #expect(abs(s.ratio - 1.0/3.0) < 0.001)
        }
    }

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
            #expect(Bool(false))
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
            #expect(Bool(false))
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
            #expect(Bool(false))
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
            #expect(Bool(false))
            return
        }
        #expect(abs(s.ratio - 0.45) < 0.001)
    }

    /// trees can be encoding and decoded and preserve structure
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
}
