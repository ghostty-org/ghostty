import AppKit

/// Vends a single shared `SpacesModel` per macOS tab-group so that every
/// tab's sidebar in a group observes the same spaces and active space.
///
/// State is session-only. Models are keyed by the live tab-group (or, for a
/// not-yet-tabbed window, the window itself) held *weakly*, so a model is
/// automatically released when its tab-group/window is deallocated — no leak
/// and no stale reuse when AppKit recycles an address.
@MainActor
final class TerminalSpacesStore {
    static let shared = TerminalSpacesStore()

    /// Weak keys (object identity) -> strong model. Auto-evicts dead keys.
    private let models = NSMapTable<NSObject, SpacesModel>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: .strongMemory)

    /// Internal (not private) so unit tests can create isolated instances.
    init() {}

    func model(for window: NSWindow) -> SpacesModel {
        guard let tabGroup = window.tabGroup else {
            // Not part of a tab group yet: key by the window itself.
            return model(forKeyObject: window)
        }

        if let existing = models.object(forKey: tabGroup) {
            return existing
        }

        // The window just joined/created a tab group. If it previously had a
        // standalone model (keyed by the window), migrate it so the spaces the
        // user created before the first extra tab are preserved.
        if let orphaned = models.object(forKey: window) {
            models.setObject(orphaned, forKey: tabGroup)
            models.removeObject(forKey: window)
            return orphaned
        }

        return makeModel(forKey: tabGroup)
    }

    /// Look up (or create) a model by an arbitrary key object. Exposed for
    /// unit tests; app code should use `model(for:)`.
    func model(forKeyObject key: NSObject) -> SpacesModel {
        if let existing = models.object(forKey: key) { return existing }
        return makeModel(forKey: key)
    }

    private func makeModel(forKey key: NSObject) -> SpacesModel {
        let model = SpacesModel(defaultSpace: Space(name: "Space 1"))
        models.setObject(model, forKey: key)
        return model
    }
}
