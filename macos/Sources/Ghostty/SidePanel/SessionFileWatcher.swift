import Foundation

class SessionFileWatcher {
    private var stream: FSEventStreamRef?
    private let sessionManager: SessionManager
    private let debounceInterval: TimeInterval = 0.2

    private var pendingUpdates: [String: Date] = [:]
    private var debounceTimer: Timer?

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        startWatching()
    }

    deinit {
        stopWatching()
    }

    func startWatching() {
        let paths = getClaudeProjectsPaths()
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (
            streamRef,
            clientCallBackInfo,
            numEvents,
            eventPaths,
            eventFlags,
            eventIds
        ) in
            guard let clientCallBackInfo = clientCallBackInfo else { return }
            let watcher = Unmanaged<SessionFileWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
            watcher.handleEvents(paths: paths)
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        if let stream = stream {
            FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            FSEventStreamStart(stream)
        }

        // Initial scan
        scanAllFiles(paths: paths)
    }

    func stopWatching() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func getClaudeProjectsPaths() -> [String] {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let claudeProjectsDir = homeDir.appendingPathComponent(".claude/projects")

        guard let contents = try? FileManager.default.contentsOfDirectory(at: claudeProjectsDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var jsonlFiles: [String] = []
        for projectDir in contents where projectDir.hasDirectoryPath {
            let jsonl = projectDir.appendingPathComponent("data.jsonl")
            if FileManager.default.fileExists(atPath: jsonl.path) {
                jsonlFiles.append(jsonl.path)
            }
        }

        return jsonlFiles
    }

    private func handleEvents(paths: [String]) {
        for path in paths {
            guard path.hasSuffix(".jsonl") else { continue }
            pendingUpdates[path] = Date()
        }

        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            self?.processPendingUpdates()
        }
    }

    private func processPendingUpdates() {
        let paths = Array(pendingUpdates.keys)
        pendingUpdates.removeAll()
        scanAllFiles(paths: paths)
    }

    private func scanAllFiles(paths: [String]) {
        for path in paths {
            parseJSONL(at: path)
        }
    }

    private func parseJSONL(at path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var sessionsByClaudeId: [String: ParsedSession] = [:]

        for line in lines {
            guard let jsonData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

            guard let sessionId = extractSessionId(from: json) else { continue }

            var parsed = sessionsByClaudeId[sessionId] ?? ParsedSession(sessionId: sessionId)
            parsed.absorb(json: json)
            sessionsByClaudeId[sessionId] = parsed
        }

        // Update sessionManager with parsed sessions
        DispatchQueue.main.async { [weak self] in
            self?.updateSessions(sessions: Array(sessionsByClaudeId.values), path: path)
        }
    }

    private func updateSessions(sessions: [ParsedSession], path: String) {
        for parsed in sessions {
            sessionManager.updateSession(from: parsed)
        }
    }

    private func extractSessionId(from json: [String: Any]) -> String? {
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
        return nil
    }
}

struct ParsedSession {
    let sessionId: String
    var title: String = "New Session"
    var status: SessionStatus = .idle
    var timestamp: Date = Date()
    var branch: String?
    var isWorkTree: Bool = false

    mutating func absorb(json: [String: Any]) {
        if let extractedTimestamp = Self.extractTimestamp(from: json) {
            timestamp = extractedTimestamp
        }

        if let gitBranch = json["gitBranch"] as? String, !gitBranch.isEmpty {
            branch = gitBranch
        }

        if let type = json["type"] as? String, type == "worktree-state" {
            isWorkTree = true
            if let worktreeSession = json["worktreeSession"] as? [String: Any],
               let worktreeName = worktreeSession["worktreeName"] as? String,
               !worktreeName.isEmpty {
                branch = worktreeName
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
        if let content = container["content"] as? [[String: Any]] {
            let joined = content.compactMap { item -> String? in
                if let text = item["text"] as? String {
                    return text
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

    private static func makeTitle(from text: String) -> String {
        let cleaned = text
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
