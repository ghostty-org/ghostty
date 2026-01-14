import Foundation
import Combine

/// Represents the state of a Claude Code session
/// This is populated from the statusline hook that writes to ~/.terminaut/state.json
struct SessionState: Codable {
    var model: String?
    var version: String?
    var cwd: String?
    var contextPercent: Double?
    var quotaPercent: Double?
    var gitBranch: String?
    var gitUncommitted: Int?
    var gitAhead: Int?
    var gitBehind: Int?
    var currentTool: String?
    var todos: [TodoItem]?
    var openPRs: [PullRequest]?
    var timestamp: Date?
    var context: ContextBreakdown?

    struct TodoItem: Codable, Identifiable {
        var id: String { content }
        let content: String
        let status: String
        let activeForm: String?
    }

    struct PullRequest: Codable, Identifiable {
        var id: Int { number }
        let number: Int
        let title: String
        let author: String?
        let isDraft: Bool?
        let updatedAt: String?
        let state: String?      // "open", "closed", "merged"
        let closedAt: String?   // ISO timestamp when closed

        var isClosed: Bool {
            guard let s = state?.uppercased() else { return false }
            return s == "CLOSED" || s == "MERGED"
        }
    }

    /// Context window usage data from Claude Code
    struct ContextBreakdown: Codable {
        // Totals for the session
        var totalInputTokens: Int?
        var totalOutputTokens: Int?
        var maxTokens: Int?
        var usedPercent: Int?
        var remainingPercent: Int?

        // Current API call usage
        var currentInput: Int?
        var currentOutput: Int?
        var cacheCreation: Int?
        var cacheRead: Int?

        /// Total tokens used (input + output)
        var totalTokens: Int? {
            guard let input = totalInputTokens, let output = totalOutputTokens else { return nil }
            return input + output
        }

        /// Calculate percentage of max tokens
        func percent(of value: Int?) -> Double {
            guard let value = value, let max = maxTokens, max > 0 else { return 0 }
            return Double(value) / Double(max) * 100
        }
    }

    static let empty = SessionState()
}

/// Watches per-session state files and finds the one matching the project path
class SessionStateWatcher: ObservableObject {
    @Published var state: SessionState = .empty

    private let statesDir: URL
    private var projectPath: String = ""
    private var dirMonitor: DispatchSourceFileSystemObject?
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var dirDescriptor: Int32 = -1
    private var fileDescriptor: Int32 = -1
    private var currentStateFile: URL?
    private var scanTimer: Timer?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        statesDir = home.appendingPathComponent(".terminaut/states")
        print("[StateWatcher] INIT - statesDir: \(statesDir.path)")
        startWatching()
    }

    deinit {
        stopWatching()
    }

    /// Set the project path to watch for
    func watchProject(path: String) {
        log("watchProject called with: \(path)")
        projectPath = path

        // Compute project state file name (same logic as statusline.sh)
        let projectName = URL(fileURLWithPath: path).lastPathComponent
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let stateFile = statesDir.appendingPathComponent("project-\(projectName).json")
        log("Looking for project state file: \(stateFile.path)")

        if FileManager.default.fileExists(atPath: stateFile.path) {
            watchFile(stateFile)
        } else {
            log("Project state file not found, waiting...")
            // Start timer to check for file creation
            startPolling()
        }
    }

    private func startPolling() {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.projectPath.isEmpty else { return }
            let projectName = URL(fileURLWithPath: self.projectPath).lastPathComponent
                .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            let stateFile = self.statesDir.appendingPathComponent("project-\(projectName).json")
            if FileManager.default.fileExists(atPath: stateFile.path) {
                self.log("Project state file found: \(stateFile.path)")
                self.watchFile(stateFile)
                self.scanTimer?.invalidate()
            }
        }
    }

    func startWatching() {
        // Create directory if needed
        try? FileManager.default.createDirectory(at: statesDir, withIntermediateDirectories: true)
        log("startWatching: statesDir=\(statesDir.path)")
        // Actual watching starts when watchProject is called
    }

    func stopWatching() {
        scanTimer?.invalidate()
        scanTimer = nil
        dirMonitor?.cancel()
        dirMonitor = nil
        fileMonitor?.cancel()
        fileMonitor = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func log(_ msg: String) {
        print("[StateWatcher] \(msg)")
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".terminaut/watcher.log")
        let line = "\(Date()): \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func watchFile(_ url: URL) {
        log("watchFile: \(url.lastPathComponent)")
        // Stop watching old file
        fileMonitor?.cancel()
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }

        currentStateFile = url

        // Read immediately
        readState(from: url)

        // Start polling timer as fallback (file watcher can be unreliable with atomic writes)
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, let url = self.currentStateFile else { return }
            self.readState(from: url)
        }

        // Also watch for changes (faster than polling when it works)
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        fileMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )

        fileMonitor?.setEventHandler { [weak self] in
            guard let self = self, let url = self.currentStateFile else { return }
            let events = self.fileMonitor?.data ?? []

            // If file was renamed/deleted (atomic write), re-watch it
            if events.contains(.rename) || events.contains(.delete) {
                self.log("File replaced (atomic write), re-watching...")
                // Small delay to let the mv complete
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.watchFile(url)
                }
            } else {
                self.readState(from: url)
            }
        }

        fileMonitor?.setCancelHandler { [weak self] in
            guard let fd = self?.fileDescriptor, fd >= 0 else { return }
            close(fd)
            self?.fileDescriptor = -1
        }

        fileMonitor?.resume()
    }

    private func readState(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let newState = try decoder.decode(SessionState.self, from: data)
            log("readState: contextPercent=\(newState.contextPercent ?? -1), quotaPercent=\(newState.quotaPercent ?? -1), todos=\(newState.todos?.count ?? 0), prs=\(newState.openPRs?.count ?? 0)")
            DispatchQueue.main.async {
                self.state = newState
            }
        } catch {
            log("readState error: \(error)")
        }
    }
}
