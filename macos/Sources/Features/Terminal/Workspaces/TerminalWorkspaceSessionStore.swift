import AppKit
import Combine

/// The sole checkpoint owner. Version 2 atomically commits the workspace graph
/// and value-only terminal descriptors in one envelope; v1 is migration input.
@MainActor
final class TerminalWorkspaceSessionStore {
    static let shared = TerminalWorkspaceSessionStore()
    struct Tab: Codable, Equatable {
        var id: UUID
        var workspace: UUID
        var state: Data
        var group: UUID?
        var selected: Bool?
        var frame: CGRect?
        var fullscreen: Bool?
        var window: UUID?
    }
    struct Snapshot: Codable, Equatable {
        var version = 1
        var tabs: [Tab] = []
        var generation: UInt64?
        var catalog: TerminalWorkspaceState?
        var explicitlyEmpty: Bool?

        /// Validate an entire generation without constructing any host objects.
        /// Shared by loading and backup rotation so a malformed payload cannot
        /// displace the last recoverable generation.
        var isComplete: Bool {
            guard version == 2, generation != nil, let catalog,
                  catalog.validationErrors.isEmpty else { return false }
            let graphIDs = Set((catalog.windows ?? [:]).values.flatMap { $0.groups.values.flatMap(\.tabs) })
            let recordIDs = Set(tabs.map(\.id))
            guard graphIDs == recordIDs, recordIDs.count == tabs.count,
                  !tabs.isEmpty || explicitlyEmpty == true else { return false }
            var panes = Set<UUID>()
            for tab in tabs {
                guard let owner = catalog.owner(of: tab.id), owner.workspace == tab.workspace,
                      owner.window == tab.window, owner.group == tab.group,
                      let descriptor = try? JSONDecoder().decode(TerminalWorkspaceSessionState.self, from: tab.state),
                      let ids = descriptor.paneIDs, panes.isDisjoint(with: ids) else { return false }
                panes.formUnion(ids)
            }
            return true
        }
    }
    static let restoreSessionsKey = CodingUserInfoKey(rawValue: "omg.workspace.restore-sessions")!
    weak var coordinator: TerminalWorkspaceCoordinator?
    private let url: URL
    private let testing: Bool
    let workspaces: TerminalWorkspaceStore
    private let writer: TerminalWorkspaceSnapshotWriter
    private var saved = Snapshot()
    private var descriptors: [UUID: TerminalWorkspaceSessionState] = [:]
    private var timer: AnyCancellable?
    private var checkpointWork: DispatchWorkItem?
    private var started = false
    private var restoring = false
    private var quitting = false
    private var preparing = false
    private var lastSubmittedCatalog: TerminalWorkspaceState?
    private var contentRevision: UInt64 = 0
    private var submittedContentRevision: UInt64 = 0
    // Exclude only the closing object, not its stable identity. Undo creates a
    // new controller with that ID and immediately becomes checkpointable again.
    private var closing: [UUID: Weak<TerminalController>] = [:]
    private(set) var ownsRestoration = false
    private(set) var recoveryWarnings: [String] = []
    var writeCount: Int { writer.writeCount }

    init(url: URL? = nil, testing: Bool = false, workspaces: TerminalWorkspaceStore? = nil) {
        self.url = url ?? OMGApplicationEnvironment.applicationSupportURL().appendingPathComponent("workspaces/state.json")
        self.testing = testing
        self.workspaces = workspaces ?? .shared
        writer = TerminalWorkspaceSnapshotWriter(url: self.url)
        writer.onCompletion = { [weak self] error in
            guard let self else { return }
            self.workspaces.reportSaveError(error)
            if error != nil { self.lastSubmittedCatalog = nil }
        }
    }

    private var runtime: TerminalWorkspaceCoordinator {
        if let coordinator { return coordinator }
        return .shared
    }

