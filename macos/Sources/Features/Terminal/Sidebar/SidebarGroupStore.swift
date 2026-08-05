import Foundation
import Combine

/// App-wide store for sidebar groups and manual tab assignments.
///
/// A single instance is shared by every terminal window so that group
/// edits, collapse state and assignments stay consistent across all
/// sidebars. State is persisted as JSON under Application Support.
@MainActor
final class SidebarGroupStore: ObservableObject {
    static let shared = SidebarGroupStore()

    /// A manual tab-to-group assignment, timestamped so stale entries
    /// from long-gone surfaces can be pruned on load. A nil `groupId`
    /// means "explicitly ungrouped", overriding any project rule.
    struct Assignment: Codable, Equatable {
        let groupId: UUID?
        let assignedAt: Date
    }

    private struct State: Codable {
        var groups: [SidebarGroup]
        var assignments: [UUID: Assignment]
    }

    @Published private(set) var groups: [SidebarGroup] = []
    @Published private(set) var assignments: [UUID: Assignment] = [:]

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    /// Assignments older than this are dropped on load; a closed surface's
    /// UUID never comes back except via window restoration, which happens
    /// well within this window.
    private static let assignmentMaxAge: TimeInterval = 30 * 24 * 60 * 60

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
            .appendingPathComponent("sidebar-groups.json")
    }

    // MARK: Group CRUD

    func createGroup(
        name: String,
        icon: String = "folder",
        color: TerminalTabColor = .none,
        kind: SidebarGroup.Kind = .manual
    ) -> SidebarGroup {
        let group = SidebarGroup(name: name, icon: icon, color: color, kind: kind)
        groups.append(group)
        scheduleSave()
        return group
    }

    func update(_ id: UUID, _ mutate: (inout SidebarGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        mutate(&groups[index])
        scheduleSave()
    }

    func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value.groupId != id }
        scheduleSave()
    }

    func moveGroup(_ id: UUID, toIndex index: Int) {
        guard let from = groups.firstIndex(where: { $0.id == id }) else { return }
        let group = groups.remove(at: from)
        groups.insert(group, at: min(max(index, 0), groups.count))
        scheduleSave()
    }

    func toggleCollapsed(_ id: UUID) {
        update(id) { $0.collapsed.toggle() }
    }

    // MARK: Assignments

    func assign(surfaceId: UUID, to groupId: UUID?) {
        assignments[surfaceId] = Assignment(groupId: groupId, assignedAt: Date())
        scheduleSave()
    }

    func unassign(surfaceId: UUID) {
        assignments.removeValue(forKey: surfaceId)
        scheduleSave()
    }

    /// Resolves the group for a tab: manual assignment wins (including an
    /// explicit "ungrouped" assignment), then the first project group whose
    /// root contains the pwd, else nil (the default ungrouped section).
    func resolveGroup(surfaceId: UUID?, pwd: String?) -> SidebarGroup? {
        if let surfaceId, let assignment = assignments[surfaceId] {
            guard let groupId = assignment.groupId else { return nil }
            if let group = groups.first(where: { $0.id == groupId }) {
                return group
            }
        }
        return groups.first { $0.claims(pwd: pwd) }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return }

        let cutoff = Date().addingTimeInterval(-Self.assignmentMaxAge)
        groups = state.groups
        assignments = state.assignments.filter { $0.value.assignedAt > cutoff }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        let state = State(groups: groups, assignments: assignments)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
