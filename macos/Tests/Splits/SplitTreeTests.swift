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
}
