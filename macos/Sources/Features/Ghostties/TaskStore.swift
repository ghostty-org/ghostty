import Foundation
import GhosttiesCore
import SwiftUI

/// Observable store that loads task fixtures from `.ghostties/tasks/*.md`
/// into typed `TaskItem` values for the SwiftUI layer to consume.
///
/// v0 is read-only: fixtures load once on init. A future revision will add
/// filesystem observation + debounced persistence along the lines of
/// `WorkspaceStore`. For now the store never mutates the markdown files.
///
/// The store **must never crash** on a missing or malformed fixture directory:
/// parse errors log and skip; a missing directory yields an empty `tasks` array.
@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []

    // MARK: - Graveyard expansion state (U7)

    /// The id of the single Graveyard row that is currently expanded, if any.
    /// Single-expansion per lane (D4 / D11). Nil = all collapsed.
    @Published private(set) var expandedGraveyardTaskId: String? = nil

    /// Toggle Graveyard row expansion for the given task id.
    /// D10: re-click collapses. D11: opening a new row closes the previous.
    func toggleGraveyardExpansion(for taskId: String) {
        if expandedGraveyardTaskId == taskId {
            expandedGraveyardTaskId = nil
        } else {
            expandedGraveyardTaskId = taskId
        }
    }

    /// Collapse any open Graveyard row. Called when a task migrates out of the
    /// done lane so stale expansion state doesn't linger.
    func collapseGraveyardExpansionIfNeeded(for taskId: String) {
        if expandedGraveyardTaskId == taskId {
            expandedGraveyardTaskId = nil
        }
    }

    /// Hardcoded machine-capacity placeholder for v0. Drives the "ACTIVE · N of ~5"
    /// header in the sidebar and the number of empty slots rendered. A later
    /// revision will derive this from `sysctl` or thermal state.
    let machineCap: Int = 5

    private var watcher: TaskFileWatcher?
    private var watchedDirectory: URL?

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init() {
        loadFromDisk()
        #if DEBUG
        print("[TaskStore] Loaded \(tasks.count) task(s) from disk")
        #endif
    }

    deinit {
        watcher?.stop()
    }

    // MARK: - Debug / test hooks

#if DEBUG
    func injectTasksForTesting(_ items: [TaskItem]) {
        tasks = items
    }

    func recomputeLanesForTesting() {
        recomputeLanes()
    }
