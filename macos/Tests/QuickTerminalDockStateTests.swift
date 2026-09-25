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

    @Test func managedHiddenDockStaysOnDetectedDisplay() {
        var state = QuickTerminalDockState()

        #expect(state.screenHasDock(displayID: 1, detected: true) == true)
        #expect(state.screenHasDock(displayID: 2, detected: false) == false)
        #expect(state.setShouldHide(true, dockAutoHide: false, fullscreenSpace: false) == .hide)

        // Once hidden, no screen reports the dock through its visible frame.
        #expect(state.screenHasDock(displayID: 1, detected: false) == true)
        #expect(state.screenHasDock(displayID: 2, detected: false) == false)
        #expect(state.screenHasDock(displayID: nil, detected: false) == false)
    }

    @Test func dockDisplayFollowsDetectionWhileVisible() {
        var state = QuickTerminalDockState()

        #expect(state.screenHasDock(displayID: 1, detected: true) == true)
        #expect(state.screenHasDock(displayID: 2, detected: true) == true)
        #expect(state.setShouldHide(true, dockAutoHide: false, fullscreenSpace: false) == .hide)

        #expect(state.screenHasDock(displayID: 1, detected: false) == false)
        #expect(state.screenHasDock(displayID: 2, detected: false) == true)
    }

    @Test func positionDoesNotConflictWithoutDockOnScreen() {
        for position in [QuickTerminalPosition.top, .bottom, .left, .right, .center] {
            for orientation in [DockOrientation.top, .bottom, .left, .right] {
                #expect(!position.conflictsWithDock(orientation: orientation, screenHasDock: false))
            }
        }

        #expect(QuickTerminalPosition.bottom.conflictsWithDock(orientation: .bottom, screenHasDock: true))
    }
}
