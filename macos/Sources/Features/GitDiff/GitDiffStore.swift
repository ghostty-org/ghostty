import AppKit
import Foundation

struct GitDiffEntry: Identifiable, Hashable {
    let path: String
    let statusCode: String
    let kind: GitDiffKind
    let originalPath: String?
    let indexStatus: Character
    let workingStatus: Character
    let stagedAdditions: Int
    let stagedDeletions: Int
    let unstagedAdditions: Int
    let unstagedDeletions: Int

    var id: String { path }

    var additions: Int { stagedAdditions + unstagedAdditions }
    var deletions: Int { stagedDeletions + unstagedDeletions }

    var hasStagedChanges: Bool {
        indexStatus != " " && indexStatus != "?"
    }

    var hasUnstagedChanges: Bool {
        workingStatus != " "
    }

    var displayPath: String {
        if let originalPath, !originalPath.isEmpty {
            return "\(path) ← \(originalPath)"
        }
        return path
    }

    func kind(for scope: GitDiffScope) -> GitDiffKind {
        switch scope {
        case .all:
            return kind
        case .staged:
            return GitDiffEntry.kindFrom(status: indexStatus)
        case .unstaged:
            return GitDiffEntry.kindFrom(status: workingStatus)
        }
    }

    func stats(for scope: GitDiffScope) -> (Int, Int) {
        switch scope {
        case .all:
            return (additions, deletions)
        case .staged:
            return (stagedAdditions, stagedDeletions)
        case .unstaged:
            return (unstagedAdditions, unstagedDeletions)
        }
    }

    private static func kindFrom(status: Character?) -> GitDiffKind {
        guard let status else { return .unknown }
        if status == "U" { return .conflicted }
        if status == "A" { return .added }
        if status == "D" { return .deleted }
        if status == "R" { return .renamed }
        if status == "C" { return .copied }
        if status == "M" { return .modified }
        if status == "?" { return .untracked }
        return .unknown
    }
}

enum GitDiffKind: String, Hashable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case untracked
    case conflicted
    case unknown
}

enum GitDiffScope: String, Hashable, CaseIterable, Codable {
    case all
    case staged
    case unstaged

    var label: String {
        switch self {
        case .all: return "All"
        case .staged: return "Staged"
        case .unstaged: return "Unstaged"
        }
    }
}

final class GitDiffStore {
    struct GitInvocation {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
    }

    struct CommandResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    func repoRoot(for cwd: String) async -> String? {
        do {
            let result = try await runGit(["-C", cwd, "rev-parse", "--show-toplevel"])
            guard result.exitCode == 0 else { return nil }
            let root = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return root.isEmpty ? nil : root
        } catch {
            return nil
        }
    }

    func currentBranch(repoRoot: String) async -> String? {
        do {
            let result = try await runGit(["-C", repoRoot, "rev-parse", "--abbrev-ref", "HEAD"])
            guard result.exitCode == 0 else { return nil }
            let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if branch.isEmpty || branch == "HEAD" { return nil }
            return branch
        } catch {
            return nil
        }
    }

    func statusEntries(repoRoot: String) async throws -> [GitDiffEntry] {
        let result = try await runGit([
            "--no-optional-locks",
            "-C",
            repoRoot,
            "status",
            "--porcelain=v1",
            "-b",
            "-z",
            "-M",
            "-unormal",
        ])
        guard result.exitCode == 0 else {
            throw GitDiffError.commandFailed(result.stderr)
        }
        return parseStatusV1(result.stdout)
    }

    func diffCommand(for entry: GitDiffEntry, scope: GitDiffScope) -> String {
        let escaped = entry.path.shellEscaped
        if entry.kind == .untracked {
            return "git -c color.ui=always -c core.quotePath=false diff --no-index -- /dev/null \(escaped)"
        }
        switch scope {
        case .all:
            return "git -c color.ui=always -c core.quotePath=false diff HEAD -- \(escaped)"
        case .staged:
            return "git -c color.ui=always -c core.quotePath=false diff --cached -- \(escaped)"
        case .unstaged:
            return "git -c color.ui=always -c core.quotePath=false diff -- \(escaped)"
        }
    }

