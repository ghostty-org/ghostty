import Foundation

enum SessionSource: String, Codable {
    case claude
    case codex

    var icon: String {
        switch self {
        case .claude: return "terminal"
        case .codex: return "sparkles"
        }
    }
}

struct AISession: Identifiable, Hashable {
    var id: String
    var source: SessionSource
    var worktreePath: String
    var cwd: String
    var timestamp: Date  // from JSON timestamp field, NOT file mtime
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
    @Published private var agentStatusByWorktreePath: [String: WorktreeAgentStatusEntry] = [:]
    @Published var isRefreshing: Bool = false
    @Published var errorMessage: String? = nil
    @Published private(set) var sidebarModelRevision: Int = 0
    @Published var worktreeSortOrder: WorktreeSortOrder = .alphabetical {
        didSet {
            if oldValue != worktreeSortOrder {
                saveSortOrder()
                resortAllWorktrees()
            }
        }
    }
    @Published var sidebarListMode: WorktrunkSidebarListMode = .nestedByRepo {
        didSet {
            if oldValue != sidebarListMode {
                saveSidebarListMode()
            }
        }
    }

    private let repositoriesKey = "GhosttyWorktrunkRepositories.v1"
    private let sortOrderKey = "GhostreeWorktreeSortOrder.v1"
    private let sidebarListModeKey = "GhostreeWorktrunkSidebarListMode.v1"
    private let agentStatusAcksKey = "GhostreeWorktrunkAgentStatusAcks.v1"
    private let sessionCache = SessionCacheManager()
    private var agentEventTailer: AgentEventTailer? = nil
    private var pendingAgentEventsByCwd: [String: AgentLifecycleEvent] = [:]
    private var agentStatusAckedAtByWorktreePath: [String: Date] = [:]
    private var lastAppQuitTimestamp: Date?
    private var sidebarModelRevisionCounter: Int = 0

    init() {
        load()
        loadSortOrder()
        loadSidebarListMode()
        loadAgentStatusAcks()
        AgentHookInstaller.ensureInstalled()
        pruneAgentEventLogIfNeeded()
        startAgentEventTailer()
        seedAgentStatusesFromLog()
    }

    private func bumpSidebarModelRevision() {
        sidebarModelRevisionCounter += 1
        sidebarModelRevision = sidebarModelRevisionCounter
    }

    private func pruneWorktreeScopedState(removedPaths: Set<String>) {
        guard !removedPaths.isEmpty else { return }
        for path in removedPaths {
            sessionsByWorktreePath[path] = nil
            gitTrackingByWorktreePath[path] = nil
            agentStatusByWorktreePath[path] = nil
            agentStatusAckedAtByWorktreePath[path] = nil
        }
    }

    func worktrees(for repositoryID: UUID) -> [Worktree] {
        worktreesByRepositoryID[repositoryID] ?? []
    }

    func allWorktreesSorted() -> [Worktree] {
        let all = repositories.flatMap { worktrees(for: $0.id) }
        return sortWorktrees(all)
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

    func acknowledgeAgentStatus(for worktreePath: String) {
        guard let entry = agentStatusByWorktreePath[worktreePath] else { return }

        switch entry.status {
        case .review:
            agentStatusByWorktreePath.removeValue(forKey: worktreePath)
            acknowledgeAgentStatusPersistently(for: worktreePath)
        case .permission:
            agentStatusByWorktreePath[worktreePath] = .init(status: .working, updatedAt: Date())
            acknowledgeAgentStatusPersistently(for: worktreePath)
        case .working:
            break
        }
    }

    func clearAgentReviewIfViewing(cwd: String) {
        guard let worktreePath = findMatchingWorktree(cwd) else { return }
        guard let entry = agentStatusByWorktreePath[worktreePath] else { return }
        guard entry.status == .review else { return }
        agentStatusByWorktreePath.removeValue(forKey: worktreePath)
        acknowledgeAgentStatusPersistently(for: worktreePath)
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
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            await MainActor.run { errorMessage = message }
        }
    }

    func addRepository(path: String, displayName: String? = nil) {
        let normalized = normalizePath(path)
        guard !repositories.contains(where: { normalizePath($0.path) == normalized }) else { return }
        repositories.append(.init(path: normalized, displayName: displayName))
        save()
        bumpSidebarModelRevision()
        Task { await refreshAll() }
    }

    func removeRepository(id: UUID) {
        let removedPaths = Set(worktreesByRepositoryID[id]?.map(\.path) ?? [])
        repositories.removeAll(where: { $0.id == id })
        worktreesByRepositoryID[id] = nil
        pruneWorktreeScopedState(removedPaths: removedPaths)
        save()
        bumpSidebarModelRevision()
    }

    func refreshAll() async {
        await MainActor.run {
            isRefreshing = true
        }

        for repo in repositories {
            await refresh(repoID: repo.id)
        }

        await refreshSessions()

        await MainActor.run {
            isRefreshing = false
        }
    }

