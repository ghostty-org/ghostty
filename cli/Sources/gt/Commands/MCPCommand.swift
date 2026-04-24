import ArgumentParser
import Foundation
import GhosttiesCore

// MARK: - Parent command

/// `gt mcp` — manage how external agents (Claude Code, etc.) reach Ghostties'
/// MCP server. The Phase 5 agent-as-middleman flow assumes the user's coding
/// agent has Ghostties registered; this command group is the one-step wiring
/// that replaces hand-editing JSON config.
struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Register Ghostties' MCP server with external agents.",
        subcommands: [InstallCommand.self]
    )
}

// MARK: - Targets

/// Coding-agent targets we know how to wire. Only `claude-code` is implemented
/// today; the rest are stubs that emit a friendly "not yet" message so the
/// surface is forward-compatible with Codex / Cursor / aider work.
enum MCPInstallTarget: String, ExpressibleByArgument, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case cursor
    case aider

    static var allValueStrings: [String] { allCases.map(\.rawValue) }
}

/// Where to register the server. Only used for the `claude-code` target;
/// passes through to `claude mcp add --scope <…>`.
enum MCPInstallScope: String, ExpressibleByArgument, CaseIterable {
    case user
    case project
    case local
}

// MARK: - Install subcommand

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Register the Ghostties MCP server with the target agent (default: claude-code)."
    )

    @Option(name: .long, help: "Target agent: claude-code (default), codex, cursor, aider.")
    var target: MCPInstallTarget = .claudeCode

    @Option(name: .long, help: "Scope: user (default), project, or local.")
    var scope: MCPInstallScope = .user

    @Flag(name: .long, help: "Overwrite an existing entry with the same name.")
    var force: Bool = false

    @Flag(name: .long, help: "Print what would happen without modifying anything.")
    var dryRun: Bool = false

    @Option(name: .long, help: "Override the ghostties-mcp binary path. Useful in dev.")
    var binary: String?

    /// Server name registered with the agent. Hard-coded so a re-run finds
    /// the existing entry and stays idempotent.
    static let serverName = "ghostties"

    func run() throws {
        switch target {
        case .claudeCode:
            try installClaudeCode()
        case .codex, .cursor, .aider:
            throw CLIError.usage("\(target.rawValue) target not yet implemented; PRs welcome. Only --target claude-code is supported today.")
        }
    }

    // MARK: - Claude Code

    private func installClaudeCode() throws {
        // 1. Find the binary we'll point Claude Code at.
        let binaryPath = try resolveBinaryPath()

        // 2. Make sure the `claude` CLI is on PATH — that's how we delegate
        //    the actual JSON write so we don't have to know where Claude Code
        //    keeps its config.
        guard let claudeCLI = which("claude") else {
            throw CLIError.io("`claude` CLI not found on PATH. Install Claude Code first (https://docs.claude.com/claude-code) or use --target codex once it ships.")
        }

        // 3. Idempotency check: ask claude what's already registered.
        let existing = currentClaudeCodeEntry(claudeCLI: claudeCLI)

        if let existing {
            if existing == binaryPath {
                print("ghostties already registered with Claude Code → \(binaryPath)")
                return
            }
            if !force {
                FileHandle.standardError.write(Data("error: ghostties is already registered with Claude Code, but it points at a different command:\n  current: \(existing)\n  desired: \(binaryPath)\nRe-run with --force to overwrite.\n".utf8))
                throw ExitCode(1)
            }
            // Force path: remove the stale entry first so `add` won't refuse.
            if dryRun {
                print("[dry-run] would run: \(claudeCLI) mcp remove \(Self.serverName) --scope \(scope.rawValue)")
            } else {
                _ = runProcess(claudeCLI, args: ["mcp", "remove", Self.serverName, "--scope", scope.rawValue])
            }
        }

        // 4. Add the entry. `claude mcp add <name> -- <command>` is the
        //    documented shape for stdio servers.
        let addArgs: [String] = [
            "mcp", "add",
            "--scope", scope.rawValue,
            "--transport", "stdio",
            Self.serverName,
            "--", binaryPath
        ]

        if dryRun {
            print("[dry-run] would run: \(claudeCLI) \(addArgs.joined(separator: " "))")
            print("[dry-run] target = claude-code · scope = \(scope.rawValue) · binary = \(binaryPath)")
            return
        }

        let result = runProcess(claudeCLI, args: addArgs)
        if result.exitCode != 0 {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError.io("`claude mcp add` failed (exit \(result.exitCode)): \(stderr.isEmpty ? "(no stderr)" : stderr)")
        }

        print("registered ghostties with Claude Code")
        print("  scope:  \(scope.rawValue)")
        print("  binary: \(binaryPath)")
        print("Restart Claude Code (or run `claude mcp list`) to verify.")
    }

    /// Returns the configured `ghostties` server's command (the binary path
    /// portion only) or `nil` if not registered. Best-effort parser over
    /// `claude mcp get <name>` output — falls back to `nil` on any parse
    /// trouble so we err toward "treat as not installed."
    private func currentClaudeCodeEntry(claudeCLI: String) -> String? {
        let result = runProcess(claudeCLI, args: ["mcp", "get", Self.serverName])
        guard result.exitCode == 0 else { return nil }
        // `claude mcp get` prints lines like `Command: /path/to/binary` (with
        // optional args appended). Strip args so the comparison matches what
        // we wrote: the bare binary path.
        for raw in result.stdout.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Match either "Command: …" or "Command/Args: …" prefixes.
            for prefix in ["Command: ", "Command/Args: "] {
                if line.hasPrefix(prefix) {
                    let rest = String(line.dropFirst(prefix.count))
                    // Take the first whitespace-delimited token = the binary.
                    return rest.split(separator: " ").first.map(String.init) ?? rest
                }
            }
        }
        return nil
    }

    // MARK: - Binary discovery

    /// Find the `ghostties-mcp` binary in this priority order:
    ///   1. `--binary` override (raw, no expansion beyond `~`).
    ///   2. `which ghostties-mcp` (already on PATH, e.g. user installed it).
    ///   3. Standard install locations.
    ///   4. Local dev build inside this repo's `cli/.build/release/`.
    private func resolveBinaryPath() throws -> String {
        if let binary, !binary.isEmpty {
            let expanded = (binary as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
            throw CLIError.io("--binary path is not executable: \(expanded)")
        }

        if let onPath = which("ghostties-mcp") {
            return onPath
        }

        let candidates = [
            "/usr/local/bin/ghostties-mcp",
            "/opt/homebrew/bin/ghostties-mcp"
        ] + devBuildCandidates()

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        throw CLIError.io("""
            could not find `ghostties-mcp` binary. Tried:
              - $PATH
              - /usr/local/bin/ghostties-mcp
              - /opt/homebrew/bin/ghostties-mcp
              - <repo>/cli/.build/release/ghostties-mcp
            Build it with `cd cli && swift build -c release`, or pass --binary <path>.
            """)
    }

    /// Walk up from CWD looking for `cli/.build/release/ghostties-mcp` so dev
    /// builds work without installing.
    private func devBuildCandidates() -> [String] {
        var paths: [String] = []
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            paths.append(dir.appendingPathComponent("cli/.build/release/ghostties-mcp").path)
            paths.append(dir.appendingPathComponent(".build/release/ghostties-mcp").path)
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return paths
    }

    // MARK: - Subprocess plumbing

    /// Find an executable on PATH. Returns the absolute path or nil.
    private func which(_ name: String) -> String? {
        let result = runProcess("/usr/bin/env", args: ["which", name])
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Synchronous subprocess runner. We don't need streaming; commands here
    /// are short and infrequent.
    private func runProcess(_ launchPath: String, args: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: "failed to launch \(launchPath): \(error.localizedDescription)")
        }

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: out, stderr: err)
    }
}
