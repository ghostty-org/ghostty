import SwiftUI

struct InspectorGitView: View {
    let content: InspectorGitContent
    let perform: (InspectorPaneActionKind) -> Void
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @State private var collectionState = GitCollectionState()
    @State private var changesController = GitCollectionController()
    @State private var branchesController = GitCollectionController()
    @State private var historyController = GitCollectionController()
    @State private var changesQuery = ""
    @AppStorage("git.collection.viewMode") private var changesMode: GitCollectionMode = .list
    @State private var branchesQuery = ""
    @State private var historyQuery = ""

    private var collectionKey: String { content.repository?.stateKey ?? "git" }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()
            if let notice = content.operationNotice {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                    NativeActionButton(
                        symbol: "xmark",
                        help: GitL10n.text("Dismiss message"),
                        action: { _ in perform(.gitAction(.clearOperationNotice)) }
                    )
                    .frame(width: 24, height: 24)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let error = content.operationError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                    ScrollView {
                        Text(error).font(.caption).foregroundStyle(.primary).textSelection(.enabled)
                    }
                    .frame(maxHeight: 64)
                    Spacer(minLength: 0)
                    NativeActionButton(
                        symbol: "xmark",
                        help: GitL10n.text("Dismiss Git error"),
                        action: { _ in perform(.gitAction(.clearOperationError)) }
                    )
                    .frame(width: 24, height: 24)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let operation = content.operation, !content.isUpdatingIndex {
                HStack { ProgressView().controlSize(.small); Text(operation).font(.caption) }.padding(6)
            }

            switch content.status {
            case .notRepository(let directory):
                emptyStateView(
                    systemImage: "folder.badge.questionmark",
                    title: GitL10n.text("Not a Git Repository"),
                    subtitle: directory.isEmpty
                        ? GitL10n.text("The terminal has not reported a working directory.")
                        : GitL10n.text("The current directory is not tracked by Git."),
                    hint: GitL10n.text("Run 'git init' in the terminal to initialize a repository.")
                )

            case .unborn:
                VStack(spacing: 12) {
                    tabPickerView
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                    tabContentView(headCommitID: nil)
                }

            case .detached(_, let commitID):
                VStack(spacing: 12) {
                    tabPickerView
                        .padding(.horizontal, 12)
                        .padding(.top, 10)

                    tabContentView(headCommitID: commitID.rawValue)
                }

            case .ssh(let host, let directory):
                emptyStateView(
                    systemImage: "network",
                    title: GitL10n.format("Remote Git ({0})", String(describing: host)),
                    subtitle: directory.isEmpty ? host : directory,
                    hint: GitL10n.text("Waiting for the SSH session to report its remote working directory.")
                )

            case .error(let title, let message):
                emptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: title,
                    subtitle: message,
                    hint: nil
                )

            case .ready(_, _, let headCommitID):
                VStack(spacing: 12) {
                    tabPickerView
                        .padding(.horizontal, 12)
                        .padding(.top, 10)

                    tabContentView(headCommitID: headCommitID?.rawValue)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: settings.language) { _ in perform(.gitAction(.refresh)) }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: content.connectionLabel == nil ? "arrow.triangle.branch" : "network")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)

                NativeActionButton(
                    title: content.repository?.repositoryName ?? "Git",
                    help: content.repository?.worktreePath ?? "",
                    height: 20,
                    showsHover: false,
                    menu: [
                        .action(GitL10n.text("Copy repository name"), symbol: "doc.on.doc") {
                            InspectorCopyMenu.copy(content.repository?.repositoryName ?? "Git")
                        },
                    ],
                    action: { _ in }
                )
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                if content.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }

                pullPushButton

                fetchButton
            }

            if let repository = content.repository {
                InspectorCopyText(text: repository.worktreePath).frame(height: 14)
                if let address = content.workingTree.remoteURL {
                    InspectorCopyText(text: address).frame(height: 14)
                }

            }
            if let connection = content.connectionLabel ?? content.repository?.sshConnection?.destination {
                InspectorCopyText(text: "SSH · " + connection).frame(height: 14)
            }
            if !headerReferences.isEmpty { GitHeaderReferences(refs: headerReferences) }
            if content.workingTree.branchesError == nil,
               let current = content.workingTree.branches.first(where: { $0.isCurrent }) {
                InspectorCopyText(text: current.upstreamTrackingDisplay)
                    .frame(height: 14)
            }
        }
    }

    private var pullPushButton: some View {
        GitPullPushControl(
            isBusy: isPullOrPushLoading,
            canPull: content.repository != nil && !isNetworkBusy && content.operation == nil && !isDetachedHead && hasRemote,
            canPush: content.repository != nil && !isNetworkBusy && content.operation == nil && !isDetachedHead && hasRemote && canPushCurrent,
            canPushTo: content.repository != nil && !isNetworkBusy && content.operation == nil && !isDetachedHead && hasRemote,
            canMerge: content.repository != nil && !isNetworkBusy && content.operation == nil && !isDetachedHead
                && GitForge(origin: content.workingTree.remoteURL) != nil,
            behindCount: currentBranch?.behindCount,
            aheadCount: currentBranch?.aheadCount,
            perform: { perform(.gitAction($0)) }
        )
        .frame(width: 24, height: 22)
        .help(GitL10n.text("Pull or Push"))
    }

    private var fetchButton: some View {
        NativeActionButton(
            symbol: isFetchLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
            help: GitL10n.text("Fetch remote changes"),
            enabled: content.repository != nil && !isNetworkBusy,
            style: .plain,
            height: 22,
            identifier: "git.fetch",
            menu: [
                .action(GitL10n.text("Fetch"), enabled: content.repository != nil && !isNetworkBusy) {
                    perform(.gitAction(.fetch))
                },
                .action(GitL10n.text("Refresh (Local Only)")) {
                    perform(.gitAction(.refreshLocal))
                },
                .separator,
                .submenu(GitL10n.text("Auto-Fetch Interval"), entries: [0, 1, 2, 5, 10, 15, 30, 60].map { minutes in
                    .action(
                        settingsStrings.gitAutoFetchIntervalTitle(minutes),
                        symbol: settings.gitAutoFetchInterval == minutes ? "checkmark" : nil,
                        checked: settings.gitAutoFetchInterval == minutes
                    ) {
                        settings.gitAutoFetchInterval = minutes
                    }
                }),
            ],
            action: { _ in perform(.gitAction(.fetch)) }
        )
        .frame(width: 24, height: 22)
        .help(GitL10n.text("Fetch remote changes"))
    }

    private var currentBranch: GitBranchInfo? {
        content.workingTree.branches.first(where: { $0.isCurrent })
    }

    private var canPushCurrent: Bool {
        guard let current = currentBranch else { return false }
        return current.aheadCount > 0
    }

    private var isFetchLoading: Bool {
        content.operation == GitL10n.text("Fetching…")
    }

    private var isPullOrPushLoading: Bool {
        content.operation == GitL10n.text("Pulling…") || content.operation == GitL10n.text("Pushing…")
    }

    private var isNetworkBusy: Bool {
        content.operation != nil
    }

    private var settingsStrings: SettingsStrings {
        SettingsStrings(language: settings.language)
    }

    private var isDetachedHead: Bool {
        switch content.status {
        case .detached: return true
        default: return false
        }
    }

    private var hasRemote: Bool {
        content.workingTree.remoteURL != nil || !content.workingTree.branches.filter(\.isRemote).isEmpty
    }

    private var headerReferences: [GitRefDecoration] {
        let branch: [GitRefDecoration]
        switch content.status {
        case .ready(_, let name, _), .unborn(_, let name): branch = [.init(name: name, kind: .currentBranch)]
        case .detached: branch = [.init(name: "HEAD", kind: .head)]
        default: branch = []
        }
        return branch + currentTags
    }

    private var currentTags: [GitRefDecoration] {
        let head: GitCommitID?
        switch content.status {
        case .ready(_, _, let id): head = id
        case .detached(_, let id): head = id
        default: head = nil
        }
        guard let head else { return [] }
        let refs = content.history.snapshot?.decorationsByCommitID[head] ??
            content.history.commits.first(where: { $0.id == head })?.refDecorations ?? []
        return refs.filter { $0.kind == .tag }
    }

    private var tabPickerView: some View {
        VStack(spacing: 6) {
        GitSidebarNavigation(selected: content.activeTab) { perform(.gitAction(.selectTab($0))) }
        HStack(spacing: 4) {
            GitCollectionToolbar(query: activeQuery, mode: $changesMode, placeholder: searchPlaceholder,
                                 showsMode: false, controller: activeController, cancel: { activeQuery.wrappedValue = "" })
            if content.activeTab == .branches {
                NativeActionButton(
                    symbol: "plus",
                    help: GitL10n.text("New Worktree"),
                    enabled: content.operation == nil && content.workingTree.worktreesError == nil,
                    height: 24,
                    identifier: "git.new-worktree",
                    action: { _ in perform(.gitAction(.createWorktree(nil))) }
                )
            }
            if content.activeTab != .history { GitCollectionModePicker(mode: $changesMode) }
        }
        }
        .task(id: collectionKey + "\n" + historyQuery) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            perform(.gitAction(.searchHistory(historyQuery.trimmingCharacters(in: .whitespacesAndNewlines))))
        }
    }

    private var activeQuery: Binding<String> {
        switch content.activeTab {
        case .history: $historyQuery
        case .changes: $changesQuery
        case .branches: $branchesQuery
        }
    }
    private var activeController: GitCollectionController {
        switch content.activeTab {
        case .history: historyController
        case .changes: changesController
        case .branches: branchesController
        }
    }

    private var searchPlaceholder: String {
        switch content.activeTab {
        case .history: GitL10n.text("Search commits…")
        case .changes: GitL10n.text("Search files…")
        case .branches: GitL10n.text("Search branches…")
        }
    }

    @ViewBuilder
    private func tabContentView(headCommitID: String?) -> some View {
        ZStack {
            historyView(headCommitID: headCommitID)
                .opacity(content.activeTab == .history ? 1 : 0)
                .allowsHitTesting(content.activeTab == .history)
                .accessibilityHidden(content.activeTab != .history)
            nonHistoryTabContent(headCommitID: headCommitID)
        }
    }

    @ViewBuilder
    private func nonHistoryTabContent(headCommitID: String?) -> some View {
        switch content.activeTab {
        case .history:
            EmptyView()

        case .changes:
            VStack(spacing: 0) {
                GitCollectionView(source: .changes(content.workingTree), mode: changesMode, query: changesQuery,
                    pending: content.pendingIndexPaths, canWrite: content.operation == nil || content.isUpdatingIndex,
                    state: collectionState, stateKey: collectionKey + "/changes", controller: changesController,
                    cancel: { changesQuery = "" }, perform: {
                    perform(.gitAction($0))
                })
                Divider()
                GitCommitComposer(message: Binding(get: { content.commitDraft }, set: { perform(.gitAction(.updateCommitDraft($0))) }),
                    stagedCount: content.workingTree.staged.count, isBusy: content.operation != nil,
                    canCommit: content.workingTree.stagedError == nil, isUpdatingIndex: content.isUpdatingIndex,
                    commit: { perform(.gitAction(.commitStaged)) }, repository: content.repository,
                    unstagedCount: content.workingTree.unstaged.count,
                    canStageAll: content.workingTree.unstagedError == nil, hasHead: headCommitID != nil,
                    submit: { perform(.gitAction(.submitCommit(stageAll: $0, amend: $1))) })
                .id(collectionKey)
                .padding(10)
            }
        case .branches:
            GitRefBrowser(branches: content.workingTree.branches, worktrees: content.workingTree.worktrees,
                          isBusy: content.operation != nil, branchesError: content.workingTree.branchesError,
                          worktreesError: content.workingTree.worktreesError,
                          externalQuery: branchesQuery, externalMode: changesMode, showsToolbar: false,
                          externalController: branchesController,
                          externalCancel: { branchesQuery = "" },
                          state: collectionState, stateKey: collectionKey + "/refs/sidebar",
                          perform: { perform(.gitAction($0)) })
        }
    }

    private func historyView(headCommitID: String?) -> some View {
        VStack(spacing: 8) {
            GitHistoryScopePicker(title: content.history.snapshot?.browsedBranch ?? content.history.scope.displayName,
                                  branches: content.workingTree.branches, enabled: content.workingTree.branchesError == nil,
                                  isActive: content.activeTab == .history, isBusy: content.operation != nil,
                                  worktrees: content.workingTree.worktrees, worktreesError: content.workingTree.worktreesError,
                                  state: collectionState, stateKey: collectionKey + "/refs/picker", selectedID: historySelectionID,
                                  tags: Array(Set(content.history.snapshot?.decorationsByCommitID.values.joined().filter { $0.kind == .tag } ?? [])).sorted { $0.name < $1.name }) {
                perform(.gitAction($0))
            }
            .frame(height: 28)
            .padding(.horizontal, 12)

            ZStack {
                GitHistoryTable(
                    commits: content.history.commits,
                    selectedCommitID: content.history.selectedCommitID,
                    headCommitID: content.history.snapshot?.headCommitID,
                    expandedCommits: content.expandedCommits,
                    fileMode: changesMode,
                    isSearching: !historyQuery.isEmpty,
                    isActive: content.activeTab == .history,
                    controller: historyController,
                    hasMore: content.history.hasMore,
                    isLoading: content.history.isLoading,
                    automaticLoadingAllowed: content.activeTab == .history && content.history.statusMessage == nil,
                    isBusy: content.operation != nil,
                    origin: content.workingTree.remoteURL,
                    onSelect: { perform(.gitAction(.selectCommit($0))) },
                    onOpen: { perform(.gitAction(.openCommit($0))) },
                    onShowInTerminal: {
                        perform(.gitAction(.sendHistoryToTerminal($0)))
                    },
                    onOpenFile: { commit, file in perform(.gitAction(.openDiff(file, .commit(commit)))) },
                    onGitFileAction: { file, directory in perform(.gitAction(.openGitFile(file, directory: directory))) },
                    onLoadMore: { perform(.gitAction(.loadMoreHistory)) },
                    onCommitAction: { perform(.gitAction(.commitOperation($0, $1))) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if content.history.commits.isEmpty && !content.history.isLoading {
                    Text(content.history.statusMessage ?? (headCommitID == nil ? GitL10n.text("No commits yet") : GitL10n.text("No history found")))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(12)
                }
            }

            if let message = content.history.statusMessage, !content.history.commits.isEmpty {
                Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
            }
            if content.history.isLoading && content.history.commits.isEmpty {
                ProgressView().controlSize(.small).padding(.vertical, 4)
            }
        }
    }

    private var historySelectionID: String {
        if let path = content.history.snapshot?.browsedWorktree { return "worktree:" + path }
        return content.history.snapshot?.browsedRef ?? "scope:" + content.history.scope.rawValue
    }

    private func emptyStateView(
        systemImage: String,
        title: String,
        subtitle: String,
        hint: String?
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.8))

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct GitHeaderActionButtonStyle: ButtonStyle {
    var selected: Bool = false
    var isBusy: Bool = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 24, height: 20)
            .background(background(isPressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(border(isPressed: configuration.isPressed), lineWidth: 0.75)
            )
            .contentShape(Rectangle())
            .opacity(!isEnabled ? 0.35 : 1.0)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }

    private func background(isPressed: Bool) -> Color {
        guard isEnabled else { return .clear }
        if selected {
            return Color.accentColor.opacity(isPressed ? 0.28 : isHovered ? 0.22 : 0.15)
        }
        if isPressed {
            return Color.primary.opacity(0.16)
        }
        if isHovered {
            return Color.primary.opacity(0.08)
        }
        return .clear
    }

    private func border(isPressed: Bool) -> Color {
        guard isEnabled else { return .clear }
        if selected {
            return Color.accentColor.opacity(isPressed ? 0.65 : isHovered ? 0.55 : 0.38)
        }
        if isPressed {
            return Color.primary.opacity(0.35)
        }
        if isHovered {
            return Color.primary.opacity(0.20)
        }
        return .clear
    }
}

private struct GitMenuRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isHovered && isEnabled ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .foregroundStyle(
                !isEnabled ? Color.secondary.opacity(0.4) :
                isHovered ? Color.white : Color.primary
            )
            .onHover { isHovered = $0 }
    }
}
