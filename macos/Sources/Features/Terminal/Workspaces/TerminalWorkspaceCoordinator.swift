import AppKit
import Combine
import GhosttyKit

@MainActor
enum TerminalWorkspacePresentation {
    private static var depth = 0
    static var isChanging: Bool { depth > 0 }
    static func begin() { depth += 1 }
    static func end() { precondition(depth > 0); depth -= 1 }
}

/// Owns commands and the live registry. All ownership/order lives in store's
/// committed graph; Controller fields and native groups are adapter projections.
@MainActor
final class TerminalWorkspaceCoordinator: ObservableObject {
    static let shared = TerminalWorkspaceCoordinator()
    @Published private(set) var revision = 0
    @Published private(set) var operationError: String?
    private var registry: [UUID: Weak<TerminalController>] = [:]
    private var retainedParked: [UUID: TerminalController] = [:]
    private var draft: TerminalWorkspaceState?
    private var restoring = true
    private var quitting = false
    private var applying = false
    private var deferredSwitches: [UUID: UUID] = [:]
    enum SwitchOutcome: Equatable { case committed, superseded, failed }
    private var deferredSwitchCompletions: [UUID: (SwitchOutcome) -> Void] = [:]
    private var deferredTabLayouts: [UUID: Ghostty.Config.MacOSTabLayout] = [:]
    let store: TerminalWorkspaceStore
    let native: TerminalWorkspaceNativeAdapter
    private var suppliedSessions: TerminalWorkspaceSessionStore?
    private let usesSharedSessions: Bool
    var sessions: TerminalWorkspaceSessionStore {
        if let suppliedSessions { return suppliedSessions }
        if usesSharedSessions { return .shared }
        let isolated = TerminalWorkspaceSessionStore(testing: false, workspaces: store)
        isolated.coordinator = self
        suppliedSessions = isolated
        return isolated
    }
    var isChanging: Bool { applying }
    var parked: [UUID: TerminalController] { retainedParked }
    var liveControllers: [TerminalController] {
        registry.values.compactMap(\.value).filter(\.isAvailableForWorkspace)
    }

    init(store: TerminalWorkspaceStore? = nil, sessions: TerminalWorkspaceSessionStore? = nil,
         native: TerminalWorkspaceNativeAdapter? = nil) {
        self.usesSharedSessions = store == nil && sessions == nil
        self.store = store ?? .shared
        self.suppliedSessions = sessions
        self.native = native ?? TerminalWorkspaceNativeAdapter()
        sessions?.coordinator = self
        self.native.transitionCompleted = { [weak self] host in
            guard let self else { return }
            let completion = self.deferredSwitchCompletions.removeValue(forKey: host)
            if let target = self.deferredSwitches.removeValue(forKey: host),
               let record = self.store.snapshot.windows?[host],
               let selected = record.groups[record.currentWorkspace]?.selected,
               let source = self.liveControllers.first(where: { $0.tabSessionID == selected }) {
                let targetController = self.switchWorkspace(to: target, from: source)
                completion?(targetController == nil ? .failed : .committed)
            } else {
                completion?(.superseded)
            }
            if let mode = self.deferredTabLayouts.removeValue(forKey: host),
               let source = self.liveControllers.first(where: { $0.windowSessionID == host }) {
                self.requestTabLayout(mode, from: source)
            }
            for controller in self.liveControllers where controller.windowSessionID == host &&
                !controller.workspacePresentationIsParked { controller.finishWorkspacePresentation() }
            self.savePresentation()
        }
    }

    func useSessions(_ sessions: TerminalWorkspaceSessionStore) {
        suppliedSessions = sessions
        sessions.coordinator = self
    }

