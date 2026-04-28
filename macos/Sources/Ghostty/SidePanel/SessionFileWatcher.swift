import Foundation

class SessionFileWatcher {
    private var stream: FSEventStreamRef?
    private let sessionManager: SessionManager
    private let claudeProjectsRoot: URL?

    private let processingQueue = DispatchQueue(label: "com.ghostty.session-file-watcher", qos: .utility)
    private let maxFileSize: UInt64 = 1_048_576 // 1MB - skip files being actively written

    /// Track modification dates so subsequent events skip unchanged files.
    private var lastModificationDates: [String: Date] = [:]
    /// Cache file path enumeration to avoid re-scanning the directory tree.
    private var cachedFilePaths: [String]?
    private var lastPathCacheRefresh = Date()
    private let pathCacheTTL: TimeInterval = 30

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        self.claudeProjectsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        startWatching()
    }

    deinit {
        stopWatching()
    }

    func startWatching() {
        guard let claudeProjectsRoot else { return }
        guard FileManager.default.fileExists(atPath: claudeProjectsRoot.path) else { return }

        // Initial scan on background queue — record mtimes so
        // subsequent FSEvents skip unchanged files.
        processingQueue.async { [weak self] in
            let paths = self?.getClaudeSessionFilePaths() ?? []
            self?.scanAllFiles(paths: paths)
            self?.recordModificationDates(for: paths)
        }

        // Start FSEventStream on a background runloop
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let pathsToWatch: [String] = [claudeProjectsRoot.path]
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                Self.fsEventCallback,
                &context,
                pathsToWatch as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.0, // latency 1s
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
            ) else { return }

            self.stream = stream
            FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            FSEventStreamStart(stream)
            CFRunLoopRun()
        }
    }

    private static let fsEventCallback: FSEventStreamCallback = { stream, info, numEvents, eventPaths, eventFlags, eventIds in
        guard let info else { return }
        let watcher = Unmanaged<SessionFileWatcher>.fromOpaque(info).takeUnretainedValue()
        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

        watcher.processingQueue.async { [weak watcher] in
            watcher?.handleEvents(paths: paths)
        }
    }

    func stopWatching() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Process only actually-changed JSONL files instead of re-scanning everything.
    private func handleEvents(paths: [String]) {
        var changedPaths: [String] = []

        for path in paths where !path.contains("/subagents/") && path.hasSuffix(".jsonl") {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: path)
                if let fileSize = attrs[.size] as? UInt64, fileSize > maxFileSize { continue }
                let modDate = (attrs[.modificationDate] as? Date) ?? Date()
                if let lastMod = lastModificationDates[path], modDate <= lastMod { continue }
                lastModificationDates[path] = modDate
                changedPaths.append(path)
            } catch {
                continue
            }
        }

        guard !changedPaths.isEmpty else { return }
        scanAllFiles(paths: changedPaths)
    }

    /// Record mtimes so subsequent FSEvents can skip unchanged files.
    private func recordModificationDates(for paths: [String]) {
        for path in paths {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let modDate = attrs[.modificationDate] as? Date else { continue }
            lastModificationDates[path] = modDate
        }
    }

    /// Claude session JSONL files, cached and refreshed every `pathCacheTTL` seconds.
    private func getClaudeSessionFilePaths() -> [String] {
        let now = Date()
        if let cached = cachedFilePaths, now.timeIntervalSince(lastPathCacheRefresh) < pathCacheTTL {
            return cached
        }

        guard let claudeProjectsRoot else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: claudeProjectsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var jsonlFiles: [String] = []
        for case let fileURL as URL in enumerator {
            let path = fileURL.path

            if path.contains("/subagents/") {
                if fileURL.hasDirectoryPath {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard path.hasSuffix(".jsonl") else { continue }

            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                jsonlFiles.append(path)
            }
        }

        let result = jsonlFiles.sorted()
        cachedFilePaths = result
        lastPathCacheRefresh = now
        return result
    }

    // MARK: - Incremental parse cache (claudine-style byte-offset tracking)

    private struct ParseCache {
        var byteOffset: UInt64
        var sessionsByClaudeId: [String: ParsedSession]
    }

    private var parseCache: [String: ParseCache] = [:]
    private var parseCacheOrder: [String] = []
    private let maxParseCacheEntries = 500

    /// Promote cache entry to MRU position; evict oldest if over limit.
    private func touchParseCache(path: String, cache: ParseCache) {
        if parseCache[path] == nil {
            parseCacheOrder.append(path)
        }
        parseCache[path] = cache
        while parseCacheOrder.count > maxParseCacheEntries {
            let oldest = parseCacheOrder.removeFirst()
            parseCache.removeValue(forKey: oldest)
        }
    }

    private func scanAllFiles(paths: [String]) {
        for path in paths {
            parseJSONL(at: path)
        }
    }

    /// Parse a JSONL file incrementally, only reading/parsing new bytes.
    private func parseJSONL(at path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64, fileSize > 0, fileSize <= maxFileSize else {
            return
        }

        if var cached = parseCache[path] {
            if cached.byteOffset == fileSize { return } // no new data

            if cached.byteOffset > fileSize {
                // File was rewritten (shrank) — invalidate, do full parse
                parseCache.removeValue(forKey: path)
                parseCacheOrder.removeAll { $0 == path }
                parseFullJSONL(path: path, fileSize: fileSize)
                return
            }

            // File grew — incremental parse: read only new bytes, parse only new lines
            parseIncrementalJSONL(path: path, cache: &cached, fileSize: fileSize)
            return
        }

        // First parse of this file
        parseFullJSONL(path: path, fileSize: fileSize)
    }

    /// Full read + parse of a JSONL file.
    private func parseFullJSONL(path: String, fileSize: UInt64) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var sessionsByClaudeId: [String: ParsedSession] = [:]

        for line in lines {
            parseJSONLLine(line, into: &sessionsByClaudeId, filePath: path)
        }

        let cache = ParseCache(byteOffset: fileSize, sessionsByClaudeId: sessionsByClaudeId)
        touchParseCache(path: path, cache: cache)

        DispatchQueue.main.async { [weak self] in
            self?.updateSessions(sessions: Array(sessionsByClaudeId.values), path: path)
        }
    }

    /// Appended-bytes-only read + parse, merging into cached state.
    private func parseIncrementalJSONL(path: String, cache: inout ParseCache, fileSize: UInt64) {
        // Read only from the previous byte offset to the end of file
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            // Fall back to full parse
            parseCache.removeValue(forKey: path)
            parseCacheOrder.removeAll { $0 == path }
            parseFullJSONL(path: path, fileSize: fileSize)
            return
        }
        defer { try? handle.close() }

        handle.seek(toFileOffset: cache.byteOffset)
        let newData = handle.readDataToEndOfFile()
        guard !newData.isEmpty else { return } // no new bytes

        // The file may have been rewritten with the same byteOffset;
        // if reading from offset yields garbage, fall back to full parse.
        guard let newContent = String(data: newData, encoding: .utf8) else { return }

        let lines = newContent.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var changed = false

        for line in lines {
            parseJSONLLine(line, into: &cache.sessionsByClaudeId, filePath: path)
            changed = true
        }

        cache.byteOffset = fileSize
        touchParseCache(path: path, cache: cache)

        if changed {
            // Only dispatch on main when there are actual updates
            let sessions = Array(cache.sessionsByClaudeId.values)
            DispatchQueue.main.async { [weak self] in
                self?.updateSessions(sessions: sessions, path: path)
            }
        }
    }

    /// Parse a single JSONL line and merge result into the accumulator.
    private func parseJSONLLine(_ line: String, into acc: inout [String: ParsedSession], filePath: String) {
        guard let lineData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let sessionId = extractSessionId(from: json, filePath: filePath) else { return }

        var parsed = acc[sessionId] ?? ParsedSession(sessionId: sessionId)
        parsed.absorb(json: json)
        acc[sessionId] = parsed
    }

    private func updateSessions(sessions: [ParsedSession], path: String) {
        for var parsed in sessions {
            if parsed.timestamp == .distantPast {
                parsed.timestamp = parsed.createdAt ?? Date()
            }
            sessionManager.updateSession(from: parsed)
        }
    }

    private func extractSessionId(from json: [String: Any], filePath: String) -> String? {
        if let value = json["sessionId"] as? String, !value.isEmpty {
            return value
        }
        if let value = json["session_id"] as? String, !value.isEmpty {
            return value
        }
        if let message = json["message"] as? [String: Any] {
            if let value = message["sessionId"] as? String, !value.isEmpty {
                return value
            }
            if let value = message["session_id"] as? String, !value.isEmpty {
                return value
            }
        }

        let fileSessionId = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        return fileSessionId.isEmpty ? nil : fileSessionId
    }
}

