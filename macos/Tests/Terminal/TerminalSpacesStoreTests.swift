import Foundation
import Testing
@testable import Ghostty

@MainActor
struct TerminalSpacesStoreTests {
    @Test func sameKeyReturnsSameModel() {
        let store = TerminalSpacesStore()
        let owner = NSObject()
        let a = store.model(forKeyObject: owner)
        let b = store.model(forKeyObject: owner)
        #expect(a === b)
    }

    @Test func differentKeysReturnDifferentModels() {
        let store = TerminalSpacesStore()
        let owner1 = NSObject()
        let owner2 = NSObject()
        let a = store.model(forKeyObject: owner1)
        let b = store.model(forKeyObject: owner2)
        #expect(a !== b)
    }

    @Test func newModelHasDefaultSpace() {
        let store = TerminalSpacesStore()
        let owner = NSObject()
        let model = store.model(forKeyObject: owner)
        #expect(model.spaces.count == 1)
        #expect(model.activeSpace.name == "Space 1")
        #expect(model.activeSpace.icon == Space.defaultIcon)
    }
}
