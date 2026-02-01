import AppKit
import SwiftUI

struct WorktrunkSidebarView: View {
    @ObservedObject var store: WorktrunkStore
    @ObservedObject var sidebarState: WorktrunkSidebarState
    let openWorktree: (String) -> Void
    var resumeSession: ((AISession) -> Void)?
    var onSelectWorktree: ((String?) -> Void)?

    @State private var createSheetRepo: WorktrunkStore.Repository?
    @State private var removeRepoConfirm: WorktrunkStore.Repository?
    @State private var removeWorktreeConfirm: WorktrunkStore.Worktree?
    @State private var removeWorktreeErrorMessage: String?
    @State private var removeWorktreeForceConfirm: WorktrunkStore.Worktree?
    @State private var showSettings: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            HStack(spacing: 8) {
                Button {
                    Task { await promptAddRepository() }
                } label: {
                    Label("Add Repo…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .help("Add repository")

                Spacer(minLength: 0)

                Button {
                    toggleSidebarListMode()
                } label: {
                    Image(systemName: store.sidebarListMode == .flatWorktrees ? "list.bullet.indent" : "list.bullet")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(store.sidebarListMode == .flatWorktrees ? "Switch to nested list" : "Switch to flat list")

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

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Worktrunk settings")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            if let err = store.errorMessage, !err.isEmpty {
                Divider()
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 240, idealWidth: 280)
        .sheet(item: $createSheetRepo) { repo in
            CreateWorktreeSheet(
                store: store,
                repoID: repo.id,
                repoName: repo.name,
                onOpen: { openWorktree($0) }
            )
        }
        .sheet(isPresented: $showSettings) {
            WorktrunkSettingsView()
        }
        .onChange(of: sidebarState.selection) { newValue in
            if sidebarState.isApplyingRemoteUpdate {
                return
            }
            switch newValue {
            case .worktree(_, let path):
                store.acknowledgeAgentStatus(for: path)
                onSelectWorktree?(path)
            case .session(_, _, let worktreePath):
                store.acknowledgeAgentStatus(for: worktreePath)
                onSelectWorktree?(worktreePath)
            default:
                onSelectWorktree?(nil)
            }
        }
        .onChange(of: store.sidebarModelRevision) { _ in
            if store.isRefreshing { return }
            sidebarState.reconcile(with: store)
        }
        .onChange(of: store.isRefreshing) { isRefreshing in
            if isRefreshing { return }
            sidebarState.reconcile(with: store)
        }
        .onAppear {
            if store.sidebarListMode == .nestedByRepo, sidebarState.expandedRepoIDs.isEmpty {
                sidebarState.expandedRepoIDs = Set(store.repositories.map(\.id))
            }
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
                        removeWorktreeErrorMessage = store.errorMessage ?? "Failed to remove worktree."
                        removeWorktreeForceConfirm = wt
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { wt in
            Text("This runs `wt remove \(wt.branch)` and deletes the worktree directory. The branch may be deleted if it's merged.")
        }
        .alert(
            "Couldn’t Remove Worktree",
            isPresented: Binding(
                get: { removeWorktreeErrorMessage != nil },
                set: { if !$0 { removeWorktreeErrorMessage = nil } }
            ),
            presenting: removeWorktreeErrorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert(
            "Force Remove Worktree?",
            isPresented: Binding(
                get: { removeWorktreeForceConfirm != nil },
                set: { if !$0 { removeWorktreeForceConfirm = nil } }
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
            Text("This will run `wt remove \(wt.branch) --force` and discard uncommitted changes in that worktree.")
        }
    }

    private var list: some View {
        let selection = Binding(
            get: { sidebarState.selection },
            set: { sidebarState.selection = $0 }
        )
        return List(selection: selection) {
            if store.sidebarListMode == .flatWorktrees {
                flatWorktreeList
            } else {
                nestedRepoList
            }
        }
        .listStyle(.sidebar)
        .overlay(alignment: .top) {
            SidebarTopProgressBar(isVisible: store.isRefreshing)
        }
    }

    @ViewBuilder
    private var nestedRepoList: some View {
        ForEach(store.repositories) { repo in
            DisclosureGroup(
                isExpanded: Binding(
                    get: { sidebarState.expandedRepoIDs.contains(repo.id) },
                    set: { newValue in
                        if newValue {
                            sidebarState.expandedRepoIDs.insert(repo.id)
                        } else {
                            sidebarState.expandedRepoIDs.remove(repo.id)
                            sidebarState.didCollapseRepo(id: repo.id)
                        }
                    }
                )
            ) {
                let worktrees = store.worktrees(for: repo.id)
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

                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                    Text("New worktree…")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    createSheetRepo = repo
                }
                .help("Create worktree")
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
    private var flatWorktreeList: some View {
        let repoNameByID = Dictionary(uniqueKeysWithValues: store.repositories.map { ($0.id, $0.name) })
        let worktrees = store.allWorktreesSorted()

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

        if store.repositories.count == 1, let repo = store.repositories.first {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                Text("New worktree…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                createSheetRepo = repo
            }
            .help("Create worktree")
        } else if store.repositories.count > 1 {
            Menu {
                ForEach(store.repositories) { repo in
                    Button(repo.name) {
                        createSheetRepo = repo
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                    Text("New worktree…")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 2)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Create worktree")
        }
    }

    private func toggleSidebarListMode() {
        if store.sidebarListMode == .flatWorktrees {
            store.sidebarListMode = .nestedByRepo
        } else {
            store.sidebarListMode = .flatWorktrees
            store.worktreeSortOrder = .recentActivity
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
                    if newValue {
                        sidebarState.expandedWorktreePaths.insert(wt.path)
                    } else {
                        sidebarState.expandedWorktreePaths.remove(wt.path)
                        sidebarState.didCollapseWorktree(repoID: wt.repositoryID, path: wt.path)
                    }
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
            .contentShape(Rectangle())
            .help(wt.path)
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
                    Text(repoName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text(wt.branch)
            }

            if let status = store.agentStatus(for: wt.path) {
                WorktreeAgentStatusBadge(status: status)
            }
            if let tracking,
               tracking.lineAdditions > 0 || tracking.lineDeletions > 0 {
                WorktreeChangeBadge(
                    additions: tracking.lineAdditions,
                    deletions: tracking.lineDeletions
                )
            }
            Spacer(minLength: 8)
            Spacer(minLength: 8)
            Button {
                store.acknowledgeAgentStatus(for: wt.path)
                openWorktree(wt.path)
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open terminal in \(wt.branch)")
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
                        Text(session.source.rawValue.capitalized)
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
            }
            if deletions > 0 {
                Text("-\(deletions)")
                    .foregroundStyle(Color.red)
            }
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

private struct SidebarTopProgressBar: View {
    let isVisible: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
            ProgressView()
                .progressViewStyle(.linear)
                .opacity(isVisible ? 1 : 0)
                .padding(.horizontal, 10)
        }
        .frame(height: 3)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isVisible)
        .allowsHitTesting(false)
    }
}
