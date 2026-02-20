import Foundation

/// A reusable template for creating terminal sessions within a project.
///
/// Templates define the command, environment, and display name for a session type.
/// Each project starts with default templates (Shell, Claude Code) and users can
/// add custom ones in a future phase.
struct SessionTemplate: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String

    /// The command to run. Nil means use the user's default shell.
    var command: String?

    /// Additional environment variables merged into the session.
    var environmentVariables: [String: String]

    /// Whether this is a built-in default template (not user-deletable).
    var isDefault: Bool

    init(
        id: UUID = UUID(),
        name: String,
        command: String? = nil,
        environmentVariables: [String: String] = [:],
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.environmentVariables = environmentVariables
        self.isDefault = isDefault
    }

    // MARK: - Built-in Templates

    /// Default shell session — uses the user's login shell.
    /// Uses a deterministic UUID so persisted sessions can find this template across launches.
    static let shell = SessionTemplate(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Shell",
        isDefault: true
    )

    /// Claude Code agent session.
    /// Uses a deterministic UUID so persisted sessions can find this template across launches.
    static let claudeCode = SessionTemplate(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "Claude Code",
        command: "claude",
        isDefault: true
    )

    /// All built-in templates, in display order.
    static let defaults: [SessionTemplate] = [shell, claudeCode]
}