    func prepare() {
        guard testing || !OMGApplicationEnvironment.isRunningTests else { return }
        guard OhMyGhosttySettings.shared.startupMode.restoresTabs else { return }
        preparing = true
        defer { preparing = false }
        let candidates = [url, url.appendingPathExtension("previous"),
            url.deletingLastPathComponent().appendingPathComponent("sessions.json")]
        var visited = Set<URL>()
        for candidate in candidates where visited.insert(candidate).inserted {
            guard let data = try? Data(contentsOf: candidate), data.count <= 32 * 1_024 * 1_024,
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  snapshot.version == 1 || snapshot.version == 2 else { continue }
            let catalog = snapshot.version == 2 ? snapshot.catalog : workspaces.snapshot
            guard let catalog, TerminalWorkspaceStore.isValid(catalog),
                  snapshot.version == 1 || catalog.validationErrors.isEmpty else {
                recoveryWarnings.append("Invalid workspace graph in \(candidate.lastPathComponent)")
                continue
            }
            var decoded: [UUID: TerminalWorkspaceSessionState] = [:]
            var paneIDs = Set<UUID>()
            let tabs = snapshot.tabs.filter { tab in
                guard decoded[tab.id] == nil,
                      let state = try? JSONDecoder().decode(TerminalWorkspaceSessionState.self, from: tab.state),
                      let ids = state.paneIDs, paneIDs.isDisjoint(with: ids) else {
                    recoveryWarnings.append("Skipped invalid or duplicate terminal \(tab.id)")
                    return false
                }
                decoded[tab.id] = state
                paneIDs.formUnion(ids)
                return true
            }
            guard !tabs.isEmpty || (snapshot.version == 2 && snapshot.explicitlyEmpty == true) else { continue }
            if snapshot.version == 2 && !snapshot.isComplete {
                recoveryWarnings.append("Incomplete workspace generation in \(candidate.lastPathComponent)")
                continue
            }
            var next = snapshot
            next.tabs = tabs
            let normalized = snapshot.version == 2 ? catalog : normalize(catalog: catalog, tabs: &next.tabs)
            guard normalized.validationErrors.isEmpty else { continue }
            descriptors = decoded
            next.catalog = normalized
            next.version = 2
            saved = next
            workspaces.restore(normalized)
            ownsRestoration = true
            break
        }
    }

    /// Repairs only legacy input or explicitly quarantined records. It never
    /// reads native windows. Unknown workspace references go to the default.
    private func normalize(catalog: TerminalWorkspaceState, tabs: inout [Tab]) -> TerminalWorkspaceState {
        var state = catalog
        let known = Set(state.workspaces.map(\.id))
        let validTabs = Set(tabs.map(\.id))
        state.membership = [:]
        var windows: [UUID: TerminalWorkspaceState.Window] = [:]
        var groupOwners: [UUID: String] = [:]
        for index in tabs.indices {
            if !known.contains(tabs[index].workspace) {
                recoveryWarnings.append("Recovered unknown workspace for \(tabs[index].id)")
                tabs[index].workspace = state.defaultID
            }
            let tab = tabs[index]
            let host = tab.window ?? tab.group ?? tab.workspace
            let workspace = tab.workspace
            var window = windows[host] ?? catalog.windows?[host] ?? .init(currentWorkspace: workspace)
            if windows[host] == nil { window.groups = [:] }
            if !known.contains(window.currentWorkspace) { window.currentWorkspace = workspace }
            if let previous = window.previousWorkspace, !known.contains(previous) { window.previousWorkspace = nil }
            let original = catalog.windows?[host]?.groups[workspace]
            var group = window.groups[workspace] ?? .init(id: original?.id ?? tab.group ?? UUID(), scrollOffset: original?.scrollOffset)
            let key = host.uuidString + workspace.uuidString
            if let owner = groupOwners[group.id], owner != key { group.id = UUID() }
            groupOwners[group.id] = key
            group.tabs.append(tab.id)
            if tab.selected == true { group.selected = tab.id }
            if let selected = original?.selected, group.tabs.contains(selected) { group.selected = selected }
            if group.selected == nil { group.selected = group.tabs.first }
            window.groups[workspace] = group
            window.frame = window.frame ?? tab.frame
            window.fullscreen = window.fullscreen ?? tab.fullscreen
            windows[host] = window
            state.membership[tab.id] = workspace
            tabs[index].window = host
            tabs[index].group = group.id
        }
        for host in Array(windows.keys) {
            guard var window = windows[host] else { continue }
            for workspace in Array(window.groups.keys) {
                guard var group = window.groups[workspace] else { continue }
                let original = catalog.windows?[host]?.groups[workspace]
                let order = original?.tabs.filter { group.tabs.contains($0) && validTabs.contains($0) } ?? []
                group.tabs = order + group.tabs.filter { !order.contains($0) }
                if let selected = original?.selected, group.tabs.contains(selected) { group.selected = selected }
                window.groups[workspace] = group
            }
            if window.groups[window.currentWorkspace] == nil {
                window.currentWorkspace = state.workspaces.first { window.groups[$0.id] != nil }?.id ?? state.defaultID
            }
            windows[host] = window
        }
        state.windows = windows
        state.updateLegacyPresentation()
        return state
    }

