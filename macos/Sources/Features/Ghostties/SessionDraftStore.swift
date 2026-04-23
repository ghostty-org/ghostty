import Foundation
import SwiftUI

/// Observable store for `SessionDraft`s — unpromoted terminal sessions
/// rendered as rows in the ACTIVE zone of the task-first sidebar.
///
/// Persists the draft list to `.ghostties/sessions.json` (sibling of
/// `.ghostties/tasks/`). `terminalSessionId` is NOT persisted — runtime UUIDs
/// don't survive app restart. A restored draft is `isStale == true` until the
/// user clicks it (future work: re-spawn at cwd).
///
/// Promotion writes a plain task markdown file that `TaskStore`'s file watcher
/// picks up on the next reload — the same `.md` format used by the `gt` CLI
/// and MCP server, so the three surfaces stay in lockstep.
@MainActor
final class SessionDraftStore: ObservableObject {
    @Published private(set) var drafts: [SessionDraft] = []

    private var ghosttiesDirectory: URL?

    init() {
        loadFromDisk()
    }

    // MARK: - Lookup

    /// Find a draft by its linked terminal session. Used by the close-hook to
    /// GC a draft when its terminal exits without being promoted.
    func draft(forTerminalSession id: UUID) -> SessionDraft? {
        drafts.first { $0.terminalSessionId == id }
    }

    // MARK: - Mutation

    /// Register a new draft for a freshly-spawned terminal at `cwd`. Persists
    /// immediately so a crash doesn't orphan the row.
    @discardableResult
    func register(cwd: String, terminalSessionId: UUID? = nil) -> SessionDraft {
        let draft = SessionDraft(cwd: cwd, terminalSessionId: terminalSessionId)
        drafts.append(draft)
        saveToDisk()
        return draft
    }

    /// Bind an existing draft to a live terminal session. No-op if the draft
    /// is unknown. Mutates the draft in place and re-publishes the array so
    /// SwiftUI picks up the change (SessionDraft is a plain class, not
    /// observable by itself).
    func attach(draftId: String, to terminalSessionId: UUID) {
        guard let draft = drafts.first(where: { $0.id == draftId }) else { return }
        draft.terminalSessionId = terminalSessionId
        objectWillChange.send()
        saveToDisk()
    }

    /// GC a draft — used when the terminal closes without being promoted.
    func remove(draftId: String) {
        drafts.removeAll { $0.id == draftId }
        saveToDisk()
    }

    /// Terminal close hook. If a draft is attached to this terminal:
    /// - unpromoted → remove (GC)
    /// - promoted → clear `terminalSessionId` so the row (if ever re-rendered)
    ///   reads as stale, but keep the record until the task layer ages it out
    func detachOrRemove(forTerminalSession id: UUID) {
        guard let draft = drafts.first(where: { $0.terminalSessionId == id }) else { return }
        if draft.promotedToTaskId == nil {
            drafts.removeAll { $0.id == draft.id }
        } else {
            draft.terminalSessionId = nil
            objectWillChange.send()
        }
        saveToDisk()
    }

