import AppKit
import SwiftUI

struct WorktrunkSidebarView: View {
    @ObservedObject var store: WorktrunkStore
    let openWorktree: (String) -> Void

    @State private var expandedRepoIDs: Set<UUID> = []
    @State private var createSheetRepo: WorktrunkStore.Repository?

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
        .onAppear {
            if expandedRepoIDs.isEmpty {
                expandedRepoIDs = Set(store.repositories.map(\.id))
            }
            Task { await store.refreshAll() }
        }
    }

    private var list: some View {
        List {
            ForEach(store.repositories) { repo in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedRepoIDs.contains(repo.id) },
                        set: { newValue in
                            if newValue { expandedRepoIDs.insert(repo.id) }
                            else { expandedRepoIDs.remove(repo.id) }
                        }
                    )
                ) {
                    let worktrees = store.worktrees(for: repo.id)
                    if worktrees.isEmpty {
                        Text("No worktrees")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(worktrees) { wt in
                            Button {
                                openWorktree(wt.path)
                            } label: {
                                HStack(spacing: 8) {
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
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .help(wt.path)
                        }
                    }

                    Button {
                        createSheetRepo = repo
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.secondary)
                            Text("New worktree…")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .opacity(0)
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
                }
                .contextMenu {
                    Button("Remove") {
                        store.removeRepository(id: repo.id)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
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
