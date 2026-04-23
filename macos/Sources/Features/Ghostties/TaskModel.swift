import Foundation

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
    let created: Date
    let status: TaskStatus
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
        case created
        case status
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
}