    func requestTabLayout(_ mode: Ghostty.Config.MacOSTabLayout, from source: TerminalController) {
        let host = source.windowSessionID
        guard source.isAvailableForWorkspace, !quitting else { return }
        if applying || native.transitioningWindows.contains(host) {
            deferredTabLayouts[host] = mode
            return
        }
        deferredTabLayouts.removeValue(forKey: host)
        store.transaction { $0.windows?[host]?.tabLayout = mode.rawValue }
        let members = liveControllers.filter { $0.windowSessionID == host }
        guard members.contains(where: { $0.tabLayout != mode }) else { sessions.capture(); return }
        for member in members where member.tabLayout != mode {
            if member.workspaceSwitcherIsPresented { member.workspacePopover.close() }
            member.adoptTabLayout(mode)
        }
        var states = Set<ObjectIdentifier>()
        for member in members {
            if mode == .vertical, states.insert(ObjectIdentifier(member.tabLayoutState)).inserted {
                member.tabLayoutState.setSidebarVisible(true)
            }
            (member.window as? TerminalWindow)?.installOMGTabChrome(controller: member)
            member.window?.contentView?.needsLayout = true
            member.window?.invalidateRestorableState()
        }
        source.finishWorkspacePresentation()
        sessions.capture()
    }

    func tabLayout(in host: UUID, fallback: Ghostty.Config.MacOSTabLayout) -> Ghostty.Config.MacOSTabLayout {
        store.snapshot.windows?[host]?.tabLayout.flatMap(Ghostty.Config.MacOSTabLayout.init(rawValue:)) ?? fallback
    }

    func controllers(in id: UUID) -> [TerminalController] {
        orderedControllers(state: store.snapshot).filter { store.snapshot.owner(of: $0.tabSessionID)?.workspace == id }
    }

    func register(_ controller: TerminalController) {
        registry[controller.tabSessionID] = Weak(controller)
        sessions.didRegister(controller)
        let owner = TerminalWorkspaceState.Owner(window: controller.windowSessionID,
            workspace: controller.workspaceID, group: controller.workspaceGroupID)
        if draft != nil {
            if draft?.owner(of: controller.tabSessionID) == nil { draft?.register(controller.tabSessionID, owner: owner) }
        } else {
            store.transaction {
                if $0.owner(of: controller.tabSessionID) == nil { $0.register(controller.tabSessionID, owner: owner) }
                if $0.windows?[owner.window]?.tabLayout == nil {
                    $0.windows?[owner.window]?.tabLayout = controller.tabLayout.rawValue
                }
            }
        }
    }

    /// Used by migration/tests to explicitly transfer a host object to a runtime.
    /// Normal controllers receive their runtime at construction.
    func adopt(_ controller: TerminalController) {
        guard controller.workspaceCoordinator !== self else { return }
        controller.workspaceCoordinator.registry.removeValue(forKey: controller.tabSessionID)
        controller.workspaceCoordinator.retainedParked.removeValue(forKey: controller.tabSessionID)
        controller.workspaceCoordinator = self
        register(controller)
        controller.tabLayoutState.bindWorkspace(controller.workspaceID, store: store)
    }

    /// The incoming window is built before catalog commit. Presentation must
    /// resolve against that same transaction, never substitute the default label.
    func presentationWorkspace(_ id: UUID) -> TerminalWorkspace? {
        (draft ?? store.snapshot).workspaces.first { $0.id == id }
    }

    func workspaceID(for tab: UUID, inheriting parent: UUID?) -> UUID {
        let state = draft ?? store.snapshot
        let id = state.membership[tab] ?? parent ?? state.defaultID
        return state.workspaces.contains { $0.id == id } ? id : state.defaultID
    }

    func previousWorkspaceID(in controller: TerminalController) -> UUID? {
        store.snapshot.windows?[controller.windowSessionID]?.previousWorkspace
    }

