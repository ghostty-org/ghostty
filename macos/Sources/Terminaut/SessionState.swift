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
    var timestamp: Date?
    var context: ContextBreakdown?

    struct TodoItem: Codable, Identifiable {
        var id: String { content }
        let content: String
        let status: String
        let activeForm: String?
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
        startWatching()
    }

    deinit {
        stopWatching()
    }

    /// Set the project path to watch for
    func watchProject(path: String) {
        projectPath = path
        findAndWatchStateFile()
    }

    func startWatching() {
        // Create directory if needed
        try? FileManager.default.createDirectory(at: statesDir, withIntermediateDirectories: true)

        // Watch the directory for new files
        dirDescriptor = open(statesDir.path, O_EVTONLY)
        guard dirDescriptor >= 0 else {
            print("Failed to open states directory for monitoring")
            return
        }

        dirMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirDescriptor,
            eventMask: [.write],
            queue: .main
        )

        dirMonitor?.setEventHandler { [weak self] in
            self?.findAndWatchStateFile()
        }

        dirMonitor?.setCancelHandler { [weak self] in
            guard let fd = self?.dirDescriptor, fd >= 0 else { return }
            close(fd)
            self?.dirDescriptor = -1
        }

        dirMonitor?.resume()

        // Also scan periodically in case we miss events
        scanTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.findAndWatchStateFile()
        }

        // Initial scan
        findAndWatchStateFile()
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

    private func findAndWatchStateFile() {
        guard !projectPath.isEmpty else { return }

        // Expand ~ in project path for comparison
        let expandedProjectPath = projectPath.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)

        // Scan all state files to find one matching our project
        guard let files = try? FileManager.default.contentsOfDirectory(at: statesDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }

        var bestMatch: (url: URL, date: Date)? = nil

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = json["cwd"] as? String else { continue }

            // Expand ~ in cwd for comparison
            let expandedCwd = cwd.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)

            // Check if this state file matches our project
            if expandedCwd == expandedProjectPath || expandedCwd.hasPrefix(expandedProjectPath + "/") || expandedProjectPath.hasPrefix(expandedCwd + "/") {
                let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                if bestMatch == nil || modDate > bestMatch!.date {
                    bestMatch = (file, modDate)
                }
            }
        }

        // If we found a matching file, watch it
        if let match = bestMatch, match.url != currentStateFile {
            watchFile(match.url)
        }
    }

    private func watchFile(_ url: URL) {
        // Stop watching old file
        fileMonitor?.cancel()
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }

        currentStateFile = url

        // Read immediately
        readState(from: url)

        // Watch for changes
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        fileMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib],
            queue: .main
        )

        fileMonitor?.setEventHandler { [weak self] in
            guard let self = self, let url = self.currentStateFile else { return }
            self.readState(from: url)
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
            DispatchQueue.main.async {
                self.state = newState
            }
        } catch {
            // State file may be empty or malformed during writes
        }
    }
}
