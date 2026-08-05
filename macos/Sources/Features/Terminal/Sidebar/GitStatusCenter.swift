import Foundation
import Combine

/// Async git/GitHub enrichment for sidebar tabs, keyed by repository
/// root: whether the worktree has uncommitted changes, and the open
/// pull request for the current branch (via the `gh` CLI when present).
///
/// Everything runs off the main thread with per-repo TTLs so the
/// sidebar refresh loop never blocks on subprocesses.
@MainActor
final class GitStatusCenter: ObservableObject {
    static let shared = GitStatusCenter()

    struct RepoInfo: Equatable {
        var isDirty: Bool?
        var prNumber: Int?
        var prURL: String?

        var dirtyCheckedAt: Date = .distantPast
        var prCheckedAt: Date = .distantPast
        var prBranch: String?
    }

    @Published private(set) var repos: [String: RepoInfo] = [:]

    private var inflight: Set<String> = []

    private static let dirtyTTL: TimeInterval = 15
    private static let prTTL: TimeInterval = 300

    func info(forRoot root: String?) -> RepoInfo? {
        root.flatMap { repos[$0] }
    }

    /// Refreshes stale data for a repo in the background; cheap no-op
    /// while fresh or already in flight.
    func requestRefresh(root: String, branch: String?) {
        let now = Date()
        let info = repos[root] ?? RepoInfo()
        let needsDirty = now.timeIntervalSince(info.dirtyCheckedAt) > Self.dirtyTTL
        let needsPR = now.timeIntervalSince(info.prCheckedAt) > Self.prTTL
            || info.prBranch != branch

        guard needsDirty || needsPR, !inflight.contains(root) else { return }
        inflight.insert(root)

        Task.detached(priority: .utility) {
            let dirty = needsDirty ? Self.checkDirty(root: root) : nil
            let pr = needsPR ? Self.checkPullRequest(root: root) : nil

            await MainActor.run { [weak self] in
                guard let self else { return }
                var info = self.repos[root] ?? RepoInfo()
                if needsDirty {
                    info.isDirty = dirty
                    info.dirtyCheckedAt = Date()
                }
                if needsPR {
                    info.prNumber = pr?.number
                    info.prURL = pr?.url
                    info.prCheckedAt = Date()
                    info.prBranch = branch
                }
                self.repos[root] = info
                self.inflight.remove(root)
            }
        }
    }

    // MARK: Subprocess checks

    nonisolated private static func checkDirty(root: String) -> Bool? {
        guard let output = run(
            "/usr/bin/git",
            ["-C", root, "status", "--porcelain", "--untracked-files=no"],
            timeout: 5
        ) else { return nil }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated private static let ghPath: String? = {
        for candidate in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }()

    nonisolated private static func checkPullRequest(root: String) -> (number: Int, url: String)? {
        guard let gh = ghPath else { return nil }
        guard let output = run(
            gh,
            ["pr", "view", "--json", "number,url,state"],
            cwd: root,
            timeout: 10
        ) else { return nil }

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = json["number"] as? Int,
              let url = json["url"] as? String,
              (json["state"] as? String) == "OPEN"
        else { return nil }

        return (number, url)
    }

    nonisolated private static func run(
        _ launchPath: String,
        _ arguments: [String],
        cwd: String? = nil,
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
