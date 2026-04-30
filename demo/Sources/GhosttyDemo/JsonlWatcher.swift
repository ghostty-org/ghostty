import Foundation

// MARK: - ParsedSession

/// Represents a Claude Code session parsed from a JSONL conversation file.
/// Mirrors the macos SidePanel `ParsedSession` from `SessionFileWatcher.swift`.
struct ParsedSession {
    let sessionId: String
    var title: String = "New Session"
    var status: SessionStatus = .idle
    var timestamp: Date = .distantPast
    var createdAt: Date?
    var branch: String?
    var isWorkTree: Bool = false
    var cwd: String?

    /// Merge fields from a single JSONL dictionary into this session.
    /// Later entries in a JSONL file can update the status, title, etc.
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

    // MARK: - Private helpers

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
        if text.range(of: "\\b(should I|would you like|do you want|shall I|please confirm)\\b",
                      options: [.regularExpression, .caseInsensitive]) != nil {
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

// MARK: - JsonlWatcher

/// Monitors `~/.claude/projects/` for changes to Claude Code JSONL session files.
///
/// Uses a lightweight GCD `DispatchSourceFileSystemObject` on the directory
/// (instead of Carbon FSEvents) for simpler dependencies.  When new data is
/// detected it re-parses only the appended bytes (incremental), extracts
/// session statuses, and delivers them via the `onChange` callback.
///
/// Usage:
/// ```swift
/// let watcher = JsonlWatcher(path: claudeProjectsPath)
/// watcher.start { statuses in
///     // statuses is [sessionId: SessionStatus]
///     // merge into your SessionManager or board state
/// }
/// ```
class JsonlWatcher {
    private let path: String  // e.g. ~/.claude/projects/
    private var source: DispatchSourceFileSystemObject?
    private var fileOffsets: [String: UInt64] = [:]  // incremental parse tracking
    private let processingQueue = DispatchQueue(label: "com.ghostty.jsonl-watcher", qos: .utility)
    private var lastModificationDates: [String: Date] = [:]
    private var onChange: (([String: SessionStatus]) -> Void)?

    // Debounce
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.5

    // Limits
    private let maxFileSize: UInt64 = 1_048_576  // 1 MB

    // Parse cache: file path -> [sessionId: ParsedSession]
    private var sessionsCache: [String: [String: ParsedSession]] = [:]
    private var cacheOrder: [String] = []
    private let maxCacheEntries = 500

    // MARK: - Lifecycle

    init(path: String) {
        self.path = path
    }

    deinit {
        stop()
    }

    /// Start monitoring.  Triggers an initial scan immediately and then
    /// watches for directory-level changes on the processing queue.
    func start(onChange: @escaping ([String: SessionStatus]) -> Void) {
        self.onChange = onChange

        guard FileManager.default.fileExists(atPath: path) else { return }

        // Initial scan on background queue — record mtimes so subsequent
        // directory events skip unchanged files.
        processingQueue.async { [weak self] in
            self?.performScan()
        }

        setupDirectoryMonitoring()
    }

    /// Stop monitoring and release resources.
    func stop() {
        source?.cancel()
        source = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    // MARK: - Directory monitoring (GCD dispatch source)

    /// Opens an event-only file descriptor on the watched directory and
    /// installs a `DispatchSourceFileSystemObject` that fires on write,
    /// rename, delete, or extend events.
    private func setupDirectoryMonitoring() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: processingQueue
        )

        dispatchSource.setEventHandler { [weak self] in
            self?.scheduleScan()
        }

        dispatchSource.setCancelHandler {
            close(fd)
        }

        source = dispatchSource
        dispatchSource.resume()
    }

    /// Debounce a full scan; coalesces rapid file-system events.
    private func scheduleScan() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performScan()
        }
        debounceWorkItem = workItem
        processingQueue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    // MARK: - Scanning

