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
        // The remembered window must still be live (present in `ordered`) and
        // still assigned to this space; otherwise fall back to the first tab in
        // the space. Checking liveness here avoids returning a stale window
        // before the next sync() prunes it (which would spawn a spurious tab).
        if let window = lastActive[id], assignments[window] == id, ordered.contains(window) {
            return window
        }
        return ordered.first { assignments[$0] == id }
    }

    func noteActiveWindow(_ window: ObjectIdentifier) {
        if let id = assignments[window] { lastActive[id] = window }
    }

    // MARK: - Mutations

    @discardableResult
    func addSpace(name: String, icon: String) -> Space {
        let space = Space(name: name, icon: icon)
        spaces.append(space)
        activeSpaceID = space.id
        return space
    }

    func rename(_ id: Space.ID, name: String, icon: String) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].name = name
        spaces[index].icon = icon.isEmpty ? Space.defaultIcon : icon
    }

    /// Remove a space. Refuses to remove the last remaining space (there must
    /// always be at least one). Any windows still assigned to it are expected to
    /// be closed by the caller; their stale assignments are pruned on sync().
    @discardableResult
    func removeSpace(_ id: Space.ID) -> Bool {
        guard spaces.count > 1, spaces.contains(where: { $0.id == id }) else { return false }
        spaces.removeAll { $0.id == id }
        lastActive[id] = nil
        if activeSpaceID == id {
            activeSpaceID = spaces[0].id
        }
        return true
    }

    func move(_ window: ObjectIdentifier, to id: Space.ID) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        assignments[window] = id
    }

    func setActive(_ id: Space.ID) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        activeSpaceID = id
    }
}
