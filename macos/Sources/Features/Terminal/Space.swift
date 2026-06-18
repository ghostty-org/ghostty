import Foundation

/// A user-defined group of tabs in the sidebar. Identity is an icon
/// (free text, typically an emoji, at most ten grapheme clusters) plus a name.
struct Space: Identifiable, Equatable {
    let id: UUID
    var name: String
    var icon: String

    init(id: UUID = UUID(), name: String, icon: String) {
        self.id = id
        self.name = name
        self.icon = Space.clampIcon(icon)
    }

    /// Clamp a free-text icon to at most ten grapheme clusters (emoji-safe),
    /// trimming surrounding whitespace. Empty input falls back to a bullet.
    static func clampIcon(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "•" }
        return String(trimmed.prefix(10))
    }
}
