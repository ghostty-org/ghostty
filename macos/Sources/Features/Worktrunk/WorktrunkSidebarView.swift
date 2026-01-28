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

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            HStack(spacing: 8) {
                Button {
                    Task { await promptAddRepository() }
                } label: {
                    Label("Add Repository…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .help("Add repository")

                Spacer(minLength: 0)
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
        .onChange(of: sidebarState.selection) { newValue in
            if sidebarState.isApplyingRemoteUpdate {
                return
            }
            switch newValue {
            case .worktree(let path):
                store.acknowledgeAgentStatus(for: path)
                onSelectWorktree?(path)
            default:
                onSelectWorktree?(nil)
            }
        }
        .onAppear {
            if sidebarState.expandedRepoIDs.isEmpty {
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
            // Small loading indicator at top - doesn't block anything
            if store.isRefreshing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading sessions...")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            ForEach(store.repositories) { repo in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { sidebarState.expandedRepoIDs.contains(repo.id) },
                        set: { newValue in
                            if newValue { sidebarState.expandedRepoIDs.insert(repo.id) }
                            else { sidebarState.expandedRepoIDs.remove(repo.id) }
                        }
                    )
                ) {
                    let worktrees = store.worktrees(for: repo.id)
                    if worktrees.isEmpty {
                        Text("No worktrees")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(worktrees) { wt in
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { sidebarState.expandedWorktreePaths.contains(wt.path) },
                                    set: { newValue in
                                        if newValue { sidebarState.expandedWorktreePaths.insert(wt.path) }
                                        else { sidebarState.expandedWorktreePaths.remove(wt.path) }
                                    }
                                )
                            ) {
                                // Sessions under this worktree
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
                                        .tag(SidebarSelection.session(id: session.id))
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    let tracking = store.gitTracking(for: wt.path)
                                    if wt.isCurrent {
                                        Image(systemName: "location.fill")
                                            .foregroundStyle(.secondary)
                                    } else if wt.isMain {
                                        Image(systemName: "house.fill")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(wt.branch)
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
                            .tag(SidebarSelection.worktree(path: wt.path))
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
            }
        }
        .listStyle(.sidebar)
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
