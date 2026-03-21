import Foundation

/// An agent-first template for creating terminal sessions.
///
/// Every session is an "agent" — Shell is just an agent with no AI config.
/// Replaces SessionTemplate with support for Claude Code agent configuration
/// (system prompt, model, permissions) that rebuilds from template on every relaunch.
struct AgentTemplate: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var kind: Kind
    var isDefault: Bool
    var isGlobal: Bool
    var projectId: UUID?

    // Terminal config
    var command: String?
    var environmentVariables: [String: String]
    var workingDirectory: String?

    // Agent config (nil for .shell)
    var agent: AgentConfig?

    // MARK: - Kind

    /// The type of session this template creates.
    ///
    /// Uses String raw values for safe Codable persistence.
    /// Custom `init(from:)` decodes as raw String and falls back to `.shell`
    /// on unknown values — never throws, never wipes state.
    enum Kind: String, Codable, Hashable {
        case shell
        case claudeCode
        case custom

        // Safe decoder: decode as raw String, construct with init(rawValue:),
        // fall back to .shell on unknown values. Never throws, never wipes state.
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            self = Kind(rawValue: rawValue) ?? .shell
        }
    }

    // MARK: - AgentConfig

    /// Configuration for Claude Code agent sessions.
    ///
    /// All fields are optional — a minimal agent template needs only a command.
    struct AgentConfig: Codable, Hashable {
        var systemPromptFile: String?
        var model: String?
        var permissionMode: String?
        var effort: String?
        var allowedTools: [String]?
        var additionalFlags: [String]

        init(
            systemPromptFile: String? = nil,
            model: String? = nil,
            permissionMode: String? = nil,
            effort: String? = nil,
            allowedTools: [String]? = nil,
            additionalFlags: [String] = []
        ) {
            self.systemPromptFile = systemPromptFile
            self.model = model
            self.permissionMode = permissionMode
            self.effort = effort
            self.allowedTools = allowedTools
            self.additionalFlags = additionalFlags
        }

        // Custom decoder so all fields degrade gracefully when missing.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.systemPromptFile = try container.decodeIfPresent(String.self, forKey: .systemPromptFile)
            self.model = try container.decodeIfPresent(String.self, forKey: .model)
            self.permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
            self.effort = try container.decodeIfPresent(String.self, forKey: .effort)
            self.allowedTools = try container.decodeIfPresent([String].self, forKey: .allowedTools)
            self.additionalFlags = try container.decodeIfPresent([String].self, forKey: .additionalFlags) ?? []
        }
    }

    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        command: String? = nil,
        environmentVariables: [String: String] = [:],
        workingDirectory: String? = nil,
        isDefault: Bool = false,
        isGlobal: Bool = true,
        projectId: UUID? = nil,
        agent: AgentConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.command = command
        self.environmentVariables = environmentVariables
        self.workingDirectory = workingDirectory
        self.isDefault = isDefault
        self.isGlobal = isGlobal
        self.projectId = projectId
        self.agent = agent
    }

    // MARK: - Built-in Templates (deterministic UUIDs)

    /// Default shell session — uses the user's login shell.
    static let shell = AgentTemplate(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Shell",
        kind: .shell,
        isDefault: true,
        isGlobal: true
    )

    /// Claude Code agent session.
    static let claudeCode = AgentTemplate(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "Claude Code",
        kind: .claudeCode,
        command: "claude",
        isDefault: true,
        isGlobal: true
    )

    /// Orchestrator agent — Claude Code with system prompt and opus model.
    static let orchestrator = AgentTemplate(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Orchestrator",
        kind: .claudeCode,
        command: "claude",
        isDefault: true,
        isGlobal: true,
        agent: AgentConfig(
            systemPromptFile: "~/.claude/orchestrator-prompt.md",
            model: "opus"
        )
    )

    /// All built-in templates, in display order.
    static let defaults: [AgentTemplate] = [shell, claudeCode, orchestrator]

    // MARK: - CLI Construction

    /// Build the full CLI string for launching this template.
    ///
    /// Starts with the command (or empty string for shell), then appends
    /// agent config flags. Prompt file contents are read from disk and
    /// shell-escaped with single quotes.
    func buildCommand() -> String {
        var parts: [String] = []

        if let command {
            parts.append(command)
        }

        guard let agent else {
            return parts.joined(separator: " ")
        }

        if let model = agent.model {
            parts.append("--model")
            parts.append(model)
        }

        if let promptFile = agent.systemPromptFile {
            let expandedPath = (promptFile as NSString).expandingTildeInPath
            if let contents = try? String(contentsOfFile: expandedPath, encoding: .utf8) {
                parts.append("--append-system-prompt")
                // Shell-escape: wrap in single quotes, escape internal single quotes.
                let escaped = contents.replacingOccurrences(of: "'", with: "'\\''")
                parts.append("'\(escaped)'")
            }
        }

        if let permissionMode = agent.permissionMode {
            parts.append("--permission-mode")
            parts.append(permissionMode)
        }

        if let effort = agent.effort {
            parts.append("--effort")
            parts.append(effort)
        }

        if let allowedTools = agent.allowedTools, !allowedTools.isEmpty {
            parts.append("--allowedTools")
            parts.append(allowedTools.joined(separator: ","))
        }

        parts.append(contentsOf: agent.additionalFlags)

        return parts.joined(separator: " ")
    }

    // MARK: - Custom Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, isDefault, isGlobal, projectId
        case command, environmentVariables, workingDirectory
        case agent
    }

    /// Custom decoder for backward compatibility with old SessionTemplate JSON.
    ///
    /// Handles two formats:
    /// 1. New format: `kind`, `agent`, `projectId`, `isGlobal` fields present
    /// 2. Old SessionTemplate format: flat command/envVars, no kind/agent
    ///
    /// Migration: command == nil -> .shell, command == "claude" -> .claudeCode, else -> .custom
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.command = try container.decodeIfPresent(String.self, forKey: .command)
        self.environmentVariables = try container.decodeIfPresent([String: String].self, forKey: .environmentVariables) ?? [:]
        self.workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        self.isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        self.isGlobal = try container.decodeIfPresent(Bool.self, forKey: .isGlobal) ?? true
        self.projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId)
        self.agent = try container.decodeIfPresent(AgentConfig.self, forKey: .agent)

        // Decode Kind safely: raw String first, then construct with init(rawValue:),
        // fall back to inference from command on unknown values.
        // This follows the safe Codable enum pattern from the codebase — never throws,
        // never wipes state on unknown raw values.
        if let rawKind = try container.decodeIfPresent(String.self, forKey: .kind),
           let decodedKind = Kind(rawValue: rawKind) {
            self.kind = decodedKind
        } else if container.contains(.kind) {
            // Kind key present but unknown value — fall back to .shell
            self.kind = .shell
        } else {
            // No kind key at all — old SessionTemplate format.
            // Infer from command.
            if command == nil {
                self.kind = .shell
            } else if command == "claude" {
                self.kind = .claudeCode
            } else {
                self.kind = .custom
            }
        }
    }
}
