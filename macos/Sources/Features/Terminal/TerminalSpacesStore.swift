import AppKit

/// Vends a single shared `SpacesModel` per macOS tab-group so that every
/// tab's sidebar in a group observes the same spaces and active space.
/// State is session-only; models are held for the process lifetime.
@MainActor
final class TerminalSpacesStore {
    static let shared = TerminalSpacesStore()

    private var models: [ObjectIdentifier: SpacesModel] = [:]

    /// Internal (not private) so unit tests can create isolated instances.
    init() {}

    func model(for window: NSWindow) -> SpacesModel {
        let key = window.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(window)
        return model(forKey: key)
    }

    func model(forKey key: ObjectIdentifier) -> SpacesModel {
        if let existing = models[key] { return existing }
        let model = SpacesModel(defaultSpace: Space(name: "Space 1"))
        models[key] = model
        return model
    }
}
