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

    /// Minimum width for a single kanban column
    static let columnMinWidth: CGFloat = 300
    /// Maximum width for a single kanban column
    static let columnMaxWidth: CGFloat = 400
    /// Horizontal padding around the column HStack (left + right)
    static let columnHPadding: CGFloat = 12

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
    var tabID: UUID?            // TerminalTabManager tab ID (nil if closed)
    var cwd: String?

    init(id: UUID = UUID(), title: String, status: SessionStatus = .running, timestamp: Date = Date(), isWorkTree: Bool = false, branch: String = "main", sessionId: String? = nil, tabID: UUID? = nil, cwd: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.timestamp = timestamp
        self.isWorkTree = isWorkTree
        self.branch = branch
        self.sessionId = sessionId
        self.tabID = tabID
        self.cwd = cwd
    }

    var relativeTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }
}

// MARK: - Tag

enum Tag: String, Codable, CaseIterable, Identifiable {
    case bug, feat, docs, refac, test, ui, sec, perf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bug: return "Bug"
        case .feat: return "Feat"
        case .docs: return "Docs"
        case .refac: return "Refac"
        case .test: return "Test"
        case .ui: return "UI"
        case .sec: return "Sec"
        case .perf: return "Perf"
        }
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
    var tags: [Tag] = []
    var isExpanded: Bool

    init(id: UUID = UUID(), title: String, description: String = "", priority: Priority = .p2, status: Status = .todo, sessions: [Session] = [], tags: [Tag] = [], isExpanded: Bool = false) {
        self.id = id
        self.title = title
        self.description = description
        self.priority = priority
        self.status = status
        self.sessions = sessions
        self.tags = tags
        self.isExpanded = isExpanded
    }
}
