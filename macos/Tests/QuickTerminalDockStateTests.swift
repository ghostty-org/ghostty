import Testing
@testable import Ghostty

struct QuickTerminalDockStateTests {
    @Test func userHiddenDockIsNotManaged() {
        var state = QuickTerminalDockState()

        #expect(state.setShouldHide(true, dockAutoHide: true, fullscreenSpace: false) == .none())
        #expect(state.shouldBeHidden)
        #expect(!state.managedHidden)

        #expect(state.setShouldHide(false, dockAutoHide: true, fullscreenSpace: false) == .none())
        #expect(!state.shouldBeHidden)
        #expect(!state.managedHidden)
    }

    @Test func normalSpaceCanHideAndShowDock() {
        var state = QuickTerminalDockState()

        #expect(state.setShouldHide(true, dockAutoHide: false, fullscreenSpace: false) == .hide)
        #expect(state.shouldBeHidden)
        #expect(state.managedHidden)

        #expect(state.setShouldHide(false, dockAutoHide: true, fullscreenSpace: false) == .show)
        #expect(!state.shouldBeHidden)
        #expect(!state.managedHidden)
    }

    @Test func fullscreenSpaceNeverShowsDock() {
        var state = QuickTerminalDockState()

        #expect(state.setShouldHide(true, dockAutoHide: false, fullscreenSpace: false) == .hide)
        #expect(state.setShouldHide(false, dockAutoHide: true, fullscreenSpace: true) == .none(skip: "fullscreenSpace"))
        #expect(!state.shouldBeHidden)
        #expect(state.managedHidden)

        #expect(state.apply(dockAutoHide: true, fullscreenSpace: true) == .none(skip: "fullscreenSpace"))
        #expect(state.managedHidden)

        #expect(state.apply(dockAutoHide: true, fullscreenSpace: false) == .show)
        #expect(!state.managedHidden)
    }

    @Test func shouldHideChangeIsAppliedWhenDockBecomesVisible() {
        var state = QuickTerminalDockState()

        #expect(state.setShouldHide(true, dockAutoHide: true, fullscreenSpace: false) == .none())
        #expect(state.shouldBeHidden)
        #expect(!state.managedHidden)

        #expect(state.apply(dockAutoHide: false, fullscreenSpace: false) == .hide)
        #expect(state.managedHidden)
    }
}
