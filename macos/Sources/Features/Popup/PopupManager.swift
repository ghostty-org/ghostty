import Cocoa
import GhosttyKit

/// Registry that owns and manages PopupController instances.
///
/// Each named popup profile gets at most one controller. Controllers are
/// created lazily on first toggle/show and kept alive for the lifetime
/// of the manager (or until explicitly removed).
class PopupManager {
    /// The built-in profile name for the quick/dropdown terminal.
    static let quickProfileName = "quick"

    private let ghosttyApp: Ghostty.App
    private(set) var controllers: [String: PopupController] = [:]

    /// Profile configurations keyed by name.  Populated from the Ghostty
    /// config in a future task (Task 20) via the C API.
    private var profileConfigs: [String: PopupController.PopupProfileConfig] = [:]

    init(ghosttyApp: Ghostty.App) {
        self.ghosttyApp = ghosttyApp
        // Always register a "quick" profile with defaults that match
        // the existing quick terminal behavior.
        profileConfigs[Self.quickProfileName] = PopupController.PopupProfileConfig(
            position: .top,
            widthValue: 100,
            widthIsPercent: true,
            heightValue: 50,
            heightIsPercent: true,
            autohide: true,
            persist: true,
            command: nil
        )

        // Load popup profiles from config (overrides default "quick" if
        // the user defined one explicitly).
        let configProfiles = ghosttyApp.config.popupProfiles
        if !configProfiles.isEmpty {
            updateProfileConfigs(configProfiles)
        }
    }

    // MARK: - Public API

    /// Toggle the named popup: show it if hidden, hide it if visible.
    func toggle(_ name: String) {
        guard let controller = getOrCreateController(name: name) else { return }
        controller.toggle()
    }

    /// Ensure the named popup is visible.
    func show(_ name: String) {
        guard let controller = getOrCreateController(name: name) else { return }
        controller.show()
    }

    /// Hide the named popup if it exists and is visible.
    func hide(_ name: String) {
        controllers[name]?.hide()
    }

    /// Hide every popup that is currently showing.
    func hideAll() {
        for controller in controllers.values {
            controller.hide()
        }
    }

    // MARK: - Profile Config Management

    /// Update the stored profile configurations (called when the Ghostty
    /// config is reloaded).  Handles additions, changes, and removals.
    func updateProfileConfigs(_ configs: [String: PopupController.PopupProfileConfig]) {
        // Find and destroy controllers for removed profiles
        let removedNames = Set(profileConfigs.keys).subtracting(configs.keys)
        for name in removedNames {
            if let controller = controllers[name] {
                controller.hide()
                controllers.removeValue(forKey: name)
            }
        }

        // Update stored configs (handles new + changed profiles)
        profileConfigs = configs
    }

    // MARK: - Private

    private func getOrCreateController(name: String) -> PopupController? {
        if let existing = controllers[name] {
            return existing
        }

        guard let config = profileConfigs[name] else {
            Ghostty.logger.warning("popup profile '\(name)' not found in config")
            return nil
        }

        let controller = PopupController(
            name: name,
            config: config,
            ghosttyApp: ghosttyApp
        )
        controllers[name] = controller
        return controller
    }
}