    /// Native user joins/detaches/reorders enter the model only at this boundary.
    /// A command's temporary mixed native group can never become authoritative.
    func reconcileNativeGroup(_ members: [TerminalController]) {
        guard !quitting, !applying, !TerminalWorkspacePresentation.isChanging, let first = members.first,
              members.allSatisfy({ $0.workspaceCoordinator === self && !$0.workspacePresentationIsParked }),
              !hasNonNativeFullscreen(in: first.windowSessionID) else { return }
        let nativeGroup = first.window?.tabGroup
        let anchor = members.first { $0.tabLayoutState.nativeTabGroup === nativeGroup } ?? first
        if members.count == 1, anchor.workspaceTabAttachmentIsPending { return }
        var host = anchor.windowSessionID
        var groupID = anchor.workspaceGroupID
        let ids = Set(members.map(\.tabSessionID))
        if let old = anchor.tabLayoutState.nativeTabGroup, old !== nativeGroup,
           old.windows.contains(where: {
               guard let other = $0.windowController as? TerminalController else { return false }
               return other.isAvailableForWorkspace && !other.workspacePresentationIsParked &&
                   other.workspaceGroupID == groupID && !ids.contains(other.tabSessionID)
           }) {
            host = UUID()
            groupID = UUID()
        }
        // A singleton may lose its old AppKit association before refresh runs.
        // The committed group still provides the split boundary in that case.
        if !restoring, members.count == 1, !anchor.workspaceTabAttachmentIsPending,
           let owner = store.snapshot.owner(of: anchor.tabSessionID),
           let original = store.group(window: owner.window, workspace: owner.workspace),
           original.tabs.contains(where: { id in
               guard id != anchor.tabSessionID, let sibling = registry[id]?.value else { return false }
               return sibling.isAvailableForWorkspace && !sibling.workspacePresentationIsParked &&
                   sibling.window?.tabGroup !== nativeGroup
           }) {
            host = UUID()
            groupID = UUID()
        }
        let selected = (nativeGroup?.selectedWindow?.windowController as? TerminalController)?.tabSessionID
        store.transaction { state in
            for member in members {
                state.register(member.tabSessionID, owner: .init(window: host, workspace: anchor.workspaceID, group: groupID))
            }
            var group = state.windows?[host]?.groups[anchor.workspaceID] ?? .init(id: groupID)
            // Suspended records stay restorable, but are not part of the live
            // native order. Preserve them behind live members until restored.
            let suspended = group.tabs.filter { !ids.contains($0) && registry[$0]?.value?.isAvailableForWorkspace != true }
            group.tabs = members.map(\.tabSessionID) + suspended
            group.selected = selected.flatMap { group.tabs.contains($0) ? $0 : nil } ?? group.selected ?? group.tabs.first
            group.scrollOffset = anchor.tabLayoutState.sidebarHost.scrollOffset ?? group.scrollOffset
            state.windows?[host]?.groups[anchor.workspaceID] = group
            state.updateLegacyPresentation()
        }
        projectIdentities(store.snapshot, controllers: members)
        let mode = tabLayout(in: host, fallback: anchor.tabLayout)
        for member in members where member.tabLayout != mode {
            member.adoptTabLayout(mode)
            (member.window as? TerminalWindow)?.installOMGTabChrome(controller: member)
        }
    }

    func didActivate(_ controller: TerminalController) {
        guard !applying, !restoring, !quitting, controller.isAvailableForWorkspace,
              controller.window?.isVisible == true else { return }
        if store.snapshot.isParked(controller.tabSessionID) {
            if let current = liveControllers.first(where: {
                $0.windowSessionID == controller.windowSessionID && !store.snapshot.isParked($0.tabSessionID)
            }) {
                _ = switchWorkspace(to: controller.workspaceID, from: current)
                return
            }
            _ = perform(hosts: [controller.windowSessionID], focus: controller) { state in
                state.select(controller.workspaceID, in: controller.windowSessionID)
                return true
            }
            return
        }
        if hasNonNativeFullscreen(in: controller.windowSessionID),
           store.group(window: controller.windowSessionID, workspace: controller.workspaceID)?.selected != controller.tabSessionID {
            _ = selectNonNativeTab(controller)
            return
        }
        let members = nativeMembers(controller)
        reconcileNativeGroup(members)
        store.transaction { state in
            state.windows?[controller.windowSessionID]?.groups[controller.workspaceID]?.selected = controller.tabSessionID
            state.select(controller.workspaceID, in: controller.windowSessionID)
        }
        savePresentation()
    }

