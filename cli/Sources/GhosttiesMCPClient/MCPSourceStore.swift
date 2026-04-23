import Foundation
import GhosttiesCore

/// Persists the list of configured MCP sources to `.ghostties/mcp-sources.json`.
/// Discovery walks up from cwd the same way `TasksDirectory.find` does — the
/// MCP sources config lives alongside `.ghostties/tasks/`.
///
/// Pretty-printed JSON with sorted keys so the file diffs cleanly in git.
public struct MCPSourceStore {
    /// Filename inside the `.ghostties/` directory.
    public static let filename = "mcp-sources.json"

    /// Resolved absolute path to the sources file.
    public let fileURL: URL

    /// Initialize with an explicit file URL (used by tests).
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Discover the `.ghostties/` state directory by walking up from cwd and
    /// point at `mcp-sources.json`. Falls back to `./.ghostties/mcp-sources.json`
    /// in the current working directory if no ancestor contains one yet.
    public static func discover(
        startingAt cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) -> MCPSourceStore {
        // Reuse TasksDirectory's walk-up: if a tasks dir exists, its parent is
        // our state dir. Otherwise default to ./.ghostties/ in cwd so a first
        // `save()` bootstraps the structure without scanning siblings.
        if let tasksDir = TasksDirectory.find(startingAt: cwd) {
            let stateDir = TasksDirectory.stateDirectory(from: tasksDir)
            return MCPSourceStore(fileURL: stateDir.appendingPathComponent(filename))
        }
        let state = cwd.appendingPathComponent(".ghostties", isDirectory: true)
        return MCPSourceStore(fileURL: state.appendingPathComponent(filename))
    }

    /// Load sources. Returns `[]` if the file doesn't exist. Throws
    /// `MCPError.decodingFailed` on malformed JSON or schema mismatch.
    public func load() throws -> [MCPSource] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw MCPError.decodingFailed("read \(fileURL.path): \(error.localizedDescription)")
        }
        // Empty file is treated as empty list (ergonomic: `touch mcp-sources.json` works).
        if data.isEmpty { return [] }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode([MCPSource].self, from: data)
        } catch {
            throw MCPError.decodingFailed("parse \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Save sources. Creates the parent `.ghostties/` directory if needed.
    /// Writes pretty-printed, sorted-keys JSON for git-friendly diffs.
    public func save(_ sources: [MCPSource]) throws {
        let parent = fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: parent.path) {
            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw MCPError.transportFailed("create \(parent.path): \(error.localizedDescription)")
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(sources)
        } catch {
            throw MCPError.decodingFailed("encode sources: \(error.localizedDescription)")
        }

        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw MCPError.transportFailed("write \(fileURL.path): \(error.localizedDescription)")
        }
    }
}
