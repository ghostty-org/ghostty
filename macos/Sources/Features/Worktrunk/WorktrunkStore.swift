import Foundation

enum SessionSource: String, Codable {
    case claude
    case codex
    case opencode

    var icon: String {
        switch self {
        case .claude: return "terminal"
        case .codex: return "sparkles"
        case .opencode: return "terminal"
        }
    }

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }
}

struct AISession: Identifiable, Hashable {
    var id: String
    var source: SessionSource
    var worktreePath: String
    var cwd: String
    var timestamp: Date  // last activity timestamp from JSONL, NOT file mtime
    var snippet: String?
    var sourcePath: String
    var messageCount: Int = 0  // number of user messages
}

// MARK: - Session Cache

struct SessionCacheEntry: Codable {
    let sessionId: String
    let source: String  // "claude" or "codex"
    let cwd: String
    let timestamp: Date
    let snippet: String?
    let messageCount: Int
    let lastParsedOffset: Int64  // for incremental message counting
    let fileMtime: TimeInterval  // file modification time (epoch)
    let fileSize: Int64          // file size in bytes
}

struct SessionCache: Codable {
    var version: Int = 1
    var entries: [String: SessionCacheEntry] = [:]  // key = file path
}

final class SessionCacheManager {
    private var cache = SessionCache()
    private let cacheURL: URL
    private let queue = DispatchQueue(label: "dev.sidequery.Ghostree.sessioncache")

    init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("dev.sidequery.Ghostree")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cacheURL = cacheDir.appendingPathComponent("sessions.json")
        loadFromDisk()
    }

    func get(_ path: String) -> SessionCacheEntry? {
        queue.sync { cache.entries[path] }
    }

    func set(_ path: String, _ entry: SessionCacheEntry) {
        queue.sync { cache.entries[path] = entry }
    }

    func saveToDisk() {
        queue.async { [self] in
            do {
                let data = try JSONEncoder().encode(cache)
                try data.write(to: cacheURL, options: .atomic)
            } catch {
                // Ignore save failures
            }
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let loaded = try? JSONDecoder().decode(SessionCache.self, from: data) else { return }
        cache = loaded
    }

    func isCacheValid(entry: SessionCacheEntry, mtime: TimeInterval, size: Int64) -> Bool {
        entry.fileMtime == mtime && entry.fileSize == size
    }
}

// MARK: - Session Index

struct SessionIndexEntry: Codable {
    var sessionId: String
    var cwd: String
    var timestamp: Date
    var snippet: String?
    var messageCount: Int
    var worktreePath: String?
    var fileMtime: TimeInterval
    var fileSize: Int64
}

struct OpenCodeIndexEntry: Codable {
    var sessionId: String
    var projectSlug: String
    var infoPath: String
    var infoMtime: TimeInterval
    var infoSize: Int64
    var title: String?
    var updatedAt: Date
    var messageDirMtime: TimeInterval?
    var messageCount: Int
    var worktreePath: String?
}

struct SessionIndex: Codable {
    var version: Int = 1
    var claude: [String: SessionIndexEntry] = [:]
    var codex: [String: SessionIndexEntry] = [:]
    var opencode: [String: OpenCodeIndexEntry] = [:]
}

final class SessionIndexManager {
    private var index = SessionIndex()
    private let indexURL: URL
    private let queue = DispatchQueue(label: "dev.sidequery.Ghostree.sessionindex")

    init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("dev.sidequery.Ghostree")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        indexURL = cacheDir.appendingPathComponent("sessions-index.json")
        loadFromDisk()
    }

    func snapshot() -> SessionIndex {
        queue.sync { index }
    }

    func update(_ newIndex: SessionIndex) {
        queue.sync { index = newIndex }
    }

    func saveToDisk() {
        queue.async { [self] in
            do {
                let data = try JSONEncoder().encode(index)
                try data.write(to: indexURL, options: .atomic)
            } catch {
                // Ignore save failures
            }
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: indexURL),
              let loaded = try? JSONDecoder().decode(SessionIndex.self, from: data),
              loaded.version == 1 else { return }
        index = loaded
    }
}

enum WorktreeSortOrder: String, CaseIterable {
    case alphabetical = "alphabetical"
    case recentActivity = "recentActivity"

    var label: String {
        switch self {
        case .alphabetical: return "Alphabetical"
        case .recentActivity: return "Recent Activity"
        }
    }
}

enum WorktrunkSidebarListMode: String {
    case nestedByRepo = "nestedByRepo"
    case flatWorktrees = "flatWorktrees"
}

final class WorktrunkStore: ObservableObject {
    struct Repository: Identifiable, Codable, Hashable {
        var id: UUID
        var path: String
        var displayName: String?

        init(id: UUID = UUID(), path: String, displayName: String? = nil) {
            self.id = id
            self.path = path
            self.displayName = displayName
        }

