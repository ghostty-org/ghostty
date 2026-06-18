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

        // The group has no model yet. A window in it may still carry a
        // standalone (per-window) model from before it was tabbed — adopt it so
        // the user's spaces survive the standalone->tabbed transition. Scan ALL
        // the group's windows (not just `window`) so the result is independent
        // of which tab's sidebar resolves first; prefer the selected window's.
        if let adopted = adoptStandaloneModel(into: tabGroup) {
            models.setObject(adopted, forKey: tabGroup)
            return adopted
        }

        return makeModel(forKey: tabGroup)
    }

    /// Find and detach an existing per-window model from any window now in
    /// `tabGroup`, preferring the selected window's.
    private func adoptStandaloneModel(into tabGroup: NSWindowTabGroup) -> SpacesModel? {
        let candidates = [tabGroup.selectedWindow].compactMap { $0 } + tabGroup.windows
        for candidate in candidates {
            if let model = models.object(forKey: candidate) {
                models.removeObject(forKey: candidate)
                return model
            }
        }
        return nil
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