    func didClose(_ controller: TerminalController) {
        guard !quitting, !applying else { return }
        registry.removeValue(forKey: controller.tabSessionID)
        retainedParked.removeValue(forKey: controller.tabSessionID)
        let host = controller.windowSessionID
        if !liveControllers.contains(where: { $0.windowSessionID == host && !$0.workspacePresentationIsParked }) {
            deferredSwitches.removeValue(forKey: host)
            deferredTabLayouts.removeValue(forKey: host)
            deferredSwitchCompletions.removeValue(forKey: host)?(.superseded)
        }
        revision &+= 1
        if !restoring { sessions.capture() }
    }

    func forget(_ controller: TerminalController) {
        guard !quitting else { return }
        sessions.forget(controller)
        store.transaction { $0.remove(controller.tabSessionID) }
    }

    func handle(_ event: NSEvent, in controller: TerminalController) -> Bool {
        guard controller.window?.attachedSheet == nil,
              (controller.window?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
        for slot in 0...min(9, store.workspaces.count) {
            guard let shortcut = OMGKeyboardShortcut(storageValue: store.shortcut(slot: slot)), shortcut.matches(event) else { continue }
            if slot == 0 { controller.workspaceSwitcherIsPresented.toggle() } else {
                switchWorkspace(to: store.workspaces[slot - 1].id, from: controller)
            }
            return true
        }
        return false
    }

    @discardableResult
    func createWorkspace(name: String, symbol: String, color: String, from source: TerminalController) -> TerminalController? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, store.workspaces.count < 100,
              TerminalWorkspace.symbols.contains(symbol), TerminalWorkspace.colors.contains(color) else {
            operationError = WorkspaceL10n.text("Enter a name of up to 40 characters; at most 100 workspaces are supported.",
                "请输入不超过 40 个字符的名称；最多支持 100 个工作区。")
            return nil
        }
        let workspace = TerminalWorkspace(id: UUID(), name: name, symbol: symbol, color: color)
        return switchWorkspace(to: workspace.id, from: source, creating: workspace)
    }

    @discardableResult
    func switchWorkspace(to id: UUID, from source: TerminalController) -> TerminalController? {
        switchWorkspace(to: id, from: source, creating: nil)
    }

    /// Management UI waits for the committed result rather than treating a queued request as failure.
    func requestWorkspaceSwitch(to id: UUID, from source: TerminalController,
                                completion: @escaping (SwitchOutcome) -> Void) {
        if switchWorkspace(to: id, from: source) != nil {
            completion(.committed)
        } else if source.isAvailableForWorkspace,
                  native.transitioningWindows.contains(source.windowSessionID),
                  deferredSwitches[source.windowSessionID] == id {
            deferredSwitchCompletions[source.windowSessionID] = completion
            operationError = nil
        } else {
            completion(.failed)
        }
    }