        var name: String {
            if let displayName, !displayName.isEmpty { return displayName }
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    struct Worktree: Identifiable, Hashable {
        var repositoryID: UUID
        var branch: String
        var path: String
        var isMain: Bool
        var isCurrent: Bool

        var id: String { "\(repositoryID.uuidString)::\(branch)::\(path)" }
    }

    struct GitTracking: Hashable {
        var hasUpstream: Bool
        var ahead: Int
        var behind: Int
        var stagedCount: Int
        var unstagedCount: Int
        var untrackedCount: Int
        var totalChangesCount: Int
        var lineAdditions: Int
        var lineDeletions: Int
    }

    struct SidebarSnapshot: Equatable {
        var repositories: [Repository]
        var worktreesByRepositoryID: [UUID: [Worktree]]
        var flatWorktrees: [Worktree]
        var repoNameByID: [UUID: String]

        static let empty = SidebarSnapshot(
            repositories: [],
            worktreesByRepositoryID: [:],
            flatWorktrees: [],
            repoNameByID: [:]
        )
    }

    private struct WtListItem: Decodable {
        var branch: String?
        var path: String?
        var kind: String
        var isMain: Bool
        var isCurrent: Bool

        enum CodingKeys: String, CodingKey {
            case branch
            case path
            case kind
            case isMain = "is_main"
            case isCurrent = "is_current"
        }
    }

    @Published private(set) var repositories: [Repository] = []
    @Published private var worktreesByRepositoryID: [UUID: [Worktree]] = [:]
    @Published private var sessionsByWorktreePath: [String: [AISession]] = [:]
    @Published private var gitTrackingByWorktreePath: [String: GitTracking] = [:]
    @Published private(set) var agentStatusByWorktreePath: [String: WorktreeAgentStatusEntry] = [:]
    @Published private(set) var sidebarSnapshot: SidebarSnapshot = .empty
    private(set) var sidebarRepoIDs: Set<UUID> = []
    private(set) var sidebarWorktreePaths: Set<String> = []

    // GitHub PR status
    private(set) var prStatusManager: PRStatusManager?
    @Published var isRefreshing: Bool = false
    @Published var isInstallingWorktrunk: Bool = false
    @Published var needsWorktrunkInstall: Bool = false
    @Published var errorMessage: String? = nil
    @Published private(set) var sidebarModelRevision: Int = 0
    @Published var worktreeSortOrder: WorktreeSortOrder = .recentActivity {
        didSet {
            if oldValue != worktreeSortOrder {
                saveSortOrder()
                resortAllWorktrees()
            }
        }
    }
    @Published var sidebarListMode: WorktrunkSidebarListMode = .flatWorktrees {
        didSet {
            if oldValue != sidebarListMode {
                saveSidebarListMode()
                rebuildSidebarSnapshot()
            }
        }
    }

    private let repositoriesKey = "GhosttyWorktrunkRepositories.v1"
    private let sortOrderKey = "GhostreeWorktreeSortOrder.v1"
    private let sidebarListModeKey = "GhostreeWorktrunkSidebarListMode.v1"
    private let agentStatusAcksKey = "GhostreeWorktrunkAgentStatusAcks.v1"
    private let firstSeenAtKey = "GhostreeWorktrunkWorktreeFirstSeenAtByPath.v1"
    private let sessionCache = SessionCacheManager()
    private let sessionIndex = SessionIndexManager()
    private var agentEventTailer: AgentEventTailer? = nil
    private var pendingAgentEventsByCwd: [String: AgentLifecycleEvent] = [:]
    private var agentStatusAckedAtByWorktreePath: [String: Date] = [:]
    private var firstSeenAtByWorktreePath: [String: Date] = [:]
    private var lastAppQuitTimestamp: Date?
    private var sidebarModelRevisionCounter: Int = 0
    private var refreshAllTask: Task<Void, Never>? = nil
    private var refreshAllNeedsRerun: Bool = false

    init() {
        load()
        loadSortOrder()
        loadSidebarListMode()
        loadFirstSeenAt()
        loadAgentStatusAcks()
        AgentHookInstaller.ensureInstalled()
        pruneAgentEventLogIfNeeded()
        startAgentEventTailer()
        seedAgentStatusesFromLog()
        rebuildSidebarSnapshot()
        setupPRStatusManager()
    }

    private func setupPRStatusManager() {
        guard WorktrunkPreferences.githubIntegrationEnabled else { return }

        let repoPaths = repositories.map { $0.path }

        Task { @MainActor [weak self] in
            let manager = PRStatusManager()

            // Wire up callbacks
            manager.onPushDetected = { [weak self] repoPath in
                await self?.handlePRPushDetected(repoPath: repoPath)
            }

            manager.onAppFocusRefresh = { [weak self] in
                await self?.refreshAllPRStatuses()
            }

            self?.prStatusManager = manager

            // Start monitoring all repos
            for repoPath in repoPaths {
                manager.startMonitoring(repoPath: repoPath)
            }
        }
    }

    private func handlePRPushDetected(repoPath: String) async {
        guard let repo = repositories.first(where: { $0.path == repoPath }) else { return }
        let worktrees = worktreesByRepositoryID[repo.id] ?? []
        let wtData = worktrees.map { (path: $0.path, branch: $0.branch) }
        await prStatusManager?.refreshRepo(repoPath: repoPath, worktrees: wtData)
    }

    private func refreshAllPRStatuses() async {
        for repo in repositories {
            let worktrees = worktreesByRepositoryID[repo.id] ?? []
            for wt in worktrees {
                await prStatusManager?.fetchIfNeeded(
                    worktreePath: wt.path,
                    branch: wt.branch,
                    repoPath: repo.path
                )
            }
        }
    }

    // MARK: - PR Status Access

    @MainActor
    func prStatus(for worktreePath: String) -> PRStatus? {
        prStatusManager?.prStatus(for: worktreePath)
    }

    @MainActor
    func ciState(for worktreePath: String) -> CIState {
        prStatusManager?.ciState(for: worktreePath) ?? .none
    }

    private func bumpSidebarModelRevision() {
        sidebarModelRevisionCounter += 1
        sidebarModelRevision = sidebarModelRevisionCounter
    }

    private func pruneWorktreeScopedState(removedPaths: Set<String>) {
        guard !removedPaths.isEmpty else { return }
        var didChangeFirstSeen = false
        for path in removedPaths {
            sessionsByWorktreePath[path] = nil
            gitTrackingByWorktreePath[path] = nil
            agentStatusByWorktreePath[path] = nil
            agentStatusAckedAtByWorktreePath[path] = nil
            if firstSeenAtByWorktreePath.removeValue(forKey: path) != nil {
                didChangeFirstSeen = true
            }
        }
        if didChangeFirstSeen {
            saveFirstSeenAt()
        }
    }

    func worktrees(for repositoryID: UUID) -> [Worktree] {
        worktreesByRepositoryID[repositoryID] ?? []
    }

    func allWorktreesSorted() -> [Worktree] {
        let all = repositories.flatMap { worktrees(for: $0.id) }
        return sortWorktrees(all, pinMain: sidebarListMode != .flatWorktrees)
    }

    private func rebuildSidebarSnapshot() {
        let repoNameByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0.name) })
        let allWorktrees = repositories.flatMap { worktreesByRepositoryID[$0.id] ?? [] }
        var allWorktreePaths = Set<String>()
        allWorktreePaths.reserveCapacity(allWorktrees.count)
        for wt in allWorktrees {
            allWorktreePaths.insert(wt.path)
        }
        sidebarRepoIDs = Set(repositories.map(\.id))
        sidebarWorktreePaths = allWorktreePaths

