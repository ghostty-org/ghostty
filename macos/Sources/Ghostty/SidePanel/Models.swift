import Foundation

enum CardStatus: String, Codable, CaseIterable {
    case todo = "todo"
    case inProgress = "in_progress"
    case review = "review"
    case done = "done"

    var title: String {
        switch self {
        case .todo: return "Todo"
        case .inProgress: return "In Progress"
        case .review: return "Review"
        case .done: return "Done"
        }
    }
}

enum Priority: Int, Codable, CaseIterable {
    case p0 = 0, p1 = 1, p2 = 2, p3 = 3
}

struct Session: Codable, Identifiable {
    let id: String
    var name: String
    var cwd: String
    var command: String
    var splitId: String?
    var isWorktree: Bool
    var worktreeName: String?
}

struct Card: Codable, Identifiable {
    let id: String
    var title: String
    var description: String
    var status: CardStatus
    var priority: Priority
    var sessions: [Session]
    var isExpanded: Bool = false
}

struct Project: Codable, Identifiable {
    let id: String
    var name: String
    var cards: [Card]
}