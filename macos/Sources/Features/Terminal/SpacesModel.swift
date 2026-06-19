import Foundation

/// Per-tab-group state for sidebar Spaces. Pure logic over opaque window
/// keys (`ObjectIdentifier`) so it can be unit-tested without AppKit.
@MainActor
final class SpacesModel: ObservableObject {
    @Published private(set) var spaces: [Space]
    @Published private(set) var activeSpaceID: Space.ID
    /// Sidebar width, shared across all of a group's tabs so it doesn't reset
    /// when switching tabs (each tab renders its own sidebar view).
    @Published var sidebarWidth: CGFloat = 281

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

    /// Reconcile against the *complete* live set of windows in a tab group:
    /// forget dead windows and assign any newly-seen window to the active space.
    /// Only call this with the authoritative full window list — never a partial
    /// view, or live windows missing from the list get their assignments wiped.
    func sync(liveWindows: [ObjectIdentifier]) {
        let live = Set(liveWindows)
        assignments = assignments.filter { live.contains($0.key) }
        lastActive = lastActive.filter { live.contains($0.value) }
        for window in liveWindows where assignments[window] == nil {
            assignments[window] = activeSpaceID
        }
    }

    /// Ensure a single window is assigned (to the active space) without pruning
    /// any others. Use when only a partial view of the group is available (a
    /// standalone window, or a window mid-teardown) so it can't wipe the shared
    /// model's assignments for the rest of the group.
    func registerIfNeeded(_ window: ObjectIdentifier) {
        if assignments[window] == nil {
            assignments[window] = activeSpaceID
        }
    }

    /// Remove any non-active space that has no tabs. This is the single owner of
    /// "a space disappears once its last tab is gone" — driven off the live
    /// assignment set after sync(), so every close path (sidebar, ⌘W, split,
    /// delete) converges here and nothing has to remove spaces optimistically.
    /// The active space is kept (it may be briefly empty while a tab is created)
    /// and there is always at least one space.
    func pruneEmptySpaces() {
        let occupied = Set(assignments.values)
        let removeIDs = Set(spaces.filter { $0.id != activeSpaceID && !occupied.contains($0.id) }.map { $0.id })
        guard !removeIDs.isEmpty else { return }
        spaces.removeAll { removeIDs.contains($0.id) }
        lastActive = lastActive.filter { !removeIDs.contains($0.key) }
    }

    // MARK: - Queries

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