    func start(_ app: Ghostty.App) {
        guard testing || !OMGApplicationEnvironment.isRunningTests else { return }
        if !testing { TerminalWorkspaceCoordinator.shared.useSessions(self) }
        restoring = true
        if ownsRestoration {
            let transaction = TerminalWorkspacePresentationTransaction([])
            let restoreSessions = SessionRuntimeRestorationPolicy.attachesSavedRuntime(
                for: OhMyGhosttySettings.shared.startupMode
            )
            for tab in saved.tabs { _ = restore(tab, app: app, restoreSessions: restoreSessions) }
            // Assembly uses the same checked native adapter as runtime handoff.
            let catalog = workspaces.snapshot
            var groups: [TerminalWorkspaceNativeAdapter.Group] = []
            for host in (catalog.windows ?? [:]).keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let record = catalog.windows?[host] else { continue }
                for workspace in catalog.workspaces {
                    guard let group = record.groups[workspace.id] else { continue }
                    let members = group.tabs.compactMap { id in runtime.liveControllers.first { $0.tabSessionID == id } }
                    guard let selected = members.first(where: { $0.tabSessionID == group.selected }) ?? members.first else { continue }
                    let layout = selected.tabLayoutState
                    layout.bindWorkspace(workspace.id, store: workspaces)
                    let tabLayout = record.tabLayout.flatMap(Ghostty.Config.MacOSTabLayout.init(rawValue:))
                        ?? selected.tabLayout
                    let visible = record.currentWorkspace == workspace.id
                    for member in members { member.workspacePresentationIsParked = !visible; member.tabLayoutState = layout }
                    if let frame = record.frame { selected.window?.setFrame(frame, display: false); selected.window?.constrainToScreen() }
                    groups.append(.init(members: members, selected: selected, tabLayout: tabLayout,
                        visible: visible, layout: layout, scrollOffset: group.scrollOffset))
                }
            }
            if !runtime.native.apply(groups, previous: [], focus: groups.first(where: \.visible)?.selected) {
                recoveryWarnings.append("Native window grouping could not be restored")
                workspaces.reportSaveError(WorkspaceL10n.text("Some restored windows could not be grouped.", "部分恢复窗口无法组成标签组。"))
            }
            transaction.publish { runtime.native.publish(groups) }
            for group in groups where group.visible {
                let selected = group.selected
                guard catalog.windows?[selected.windowSessionID]?.fullscreen == true else { continue }
                let mode = catalog.windows?[selected.windowSessionID]?.fullscreenMode ?? .native
                let generation = selected.workspacePresentationGeneration
                DispatchQueue.main.async { [weak selected] in
                    guard let selected,
                          selected.workspacePresentationGeneration == generation,
                          selected.isAvailableForWorkspace, !selected.workspacePresentationIsParked,
                          selected.workspaceCoordinator.store.snapshot.windows?[selected.windowSessionID]?.currentWorkspace == selected.workspaceID,
                          let window = selected.window, window.isVisible,
                          selected.fullscreenStyle?.isFullscreen != true,
                          !window.styleMask.contains(.fullScreen) else { return }
                    selected.toggleFullscreen(mode: mode)
                }
            }
        }
        restoring = false
        started = true
        workspaces.flush()
        workspaces.checkpointRequested = { [weak self] in self?.scheduleCapture() }
        if ownsRestoration, runtime.liveControllers.isEmpty {
            _ = TerminalController.newWindow(app)
        }
        capture()
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.capture() }
    }

    func restoreWorkspace(_ id: UUID, window: UUID, group: UUID?, app: Ghostty.App, parent: NSWindow?) -> [TerminalController] {
        let wasRestoring = restoring
        restoring = true
        defer { restoring = wasRestoring }
        let ids = workspaces.group(window: window, workspace: id)?.tabs ?? []
        let records = saved.tabs.filter { ids.contains($0.id) && closing[$0.id]?.value == nil }
        return records.sorted { (ids.firstIndex(of: $0.id) ?? 0) < (ids.firstIndex(of: $1.id) ?? 0) }
            .compactMap { restore($0, app: app, parent: parent, restoreSessions: true) }
    }

    private func restore(
        _ tab: Tab,
        app: Ghostty.App,
        parent: NSWindow? = nil,
        restoreSessions: Bool
    ) -> TerminalController? {
        guard !runtime.liveControllers.contains(where: { $0.tabSessionID == tab.id }),
              let owner = workspaces.snapshot.owner(of: tab.id),
              let descriptor = descriptors[tab.id],
              let state = try? descriptor.instantiate(restoreSessions: restoreSessions) else { return nil }
        let controller = TerminalController(app, withSurfaceTree: state.surfaceTree, parent: parent,
            tabLayout: (parent?.windowController as? TerminalController)?.tabLayout,
            tabSessionID: tab.id, tabCreatedAt: state.tabCreatedAt, workspaceID: owner.workspace,
            windowSessionID: owner.window, workspaceGroupID: owner.group, workspaceCoordinator: runtime)
        controller.titleOverride = state.titleOverride
        if let focused = state.focusedSurface { controller.focusedSurface = controller.surfaceTree.first { $0.id.uuidString == focused } }
        guard let window = controller.window else { return nil }
        if parent == nil, let frame = tab.frame { window.setFrame(frame, display: false); window.constrainToScreen() }
        (window as? TerminalWindow)?.tabColor = state.tabColor ?? .none
        controller.cancelWorkspacePendingPresentation()
        return controller
    }

    func didRegister(_ controller: TerminalController) {
        if closing[controller.tabSessionID]?.value !== controller { closing.removeValue(forKey: controller.tabSessionID) }
    }

    func prepareToQuit() {
        guard started, !quitting else { return }
        if !testing || coordinator != nil { runtime.prepareToQuit() }
        capture()
        quitting = true
        flush()
    }
    func cancelQuit() {
        quitting = false
        if !testing || coordinator != nil { runtime.cancelQuit() }
        capture()
    }

    func forget(_ controller: TerminalController) {
        guard !quitting else { return }
        closing[controller.tabSessionID] = Weak(controller)
        descriptors.removeValue(forKey: controller.tabSessionID)
        saved.tabs.removeAll { $0.id == controller.tabSessionID }
        workspaces.transaction { $0.remove(controller.tabSessionID) }
        capture()
    }

    private func scheduleCapture() {
        guard checkpointWork == nil, !preparing, !quitting else { return }
        let work = DispatchWorkItem { [weak self] in self?.checkpointWork = nil; self?.capture() }
        checkpointWork = work
        DispatchQueue.main.async(execute: work)
    }

    func capture() {
        guard started, !restoring, !quitting, !runtime.isChanging, !TerminalWorkspacePresentation.isChanging else { return }
        closing = closing.filter { $0.value.value != nil }
        var records = Dictionary(uniqueKeysWithValues: saved.tabs.map { ($0.id, $0) })
        let catalog = workspaces.snapshot
        for controller in runtime.liveControllers where closing[controller.tabSessionID]?.value !== controller {
            guard catalog.owner(of: controller.tabSessionID) != nil else { continue }
            let descriptor = TerminalWorkspaceSessionState(controller)
            guard descriptor.paneIDs != nil else { continue }
            if descriptors[controller.tabSessionID] != descriptor || records[controller.tabSessionID] == nil {
                descriptors[controller.tabSessionID] = descriptor
                if records[controller.tabSessionID] == nil {
                    records[controller.tabSessionID] = Tab(id: controller.tabSessionID, workspace: controller.workspaceID, state: Data())
                }
                contentRevision &+= 1
            }
        }
        guard catalog != lastSubmittedCatalog || contentRevision != submittedContentRevision else { return }
        var tabs: [Tab] = []
        for host in (catalog.windows ?? [:]).keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let window = catalog.windows?[host] else { continue }
            for workspace in catalog.workspaces {
                guard let group = window.groups[workspace.id] else { continue }
                for id in group.tabs {
                    guard var tab = records[id], closing[id]?.value == nil || closing[id]?.value !== runtime.liveControllers.first(where: { $0.tabSessionID == id }) else { continue }
                    tab.workspace = workspace.id
                    tab.window = host
                    tab.group = group.id
                    tab.selected = group.selected == id
                    tab.frame = window.frame
                    tab.fullscreen = window.fullscreen
                    tabs.append(tab)
                }
            }
        }
        // Persist only records with a pure descriptor. No half-created terminal
        // can make the durable graph reference a nonexistent session payload.
        var durable = catalog
        let included = Set(tabs.map(\.id))
        for tab in catalog.membership.keys where !included.contains(tab) { durable.remove(tab) }
        guard durable.validationErrors.isEmpty else { return }
        let next = Snapshot(version: 2, tabs: tabs, generation: saved.generation ?? 0,
            catalog: durable, explicitlyEmpty: tabs.isEmpty)
        guard next != saved || contentRevision != submittedContentRevision || lastSubmittedCatalog == nil else { return }
        saved = next
        saved.generation = (saved.generation ?? 0) &+ 1
        lastSubmittedCatalog = catalog
        submittedContentRevision = contentRevision
        writer.submit(saved, descriptors: descriptors)
        if testing { flush() }
    }

    func flush() {
        writer.flush()
        workspaces.reportSaveError(writer.lastError)
        if writer.lastError != nil { lastSubmittedCatalog = nil }
    }
}