#endif

    // MARK: - URL lookup

    /// Resolve the on-disk `.md` URL for a task. Uses the currently watched
    /// tasks directory (the one `loadFromDisk` resolved on the last pass).
    /// Returns nil if the directory hasn't been discovered yet.
    func fileURL(for task: TaskItem) -> URL? {
        guard let dir = watchedDirectory else { return nil }
        return dir.appendingPathComponent("\(task.id).md")
    }

    // MARK: - Grouped accessors
    // Stored @Published so SwiftUI sees stable array identity across transactions.
    // Recomputed in a single pass by recomputeLanes() — see hang report 26Apr2026.

    @Published private(set) var needsYou: [TaskItem] = []
    @Published private(set) var active:   [TaskItem] = []
    @Published private(set) var inbox:    [TaskItem] = []
    @Published private(set) var backlog:  [TaskItem] = []
    @Published private(set) var review:   [TaskItem] = []
    @Published private(set) var done:     [TaskItem] = []

    /// Tasks that arrived from an external MCP source (Linear, GitHub, Sentry,
    /// etc.) — i.e. anything whose `source` is not the local `.shell` case.
    /// `.unknown` is treated as external too: a fixture with a missing/garbled
    /// source field is more likely to be an upstream sync row than a local
    /// shell session, and surfacing it in the Inbox makes the bad data visible
    /// instead of hiding it.
    ///
    /// Drives `InboxZoneView` (Phase 5: agent-as-middleman). The lane is the
    /// first user-visible payoff of the external-source pivot — sync 8 Linear
    /// tickets via the user's agent and they land here.
    ///
    /// Sort: newest-first by `created`, matching the global sort `tasks`
    /// already uses (set in `loadFromDisk`). The filter preserves that order.
    @Published private(set) var externalInbox: [TaskItem] = []

    /// SEA-215: Pre-sorted external inbox for `InboxZoneView`. Sorted by
    /// priority descending then created descending — matches R15 from the U1 spec.
    /// Computed once in `recomputeLanes()` so the view never re-sorts on every body call.
    @Published private(set) var sortedExternalInbox: [TaskItem] = []

    /// Recomputes all lane arrays in a single pass over `tasks`. Call this
    /// everywhere `tasks` is mutated so the stored arrays stay in sync.
    private func recomputeLanes() {
        let signpostState = Perf.signposter.beginInterval("taskStore.recomputeLanes", "\(self.tasks.count) tasks")
        defer { Perf.signposter.endInterval("taskStore.recomputeLanes", signpostState) }
        var needs: [TaskItem] = [], act: [TaskItem] = []
        var inb: [TaskItem] = [], bl: [TaskItem] = []
        var rev: [TaskItem] = [], dn: [TaskItem] = []
        var ext: [TaskItem] = []
        for t in tasks {
            switch t.status {
            case .needsYou: needs.append(t)
            case .running:  act.append(t)
            case .inbox:    inb.append(t)
            case .backlog:  bl.append(t)
            case .review:   rev.append(t)
            case .done:     dn.append(t)
            }
            // A1: done tasks must never surface in the Inbox lane — the
            // Graveyard handles them. Filter here at classification time so
            // every downstream consumer (externalInbox, sortedExternalInbox)
            // is automatically correct without each view needing its own guard.
            if t.source != .shell && t.status != .done { ext.append(t) }
        }
        needsYou = needs; active = act; inbox = inb; backlog = bl
        review = rev; done = dn; externalInbox = ext

        // SEA-215: sort once here so InboxZoneView.body never re-sorts.
        sortedExternalInbox = ext.sorted {
            if $0.priority.sortRank != $1.priority.sortRank {
                return $0.priority.sortRank > $1.priority.sortRank
            }
            return $0.created > $1.created
        }
    }

    // MARK: - Write wrappers
    //
    // These methods delegate to GhosttiesCore.TaskStore for all disk I/O.
    // They intentionally contain no business logic — that belongs in U3+.
    //
    // After a successful write the TaskFileWatcher will detect the change and
    // call loadFromDisk automatically; we do NOT manually mutate `tasks` here.

    /// Update the `status:` frontmatter key for the task with the given id.
    /// - Throws: `CLIError.io` if the file can't be read or written, or
    ///   `CLIError.notFound` if no task matches the id.
    func writeStatus(_ status: TaskStatus, for taskId: String) async throws {
        let coreStore = try requireCoreStore()
        let (task, url) = try coreStore.resolve(idOrPrefix: taskId)
        let updatedPairs = GhosttiesCore.Frontmatter.set(
            "status", status.rawValue, in: task.frontmatter)
        try coreStore.write(pairs: updatedPairs, body: task.body, to: url)
    }

    /// Update the `project-path:` frontmatter key for the task with the given id.
    /// Pass an empty string to clear the field.
    /// - Throws: `CLIError.io` if the file can't be read or written, or
    ///   `CLIError.notFound` if no task matches the id.
    func writeProjectPath(_ path: String, for taskId: String) async throws {
        let coreStore = try requireCoreStore()
        let (task, url) = try coreStore.resolve(idOrPrefix: taskId)
        let updatedPairs = GhosttiesCore.Frontmatter.set(
            "project-path", path, in: task.frontmatter)
        try coreStore.write(pairs: updatedPairs, body: task.body, to: url)
    }

    /// Update the `template:` frontmatter key for the task with the given id.
    /// Pass an empty string to clear the field.
    /// - Throws: `CLIError.io` / `CLIError.notFound`.
    func writeTemplate(_ templateName: String, for taskId: String) async throws {
        let coreStore = try requireCoreStore()
        let (task, url) = try coreStore.resolve(idOrPrefix: taskId)
        let updatedPairs = GhosttiesCore.Frontmatter.set(
            "template", templateName, in: task.frontmatter)
        try coreStore.write(pairs: updatedPairs, body: task.body, to: url)
    }

    /// Update the `title:` frontmatter key for the task with the given id.
    /// - Throws: `CLIError.io` / `CLIError.notFound`.
    func writeTitle(_ title: String, for taskId: String) async throws {
        let coreStore = try requireCoreStore()
        let (task, url) = try coreStore.resolve(idOrPrefix: taskId)
        let updatedPairs = GhosttiesCore.Frontmatter.set(
            "title", title, in: task.frontmatter)
        try coreStore.write(pairs: updatedPairs, body: task.body, to: url)
    }

    /// Create a new task `.md` file and return the parsed `TaskItem`.
    ///
    /// - Parameters:
    ///   - title: Human-readable task title (written to `title:` key).
    ///   - project: Project tag (written to `project:` key).
    ///   - status: Initial lane; defaults to `.backlog`.
    ///   - priority: Initial priority; defaults to `.none`.
    ///   - projectPath: Optional filesystem root for the task's project (tilde-raw).
    ///   - template: Optional launch template name.
    ///   - source: Source tag (defaults to `"shell"`).
    ///   - sourceID: Optional external source ID.
    ///
    /// - Returns: The newly created `TaskItem` parsed from the written file.
    /// - Throws: `CLIError.io` if the tasks directory isn't available or the
    ///   file can't be written, or if a file with the generated id already
    ///   exists.
    @discardableResult
    func createTask(
        title: String,
        project: String,
        status: TaskStatus = .backlog,
        priority: TaskPriority = .none,
        projectPath: String? = nil,
        template: String? = nil,
        source: String = "shell",
        sourceID: String? = nil
    ) async throws -> TaskItem {
        let coreStore = try requireCoreStore()
        let id = makeTaskID(title: title)
        let nowISO = Self.isoFormatter.string(from: Date())

        var pairs: [(String, String)] = [
            ("title", title),
            ("source", source),
            ("source-id", sourceID ?? id),
            ("project", project),
            ("created", nowISO),
            ("status", status.rawValue),
            ("priority", priority.rawValue)
        ]
        if let projectPath, !projectPath.isEmpty {
            pairs.append(("project-path", projectPath))
        }
        if let template, !template.isEmpty {
            pairs.append(("template", template))
        }

        let body = "\n## Goal\n\n\n## Notes\n\n\n## Activity\n\n- \(nowISO) — Task created\n"
        let url = try coreStore.create(id: id, pairs: pairs, body: body)

        // Parse the written file back into a TaskItem so the caller gets a
        // typed value. Fail loudly if the round-trip breaks.
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let item = TaskFixtureParser.parse(
                markdown: raw, filename: url.deletingPathExtension().lastPathComponent)
        else {
            throw CLIError.io("created task at \(url.path) but could not re-parse it")
        }
        return item
    }

    // MARK: - Write helpers

    /// Return a `GhosttiesCore.TaskStore` pointed at the current `watchedDirectory`.
    /// Throws `CLIError.io` if the directory hasn't been resolved yet.
    private func requireCoreStore() throws -> GhosttiesCore.TaskStore {
        guard let dir = watchedDirectory else {
            throw CLIError.io("tasks directory not yet resolved — call loadFromDisk first")
        }
        return GhosttiesCore.TaskStore(directory: dir)
    }

    /// Kebab-slug `title` with a 6-char UUID suffix to avoid collisions.
    private func makeTaskID(title: String) -> String {
        let slug: String = {
            let lowered = title.lowercased()
            var out = ""
            var lastDash = false
            for ch in lowered {
                if ch.isLetter || ch.isNumber {
                    out.append(ch); lastDash = false
                } else if !lastDash {
                    out.append("-"); lastDash = true
                }
            }
            return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }()
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        return slug.isEmpty ? "task-\(suffix)" : "\(slug)-\(suffix)"
    }

    // MARK: - Loading

    func loadFromDisk() {
        let signpostState = Perf.signposter.beginInterval("taskStore.load")
        defer { Perf.signposter.endInterval("taskStore.load", signpostState) }
        guard let dir = Self.resolveTasksDirectory() else {
            #if DEBUG
            print("[TaskStore] No tasks directory found; tasks=[]")
            #endif
            tasks = []
            recomputeLanes()
            return
        }

        // If the resolved directory changed since last load (e.g. one directory
        // was deleted and a different candidate now wins), rewire the watcher.
        if watchedDirectory != dir {
            rewireWatcher(to: dir)
        }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir,
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) else {
            #if DEBUG
            print("[TaskStore] Could not enumerate \(dir.path); tasks=[]")
            #endif
            tasks = []
            recomputeLanes()
            return
        }

        let mdFiles = entries.filter { $0.pathExtension.lowercased() == "md" }
        var loaded: [TaskItem] = []
        loaded.reserveCapacity(mdFiles.count)

        for url in mdFiles {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                #if DEBUG
                print("[TaskStore] Failed to read \(url.lastPathComponent)")
                #endif
                continue
            }
            if let item = TaskFixtureParser.parse(markdown: raw, filename: url.deletingPathExtension().lastPathComponent) {
                loaded.append(item)
            } else {
                #if DEBUG
                print("[TaskStore] Failed to parse \(url.lastPathComponent)")
                #endif
            }
        }

        // Stable ordering: newest created first within each lane. Lane grouping
        // is up to the view layer; here we just produce a deterministic list.
        loaded.sort { $0.created > $1.created }
        tasks = loaded

        // Collapse Graveyard expansion if the previously-expanded task is no
        // longer in the done lane (e.g. agent re-opened it).
        if let expandedId = expandedGraveyardTaskId {
            let stillDone = loaded.contains { $0.id == expandedId && $0.status == .done }
            if !stillDone {
                expandedGraveyardTaskId = nil
            }
        }

        recomputeLanes()
    }

    // MARK: - Filesystem watching

    private func rewireWatcher(to dir: URL) {
        watcher?.stop()
        watchedDirectory = dir
        let w = TaskFileWatcher(url: dir) { [weak self] in
            guard let self = self else { return }
            _Concurrency.Task { @MainActor in self.loadFromDisk() }
        }
        watcher = w
        w.start()
    }

    // MARK: - Directory discovery

    /// Look for fixtures in priority order:
    ///   0. `GHOSTTIES_TASKS_DIR` env var (empty string → no directory; used by tests)
    ///   1. Delegate to `GhosttiesCore.TasksDirectory.find(startingAt:)` — canonical
    ///      git-walk shared with the CLI and MCP server (A6: resolver parity)
    ///   2. `~/Code/ghostties/.ghostties/tasks/` (dev convenience fallback)
    ///
    /// Delegating to `GhosttiesCore.TasksDirectory.find` guarantees the macOS
    /// sidebar and the `gt` CLI agree on which tasks directory wins for any given
    /// project tree. Prior to A6 the macOS version did its own walk that stopped
    /// at the first `.git` boundary (even when no `.ghostties/tasks` existed
    /// there), whereas the core walk continues up to `$HOME`. That divergence
    /// caused "task file not found" failures on real projects.
    private static func resolveTasksDirectory() -> URL? {
        let fm = FileManager.default

        // 0. Test isolation override — preserve for unit-test isolation.
        if let override = ProcessInfo.processInfo.environment["GHOSTTIES_TASKS_DIR"] {
            guard !override.isEmpty else { return nil }
            let url = URL(fileURLWithPath: override, isDirectory: true)
            return fm.fileExists(atPath: url.path) ? url : nil
        }

        // 1. Delegate to the canonical GhosttiesCore resolver.
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        if let found = GhosttiesCore.TasksDirectory.find(startingAt: cwd) {
            return found
        }

        // 2. Dev convenience fallback — keeps the app usable during local
        //    development when cwd is not inside the ghostties repo.
        let home = fm.homeDirectoryForCurrentUser
        let devFallback = home.appendingPathComponent("Code/ghostties/.ghostties/tasks", isDirectory: true)
        if fm.fileExists(atPath: devFallback.path) {
            return devFallback
        }

        return nil
    }
}