    private func switchWorkspace(to id: UUID, from source: TerminalController,
                                 creating: TerminalWorkspace?) -> TerminalController? {
        guard creating != nil || store.workspaces.contains(where: { $0.id == id }), !quitting, !applying,
              source.isAvailableForWorkspace else {
            operationError = WorkspaceL10n.text("The workspace could not be opened. Try again after the current operation.", "当前无法打开工作区，请等待当前操作完成后重试。")
            return nil
        }
        adopt(source)
        source.workspaceSwitcherIsPresented = false
        source.workspacePopover.close()
        // Every new valid request supersedes the older intent for this host,
        // including "stay here" and requests arriving before a queued drain.
        deferredSwitches.removeValue(forKey: source.windowSessionID)
        deferredSwitchCompletions.removeValue(forKey: source.windowSessionID)?(.superseded)
        if source.workspaceID == id {
            operationError = nil
            return source
        }
        if native.transitioningWindows.contains(source.windowSessionID) {
            if creating == nil { deferredSwitches[source.windowSessionID] = id }
            operationError = WorkspaceL10n.text("The window is changing fullscreen mode. Try again when it finishes.", "窗口正在切换全屏状态，请完成后重试。")
            return nil
        }
        reconcileNativeGroup(nativeMembers(source))
        let host = source.windowSessionID
        var destination: TerminalController?
        let success = perform(hosts: [host], focus: source, desiredFocus: { destination }, change: { state in
            if let creating {
                state.workspaces.append(creating)
                self.draft = state
            }
            let group = state.windows?[host]?.groups[id]
            self.restoreMissing(workspace: id, host: host, app: source.ghostty, parent: source.window)
            state = self.draft ?? state
            let members = self.members(host: host, workspace: id, state: state)
            destination = members.first { $0.tabSessionID == group?.selected } ?? members.first
            if destination == nil {
                destination = TerminalController(source.ghostty, withBaseConfig: self.localShellConfiguration(from: source),
                    parent: source.window, tabLayout: source.tabLayout,
                    workspaceID: id, windowSessionID: host, workspaceGroupID: group?.id, workspaceCoordinator: self)
                destination?.isBackgroundOpaque = source.isBackgroundOpaque
                _ = destination?.window
                state = self.draft ?? state
            }
            guard let destination, destination.isAvailableForWorkspace else { return false }
            state.windows?[host]?.groups[id]?.selected = destination.tabSessionID
            state.select(id, in: host)
            return true
        })
        return success ? destination : nil
    }

    @discardableResult
    func move(_ controller: TerminalController, to id: UUID, replacingLastTab: Bool = true) -> Bool {
        guard !quitting, !applying, controller.workspaceID != id,
              store.workspaces.contains(where: { $0.id == id }) else { return false }
        adopt(controller)
        if !store.snapshot.isParked(controller.tabSessionID) { reconcileNativeGroup(nativeMembers(controller)) }
        let host = controller.windowSessionID
        let sourceWorkspace = controller.workspaceID
        let sourceGroup = controller.workspaceGroupID
        var focus: TerminalController? = liveControllers.first { $0.window?.isKeyWindow == true }
        return perform(hosts: [host], focus: focus, desiredFocus: { focus }, change: { state in
            self.restoreMissing(workspace: id, host: host, app: controller.ghostty, parent: nil)
            state = self.draft ?? state
            guard state.move(controller.tabSessionID, to: id) else { return false }
            self.draft = state
            if state.windows?[host]?.currentWorkspace == sourceWorkspace {
                let remaining = self.members(host: host, workspace: sourceWorkspace, state: state)
                if remaining.isEmpty && replacingLastTab {
                    let replacement = TerminalController(controller.ghostty, withBaseConfig: self.localShellConfiguration(from: controller),
                        parent: controller.window, tabLayout: controller.tabLayout, workspaceID: sourceWorkspace, windowSessionID: host,
                        workspaceGroupID: sourceGroup, workspaceCoordinator: self)
                    _ = replacement.window
                    state = self.draft ?? state
                    focus = replacement
                } else { focus = remaining.first }
            }
            return true
        })
    }

    @discardableResult
    func deleteWorkspace(_ id: UUID, from source: TerminalController? = nil) -> Bool {
        let focus = source ?? liveControllers.first { $0.window?.isKeyWindow == true }
        let current = focus?.workspaceID
        guard !quitting, !applying, store.workspaces.count > 1,
              store.workspaces.contains(where: { $0.id == id }) else { return false }
        guard current != id else {
            operationError = WorkspaceL10n.text("Switch to another workspace before deleting this one.", "请先切换到其他工作区，再删除此工作区。")
            return false
        }
        let fallback = current ?? store.workspaces.first(where: { $0.id != id })!.id
        let hosts = Set((store.snapshot.windows ?? [:]).filter { $0.value.groups[id] != nil }.map(\.key))
        return perform(hosts: hosts, focus: focus) { state in state.deleteWorkspace(id, movingTo: fallback) }
    }