    /// Promote a draft to a named task. Writes the `.md`, removes the draft,
    /// and returns the new task's filename stem (the id `TaskStore` will use).
    /// Returns nil if the draft is unknown or the file write fails.
    func promoteToTask(draftId: String,
                       title: String,
                       workspaceStore: WorkspaceStore) -> String? {
        guard let idx = drafts.firstIndex(where: { $0.id == draftId }) else { return nil }
        let draft = drafts[idx]

        // Infer project from cwd by matching against WorkspaceStore.projects
        // (longest prefix match on rootPath). Fall back to the trailing path
        // component so we always have something for the `project:` field.
        let expandedCwd = (draft.cwd as NSString).expandingTildeInPath
        let matchedProject = workspaceStore.projects
            .filter { expandedCwd.hasPrefix((($0.rootPath as NSString).expandingTildeInPath)) }
            .max(by: { $0.rootPath.count < $1.rootPath.count })

        let projectName = matchedProject?.name
            ?? URL(fileURLWithPath: expandedCwd).lastPathComponent
        let projectPathRaw = matchedProject?.rootPath ?? draft.cwd

        let branch = Self.currentGitBranch(atCwd: expandedCwd)
        let slug = Self.slugify(title)
        let stem = "\(slug)-\(Self.shortId(from: draft.id))"

        guard let dir = resolveTasksDirectory() else {
            FileHandle.standardError.write(Data(
                "⚠️ Ghostties: no .ghostties/tasks directory resolvable; promotion aborted\n".utf8
            ))
            return nil
        }

        let fileURL = dir.appendingPathComponent("\(stem).md")
        let markdown = Self.buildTaskMarkdown(
            id: stem,
            title: title,
            project: projectName,
            projectPath: projectPathRaw,
            branch: branch,
            created: draft.startedAt
        )

        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data(
                "⚠️ Ghostties: failed to write task .md at \(fileURL.path): \(error)\n".utf8
            ))
            return nil
        }

        // Remove the draft — the new .md takes its place in the sidebar via
        // TaskFileWatcher.
        drafts.remove(at: idx)
        saveToDisk()

        return stem
    }

    // MARK: - Persistence

    func loadFromDisk() {
        guard let dir = resolveGhosttiesDirectory() else {
            drafts = []
            return
        }
        ghosttiesDirectory = dir
        let url = dir.appendingPathComponent("sessions.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            drafts = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            drafts = try decoder.decode([SessionDraft].self, from: data)
        } catch {
            FileHandle.standardError.write(Data(
                "⚠️ Ghostties: sessions.json failed to decode (\(error)); starting fresh\n".utf8
            ))
            drafts = []
        }
    }

    private func saveToDisk() {
        guard let dir = ghosttiesDirectory ?? resolveGhosttiesDirectory() else { return }
        ghosttiesDirectory = dir

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            let data = try encoder.encode(drafts)
            let finalURL = dir.appendingPathComponent("sessions.json")
            let tmpURL = dir.appendingPathComponent("sessions.json.tmp")
            try data.write(to: tmpURL, options: [.atomic])
            _ = try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: tmpURL, to: finalURL)
        } catch {
            FileHandle.standardError.write(Data(
                "⚠️ Ghostties: failed to write sessions.json: \(error)\n".utf8
            ))
        }
    }

    // MARK: - Directory resolution

    /// Return the `.ghostties/` directory (parent of both `tasks/` and
    /// `sessions.json`). Walks up from cwd for a `.git`; falls back to
    /// `~/.ghostties/` then the dev convenience path.
    private func resolveGhosttiesDirectory() -> URL? {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        var cursor: URL? = cwd
        while let here = cursor {
            if fm.fileExists(atPath: here.appendingPathComponent(".git").path) {
                return here.appendingPathComponent(".ghostties", isDirectory: true)
            }
            let parent = here.deletingLastPathComponent()
            cursor = parent.path == here.path ? nil : parent
        }
        let home = fm.homeDirectoryForCurrentUser
        let userGlobal = home.appendingPathComponent(".ghostties", isDirectory: true)
        if fm.fileExists(atPath: userGlobal.path) { return userGlobal }

        let devFallback = home.appendingPathComponent("Code/ghostties/.ghostties", isDirectory: true)
        if fm.fileExists(atPath: devFallback.path) { return devFallback }

        // Last resort: create user-global.
        return userGlobal
    }

    /// Tasks directory inside the `.ghostties/` root. Mirrors (but doesn't
    /// share code with) `TaskStore.resolveTasksDirectory` — both paths must
    /// agree for promotion to round-trip via the file watcher.
    private func resolveTasksDirectory() -> URL? {
        resolveGhosttiesDirectory()?.appendingPathComponent("tasks", isDirectory: true)
    }

    // MARK: - Task markdown writer

    private static func buildTaskMarkdown(
        id: String,
        title: String,
        project: String,
        projectPath: String,
        branch: String?,
        created: Date
    ) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let createdStr = iso.string(from: created)

        var fm = "---\n"
        fm += "title: \(yamlEscape(title))\n"
        fm += "source: shell\n"
        fm += "project: \(yamlEscape(project))\n"
        fm += "project-path: \(yamlEscape(projectPath))\n"
        if let b = branch {
            fm += "branch: \(yamlEscape(b))\n"
        }
        fm += "created: \(createdStr)\n"
        fm += "status: running\n"
        fm += "---\n\n"
        fm += "## Goal\n\n\n"
        fm += "## Notes\n\n\n"
        fm += "## Activity\n\n"
        fm += "- \(createdStr) — Promoted from terminal session\n"
        return fm
    }

    private static func yamlEscape(_ s: String) -> String {
        // Quote when the string contains YAML-special characters; otherwise leave bare.
        if s.contains(where: { ":\"'#[]{}&*!|>%@`".contains($0) }) || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return s
    }

    private static func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        var out = ""
        var lastDash = false
        for ch in lowered {
            if allowed.contains(ch) {
                out.append(ch)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.isEmpty { return "session" }
        return String(out.prefix(40))
    }

    private static func shortId(from uuid: String) -> String {
        // First 6 hex chars of the UUID. Keeps filenames readable without
        // risking collisions for the small ~dozen drafts a user holds at once.
        String(uuid.replacingOccurrences(of: "-", with: "").prefix(6))
    }

    // MARK: - Git

    /// Run `git -C <cwd> rev-parse --abbrev-ref HEAD` to capture the branch
    /// name. Returns nil on any failure — promotion is tolerant of missing
    /// git state (the draft's cwd might not be inside a repo).
    nonisolated static func currentGitBranch(atCwd cwd: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cwd) else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty || out == "HEAD" ? nil : out
    }
}

