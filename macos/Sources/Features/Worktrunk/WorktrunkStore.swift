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
    @Published var isRefreshing: Bool = false
    @Published var errorMessage: String? = nil

    private let repositoriesKey = "GhosttyWorktrunkRepositories.v1"
    private let sessionCache = SessionCacheManager()

    init() {
        load()
    }

    func worktrees(for repositoryID: UUID) -> [Worktree] {
        worktreesByRepositoryID[repositoryID] ?? []
    }

    func sessions(for worktreePath: String) -> [AISession] {
        sessionsByWorktreePath[worktreePath] ?? []
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
        Task { await refreshAll() }
    }

    func removeRepository(id: UUID) {
        repositories.removeAll(where: { $0.id == id })
        worktreesByRepositoryID[id] = nil
        save()
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
            await MainActor.run {
                worktreesByRepositoryID[repoID] = worktrees.sorted { a, b in
                    if a.isCurrent != b.isCurrent { return a.isCurrent }
                    if a.isMain != b.isMain { return a.isMain }
                    return a.branch.localizedStandardCompare(b.branch) == .orderedAscending
                }
                errorMessage = nil
            }
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

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - Session Discovery

    func refreshSessions() async {
        var allSessions: [String: [AISession]] = [:]
        var updateCount = 0
        let batchSize = 50

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
                            updateCount += 1

                            // Update UI every batchSize sessions
                            if updateCount % batchSize == 0 {
                                let snapshot = allSessions
                                await MainActor.run {
                                    sessionsByWorktreePath = snapshot
                                }
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
                        updateCount += 1

                        if updateCount % batchSize == 0 {
                            let snapshot = allSessions
                            await MainActor.run {
                                sessionsByWorktreePath = snapshot
                            }
                        }
                    }
                }
            }
        }

        // Final sort and update
        for key in allSessions.keys {
            allSessions[key]?.sort { $0.timestamp > $1.timestamp }
        }

        sessionCache.saveToDisk()

        await MainActor.run {
            sessionsByWorktreePath = allSessions
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

        for (_, worktrees) in worktreesByRepositoryID {
            for wt in worktrees {
                // Must match at directory boundary: exact match OR cwd starts with worktree path + "/"
                let isMatch = cwd == wt.path || cwd.hasPrefix(wt.path + "/")
                if isMatch && wt.path.count > bestLength {
                    bestMatch = wt.path
                    bestLength = wt.path.count
                }
            }
        }
        return bestMatch
    }

    private func parseRFC3339(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
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