        let flatWorktrees: [Worktree]
        if sidebarListMode == .flatWorktrees {
            let sorted = sortWorktrees(allWorktrees, pinMain: false)
            flatWorktrees = sorted.filter { !$0.isMain }
        } else {
            flatWorktrees = []
        }
        let snapshot = SidebarSnapshot(
            repositories: repositories,
            worktreesByRepositoryID: worktreesByRepositoryID,
            flatWorktrees: flatWorktrees,
            repoNameByID: repoNameByID
        )
        if snapshot != sidebarSnapshot {
            sidebarSnapshot = snapshot
        }
    }

    private func rebuildSnapshotIfRecencySensitive() {
        if sidebarListMode == .flatWorktrees, worktreeSortOrder == .recentActivity {
            rebuildSidebarSnapshot()
        }
    }

    func sessions(for worktreePath: String) -> [AISession] {
        sessionsByWorktreePath[worktreePath] ?? []
    }

    func gitTracking(for worktreePath: String) -> GitTracking? {
        gitTrackingByWorktreePath[worktreePath]
    }

    func agentStatus(for worktreePath: String) -> WorktreeAgentStatus? {
        agentStatusByWorktreePath[worktreePath]?.status
    }

    /// Number of worktrees with statuses that need user attention (.permission or .review).
    var attentionCount: Int {
        agentStatusByWorktreePath.values.filter {
            $0.status == .permission || $0.status == .review
        }.count
    }

    func acknowledgeAgentStatus(for worktreePath: String) {
        guard let entry = agentStatusByWorktreePath[worktreePath] else { return }
        var didChange = false

        switch entry.status {
        case .review:
            agentStatusByWorktreePath.removeValue(forKey: worktreePath)
            acknowledgeAgentStatusPersistently(for: worktreePath)
            didChange = true
        case .permission:
            agentStatusByWorktreePath[worktreePath] = .init(status: .working, updatedAt: Date())
            acknowledgeAgentStatusPersistently(for: worktreePath)
            didChange = true
        case .working:
            break
        }
        if didChange {
            rebuildSnapshotIfRecencySensitive()
        }
    }

    func clearAgentReviewIfViewing(cwd: String) {
        guard let worktreePath = findMatchingWorktree(cwd) else { return }
        guard let entry = agentStatusByWorktreePath[worktreePath] else { return }
        guard entry.status == .review else { return }
        agentStatusByWorktreePath.removeValue(forKey: worktreePath)
        acknowledgeAgentStatusPersistently(for: worktreePath)
        rebuildSnapshotIfRecencySensitive()
    }

    func addRepositoryValidated(path: String, displayName: String? = nil) async {
        let normalized = normalizePath(path)

        let alreadyExists = repositories.contains(where: { normalizePath($0.path) == normalized })
        guard !alreadyExists else {
            await MainActor.run { errorMessage = nil }
            return
        }

        do {
            _ = try await WorktrunkClient.run(["-C", normalized, "list", "--format=json"])
            await MainActor.run {
                addRepository(path: normalized, displayName: displayName)
                errorMessage = nil
                needsWorktrunkInstall = false
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            await MainActor.run {
                errorMessage = message
                needsWorktrunkInstall = isWorktrunkMissing(error)
            }
        }
    }

    func addRepository(path: String, displayName: String? = nil) {
        let normalized = normalizePath(path)
        guard !repositories.contains(where: { normalizePath($0.path) == normalized }) else { return }
        repositories.append(.init(path: normalized, displayName: displayName))
        save()
        rebuildSidebarSnapshot()
        bumpSidebarModelRevision()
        Task { await refreshAll() }
    }

    func removeRepository(id: UUID) {
        let removedPaths = Set(worktreesByRepositoryID[id]?.map(\.path) ?? [])
        repositories.removeAll(where: { $0.id == id })
        worktreesByRepositoryID[id] = nil
        pruneWorktreeScopedState(removedPaths: removedPaths)
        save()
        rebuildSidebarSnapshot()
        bumpSidebarModelRevision()
    }

    func refreshAll() async {
        if let existing = refreshAllTask {
            refreshAllNeedsRerun = true
            await existing.value
            if refreshAllNeedsRerun {
                refreshAllNeedsRerun = false
                await refreshAll()
            }
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.refreshAllBatchedLoop()
        }
        refreshAllTask = task
        await task.value
        refreshAllTask = nil
    }

    private struct RefreshListResult {
        var repoID: UUID
        var worktrees: [Worktree]?
        var error: String?
        var previousPaths: Set<String>
        var hadExistingList: Bool
    }

    private func refreshAllBatchedLoop() async {
        await MainActor.run {
            isRefreshing = true
        }
        repeat {
            refreshAllNeedsRerun = false
            await refreshAllBatchedOnce()
        } while refreshAllNeedsRerun
        await MainActor.run {
            isRefreshing = false
        }
    }

    private func refreshAllBatchedOnce() async {
        let repoSnapshot = await MainActor.run { repositories }
        let previousByRepoID = await MainActor.run {
            var snapshot: [UUID: (hadExisting: Bool, paths: Set<String>)] = [:]
            snapshot.reserveCapacity(repositories.count)
            for repo in repositories {
                let existing = worktreesByRepositoryID[repo.id]
                snapshot[repo.id] = (existing != nil, Set(existing?.map(\.path) ?? []))
            }
            return snapshot
        }

        var results: [RefreshListResult] = []
        results.reserveCapacity(repoSnapshot.count)

        await withTaskGroup(of: RefreshListResult.self) { group in
            for repo in repoSnapshot {
                let previous = previousByRepoID[repo.id] ?? (hadExisting: false, paths: Set<String>())
                group.addTask { [self] in
                    do {
                        let result = try await WorktrunkClient.run(["-C", repo.path, "list", "--format=json"])
                        let data = Data(result.stdout.utf8)
                        let worktrees = try decodeWorktrees(repoID: repo.id, data: data)
                        return RefreshListResult(
                            repoID: repo.id,
                            worktrees: worktrees,
                            error: nil,
                            previousPaths: previous.paths,
                            hadExistingList: previous.hadExisting
                        )
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                        return RefreshListResult(
                            repoID: repo.id,
                            worktrees: nil,
                            error: message,
                            previousPaths: previous.paths,
                            hadExistingList: previous.hadExisting
                        )
                    }
                }
            }

            for await result in group {
                results.append(result)
            }
        }

        let resultsByRepoID = Dictionary(uniqueKeysWithValues: results.map { ($0.repoID, $0) })
        let allPreviousPaths = results.reduce(into: Set<String>()) { $0.formUnion($1.previousPaths) }

        await MainActor.run {
            var removedPaths = Set<String>()
            var didChangeFirstSeen = false
            var lastError: String? = nil

            for repo in repoSnapshot {
                guard let result = resultsByRepoID[repo.id] else { continue }
                if let error = result.error {
                    lastError = error
                    continue
                }

                lastError = nil

                guard let worktrees = result.worktrees else { continue }
                let newPaths = Set(worktrees.map(\.path))
                let removed = result.previousPaths.subtracting(newPaths)
                let added = newPaths.subtracting(result.previousPaths)
                removedPaths.formUnion(removed)

                if result.hadExistingList, !added.isEmpty {
                    let now = Date()
                    for path in added {
                        if firstSeenAtByWorktreePath[path] == nil {
                            firstSeenAtByWorktreePath[path] = now
                            didChangeFirstSeen = true
                        }
                    }
                }

                worktreesByRepositoryID[repo.id] = sortWorktrees(worktrees)
            }

            if didChangeFirstSeen {
                saveFirstSeenAt()
            }

            reconcilePendingAgentEvents()
            pruneWorktreeScopedState(removedPaths: removedPaths)
            errorMessage = lastError
            rebuildSidebarSnapshot()
            bumpSidebarModelRevision()
        }

        let allWorktrees = await MainActor.run {
            repositories.flatMap { worktreesByRepositoryID[$0.id] ?? [] }
        }

        await refreshGitTracking(for: allWorktrees, removing: allPreviousPaths)
        await refreshSessions()
    }

    private func decodeWorktrees(repoID: UUID, data: Data) throws -> [Worktree] {
        let items = try JSONDecoder().decode([WtListItem].self, from: data)
        return items.compactMap { item in
            guard item.kind == "worktree" else { return nil }
            guard let branch = item.branch, !branch.isEmpty else { return nil }
            guard let path = item.path, !path.isEmpty else { return nil }
            return Worktree(
                repositoryID: repoID,
                branch: branch,
                path: path,
                isMain: item.isMain,
                isCurrent: item.isCurrent
            )
        }
    }

    func refresh(repoID: UUID) async {
        guard let repo = repositories.first(where: { $0.id == repoID }) else { return }
        let (hadExistingList, previousPaths) = await MainActor.run {
            let existing = worktreesByRepositoryID[repoID]
            return (existing != nil, Set(existing?.map(\.path) ?? []))
        }
        do {
            let result = try await WorktrunkClient.run(["-C", repo.path, "list", "--format=json"])
            let data = Data(result.stdout.utf8)
            let worktrees = try decodeWorktrees(repoID: repoID, data: data)
            let newPaths = Set(worktrees.map(\.path))
            let removedPaths = previousPaths.subtracting(newPaths)
            let addedPaths = newPaths.subtracting(previousPaths)
            await MainActor.run {
                if hadExistingList, !addedPaths.isEmpty {
                    let now = Date()
                    var didChange = false
                    for path in addedPaths {
                        if firstSeenAtByWorktreePath[path] == nil {
                            firstSeenAtByWorktreePath[path] = now
                            didChange = true
                        }
                    }
                    if didChange {
                        saveFirstSeenAt()
                    }
                }
                worktreesByRepositoryID[repoID] = sortWorktrees(worktrees)
                errorMessage = nil
                needsWorktrunkInstall = false
                reconcilePendingAgentEvents()
                pruneWorktreeScopedState(removedPaths: removedPaths)
                rebuildSidebarSnapshot()
                bumpSidebarModelRevision()
            }
            await refreshGitTracking(for: worktrees, removing: previousPaths)
        } catch {
            await MainActor.run {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                needsWorktrunkInstall = isWorktrunkMissing(error)
            }
        }
    }

    func createWorktree(
        repoID: UUID,
        branch: String,
        base: String?,
        createBranch: Bool
    ) async -> Worktree? {
        guard let repo = repositories.first(where: { $0.id == repoID }) else { return nil }

        do {
            var args = ["-C", repo.path, "switch", "--yes"]
            if createBranch {
                args.append("--create")
            }
            if let base, !base.isEmpty {
                args.append(contentsOf: ["--base", base])
            }
            args.append(branch)

            _ = try await WorktrunkClient.run(args)

            await refresh(repoID: repoID)
            await MainActor.run { needsWorktrunkInstall = false }
            return worktrees(for: repoID).first(where: { $0.branch == branch })
        } catch {
            await MainActor.run {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                needsWorktrunkInstall = isWorktrunkMissing(error)
            }
            return nil
        }
    }

    func removeWorktree(repoID: UUID, branch: String, force: Bool = false) async -> Bool {
        guard let repo = repositories.first(where: { $0.id == repoID }) else { return false }
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else { return false }

        do {
            var args = [
                "-C",
                repo.path,
                "remove",
                "--yes",
                "--foreground",
            ]
            if force {
                args.append("--force")
            }
            args.append(trimmedBranch)
            _ = try await WorktrunkClient.run(args)
            await refresh(repoID: repoID)
            await MainActor.run {
                errorMessage = nil
                needsWorktrunkInstall = false
            }
            return true
        } catch {
            await MainActor.run {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                needsWorktrunkInstall = isWorktrunkMissing(error)
            }
            return false
        }
    }

    func installWorktrunk() async -> Bool {
        await MainActor.run {
            isInstallingWorktrunk = true
            errorMessage = nil
        }

        do {
            try await WorktrunkInstaller.installPinnedWorktrunkIfNeeded()
            await MainActor.run {
                isInstallingWorktrunk = false
                errorMessage = nil
                needsWorktrunkInstall = false
            }
            await refreshAll()
            return true
        } catch {
            await MainActor.run {
                isInstallingWorktrunk = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                needsWorktrunkInstall = true
            }
            return false
        }
    }

    private func isWorktrunkMissing(_ error: Error) -> Bool {
        guard let wt = error as? WorktrunkClientError else { return false }
        switch wt {
        case .executableNotFound:
            return true
        case .nonZeroExit(let code, let stderr):
            // When we fall back to `/usr/bin/env wt ...` and `wt` isn't on PATH, env exits 127.
            if code == 127 {
                let s = stderr.lowercased()
                if s.contains("wt") && (s.contains("not found") || s.contains("no such file")) {
                    return true
                }
            }
            return false
        case .invalidUTF8:
            return false
        }
    }

    private func load() {
        let ud = UserDefaults.standard
        guard let data = ud.data(forKey: repositoriesKey) else { return }
        do {
            repositories = try JSONDecoder().decode([Repository].self, from: data)
        } catch {
            repositories = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(repositories)
            UserDefaults.standard.set(data, forKey: repositoriesKey)
        } catch {
            // Ignore persistence failure.
        }
    }

    private func loadSortOrder() {
        if let raw = UserDefaults.standard.string(forKey: sortOrderKey),
           let order = WorktreeSortOrder(rawValue: raw) {
            worktreeSortOrder = order
        }
    }

    private func saveSortOrder() {
        UserDefaults.standard.set(worktreeSortOrder.rawValue, forKey: sortOrderKey)
    }

    private func loadSidebarListMode() {
        if let raw = UserDefaults.standard.string(forKey: sidebarListModeKey),
           let mode = WorktrunkSidebarListMode(rawValue: raw) {
            sidebarListMode = mode
            if mode == .flatWorktrees {
                worktreeSortOrder = .recentActivity
            }
        }
    }

    private func saveSidebarListMode() {
        UserDefaults.standard.set(sidebarListMode.rawValue, forKey: sidebarListModeKey)
    }

    private func loadFirstSeenAt() {
        let ud = UserDefaults.standard
        guard let raw = ud.dictionary(forKey: firstSeenAtKey) else { return }
        var loaded: [String: Date] = [:]
        loaded.reserveCapacity(raw.count)
        for (path, value) in raw {
            if let epoch = value as? TimeInterval {
                loaded[path] = Date(timeIntervalSince1970: epoch)
            } else if let number = value as? NSNumber {
                loaded[path] = Date(timeIntervalSince1970: number.doubleValue)
            }
        }
        firstSeenAtByWorktreePath = loaded
    }

    private func saveFirstSeenAt() {
        let ud = UserDefaults.standard
        let payload = firstSeenAtByWorktreePath.mapValues { $0.timeIntervalSince1970 }
        ud.set(payload, forKey: firstSeenAtKey)
    }

    func latestActivityDate(for worktreePath: String) -> Date? {
        let sessionDate = sessionsByWorktreePath[worktreePath]?.first?.timestamp
        let agentDate = agentStatusByWorktreePath[worktreePath]?.updatedAt

        switch (sessionDate, agentDate) {
        case (.some(let s), .some(let a)): return max(s, a)
        case (.some(let s), .none): return s
        case (.none, .some(let a)): return a
        case (.none, .none): return nil
        }
    }

    func recencyDate(for worktreePath: String) -> Date? {
        latestActivityDate(for: worktreePath) ?? firstSeenAtByWorktreePath[worktreePath]
    }

    @discardableResult
    private func resortAllWorktrees() -> Bool {
        var didChange = false
        for repoID in worktreesByRepositoryID.keys {
            if let existing = worktreesByRepositoryID[repoID] {
                let sorted = sortWorktrees(existing)
                if sorted != existing {
                    worktreesByRepositoryID[repoID] = sorted
                    didChange = true
                }
            }
        }
        if didChange {
            rebuildSidebarSnapshot()
            bumpSidebarModelRevision()
        }
        return didChange
    }

    private func sortWorktrees(_ worktrees: [Worktree], pinMain: Bool = true) -> [Worktree] {
        Self.sortedWorktrees(
            worktrees,
            sortOrder: worktreeSortOrder,
            pinMain: pinMain,
            recencyDate: { [self] path in recencyDate(for: path) }
        )
    }

    static func sortedWorktrees(
        _ worktrees: [Worktree],
        sortOrder: WorktreeSortOrder,
        pinMain: Bool,
        recencyDate: (String) -> Date?
    ) -> [Worktree] {
        worktrees.sorted { a, b in
            // Current always pinned to top.
            if a.isCurrent != b.isCurrent { return a.isCurrent }
            if pinMain, a.isMain != b.isMain { return a.isMain }

            switch sortOrder {
            case .alphabetical:
                return a.branch.localizedStandardCompare(b.branch) == .orderedAscending
            case .recentActivity:
                let dateA = recencyDate(a.path)
                let dateB = recencyDate(b.path)
                switch (dateA, dateB) {
                case (.some(let da), .some(let db)):
                    if da != db { return da > db }
                    return a.branch.localizedStandardCompare(b.branch) == .orderedAscending
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none):
                    return a.branch.localizedStandardCompare(b.branch) == .orderedAscending
                }
            }
        }
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func normalizePathForMatch(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func refreshGitTracking(for worktrees: [Worktree], removing previousPaths: Set<String>) async {
        let newPaths = Set(worktrees.map(\.path))
        var results: [String: GitTracking] = [:]

        await withTaskGroup(of: (String, GitTracking?).self) { group in
            for worktree in worktrees {
                group.addTask { [self] in
                    let tracking = try? await getGitTracking(worktreePath: worktree.path)
                    return (worktree.path, tracking)
                }
            }

            for await (path, tracking) in group {
                if let tracking {
                    results[path] = tracking
                }
            }
        }

        await MainActor.run {
            var next = gitTrackingByWorktreePath
            for path in previousPaths where !newPaths.contains(path) {
                next[path] = nil
            }
            for path in newPaths {
                if let tracking = results[path] {
                    next[path] = tracking
                } else {
                    next[path] = nil
                }
            }
            if next != gitTrackingByWorktreePath {
                gitTrackingByWorktreePath = next
            }
        }
    }

    private func getGitTracking(worktreePath: String) async throws -> GitTracking? {
        let output = try await runGitStatus(worktreePath: worktreePath)
        if output.isEmpty { return nil }
        var parsed = parseGitStatusOutput(output)

        let (unstagedAdds, unstagedDeletes) = (try? await runGitNumstat(
            worktreePath: worktreePath,
            args: ["diff", "--numstat"]
        )) ?? (0, 0)

        let (stagedAdds, stagedDeletes) = (try? await runGitNumstat(
            worktreePath: worktreePath,
            args: ["diff", "--cached", "--numstat"]
        )) ?? (0, 0)

        let untrackedAdds = countUntrackedAdditions(
            worktreePath: worktreePath,
            paths: parsed.untrackedFiles
        )

        parsed.tracking.lineAdditions = unstagedAdds + stagedAdds + untrackedAdds
        parsed.tracking.lineDeletions = unstagedDeletes + stagedDeletes

        return parsed.tracking
    }

    private struct GitInvocation {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
    }

    private func makeGitInvocation(args: [String]) throws -> GitInvocation {
        var env = ProcessInfo.processInfo.environment
        let prefix = ["/opt/homebrew/bin", "/usr/local/bin"]
        let existingPath = env["PATH"] ?? ""
        if existingPath.isEmpty {
            env["PATH"] = prefix.joined(separator: ":")
        } else {
            let existingComponents = Set(existingPath.split(separator: ":").map(String.init))
            let missingPaths = prefix.filter { !existingComponents.contains($0) }
            if !missingPaths.isEmpty {
                env["PATH"] = (missingPaths + [existingPath]).joined(separator: ":")
            }
        }

        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return GitInvocation(
                    executableURL: URL(fileURLWithPath: path),
                    arguments: args,
                    environment: env
                )
            }
        }

        let envURL = URL(fileURLWithPath: "/usr/bin/env")
        guard FileManager.default.isExecutableFile(atPath: envURL.path) else {
            throw WorktrunkClientError.executableNotFound
        }

        return GitInvocation(
            executableURL: envURL,
            arguments: ["git"] + args,
            environment: env
        )
    }

    private func runGitStatus(worktreePath: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) { [self] in
            try runGitStatusSync(worktreePath: worktreePath)
        }.value
    }

    private func runGitStatusSync(worktreePath: String) throws -> String {
        let args = [
            "--no-optional-locks",
            "-C",
            worktreePath,
            "status",
            "--porcelain=v1",
            "-b",
            "-z",
            "-M",
            "-uall",
        ]

        let invocation = try makeGitInvocation(args: args)
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment

        let stdinPipe = Pipe()
        stdinPipe.fileHandleForWriting.closeFile()
        process.standardInput = stdinPipe

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let stdout = String(data: stdoutData, encoding: .utf8),
              let stderr = String(data: stderrData, encoding: .utf8) else {
            throw WorktrunkClientError.invalidUTF8
        }

        if process.terminationStatus != 0 {
            throw WorktrunkClientError.nonZeroExit(
                code: process.terminationStatus,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return stdout
    }

    private struct ParsedGitStatus {
        var tracking: GitTracking
        var untrackedFiles: [String]
    }

    private func parseGitStatusOutput(_ output: String) -> ParsedGitStatus {
        let entries = output.split(separator: "\0").map(String.init)
        var hasUpstream = false
        var ahead = 0
        var behind = 0

        var stagedFiles = Set<String>()
        var unstagedFiles = Set<String>()
        var untrackedFiles = Set<String>()
        var anyFiles = Set<String>()

        var i = 0
        while i < entries.count {
            let entry = entries[i]
            if entry.hasPrefix("## ") {
                let branchInfo = String(entry.dropFirst(3))
                if let range = branchInfo.range(of: "...") {
                    let after = branchInfo[range.upperBound...]
                    let upstream = after.split(whereSeparator: { $0 == " " || $0 == "[" }).first
                    hasUpstream = (upstream?.isEmpty == false)
                }

                if let start = branchInfo.firstIndex(of: "["),
                   let end = branchInfo.firstIndex(of: "]"),
                   start < end {
                    let inside = branchInfo[branchInfo.index(after: start)..<end]
                    let parts = inside.split(separator: ",")
                    for part in parts {
                        let trimmed = part.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("ahead ") {
                            let value = trimmed.replacingOccurrences(of: "ahead ", with: "")
                            ahead = Int(value) ?? 0
                        } else if trimmed.hasPrefix("behind ") {
                            let value = trimmed.replacingOccurrences(of: "behind ", with: "")
                            behind = Int(value) ?? 0
                        }
                    }
                }

                i += 1
                continue
            }

            if entry.count < 3 {
                i += 1
                continue
            }

            let indexStatus = entry[entry.startIndex]
            let workingStatus = entry[entry.index(after: entry.startIndex)]
            let pathStart = entry.index(entry.startIndex, offsetBy: 3)
            let path = String(entry[pathStart...])

            if indexStatus == "?" && workingStatus == "?" {
                untrackedFiles.insert(path)
                anyFiles.insert(path)
                i += 1
                continue
            }

            if indexStatus != " " {
                stagedFiles.insert(path)
                anyFiles.insert(path)
            }

            if workingStatus != " " {
                unstagedFiles.insert(path)
                anyFiles.insert(path)
            }

            if indexStatus == "R" || indexStatus == "C" {
                i += 1
            }

            i += 1
        }

        return ParsedGitStatus(
            tracking: GitTracking(
            hasUpstream: hasUpstream,
            ahead: ahead,
            behind: behind,
            stagedCount: stagedFiles.count,
            unstagedCount: unstagedFiles.count,
            untrackedCount: untrackedFiles.count,
            totalChangesCount: anyFiles.count,
            lineAdditions: 0,
            lineDeletions: 0
        ),
            untrackedFiles: Array(untrackedFiles)
        )
    }

    private func runGitNumstat(worktreePath: String, args: [String]) async throws -> (Int, Int) {
        try await Task.detached(priority: .userInitiated) { [self] in
            try runGitNumstatSync(worktreePath: worktreePath, args: args)
        }.value
    }

    private func runGitNumstatSync(worktreePath: String, args: [String]) throws -> (Int, Int) {
        let fullArgs = ["-C", worktreePath] + args
        let invocation = try makeGitInvocation(args: fullArgs)

        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment

        let stdinPipe = Pipe()
        stdinPipe.fileHandleForWriting.closeFile()
        process.standardInput = stdinPipe

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let stdout = String(data: stdoutData, encoding: .utf8),
              let stderr = String(data: stderrData, encoding: .utf8) else {
            throw WorktrunkClientError.invalidUTF8
        }

        if process.terminationStatus != 0 {
            throw WorktrunkClientError.nonZeroExit(
                code: process.terminationStatus,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return parseNumstat(stdout)
    }

    private func parseNumstat(_ output: String) -> (Int, Int) {
        var additions = 0
        var deletions = 0

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count < 2 { continue }
            let addStr = String(parts[0])
            let delStr = String(parts[1])

            if addStr != "-", let add = Int(addStr) {
                additions += add
            }
            if delStr != "-", let del = Int(delStr) {
                deletions += del
            }
        }

        return (additions, deletions)
    }

    private func countUntrackedAdditions(worktreePath: String, paths: [String]) -> Int {
        var total = 0
        for path in paths {
            let url = URL(fileURLWithPath: worktreePath).appendingPathComponent(path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else { continue }
            if size.int64Value > 1_000_000 { continue }
            if let data = try? Data(contentsOf: url),
               let content = String(data: data, encoding: .utf8) {
                total += content.split(separator: "\n", omittingEmptySubsequences: false).count
            }
        }
        return total
    }

    // MARK: - Session Discovery

    private struct OpenCodeSessionInfo: Decodable {
        struct TimeInfo: Decodable {
            var created: Double?
            var updated: Double?
        }

        var id: String
        var title: String?
        var time: TimeInfo
    }

    private func openCodeSlugVariants(for path: String) -> [String] {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let slug = trimmed.replacingOccurrences(of: "/", with: "-")
        return ["\(slug)", "-\(slug)"]
    }

    private func resolveWorktreePath(
        cachedPath: String?,
        cwd: String,
        validWorktreePaths: Set<String>
    ) -> String? {
        if let cachedPath, validWorktreePaths.contains(cachedPath) {
            return cachedPath
        }
        return findMatchingWorktree(cwd)
    }

    private func parseOpenCodeSessionInfo(_ url: URL) -> OpenCodeSessionInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OpenCodeSessionInfo.self, from: data)
    }

    private func fileAttributes(for url: URL) -> (mtime: TimeInterval, size: Int64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        let size = Int64((attrs[.size] as? UInt64) ?? (attrs[.size] as? Int).map { UInt64($0) } ?? 0)
        return (mtime, size)
    }

    func refreshSessions() async {
        var allSessions: [String: [AISession]] = [:]
        var updateCount = 0
        var dirtyWorktreePaths = Set<String>()
        let publishCheckBatch = 25
        let publishIntervalSeconds: TimeInterval = 0.2
        var lastPublish = Date.distantPast
        let validWorktreePaths = sidebarWorktreePaths
        var index = sessionIndex.snapshot()
        var seenClaudePaths = Set<String>()
        var seenCodexPaths = Set<String>()
        var seenOpenCodePaths = Set<String>()
        var openCodeSlugToWorktreePath: [String: String] = [:]

        for path in validWorktreePaths {
            for slug in openCodeSlugVariants(for: path) {
                if let existing = openCodeSlugToWorktreePath[slug] {
                    if path.count > existing.count {
                        openCodeSlugToWorktreePath[slug] = path
                    }
                } else {
                    openCodeSlugToWorktreePath[slug] = path
                }
            }
        }

        func prepareForPublish() {
            guard !dirtyWorktreePaths.isEmpty else { return }
            for path in dirtyWorktreePaths {
                allSessions[path]?.sort { $0.timestamp > $1.timestamp }
            }
            dirtyWorktreePaths.removeAll(keepingCapacity: true)
        }

        func publishSnapshotIfNeeded(force: Bool = false) async {
            let now = Date()
            if !force, now.timeIntervalSince(lastPublish) < publishIntervalSeconds {
                return
            }
            lastPublish = now
            prepareForPublish()
            let snapshot = allSessions
            await MainActor.run {
                if sessionsByWorktreePath != snapshot {
                    sessionsByWorktreePath = snapshot
                }
            }
        }

        func noteSession(_ session: AISession, worktreePath: String) async {
            allSessions[worktreePath, default: []].append(session)
            dirtyWorktreePaths.insert(worktreePath)
            updateCount += 1
            if updateCount % publishCheckBatch == 0 {
                await publishSnapshotIfNeeded()
            }
        }

        // Scan Claude sessions with periodic UI updates
        let claudeProjectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        if FileManager.default.fileExists(atPath: claudeProjectsDir.path),
           let projectDirs = try? FileManager.default.contentsOfDirectory(
               at: claudeProjectsDir,
               includingPropertiesForKeys: [.isDirectoryKey]
           ) {
            for projectDir in projectDirs {
                let isDirectory = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDirectory else { continue }

                let sessionFiles = (try? FileManager.default.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
                ))?.filter { $0.pathExtension == "jsonl" } ?? []

                for sessionFile in sessionFiles {
                    seenClaudePaths.insert(sessionFile.path)
                    guard let attrs = fileAttributes(for: sessionFile) else { continue }
                    let cached = index.claude[sessionFile.path]

                    if let cached,
                       cached.fileMtime == attrs.mtime,
                       cached.fileSize == attrs.size {
                        if cached.snippet == "Warmup" { continue }
                        if let worktreePath = resolveWorktreePath(
                            cachedPath: cached.worktreePath,
                            cwd: cached.cwd,
                            validWorktreePaths: validWorktreePaths
                        ) {
                            let session = AISession(
                                id: cached.sessionId,
                                source: .claude,
                                worktreePath: worktreePath,
                                cwd: cached.cwd,
                                timestamp: cached.timestamp,
                                snippet: cached.snippet,
                                sourcePath: sessionFile.path,
                                messageCount: cached.messageCount
                            )
                            await noteSession(session, worktreePath: worktreePath)
                            if cached.worktreePath != worktreePath {
                                var updated = cached
                                updated.worktreePath = worktreePath
                                index.claude[sessionFile.path] = updated
                            }
                        }
                        continue
                    }

                    if var session = parseClaudeSession(sessionFile) {
                        if session.snippet == "Warmup" {
                            index.claude[sessionFile.path] = nil
                            continue
                        }
                        if let worktreePath = resolveWorktreePath(
                            cachedPath: nil,
                            cwd: session.cwd,
                            validWorktreePaths: validWorktreePaths
                        ) {
                            session.worktreePath = worktreePath
                            await noteSession(session, worktreePath: worktreePath)
                            index.claude[sessionFile.path] = SessionIndexEntry(
                                sessionId: session.id,
                                cwd: session.cwd,
                                timestamp: session.timestamp,
                                snippet: session.snippet,
                                messageCount: session.messageCount,
                                worktreePath: worktreePath,
                                fileMtime: attrs.mtime,
                                fileSize: attrs.size
                            )
                        } else {
                            index.claude[sessionFile.path] = nil
                        }
                    } else {
                        index.claude[sessionFile.path] = nil
                    }
                }
            }
        } else {
            index.claude = [:]
        }

        index.claude = index.claude.filter { seenClaudePaths.contains($0.key) }

        // Scan Codex sessions
        let codexSessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")

        if FileManager.default.fileExists(atPath: codexSessionsDir.path),
           let enumerator = FileManager.default.enumerator(
               at: codexSessionsDir,
               includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
           ) {
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }
                let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isRegular else { continue }

                seenCodexPaths.insert(fileURL.path)
                guard let attrs = fileAttributes(for: fileURL) else { continue }
                let cached = index.codex[fileURL.path]

                if let cached,
                   cached.fileMtime == attrs.mtime,
                   cached.fileSize == attrs.size {
                    if let worktreePath = resolveWorktreePath(
                        cachedPath: cached.worktreePath,
                        cwd: cached.cwd,
                        validWorktreePaths: validWorktreePaths
                    ) {
                        let session = AISession(
                            id: cached.sessionId,
                            source: .codex,
                            worktreePath: worktreePath,
                            cwd: cached.cwd,
                            timestamp: cached.timestamp,
                            snippet: cached.snippet,
                            sourcePath: fileURL.path,
                            messageCount: cached.messageCount
                        )
                        await noteSession(session, worktreePath: worktreePath)
                        if cached.worktreePath != worktreePath {
                            var updated = cached
                            updated.worktreePath = worktreePath
                            index.codex[fileURL.path] = updated
                        }
                    }
                    continue
                }

                if var session = parseCodexSession(fileURL) {
                    if let worktreePath = resolveWorktreePath(
                        cachedPath: nil,
                        cwd: session.cwd,
                        validWorktreePaths: validWorktreePaths
                    ) {
                        session.worktreePath = worktreePath
                        await noteSession(session, worktreePath: worktreePath)
                        index.codex[fileURL.path] = SessionIndexEntry(
                            sessionId: session.id,
                            cwd: session.cwd,
                            timestamp: session.timestamp,
                            snippet: session.snippet,
                            messageCount: session.messageCount,
                            worktreePath: worktreePath,
                            fileMtime: attrs.mtime,
                            fileSize: attrs.size
                        )
                    } else {
                        index.codex[fileURL.path] = nil
                    }
                } else {
                    index.codex[fileURL.path] = nil
                }
            }
        } else {
            index.codex = [:]
        }

        index.codex = index.codex.filter { seenCodexPaths.contains($0.key) }

        // Scan OpenCode sessions
        let openCodeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/project")

        if FileManager.default.fileExists(atPath: openCodeRoot.path),
           let projectDirs = try? FileManager.default.contentsOfDirectory(
               at: openCodeRoot,
               includingPropertiesForKeys: [.isDirectoryKey]
           ) {
            for projectDir in projectDirs {
                let isDirectory = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDirectory else { continue }

                let projectSlug = projectDir.lastPathComponent
                let infoDir = projectDir
                    .appendingPathComponent("storage")
                    .appendingPathComponent("session")
                    .appendingPathComponent("info")
                guard FileManager.default.fileExists(atPath: infoDir.path) else { continue }

                let infoFiles = (try? FileManager.default.contentsOfDirectory(
                    at: infoDir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
                ))?.filter { $0.pathExtension == "json" } ?? []

                for infoFile in infoFiles {
                    seenOpenCodePaths.insert(infoFile.path)
                    guard let attrs = fileAttributes(for: infoFile) else { continue }
                    let cached = index.opencode[infoFile.path]

                    if var cached,
                       cached.infoMtime == attrs.mtime,
                       cached.infoSize == attrs.size {
                        let messageDir = projectDir
                            .appendingPathComponent("storage")
                            .appendingPathComponent("session")
                            .appendingPathComponent("message")
                            .appendingPathComponent(cached.sessionId)
                        var didUpdate = false
                        if let dirAttrs = try? FileManager.default.attributesOfItem(atPath: messageDir.path),
                           let dirMtime = (dirAttrs[.modificationDate] as? Date)?.timeIntervalSince1970 {
                            if cached.messageDirMtime != dirMtime {
                                cached.messageDirMtime = dirMtime
                                cached.messageCount = (try? FileManager.default.contentsOfDirectory(
                                    at: messageDir,
                                    includingPropertiesForKeys: nil
                                ))?.count ?? 0
                                didUpdate = true
                            }
                        } else if cached.messageCount != 0 || cached.messageDirMtime != nil {
                            cached.messageCount = 0
                            cached.messageDirMtime = nil
                            didUpdate = true
                        }

                        if let mapped = openCodeSlugToWorktreePath[projectSlug] {
                            if cached.worktreePath != mapped {
                                cached.worktreePath = mapped
                                didUpdate = true
                            }
                        } else if cached.worktreePath != nil {
                            cached.worktreePath = nil
                            didUpdate = true
                        }

                        if didUpdate {
                            index.opencode[infoFile.path] = cached
                        }

                        if let worktreePath = cached.worktreePath {
                            let session = AISession(
                                id: cached.sessionId,
                                source: .opencode,
                                worktreePath: worktreePath,
                                cwd: worktreePath,
                                timestamp: cached.updatedAt,
                                snippet: cached.title,
                                sourcePath: infoFile.path,
                                messageCount: cached.messageCount
                            )
                            await noteSession(session, worktreePath: worktreePath)
                        }
                        continue
                    }

                    guard let info = parseOpenCodeSessionInfo(infoFile) else {
                        index.opencode[infoFile.path] = nil
                        continue
                    }

                    let updatedMs = info.time.updated ?? info.time.created ?? 0
                    let updatedAt = Date(timeIntervalSince1970: updatedMs / 1000.0)
                    let messageDir = projectDir
                        .appendingPathComponent("storage")
                        .appendingPathComponent("session")
                        .appendingPathComponent("message")
                        .appendingPathComponent(info.id)
                    var messageDirMtime: TimeInterval? = nil
                    var messageCount = 0
                    if let dirAttrs = try? FileManager.default.attributesOfItem(atPath: messageDir.path),
                       let dirMtime = (dirAttrs[.modificationDate] as? Date)?.timeIntervalSince1970 {
                        messageDirMtime = dirMtime
                        messageCount = (try? FileManager.default.contentsOfDirectory(
                            at: messageDir,
                            includingPropertiesForKeys: nil
                        ))?.count ?? 0
                    }

                    let worktreePath = openCodeSlugToWorktreePath[projectSlug]

                    let entry = OpenCodeIndexEntry(
                        sessionId: info.id,
                        projectSlug: projectSlug,
                        infoPath: infoFile.path,
                        infoMtime: attrs.mtime,
                        infoSize: attrs.size,
                        title: info.title,
                        updatedAt: updatedAt,
                        messageDirMtime: messageDirMtime,
                        messageCount: messageCount,
                        worktreePath: worktreePath
                    )
                    index.opencode[infoFile.path] = entry

                    if let worktreePath {
                        let session = AISession(
                            id: info.id,
                            source: .opencode,
                            worktreePath: worktreePath,
                            cwd: worktreePath,
                            timestamp: updatedAt,
                            snippet: info.title,
                            sourcePath: infoFile.path,
                            messageCount: messageCount
                        )
                        await noteSession(session, worktreePath: worktreePath)
                    }
                }
            }
        } else {
            index.opencode = [:]
        }

        index.opencode = index.opencode.filter { seenOpenCodePaths.contains($0.key) }

        // Final sort and update
        prepareForPublish()

        sessionCache.saveToDisk()
        sessionIndex.update(index)
        sessionIndex.saveToDisk()

        await MainActor.run {
            sessionsByWorktreePath = allSessions
            let didResort = worktreeSortOrder == .recentActivity ? resortAllWorktrees() : false
            if !didResort {
                bumpSidebarModelRevision()
            }
        }
    }

    private func parseClaudeSession(_ url: URL) -> AISession? {
        // Check file attributes for cache validation
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        let size = Int64((attrs[.size] as? UInt64) ?? (attrs[.size] as? Int).map { UInt64($0) } ?? 0)

        let sessionId = url.deletingPathExtension().lastPathComponent

        // Check cache
        if let cached = sessionCache.get(url.path),
           sessionCache.isCacheValid(entry: cached, mtime: mtime, size: size) {
            return AISession(
                id: cached.sessionId,
                source: .claude,
                worktreePath: "",
                cwd: cached.cwd,
                timestamp: cached.timestamp,
                snippet: cached.snippet,
                sourcePath: url.path,
                messageCount: cached.messageCount
            )
        }

        // Parse fresh
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var cwd: String?
        var timestamp: Date?
        var snippet: String?
        var messageCount = 0

        let data = handle.readData(ofLength: 50_000)
        let content = String(data: data, encoding: .utf8) ?? ""

        for line in content.components(separatedBy: "\n").prefix(100) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            // Extract cwd (top-level field)
            if cwd == nil, let c = json["cwd"] as? String {
                cwd = c
            }

            // Extract timestamp (RFC3339 string) - keep updating to get the LAST one
            if let ts = json["timestamp"] as? String, let parsed = parseRFC3339(ts) {
                timestamp = parsed
            }

            // Count user messages and extract snippet
            if let type = json["type"] as? String, type == "user" {
                // Skip meta messages (system instructions) and compaction summaries
                let isMeta = json["isMeta"] as? Bool ?? false
                let isCompactSummary = json["isCompactSummary"] as? Bool ?? false

                if !isMeta && !isCompactSummary {
                    messageCount += 1
                    if snippet == nil,
                       let msg = json["message"] as? [String: Any],
                       let msgContent = msg["content"] as? String {
                        // Skip content starting with XML tags (command outputs, system stuff)
                        let trimmed = msgContent.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.hasPrefix("<") {
                            snippet = String(trimmed.prefix(60))
                        }
                    }
                }
            }
        }

        // For large files, use grep to count remaining messages and read tail for last timestamp
        if size > 50_000 {
            messageCount += grepCountUserMessages(url: url, pattern: "\"type\":\"user\"", skipBytes: 50_000)
            if let tailTs = lastTimestampFromTail(url: url, fileSize: size) {
                timestamp = tailTs
            }
        }

        guard let cwd else { return nil }

        let ts = timestamp ?? Date.distantPast

        // Update cache
        let cacheEntry = SessionCacheEntry(
            sessionId: sessionId,
            source: "claude",
            cwd: cwd,
            timestamp: ts,
            snippet: snippet,
            messageCount: messageCount,
            lastParsedOffset: Int64(size),
            fileMtime: mtime,
            fileSize: size
        )
        sessionCache.set(url.path, cacheEntry)

        return AISession(
            id: sessionId,
            source: .claude,
            worktreePath: "",
            cwd: cwd,
            timestamp: ts,
            snippet: snippet,
            sourcePath: url.path,
            messageCount: messageCount
        )
    }

    // MARK: - Codex Sessions

    private func parseCodexSession(_ url: URL) -> AISession? {
        // Check file attributes for cache validation
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        let size = Int64((attrs[.size] as? UInt64) ?? (attrs[.size] as? Int).map { UInt64($0) } ?? 0)

        // Extract UUID from filename
        let filename = url.deletingPathExtension().lastPathComponent
        let uuidPattern = try? NSRegularExpression(
            pattern: "([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
            options: .caseInsensitive
        )
        var sessionId: String?
        if let match = uuidPattern?.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
           let range = Range(match.range(at: 1), in: filename) {
            sessionId = String(filename[range])
        }

        // Check cache
        if let cached = sessionCache.get(url.path),
           sessionCache.isCacheValid(entry: cached, mtime: mtime, size: size) {
            return AISession(
                id: cached.sessionId,
                source: .codex,
                worktreePath: "",
                cwd: cached.cwd,
                timestamp: cached.timestamp,
                snippet: cached.snippet,
                sourcePath: url.path,
                messageCount: cached.messageCount
            )
        }

        // Parse fresh
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var cwd: String?
        var timestamp: Date?
        var snippet: String?
        var messageCount = 0

        let data = handle.readData(ofLength: 50_000)
        let content = String(data: data, encoding: .utf8) ?? ""

        for line in content.components(separatedBy: "\n").prefix(100) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let entryType = json["type"] as? String

            // Extract from session_meta
            if entryType == "session_meta",
               let payload = json["payload"] as? [String: Any] {
                if sessionId == nil, let id = payload["id"] as? String {
                    sessionId = id
                }
                if cwd == nil, let c = payload["cwd"] as? String {
                    cwd = c
                }
            }

            // Extract timestamp (RFC3339 string) - keep updating to get the LAST one
            if let ts = json["timestamp"] as? String, let parsed = parseRFC3339(ts) {
                timestamp = parsed
            }

            // Count user messages and extract snippet (response_item with payload.role == "user")
            if entryType == "response_item",
               let payload = json["payload"] as? [String: Any],
               payload["type"] as? String == "message",
               payload["role"] as? String == "user" {
                messageCount += 1
                if snippet == nil, let msgContent = payload["content"] {
                    if let text = msgContent as? String {
                        snippet = String(text.prefix(60))
                    } else if let arr = msgContent as? [[String: Any]] {
                        for block in arr {
                            if let text = block["text"] as? String {
                                snippet = String(text.prefix(60))
                                break
                            }
                        }
                    }
                }
            }
        }

        // For large files, use grep to count remaining user messages and read tail for last timestamp
        if size > 50_000 {
            messageCount += grepCountUserMessages(url: url, pattern: "\"role\":\"user\"", skipBytes: 50_000)
            if let tailTs = lastTimestampFromTail(url: url, fileSize: size) {
                timestamp = tailTs
            }
        }

        guard let sessionId, let cwd else { return nil }

        let ts = timestamp ?? Date.distantPast

        // Update cache
        let cacheEntry = SessionCacheEntry(
            sessionId: sessionId,
            source: "codex",
            cwd: cwd,
            timestamp: ts,
            snippet: snippet,
            messageCount: messageCount,
            lastParsedOffset: Int64(size),
            fileMtime: mtime,
            fileSize: size
        )
        sessionCache.set(url.path, cacheEntry)

        return AISession(
            id: sessionId,
            source: .codex,
            worktreePath: "",
            cwd: cwd,
            timestamp: ts,
            snippet: snippet,
            sourcePath: url.path,
            messageCount: messageCount
        )
    }

    // MARK: - Session Helpers

    private func findMatchingWorktree(_ cwd: String) -> String? {
        var bestMatch: String? = nil
        var bestLength = 0
        let normalizedCwd = normalizePathForMatch(cwd)

        for (_, worktrees) in worktreesByRepositoryID {
            for wt in worktrees {
                let normalizedWorktreePath = normalizePathForMatch(wt.path)
                // Must match at directory boundary: exact match OR cwd starts with worktree path + "/"
                let isMatch = normalizedCwd == normalizedWorktreePath ||
                    normalizedCwd.hasPrefix(normalizedWorktreePath + "/")
                if isMatch && normalizedWorktreePath.count > bestLength {
                    bestMatch = wt.path
                    bestLength = normalizedWorktreePath.count
                }
            }
        }
        return bestMatch
    }

    private func startAgentEventTailer() {
        let tailer = AgentEventTailer(url: AgentStatusPaths.eventsLogURL) { [weak self] event in
            self?.handleAgentLifecycleEvent(event)
        }
        agentEventTailer = tailer
        tailer.start()
    }

    private func handleAgentLifecycleEvent(_ event: AgentLifecycleEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            guard let worktreePath = self.findMatchingWorktree(event.cwd) else {
                if let existing = self.pendingAgentEventsByCwd[event.cwd],
                   existing.timestamp >= event.timestamp {
                    return
                }
                self.pendingAgentEventsByCwd[event.cwd] = event
                return
            }

            if let ackedAt = self.agentStatusAckedAtByWorktreePath[worktreePath],
               ackedAt >= event.timestamp {
                return
            }

            let status: WorktreeAgentStatus = switch event.eventType {
            case .start: .working
            case .permissionRequest: .permission
            case .stop: .review
            case .sessionEnd: .review
            }

            if let existing = self.agentStatusByWorktreePath[worktreePath],
               existing.updatedAt >= event.timestamp {
                return
            }

            self.agentStatusByWorktreePath[worktreePath] = .init(status: status, updatedAt: event.timestamp)
            self.rebuildSnapshotIfRecencySensitive()
        }
    }

    private func reconcilePendingAgentEvents() {
        if pendingAgentEventsByCwd.isEmpty { return }
        var didChange = false

        for (cwd, event) in pendingAgentEventsByCwd {
            guard let worktreePath = findMatchingWorktree(cwd) else { continue }

            if let ackedAt = agentStatusAckedAtByWorktreePath[worktreePath],
               ackedAt >= event.timestamp {
                pendingAgentEventsByCwd.removeValue(forKey: cwd)
                continue
            }

            let status: WorktreeAgentStatus = switch event.eventType {
            case .start: .working
            case .permissionRequest: .permission
            case .stop: .review
            case .sessionEnd: .review
            }

            if let existing = agentStatusByWorktreePath[worktreePath],
               existing.updatedAt >= event.timestamp {
                pendingAgentEventsByCwd.removeValue(forKey: cwd)
                continue
            }

            agentStatusByWorktreePath[worktreePath] = .init(status: status, updatedAt: event.timestamp)
            pendingAgentEventsByCwd.removeValue(forKey: cwd)
            didChange = true
        }

        if didChange {
            rebuildSnapshotIfRecencySensitive()
        }
    }

    private func seedAgentStatusesFromLog() {
        let url = AgentStatusPaths.eventsLogURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return }
        if size.int64Value <= 0 { return }

        let readBytes: Int64 = 256_000
        let start = UInt64(max(0, size.int64Value - readBytes))
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let data: Data
        do {
            try handle.seek(toOffset: start)
            data = try handle.readToEnd() ?? Data()
        } catch {
            return
        }

        var latestByCwd: [String: AgentLifecycleEvent] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let event = AgentEventTailer.parseLineData(Data(line)) else { continue }
            if let existing = latestByCwd[event.cwd],
               existing.timestamp >= event.timestamp {
                continue
            }
            latestByCwd[event.cwd] = event
        }

        for (_, event) in latestByCwd {
            // Skip Stop/SessionEnd events from before the last app quit:
            // they were already visible (or dismissed) in the previous session.
            if (event.eventType == .stop || event.eventType == .sessionEnd),
               let lastQuit = lastAppQuitTimestamp,
               event.timestamp <= lastQuit {
                continue
            }
            handleAgentLifecycleEvent(event)
        }
    }

    private func pruneAgentEventLogIfNeeded() {
        let url = AgentStatusPaths.eventsLogURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return }

        let maxBytes: Int64 = 5_000_000
        let keepBytes: Int64 = 1_000_000
        if size.int64Value <= maxBytes { return }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let fileSize = size.int64Value
        let start = UInt64(max(0, fileSize - keepBytes))
        do {
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    private func parseRFC3339(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Read the last N bytes of a JSONL file and extract the most recent RFC3339 timestamp.
    private func lastTimestampFromTail(url: URL, fileSize: Int64, tailBytes: Int = 8192) -> Date? {
        guard fileSize > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let offset = max(0, fileSize - Int64(tailBytes))
        handle.seek(toFileOffset: UInt64(offset))
        let data = handle.readData(ofLength: tailBytes)
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        // Walk lines in reverse to find the last valid timestamp
        for line in content.components(separatedBy: "\n").reversed() {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let ts = json["timestamp"] as? String,
                  let date = parseRFC3339(ts) else { continue }
            return date
        }
        return nil
    }

    private struct AgentStatusAcksPayload: Codable {
        var version: Int
        var ackedAtEpochByWorktreePath: [String: TimeInterval]
        var lastAppQuitEpoch: TimeInterval?
    }

    private static var agentStatusAcksFileURL: URL {
        AgentStatusPaths.eventsCacheDir.appendingPathComponent("agent-status-acks.json")
    }

    private func loadAgentStatusAcks() {
        // Try file-based storage first (shared across debug/release builds)
        if let data = try? Data(contentsOf: Self.agentStatusAcksFileURL),
           let payload = try? JSONDecoder().decode(AgentStatusAcksPayload.self, from: data),
           payload.version == 1 {
            agentStatusAckedAtByWorktreePath = payload.ackedAtEpochByWorktreePath.compactMapValues { Date(timeIntervalSince1970: $0) }
            if let epoch = payload.lastAppQuitEpoch {
                lastAppQuitTimestamp = Date(timeIntervalSince1970: epoch)
            }
            return
        }

        // One-time migration from UserDefaults (which has debug/release domain split)
        if let data = UserDefaults.standard.data(forKey: agentStatusAcksKey),
           let payload = try? JSONDecoder().decode(AgentStatusAcksPayload.self, from: data),
           payload.version == 1 {
            agentStatusAckedAtByWorktreePath = payload.ackedAtEpochByWorktreePath.compactMapValues { Date(timeIntervalSince1970: $0) }
            saveAgentStatusAcks()
            UserDefaults.standard.removeObject(forKey: agentStatusAcksKey)
        }
    }

    private func saveAgentStatusAcks() {
        let payload = AgentStatusAcksPayload(
            version: 1,
            ackedAtEpochByWorktreePath: agentStatusAckedAtByWorktreePath.mapValues { $0.timeIntervalSince1970 },
            lastAppQuitEpoch: lastAppQuitTimestamp?.timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: Self.agentStatusAcksFileURL, options: .atomic)
    }

    func recordAppQuit() {
        lastAppQuitTimestamp = Date()
        saveAgentStatusAcks()
    }

    private func acknowledgeAgentStatusPersistently(for worktreePath: String) {
        agentStatusAckedAtByWorktreePath[worktreePath] = Date()
        saveAgentStatusAcks()
    }

    /// Count occurrences of a pattern in a file using grep (faster for large files)
    private func grepCountUserMessages(url: URL, pattern: String, skipBytes: Int64) -> Int {
        // For files > 1MB, use grep which is much faster than Swift parsing
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return 0
        }
        let size = Int64((attrs[.size] as? UInt64) ?? (attrs[.size] as? Int).map { UInt64($0) } ?? 0)
        guard size > 1_000_000 else {
            return 0  // Small files are fully parsed in the main loop
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = ["-c", pattern, url.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let count = Int(output) {
                // Subtract the count from the first 50KB we already parsed
                // This is an approximation but good enough for display
                return max(0, count - 10)  // Assume ~10 messages in first 50KB
            }
        } catch {
            // Ignore grep failures
        }

        return 0
    }
}

extension WorktrunkStore: WorktrunkSidebarReconcilingStore {}
