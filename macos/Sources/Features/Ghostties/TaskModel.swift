import Foundation
import GhosttiesCore

/// Task priority levels. Bridged directly from `GhosttiesCore.TaskPriority`
/// so the raw values, `Codable` conformance, and `CaseIterable` conformance
/// stay in sync across CLI, MCP, and macOS surfaces automatically.
/// Default is `.none`. Unknown values decoded from disk fall back to `.none`.
typealias TaskPriority = GhosttiesCore.TaskPriority

extension TaskPriority {
    /// Numeric rank for descending sort: higher value = higher priority.
    /// `.high` = 3, `.medium` = 2, `.low` = 1, `.none` = 0.
    /// Used by `InboxZoneView` to sort rows by priority desc, created desc.
    var sortRank: Int {
        switch self {
        case .high:   return 3
        case .medium: return 2
        case .low:    return 1
        case .none:   return 0
        }
    }
}

/// Status lanes for a task, matching the six-lane IA from the task-first sidebar brief.
///
/// Raw values are the snake/kebab-case strings used in `.ghostties/tasks/*.md`
/// frontmatter (e.g. `status: needs-you`).
enum TaskStatus: String, Codable, CaseIterable {
    case inbox
    case backlog
    case running
    case needsYou = "needs-you"
    case review
    case done
}

/// The originating source of a task. Drives the source-glyph in the sidebar row
/// and determines which metadata fields are expected on the frontmatter.
///
/// Unknown sources decode as `.unknown` so a future source type in a fixture
/// file doesn't crash the store.
enum TaskSource: String, Codable {
    case linear
    case github
    case sentry
    case shell
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = TaskSource(rawValue: raw.lowercased()) ?? .unknown
    }
}

/// A single event in a task's activity log. Parsed from `## Activity` section
/// lines of the form `- <ISO8601> — <description>` (em-dash or hyphen accepted).
struct TaskEvent: Codable, Equatable, Hashable {
    let timestamp: Date
    let description: String
}

/// One task row. Matches the frontmatter schema documented in the task-first
/// sidebar brief §7, plus derived `goal`/`notes`/`events` extracted from the
/// markdown body.
///
/// Snake/kebab-case YAML fields are mapped to camelCase Swift via `CodingKeys`.
/// All fields except the core identity set are optional because the fixtures
/// vary by lane (shell tasks have no PR, done tasks have `completed`, etc.).
struct TaskItem: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let source: TaskSource
    let sourceID: String?
    let branch: String?
    let project: String
    /// Optional explicit filesystem root for the task's project (e.g.
    /// `~/Code/ghostties`). When present, used as the cwd when the row-click
    /// spawns a terminal. Authoritative over `WorkspaceStore` name-lookup.
    /// Stored tilde-raw — expand via `NSString(string:).expandingTildeInPath`
    /// at the call site, never on write.
    let projectPath: String?
    /// Optional `AgentTemplate` name override (e.g. `orchestrator`,
    /// `claude code`). Resolved case-insensitively at spawn time against
    /// `WorkspaceStore.templates`; a non-nil value that fails to resolve logs
    /// to stderr and falls back to the user-preference / built-in default.
    let template: String?
    let created: Date
    let status: TaskStatus
    /// Task priority parsed from the `priority:` frontmatter key.
    /// Defaults to `.none` when the key is absent or contains an unknown value.
    let priority: TaskPriority
    let filesStaged: Int?
    let goal: String?
    let notes: String?
    let needs: String?
    let severity: String?
    let pr: Int?
    let prState: String?
    let ci: String?
    let completed: Date?
    let events: [TaskEvent]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case source
        case sourceID = "source-id"
        case branch
        case project
        case projectPath = "project-path"
        case template
        case created
        case status
        case priority
        case filesStaged = "files-staged"
        case goal
        case notes
        case needs
        case severity
        case pr
        case prState = "pr-state"
        case ci
        case completed
        case events
    }

    // Custom Decodable init so that:
    //   1. Old fixture files without a `priority:` key default to `.none` (backward compat).
    //   2. Unknown priority strings (e.g. `urgent`) also default to `.none` (strict-with-skip).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        source = try c.decode(TaskSource.self, forKey: .source)
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        project = try c.decode(String.self, forKey: .project)
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        template = try c.decodeIfPresent(String.self, forKey: .template)
        created = try c.decode(Date.self, forKey: .created)
        status = try c.decode(TaskStatus.self, forKey: .status)
        // priority: missing key → .none; unknown raw value → .none (strict-with-skip).
        if let raw = try c.decodeIfPresent(String.self, forKey: .priority) {
            priority = TaskPriority(rawValue: raw) ?? .none
        } else {
            priority = .none
        }
        filesStaged = try c.decodeIfPresent(Int.self, forKey: .filesStaged)
        goal = try c.decodeIfPresent(String.self, forKey: .goal)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        needs = try c.decodeIfPresent(String.self, forKey: .needs)
        severity = try c.decodeIfPresent(String.self, forKey: .severity)
        pr = try c.decodeIfPresent(Int.self, forKey: .pr)
        prState = try c.decodeIfPresent(String.self, forKey: .prState)
        ci = try c.decodeIfPresent(String.self, forKey: .ci)
        completed = try c.decodeIfPresent(Date.self, forKey: .completed)
        events = try c.decodeIfPresent([TaskEvent].self, forKey: .events)
    }

    // Explicit memberwise init used by TaskFixtureParser (not Codable-based).
    init(
        id: String,
        title: String,
        source: TaskSource,
        sourceID: String?,
        branch: String?,
        project: String,
        projectPath: String?,
        template: String?,
        created: Date,
        status: TaskStatus,
        priority: TaskPriority = .none,
        filesStaged: Int?,
        goal: String?,
        notes: String?,
        needs: String?,
        severity: String?,
        pr: Int?,
        prState: String?,
        ci: String?,
        completed: Date?,
        events: [TaskEvent]?
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.sourceID = sourceID
        self.branch = branch
        self.project = project
        self.projectPath = projectPath
        self.template = template
        self.created = created
        self.status = status
        self.priority = priority
        self.filesStaged = filesStaged
        self.goal = goal
        self.notes = notes
        self.needs = needs
        self.severity = severity
        self.pr = pr
        self.prState = prState
        self.ci = ci
        self.completed = completed
        self.events = events
    }
}
