import Foundation

enum TerminalAgentActivityState: Equatable {
    case idle
    case running(agent: String)
    case needsInput(agent: String)
    case error(agent: String)

    var agent: String? {
        switch self {
        case .idle:
            nil
        case .running(let agent), .needsInput(let agent), .error(let agent):
            agent
        }
    }
}

enum TerminalSidebarStatusIndicatorState: Equatable {
    case none
    case spinner(agent: String)
    case bell(agent: String)
    case error(agent: String)

    var accessibilityDescription: String? {
        switch self {
        case .none:
            nil
        case .spinner(let agent):
            "\(Self.displayName(for: agent)) running"
        case .bell(let agent):
            agent == "terminal" ? "Terminal bell" : "\(Self.displayName(for: agent)) needs input"
        case .error(let agent):
            "\(Self.displayName(for: agent)) error"
        }
    }

    var isAttentionIndicator: Bool {
        switch self {
        case .bell, .error:
            true
        case .none, .spinner:
            false
        }
    }

    func visibleState(isSelected: Bool) -> TerminalSidebarStatusIndicatorState {
        isSelected && isAttentionIndicator ? .none : self
    }

    static func derive(
        from states: [TerminalAgentActivityState],
        hasTerminalProgress: Bool,
        hasTerminalBell: Bool
    ) -> TerminalSidebarStatusIndicatorState {
        for state in states {
            if case .running(let agent) = state {
                return .spinner(agent: agent)
            }
        }

        for state in states {
            if case .error(let agent) = state {
                return .error(agent: agent)
            }
        }

        for state in states {
            if case .needsInput(let agent) = state {
                return .bell(agent: agent)
            }
        }

        if hasTerminalProgress {
            return .spinner(agent: "terminal")
        }

        if hasTerminalBell {
            return .bell(agent: "terminal")
        }

        return .none
    }

    private static func displayName(for agent: String) -> String {
        switch agent.lowercased() {
        case "claude":
            "Claude"
        case "codex":
            "Codex"
        case "terminal":
            "Terminal"
        default:
            agent
        }
    }
}

struct TerminalAgentActivityEvent: Decodable, Equatable {
    let version: Int?
    let surfaceID: String?
    let agent: String
    let event: String?
    let state: String?
    let statusTitle: String?
    let statusValue: String?
    let sessionID: String?
    let turnID: String?
    let pid: Int?
    let timestamp: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case version
        case surfaceID = "surface_id"
        case agent
        case event
        case state
        case statusTitle = "status_title"
        case statusValue = "status_value"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case pid
        case timestamp
    }

    enum AlternateCodingKeys: String, CodingKey {
        case surfaceId
        case statusTitle
        case statusValue
        case sessionId
        case turnId
    }

    init(
        version: Int? = 1,
        surfaceID: String?,
        agent: String,
        event: String?,
        state: String?,
        statusTitle: String? = nil,
        statusValue: String? = nil,
        sessionID: String? = nil,
        turnID: String? = nil,
        pid: Int? = nil,
        timestamp: TimeInterval? = nil
    ) {
        self.version = version
        self.surfaceID = surfaceID
        self.agent = agent
        self.event = event
        self.state = state
        self.statusTitle = statusTitle
        self.statusValue = statusValue
        self.sessionID = sessionID
        self.turnID = turnID
        self.pid = pid
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let alternate = try decoder.container(keyedBy: AlternateCodingKeys.self)

        self.version = try container.decodeIfPresent(Int.self, forKey: .version)
        self.surfaceID = try container.decodeIfPresent(String.self, forKey: .surfaceID)
            ?? alternate.decodeIfPresent(String.self, forKey: .surfaceId)
        self.agent = try container.decode(String.self, forKey: .agent)
        self.event = try container.decodeIfPresent(String.self, forKey: .event)
        self.state = try container.decodeIfPresent(String.self, forKey: .state)
        self.statusTitle = try container.decodeIfPresent(String.self, forKey: .statusTitle)
            ?? alternate.decodeIfPresent(String.self, forKey: .statusTitle)
        self.statusValue = try container.decodeIfPresent(String.self, forKey: .statusValue)
            ?? alternate.decodeIfPresent(String.self, forKey: .statusValue)
        self.sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            ?? alternate.decodeIfPresent(String.self, forKey: .sessionId)
        self.turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
            ?? alternate.decodeIfPresent(String.self, forKey: .turnId)
        self.pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        self.timestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .timestamp)
    }

    static func parse(jsonLine line: String) -> TerminalAgentActivityEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TerminalAgentActivityEvent.self, from: data)
    }
}