// MARK: - Fixture parser

/// Hand-rolled parser for the v0 task fixture format. Deliberately narrow:
/// the fixtures are flat YAML frontmatter plus three known H2 sections
/// (`Goal`, `Notes`, `Activity`). No general-purpose YAML or markdown support.
enum TaskFixtureParser {
    /// Parse a fixture file into a `TaskItem`, or return nil if the frontmatter
    /// is unparseable / missing required fields.
    ///
    /// `filename` is the file stem (no `.md`) used as a fallback `id` when the
    /// frontmatter lacks a `source-id`.
    static func parse(markdown: String, filename: String) -> TaskItem? {
        guard let (frontmatter, body) = splitFrontmatter(markdown) else { return nil }
        let yaml = parseFlatYAML(frontmatter)

        guard let title = yaml["title"],
              let statusRaw = yaml["status"],
              let status = TaskStatus(rawValue: statusRaw),
              let createdRaw = yaml["created"],
              let created = parseISODate(createdRaw),
              let project = yaml["project"] else {
            return nil
        }

        let sourceRaw = yaml["source"] ?? "unknown"
        let source = TaskSource(rawValue: sourceRaw.lowercased()) ?? .unknown

        let sourceID = yaml["source-id"]
        let id = sourceID ?? filename

        // Body sections
        let sections = splitH2Sections(body)
        let goal = sections["Goal"]?.trimmed()
        let notes = sections["Notes"]?.trimmed()
        let events = sections["Activity"].map(parseActivity)

        // `project-path` is optional — drives the click-spawns-terminal cwd.
        // Stored tilde-raw; consumers expand. Empty string ≡ unset.
        let projectPath: String? = {
            guard let raw = yaml["project-path"]?
                .trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
                return nil
            }
            return raw
        }()

