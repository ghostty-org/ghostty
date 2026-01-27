import AppKit
import Foundation

struct GitDiffEntry: Identifiable, Hashable {
    let path: String
    let statusCode: String
    let kind: GitDiffKind
    let originalPath: String?
    let additions: Int
    let deletions: Int

    var id: String { path }

    var displayPath: String {
        if let originalPath, !originalPath.isEmpty {
            return "\(path) ← \(originalPath)"
        }
        return path
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
            "-uall",
        ])
        guard result.exitCode == 0 else {
            throw GitDiffError.commandFailed(result.stderr)
        }
        let entries = parseStatusV1(result.stdout)
        return await enrichWithStats(repoRoot: repoRoot, entries: entries)
    }

    func diffCommand(for entry: GitDiffEntry) -> String {
        let escaped = entry.path.shellEscaped
        if entry.kind == .untracked {
            return "git -c color.ui=always diff --no-index -- /dev/null \(escaped)"
        }
        return "git -c color.ui=always diff -- \(escaped)"
    }

    func diffText(repoRoot: String, entry: GitDiffEntry) async throws -> String {
        let args: [String]
        if entry.kind == .untracked {
            args = ["-C", repoRoot, "-c", "color.ui=never", "diff", "--no-index", "--", "/dev/null", entry.path]
        } else {
            args = ["-C", repoRoot, "-c", "color.ui=never", "diff", "--", entry.path]
        }
        let result = try await runGit(args)
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw GitDiffError.commandFailed(result.stderr)
        }
        return result.stdout
    }

    private func runGit(_ args: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let invocation = try? makeGitInvocation(args: args)
            guard let invocation else {
                continuation.resume(throwing: GitDiffError.commandFailed("git not found"))
                return
            }
            let process = Process()
            process.executableURL = invocation.executableURL
            process.arguments = invocation.arguments
            process.environment = invocation.environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { process in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(returning: CommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
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
                entries.append(GitDiffEntry(path: path, statusCode: "??", kind: .untracked, originalPath: nil, additions: 0, deletions: 0))
                index += 1
                continue
            }

            let isRenameOrCopy = indexStatus == "R" || indexStatus == "C" || workingStatus == "R" || workingStatus == "C"
            if isRenameOrCopy && (index + 1) < tokens.count {
                let newPath = String(tokens[index + 1])
                let kind = kindFrom(x: indexStatus, y: workingStatus)
                entries.append(GitDiffEntry(path: newPath, statusCode: statusCode, kind: kind, originalPath: path, additions: 0, deletions: 0))
                index += 2
                continue
            }

            let kind = kindFrom(x: indexStatus, y: workingStatus)
            entries.append(GitDiffEntry(path: path, statusCode: statusCode, kind: kind, originalPath: nil, additions: 0, deletions: 0))
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

    private func enrichWithStats(repoRoot: String, entries: [GitDiffEntry]) async -> [GitDiffEntry] {
        let (unstagedMap, stagedMap) = await (
            fetchNumstatMap(repoRoot: repoRoot, args: ["diff", "--numstat"]),
            fetchNumstatMap(repoRoot: repoRoot, args: ["diff", "--cached", "--numstat"])
        )

        var result: [GitDiffEntry] = []
        for entry in entries {
            if entry.kind == .untracked {
                let adds = countUntrackedAdditions(repoRoot: repoRoot, path: entry.path)
                result.append(GitDiffEntry(
                    path: entry.path,
                    statusCode: entry.statusCode,
                    kind: entry.kind,
                    originalPath: entry.originalPath,
                    additions: adds,
                    deletions: 0
                ))
                continue
            }
            let (uAdd, uDel) = unstagedMap[entry.path] ?? (0, 0)
            let (sAdd, sDel) = stagedMap[entry.path] ?? (0, 0)
            result.append(GitDiffEntry(
                path: entry.path,
                statusCode: entry.statusCode,
                kind: entry.kind,
                originalPath: entry.originalPath,
                additions: uAdd + sAdd,
                deletions: uDel + sDel
            ))
        }
        return result
    }

    private func fetchNumstatMap(repoRoot: String, args: [String]) async -> [String: (Int, Int)] {
        guard let result = try? await runGit(["-C", repoRoot] + args) else { return [:] }
        guard result.exitCode == 0 else { return [:] }
        return parseNumstatMap(result.stdout)
    }

    private func parseNumstatMap(_ output: String) -> [String: (Int, Int)] {
        var map: [String: (Int, Int)] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count < 3 { continue }
            let addStr = String(parts[0])
            let delStr = String(parts[1])
            let path = String(parts[2])
            let adds = addStr == "-" ? 0 : (Int(addStr) ?? 0)
            let dels = delStr == "-" ? 0 : (Int(delStr) ?? 0)
            map[path] = (adds, dels)
        }
        return map
    }

    private func countUntrackedAdditions(repoRoot: String, path: String) -> Int {
        let url = URL(fileURLWithPath: repoRoot).appendingPathComponent(path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        if size.int64Value > 1_000_000 { return 0 }
        if let data = try? Data(contentsOf: url),
           let content = String(data: data, encoding: .utf8) {
            return content.split(separator: "\n", omittingEmptySubsequences: false).count
        }
        return 0
    }
}

enum GitDiffError: Error {
    case commandFailed(String)
}