    /// Build the entire next graph before touching native ownership. Every host
    /// affected by delete/move is preflighted before the first native mutation.
    private func perform(hosts: Set<UUID>, focus: TerminalController?,
                         desiredFocus: (() -> TerminalController?)? = nil,
                         change: (inout TerminalWorkspaceState) -> Bool) -> Bool {
        guard !applying else { return false }
        let before = store.snapshot
        let previous = groups(state: before, hosts: hosts)
        let existing = Set(registry.keys)
        if let error = native.preflightError(previous.flatMap(\.members)) {
            operationError = error
            return false
        }
        applying = true
        draft = before
        let transaction = TerminalWorkspacePresentationTransaction(previous.flatMap(\.members))
        var next = before
        var succeeded = change(&next)
        draft = next
        let proposed = groups(state: next, hosts: hosts)
        let preflightError = native.preflightError(proposed.flatMap(\.members))
        succeeded = succeeded && next.validationErrors.isEmpty && preflightError == nil
        if succeeded { succeeded = native.apply(proposed, previous: previous, focus: desiredFocus?() ?? focus) }
        if succeeded {
            projectIdentities(next, controllers: proposed.flatMap(\.members))
            for group in proposed where group.visible {
                let host = group.selected.windowSessionID
                next.windows?[host]?.frame = group.selected.window?.frame
                next.windows?[host]?.fullscreen = group.selected.fullscreenStyle?.isFullscreen == true
                next.windows?[host]?.fullscreenMode = group.selected.fullscreenStyle?.isFullscreen == true
                    ? group.selected.fullscreenStyle?.fullscreenMode : nil
            }
            store.commit(next)
            operationError = nil
        } else {
            operationError = preflightError ?? WorkspaceL10n.text("The window could not display the workspace. Your previous workspace is retained.",
                "窗口未能显示该工作区，原工作区已保留。")
            if !native.rollback(previous, attempted: proposed, focus: focus) {
                operationError = WorkspaceL10n.text("Could not restore the window arrangement. Your sessions are retained.",
                    "无法恢复窗口布局，会话仍然保留。")
            }
            for id in Set(registry.keys).subtracting(existing) {
                let controller = registry.removeValue(forKey: id)?.value
                controller?.cancelWorkspacePendingPresentation()
                controller?.window?.close()
            }
            projectIdentities(before, controllers: previous.flatMap(\.members))
        }
        draft = nil
        // Keep command echo notifications suppressed while native snapshots and
        // first frames are published. The adapter alone performs the projection.
        let finalGroups = succeeded ? proposed : previous
        for group in finalGroups {
            for controller in group.members { controller.workspacePresentationIsParked = !group.visible }
        }
        transaction.publish { native.publish(finalGroups) }
        applying = false
        updateRetention()
        revision &+= 1
        sessions.capture()
        for host in hosts where !native.transitioningWindows.contains(host) {
            if let mode = deferredTabLayouts.removeValue(forKey: host),
               let source = liveControllers.first(where: { $0.windowSessionID == host && !$0.workspacePresentationIsParked }) {
                requestTabLayout(mode, from: source)
            }
        }
        return succeeded
    }

    /// Use the host's existing new-tab configuration contract. Besides keeping
    /// SSH/runtime directories local, this supplies launch metadata before OSC
    /// title/cwd events arrive, so the first row need not flash a generic title.
    private func localShellConfiguration(from source: TerminalController) -> Ghostty.SurfaceConfiguration? {
        guard let pane = source.focusedSurface ?? source.surfaceTree.first,
              let surface = pane.surface else { return nil }
        return source.tabConfiguration(inherited: .init(from: ghostty_surface_inherited_config(
            surface, GHOSTTY_SURFACE_CONTEXT_TAB)), from: pane)
    }

    func hasNonNativeFullscreen(in host: UUID) -> Bool {
        liveControllers.contains { $0.windowSessionID == host && $0.fullscreenStyle?.isFullscreen == true &&
            $0.fullscreenStyle?.supportsTabs == false }
    }

