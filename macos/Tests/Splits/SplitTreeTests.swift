import Testing
@testable import Ghostty

struct SplitTreeTests {
    @Test func emptyTreeIsEmpty() {
        let tree = SplitTree<MockView>()
        #expect(tree.isEmpty)
    }
}
