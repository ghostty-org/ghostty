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
        #expect(tree.contains(view))
    }

    /// A tree without a view does not contain that view.
    @Test func treeDoesNotContainView() {
        let view = MockView()
        let tree = SplitTree<MockView>()
        #expect(!tree.contains(view))
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
        #expect(tree.contains(view2))
    }

    /// A tree that never inserts a view does not contain that view.
    @Test func treeDoesNotContainUninsertedView() {
        let view1 = MockView()
        let view2 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        #expect(!tree.contains(view2))
    }

    /// A tree with a removed view does not contain that view.
    @Test func treeDoesNotContainRemovedView() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.removing(.leaf(view: view1))
        #expect(!tree.contains(view1))
    }
}
