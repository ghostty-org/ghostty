import AppKit
import Combine
import SwiftUI

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

    /// Per-tab customization: any of a custom display name, an icon and
    /// a color dot, keyed by surface id.
    struct TabOverride: Codable, Equatable {
        var name: String?
        var icon: String?
        var color: TerminalTabColor?

        /// A theme-palette (or otherwise custom) color; wins over `color`.
        var colorHex: String?

        /// The file this terminal was opened for, when a panel opened it.
        ///
        /// Kept as well as `name` — which is set to the same thing — because
        /// the two answer different questions: `name` is what the tab is
        /// called and the user may retype it, while this is what the tab is
        /// *showing*, and it is what picks the file-type icon.
        var fileName: String?

        var isEmpty: Bool {
            (name?.isEmpty ?? true) && (icon?.isEmpty ?? true)
                && (color ?? .none) == .none
                && (colorHex?.isEmpty ?? true)
                && (fileName?.isEmpty ?? true)
        }

        var accentColor: Color? {
            if let colorHex, let nsColor = NSColor(hex: colorHex) {
                return Color(nsColor: nsColor)
            }
            return color?.sidebarAccent
        }
    }

    private struct State: Codable {
        var groups: [SidebarGroup]
        var assignments: [UUID: Assignment]
        var tabOrder: [UUID]?
        var tabOverrides: [UUID: TabOverride]?
    }

    @Published private(set) var groups: [SidebarGroup] = []
    @Published private(set) var assignments: [UUID: Assignment] = [:]
    @Published private(set) var tabOverrides: [UUID: TabOverride] = [:]

    /// Display order of tabs in the sidebar, by surface id. Tabs not in
    /// the list sort after ordered ones, in native tab-group order.
    @Published private(set) var tabOrder: [UUID] = []

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
            .appendingPathComponent("com.ipetinate.phantom", isDirectory: true)
            .appendingPathComponent("sidebar-groups.json")
    }

    // MARK: Group CRUD

    func createGroup(
        name: String,
        details: String? = nil,
        icon: String = "folder",
        color: TerminalTabColor = .none,
        kind: SidebarGroup.Kind = .manual
    ) -> SidebarGroup {
        let group = SidebarGroup(name: name, details: details, icon: icon, color: color, kind: kind)
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

    /// Moves a group to another group's position (drag-and-drop reorder).
    func moveGroup(_ id: UUID, before targetId: UUID) {
        guard id != targetId,
              let from = groups.firstIndex(where: { $0.id == id })
        else { return }
        let group = groups.remove(at: from)
        let to = groups.firstIndex(where: { $0.id == targetId }) ?? groups.count
        groups.insert(group, at: to)
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

    /// Places a newly created tab at the top or bottom of the sidebar
    /// display order. No-op for tabs already ordered (e.g. restored).
    func registerNewTab(surfaceId: UUID, atStart: Bool) {
        guard !tabOrder.contains(surfaceId) else { return }
        if atStart {
            tabOrder.insert(surfaceId, at: 0)
        } else {
            tabOrder.append(surfaceId)
        }
        scheduleSave()
    }

    func setTabOverride(surfaceId: UUID, _ override: TabOverride) {
        if override.isEmpty {
            tabOverrides.removeValue(forKey: surfaceId)
        } else {
            tabOverrides[surfaceId] = override
        }
        scheduleSave()
    }

    /// Moves a tab next to another tab (drag-and-drop reorder), also
    /// adopting the target's group so a single drop both repositions
    /// and regroups.
    func insert(surfaceId: UUID, near targetSurfaceId: UUID, after: Bool, groupId: UUID?) {
        guard surfaceId != targetSurfaceId else { return }

        assign(surfaceId: surfaceId, to: groupId)

        var order = tabOrder.filter { $0 != surfaceId }
        if !order.contains(targetSurfaceId) {
            order.append(targetSurfaceId)
        }
        let targetIndex = order.firstIndex(of: targetSurfaceId)!
        order.insert(surfaceId, at: after ? targetIndex + 1 : targetIndex)
        tabOrder = order
        scheduleSave()
    }

    /// Sorts tabs by the persisted sidebar order; unknown tabs keep
    /// their native relative order after the ordered ones.
    func sorted<T>(_ tabs: [T], id: (T) -> UUID?) -> [T] {
        let indexById = Dictionary(
            uniqueKeysWithValues: tabOrder.enumerated().map { ($1, $0) }
        )
        return tabs.enumerated().sorted { lhs, rhs in
            let lo = id(lhs.element).flatMap { indexById[$0] }
            let ro = id(rhs.element).flatMap { indexById[$0] }
            switch (lo, ro) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
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
        tabOrder = Array((state.tabOrder ?? []).suffix(300))
        tabOverrides = state.tabOverrides ?? [:]
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
        let state = State(
            groups: groups,
            assignments: assignments,
            tabOrder: tabOrder,
            tabOverrides: tabOverrides
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
