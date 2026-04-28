import Foundation

class SessionFileWatcher {
    private var stream: FSEventStreamRef?
    private var knownFiles: Set<String> = []
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

        var sessions: [ParsedSession] = []
        for line in lines {
            guard let jsonData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

            if let type = json["type"] as? String, type == "user" {
                let message = json["message"] as? [String: Any]
                let content = message?["content"] as? [[String: Any]]
                let textContent = content?.first(where: { $0["type"] as? String == "text" }) as? [String: Any]
                let text = textContent?["text"] as? String ?? ""

                let title = String(text.prefix(10))
                let sessionId = json["session_id"] as? String ?? UUID().uuidString

                sessions.append(ParsedSession(sessionId: sessionId, title: title))
            }
        }

        // Update sessionManager with parsed sessions
        DispatchQueue.main.async { [weak self] in
            self?.updateSessions(sessions: sessions, path: path)
        }
    }

    private func updateSessions(sessions: [ParsedSession], path: String) {
        for parsed in sessions {
            if let existing = sessionManager.sessions.first(where: { $0.sessionId == parsed.sessionId }) {
                // Update existing session
                sessionManager.updateSessionStatus(sessionId: existing.id, status: parsed.status)
            }
        }
    }
}

private struct ParsedSession {
    let sessionId: String
    let title: String
    var status: SessionStatus = .idle
}
