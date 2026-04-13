import Foundation

/// Persistent metadata for a terminal session.
///
/// This is the Codable record stored in workspace.json. Runtime state (the actual
/// SurfaceView reference, live status) lives in SessionCoordinator and is NOT persisted.
///
/// On app restart, previously active sessions appear as "Exited" with a relaunch option.
struct AgentSession: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var templateId: UUID
    var projectId: UUID

    /// Explicit ordering within a project. Nil means this session predates
    /// drag-and-drop reorder and will be sorted alphabetically.
    var sortOrder: Int?

    /// The last moment this session produced output, was focused, or transitioned
    /// out of idle. Drives the session-level "Recent" bucket inside an expanded project.
    /// Nil means this session predates the timestamp system or has never been touched.
    var lastActiveAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        templateId: UUID,
        projectId: UUID,
        sortOrder: Int? = nil,
        lastActiveAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.templateId = templateId
        self.projectId = projectId
        self.sortOrder = sortOrder
        self.lastActiveAt = lastActiveAt
    }

    // Custom decoder so existing workspace.json files (without sortOrder/lastActiveAt)
    // load without error.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.templateId = try container.decode(UUID.self, forKey: .templateId)
        self.projectId = try container.decode(UUID.self, forKey: .projectId)
        self.sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder)
        self.lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt)
    }
}

// MARK: - Runtime State

/// Live status of a running session. Not persisted.
enum SessionStatus: Equatable {
    /// Process is alive and running.
    case running
    /// Process exited naturally (process_alive was false when surface closed).
    case exited
    /// Command completed successfully (exit code 0).
    case completed
    /// Command failed with a non-zero exit code.
    case error(exitCode: Int16)
    /// Surface was closed while the process was still running (force-killed by user).
    case killed

    /// Whether the underlying process is still alive.
    var isAlive: Bool {
        switch self {
        case .running: return true
        case .exited, .completed, .error, .killed: return false
        }
    }
}

// MARK: - Indicator State

/// View-layer state combining lifecycle status + output activity + prompt state.
///
/// `SessionStatus` tracks *what happened* to the process. This enum tracks
/// *what the user should see* — it folds in output recency and shell prompt signals
/// so the ghost indicator can distinguish seven distinct visual states.
///
/// Conforms to `Comparable` so project headers can aggregate by priority.
/// States needing user attention (`needsAttention`, `waiting`) rank highest below `error`.
enum SessionIndicatorState: Comparable {
    case inactive       // exited/completed/killed — collapsed, outline ghost
    case idle           // at shell prompt, nothing to do
    case processing     // actively producing output
    case longRunning    // processing for 30+ min continuously
    case waiting        // silent, not at shell prompt (subprocess may be running)
    case needsAttention // agent blocked on user input (permission prompt, question)
    case error

    /// The priority for aggregation — higher value wins in project headers.
    private var priority: Int {
        switch self {
        case .inactive:       return 0
        case .idle:           return 1
        case .processing:     return 2
        case .longRunning:    return 3
        case .waiting:        return 4
        case .needsAttention: return 5
        case .error:          return 6
        }
    }

    static func < (lhs: SessionIndicatorState, rhs: SessionIndicatorState) -> Bool {
        lhs.priority < rhs.priority
    }
}