struct ParsedSession {
    let sessionId: String
    var title: String = "New Session"
    var status: SessionStatus = .idle
    var timestamp: Date = .distantPast
    var createdAt: Date?
    var branch: String?
    var isWorkTree: Bool = false
    var cwd: String?

    mutating func absorb(json: [String: Any]) {
        if let extractedTimestamp = Self.extractTimestamp(from: json) {
            if createdAt == nil || extractedTimestamp < createdAt! {
                createdAt = extractedTimestamp
            }
            if extractedTimestamp > timestamp {
                timestamp = extractedTimestamp
            }
        }

        if let gitBranch = Self.extractGitBranch(from: json), !gitBranch.isEmpty {
            branch = gitBranch
        }

        if let extractedCWD = Self.extractCWD(from: json), !extractedCWD.isEmpty {
            cwd = extractedCWD
        }

        if let type = json["type"] as? String, type == "worktree-state" {
            isWorkTree = true
            if let worktreeSession = json["worktreeSession"] as? [String: Any],
               let worktreeName = worktreeSession["worktreeName"] as? String,
               !worktreeName.isEmpty {
                branch = worktreeName
            }
            if let worktreeSession = json["worktreeSession"] as? [String: Any],
               let worktreePath = worktreeSession["worktreePath"] as? String,
               !worktreePath.isEmpty {
                cwd = worktreePath
            }
        }

        let role = (json["type"] as? String) ?? ((json["message"] as? [String: Any])?["role"] as? String)
        let text = Self.extractText(from: json)

        if role == "user", title == "New Session", !text.isEmpty {
            title = Self.makeTitle(from: text)
            status = .running
        } else if role == "assistant" {
            if Self.needsUserInput(text: text, json: json) {
                status = .needInput
            } else if Self.isRunning(json: json) {
                status = .running
            } else {
                status = .idle
            }
        }
    }

