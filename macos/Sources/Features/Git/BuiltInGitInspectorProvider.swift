import AppKit
import Foundation
import OSLog

@MainActor
final class BuiltInGitInspectorProvider {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "oh-my-ghostty",
        category: "git-inspector"
    )

    static let pluginID = "builtin.git"
    static let paneID = "builtin.git"

    struct WorktreeUIState: Equatable, Sendable {
        var activeTab: InspectorGitContent.ActiveTab = .history
        var browsedBranch: String?
        var browsedWorktree: String?
        var commitDraft: String = ""
        var operationError: String?
        var detailCache: [GitCommitID: GitCommitExpansion] = [:]
        var detailCacheOrder: [GitCommitID] = []
        var expandedCommits: [GitCommitID: GitCommitExpansion] = [:]
        var selectedCommitID: GitCommitID?
        var historyScope: GitHistoryScope = .allBranches
        var historyQuery = ""
        var unfilteredHistory: InspectorGitHistoryContent?
        var history: InspectorGitHistoryContent = InspectorGitHistoryContent()
    }

    private let registry: InspectorRegistry
    private let repositoryService: GitRepositoryService
    private let historyService: GitHistoryService
    private let diffService: GitDiffService
    private let mutationService: GitMutationService
    private let terminalBridge: GitTerminalBridge
    private var presentedContexts: [UUID: InspectorPaneContext] = [:]
    private var loadTasks: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UInt64] = [:]
    private var historyTasks: [UUID: Task<Void, Never>] = [:]
    private var historyGenerations: [UUID: UInt64] = [:]
    private var pendingHistoryRefreshes: [UUID: Bool] = [:]
    private var tabWorktreeStates: [UUID: [String: WorktreeUIState]] = [:]
    private var lastPublishedContent: [UUID: InspectorGitContent] = [:]
    private var pollTimer: Timer?
    private var mutationTasks: [String: Task<Void, Never>] = [:]
    private var operationTitles: [String: String] = [:]
    private var indexUpdates = Set<String>()
    private struct IndexRequest {
        let mutation: GitMutation
        let context: InspectorPaneContext
    }
    private var indexQueues: [String: [IndexRequest]] = [:]
    private var pendingIndexPaths: [String: Set<String>] = [:]
    private struct DetailKey: Hashable {
        let tabID: UUID
        let worktree: String
        let commit: GitCommitID
    }
    private var detailTasks: [DetailKey: Task<Void, Never>] = [:]
    private var lastRemotePoll: [UUID: Date] = [:]
    private var resolvedDirectories: [UUID: String] = [:]

    init(
        registry: InspectorRegistry,
        repositoryService: GitRepositoryService? = nil,
        historyService: GitHistoryService? = nil,
        terminalBridge: GitTerminalBridge? = nil,
        executor: (any GitExecutor)? = nil
    ) {
        self.registry = registry
        self.repositoryService = repositoryService ?? GitRepositoryService(executor: executor)
        self.historyService = historyService ?? GitHistoryService(executor: executor)
        self.diffService = GitDiffService(executor: executor)
        self.mutationService = GitMutationService(executor: executor)
        self.terminalBridge = terminalBridge ?? GitTerminalBridge()
    }

    func register() throws {
        let descriptor = InspectorPaneDescriptor(id: Self.paneID, title: "Git", systemImage: "arrow.triangle.branch", source: .plugin(Self.pluginID), preferredWidth: RightInspectorMetrics.defaultWidth, minimumWidth: 220)
        try registry.registerPluginPane(descriptor, lifecycle: { [weak self] event in self?.handle(event) }, action: { [weak self] action in self?.handle(action) })
    }

    func forgetTab(_ tabID: UUID) {
        cancelTask(tabID: tabID)
        for key in detailTasks.keys where key.tabID == tabID { detailTasks.removeValue(forKey: key)?.cancel() }
        presentedContexts.removeValue(forKey: tabID)
        // Keep authored drafts for tab restoration without retaining history,
        // file lists or expanded commit details behind a closed window.
        let drafts = tabWorktreeStates[tabID, default: [:]].filter { !$0.value.commitDraft.isEmpty }
            .mapValues { WorktreeUIState(commitDraft: $0.commitDraft) }
        if drafts.isEmpty { tabWorktreeStates.removeValue(forKey: tabID) } else { tabWorktreeStates[tabID] = drafts }
        lastPublishedContent.removeValue(forKey: tabID)
        resolvedDirectories.removeValue(forKey: tabID)
        lastRemotePoll.removeValue(forKey: tabID)
        generations.removeValue(forKey: tabID)
        historyGenerations.removeValue(forKey: tabID)
        if presentedContexts.isEmpty { stopPollingTimer() }
    }

    private func handle(_ event: InspectorPaneLifecycleEvent) {
        switch event {
        case .appeared(let context):
            let returning = presentedContexts[context.tabID] == nil
            presentedContexts[context.tabID] = context
            let cached = lastPublishedContent[context.tabID]
            let canReuse = returning && cached?.repository?.matches(context.session) == true &&
                resolvedDirectories[context.tabID] == context.workingDirectory &&
                cached?.isLoading == false && cached?.history.isLoading == false
            // Re-enter with the ready snapshot. Normal polling refreshes it;
            // rapid pane switches must not launch/cancel full SSH queries.
            if !canReuse { load(context: context) }
            ensurePollingTimer()
        case .disappeared(let context): cancelTask(tabID: context.tabID); presentedContexts.removeValue(forKey: context.tabID); if presentedContexts.isEmpty { stopPollingTimer() }
        }
    }

    private func handle(_ action: InspectorPaneAction) {
        guard case .gitAction(let gitAction) = action.kind else { return }
        switch gitAction {
        case .refresh:
            let key = currentWorktreeKey(for: action.context)
            var value = state(for: action.context.tabID, worktreeKey: key)
            value.detailCache.removeAll(); value.detailCacheOrder.removeAll()
            value.unfilteredHistory = nil
            save(value, tabID: action.context.tabID, worktreeKey: key)
            load(context: action.context, force: true)
        case .selectTab(let tab):
            let key = currentWorktreeKey(for: action.context)
            var state = state(for: action.context.tabID, worktreeKey: key); state.activeTab = tab; save(state, tabID: action.context.tabID, worktreeKey: key)
            if let current = lastPublishedContent[action.context.tabID] {
                publish(makeContent(from: current, activeTab: tab, history: state.history), tabID: action.context.tabID)
                if tab == .history && state.history.snapshot == nil { loadHistory(context: action.context, force: true) }
            }
        case .selectHistoryScope(let scope):
            let key = currentWorktreeKey(for: action.context)
            var state = state(for: action.context.tabID, worktreeKey: key)
            guard state.historyScope != scope || state.browsedBranch != nil || state.browsedWorktree != nil else { return }
            state.browsedBranch = nil
            state.unfilteredHistory = nil
            state.browsedWorktree = nil
            state.historyScope = scope; state.selectedCommitID = nil; state.history = InspectorGitHistoryContent(scope: scope, isLoading: true); save(state, tabID: action.context.tabID, worktreeKey: key)
            if let current = lastPublishedContent[action.context.tabID] { publish(makeContent(from: current, history: state.history), tabID: action.context.tabID) }
            loadHistory(context: action.context, force: true)
        case .searchHistory(let query):
            let key = currentWorktreeKey(for: action.context)
            var value = state(for: action.context.tabID, worktreeKey: key)
            guard value.historyQuery != query else { return }
            if value.historyQuery.isEmpty {
                value.unfilteredHistory = value.history.isLoading || value.history.snapshot == nil ? nil : value.history
            }
            value.historyQuery = query
            cancelHistoryTask(tabID: action.context.tabID)
            if query.isEmpty, let cached = value.unfilteredHistory {
                value.history = cached
                value.selectedCommitID = cached.selectedCommitID
                value.unfilteredHistory = nil
                save(value, tabID: action.context.tabID, worktreeKey: key)
                if let current = lastPublishedContent[action.context.tabID] {
                    publish(makeContent(from: current, history: cached), tabID: action.context.tabID)
                }
            } else {
                save(value, tabID: action.context.tabID, worktreeKey: key)
                loadHistory(context: action.context, force: true)
            }
        case .loadMoreHistory: loadHistory(context: action.context, force: false)
        case .selectCommit(let commitID):
            let key = currentWorktreeKey(for: action.context)
            var state = state(for: action.context.tabID, worktreeKey: key)
            guard state.history.commits.contains(where: { $0.id == commitID }) else { return }
            state.selectedCommitID = commitID
            state.history = InspectorGitHistoryContent(scope: state.history.scope, commits: state.history.commits, selectedCommitID: commitID, hasMore: state.history.hasMore, isLoading: state.history.isLoading, statusMessage: state.history.statusMessage, snapshot: state.history.snapshot)
            save(state, tabID: action.context.tabID, worktreeKey: key)
            if let current = lastPublishedContent[action.context.tabID] { publish(makeContent(from: current, history: state.history), tabID: action.context.tabID) }
        case .openCommit(let commitID):
            toggleCommit(commitID, context: action.context)
        case .openDiff(let file, let target):
            guard let content = lastPublishedContent[action.context.tabID], let repository = content.repository else { return }
            let files: [GitDiffFile]
            switch target {
            case .comparison: return
            case .staged:
                guard content.workingTree.stagedError == nil else { return }
                files = content.workingTree.staged
            case .unstaged:
                guard content.workingTree.unstagedError == nil else { return }
                files = content.workingTree.unstaged
            case .commit(let commit):
                guard content.history.commits.contains(where: { $0.id == commit }) else { return }
                files = content.expandedCommits[commit]?.files ?? []
            }
            guard files.contains(file) else { return }
            EditorWorkspaceStore.shared.openGitDiff(repository: repository, target: target,
                                                     file: file, context: action.context)
        case .browseBranch(let name), .browseRef(let name):
            guard let content = lastPublishedContent[action.context.tabID],
                  (content.workingTree.branchesError == nil && content.workingTree.branches.contains(where: { $0.id == name })) ||
                    content.history.snapshot?.decorationsByCommitID.values.joined().contains(where: { $0.kind == .tag && $0.fullRef == name }) == true else { return }
            let key = currentWorktreeKey(for: action.context)
            var state = state(for: action.context.tabID, worktreeKey: key)
            state.activeTab = .history
            state.browsedBranch = name
            state.unfilteredHistory = nil
            state.browsedWorktree = nil
            state.selectedCommitID = nil
            state.history = InspectorGitHistoryContent(scope: state.historyScope)
            save(state, tabID: action.context.tabID, worktreeKey: key)
            publish(makeContent(from: content, activeTab: .history, history: state.history), tabID: action.context.tabID)
            loadHistory(context: action.context, force: true)
        case .browseWorktree(let path):
            guard let content = lastPublishedContent[action.context.tabID], let repository = content.repository,
                  content.workingTree.worktreesError == nil,
                  content.workingTree.worktrees.contains(where: { $0.path == path && !$0.isBare }) else { return }
            var state = state(for: action.context.tabID, worktreeKey: repository.stateKey)
            state.activeTab = .history
            state.browsedBranch = nil
            state.browsedWorktree = path
            state.unfilteredHistory = nil
            state.selectedCommitID = nil
            state.history = InspectorGitHistoryContent(scope: state.historyScope)
            save(state, tabID: action.context.tabID, worktreeKey: repository.stateKey)
            publish(makeContent(from: content, activeTab: .history, history: state.history), tabID: action.context.tabID)
            loadHistory(context: action.context, force: true)
        case .commitOperation(let operation, let commit):
            handleCommit(operation, id: commit, context: action.context)
        case .createWorktree, .openWorktree, .removeWorktree:
            handleWorktree(gitAction, context: action.context)
        case .branchOperation(let operation, let ref):
            guard let content = lastPublishedContent[action.context.tabID], let repository = content.repository,
                  content.workingTree.branchesError == nil,
                  let branch = content.workingTree.branches.first(where: { $0.id == ref }),
                  mutationTasks[repository.stateKey] == nil,
                  !branch.isRemote || operation == .checkout || operation == .create else { return }
            let window = NSApp.windows.first { ($0.windowController as? TerminalController)?.tabSessionID == action.context.tabID }
            Task {
                do {
                    if let mutation = try await GitBranchDialogs.mutation(for: operation, branch: branch,
                        branches: content.workingTree.branches, repository: repository, window: window) {
                        self.mutate(mutation, repository: repository, context: action.context)
                    }
                } catch { self.publishOperationError(error.localizedDescription, repository: repository, context: action.context) }
            }
        case .openGitFile(let file, let directory):
            guard let content = lastPublishedContent[action.context.tabID], let repository = content.repository,
                  (content.workingTree.staged + content.workingTree.unstaged + content.expandedCommits.values.flatMap(\.files)).contains(file) else { return }
            do { try GitFileActions.open(file, repository: repository, context: action.context, directory: directory) } catch { publishOperationError(error.localizedDescription, repository: repository, context: action.context) }
        case .discardChanges(let file, let staged):
            confirmDiscard(.init(entries: [.init(file: file, section: staged ? .staged : .unstaged)]), context: action.context)
        case .discardSelectedChanges(let batch):
            confirmDiscard(batch, context: action.context)
        case .setFileStaged(let file, let staged):
            guard let content = lastPublishedContent[action.context.tabID], let repository = content.repository,
                  (staged ? content.workingTree.unstagedError : content.workingTree.stagedError) == nil,
                  (staged ? content.workingTree.unstaged : content.workingTree.staged).contains(file) else { return }
            let paths = Array(Set([file.path] + (file.oldPath.map { [$0] } ?? []))).sorted()
            mutate(staged ? .stage(paths) : .unstage(paths), repository: repository, context: action.context)
        case .setFilesStaged(let files, let staged):
            guard let content = lastPublishedContent[action.context.tabID], let repository = content.repository else { return }
            let available = Set(content.workingTree.staged + content.workingTree.unstaged)
            guard !files.isEmpty, content.workingTree.stagedError == nil, content.workingTree.unstagedError == nil,
                  files.allSatisfy(available.contains) else { return }
            let paths = Array(Set(files.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) })).sorted()
            mutate(staged ? .stage(paths) : .unstage(paths), repository: repository, context: action.context)
        case .updateCommitDraft(let draft):
            let key = currentWorktreeKey(for: action.context)
            var state = state(for: action.context.tabID, worktreeKey: key)
            state.commitDraft = draft
            save(state, tabID: action.context.tabID, worktreeKey: key)
            if let current = lastPublishedContent[action.context.tabID] { publish(current, tabID: action.context.tabID) }
        case .clearOperationError:
            let key = currentWorktreeKey(for: action.context)
            var state = state(for: action.context.tabID, worktreeKey: key)
            state.operationError = nil
            save(state, tabID: action.context.tabID, worktreeKey: key)
            if let content = lastPublishedContent[action.context.tabID] { publish(content, tabID: action.context.tabID) }
        case .commitStaged:
            guard let content = lastPublishedContent[action.context.tabID], let repository = content.repository,
                  content.workingTree.stagedError == nil,
                  !content.workingTree.staged.isEmpty else { return }
            mutate(.commit(content.commitDraft), repository: repository, context: action.context)
        case .sendHistoryToTerminal(let commitID):
            guard let content = lastPublishedContent[action.context.tabID],
                  let repository = content.repository else { return }
            let intent: GitTerminalCommandIntent
            if let commitID {
                guard content.history.commits.contains(where: { $0.id == commitID }) else {
                    return
                }
                intent = .show(repository: repository, commit: commitID)
            } else {
                intent = .log(repository: repository)
            }
            _ = terminalBridge.dispatch(intent, in: action.context)
        }
    }

    private func load(context: InspectorPaneContext, force: Bool = false) {
        if let repository = lastPublishedContent[context.tabID]?.repository,
           mutationTasks[repository.stateKey] != nil, repository.matches(context.session),
           context.workingDirectory == resolvedDirectories[context.tabID] { return }
        loadTasks.removeValue(forKey: context.tabID)?.cancel()
        let generation = nextGeneration(for: context.tabID)
        let key = currentWorktreeKey(for: context)
        let activeTab = state(for: context.tabID, worktreeKey: key).activeTab
        switch context.session.state {
        case .sshReady: break
        case .sshConnecting(let ssh): publish(InspectorGitContent(status: .ssh(host: ssh.alias, workingDirectory: ""), activeTab: activeTab), tabID: context.tabID); return
        case .local: break
        }
        guard let directory = context.workingDirectory, !directory.isEmpty else { publish(InspectorGitContent(status: .notRepository(directory: ""), activeTab: activeTab), tabID: context.tabID); return }
        let oldContent = lastPublishedContent[context.tabID].flatMap { value in
            value.repository?.matches(context.session) == true && resolvedDirectories[context.tabID] == directory ? value : nil
        }
        if oldContent == nil {
            var loading = InspectorGitContent(repository: oldContent?.repository, branch: oldContent?.branch,
                status: oldContent?.status ?? .notRepository(directory: directory), activeTab: activeTab,
                history: state(for: context.tabID, worktreeKey: key).history, isLoading: true)
            loading.workingTree = oldContent?.workingTree ?? GitWorkingTreeContent()
            publish(loading, tabID: context.tabID)
        }
        loadTasks[context.tabID] = Task { [weak self] in
            guard let self else { return }
            let status = await self.repositoryService.resolveStatus(workingDirectory: directory, session: context.session)
            guard !Task.isCancelled, self.generations[context.tabID] == generation else { return }
            self.resolvedDirectories[context.tabID] = directory
            var workingTree = oldContent?.repository == status.repository
                ? (oldContent?.workingTree ?? GitWorkingTreeContent()) : GitWorkingTreeContent()
            if let repository = status.repository {
                async let files = Self.readFiles(service: self.diffService, repository: repository)
                async let branches = Self.result { try await self.repositoryService.branches(for: repository) }
                async let worktrees = Self.result { try await self.repositoryService.worktrees(for: repository, includeStatus: force || activeTab == .branches) }
                Self.updateFiles(await files, workingTree: &workingTree)
                Self.update(await branches, values: &workingTree.branches, error: &workingTree.branchesError)
                Self.update(await worktrees, values: &workingTree.worktrees, error: &workingTree.worktreesError)
                if force || oldContent?.repository != repository {
                    workingTree.remoteURL = try? await self.repositoryService.remoteAddress(for: repository)
                }
            }
            guard !Task.isCancelled, self.generations[context.tabID] == generation else { return }
            let repo = status.repository; let resolvedKey = repo?.stateKey ?? self.currentWorktreeKey(for: context)
            let latestState = self.state(for: context.tabID, worktreeKey: resolvedKey)
            if self.lastPublishedContent[context.tabID]?.repository != repo {
                self.cancelHistoryTask(tabID: context.tabID)
            }
            self.loadTasks.removeValue(forKey: context.tabID)
            var content = InspectorGitContent(repository: repo, branch: status.headDescription, status: status,
                                              activeTab: latestState.activeTab, history: latestState.history)
            content.workingTree = workingTree
            self.publish(content, tabID: context.tabID)
            if repo != nil, content.activeTab == .history || force { self.loadHistory(context: context, force: force, refreshing: true) }
        }
    }

    private func loadHistory(context: InspectorPaneContext, force: Bool, refreshing: Bool = false) {
        guard let current = lastPublishedContent[context.tabID], let repository = current.repository else { return }
        if refreshing, historyTasks[context.tabID] != nil {
            pendingHistoryRefreshes[context.tabID] = force || (pendingHistoryRefreshes[context.tabID] ?? false)
            return
        }
        guard force || refreshing || (current.history.hasMore && !current.history.isLoading) else { return }
        cancelHistoryTask(tabID: context.tabID)
        let generation = historyGenerations[context.tabID, default: 0]
        let key = repository.stateKey
        let stateBefore = state(for: context.tabID, worktreeKey: key)
        let replacing = force && !refreshing
        let oldCommits = replacing ? [] : stateBefore.history.commits
        let offset = replacing || refreshing ? 0 : oldCommits.count
        let loading = InspectorGitHistoryContent(scope: stateBefore.historyScope, commits: oldCommits,
            selectedCommitID: replacing ? nil : stateBefore.selectedCommitID, hasMore: stateBefore.history.hasMore,
            isLoading: true, snapshot: replacing ? nil : stateBefore.history.snapshot)
        var loadingState = stateBefore
        loadingState.history = loading
        if replacing { loadingState.selectedCommitID = nil }
        save(loadingState, tabID: context.tabID, worktreeKey: key)
        if !refreshing || force || stateBefore.history.snapshot == nil {
            publish(makeContent(from: current, history: loading), tabID: context.tabID)
        }
        historyTasks[context.tabID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.historyGenerations[context.tabID] == generation {
                    self.historyTasks.removeValue(forKey: context.tabID)
                    if let pending = self.pendingHistoryRefreshes.removeValue(forKey: context.tabID),
                       let latest = self.presentedContexts[context.tabID] {
                        self.loadHistory(context: latest, force: pending, refreshing: true)
                    }
                }
            }
            do {
                let snapshot = force || refreshing || stateBefore.history.snapshot == nil
                    ? try await self.captureSnapshot(repository: repository, state: stateBefore) : stateBefore.history.snapshot!
                var loaded = stateBefore.history
                if !refreshing || force || snapshot != stateBefore.history.snapshot {
                    let page = try await self.historyService.loadPage(snapshot: snapshot, repository: repository, offset: offset,
                        pageSize: refreshing ? max(GitHistoryService.pageSize, oldCommits.count) : GitHistoryService.pageSize,
                        query: stateBefore.historyQuery)
                    loaded = InspectorGitHistoryContent(scope: stateBefore.historyScope,
                        commits: (refreshing ? [] : oldCommits) + page.commits, hasMore: page.hasMore, snapshot: snapshot)
                }
                guard !Task.isCancelled, self.historyGenerations[context.tabID] == generation else { return }
                var updated = self.state(for: context.tabID, worktreeKey: key)
                let history = InspectorGitHistoryContent(scope: updated.historyScope, commits: loaded.commits,
                    selectedCommitID: updated.selectedCommitID, hasMore: loaded.hasMore,
                    statusMessage: loaded.statusMessage, snapshot: loaded.snapshot)
                updated.history = history
                self.save(updated, tabID: context.tabID, worktreeKey: key)
                if let latest = self.lastPublishedContent[context.tabID] { self.publish(self.makeContent(from: latest, history: history), tabID: context.tabID) }
            } catch {
                guard !Task.isCancelled, self.historyGenerations[context.tabID] == generation else { return }
                var state = self.state(for: context.tabID, worktreeKey: key)
                let history = InspectorGitHistoryContent(scope: stateBefore.historyScope, commits: oldCommits,
                    selectedCommitID: state.selectedCommitID, hasMore: stateBefore.history.hasMore,
                    statusMessage: error.localizedDescription, snapshot: stateBefore.history.snapshot)
                state.history = history
                self.save(state, tabID: context.tabID, worktreeKey: key)
                if let latest = self.lastPublishedContent[context.tabID] { self.publish(self.makeContent(from: latest, history: history), tabID: context.tabID) }
            }
        }
    }

    private func toggleCommit(_ commit: GitCommitID, context: InspectorPaneContext) {
        guard let content = lastPublishedContent[context.tabID], let repository = content.repository,
              content.history.commits.contains(where: { $0.id == commit }) else { return }
        let worktree = repository.stateKey
        let key = DetailKey(tabID: context.tabID, worktree: worktree, commit: commit)
        var state = state(for: context.tabID, worktreeKey: worktree)
        if state.expandedCommits.removeValue(forKey: commit) != nil {
            detailTasks.removeValue(forKey: key)?.cancel()
            save(state, tabID: context.tabID, worktreeKey: worktree)
            publish(content, tabID: context.tabID)
            return
        }
        if let cached = state.detailCache[commit] {
            state.expandedCommits[commit] = cached
            save(state, tabID: context.tabID, worktreeKey: worktree)
            publish(content, tabID: context.tabID)
            return
        }
        let parents = content.history.commits.first(where: { $0.id == commit })?.parentIDs
        state.expandedCommits[commit] = GitCommitExpansion(isLoading: true)
        save(state, tabID: context.tabID, worktreeKey: worktree)
        publish(content, tabID: context.tabID)
        detailTasks[key] = Task {
            let detail: GitCommitExpansion
            do {
                let service = self.diffService
                async let metadata = service.loadCommitMetadata(for: commit, repository: repository)
                async let list = service.listFiles(for: repository, target: .commit(commit), parentIDs: parents)
                detail = try await GitCommitExpansion(metadata: metadata, files: list.files, statistics: list.statistics)
            } catch { detail = GitCommitExpansion(error: error.localizedDescription) }
            guard !Task.isCancelled else { return }
            var current = self.state(for: context.tabID, worktreeKey: worktree)
            guard current.expandedCommits[commit] != nil else { return }
            current.expandedCommits[commit] = detail
            if detail.error == nil {
                current.detailCache[commit] = detail
                current.detailCacheOrder.removeAll { $0 == commit }
                current.detailCacheOrder.append(commit)
                if current.detailCacheOrder.count > 32 {
                    current.detailCache.removeValue(forKey: current.detailCacheOrder.removeFirst())
                }
            }
            self.save(current, tabID: context.tabID, worktreeKey: worktree)
            self.detailTasks.removeValue(forKey: key)
            if let latest = self.lastPublishedContent[context.tabID], latest.repository == repository,
               self.presentedContexts[context.tabID] != nil { self.publish(latest, tabID: context.tabID) }
        }
    }

    private func captureSnapshot(repository: GitRepositoryIdentity, state: WorktreeUIState) async throws -> GitHistorySnapshot {
        let snapshot = try await historyService.captureSnapshot(for: repository, scope: state.historyScope)
        if let path = state.browsedWorktree {
            let trees = try await repositoryService.worktrees(for: repository)
            guard let tree = trees.first(where: { $0.path == path && !$0.isBare }) else {
                throw GitDiffServiceError.gitFailed(GitL10n.format("Worktree no longer exists: {0}", String(describing: path)))
            }
            return GitHistorySnapshot(scope: snapshot.scope, branchName: snapshot.branchName,
                headCommitID: tree.head, tipCommitIDs: tree.head.map { [$0] } ?? [],
                decorationsByCommitID: snapshot.decorationsByCommitID,
                browsedBranch: tree.branchRef == nil ? tree.head?.shortSHA ?? GitL10n.text("No commits") : tree.branchName,
                browsedWorktree: path)
        }
        guard let branch = state.browsedBranch else { return snapshot }
        if branch.hasPrefix("refs/tags/") {
            let result = try await (repositoryService.executor ?? repository.executor).execute(arguments: ["rev-parse", "--verify", branch + "^{commit}"], workingDirectory: repository.worktreePath)
            guard result.isSuccess else { throw GitDiffServiceError.gitFailed(result.stderrString) }
            return GitHistorySnapshot(scope: snapshot.scope, branchName: snapshot.branchName,
                headCommitID: snapshot.headCommitID, tipCommitIDs: [.init(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))],
                decorationsByCommitID: snapshot.decorationsByCommitID, browsedBranch: String(branch.dropFirst("refs/tags/".count)), browsedRef: branch)
        }
        let branches = try await repositoryService.branches(for: repository)
        guard let tip = branches.first(where: { $0.id == branch }) else {
            throw GitDiffServiceError.gitFailed(GitL10n.format("Branch no longer exists: {0}", String(describing: branch)))
        }
        return GitHistorySnapshot(scope: snapshot.scope, branchName: snapshot.branchName,
                                  headCommitID: snapshot.headCommitID, tipCommitIDs: [tip.commit],
                                  decorationsByCommitID: snapshot.decorationsByCommitID, browsedBranch: tip.name, browsedRef: tip.id)
    }

    private func ensurePollingTimer() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollActiveTabs() } }
    }
    private func stopPollingTimer() { pollTimer?.invalidate(); pollTimer = nil }

    private func pollActiveTabs() {
        guard NSApp.isActive else { return }
        for (tabID, context) in presentedContexts {
            guard loadTasks[tabID] == nil, let directory = context.workingDirectory, !directory.isEmpty else { continue }
            if case .sshConnecting = context.session.state { continue }
            if case .sshReady = context.session.state {
                let now = Date()
                guard now.timeIntervalSince(lastRemotePoll[tabID] ?? .distantPast) >= 10 else { continue }
                lastRemotePoll[tabID] = now
            }
            load(context: context)

        }
    }

    private func makeContent(from current: InspectorGitContent, activeTab: InspectorGitContent.ActiveTab? = nil,
                             history: InspectorGitHistoryContent? = nil) -> InspectorGitContent {
        var content = InspectorGitContent(repository: current.repository, branch: current.branch, status: current.status,
                                         activeTab: activeTab ?? current.activeTab, history: history ?? current.history,
                                         isLoading: current.isLoading, statusMessage: current.statusMessage)
        content.workingTree = current.workingTree
        return content
    }

    private func state(for tabID: UUID, worktreeKey: String) -> WorktreeUIState { tabWorktreeStates[tabID]?[worktreeKey] ?? WorktreeUIState() }
    private func save(_ state: WorktreeUIState, tabID: UUID, worktreeKey: String) { guard !registry.isTabClosed(tabID) else { return }; var states = tabWorktreeStates[tabID] ?? [:]; states[worktreeKey] = state; tabWorktreeStates[tabID] = states }
    private func publish(_ value: InspectorGitContent, tabID: UUID) {
        guard !registry.isTabClosed(tabID) else { return }
        var content = value
        if let context = presentedContexts[tabID] {
            switch context.session.state {
            case .local: content.connectionLabel = nil
            case .sshConnecting(let ssh), .sshReady(let ssh, _): content.connectionLabel = ssh.transferTarget
            }
        }
        if let key = content.repository?.stateKey {
            let state = state(for: tabID, worktreeKey: key)
            content.expandedCommits = state.expandedCommits
            content.commitDraft = state.commitDraft
            content.operationError = state.operationError
            content.operation = operationTitles[key]
            content.isUpdatingIndex = indexUpdates.contains(key)
            content.pendingIndexPaths = pendingIndexPaths[key] ?? []
        }
        guard lastPublishedContent[tabID] != content else { return }
        lastPublishedContent[tabID] = content
        do {
            try registry.updatePluginContent(paneID: Self.paneID, pluginID: Self.pluginID,
                                             tabID: tabID, content: .git(content))
        } catch { Self.logger.error("Git state publish failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func handleCommit(_ operation: GitCommitOperation, id: GitCommitID, context: InspectorPaneContext) {
        guard let content = lastPublishedContent[context.tabID], let repository = content.repository,
              let commit = content.history.commits.first(where: { $0.id == id }) else { return }
        if operation == .details {
            if content.expandedCommits[id] == nil { toggleCommit(id, context: context) }
            return
        }
        guard !operation.modifiesRepository || mutationTasks[repository.stateKey] == nil else { return }
        let window = TerminalController.all.first { $0.tabSessionID == context.tabID }?.window
        Task {
            do {
                switch operation {
                case .compareWithHead:
                    let head = try await self.repositoryService.headCommit(for: repository)
                    guard self.lastPublishedContent[context.tabID]?.repository == repository else { return }
                    EditorWorkspaceStore.shared.openGitDiff(repository: repository, target: .comparison(base: id, head: head), context: context)
                case .createWorktree, .detachedWorktree:
                    if let creation = await GitWorktreeActions.creation(start: id.rawValue, repository: repository, window: window,
                                                                        detached: operation == .detachedWorktree) {
                        self.mutate(creation.mutation, repository: repository, context: context, openCreatedWorktree: creation.openAfterCreation)
                    }
                case .createBranch, .cherryPick, .revert:
                    if let mutation = await GitCommitActions.mutation(operation, commit: commit, window: window) {
                        self.mutate(mutation, repository: repository, context: context)
                    }
                case .details: break
                }
            } catch { self.publishOperationError(error.localizedDescription, repository: repository, context: context) }
        }
    }

    private func refreshIndex(repository: GitRepositoryIdentity, paths: [String]) async {
        // Bulk operations use one complete status read, avoiding a huge SSH
        // command argument and N successive refreshes for N files.
        let files = await Self.result { try await self.diffService.workingTreeFiles(for: repository, paths: paths.count > 1 ? nil : paths) }
        let fallback: (staged: Result<[GitDiffFile], Error>, unstaged: Result<[GitDiffFile], Error>)?
        if case .failure(let error) = files {
            // A bulk action owns one status read. Retain the previous snapshot
            // on failure rather than starting another chain of remote reads.
            if paths.count > 1 || (error as? GitExecutionError) == .timedOut {
                fallback = (.failure(error), .failure(error))
            } else { fallback = await Self.readFiles(service: diffService, repository: repository) }
        } else { fallback = nil }
        pendingIndexPaths[repository.stateKey]?.subtract(paths)
        for (tabID, var content) in lastPublishedContent where content.repository == repository {
            if let fallback { Self.updateFiles(fallback, workingTree: &content.workingTree) } else if case .success(let files) = files {
                if paths.count > 1 {
                    content.workingTree.staged = files.staged
                    content.workingTree.unstaged = files.unstaged
                    content.workingTree.stagedError = nil
                    content.workingTree.unstagedError = nil
                } else { content.workingTree.applyIndexChanges(paths: paths, staged: files.staged, unstaged: files.unstaged) }
            }
            publish(content, tabID: tabID)
        }
    }

    private func enqueueIndexMutation(_ mutation: GitMutation, repository: GitRepositoryIdentity, context: InspectorPaneContext) {
        let key = repository.stateKey
        guard let paths = mutation.indexPaths else { return }
        guard mutationTasks[key] == nil || indexUpdates.contains(key) else {
            publishOperationError(GitL10n.text("Another Git operation is running in this worktree."), repository: repository, context: context)
            return
        }
        guard pendingIndexPaths[key, default: []].isDisjoint(with: paths) else { return }
        indexQueues[key, default: []].append(.init(mutation: mutation, context: context))
        pendingIndexPaths[key, default: []].formUnion(paths)
        indexUpdates.insert(key)
        operationTitles[key] = operationTitles[key] ?? mutation.title
        var state = state(for: context.tabID, worktreeKey: key)
        state.operationError = nil
        save(state, tabID: context.tabID, worktreeKey: key)
        for (tabID, content) in lastPublishedContent where content.repository == repository {
            loadTasks.removeValue(forKey: tabID)?.cancel()
            _ = nextGeneration(for: tabID)
            publish(content, tabID: tabID)
        }
        guard mutationTasks[key] == nil else { return }
        mutationTasks[key] = Task {
            while let request = self.indexQueues[key]?.first, let paths = request.mutation.indexPaths {
                let mutation = request.mutation
                self.indexQueues[key]?.removeFirst()
                self.operationTitles[key] = mutation.title
                do {
                    try await self.mutationService.perform(mutation, in: repository)
                    await self.refreshIndex(repository: repository, paths: paths)
                } catch {
                    self.pendingIndexPaths[key]?.subtract(paths)
                    self.publishOperationError(error.localizedDescription, repository: repository, context: request.context)
                }
            }
            self.indexQueues.removeValue(forKey: key)
            self.pendingIndexPaths.removeValue(forKey: key)
            self.indexUpdates.remove(key)
            self.operationTitles.removeValue(forKey: key)
            self.mutationTasks.removeValue(forKey: key)
            for (tabID, content) in self.lastPublishedContent where content.repository == repository { self.publish(content, tabID: tabID) }
        }
    }

    nonisolated private static func readFiles(service: GitDiffService, repository: GitRepositoryIdentity)
        async -> (staged: Result<[GitDiffFile], Error>, unstaged: Result<[GitDiffFile], Error>) {
        do {
            let files = try await service.workingTreeFiles(for: repository)
            return (.success(files.staged), .success(files.unstaged))
        } catch {
            guard !Task.isCancelled else { return (.failure(error), .failure(error)) }
            // Preserve independent error handling if only one side is readable.
            async let staged = result { try await service.listFiles(for: repository, target: .staged).files }
            async let unstaged = result { try await service.listFiles(for: repository, target: .unstaged).files }
            return await (staged, unstaged)
        }
    }

    private static func updateFiles(
        _ result: (staged: Result<[GitDiffFile], Error>, unstaged: Result<[GitDiffFile], Error>),
        workingTree: inout GitWorkingTreeContent
    ) {
        update(result.staged, values: &workingTree.staged, error: &workingTree.stagedError)
        update(result.unstaged, values: &workingTree.unstaged, error: &workingTree.unstagedError)
    }

    private func handleWorktree(_ action: InspectorGitAction, context: InspectorPaneContext) {
        guard let content = lastPublishedContent[context.tabID], let repository = content.repository,
              content.workingTree.worktreesError == nil else { return }
        let window = TerminalController.all.first { $0.tabSessionID == context.tabID }?.window
        switch action {
        case .openWorktree(let path):
            guard let worktree = content.workingTree.worktrees.first(where: { $0.path == path }) else { return }
            do { try GitWorktreeActions.open(worktree, repository: repository, context: context) } catch { publishOperationError(error.localizedDescription, repository: repository, context: context) }
        case .createWorktree(let start):
            guard mutationTasks[repository.stateKey] == nil,
                  start == nil || (content.workingTree.branchesError == nil && content.workingTree.branches.contains { $0.id == start }) else { return }
            Task {
                if let mutation = await GitWorktreeActions.creation(start: start, repository: repository, window: window) {
                    self.mutate(mutation.mutation, repository: repository, context: context, openCreatedWorktree: mutation.openAfterCreation)
                }
            }
        case .removeWorktree(let path):
            guard mutationTasks[repository.stateKey] == nil,
                  let worktree = content.workingTree.worktrees.first(where: { $0.path == path }), worktree.canRemove else { return }
            Task {
                if await GitWorktreeActions.removal(worktree, window: window) {
                    self.mutate(.removeWorktree(path), repository: repository, context: context)
                }
            }
        default: break
        }
    }

    private func confirmDiscard(_ batch: GitStageBatch, context: InspectorPaneContext) {
        guard let content = lastPublishedContent[context.tabID], let repository = content.repository,
              !batch.isEmpty, mutationTasks[repository.stateKey] == nil,
              batch.entries.allSatisfy({ entry in
                  let staged = entry.section == .staged
                  return entry.file.kind != .unmerged
                      && (staged ? content.workingTree.stagedError : content.workingTree.unstagedError) == nil
                      && (staged ? content.workingTree.staged : content.workingTree.unstaged).contains(entry.file)
              }) else { return }
        let window = NSApp.windows.first { ($0.windowController as? TerminalController)?.tabSessionID == context.tabID }
        let entries = batch.discardEntries
        Task {
            let alert = NSAlert()
            alert.messageText = GitL10n.text("Discard Changes?")
            alert.informativeText = entries.map { entry in
                let file = entry.file
                let staged = entry.section == .staged
                let explanation = file.isUntracked || (staged && file.kind == .added)
                    ? "This deletes the added file. This cannot be undone."
                    : staged ? "This restores the file to HEAD, discarding both staged and unstaged changes. This cannot be undone."
                    : "This restores the file to its staged version. Staged changes are kept. This cannot be undone."
                return file.displayPath + "\n" + GitL10n.text(explanation)
            }.joined(separator: "\n\n")
            if entries.count > 1 {
                let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 420, height: 220))
                scroll.hasVerticalScroller = true
                let details = NSTextView(frame: scroll.bounds)
                details.isEditable = false
                details.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                details.string = alert.informativeText
                details.isVerticallyResizable = true
                details.autoresizingMask = [.width]
                details.textContainer?.widthTracksTextView = true
                scroll.documentView = details
                alert.accessoryView = scroll
                alert.informativeText = GitL10n.format("Discard changes in {0} selected files? Review the files below. This cannot be undone.", String(entries.count))
            }
            alert.addButton(withTitle: GitL10n.text("Discard Changes"))
            alert.addButton(withTitle: GitL10n.text("Cancel"))
            let response: NSApplication.ModalResponse
            if let window { response = await alert.beginSheetModal(for: window) } else { response = alert.runModal() }
            guard response == .alertFirstButtonReturn else { return }
            self.mutate(.discardBatch(.init(entries: entries)), repository: repository, context: context)
        }
    }

    private func mutate(_ mutation: GitMutation, repository: GitRepositoryIdentity, context: InspectorPaneContext, openCreatedWorktree: Bool = false) {
        let key = repository.stateKey
        guard lastPublishedContent[context.tabID]?.repository == repository else { return }
        if mutation.updatesIndexOnly {
            enqueueIndexMutation(mutation, repository: repository, context: context)
            return
        }
        guard mutationTasks[key] == nil else {
            publishOperationError(GitL10n.text("Another Git operation is running in this worktree."), repository: repository, context: context)
            return
        }
        switch mutation {
        case .removeWorktree(let path):
            guard !EditorWorkspaceStore.shared.hasUnsavedDocuments(in: path,
                endpoint: repository.sshConnection.map { .ssh(workspaceID: $0.workspaceID) } ?? .local) else {
                publishOperationError(GitL10n.text("Save or discard unsaved editor changes before removing this worktree."), repository: repository, context: context)
                return
            }
        case .checkout, .create, .applyCommit:
            guard !EditorWorkspaceStore.shared.hasUnsavedDocuments(
                in: repository.worktreePath,
                endpoint: repository.sshConnection.map { .ssh(workspaceID: $0.workspaceID) } ?? .local
            ) else {
                publishOperationError(GitL10n.text("Save or discard unsaved editor changes before switching branches."),
                                      repository: repository, context: context)
                return
            }
        default: break
        }
        operationTitles[key] = mutation.title
        var state = state(for: context.tabID, worktreeKey: key)
        state.operationError = nil
        save(state, tabID: context.tabID, worktreeKey: key)
        for (tabID, content) in lastPublishedContent where content.repository == repository {
            cancelTask(tabID: tabID)
            _ = nextGeneration(for: tabID)
            publish(content, tabID: tabID)
        }
        mutationTasks[key] = Task {
            do {
                if case .discard(let file, _) = mutation {
                    try await EditorWorkspaceStore.shared.withGitFileRestore(file, repository: repository) {
                        try await self.mutationService.perform(mutation, in: repository)
                    }
                } else if case .discardBatch(let batch) = mutation {
                    try await EditorWorkspaceStore.shared.withGitFilesRestore(batch.files, repository: repository) {
                        try await self.mutationService.perform(mutation, in: repository)
                    }
                } else {
                    try await self.mutationService.perform(mutation, in: repository)
                }
                if openCreatedWorktree, case .addWorktree(let path, _, _, _) = mutation {
                    try GitWorktreeActions.open(GitWorktreeInfo(path: path, head: nil, branchRef: nil, isMain: false, isCurrent: false),
                                                repository: repository, context: context)
                }
                if case .commit(let submitted) = mutation {
                    var state = self.state(for: context.tabID, worktreeKey: key)
                    if state.commitDraft == submitted { state.commitDraft = "" }
                    self.save(state, tabID: context.tabID, worktreeKey: key)
                }
            } catch { self.publishOperationError(error.localizedDescription, repository: repository, context: context) }
            self.mutationTasks.removeValue(forKey: key)
            self.operationTitles.removeValue(forKey: key)
            for (tabID, content) in self.lastPublishedContent where content.repository == repository {
                self.publish(content, tabID: tabID)
                if let current = self.presentedContexts[tabID] { self.load(context: current, force: true) }
            }
        }
    }

    private func publishOperationError(_ message: String, repository: GitRepositoryIdentity, context: InspectorPaneContext) {
        var state = state(for: context.tabID, worktreeKey: repository.stateKey)
        state.operationError = message
        save(state, tabID: context.tabID, worktreeKey: repository.stateKey)
        if let content = lastPublishedContent[context.tabID], content.repository == repository {
            publish(content, tabID: context.tabID)
        }
    }

    nonisolated private static func result<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async -> Result<Value, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    private static func update<Value>(_ result: Result<Value, Error>, values: inout Value, error: inout String?) {
        switch result {
        case .success(let value): values = value; error = nil
        case .failure(let failure): error = failure.localizedDescription
        }
    }

    private func cancelTask(tabID: UUID) {
        loadTasks.removeValue(forKey: tabID)?.cancel()
        cancelHistoryTask(tabID: tabID)
    }
    private func cancelHistoryTask(tabID: UUID) {
        historyTasks.removeValue(forKey: tabID)?.cancel()
        historyGenerations[tabID, default: 0] &+= 1
        pendingHistoryRefreshes.removeValue(forKey: tabID)
    }
    private func nextGeneration(for tabID: UUID) -> UInt64 { let next = (generations[tabID] ?? 0) &+ 1; generations[tabID] = next; return next }
    private func currentWorktreeKey(for context: InspectorPaneContext) -> String {
        if let repository = lastPublishedContent[context.tabID]?.repository, repository.matches(context.session) {
            return repository.stateKey
        }
        if case .sshReady(let ssh, _) = context.session.state {
            if let connection = (try? GitExecutionTarget(session: context.session))?.sshConnection {
                return "ssh\0" + connection.identity + "\0" + (context.workingDirectory ?? "")
            }
            return "ssh-pending:" + ssh.connectionID
        }
        return context.workingDirectory ?? ""
    }
}