    /// Enumerate JSONL files, check modification times against the last
    /// known values, and parse any that have changed.
    private func performScan() {
        let jsonlFiles = enumerateJsonlFiles()
        var changedStatuses: [String: SessionStatus] = [:]

        for filePath in jsonlFiles {
            // Skip sub-agent directories
            guard !filePath.contains("/subagents/") else { continue }

            // Check file size
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                  let fileSize = attrs[.size] as? UInt64,
                  fileSize > 0,
                  fileSize <= maxFileSize else {
                continue
            }

            // Check modification date
            let modDate = (attrs[.modificationDate] as? Date) ?? Date()
            if let lastMod = lastModificationDates[filePath], modDate <= lastMod {
                continue  // unchanged
            }
            lastModificationDates[filePath] = modDate

            // Parse incrementally
            guard let parsed = parseJSONL(at: filePath, fileSize: fileSize) else {
                continue
            }

            for (sessionId, session) in parsed {
                changedStatuses[sessionId] = session.status
            }
        }

        guard !changedStatuses.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onChange?(changedStatuses)
        }
    }

    /// Recursively list `.jsonl` files under the watched directory,
    /// skipping `subagents/` directories.
    private func enumerateJsonlFiles() -> [String] {
        let rootURL = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var jsonlFiles: [String] = []
        for case let fileURL as URL in enumerator {
            let filePath = fileURL.path

            if filePath.contains("/subagents/") {
                if fileURL.hasDirectoryPath {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard filePath.hasSuffix(".jsonl") else { continue }

            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                jsonlFiles.append(filePath)
            }
        }

        return jsonlFiles.sorted()
    }

    // MARK: - Incremental JSONL parsing

    /// Parse a JSONL file, either from scratch or incrementally from the
    /// last known byte offset.  Returns the session map for the file, or
    /// `nil` if nothing changed.
    ///
    /// Updates `fileOffsets[path]` and `sessionsCache[path]` as a side-effect.
    private func parseJSONL(at path: String, fileSize: UInt64) -> [String: ParsedSession]? {
        guard let lastOffset = fileOffsets[path] else {
            // First parse — full file
            return parseFullJSONL(at: path, fileSize: fileSize)
        }

        if lastOffset == fileSize {
            return nil  // no new data
        }

        if lastOffset > fileSize {
            // File was truncated / rewritten — full re-parse
            fileOffsets.removeValue(forKey: path)
            sessionsCache.removeValue(forKey: path)
            cacheOrder.removeAll { $0 == path }
            return parseFullJSONL(at: path, fileSize: fileSize)
        }

        // File grew — incremental parse
        return parseIncrementalJSONL(at: path, fileSize: fileSize)
    }

    /// Full read + parse of a JSONL file.
    private func parseFullJSONL(at path: String, fileSize: UInt64) -> [String: ParsedSession]? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var sessions: [String: ParsedSession] = [:]

        for line in lines {
            parseJSONLine(line, into: &sessions, filePath: path)
        }

        fileOffsets[path] = fileSize
        setCache(path: path, sessions: sessions)
        return sessions
    }

    /// Appended-bytes-only read + parse, merging into the cached state.
    private func parseIncrementalJSONL(at path: String, fileSize: UInt64) -> [String: ParsedSession]? {
        guard let lastOffset = fileOffsets[path] else {
            return parseFullJSONL(at: path, fileSize: fileSize)
        }

        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            // Fall back to full parse
            fileOffsets.removeValue(forKey: path)
            sessionsCache.removeValue(forKey: path)
            cacheOrder.removeAll { $0 == path }
            return parseFullJSONL(at: path, fileSize: fileSize)
        }
        defer { try? handle.close() }

        handle.seek(toFileOffset: lastOffset)
        let newData = handle.readDataToEndOfFile()

        guard !newData.isEmpty else { return nil }

        guard let newContent = String(data: newData, encoding: .utf8) else { return nil }

        let lines = newContent.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        // Start from cached state
        var sessions = sessionsCache[path] ?? [:]
        for line in lines {
            parseJSONLine(line, into: &sessions, filePath: path)
        }

        fileOffsets[path] = fileSize
        setCache(path: path, sessions: sessions)

        // Only return sessions that were touched by the new lines
        var touched: [String: ParsedSession] = [:]
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let sessionId = extractSessionId(from: json, filePath: path) else { continue }
            if let session = sessions[sessionId] {
                touched[sessionId] = session
            }
        }
        return touched.isEmpty ? nil : touched
    }

    /// Parse a single JSONL line and merge the result into the accumulator.
    private func parseJSONLine(_ line: String, into acc: inout [String: ParsedSession], filePath: String) {
        guard let lineData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let sessionId = extractSessionId(from: json, filePath: filePath) else { return }

        var parsed = acc[sessionId] ?? ParsedSession(sessionId: sessionId)
        parsed.absorb(json: json)
        acc[sessionId] = parsed
    }

    /// Extract a session identifier from a JSONL line dictionary.
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

        // Fall back to the file name (minus extension) as session ID
        let fileSessionId = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        return fileSessionId.isEmpty ? nil : fileSessionId
    }

    // MARK: - Cache management (LRU-eviction)

    /// Store sessions for a file path, promoting to MRU position and
    /// evicting the oldest entry when over the limit.
    private func setCache(path: String, sessions: [String: ParsedSession]) {
        if sessionsCache[path] == nil {
            cacheOrder.append(path)
        }
        sessionsCache[path] = sessions
        while cacheOrder.count > maxCacheEntries {
            let oldest = cacheOrder.removeFirst()
            sessionsCache.removeValue(forKey: oldest)
            fileOffsets.removeValue(forKey: oldest)
            lastModificationDates.removeValue(forKey: oldest)
        }
    }
}