    private static func extractText(from json: [String: Any]) -> String {
        if let text = json["text"] as? String {
            return text
        }

        let container = (json["message"] as? [String: Any]) ?? json
        if let content = container["content"] as? String {
            return content
        }
        if let content = container["content"] as? [[String: Any]] {
            let joined = content.compactMap { item -> String? in
                if let text = item["text"] as? String {
                    return text
                }
                if let content = item["content"] as? String {
                    return content
                }
                if let input = item["input"] as? [String: Any],
                   let text = input["text"] as? String {
                    return text
                }
                return nil
            }.joined(separator: "\n")
            if !joined.isEmpty {
                return joined
            }
        }

        return ""
    }

    private static func extractCWD(from json: [String: Any]) -> String? {
        if let cwd = json["cwd"] as? String, !cwd.isEmpty {
            return cwd
        }

        if let worktreeSession = json["worktreeSession"] as? [String: Any] {
            if let worktreePath = worktreeSession["worktreePath"] as? String, !worktreePath.isEmpty {
                return worktreePath
            }
            if let originalCwd = worktreeSession["originalCwd"] as? String, !originalCwd.isEmpty {
                return originalCwd
            }
        }

        if let message = json["message"] as? [String: Any],
           let cwd = message["cwd"] as? String,
           !cwd.isEmpty {
            return cwd
        }

        return nil
    }

    private static func extractGitBranch(from json: [String: Any]) -> String? {
        if let gitBranch = json["gitBranch"] as? String, !gitBranch.isEmpty {
            return gitBranch
        }
        if let worktreeSession = json["worktreeSession"] as? [String: Any],
           let worktreeBranch = worktreeSession["worktreeBranch"] as? String,
           !worktreeBranch.isEmpty {
            return worktreeBranch
        }
        return nil
    }

    private static func makeTitle(from text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "<([a-zA-Z][\\w-]*)[\\s>][\\s\\S]*?<\\/\\1>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return "New Session" }

        let firstLine = cleaned.components(separatedBy: .newlines).first ?? cleaned
        return String(firstLine.prefix(60))
    }

    private static func extractTimestamp(from json: [String: Any]) -> Date? {
        if let iso = json["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: iso)
        }
        if let ts = json["timestamp"] as? TimeInterval {
            return Date(timeIntervalSince1970: ts)
        }
        return nil
    }

    private static func needsUserInput(text: String, json: [String: Any]) -> Bool {
        if text.range(of: "\\b(should I|would you like|do you want|shall I|please confirm)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }

        if let toolUses = json["toolUses"] as? [[String: Any]],
           toolUses.contains(where: { ($0["name"] as? String) == "AskUserQuestion" }) {
            return true
        }

        return false
    }

    private static func isRunning(json: [String: Any]) -> Bool {
        if let toolUses = json["toolUses"] as? [[String: Any]], !toolUses.isEmpty {
            return true
        }
        if let message = json["message"] as? [String: Any],
           let role = message["role"] as? String,
           role == "user" {
            return true
        }
        return false
    }
}
