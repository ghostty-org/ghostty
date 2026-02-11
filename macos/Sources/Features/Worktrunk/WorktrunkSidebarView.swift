import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorktrunkSidebarView: View {
    @ObservedObject var store: WorktrunkStore
    @ObservedObject var sidebarState: WorktrunkSidebarState
    @ObservedObject var openTabsModel: WorktrunkOpenTabsModel
    @ObservedObject var tooltipState: StatusRingTooltipState
    let openWorktree: (String) -> Void
    let openWorktreeAgent: (String, WorktrunkAgent) -> Void
    var resumeSession: ((AISession) -> Void)?
    let focusNativeTab: (Int) -> Void
    let moveNativeTabBefore: (Int, Int) -> Void
    let moveNativeTabAfter: (Int, Int) -> Void
    var onSelectWorktree: ((String?) -> Void)?

    @AppStorage(WorktrunkPreferences.defaultAgentKey) private var defaultActionRaw: String = WorktrunkDefaultAction.terminal.rawValue
    @AppStorage(WorktrunkPreferences.sidebarTabsKey) private var sidebarTabsEnabled: Bool = false
    @State private var createSheetRepo: WorktrunkStore.Repository?
    @State private var removeRepoConfirm: WorktrunkStore.Repository?
    @State private var removeWorktreeConfirm: WorktrunkStore.Worktree?
    @State private var removeWorktreeForceConfirm: WorktrunkStore.Worktree?
    @State private var removeWorktreeForceError: String?
    @State private var showRepoPicker: Bool = false
    @State private var repoSearchText: String = ""
    @State private var sidebarTabsEndDropTarget: Bool = false
    @StateObject private var sidebarScrollPreserver = SidebarListScrollPreserver()

    private var availableAgents: [WorktrunkAgent] {
        WorktrunkAgent.availableAgents()
    }

    private var availableActions: [WorktrunkDefaultAction] {
        WorktrunkDefaultAction.availableActions()
    }

    private var defaultAction: WorktrunkDefaultAction {
        WorktrunkDefaultAction.preferredAction(from: defaultActionRaw, availableActions: availableActions)
    }

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            if store.isRefreshing {
                SidebarRefreshProgressBar()
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await promptAddRepository() }
                } label: {
                    Label("Add Repo…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .help("Add repository")

                Spacer(minLength: 0)

                if !sidebarTabsEnabled {
                    Button {
                        toggleSidebarListMode()
                    } label: {
                        Image(systemName: store.sidebarListMode == .flatWorktrees ? "list.bullet.indent" : "list.bullet")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(store.sidebarListMode == .flatWorktrees ? "Switch to nested list" : "Switch to flat list")
                }

                Menu {
                    ForEach(WorktreeSortOrder.allCases, id: \.self) { order in
                        Button {
                            store.worktreeSortOrder = order
                        } label: {
                            if store.worktreeSortOrder == order {
                                Label(order.label, systemImage: "checkmark")
                            } else {
                                Text(order.label)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort worktrees")

            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            if let err = store.errorMessage, !err.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if store.needsWorktrunkInstall {
                        HStack(spacing: 8) {
                            Button {
                                Task { _ = await store.installWorktrunk() }
                            } label: {
                                Text("Install Worktrunk…")
                            }
                            .disabled(store.isInstallingWorktrunk)

                            if store.isInstallingWorktrunk {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 240, idealWidth: 280)
        .environment(\.statusRingTooltipState, tooltipState)
        .animation(.easeOut(duration: 0.08), value: store.isRefreshing)
        .sheet(item: $createSheetRepo) { repo in
            CreateWorktreeSheet(
                store: store,
                repoID: repo.id,
                repoName: repo.name,
                onOpen: { openWorktree($0) }
            )
        }
        .onChange(of: sidebarState.selection) { newValue in
            var focusedWorktreePath: String?
            if sidebarTabsEnabled {
                let worktreePath: String?
                switch newValue {
                case .worktree(_, let path):
                    worktreePath = path
                case .session(_, _, let path):
                    worktreePath = path
                default:
                    worktreePath = nil
                }

                if let worktreePath {
                    let key = standardizedPath(worktreePath)
                    if let tab = openTabsModel.tabs.first(where: { tab in
                        guard let root = tab.worktreeRootPath else { return false }
                        return standardizedPath(root) == key
                    }) {
                        focusedWorktreePath = worktreePath
                        DispatchQueue.main.async {
                            focusNativeTab(tab.windowNumber)
                        }
                    }
                }
            }

            switch newValue {
            case .worktree(_, let path):
                store.acknowledgeAgentStatus(for: path)
                if focusedWorktreePath == path {
                    return
                }
                onSelectWorktree?(path)
            case .session(_, _, let worktreePath):
                store.acknowledgeAgentStatus(for: worktreePath)
                if focusedWorktreePath == worktreePath {
                    return
                }
                onSelectWorktree?(worktreePath)
            default:
                onSelectWorktree?(nil)
            }
        }
        .onChange(of: store.sidebarModelRevision) { _ in
            if store.isRefreshing { return }
            sidebarState.reconcile(with: store, listMode: store.sidebarListMode)
        }
        .onChange(of: store.isRefreshing) { isRefreshing in
            if isRefreshing { return }
            clearSelectionIfMainInFlatMode()
            sidebarState.reconcile(with: store, listMode: store.sidebarListMode)
        }
        .onChange(of: store.sidebarListMode) { _ in
            clearSelectionIfMainInFlatMode()
        }
        .onChange(of: sidebarTabsEnabled) { enabled in
            if enabled {
                forceFlatModeIfNeeded()
            }
        }
        .onAppear {
            if sidebarTabsEnabled {
                forceFlatModeIfNeeded()
            }
            if store.sidebarListMode == .nestedByRepo, sidebarState.expandedRepoIDs.isEmpty {
                sidebarState.applyExpandedRepoIDs(
                    Set(store.sidebarSnapshot.repositories.map(\.id)),
                    listMode: store.sidebarListMode
                )
            }
            clearSelectionIfMainInFlatMode()
            Task { await store.refreshAll() }
        }
        .alert(
            "Remove Repository?",
            isPresented: Binding(
                get: { removeRepoConfirm != nil },
                set: { if !$0 { removeRepoConfirm = nil } }
            ),
            presenting: removeRepoConfirm
        ) { repo in
            Button("Remove", role: .destructive) {
                store.removeRepository(id: repo.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { repo in
            Text("Remove \(repo.name) from the sidebar. Nothing will be deleted from disk.")
        }
        .alert(
            "Remove Worktree?",
            isPresented: Binding(
                get: { removeWorktreeConfirm != nil },
                set: { if !$0 { removeWorktreeConfirm = nil } }
            ),
            presenting: removeWorktreeConfirm
        ) { wt in
            Button("Remove", role: .destructive) {
                Task {
                    let ok = await store.removeWorktree(repoID: wt.repositoryID, branch: wt.branch)
                    if !ok {
                        removeWorktreeForceError = store.errorMessage ?? "Failed to remove worktree."
                        store.errorMessage = nil
                        removeWorktreeForceConfirm = wt
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { wt in
            Text("This runs `wt remove \(wt.branch)` and deletes the worktree directory. The branch may be deleted if it's merged.")
        }
        .alert(
            "Force Remove Worktree?",
            isPresented: Binding(
                get: { removeWorktreeForceConfirm != nil },
                set: { if !$0 {
                    removeWorktreeForceConfirm = nil
                    removeWorktreeForceError = nil
                } }
            ),
            presenting: removeWorktreeForceConfirm
        ) { wt in
            Button("Force Remove", role: .destructive) {
                Task {
                    _ = await store.removeWorktree(repoID: wt.repositoryID, branch: wt.branch, force: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { wt in
            if let error = removeWorktreeForceError {
                Text("\(error)\n\nForce remove will run `wt remove \(wt.branch) --force` and discard uncommitted changes.")
            } else {
                Text("This will run `wt remove \(wt.branch) --force` and discard uncommitted changes in that worktree.")
            }
        }
    }

    private var list: some View {
        let selection = Binding(
            get: { sidebarState.selection },
            set: { sidebarState.selection = $0 }
        )
        let snapshot = store.sidebarSnapshot
        let worktreeTabs: [WorktrunkOpenTabsModel.Tab] = {
            guard sidebarTabsEnabled else { return [] }
            var seen = Set<String>()
            var result: [WorktrunkOpenTabsModel.Tab] = []
            result.reserveCapacity(openTabsModel.tabs.count)
            for tab in openTabsModel.tabs {
                guard let root = tab.worktreeRootPath else { continue }
                let key = standardizedPath(root)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(tab)
            }
            return result
        }()
        let topWorktreePaths = Set(worktreeTabs.compactMap(\.worktreeRootPath).map(standardizedPath))
        return List(selection: selection) {
            if sidebarTabsEnabled {
                sidebarTabsList(snapshot: snapshot, tabs: worktreeTabs)
            }

            if store.sidebarListMode == .flatWorktrees {
                flatWorktreeList(snapshot: snapshot, excludingWorktreePaths: topWorktreePaths)
            } else {
                nestedRepoList(snapshot: snapshot)
            }
        }
        .background(SidebarListScrollFinder(preserver: sidebarScrollPreserver))
        .id(store.sidebarListMode.rawValue + (sidebarTabsEnabled ? ".sidebarTabs" : ""))
        .listStyle(.sidebar)
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func findWorktree(forWorktreeRootPath rootPath: String) -> WorktrunkStore.Worktree? {
        let root = standardizedPath(rootPath)
        for repo in store.repositories {
            for wt in store.worktrees(for: repo.id) {
                if standardizedPath(wt.path) == root {
                    return wt
                }
            }
        }
        return nil
    }

    private func forceFlatModeIfNeeded() {
        if store.sidebarListMode != .flatWorktrees {
            store.sidebarListMode = .flatWorktrees
        }
        if store.worktreeSortOrder != .recentActivity {
            store.worktreeSortOrder = .recentActivity
        }
        clearSelectionIfMainInFlatMode()
    }

    @ViewBuilder
    private func sidebarTabsList(
        snapshot: WorktrunkStore.SidebarSnapshot,
        tabs: [WorktrunkOpenTabsModel.Tab]
    ) -> some View {
        let shownTabs: [(tab: WorktrunkOpenTabsModel.Tab, worktree: WorktrunkStore.Worktree)] = tabs.compactMap { tab in
            guard let root = tab.worktreeRootPath else { return nil }
            guard let wt = findWorktree(forWorktreeRootPath: root) else { return nil }
            return (tab, wt)
        }
        let windowNumberByWorktreePath: [String: Int] = Dictionary(
            uniqueKeysWithValues: shownTabs.map { item in
                let key = URL(fileURLWithPath: item.worktree.path).standardizedFileURL.path
                return (key, item.tab.windowNumber)
            }
        )
        let moveBeforePreservingScroll: (Int, Int) -> Void = { moving, target in
            let scrollY = sidebarScrollPreserver.captureScrollY()
            moveNativeTabBefore(moving, target)
            if let scrollY {
                DispatchQueue.main.async {
                    sidebarScrollPreserver.restoreScrollY(scrollY)
                }
            }
        }
        let moveAfterPreservingScroll: (Int, Int) -> Void = { moving, target in
            let scrollY = sidebarScrollPreserver.captureScrollY()
            moveNativeTabAfter(moving, target)
            if let scrollY {
                DispatchQueue.main.async {
                    sidebarScrollPreserver.restoreScrollY(scrollY)
                }
            }
        }

        ForEach(shownTabs, id: \.tab.id) { item in
            WorktreeTabDisclosureGroup(
                store: store,
                sidebarState: sidebarState,
                snapshot: snapshot,
                tab: item.tab,
                worktree: item.worktree,
                repoName: snapshot.repoNameByID[item.worktree.repositoryID],
                resumeSession: resumeSession,
                openWorktree: openWorktree,
                openWorktreeAgent: openWorktreeAgent,
                defaultAction: defaultAction,
                availableAgents: availableAgents,
                  focusNativeTab: focusNativeTab,
                  moveBefore: moveBeforePreservingScroll,
                  moveAfter: moveAfterPreservingScroll,
                  windowNumberByWorktreePath: windowNumberByWorktreePath
              )
          }

          if let last = shownTabs.last?.tab {
              Rectangle()
                  .fill(Color.clear)
                  .frame(maxWidth: .infinity)
                  .frame(height: 1)
                  .contentShape(Rectangle())
                  .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                  .listRowSeparator(.hidden)
                  .overlay(alignment: .center) {
                      if sidebarTabsEndDropTarget {
                        SidebarInsertionIndicatorLine()
                    }
                }
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: Binding(
                    get: { sidebarTabsEndDropTarget },
                    set: { targeted in
                        DispatchQueue.main.async {
                            sidebarTabsEndDropTarget = targeted
                        }
                    }
                )) { providers in
                    return SidebarFileURLDrop.loadURL(from: providers) { url in
                        guard let url else { return }
                        let key = URL(fileURLWithPath: url.path).standardizedFileURL.path
                        guard let moving = windowNumberByWorktreePath[key] else { return }
                        guard moving != last.windowNumber else { return }
                        moveAfterPreservingScroll(moving, last.windowNumber)
                    }
                }
        }
    }

    @ViewBuilder
    private func nestedRepoList(snapshot: WorktrunkStore.SidebarSnapshot) -> some View {
        ForEach(snapshot.repositories) { repo in
            DisclosureGroup(
                isExpanded: Binding(
                    get: { sidebarState.expandedRepoIDs.contains(repo.id) },
                    set: { newValue in
                        var next = sidebarState.expandedRepoIDs
                        if newValue {
                            next.insert(repo.id)
                        } else {
                            next.remove(repo.id)
                        }
                        sidebarState.applyExpandedRepoIDs(next, listMode: store.sidebarListMode)
                    }
                )
            ) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                    Text("New worktree…")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.bottom, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    createSheetRepo = repo
                }
                .help("Create worktree")

                let worktrees = snapshot.worktreesByRepositoryID[repo.id] ?? []
                if worktrees.isEmpty {
                    Text("No worktrees")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(worktrees) { wt in
                        worktreeDisclosureGroup(
                            wt: wt,
                            repoName: nil,
                            showsFolderIcon: true,
                            showsRepoName: false
                        )
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(repo.name)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        createSheetRepo = repo
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Create worktree")
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Remove Repository…") {
                        removeRepoConfirm = repo
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
                    }
                }
            }
            .tag(SidebarSelection.repo(id: repo.id))
        }
    }

    @ViewBuilder
    private func flatWorktreeList(
        snapshot: WorktrunkStore.SidebarSnapshot,
        excludingWorktreePaths: Set<String>
    ) -> some View {
        let repoNameByID = snapshot.repoNameByID
        let worktrees = snapshot.flatWorktrees.filter { wt in
            !excludingWorktreePaths.contains(standardizedPath(wt.path))
        }

        if !snapshot.repositories.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                Text("New worktree…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                if snapshot.repositories.count == 1, let repo = snapshot.repositories.first {
                    createSheetRepo = repo
                } else {
                    showRepoPicker = true
                }
            }
            .help("Create worktree")
            .popover(isPresented: $showRepoPicker) {
                RepoPickerPopover(
                    repositories: snapshot.repositories,
                    searchText: $repoSearchText
                ) { repo in
                    showRepoPicker = false
                    createSheetRepo = repo
                }
            }
            .onChange(of: showRepoPicker) { isShowing in
                if isShowing { repoSearchText = "" }
            }
        }

        if worktrees.isEmpty {
            Text("No worktrees")
                .foregroundStyle(.secondary)
        } else {
            ForEach(worktrees) { wt in
                worktreeDisclosureGroup(
                    wt: wt,
                    repoName: repoNameByID[wt.repositoryID],
                    showsFolderIcon: false,
                    showsRepoName: true
                )
            }
        }
    }

    private func toggleSidebarListMode() {
        if store.sidebarListMode == .flatWorktrees {
            store.sidebarListMode = .nestedByRepo
        } else {
            store.sidebarListMode = .flatWorktrees
            store.worktreeSortOrder = .recentActivity
            clearSelectionIfMainInFlatMode()
        }
    }

    private func clearSelectionIfMainInFlatMode() {
        guard store.sidebarListMode == .flatWorktrees else { return }
        guard let selection = sidebarState.selection else { return }

        let selectedPath: String?
        switch selection {
        case .worktree(_, let path):
            selectedPath = path
        case .session(_, _, let worktreePath):
            selectedPath = worktreePath
        case .repo:
            selectedPath = nil
        }

        guard let selectedPath else { return }

        let isMain = store.repositories
            .flatMap { store.worktrees(for: $0.id) }
            .first(where: { $0.path == selectedPath })?
            .isMain ?? false

        if isMain {
            sidebarState.selection = nil
        }
    }

    @ViewBuilder
    private func worktreeDisclosureGroup(
        wt: WorktrunkStore.Worktree,
        repoName: String?,
        showsFolderIcon: Bool,
        showsRepoName: Bool
    ) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { sidebarState.expandedWorktreePaths.contains(wt.path) },
                set: { newValue in
                    var next = sidebarState.expandedWorktreePaths
                    if newValue {
                        next.insert(wt.path)
                    } else {
                        next.remove(wt.path)
                    }
                    sidebarState.applyExpandedWorktreePaths(next, listMode: store.sidebarListMode)
                }
            )
        ) {
            let sessions = store.sessions(for: wt.path)
            if sessions.isEmpty {
                Text("No sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            } else {
                ForEach(sessions) { session in
                    SessionRow(session: session, onResume: {
                        store.acknowledgeAgentStatus(for: session.worktreePath)
                        resumeSession?(session)
                    })
                    .tag(SidebarSelection.session(
                        id: session.id,
                        repoID: wt.repositoryID,
                        worktreePath: wt.path
                    ))
                }
            }
          } label: {
              worktreeRowLabel(
                  wt: wt,
                  repoName: repoName,
                  showsFolderIcon: showsFolderIcon,
                  showsRepoName: showsRepoName
              )
              .padding(.leading, 4)
              .alignmentGuide(.firstTextBaseline) { d in
                  d[VerticalAlignment.center]
              }
              .contentShape(Rectangle())
              .contextMenu {
                  Button("Remove Worktree…") {
                      removeWorktreeConfirm = wt
                  }
                .disabled(wt.isMain)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wt.path)])
                }
            }
        }
        .tag(SidebarSelection.worktree(repoID: wt.repositoryID, path: wt.path))
    }

    @ViewBuilder
    private func worktreeRowLabel(
        wt: WorktrunkStore.Worktree,
        repoName: String?,
        showsFolderIcon: Bool,
        showsRepoName: Bool
    ) -> some View {
        HStack(spacing: 8) {
            let tracking = store.gitTracking(for: wt.path)
            let recencyDate = store.recencyDate(for: wt.path)
            let status = store.agentStatus(for: wt.path)
            let showsChanges = tracking.map { $0.lineAdditions > 0 || $0.lineDeletions > 0 } ?? false
            if wt.isCurrent {
                Image(systemName: "location.fill")
                    .foregroundStyle(.secondary)
            } else if wt.isMain {
                Image(systemName: "house.fill")
                    .foregroundStyle(.secondary)
            } else if showsFolderIcon {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
            }

            if showsRepoName, let repoName {
                VStack(alignment: .leading, spacing: 1) {
                    Text(wt.branch)
                        .lineLimit(1)
                    if let recencyDate {
                        (Text(repoName) + Text(" • ") + Text(recencyDate, style: .relative))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(repoName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)
            } else {
                Text(wt.branch)
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            Spacer(minLength: 0)

            let ciState = store.ciState(for: wt.path)
            let prStatus = store.prStatus(for: wt.path)
            let hasStatusRing = status != nil || ciState != .none

            if hasStatusRing || showsChanges {
                HStack(spacing: 6) {
                    // Combined status ring (agent + CI)
                    if hasStatusRing {
                        StatusRingView(
                            agentStatus: status,
                            ciState: ciState,
                            prStatus: prStatus,
                            onTap: {
                                if let url = prStatus?.url, let nsURL = URL(string: url) {
                                    NSWorkspace.shared.open(nsURL)
                                }
                            }
                        )
                    }

                    // Line changes badge
                    if let tracking, showsChanges {
                        WorktreeChangeBadge(
                            additions: tracking.lineAdditions,
                            deletions: tracking.lineDeletions
                        )
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            }
            HStack(spacing: 4) {
                Button {
                    if let agent = defaultAction.agent {
                        store.acknowledgeAgentStatus(for: wt.path)
                        openWorktreeAgent(wt.path, agent)
                    } else {
                        openWorktree(wt.path)
                    }
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New \(defaultAction.title) in \(wt.branch)")

                Menu {
                    ForEach(availableAgents) { agent in
                        Button {
                            store.acknowledgeAgentStatus(for: wt.path)
                            openWorktreeAgent(wt.path, agent)
                        } label: {
                            Text("New \(agent.title) Session")
                        }
                    }
                    if !availableAgents.isEmpty {
                        Divider()
                    }
                    Button {
                        openWorktree(wt.path)
                    } label: {
                        Text("New Terminal")
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(Color.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("New terminal or agent session")
            }
        }
    }

    private func promptAddRepository() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.title = "Add Repository"

        let url: URL? = await withCheckedContinuation { continuation in
            panel.begin { response in
                if response == .OK {
                    continuation.resume(returning: panel.url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }

        guard let url else { return }
        await store.addRepositoryValidated(path: url.path)
    }
}

private enum SidebarFileURLDrop {
    static func loadURL(from providers: [NSItemProvider], completion: @escaping (URL?) -> Void) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL? = {
                guard let data = item as? Data else { return nil }
                return URL(dataRepresentation: data, relativeTo: nil)
            }()
            DispatchQueue.main.async {
                completion(url)
            }
        }

        return true
    }
}

private struct SidebarTabFallbackRow: View {
    let tab: WorktrunkOpenTabsModel.Tab
    let focusNativeTab: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(tab.title.isEmpty ? "Terminal" : tab.title)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .onTapGesture {
            focusNativeTab(tab.windowNumber)
        }
    }
}

private struct SidebarInsertionIndicatorLine: View {
    @Environment(\.colorScheme) private var colorScheme

    private var color: Color {
        // High-contrast insertion indicator.
        colorScheme == .dark ? Color.white.opacity(0.9) : Color.black.opacity(0.35)
    }

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 2)
            .padding(.horizontal, 12)
    }
}

private struct WorktreeTabDisclosureGroup: View {
    @ObservedObject var store: WorktrunkStore
    @ObservedObject var sidebarState: WorktrunkSidebarState
    let snapshot: WorktrunkStore.SidebarSnapshot
    let tab: WorktrunkOpenTabsModel.Tab
    let worktree: WorktrunkStore.Worktree
    let repoName: String?
    let resumeSession: ((AISession) -> Void)?
    let openWorktree: (String) -> Void
    let openWorktreeAgent: (String, WorktrunkAgent) -> Void
    let defaultAction: WorktrunkDefaultAction
    let availableAgents: [WorktrunkAgent]
    let focusNativeTab: (Int) -> Void
    let moveBefore: (Int, Int) -> Void
    let moveAfter: (Int, Int) -> Void
    let windowNumberByWorktreePath: [String: Int]

    var body: some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { sidebarState.expandedWorktreePaths.contains(worktree.path) },
                set: { newValue in
                    var next = sidebarState.expandedWorktreePaths
                    if newValue {
                        next.insert(worktree.path)
                    } else {
                        next.remove(worktree.path)
                    }
                    sidebarState.applyExpandedWorktreePaths(next, listMode: store.sidebarListMode)
                }
            )
        ) {
            let sessions = store.sessions(for: worktree.path)
            if sessions.isEmpty {
                Text("No sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            } else {
                ForEach(sessions) { session in
                    SessionRow(session: session, onResume: {
                        store.acknowledgeAgentStatus(for: session.worktreePath)
                        resumeSession?(session)
                    })
                    .tag(SidebarSelection.session(
                        id: session.id,
                        repoID: worktree.repositoryID,
                        worktreePath: worktree.path
                    ))
                }
            }
          } label: {
              WorktreeTabRowLabel(
                  store: store,
                  tab: tab,
                  worktree: worktree,
                  repoName: repoName,
                  defaultAction: defaultAction,
                  availableAgents: availableAgents,
                  openWorktree: openWorktree,
                  openWorktreeAgent: openWorktreeAgent,
                  onActivate: {
                      sidebarState.selection = .worktree(repoID: worktree.repositoryID, path: worktree.path)
                      focusNativeTab(tab.windowNumber)
                  },
                  onDropBefore: { moving in
                      guard moving != tab.windowNumber else { return }
                      moveBefore(moving, tab.windowNumber)
                  },
                  windowNumberByWorktreePath: windowNumberByWorktreePath
              )
              .padding(.leading, 4)
              .alignmentGuide(.firstTextBaseline) { d in
                  d[VerticalAlignment.center]
              }
          }
          .tag(SidebarSelection.worktree(repoID: worktree.repositoryID, path: worktree.path))
      }
  }

private struct WorktreeTabRowLabel: View {
    @ObservedObject var store: WorktrunkStore
    let tab: WorktrunkOpenTabsModel.Tab
    let worktree: WorktrunkStore.Worktree
    let repoName: String?
    let defaultAction: WorktrunkDefaultAction
    let availableAgents: [WorktrunkAgent]
    let openWorktree: (String) -> Void
    let openWorktreeAgent: (String, WorktrunkAgent) -> Void
    let onActivate: () -> Void
    let onDropBefore: (Int) -> Void
    let windowNumberByWorktreePath: [String: Int]

    @State private var isDropTarget: Bool = false

    private var isDropTargetBinding: Binding<Bool> {
        Binding(
            get: { isDropTarget },
            set: { targeted in
                DispatchQueue.main.async {
                    isDropTarget = targeted
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            let tracking = store.gitTracking(for: worktree.path)
            let showsChanges = tracking.map { $0.lineAdditions > 0 || $0.lineDeletions > 0 } ?? false
            let status = store.agentStatus(for: worktree.path)
            let ciState = store.ciState(for: worktree.path)
            let prStatus = store.prStatus(for: worktree.path)
            let hasStatusRing = status != nil || ciState != .none

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(worktree.branch)
                            .lineLimit(1)
                            .fontWeight(tab.isActive ? .semibold : .regular)
                        if let repoName {
                            let recencyDate = store.recencyDate(for: worktree.path)
                            if let recencyDate {
                                (Text(repoName) + Text(" • ") + Text(recencyDate, style: .relative))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text(repoName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded(onActivate))

                if hasStatusRing || showsChanges {
                    HStack(spacing: 6) {
                        if hasStatusRing {
                            StatusRingView(
                                agentStatus: status,
                                ciState: ciState,
                                prStatus: prStatus,
                                onTap: {
                                    if let url = prStatus?.url, let nsURL = URL(string: url) {
                                        NSWorkspace.shared.open(nsURL)
                                    }
                                }
                            )
                        }
                        if let tracking, showsChanges {
                            WorktreeChangeBadge(
                                additions: tracking.lineAdditions,
                                deletions: tracking.lineDeletions
                            )
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                }
            }
            .draggable(URL(fileURLWithPath: URL(fileURLWithPath: worktree.path).standardizedFileURL.path))

            HStack(spacing: 4) {
                Button {
                    if let agent = defaultAction.agent {
                        store.acknowledgeAgentStatus(for: worktree.path)
                        openWorktreeAgent(worktree.path, agent)
                    } else {
                        openWorktree(worktree.path)
                    }
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New \(defaultAction.title) in \(worktree.branch)")

                Menu {
                    ForEach(availableAgents) { agent in
                        Button {
                            store.acknowledgeAgentStatus(for: worktree.path)
                            openWorktreeAgent(worktree.path, agent)
                        } label: {
                            Text("New \(agent.title) Session")
                        }
                    }
                    if !availableAgents.isEmpty {
                        Divider()
                    }
                    Button {
                        openWorktree(worktree.path)
                    } label: {
                        Text("New Terminal")
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(Color.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("New terminal or agent session")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .overlay(alignment: .top) {
            if isDropTarget {
                SidebarInsertionIndicatorLine()
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: isDropTargetBinding) { providers in
            return SidebarFileURLDrop.loadURL(from: providers) { url in
                guard let url else { return }
                let key = URL(fileURLWithPath: url.path).standardizedFileURL.path
                guard let moving = windowNumberByWorktreePath[key] else { return }
                onDropBefore(moving)
            }
        }
    }
}

private struct CreateWorktreeSheet: View {
    @ObservedObject var store: WorktrunkStore
    let repoID: UUID
    let repoName: String
    let onOpen: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var branch: String = ""
    @State private var base: String = ""
    @State private var createBranch: Bool = true
    @State private var isWorking: Bool = false
    @State private var errorText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New worktree")
                .font(.headline)
            Text(repoName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Form {
                TextField("Branch", text: $branch)
                TextField("Base (optional)", text: $base)
                Toggle("Create branch", isOn: $createBranch)
            }

            if let errorText, !errorText.isEmpty {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(isWorking)
                Button {
                    Task { await create() }
                } label: {
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .disabled(isWorking || branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func create() async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }

        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = await store.createWorktree(
            repoID: repoID,
            branch: trimmedBranch,
            base: trimmedBase.isEmpty ? nil : trimmedBase,
            createBranch: createBranch
        )
        guard let created else {
            errorText = store.errorMessage ?? "Failed to create worktree."
            return
        }
        onOpen(created.path)
        dismiss()
    }
}

private struct SessionRow: View {
    let session: AISession
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.snippet ?? "Session")
                        .font(.caption)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(session.source.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if session.messageCount > 0 {
                            Text("\(session.messageCount) msgs")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(session.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.leading, 8)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

private struct WorktreeAgentStatusBadge: View {
    let status: WorktreeAgentStatus

    private var label: String {
        switch status {
        case .working: return "Working"
        case .permission: return "Input"
        case .review: return "Done"
        }
    }

    private var color: Color {
        switch status {
        case .working: return .orange
        case .permission: return .red
        case .review: return .green
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct WorktreeTrackingBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
private struct WorktreeChangeBadge: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 6) {
            if additions > 0 {
                Text("+\(additions)")
                    .foregroundStyle(Color.green)
                    .monospacedDigit()
            }
            if deletions > 0 {
                Text("-\(deletions)")
                    .foregroundStyle(Color.red)
                    .monospacedDigit()
            }
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct RepoPickerPopover: View {
    let repositories: [WorktrunkStore.Repository]
    @Binding var searchText: String
    let onSelect: (WorktrunkStore.Repository) -> Void

    private var filtered: [WorktrunkStore.Repository] {
        if searchText.isEmpty { return repositories }
        return repositories.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { repo in
                        Button {
                            onSelect(repo)
                        } label: {
                            Text(repo.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if filtered.isEmpty {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 240)
    }
}

private struct SidebarRefreshProgressBar: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = (1 + sin(t * .pi)) / 2
            Canvas { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(.accentColor.opacity(0.15))
                )
                let barWidth = size.width * 0.25
                let x = phase * (size.width - barWidth)
                context.fill(
                    Path(CGRect(x: x, y: 0, width: barWidth, height: size.height)),
                    with: .color(.accentColor)
                )
            }
        }
        .frame(height: 3)
        .allowsHitTesting(false)
    }
}
