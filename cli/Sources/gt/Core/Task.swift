import Foundation

/// Status lanes — raw values match what the macOS app writes and reads in
/// `status:` frontmatter. "graveyard" is the UI name for `done` but the
/// on-disk value must stay `done` so the app parses it.
enum TaskLane: String, CaseIterable {
    case inbox
    case backlog
    case running
    case needsYou = "needs-you"
    case review
    case done

    /// Accept "graveyard" as an alias for "done" on input only. Never written.
    static func parse(_ s: String) -> TaskLane? {
        let lower = s.lowercased()
        if lower == "graveyard" { return .done }
        return TaskLane(rawValue: lower)
    }

    /// Display name. "done" shows as "graveyard" to match sidebar UI.
    var display: String {
        switch self {
        case .done: return "graveyard"
        default: return rawValue
        }
    }

    /// Lane priority for sorted listing. Lower = higher priority.
    var priority: Int {
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
struct Task {
    var id: String
    var title: String
    var lane: TaskLane
    var project: String?
    var source: String?
    var sourceID: String?
    var branch: String?
    /// Raw frontmatter key order + values. Preserved so round-trips don't
    /// reshuffle unrelated fields.
    var frontmatter: [(String, String)]
    /// Full body (everything after the second `---`). Preserved verbatim.
    var body: String
}
