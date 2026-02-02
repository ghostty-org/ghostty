import Foundation

/// Source of a configuration value.
enum ConfigValueSource {
    /// Value was set in a config file or via CLI args.
    case file
    /// Value was set in the platform settings store (e.g. NSUserDefaults).
    case settingsStore
    /// Neither file nor settings store set this value; it is the default.
    case `default`
}

/// A resolved configuration value with its source.
struct ConfigValue<T> {
    let value: T
    let source: ConfigValueSource
}

/// NSUserDefaults-backed settings store for Ghostty configuration.
///
/// All values are string-based because every Ghostty config value can be
/// expressed as a string (same format as config files). This avoids
/// duplicating the ~200+ field type system in Swift and allows values to
/// be fed directly into the Zig config parser.
///
/// Keys are namespaced with a prefix to avoid collisions with existing
/// app-state UserDefaults keys (SecureInput, CustomGhosttyIcon, etc.).
final class UserDefaultsSettingsStore {
    private let defaults: UserDefaults

    /// The prefix applied to all Ghostty config keys stored in UserDefaults.
    static let keyPrefix = "ghostty.config."

    /// Create a store backed by the given UserDefaults instance.
    /// - Parameter defaults: The UserDefaults to use. Defaults to `.standard`.
    ///   Pass a custom suite for testing.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Read all string values for a Ghostty config key.
    /// Returns nil if no value is stored.
    /// Repeatable keys (e.g. font-family) may have multiple values.
    func strings(forKey key: String) -> [String]? {
        let stored = defaults.object(forKey: Self.keyPrefix + key)
        if let array = stored as? [String] {
            return array.isEmpty ? nil : array
        }
        if let single = stored as? String {
            return [single]
        }
        return nil
    }

    /// Read the first (or only) string value for a key.
    func string(forKey key: String) -> String? {
        strings(forKey: key)?.first
    }

    /// Write string values for a Ghostty config key.
    /// Pass multiple values for repeatable keys (e.g. font-family).
    func set(_ values: [String], forKey key: String) {
        defaults.set(values, forKey: Self.keyPrefix + key)
    }

    /// Write a single string value for a key.
    func set(_ value: String, forKey key: String) {
        set([value], forKey: key)
    }

    /// Remove the value for a Ghostty config key.
    func removeValue(forKey key: String) {
        defaults.removeObject(forKey: Self.keyPrefix + key)
    }

    /// Remove all stored settings values, resetting to defaults.
    func resetAll() {
        for key in allKeys {
            removeValue(forKey: key)
        }
    }

    /// All Ghostty config keys that have stored values.
    var allKeys: [String] {
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.keyPrefix) }
            .map { String($0.dropFirst(Self.keyPrefix.count)) }
    }
}
