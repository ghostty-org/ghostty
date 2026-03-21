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
        var systemPromptFile: String? = nil
        var model: String? = nil
        var permissionMode: String? = nil
        var effort: String? = nil
        var allowedTools: [String]? = nil
        var additionalFlags: [String]? = nil
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

    /// Shell-escape a value by wrapping in single quotes with internal quote escaping.
    private static func shellEscape(_ value: String) -> String {
        let escaped = value.contains("'") ? value.replacingOccurrences(of: "'", with: "'\\''") : value
        return "'\(escaped)'"
    }

    /// Maximum file size (1 MB) for systemPromptFile contents.
    private static let maxPromptFileSize = 1_048_576

    /// Build the full CLI string for launching this template.
    ///
    /// Starts with the command (or empty string for shell), then appends
    /// agent config flags. All values are shell-escaped with single quotes.
    /// Prompt file contents are read from disk with a 1 MB size cap.
    func buildCommand() -> String {
        var parts: [String] = []

        if let command {
            // Don't shell-escape the command name — it needs to be resolved
            // via PATH by the coordinator. Only values are escaped.
            parts.append(command)
        }

        guard let agent else {
            return parts.joined(separator: " ")
        }

        if let model = agent.model {
            parts.append("--model")
            parts.append(Self.shellEscape(model))
        }

        if let promptFile = agent.systemPromptFile {
            let expandedPath = (promptFile as NSString).expandingTildeInPath
            let attrs = try? FileManager.default.attributesOfItem(atPath: expandedPath)
            let fileSize = attrs?[.size] as? Int ?? 0
            if fileSize > Self.maxPromptFileSize {
                print("[AgentTemplate] Skipping systemPromptFile: file too large (\(fileSize) bytes > \(Self.maxPromptFileSize))")
            } else if let contents = try? String(contentsOfFile: expandedPath, encoding: .utf8) {
                parts.append("--append-system-prompt")
                parts.append(Self.shellEscape(contents))
            } else {
                print("[AgentTemplate] Skipping systemPromptFile: file not found or unreadable at \(expandedPath)")
            }
        }

        if let permissionMode = agent.permissionMode {
            parts.append("--permission-mode")
            parts.append(Self.shellEscape(permissionMode))
        }

        if let effort = agent.effort {
            parts.append("--effort")
            parts.append(Self.shellEscape(effort))
        }

        if let allowedTools = agent.allowedTools, !allowedTools.isEmpty {
            parts.append("--allowedTools")
            parts.append(Self.shellEscape(allowedTools.joined(separator: ",")))
        }

        for flag in agent.additionalFlags ?? [] {
            parts.append(Self.shellEscape(flag))
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Environment Safety

    /// Environment variable keys that should be stripped from loaded templates.
    ///
    /// Shared constant — used by WorkspacePersistence and any other validation sites.
    static let dangerousEnvKeys: Set<String> = [
        "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH",
        "LD_PRELOAD", "LD_LIBRARY_PATH",
        "PATH", "HOME", "SHELL", "USER", "LOGNAME",
        "PYTHONPATH", "NODE_PATH", "RUBYLIB", "GEM_HOME", "GEM_PATH",
    ]

    // MARK: - Copying

    /// Return a copy of this template with agent config removed.
    ///
    /// Preserves all other fields. Safer than manual field-by-field copy
    /// because new fields are automatically included.
    func withoutAgent() -> AgentTemplate {
        var copy = self
        copy.agent = nil
        return copy
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

        // Decode Kind using Kind's own safe decoder (falls back to .shell on unknown values).
        // Only handle nil case for old SessionTemplate migration.
        if let decoded = try container.decodeIfPresent(Kind.self, forKey: .kind) {
            self.kind = decoded
        } else {
            // Old SessionTemplate format — infer kind from command
            switch self.command {
            case nil: self.kind = .shell
            case "claude": self.kind = .claudeCode
            default: self.kind = .custom
            }
        }
    }
}