    func refresh(repoID: UUID) async {
        guard let repo = repositories.first(where: { $0.id == repoID }) else { return }
        let previousPaths = await MainActor.run {
            Set(worktreesByRepositoryID[repoID]?.map(\.path) ?? [])
        }
        do {
            let result = try await WorktrunkClient.run(["-C", repo.path, "list", "--format=json"])
            let data = Data(result.stdout.utf8)
            let items = try JSONDecoder().decode([WtListItem].self, from: data)

            let worktrees: [Worktree] = items.compactMap { item in
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
            let newPaths = Set(worktrees.map(\.path))
            let removedPaths = previousPaths.subtracting(newPaths)
            await MainActor.run {
                worktreesByRepositoryID[repoID] = sortWorktrees(worktrees)
                errorMessage = nil
                reconcilePendingAgentEvents()
                pruneWorktreeScopedState(removedPaths: removedPaths)
                bumpSidebarModelRevision()
            }
            await refreshGitTracking(for: worktrees, removing: previousPaths)
        } catch {
            await MainActor.run {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
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
            return worktrees(for: repoID).first(where: { $0.branch == branch })
        } catch {
            await MainActor.run {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
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
            await MainActor.run { errorMessage = nil }
            return true
        } catch {
            await MainActor.run {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
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

    private func resortAllWorktrees() {
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
            bumpSidebarModelRevision()
        }
    }

    private func sortWorktrees(_ worktrees: [Worktree]) -> [Worktree] {
        worktrees.sorted { a, b in
            // Current and main always pinned to top
            if a.isCurrent != b.isCurrent { return a.isCurrent }
            if a.isMain != b.isMain { return a.isMain }

            switch worktreeSortOrder {
            case .alphabetical:
                return a.branch.localizedStandardCompare(b.branch) == .orderedAscending
            case .recentActivity:
                let dateA = latestActivityDate(for: a.path)
                let dateB = latestActivityDate(for: b.path)
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
            for path in previousPaths where !newPaths.contains(path) {
                gitTrackingByWorktreePath[path] = nil
            }
            for path in newPaths where results[path] == nil {
                gitTrackingByWorktreePath[path] = nil
            }
            for (path, tracking) in results {
                gitTrackingByWorktreePath[path] = tracking
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

    func refreshSessions() async {
        var allSessions: [String: [AISession]] = [:]
        var updateCount = 0
        var dirtyWorktreePaths = Set<String>()
        let publishCheckBatch = 25
        let publishIntervalSeconds: TimeInterval = 0.2
        var lastPublish = Date.distantPast

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
                sessionsByWorktreePath = snapshot
                bumpSidebarModelRevision()
            }
        }

        // Scan Claude sessions with periodic UI updates
        let claudeProjectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        if let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for projectDir in projectDirs {
                let sessionFiles = (try? FileManager.default.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
                ))?.filter { $0.pathExtension == "jsonl" } ?? []

                for sessionFile in sessionFiles {
                    if var session = parseClaudeSession(sessionFile) {
                        if session.snippet == "Warmup" { continue }
                        if let worktreePath = findMatchingWorktree(session.cwd) {
                            session.worktreePath = worktreePath
                            allSessions[worktreePath, default: []].append(session)
                            dirtyWorktreePaths.insert(worktreePath)
                            updateCount += 1

                            if updateCount % publishCheckBatch == 0 {
                                await publishSnapshotIfNeeded()
                            }
                        }
                    }
                }
            }
        }

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

                if var session = parseCodexSession(fileURL) {
                    if let worktreePath = findMatchingWorktree(session.cwd) {
                        session.worktreePath = worktreePath
                        allSessions[worktreePath, default: []].append(session)
                        dirtyWorktreePaths.insert(worktreePath)
                        updateCount += 1

                        if updateCount % publishCheckBatch == 0 {
                            await publishSnapshotIfNeeded()
                        }
                    }
                }
            }
        }

        // Final sort and update
        prepareForPublish()

        sessionCache.saveToDisk()

        await MainActor.run {
            sessionsByWorktreePath = allSessions
            bumpSidebarModelRevision()
            if worktreeSortOrder == .recentActivity {
                resortAllWorktrees()
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

            // Extract timestamp (RFC3339 string)
            if timestamp == nil, let ts = json["timestamp"] as? String {
                timestamp = parseRFC3339(ts)
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

        // For large files, use grep to count remaining messages
        if size > 50_000 {
            messageCount += grepCountUserMessages(url: url, pattern: "\"type\":\"user\"", skipBytes: 50_000)
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

            // Extract timestamp (RFC3339 string)
            if timestamp == nil, let ts = json["timestamp"] as? String {
                timestamp = parseRFC3339(ts)
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

        // For large files, use grep to count remaining user messages
        if size > 50_000 {
            messageCount += grepCountUserMessages(url: url, pattern: "\"role\":\"user\"", skipBytes: 50_000)
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
        }
    }

    private func reconcilePendingAgentEvents() {
        if pendingAgentEventsByCwd.isEmpty { return }

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
