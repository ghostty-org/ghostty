import Foundation

/// Status lanes — raw values match what the macOS app writes and reads in
/// `status:` frontmatter. "graveyard" is the UI name for `done` but the
/// on-disk value must stay `done` so the app parses it.
public enum TaskLane: String, CaseIterable, Sendable {
    case inbox
    case backlog
    case running
    case needsYou = "needs-you"
    case review
    case done

    /// Accept "graveyard" as an alias for "done" on input only. Never written.
    public static func parse(_ s: String) -> TaskLane? {
        let lower = s.lowercased()
        if lower == "graveyard" { return .done }
        return TaskLane(rawValue: lower)
    }

    /// Display name. "done" shows as "graveyard" to match sidebar UI.
    public var display: String {
        switch self {
        case .done: return "graveyard"
        default: return rawValue
        }
    }

    /// Lane priority for sorted listing. Lower = higher priority.
    public var priority: Int {
        switch self {
        case .needsYou: return 0
        case .running:  return 1
        case .review:   return 2
        case .inbox:    return 3
        case .backlog:  return 4
        case .done:     return 5
        }
    }
}

/// On-disk task view. Only the fields we need for CLI operations — the sidebar
/// parses more detail but the CLI just shuffles lanes, titles, and notes.
public struct Task {
    public var id: String
    public var title: String
    public var lane: TaskLane
    public var project: String?
    public var source: String?
    public var sourceID: String?
    public var branch: String?
    /// Raw frontmatter key order + values. Preserved so round-trips don't
    /// reshuffle unrelated fields.
    public var frontmatter: [(String, String)]
    /// Full body (everything after the second `---`). Preserved verbatim.
    public var body: String

    public init(
        id: String,
        title: String,
        lane: TaskLane,
        project: String?,
        source: String?,
        sourceID: String?,
        branch: String?,
        frontmatter: [(String, String)],
        body: String
    ) {
        self.id = id
        self.title = title
        self.lane = lane
        self.project = project
        self.source = source
        self.sourceID = sourceID
        self.branch = branch
        self.frontmatter = frontmatter
        self.body = body
    }
}
