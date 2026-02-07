import Foundation

enum WorktrunkAgent: String, CaseIterable, Identifiable {
    case claude
    case codex
    case opencode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }

    var command: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .opencode: return "opencode"
        }
    }

    var isAvailable: Bool {
        Self.isExecutableAvailable(command)
    }

    static func availableAgents() -> [WorktrunkAgent] {
        allCases.filter { $0.isAvailable }
    }

    static func preferredAgent(from rawValue: String, availableAgents: [WorktrunkAgent]) -> WorktrunkAgent? {
        if let preferred = WorktrunkAgent(rawValue: rawValue),
           availableAgents.contains(preferred) {
            return preferred
        }
        return availableAgents.first
    }

    private static func isExecutableAvailable(_ name: String) -> Bool {
        let binDir = AgentStatusPaths.binDir.path
        for path in searchPaths(excluding: binDir) {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return true
            }
        }
        return false
    }

    private static func searchPaths(excluding excludedPath: String) -> [String] {
        var paths: [String] = []
        let prefix = ["/opt/homebrew/bin", "/usr/local/bin"]
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let existingComponents = existingPath.split(separator: ":").map(String.init)

        for path in prefix + existingComponents {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
            guard normalized != excludedPath else { continue }
            if !paths.contains(normalized) {
                paths.append(normalized)
            }
        }

        return paths
    }
}

enum WorktrunkDefaultAction: String, CaseIterable, Identifiable {
    case terminal
    case claude
    case codex
    case opencode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }

    var agent: WorktrunkAgent? {
        switch self {
        case .terminal: return nil
        case .claude: return .claude
        case .codex: return .codex
        case .opencode: return .opencode
        }
    }

    var isAvailable: Bool {
        switch self {
        case .terminal: return true
        default: return agent?.isAvailable ?? false
        }
    }

    static func availableActions() -> [WorktrunkDefaultAction] {
        allCases.filter { $0.isAvailable }
    }

    static func preferredAction(from rawValue: String, availableActions: [WorktrunkDefaultAction]) -> WorktrunkDefaultAction {
        if let preferred = WorktrunkDefaultAction(rawValue: rawValue),
           availableActions.contains(preferred) {
            return preferred
        }
        return .terminal
    }
}

enum WorktrunkOpenBehavior: String, CaseIterable, Identifiable {
    case newTab = "new_tab"
    case splitRight = "split_right"
    case splitDown = "split_down"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTab: return "New Tab"
        case .splitRight: return "Split Right"
        case .splitDown: return "Split Down"
        }
    }
}

enum WorktrunkPreferences {
    static let openBehaviorKey = "GhosttyWorktrunkOpenBehavior.v1"
    static let worktreeTabsKey = "GhosttyWorktreeTabs.v1"
    static let sidebarTabsKey = "GhostreeWorktrunkSidebarTabs.v1"
    static let defaultAgentKey = "GhosttyWorktrunkDefaultAgent.v1"
    static let githubIntegrationKey = "GhostreeGitHubIntegration.v1"

    static var worktreeTabsEnabled: Bool {
        UserDefaults.standard.bool(forKey: worktreeTabsKey)
    }

    static var sidebarTabsEnabled: Bool {
        UserDefaults.standard.bool(forKey: sidebarTabsKey)
    }

    static var githubIntegrationEnabled: Bool {
        // Default to true if gh CLI is likely available
        if !UserDefaults.standard.dictionaryRepresentation().keys.contains(githubIntegrationKey) {
            return true  // Default enabled
        }
        return UserDefaults.standard.bool(forKey: githubIntegrationKey)
    }
}
