import Foundation
import OSLog

/// Reads and writes workspace state (projects) to a JSON file
/// at ~/Library/Application Support/Ghostties/workspace.json.
struct WorkspacePersistence {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.seansmithdesign.ghostties",
        category: "WorkspacePersistence"
    )

    /// The directory where workspace data is stored.
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ghostties", isDirectory: true)
    }

    private static var fileURL: URL {
        directory.appendingPathComponent("workspace.json")
    }

    // MARK: - Persistence Model

    /// Top-level container for everything we persist.
    ///
    /// Uses a custom `Decodable` init so that new fields (sessions, templates)
    /// are decoded with defaults when missing from older workspace.json files.
    /// Without this, adding a new field would fail to decode existing JSON and
    /// silently wipe the user's projects.
    struct State: Codable {
        var projects: [Project]
        var sessions: [AgentSession]
        var templates: [AgentTemplate]

        /// Sidebar mode when the app last saved state.
        /// `.overlay` is transient — always persisted as `.closed`.
        var sidebarMode: SidebarMode

        /// The last selected project ID, for restoring selection on launch.
        var lastSelectedProjectId: UUID?

        init(
            projects: [Project] = [],
            sessions: [AgentSession] = [],
            templates: [AgentTemplate] = [],
            sidebarMode: SidebarMode = .pinned,
            lastSelectedProjectId: UUID? = nil
        ) {
            self.projects = projects
            self.sessions = sessions
            self.templates = templates
            self.sidebarMode = sidebarMode
            self.lastSelectedProjectId = lastSelectedProjectId
        }

        private enum CodingKeys: String, CodingKey {
            case projects, sessions, templates, sidebarMode, lastSelectedProjectId
            // Legacy key for backward compatibility.
            case sidebarVisible
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
            self.sessions = try container.decodeIfPresent([AgentSession].self, forKey: .sessions) ?? []
            self.templates = try container.decodeIfPresent([AgentTemplate].self, forKey: .templates) ?? []
            self.lastSelectedProjectId = try container.decodeIfPresent(UUID.self, forKey: .lastSelectedProjectId)

            // Try new sidebarMode first; fall back to legacy sidebarVisible bool.
            // Decode as raw Int to avoid a DecodingError (and full state wipe) on
            // unknown raw values — gracefully fall through to the default instead.
            if let rawMode = try container.decodeIfPresent(Int.self, forKey: .sidebarMode),
               let mode = SidebarMode(rawValue: rawMode) {
                self.sidebarMode = mode
            } else if let visible = try container.decodeIfPresent(Bool.self, forKey: .sidebarVisible) {
                self.sidebarMode = visible ? .pinned : .closed
            } else {
                self.sidebarMode = .pinned
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(projects, forKey: .projects)
            try container.encode(sessions, forKey: .sessions)
            try container.encode(templates, forKey: .templates)
            // Overlay is transient — always persist as closed.
            let persistedMode = sidebarMode == .overlay ? SidebarMode.closed : sidebarMode
            try container.encode(persistedMode, forKey: .sidebarMode)
            try container.encodeIfPresent(lastSelectedProjectId, forKey: .lastSelectedProjectId)
            // Omit the legacy sidebarVisible key on new writes.
        }
    }

    // MARK: - Read / Write

    static func load() -> State {
        let url = fileURL
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(State.self, from: data)
            return validate(state)
        } catch is DecodingError {
            logger.error("Corrupted workspace.json, backing up and starting fresh")
            backupCorruptFile(at: url)
            return State()
        } catch {
            // File doesn't exist or can't be read — start fresh
            return State()
        }
    }

    /// Regex pattern matching valid CLI flags: single or double dash, then
    /// alphanumeric/underscore/hyphen identifier, with an optional =value suffix.
    /// Rejects shell metacharacters in flag names; restricts values to safe characters.
    private static let validFlagPattern = "^--?[a-zA-Z][a-zA-Z0-9_-]*(=[a-zA-Z0-9_./:@=-]+)?$"

    /// Sanitize a single template by stripping dangerous env keys and
    /// validating additionalFlags against an allowlist regex.
    ///
    /// Called both at load time (via `validate`) and at write time
    /// (via `WorkspaceStore.addTemplate` / `updateTemplate`).
    static func sanitizeTemplate(_ template: AgentTemplate) -> AgentTemplate {
        var sanitized = template

        // Strip dangerous env keys.
        let dangerousKeys = AgentTemplate.dangerousEnvKeys
        sanitized.environmentVariables = sanitized.environmentVariables
            .filter { !dangerousKeys.contains($0.key.uppercased()) }

        // Validate additionalFlags with allowlist regex.
        if var agent = sanitized.agent {
            agent.additionalFlags = (agent.additionalFlags ?? []).filter { flag in
                flag.range(of: validFlagPattern, options: .regularExpression) != nil
            }
            sanitized.agent = agent
        }

        return sanitized
    }

    /// Validates referential integrity of loaded state.
    static func validate(_ state: State) -> State {
        var validated = state

        // Remove sessions whose template no longer exists.
        // Include built-in defaults AND file-based preset IDs so sessions
        // referencing presets survive across app launches.
        let presetIds = PresetLoader.loadPresets().map(\.id)
        let knownTemplateIds = Set(state.templates.map(\.id))
            .union(AgentTemplate.defaults.map(\.id))
            .union(presetIds)
        validated.sessions = state.sessions.filter { session in
            knownTemplateIds.contains(session.templateId)
        }

        // Remove sessions whose project no longer exists.
        let knownProjectIds = Set(state.projects.map(\.id))
        validated.sessions = validated.sessions.filter { session in
            knownProjectIds.contains(session.projectId)
        }

        // Clear stale lastSelectedProjectId if the project was deleted.
        if let lastId = validated.lastSelectedProjectId,
           !knownProjectIds.contains(lastId) {
            validated.lastSelectedProjectId = nil
        }

        // Clear orphaned project-scoped templates whose project was deleted.
        validated.templates = validated.templates.filter { template in
            if let projectId = template.projectId {
                return knownProjectIds.contains(projectId)
            }
            return true
        }

        // Sanitize each template (env keys + flag allowlist).
        for i in validated.templates.indices {
            validated.templates[i] = Self.sanitizeTemplate(validated.templates[i])
        }

        return validated
    }

    /// Renames a corrupt workspace file so the user can recover data manually.
    private static func backupCorruptFile(at url: URL) {
        let backupURL = url.deletingPathExtension()
            .appendingPathExtension("corrupt.json")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: url, to: backupURL)
    }

    static func save(_ state: State) {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
            // Atomic write inherits default umask; restrict to owner-only.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            logger.error("Failed to save workspace state: \(error.localizedDescription)")
        }
    }
}