    func diffText(repoRoot: String, entry: GitDiffEntry, scope: GitDiffScope) async throws -> String {
        let args = ["-C", repoRoot, "-c", "color.ui=never", "-c", "core.quotePath=false"] + diffArguments(entry: entry, scope: scope)
        let result = try await runGit(args)
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw GitDiffError.commandFailed(result.stderr)
        }
        return result.stdout
    }

    func unifiedDiffText(repoRoot: String, scope: GitDiffScope, entries: [GitDiffEntry]) async throws -> String {
        let args = ["-C", repoRoot, "-c", "color.ui=never", "-c", "core.quotePath=false"] + unifiedDiffArguments(scope: scope)
        let result = try await runGit(args)
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw GitDiffError.commandFailed(result.stderr)
        }

        var chunks: [String] = []
        chunks.reserveCapacity(1 + 8)
        if !result.stdout.isEmpty {
            chunks.append(result.stdout)
        }

        if scope != .staged {
            let untracked = entries.filter { $0.kind == .untracked }
            let maxUntrackedDiffs = 25
            let maxUntrackedPlaceholders = 200

            for entry in untracked.prefix(maxUntrackedDiffs) {
                if let text = try await untrackedDiffText(repoRoot: repoRoot, path: entry.path) {
                    if !text.isEmpty {
                        chunks.append(text)
                    }
                } else {
                    chunks.append(untrackedPlaceholderDiff(path: entry.path, message: "Untracked path is a directory, diff not shown."))
                }
            }

            if untracked.count > maxUntrackedDiffs {
                let omitted = untracked.dropFirst(maxUntrackedDiffs)
                for entry in omitted.prefix(maxUntrackedPlaceholders) {
                    chunks.append(untrackedPlaceholderDiff(path: entry.path, message: "Untracked diff omitted for performance (too many untracked files)."))
                }
                let remaining = omitted.count - min(omitted.count, maxUntrackedPlaceholders)
                if remaining > 0 {
                    chunks.append(untrackedPlaceholderDiff(
                        path: ".gitdiff/omitted_untracked",
                        message: "Omitted diffs for \(remaining) additional untracked file(s)."
                    ))
                }
            }
        }

        if chunks.isEmpty { return "" }

        return chunks
            .map { $0.hasSuffix("\n") ? $0 : ($0 + "\n") }
            .joined(separator: "\n")
    }

    private func untrackedPlaceholderDiff(path: String, message: String) -> String {
        """
        diff --git a/\(path) b/\(path)
        new file mode 100644
        --- /dev/null
        +++ b/\(path)
        # \(message)

        """
    }

    private func runGit(_ args: [String]) async throws -> CommandResult {
        guard let invocation = try? makeGitInvocation(args: args) else {
            throw GitDiffError.commandFailed("git not found")
        }
        return try await Task.detached(priority: .userInitiated) {
            try GitDiffStore.runGitInvocation(invocation)
        }.value
    }

    private static func runGitInvocation(_ invocation: GitInvocation) throws -> CommandResult {
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment

        let stdinPipe = Pipe()
        stdinPipe.fileHandleForWriting.closeFile()
        process.standardInput = stdinPipe

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return CommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    private func makeGitInvocation(args: [String]) throws -> GitInvocation {
        var env = ProcessInfo.processInfo.environment
        let prefix = ["/opt/homebrew/bin", "/usr/local/bin"]
        let existingPath = env["PATH"] ?? ""
        if existingPath.isEmpty {
            env["PATH"] = prefix.joined(separator: ":")
        } else {
            let existingComponents = Set(existingPath.split(separator: ":").map(String.init))
            let missingPaths = prefix.filter { !existingComponents.contains($0) }
            if !missingPaths.isEmpty {
                env["PATH"] = (missingPaths + [existingPath]).joined(separator: ":")
            }
        }

        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return GitInvocation(
                    executableURL: URL(fileURLWithPath: path),
                    arguments: args,
                    environment: env
                )
            }
        }

        let envURL = URL(fileURLWithPath: "/usr/bin/env")
        guard FileManager.default.isExecutableFile(atPath: envURL.path) else {
            throw GitDiffError.commandFailed("git not found")
        }

        return GitInvocation(
            executableURL: envURL,
            arguments: ["git"] + args,
            environment: env
        )
    }

    private func parseStatusV1(_ output: String) -> [GitDiffEntry] {
        var entries: [GitDiffEntry] = []
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true)
        var index = 0
        while index < tokens.count {
            let header = String(tokens[index])
            if header.hasPrefix("## ") {
                index += 1
                continue
            }
            if header.count < 3 {
                index += 1
                continue
            }

            let indexStatus = header[header.startIndex]
            let workingStatus = header[header.index(after: header.startIndex)]
            let statusCode = String(header.prefix(2))
            let pathStart = header.index(header.startIndex, offsetBy: 3)
            let path = String(header[pathStart...])

            if indexStatus == "?" && workingStatus == "?" {
                entries.append(GitDiffEntry(
                    path: path,
                    statusCode: "??",
                    kind: .untracked,
                    originalPath: nil,
                    indexStatus: indexStatus,
                    workingStatus: workingStatus,
                    stagedAdditions: 0,
                    stagedDeletions: 0,
                    unstagedAdditions: 0,
                    unstagedDeletions: 0
                ))
                index += 1
                continue
            }

            let isRenameOrCopy = indexStatus == "R" || indexStatus == "C" || workingStatus == "R" || workingStatus == "C"
            if isRenameOrCopy && (index + 1) < tokens.count {
                let newPath = String(tokens[index + 1])
                let kind = kindFrom(x: indexStatus, y: workingStatus)
                entries.append(GitDiffEntry(
                    path: newPath,
                    statusCode: statusCode,
                    kind: kind,
                    originalPath: path,
                    indexStatus: indexStatus,
                    workingStatus: workingStatus,
                    stagedAdditions: 0,
                    stagedDeletions: 0,
                    unstagedAdditions: 0,
                    unstagedDeletions: 0
                ))
                index += 2
                continue
            }

            let kind = kindFrom(x: indexStatus, y: workingStatus)
            entries.append(GitDiffEntry(
                path: path,
                statusCode: statusCode,
                kind: kind,
                originalPath: nil,
                indexStatus: indexStatus,
                workingStatus: workingStatus,
                stagedAdditions: 0,
                stagedDeletions: 0,
                unstagedAdditions: 0,
                unstagedDeletions: 0
            ))
            index += 1
        }
        return entries
    }

    private func kindFrom(x: Character?, y: Character?) -> GitDiffKind {
        if x == "U" || y == "U" { return .conflicted }
        if x == "A" || y == "A" { return .added }
        if x == "D" || y == "D" { return .deleted }
        if x == "R" || y == "R" { return .renamed }
        if x == "C" || y == "C" { return .copied }
        if x == "M" || y == "M" { return .modified }
        if x == "?" || y == "?" { return .untracked }
        return .unknown
    }

    private func diffArguments(entry: GitDiffEntry, scope: GitDiffScope) -> [String] {
        if entry.kind == .untracked {
            return ["diff", "--no-index", "--", "/dev/null", entry.path]
        }
        switch scope {
        case .all:
            return ["diff", "HEAD", "--", entry.path]
        case .staged:
            return ["diff", "--cached", "--", entry.path]
        case .unstaged:
            return ["diff", "--", entry.path]
        }
    }

    private func unifiedDiffArguments(scope: GitDiffScope) -> [String] {
        switch scope {
        case .all:
            return ["diff", "HEAD", "-M"]
        case .staged:
            return ["diff", "--cached", "-M"]
        case .unstaged:
            return ["diff", "-M"]
        }
    }

    private func untrackedDiffText(repoRoot: String, path: String) async throws -> String? {
        let url = URL(fileURLWithPath: repoRoot).appendingPathComponent(path)

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return nil
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber,
           size.int64Value > 1_000_000 {
            return """
            diff --git a/\(path) b/\(path)
            new file mode 100644
            --- /dev/null
            +++ b/\(path)
            # File too large to render (\(size.int64Value) bytes)

            """
        }

        let result = try await runGit(["-C", repoRoot, "-c", "color.ui=never", "-c", "core.quotePath=false", "diff", "--no-index", "--", "/dev/null", path])
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw GitDiffError.commandFailed(result.stderr)
        }
        return result.stdout
    }

    func stage(repoRoot: String, path: String) async throws {
        let result = try await runGit(["-C", repoRoot, "add", "--", path])
        guard result.exitCode == 0 else {
            throw GitDiffError.commandFailed(result.stderr)
        }
    }

    func unstage(repoRoot: String, path: String) async throws {
        let result = try await runGit(["-C", repoRoot, "restore", "--staged", "--", path])
        guard result.exitCode == 0 else {
            throw GitDiffError.commandFailed(result.stderr)
        }
    }

}

enum GitDiffError: Error {
    case commandFailed(String)
}
