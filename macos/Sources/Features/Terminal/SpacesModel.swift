import Foundation

/// Per-tab-group state for sidebar Spaces. Pure logic over opaque window
/// keys (`ObjectIdentifier`) so it can be unit-tested without AppKit.
@MainActor
final class SpacesModel: ObservableObject {
    @Published private(set) var spaces: [Space]
    @Published private(set) var activeSpaceID: Space.ID

    /// window key -> space id
    private var assignments: [ObjectIdentifier: Space.ID] = [:]
    /// space id -> most-recently-active window key
    private var lastActive: [Space.ID: ObjectIdentifier] = [:]

    init(defaultSpace: Space) {
        self.spaces = [defaultSpace]
        self.activeSpaceID = defaultSpace.id
    }

    var activeSpace: Space {
        spaces.first { $0.id == activeSpaceID } ?? spaces[0]
    }

    func space(_ id: Space.ID) -> Space? {
        spaces.first { $0.id == id }
    }

    // MARK: - Sync

    /// Reconcile against the live set of windows: forget dead windows and
    /// assign any newly-seen window to the active space.
    func sync(liveWindows: [ObjectIdentifier]) {
        let live = Set(liveWindows)
        assignments = assignments.filter { live.contains($0.key) }
        lastActive = lastActive.filter { live.contains($0.value) }
        for window in liveWindows where assignments[window] == nil {
            assignments[window] = activeSpaceID
        }
    }

    // MARK: - Queries

    func windowsInActiveSpace(from ordered: [ObjectIdentifier]) -> [ObjectIdentifier] {
        ordered.filter { assignments[$0] == activeSpaceID }
    }

    func spaceID(for window: ObjectIdentifier) -> Space.ID? {
        assignments[window]
    }

    func isEmpty(_ id: Space.ID) -> Bool {
        !assignments.values.contains(id)
    }

    func lastActiveWindow(in id: Space.ID, from ordered: [ObjectIdentifier]) -> ObjectIdentifier? {
        if let window = lastActive[id], assignments[window] == id { return window }
        return ordered.first { assignments[$0] == id }
    }

    func noteActiveWindow(_ window: ObjectIdentifier) {
        if let id = assignments[window] { lastActive[id] = window }
    }
}
