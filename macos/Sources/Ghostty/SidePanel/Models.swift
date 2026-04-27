import Foundation

enum CardStatus: String, Codable, CaseIterable, Hashable {
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

enum Priority: Int, Codable, CaseIterable, Hashable {
    case p0 = 0, p1 = 1, p2 = 2, p3 = 3

    var title: String {
        switch self {
        case .p0: return "P0"
        case .p1: return "P1"
        case .p2: return "P2"
        case .p3: return "P3"
        }
    }
}

enum SessionStatus: String, Codable {
    case running = "running"
    case idle = "idle"
    case needInput = "need-input"
}

struct Session: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String = ""
    var cwd: String = ""
    var command: String = ""
    var splitId: String?
    var isWorktree: Bool = false
    var worktreeName: String?
    var status: SessionStatus = .idle
    var timestamp: Date? = nil
    var branch: String? = nil
}

struct Card: Codable, Identifiable {
    var id: String = UUID().uuidString
    var title: String = ""
    var description: String = ""
    var status: CardStatus = .todo
    var priority: Priority = .p2
    var sessions: [Session] = []
    var isExpanded: Bool = false
}

struct Project: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String = ""
    var cards: [Card] = []
}