struct TerminalAgentActivityReducer {
    static let runningTTL: TimeInterval = 6 * 60 * 60

    private(set) var state: TerminalAgentActivityState = .idle
    private var activeSessionIDByAgent: [String: String] = [:]
    private var runningStartedAt: Date?

    mutating func apply(
        _ event: TerminalAgentActivityEvent,
        expectedSurfaceID: String? = nil,
        now: Date = Date()
    ) -> TerminalAgentActivityState? {
        if let expectedSurfaceID,
           let eventSurfaceID = event.surfaceID,
           eventSurfaceID != expectedSurfaceID {
            return nil
        }

        let agent = event.agent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !agent.isEmpty else { return nil }
        guard let nextState = Self.state(from: event, agent: agent) else { return nil }

        if Self.isSessionBoundaryEvent(event),
           let sessionID = Self.normalized(event.sessionID),
           let activeSessionID = activeSessionIDByAgent[agent],
           activeSessionID != sessionID {
            return nil
        }

        if let sessionID = Self.normalized(event.sessionID), Self.startsOrContinuesSession(nextState) {
            activeSessionIDByAgent[agent] = sessionID
        }

        switch nextState {
        case .idle:
            activeSessionIDByAgent[agent] = nil
            guard state.agent == nil || state.agent == agent else { return state }
            state = .idle
            runningStartedAt = nil

        case .running:
            state = nextState
            runningStartedAt = now

        case .needsInput, .error:
            state = nextState
            runningStartedAt = nil
        }

        return state
    }

    mutating func acknowledgeAttention() -> TerminalAgentActivityState? {
        switch state {
        case .needsInput(let agent), .error(let agent):
            activeSessionIDByAgent[agent] = nil
            state = .idle
            runningStartedAt = nil
            return state

        case .idle, .running:
            return nil
        }
    }

    mutating func expireRunningState(now: Date = Date()) -> TerminalAgentActivityState? {
        guard case .running = state,
              let runningStartedAt,
              now.timeIntervalSince(runningStartedAt) >= Self.runningTTL
        else {
            return nil
        }

        state = .idle
        self.runningStartedAt = nil
        return state
    }

    private static func state(
        from event: TerminalAgentActivityEvent,
        agent: String
    ) -> TerminalAgentActivityState? {
        if normalized(event.event) == "stop" {
            return .needsInput(agent: agent)
        }

        if let state = normalized(event.state) {
            switch state {
            case "running":
                return .running(agent: agent)
            case "needsinput", "needs-input", "needs_input":
                return .needsInput(agent: agent)
            case "error":
                return .error(agent: agent)
            case "idle":
                return .idle
            default:
                return nil
            }
        }

        switch normalized(event.event) {
        case "session-start":
            return .idle
        case "prompt-submit", "user-prompt-submit", "pre-tool-use":
            return .running(agent: agent)
        case "notification", "permission-request", "ask-user-question":
            return .needsInput(agent: agent)
        case "stop":
            return .needsInput(agent: agent)
        case "idle", "session-end":
            return .idle
        case "error", "failure", "failed", "hook-error":
            return .error(agent: agent)
        default:
            return nil
        }
    }

    private static func startsOrContinuesSession(_ state: TerminalAgentActivityState) -> Bool {
        switch state {
        case .idle:
            false
        case .running, .needsInput, .error:
            true
        }
    }

    private static func isSessionBoundaryEvent(_ event: TerminalAgentActivityEvent) -> Bool {
        switch normalized(event.event) {
        case "stop", "idle", "session-end":
            true
        default:
            false
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }
}
