import Foundation
import OSLog

#if os(macOS)

struct Worktree: Equatable {
    let path: URL
    let branch: String?
    let isMain: Bool
    let isDetached: Bool
}

func repoRoot(forCwd cwd: URL) async -> URL? {
    await GitWorktreeModel().repoRoot(forCwd: cwd)
}

func worktrees(forCwd cwd: URL) async -> [Worktree] {
    await GitWorktreeModel().worktrees(forCwd: cwd)
}

struct GitWorktreeModel {
    var runner: GitCommandRunning = GitProcessRunner()
    var timeout: TimeInterval = 2

    func repoRoot(forCwd cwd: URL) async -> URL? {
        let result = await runner.runGit(
            arguments: ["rev-parse", "--git-common-dir"],
            cwd: cwd,
            timeout: timeout
        )

        guard case .success(let output) = result else {
            logFailure(result, command: "rev-parse --git-common-dir", cwd: cwd)
            return nil
        }

        guard let firstLine = output.lines.first, !firstLine.isEmpty else {
            logger.warning("git rev-parse --git-common-dir returned no path for \(cwd.path, privacy: .public)")
            return nil
        }

        let commonDir = absoluteURL(forGitPath: firstLine, relativeTo: cwd)
        return worktreeRoot(fromCommonGitDir: commonDir)
    }

    func worktrees(forCwd cwd: URL) async -> [Worktree] {
        guard let root = await repoRoot(forCwd: cwd) else { return [] }

        let result = await runner.runGit(
            arguments: ["worktree", "list", "--porcelain"],
            cwd: root,
            timeout: timeout
        )

        guard case .success(let output) = result else {
            logFailure(result, command: "worktree list --porcelain", cwd: root)
            return []
        }

        return WorktreePorcelainParser.parse(output, mainRoot: root)
    }

    func createWorktree(branchName rawBranchName: String, forCwd cwd: URL) async -> Result<URL, GitWorktreeCreationError> {
        let branchName = rawBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branchName.isEmpty else {
            return .failure(.init(message: "Enter a branch name."))
        }

        guard let root = await repoRoot(forCwd: cwd) else {
            return .failure(.init(message: "Not a git repository."))
        }

        let path = Self.defaultNewWorktreePath(repoRoot: root, branchName: branchName)
        let result = await runner.runGit(
            arguments: ["worktree", "add", "-b", branchName, path.path],
            cwd: root,
            timeout: timeout
        )

        switch result {
        case .success:
            return .success(path)
        case .failure(let status, let stderr):
            logFailure(result, command: "worktree add", cwd: root)
            let detail = stderr.isEmpty ? "git worktree add failed with status \(status)." : stderr
            return .failure(.init(message: detail))
        case .timedOut:
            logFailure(result, command: "worktree add", cwd: root)
            return .failure(.init(message: "git worktree add timed out."))
        case .launchFailed(let message):
            logFailure(result, command: "worktree add", cwd: root)
            return .failure(.init(message: "Could not launch git: \(message)"))
        }
    }

    static func defaultNewWorktreePath(repoRoot: URL, branchName: String) -> URL {
        let repoName = repoRoot.lastPathComponent
        let branchComponent = pathComponent(forBranchName: branchName)
        return repoRoot
            .deletingLastPathComponent()
            .appendingPathComponent("\(repoName)-\(branchComponent)")
            .standardizedFileURL
    }

    private func logFailure(_ result: GitCommandResult, command: String, cwd: URL) {
        switch result {
        case .success:
            break
        case .failure(let status, let stderr):
            logger.warning(
                "git \(command, privacy: .public) failed in \(cwd.path, privacy: .public): status \(status), \(stderr, privacy: .public)"
            )
        case .timedOut:
            logger.warning("git \(command, privacy: .public) timed out in \(cwd.path, privacy: .public)")
        case .launchFailed(let message):
            logger.warning(
                "git \(command, privacy: .public) could not launch in \(cwd.path, privacy: .public): \(message, privacy: .public)"
            )
        }
    }
}

struct GitWorktreeCreationError: Error, Equatable {
    let message: String
}

protocol GitCommandRunning {
    func runGit(arguments: [String], cwd: URL, timeout: TimeInterval) async -> GitCommandResult
}

enum GitCommandResult: Equatable {
    case success(String)
    case failure(status: Int32, stderr: String)
    case timedOut
    case launchFailed(String)
}

