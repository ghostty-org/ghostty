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
}
