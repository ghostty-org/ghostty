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
        SpacesModel(defaultSpace: Space(name: "Space 1"))
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

    @Test func lastActiveWindowIgnoresStaleRememberedWindow() {
        let m = model()
        let (owners, keys) = makeKeys(2)
        _ = owners
        m.sync(liveWindows: keys)
        m.noteActiveWindow(keys[1])
        // keys[1] is now gone from the live set: must NOT be returned; falls
        // back to the first live window still in the space.
        #expect(m.lastActiveWindow(in: m.activeSpaceID, from: [keys[0]]) == keys[0])
    }

    @Test func addSpaceAppendsAndActivates() {
        let m = model()
        let created = m.addSpace(name: "Work", icon: "wrench.and.screwdriver.fill")
        #expect(m.spaces.count == 2)
        #expect(m.activeSpaceID == created.id)
        #expect(m.activeSpace.name == "Work")
    }

    @Test func renameUpdatesNameAndIcon() {
        let m = model()
        let id = m.activeSpaceID
        m.rename(id, name: "Renamed", icon: "folder.fill")
        #expect(m.space(id)?.name == "Renamed")
        #expect(m.space(id)?.icon == "folder.fill")
    }

    @Test func removeSpaceRefusesLastSpace() {
        let m = model()
        let first = m.activeSpaceID
        #expect(m.removeSpace(first) == false)
        #expect(m.spaces.count == 1)
    }

    @Test func removeSpaceRemovesNonLastEvenIfNonEmpty() {
        let m = model()
        let first = m.activeSpaceID
        let second = m.addSpace(name: "Work", icon: "wrench.and.screwdriver.fill")
        // Put a window in the second space; it is still removable (non-empty).
        let (owners, keys) = makeKeys(1)
        _ = owners
        m.sync(liveWindows: keys) // assigned to active (second)
        #expect(m.spaceID(for: keys[0]) == second.id)
        #expect(m.removeSpace(second.id) == true)
        #expect(m.spaces.count == 1)
        #expect(m.spaces.first?.id == first)
    }

    @Test func removeActiveSpaceResetsActive() {
        let m = model()
        let first = m.activeSpaceID
        let second = m.addSpace(name: "Work", icon: "wrench.and.screwdriver.fill") // active == second
        #expect(m.removeSpace(second.id) == true)
        #expect(m.spaces.count == 1)
        #expect(m.activeSpaceID == first)
    }

    @Test func moveReassignsWindow() {
        let m = model()
        let first = m.activeSpaceID
        let second = m.addSpace(name: "Work", icon: "wrench.and.screwdriver.fill")
        m.setActive(first)
        let (owners, keys) = makeKeys(1)
        _ = owners
        m.sync(liveWindows: keys) // assigned to first
        m.move(keys[0], to: second.id)
        #expect(m.spaceID(for: keys[0]) == second.id)
        #expect(m.isEmpty(first) == true)
        #expect(m.isEmpty(second.id) == false)
    }

    @Test func setActiveSwitchesSpace() {
        let m = model()
        let first = m.activeSpaceID
        let second = m.addSpace(name: "Work", icon: "wrench.and.screwdriver.fill")
        #expect(m.activeSpaceID == second.id)
        m.setActive(first)
        #expect(m.activeSpaceID == first)
    }
}
