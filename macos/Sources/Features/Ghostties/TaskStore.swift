import Foundation
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

    /// Hardcoded machine-capacity placeholder for v0. Drives the "ACTIVE · N of ~5"
    /// header in the sidebar and the number of empty slots rendered. A later
    /// revision will derive this from `sysctl` or thermal state.
    let machineCap: Int = 5

    private var watcher: TaskFileWatcher?
    private var watchedDirectory: URL?

    init() {
        loadFromDisk()
        #if DEBUG
        print("[TaskStore] Loaded \(tasks.count) task(s) from disk")
        #endif
    }

    deinit {
        watcher?.stop()
    }

    // MARK: - URL lookup

    /// Resolve the on-disk `.md` URL for a task. Uses the currently watched
    /// tasks directory (the one `loadFromDisk` resolved on the last pass).
    /// Returns nil if the directory hasn't been discovered yet.
    func fileURL(for task: TaskItem) -> URL? {
        guard let dir = watchedDirectory else { return nil }
        return dir.appendingPathComponent("\(task.id).md")
    }

    // MARK: - Grouped accessors

    var needsYou: [TaskItem] { tasks.filter { $0.status == .needsYou } }
    var active: [TaskItem] { tasks.filter { $0.status == .running } }
    var inbox: [TaskItem] { tasks.filter { $0.status == .inbox } }
    var backlog: [TaskItem] { tasks.filter { $0.status == .backlog } }
    var review: [TaskItem] { tasks.filter { $0.status == .review } }
    var done: [TaskItem] { tasks.filter { $0.status == .done } }

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
    var externalInbox: [TaskItem] {
        tasks.filter { $0.source != .shell }
    }

    // MARK: - Loading

    func loadFromDisk() {
        guard let dir = Self.resolveTasksDirectory() else {
            #if DEBUG
            print("[TaskStore] No tasks directory found; tasks=[]")
            #endif
            tasks = []
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
    }

    // MARK: - Filesystem watching

    private func rewireWatcher(to dir: URL) {
        watcher?.stop()
        watchedDirectory = dir
        let w = TaskFileWatcher(url: dir) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in self.loadFromDisk() }
        }
        watcher = w
        w.start()
    }

    // MARK: - Directory discovery

    /// Look for fixtures in priority order:
    ///   1. `<cwd-up-to-.git>/.ghostties/tasks/`
    ///   2. `~/.ghostties/tasks/`
    ///   3. `~/Code/ghostties/.ghostties/tasks/` (dev fallback)
    private static func resolveTasksDirectory() -> URL? {
        let fm = FileManager.default

        // 1. Walk up from cwd looking for a .git directory
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        var cursor: URL? = cwd
        while let here = cursor {
            let gitPath = here.appendingPathComponent(".git")
            if fm.fileExists(atPath: gitPath.path) {
                let candidate = here.appendingPathComponent(".ghostties/tasks", isDirectory: true)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
                break // found a repo root, but no .ghostties/tasks; fall through
            }
            let parent = here.deletingLastPathComponent()
            cursor = parent.path == here.path ? nil : parent
        }

        // 2. User-global
        let home = fm.homeDirectoryForCurrentUser
        let userGlobal = home.appendingPathComponent(".ghostties/tasks", isDirectory: true)
        if fm.fileExists(atPath: userGlobal.path) {
            return userGlobal
        }

        // 3. Dev convenience fallback
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