        // `template` is optional — resolved by name (case-insensitive) at
        // session-spawn time. Empty string ≡ unset.
        let template: String? = {
            guard let raw = yaml["template"]?
                .trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
                return nil
            }
            return raw
        }()

        // Parse priority with strict-with-skip: unknown value → .none, never crash.
        let priority: TaskPriority = {
            guard let raw = yaml["priority"], !raw.isEmpty else { return .none }
            return TaskPriority(rawValue: raw) ?? .none
        }()

        return TaskItem(
            id: id,
            title: title,
            source: source,
            sourceID: sourceID,
            branch: yaml["branch"].flatMap { $0 == "null" ? nil : $0 },
            project: project,
            projectPath: projectPath,
            template: template,
            created: created,
            status: status,
            priority: priority,
            filesStaged: yaml["files-staged"].flatMap(Int.init),
            goal: goal?.isEmpty == true ? nil : goal,
            notes: notes?.isEmpty == true ? nil : notes,
            needs: yaml["needs"],
            severity: yaml["severity"],
            pr: yaml["pr"].flatMap(Int.init),
            prState: yaml["pr-state"],
            ci: yaml["ci"],
            completed: yaml["completed"].flatMap(parseISODate),
            events: (events?.isEmpty == true) ? nil : events
        )
    }

    // MARK: Frontmatter split

    /// Returns the frontmatter (between leading `---` fences) and the body.
    /// Returns nil if the file does not start with a frontmatter block.
    private static func splitFrontmatter(_ raw: String) -> (String, String)? {
        var lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()

        var fmLines: [String] = []
        var bodyLines: [String] = []
        var inBody = false
        for line in lines {
            if !inBody, line.trimmingCharacters(in: .whitespaces) == "---" {
                inBody = true
                continue
            }
            if inBody {
                bodyLines.append(line)
            } else {
                fmLines.append(line)
            }
        }
        guard inBody else { return nil }
        return (fmLines.joined(separator: "\n"), bodyLines.joined(separator: "\n"))
    }

    // MARK: Flat YAML

    /// Parse a flat `key: value` block. Values are trimmed of leading/trailing
    /// whitespace and surrounding single/double quotes. Comments (`# ...`) are
    /// not supported — the fixtures don't use them.
    private static func parseFlatYAML(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    // MARK: H2 section split

    /// Split the body by `## Heading` lines. Returns a dict keyed by the
    /// heading text (trimmed), value is the content until the next `## ` or EOF.
    private static func splitH2Sections(_ body: String) -> [String: String] {
        var sections: [String: String] = [:]
        var currentKey: String?
        var currentLines: [String] = []

        func flush() {
            if let key = currentKey {
                sections[key] = currentLines.joined(separator: "\n")
            }
        }

        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                currentKey = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentLines = []
            } else if currentKey != nil {
                currentLines.append(line)
            }
        }
        flush()
        return sections
    }

    // MARK: Activity parsing

    /// Parse `- <ISO8601> — <description>` lines into `[TaskEvent]`.
    /// Accepts em-dash (U+2014), en-dash (U+2013), or double-hyphen `--` as
    /// the timestamp/description separator. Skips lines that don't match.
    private static func parseActivity(_ section: String) -> [TaskEvent] {
        var events: [TaskEvent] = []
        let separators: [String] = [" — ", " – ", " -- "]

        for raw in section.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { continue }
            let line = String(trimmed.dropFirst(2))

            var hit: (String, String)?
            for sep in separators {
                if let r = line.range(of: sep) {
                    hit = (String(line[..<r.lowerBound]),
                           String(line[r.upperBound...]))
                    break
                }
            }
            guard let (tsPart, descPart) = hit,
                  let ts = parseISODate(tsPart.trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            events.append(TaskEvent(
                timestamp: ts,
                description: descPart.trimmingCharacters(in: .whitespaces)
            ))
        }
        return events
    }

    // MARK: ISO8601

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseISODate(_ s: String) -> Date? {
        if let d = isoFormatter.date(from: s) { return d }
        if let d = isoFormatterFractional.date(from: s) { return d }
        return nil
    }
}

private extension String {
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
