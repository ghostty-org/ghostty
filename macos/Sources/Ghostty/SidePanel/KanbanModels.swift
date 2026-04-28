import Foundation

// MARK: - Priority

enum Priority: String, Codable, CaseIterable, Identifiable {
    case p0, p1, p2, p3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .p0: return "P0"
        case .p1: return "P1"
        case .p2: return "P2"
        case .p3: return "P3"
        }
    }
}

// MARK: - Status

enum Status: String, Codable, CaseIterable, Identifiable {
    case todo, inProgress, review, done

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .todo: return "Todo"
        case .inProgress: return "In Progress"
        case .review: return "Review"
        case .done: return "Done"
        }
    }
}

// MARK: - SessionStatus

enum SessionStatus: String, Codable {
    case running, idle, needInput
}

// MARK: - Session

struct Session: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var status: SessionStatus
    var timestamp: Date
    var isWorkTree: Bool
    var branch: String
    var sessionId: String?      // Claude session UUID from JSONL
    var surfaceId: UInt64?      // Ghostty surface ID (nil if split closed)
    var cwd: String?

    init(id: UUID = UUID(), title: String, status: SessionStatus = .running, timestamp: Date = Date(), isWorkTree: Bool = false, branch: String = "main", sessionId: String? = nil, surfaceId: UInt64? = nil, cwd: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.timestamp = timestamp
        self.isWorkTree = isWorkTree
        self.branch = branch
        self.sessionId = sessionId
        self.surfaceId = surfaceId
        self.cwd = cwd
    }

    var relativeTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }
}

// MARK: - KanbanTask

struct KanbanTask: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var description: String
    var priority: Priority
    var status: Status
    var sessions: [Session]
    var isExpanded: Bool

    init(id: UUID = UUID(), title: String, description: String = "", priority: Priority = .p2, status: Status = .todo, sessions: [Session] = [], isExpanded: Bool = false) {
        self.id = id
        self.title = title
        self.description = description
        self.priority = priority
        self.status = status
        self.sessions = sessions
        self.isExpanded = isExpanded
    }
}
