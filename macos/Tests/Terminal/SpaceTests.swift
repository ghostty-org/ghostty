import Testing
@testable import Ghostty

struct SpaceTests {
    @Test func storesNameAndIcon() {
        let space = Space(name: "Work", icon: "folder.fill")
        #expect(space.name == "Work")
        #expect(space.icon == "folder.fill")
    }

    @Test func usesDefaultIconWhenUnspecified() {
        let space = Space(name: "Work")
        #expect(space.icon == Space.defaultIcon)
    }

    @Test func emptyIconFallsBackToDefault() {
        let space = Space(name: "Work", icon: "")
        #expect(space.icon == Space.defaultIcon)
    }
}
