import Foundation
import Testing
@testable import Ghostty

@MainActor
struct SpacesModelTests {
    /// Returns `count` distinct ObjectIdentifier keys plus the owning objects
    /// (kept alive by the caller so the identifiers stay valid).
    private func makeKeys(_ count: Int) -> (owners: [NSObject], keys: [ObjectIdentifier]) {
        let owners = (0..<count).map { _ in NSObject() }
        return (owners, owners.map(ObjectIdentifier.init))
    }

    private func model() -> SpacesModel {
        SpacesModel(defaultSpace: Space(name: "Space 1", icon: "💻"))
    }

    @Test func startsWithDefaultActiveSpace() {
        let m = model()
        #expect(m.spaces.count == 1)
        #expect(m.activeSpaceID == m.spaces[0].id)
        #expect(m.activeSpace.name == "Space 1")
    }

    @Test func syncAssignsNewWindowsToActiveSpace() {
        let m = model()
        let (owners, keys) = makeKeys(2)
        _ = owners
        m.sync(liveWindows: keys)
        #expect(m.spaceID(for: keys[0]) == m.activeSpaceID)
        #expect(m.spaceID(for: keys[1]) == m.activeSpaceID)
        #expect(m.windowsInActiveSpace(from: keys) == keys)
    }

    @Test func syncDropsDeadWindows() {
        let m = model()
        let (owners, keys) = makeKeys(3)
        _ = owners
        m.sync(liveWindows: keys)
        m.sync(liveWindows: [keys[0], keys[2]])
        #expect(m.spaceID(for: keys[1]) == nil)
        #expect(m.windowsInActiveSpace(from: [keys[0], keys[2]]) == [keys[0], keys[2]])
    }

    @Test func isEmptyReflectsAssignments() {
        let m = model()
        let firstID = m.activeSpaceID
        #expect(m.isEmpty(firstID) == true)
        let (owners, keys) = makeKeys(1)
        _ = owners
        m.sync(liveWindows: keys)
        #expect(m.isEmpty(firstID) == false)
    }

    @Test func lastActiveWindowFallsBackToFirstInSpace() {
        let m = model()
        let (owners, keys) = makeKeys(2)
        _ = owners
        m.sync(liveWindows: keys)
        // No note yet: falls back to first window in the space.
        #expect(m.lastActiveWindow(in: m.activeSpaceID, from: keys) == keys[0])
        // After noting the second window, it is returned.
        m.noteActiveWindow(keys[1])
        #expect(m.lastActiveWindow(in: m.activeSpaceID, from: keys) == keys[1])
    }
}