struct GitProcessRunner: GitCommandRunning {
    func runGit(arguments: [String], cwd: URL, timeout: TimeInterval) async -> GitCommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runGitSynchronously(arguments: arguments, cwd: cwd, timeout: timeout))
            }
        }
    }
}

private func runGitSynchronously(arguments: [String], cwd: URL, timeout: TimeInterval) -> GitCommandResult {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    let semaphore = DispatchSemaphore(value: 0)

    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", cwd.path] + arguments
    process.standardOutput = stdout
    process.standardError = stderr

    do {
        try process.run()
    } catch {
        return .launchFailed(error.localizedDescription)
    }

    let stdoutDrain = PipeDrain(stdout.fileHandleForReading)
    let stderrDrain = PipeDrain(stderr.fileHandleForReading)

    DispatchQueue.global(qos: .utility).async {
        process.waitUntilExit()
        semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        _ = semaphore.wait(timeout: .now() + 1)
        stdoutDrain.wait(timeout: .now() + 1)
        stderrDrain.wait(timeout: .now() + 1)
        return .timedOut
    }

    let output = String(data: stdoutDrain.data(), encoding: .utf8) ?? ""
    let error = String(data: stderrDrain.data(), encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        return .failure(status: process.terminationStatus, stderr: error.trimmedGitOutput)
    }

    return .success(output.trimmedGitOutput)
}

private struct WorktreePorcelainParser {
    static func parse(_ output: String, mainRoot: URL) -> [Worktree] {
        let blocks = output
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let mainPath = normalizedPath(mainRoot)

        let parsed = blocks.compactMap { block -> Worktree? in
            parseBlock(block, mainPath: mainPath)
        }

        let linked = parsed
            .filter { !$0.isMain }
            .sorted {
                if $0.isDetached != $1.isDetached {
                    return !$0.isDetached
                }

                return sortKey($0) < sortKey($1)
            }

        return parsed.filter(\.isMain) + linked
    }

    private static func parseBlock(_ block: String, mainPath: String) -> Worktree? {
        var path: URL?
        var branch: String?
        var isDetached = false

        for line in block.lines {
            if line.hasPrefix("worktree ") {
                path = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("branch ") {
                branch = branchName(fromRef: String(line.dropFirst("branch ".count)))
            } else if line == "detached" {
                isDetached = true
            }
        }

        guard let path else { return nil }

        if branch == nil && isDetached {
            branch = path.lastPathComponent
        }

        return Worktree(
            path: path,
            branch: branch,
            isMain: normalizedPath(path) == mainPath,
            isDetached: isDetached
        )
    }

    private static func branchName(fromRef ref: String) -> String {
        let prefix = "refs/heads/"
        guard ref.hasPrefix(prefix) else { return ref }
        return String(ref.dropFirst(prefix.count))
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func sortKey(_ worktree: Worktree) -> String {
        worktree.branch ?? worktree.path.lastPathComponent
    }
}

private final class PipeDrain {
    private let group = DispatchGroup()
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.git-pipe-drain")
    private var bufferedData = Data()

    init(_ fileHandle: FileHandle) {
        group.enter()

        DispatchQueue.global(qos: .utility).async { [self] in
            let data = fileHandle.readDataToEndOfFile()

            self.queue.sync {
                self.bufferedData = data
            }

            self.group.leave()
        }
    }

    func data() -> Data {
        group.wait()
        return queue.sync { bufferedData }
    }

    func wait(timeout: DispatchTime) {
        _ = group.wait(timeout: timeout)
    }
}

private func absoluteURL(forGitPath path: String, relativeTo cwd: URL) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    return cwd.appendingPathComponent(path).standardizedFileURL
}

private func worktreeRoot(fromCommonGitDir commonDir: URL) -> URL {
    if commonDir.lastPathComponent == ".git" {
        return commonDir.deletingLastPathComponent().standardizedFileURL
    }

    return commonDir.standardizedFileURL
}

private func pathComponent(forBranchName branchName: String) -> String {
    let separators = CharacterSet(charactersIn: "/:")
    let pieces = branchName
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: separators)
        .filter { !$0.isEmpty }
    return pieces.isEmpty ? "worktree" : pieces.joined(separator: "-")
}

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
    category: "worktrees"
)

private extension String {
    var trimmedGitOutput: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var lines: [String] {
        split(whereSeparator: \.isNewline).map(String.init)
    }
}

#endif