    /// Borderless fullscreen temporarily detaches the selected native tab. Its
    /// logical group remains complete and continues to drive the sidebar.
    @discardableResult
    func projectNonNativeTabs(for controller: TerminalController) -> Bool {
        // exit() restores key status before fullscreenDidChange reattaches the
        // native group. Keep its complete logical membership during that gap;
        // otherwise windowDidBecomeKey commits the temporary singleton.
        guard hasNonNativeFullscreen(in: controller.windowSessionID) ||
                native.nonNativeProjectionWindows.contains(controller.windowSessionID),
              let group = store.group(window: controller.windowSessionID, workspace: controller.workspaceID) else { return false }
        let members = members(host: controller.windowSessionID, workspace: controller.workspaceID, state: store.snapshot)
        let selected = members.first { $0.tabSessionID == group.selected } ?? controller
        for member in members {
            member.tabLayoutState = selected.tabLayoutState
            member.applyWorkspaceTabProjection(members, selected: selected)
        }
        selected.tabLayoutState.sidebarHost.presentSelectedWindow()
        return true
    }

    @discardableResult
    func selectNonNativeTab(_ controller: TerminalController) -> Bool {
        guard hasNonNativeFullscreen(in: controller.windowSessionID) else { return false }
        return perform(hosts: [controller.windowSessionID], focus: controller) { state in
            state.windows?[controller.windowSessionID]?.groups[controller.workspaceID]?.selected = controller.tabSessionID
            return true
        }
    }

    func fullscreenDidChange(_ controller: TerminalController) {
        guard !applying, !restoring, !quitting else { return }
        if hasNonNativeFullscreen(in: controller.windowSessionID) {
            native.beginNonNativeProjection(in: controller.windowSessionID)
            for member in members(host: controller.windowSessionID, workspace: controller.workspaceID, state: store.snapshot)
                where member !== controller { member.window?.orderOut(nil) }
            _ = projectNonNativeTabs(for: controller)
        } else if native.nonNativeProjectionWindows.contains(controller.windowSessionID) {
            native.finishNonNativeProjection(in: controller.windowSessionID)
            _ = perform(hosts: [controller.windowSessionID], focus: controller) { _ in true }
        }
        savePresentation()
    }

    private func restoreMissing(workspace: UUID, host: UUID, app: Ghostty.App, parent: NSWindow?) {
        _ = sessions.restoreWorkspace(workspace, window: host,
            group: (draft ?? store.snapshot).windows?[host]?.groups[workspace]?.id,
            app: app, parent: parent)
    }

    private func members(host: UUID, workspace: UUID, state: TerminalWorkspaceState) -> [TerminalController] {
        (state.windows?[host]?.groups[workspace]?.tabs ?? []).compactMap { registry[$0]?.value }.filter(\.isAvailableForWorkspace)
    }

    private func orderedControllers(state: TerminalWorkspaceState) -> [TerminalController] {
        (state.windows ?? [:]).keys.sorted { $0.uuidString < $1.uuidString }.flatMap { host in
            state.workspaces.flatMap { members(host: host, workspace: $0.id, state: state) }
        }
    }

    private func groups(state: TerminalWorkspaceState, hosts: Set<UUID>) -> [TerminalWorkspaceNativeAdapter.Group] {
        hosts.sorted { $0.uuidString < $1.uuidString }.flatMap { host in
            state.workspaces.compactMap { workspace in
                guard let window = state.windows?[host], let group = window.groups[workspace.id] else { return nil }
                let controllers = members(host: host, workspace: workspace.id, state: state)
                guard let selected = controllers.first(where: { $0.tabSessionID == group.selected }) ?? controllers.first else { return nil }
                let layoutOwner = controllers.first { $0.workspaceID == workspace.id }
                let layout = layoutOwner?.tabLayoutState ?? selected.tabLayoutState.detachedCopy()
                // Different workspaces must not share a host inherited during
                // fullscreen child creation, even before native attachment.
                let bound = layout.workspaceBindingID
                let ownLayout = bound == nil || bound == workspace.id ? layout : layout.detachedCopy()
                ownLayout.bindWorkspace(workspace.id, store: store)
                return .init(members: controllers, selected: selected,
                    visible: window.currentWorkspace == workspace.id, layout: ownLayout, scrollOffset: group.scrollOffset)
            }
        }
    }

