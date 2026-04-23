import Foundation
import GhosttiesCore

/// Resolves where `.ghostties/tasks/` lives for this MCP session.
///
/// Priority:
///   1. `--tasks-dir <path>` CLI arg (absolute or relative to cwd)
///   2. Walk up from cwd via `TasksDirectory.find()`
///
/// Resolution is deferred until first tool call so `ghostties-mcp` can boot
/// and respond to `initialize` even when launched from a directory that has
/// no tasks dir yet.
final class TasksDirectoryResolver {
    private let override: URL?
    private var cached: URL?

    init(override: URL?) {
        self.override = override
    }

    /// Resolve or throw. On success, caches the URL — we don't want to re-walk
    /// the filesystem for every tool call.
    func resolve() throws -> URL {
        if let cached { return cached }

        if let override {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: override.path, isDirectory: &isDir),
                  isDir.boolValue else {
                throw CLIError.notFound("--tasks-dir path does not exist or is not a directory: \(override.path)")
            }
            cached = override.standardizedFileURL
            return cached!
        }

        guard let dir = TasksDirectory.find() else {
            throw CLIError.notFound("no .ghostties/tasks/ in any ancestor of cwd. pass --tasks-dir <path> or run 'gt new' first")
        }
        cached = dir
        return dir
    }
}
