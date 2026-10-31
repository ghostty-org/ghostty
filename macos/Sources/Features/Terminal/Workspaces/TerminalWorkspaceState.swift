import Foundation

/// The committed workspace graph. Native tab groups are a projection of this
/// value, including while AppKit has split parked windows into singletons.
struct TerminalWorkspaceState: Codable, Equatable {
    struct Group: Codable, Equatable {
        var id: UUID
        var tabs: [UUID] = []
        var selected: UUID?
        var scrollOffset: Double?
    }

    struct Window: Codable, Equatable {
        var currentWorkspace: UUID
        var tabLayout: String?
        var previousWorkspace: UUID?
        var groups: [UUID: Group] = [:]
        var frame: CGRect?
        var fullscreen: Bool?
        var fullscreenMode: FullscreenMode?
    }

    struct Owner: Equatable {
        var window: UUID
        var workspace: UUID
        var group: UUID
    }

    struct Presentation: Codable, Equatable {
        var sidebarVisible: Bool
        var sidebarWidth: Double
        var inspectorVisible: Bool
        var inspectorWidth: Double
        var inspectorPane: String?
        var quickInputVisible = false
        var quickInputPinned = false
        var quickInputHeight: Double
    }

    var version = 1
    var workspaces: [TerminalWorkspace] = [.initial]
    // Compatibility with v1/AppKit archives. Commands keep this index in sync;
    // ownership and ordering are always resolved from windows, never this index.
    var membership: [UUID: UUID] = [:]
    var hiddenTabs: Set<UUID> = []
    var selectedTabs: [UUID: UUID] = [:]
    var parkedGroups: [UUID: [UUID]]? = [:]
    var shortcuts: [String: String] = [:]
    var presentations: [UUID: Presentation]? = [:]
    var windows: [UUID: Window]?

    var defaultID: UUID { workspaces.first?.id ?? TerminalWorkspace.defaultID }

    func owner(of tab: UUID) -> Owner? {
        for (window, record) in windows ?? [:] {
            for (workspace, group) in record.groups where group.tabs.contains(tab) {
                return Owner(window: window, workspace: workspace, group: group.id)
            }
        }
        return nil
    }

    func isParked(_ tab: UUID) -> Bool {
        guard let owner = owner(of: tab) else { return false }
        return windows?[owner.window]?.currentWorkspace != owner.workspace
    }

    mutating func register(_ tab: UUID, owner: Owner) {
        if let old = self.owner(of: tab), old != owner { remove(tab) }
        var window = windows?[owner.window] ?? Window(currentWorkspace: owner.workspace)
        var group = window.groups[owner.workspace] ?? Group(id: owner.group)
        if !group.tabs.contains(tab) { group.tabs.append(tab) }
        if group.selected == nil { group.selected = tab }
        window.groups[owner.workspace] = group
        if windows == nil { windows = [:] }
        windows?[owner.window] = window
        membership[tab] = owner.workspace
        updateLegacyPresentation()
    }

    mutating func remove(_ tab: UUID) {
        for host in Array((windows ?? [:]).keys) {
            guard var record = windows?[host] else { continue }
            for workspace in Array(record.groups.keys) {
                guard var group = record.groups[workspace], group.tabs.contains(tab) else { continue }
                let index = group.tabs.firstIndex(of: tab) ?? 0
                group.tabs.removeAll { $0 == tab }
                if group.selected == tab {
                    group.selected = group.tabs.isEmpty ? nil : group.tabs[min(index, group.tabs.count - 1)]
                }
                record.groups[workspace] = group
            }
            windows?[host] = record
        }
        membership.removeValue(forKey: tab)
        updateLegacyPresentation()
    }

    mutating func select(_ workspace: UUID, in host: UUID) {
        guard var window = windows?[host] else { return }
        if window.currentWorkspace != workspace {
            window.previousWorkspace = window.currentWorkspace
            window.currentWorkspace = workspace
        }
        windows?[host] = window
        updateLegacyPresentation()
    }

    mutating func move(_ tab: UUID, to workspace: UUID, groupID: UUID = UUID()) -> Bool {
        guard workspaces.contains(where: { $0.id == workspace }),
              let old = owner(of: tab), old.workspace != workspace else { return false }
        let group = windows?[old.window]?.groups[workspace]?.id ?? groupID
        remove(tab)
        register(tab, owner: Owner(window: old.window, workspace: workspace, group: group))
        return true
    }

    mutating func deleteWorkspace(_ id: UUID, movingTo destination: UUID? = nil) -> Bool {
        guard workspaces.count > 1, workspaces.contains(where: { $0.id == id }),
              let fallback = destination ?? workspaces.first(where: { $0.id != id })?.id,
              fallback != id, workspaces.contains(where: { $0.id == fallback }) else { return false }
        for host in Array((windows ?? [:]).keys) {
            guard var window = windows?[host] else { continue }
            if let source = window.groups.removeValue(forKey: id) {
                var target = window.groups[fallback] ?? Group(id: source.id)
                target.tabs += source.tabs.filter { !target.tabs.contains($0) }
                if window.currentWorkspace == id, let selected = source.selected { target.selected = selected }
                if target.selected == nil { target.selected = target.tabs.first }
                window.groups[fallback] = target
            }
            if window.currentWorkspace == id { window.currentWorkspace = fallback }
            if window.previousWorkspace == id { window.previousWorkspace = nil }
            windows?[host] = window
        }
        workspaces.removeAll { $0.id == id }
        for tab in Array(membership.keys) where membership[tab] == id { membership[tab] = fallback }
        presentations?.removeValue(forKey: id)
        selectedTabs.removeValue(forKey: id)
        updateLegacyPresentation()
        return true
    }

    /// A diagnostic invariant checker, also used before accepting a checkpoint.
    var validationErrors: [String] {
        let workspaceIDs = Set(workspaces.map(\.id))
        var errors: [String] = []
        var tabs = Set<UUID>()
        var groups = Set<UUID>()
        if workspaces.isEmpty || workspaceIDs.count != workspaces.count { errors.append("workspace identities") }
        for (_, window) in windows ?? [:] {
            if !workspaceIDs.contains(window.currentWorkspace) { errors.append("current workspace") }
            if let previous = window.previousWorkspace, !workspaceIDs.contains(previous) { errors.append("previous workspace") }
            for (workspace, group) in window.groups {
                if !workspaceIDs.contains(workspace) { errors.append("group workspace") }
                if !groups.insert(group.id).inserted { errors.append("duplicate group") }
                if group.tabs.isEmpty != (group.selected == nil) { errors.append("empty selection") }
                if let selected = group.selected, !group.tabs.contains(selected) { errors.append("selection membership") }
                for tab in group.tabs {
                    if !tabs.insert(tab).inserted { errors.append("duplicate tab") }
                    if membership[tab] != workspace { errors.append("membership index") }
                }
            }
        }
        return errors
    }

    mutating func updateLegacyPresentation() {
        hiddenTabs = []
        parkedGroups = [:]
        selectedTabs = [:]
        for (_, window) in windows ?? [:] {
            for (workspace, group) in window.groups {
                for tab in group.tabs { membership[tab] = workspace }
                if window.currentWorkspace != workspace {
                    hiddenTabs.formUnion(group.tabs)
                    parkedGroups?[group.id] = group.tabs
                }
            }
        }
    }
}
