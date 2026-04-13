import Foundation

/// A workspace project representing a directory the user has pinned.
struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var rootPath: String
    var isPinned: Bool

    /// The pixel-art ghost character displayed in the icon rail.
    /// Nil means the project predates the ghost system (shows initial fallback).
    var ghostCharacter: GhostCharacter?

    /// The default template to use when creating sessions with a single click.
    /// Nil means always show the template picker.
    var defaultTemplateId: UUID?

    /// The last moment any session in this project produced output, was focused,
    /// or was created. Drives the "Recent" smart-section membership rule.
    /// Nil means this project predates the timestamp system or has never been touched.
    var lastActiveAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        isPinned: Bool = false,
        ghostCharacter: GhostCharacter? = nil,
        defaultTemplateId: UUID? = nil,
        lastActiveAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.isPinned = isPinned
        self.ghostCharacter = ghostCharacter
        self.defaultTemplateId = defaultTemplateId
        self.lastActiveAt = lastActiveAt
    }

    // Custom decoder so existing workspace.json files (without ghost/template/timestamp
    // fields) load without error. New fields default to nil when missing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.rootPath = try container.decode(String.self, forKey: .rootPath)
        self.isPinned = try container.decode(Bool.self, forKey: .isPinned)
        self.ghostCharacter = try container.decodeIfPresent(GhostCharacter.self, forKey: .ghostCharacter)
        self.defaultTemplateId = try container.decodeIfPresent(UUID.self, forKey: .defaultTemplateId)
        self.lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt)
    }
}
