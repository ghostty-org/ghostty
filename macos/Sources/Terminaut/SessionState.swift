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

/// Watches the state file and publishes updates
class SessionStateWatcher: ObservableObject {
    @Published var state: SessionState = .empty

    private let stateURL: URL
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        stateURL = home.appendingPathComponent(".terminaut/state.json")
        startWatching()
    }

    deinit {
        stopWatching()
    }

    func startWatching() {
        // Initial read
        readState()

        // Create directory if needed
        let dir = stateURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Create empty file if needed
        if !FileManager.default.fileExists(atPath: stateURL.path) {
            FileManager.default.createFile(atPath: stateURL.path, contents: "{}".data(using: .utf8))
        }

        // Open file for monitoring
        fileDescriptor = open(stateURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            print("Failed to open state file for monitoring")
            return
        }

        // Create dispatch source for file changes
        fileMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib],
            queue: .main
        )

        fileMonitor?.setEventHandler { [weak self] in
            self?.readState()
        }

        fileMonitor?.setCancelHandler { [weak self] in
            guard let fd = self?.fileDescriptor, fd >= 0 else { return }
            close(fd)
            self?.fileDescriptor = -1
        }

        fileMonitor?.resume()
    }

    func stopWatching() {
        fileMonitor?.cancel()
        fileMonitor = nil
    }

    private func readState() {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }

        do {
            let data = try Data(contentsOf: stateURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let newState = try decoder.decode(SessionState.self, from: data)
            DispatchQueue.main.async {
                self.state = newState
            }
        } catch {
            // State file may be empty or malformed during writes
            // This is expected, just ignore
        }
    }
}