    private func projectIdentities(_ state: TerminalWorkspaceState, controllers: [TerminalController]) {
        for controller in controllers {
            guard let owner = state.owner(of: controller.tabSessionID) else { continue }
            controller.windowSessionID = owner.window
            controller.workspaceGroupID = owner.group
            controller.workspaceID = owner.workspace
            controller.window?.tabbingIdentifier = "omg.window.\(owner.window).workspace.\(owner.workspace)"
        }
    }

    private func updateRetention() {
        retainedParked = Dictionary(uniqueKeysWithValues: liveControllers.filter {
            store.snapshot.isParked($0.tabSessionID)
        }.map { ($0.tabSessionID, $0) })
    }

    private func nativeMembers(_ controller: TerminalController) -> [TerminalController] {
        (controller.window?.tabGroup?.windows ?? [controller.window].compactMap { $0 }).compactMap {
            $0.windowController as? TerminalController
        }.filter { $0.workspaceCoordinator === self && $0.isAvailableForWorkspace }
    }

    func finishRestoring() {
        guard restoring else { return }
        restoring = false
        let allGroups = groups(state: store.snapshot, hosts: Set((store.snapshot.windows ?? [:]).keys))
        let transaction = TerminalWorkspacePresentationTransaction(allGroups.flatMap(\.members))
        applying = true
        for group in allGroups where !group.visible {
            for member in group.members {
                member.workspacePresentationIsParked = true
                member.window?.orderOut(nil)
            }
        }
        transaction.publish { native.publish(allGroups) }
        applying = false
        updateRetention()
        ensureVisibleWorkspace()
    }

    func ensureVisibleWorkspace() {
        guard !quitting, !applying, !liveControllers.contains(where: { $0.window?.isVisible == true }),
              let target = orderedControllers(state: store.snapshot).first else { return }
        _ = perform(hosts: [target.windowSessionID], focus: target) { state in
            state.select(target.workspaceID, in: target.windowSessionID)
            return true
        }
    }

    func prepareToQuit() {
        guard !quitting else { return }
        savePresentation()
        quitting = true
        let completions = Array(deferredSwitchCompletions.values)
        deferredSwitches.removeAll()
        deferredTabLayouts.removeAll()
        deferredSwitchCompletions.removeAll()
        completions.forEach { $0(.superseded) }
    }
    func cancelQuit() { quitting = false; savePresentation() }

    /// Presentation sampling updates geometry only. Ownership/order enter via
    /// native events or commands, never through the persistence timer.
    func savePresentation() {
        guard !quitting, !restoring, !applying else { return }
        store.transaction { state in
            for controller in liveControllers where !state.isParked(controller.tabSessionID) {
                guard state.windows?[controller.windowSessionID]?.groups[controller.workspaceID]?.selected == controller.tabSessionID,
                      let window = controller.window else { continue }
                state.windows?[controller.windowSessionID]?.frame = window.frame
                if !native.transitioningWindows.contains(controller.windowSessionID) {
                    state.windows?[controller.windowSessionID]?.fullscreen = controller.fullscreenStyle?.isFullscreen == true
                    state.windows?[controller.windowSessionID]?.fullscreenMode = controller.fullscreenStyle?.isFullscreen == true
                        ? controller.fullscreenStyle?.fullscreenMode : nil
                }
                state.windows?[controller.windowSessionID]?.groups[controller.workspaceID]?.scrollOffset =
                    controller.tabLayoutState.sidebarHost.scrollOffset
            }
        }
        revision &+= 1
        sessions.capture()
    }
}
