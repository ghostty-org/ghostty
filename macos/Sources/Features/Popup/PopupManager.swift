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

    /// Default configuration for the built-in quick terminal profile.
    /// Extracted as a static constant so both init() and updateProfileConfigs()
    /// reference the same definition.
    private static let defaultQuickConfig = PopupController.PopupProfileConfig(
        position: .top,
        widthValue: 100,
        widthIsPercent: true,
        heightValue: 50,
        heightIsPercent: true,
        autohide: true,
        persist: true,
        command: nil
    )

    private let ghosttyApp: Ghostty.App
    private(set) var controllers: [String: PopupController] = [:]

    /// Profile configurations keyed by name.  Populated from the Ghostty
    /// config in a future task (Task 20) via the C API.
    private var profileConfigs: [String: PopupController.PopupProfileConfig] = [:]

    init(ghosttyApp: Ghostty.App) {
        self.ghosttyApp = ghosttyApp
        // Always register a "quick" profile with defaults that match
        // the existing quick terminal behavior.
        profileConfigs[Self.quickProfileName] = Self.defaultQuickConfig

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
    /// config is reloaded).  Handles additions, changes, and removals:
    /// - Removed profiles: hide and destroy any running controller
    /// - New profiles: stored for lazy creation on next toggle/show
    /// - Changed profiles: stored config updated; currently-visible popups
    ///   keep running. Controllers are marked stale so the next toggle
    ///   cycle (hide→show) recreates them with the new config.
    func updateProfileConfigs(_ configs: [String: PopupController.PopupProfileConfig]) {
        // Build the effective config map, preserving the built-in quick
        // profile as a fallback so it is never accidentally dropped.
        var effectiveConfigs = configs
        if effectiveConfigs[Self.quickProfileName] == nil {
            effectiveConfigs[Self.quickProfileName] = Self.defaultQuickConfig
        }

        // Find and destroy controllers for truly removed profiles
        let removedNames = Set(profileConfigs.keys).subtracting(effectiveConfigs.keys)
        for name in removedNames {
            if let controller = controllers[name] {
                controller.hide()
                controller.surfaceTree = .init()
                controllers.removeValue(forKey: name)
            }
        }

        // For changed profiles, mark existing controllers as stale.
        // They keep running if visible — on the next toggle (hide→show
        // cycle), getOrCreateController will notice the stale flag and
        // recreate the controller with the new config.
        for (name, newConfig) in effectiveConfigs {
            if let oldConfig = profileConfigs[name], let controller = controllers[name] {
                if !oldConfig.isEqual(to: newConfig) {
                    controller.isStale = true
                }
            }
        }

        profileConfigs = effectiveConfigs
    }

    // MARK: - Private

    private func getOrCreateController(name: String) -> PopupController? {
        if let existing = controllers[name] {
            // If the controller is stale (config changed since last reload)
            // and currently hidden, destroy it so we recreate with new config.
            // If it's visible, keep using it — it'll be recreated after the
            // user hides it and toggles again.
            if existing.isStale && !existing.visible {
                existing.hide()
                existing.surfaceTree = .init()
                controllers.removeValue(forKey: name)
                // Fall through to create a new controller below
            } else {
                return existing
            }
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
