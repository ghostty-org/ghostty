import ArgumentParser
import Foundation
import GhosttiesCore

struct NewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Create a new task in .ghostties/tasks/."
    )

    @Argument(help: "Task title (quoted).")
    var title: String

    @Option(name: .long, help: "Task source (linear, github, shell, sentry, ...).")
    var source: String?

    @Option(name: .long, help: "Branch name to associate with the task.")
    var branch: String?

    @Option(name: .long, help: "Project tag (defaults to containing directory name).")
    var project: String?

    @Option(name: .long, help: "Path to the project's root directory (e.g. ~/Code/ghostties). Stored raw — tildes are not expanded.")
    var projectPath: String?

    @Option(name: .long, help: "Launch template name (e.g. \"Claude Code\"). Defaults to \"Claude Code\".")
    var template: String?

    @Option(name: .long, help: "Status lane: inbox, backlog, running, needs-you, review, done/graveyard.")
    var lane: String?

    @Option(name: .long, help: "Task priority: high, medium, low, none. Defaults to none (field omitted).")
    var priority: String?

    func run() throws {
        let dir = try TasksDirectory.findOrCreate()
        let store = TaskStore(directory: dir)

        let laneValue: TaskLane
        if let lane {
            guard let parsed = TaskLane.parse(lane) else {
                throw CLIError.usage("unknown lane \"\(lane)\"")
            }
            laneValue = parsed
        } else {
            laneValue = .backlog
        }

        // Parse priority strictly — unknown values error at the CLI layer rather
        // than silently falling back to .none. This matches the three-surface
        // contract (D27) and is intentionally stricter than the MCP tool's
        // permissive fallback, which handles agent-generated free-text.
        let priorityValue: TaskPriority
        if let priority {
            guard let parsed = TaskPriority(rawValue: priority.lowercased()) else {
                let valid = TaskPriority.allCases.map(\.rawValue).joined(separator: ", ")
                throw CLIError.usage("unknown priority \"\(priority)\" — valid values: \(valid)")
            }
            priorityValue = parsed
        } else {
            priorityValue = .none
        }

        let id = makeID(title: title)
        let projectValue = project ?? defaultProject(from: dir)
        let nowISO = isoFormatter.string(from: Date())

        var pairs: [(String, String)] = [
            ("title", title),
            ("source", source ?? "shell"),
            ("source-id", id),
            ("branch", branch ?? "null"),
            ("project", projectValue),
            ("created", nowISO),
            ("status", laneValue.rawValue)
        ]
        // Per U1 / three-surface contract: .none is not written to disk so that
        // legacy fixtures without a priority: field are treated as .none on load.
        // This keeps round-trips clean and avoids polluting existing task files.
        if priorityValue != .none {
            pairs.append(("priority", priorityValue.rawValue))
        }
        if let projectPath, !projectPath.isEmpty {
            pairs.append(("project-path", projectPath))
        }
        // Default to "Claude Code" when no template is specified so new tasks
        // get a sensible launch template without requiring an explicit flag.
        let templateValue = (template?.isEmpty == false) ? template! : "Claude Code"
        pairs.append(("template", templateValue))

        let body = "\n## Goal\n\n\n## Notes\n\n\n## Activity\n\n- \(nowISO) — Task created via gt new\n"

        let url = try store.create(id: id, pairs: pairs, body: body)
        print(url.path)
    }

    // MARK: - Helpers

    /// Kebab-case the title and append a short unique suffix so two tasks with
    /// similar titles don't collide. Suffix is the first 6 chars of a UUID.
    private func makeID(title: String) -> String {
        let slug = slugify(title)
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        return slug.isEmpty ? "task-\(suffix)" : "\(slug)-\(suffix)"
    }

    private func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        var lastWasDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func defaultProject(from tasksDir: URL) -> String {
        // tasksDir is .../<repo>/.ghostties/tasks — go up two to get <repo>.
        let repo = tasksDir.deletingLastPathComponent().deletingLastPathComponent()
        let name = repo.lastPathComponent
        return name.isEmpty ? "ghostties" : name
    }
}

/// Shared ISO formatter across commands. Matches the `created:` format used in
/// existing fixtures (full internet date-time, no fractional seconds).
let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
