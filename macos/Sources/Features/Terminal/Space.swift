import Foundation

/// A user-defined group of tabs in the sidebar. Identity is an SF Symbol name
/// (rendered monochrome via `Image(systemName:)`) plus a name.
struct Space: Identifiable, Equatable {
    /// SF Symbol used when none is specified.
    static let defaultIcon = "bolt.fill"

    let id: UUID
    var name: String
    /// SF Symbol name, e.g. "folder.fill".
    var icon: String

    init(id: UUID = UUID(), name: String, icon: String = Space.defaultIcon) {
        self.id = id
        self.name = name
        self.icon = icon.isEmpty ? Space.defaultIcon : icon
    }
}
