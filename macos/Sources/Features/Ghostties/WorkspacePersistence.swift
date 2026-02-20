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
        var templates: [SessionTemplate]

        init(
            projects: [Project] = [],
            sessions: [AgentSession] = [],
            templates: [SessionTemplate] = []
        ) {
            self.projects = projects
            self.sessions = sessions
            self.templates = templates
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
            self.sessions = try container.decodeIfPresent([AgentSession].self, forKey: .sessions) ?? []
            self.templates = try container.decodeIfPresent([SessionTemplate].self, forKey: .templates) ?? []
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
        } catch let error as DecodingError {
            logger.error("Corrupted workspace.json, backing up and starting fresh")
            backupCorruptFile(at: url)
            return State()
        } catch {
            // File doesn't exist or can't be read — start fresh
            return State()
        }
    }

    /// Validates referential integrity of loaded state.
    private static func validate(_ state: State) -> State {
        var validated = state

        // Remove sessions whose template no longer exists.
        let knownTemplateIds = Set(state.templates.map(\.id))
            .union(SessionTemplate.defaults.map(\.id))
        validated.sessions = state.sessions.filter { session in
            knownTemplateIds.contains(session.templateId)
        }

        // Remove sessions whose project no longer exists.
        let knownProjectIds = Set(state.projects.map(\.id))
        validated.sessions = validated.sessions.filter { session in
            knownProjectIds.contains(session.projectId)
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
