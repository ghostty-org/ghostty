import Foundation

/// One server's worth of user overrides to the registry's defaults.
///
/// All three fields read as "no override" when blank, rather than the
/// registry's own required fields, so a user changing one of them — say,
/// pointing at a different binary — doesn't also have to retype the
/// arguments they were happy with.
struct LSPServerOverride: Codable, Equatable {
    var command: String = ""
    var arguments: String = ""
    var initializationOptionsJSON: String = ""

    var isEmpty: Bool {
        command.trimmingCharacters(in: .whitespaces).isEmpty
            && arguments.trimmingCharacters(in: .whitespaces).isEmpty
            && initializationOptionsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Reads and writes per-server overrides, keyed by the registry's *default*
/// command.
///
/// Not by language id: four ids in the registry (`typescript`,
/// `typescriptreact`, `javascript`, `javascriptreact`) are the same
/// `typescript-language-server` process, and a user who changes that
/// server's command or arguments means all four, not one quarter of them.
/// Keying by the default command is also why this stays independent of
/// whatever the override itself changes the command *to* — the identity of
/// "which server is this a setting for" can't be the thing being edited.
///
/// `LSPServerRegistry` stays what it has always been: pure data, no
/// `UserDefaults`, testable without the app around it. This is the layer
/// above it that a user's own choices go through — the registry is the
/// default, this is the override, and `LSPCenter.effectiveDefinition`
/// merges them.
enum LSPServerOverrideStore {
    static let defaultsKey = "LSPServerOverrides"

    static var all: [String: LSPServerOverride] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: LSPServerOverride].self, from: data)
        else { return [:] }
        return decoded
    }

    static func override(for defaultCommand: String) -> LSPServerOverride? {
        all[defaultCommand]
    }

    static func set(_ override: LSPServerOverride, for defaultCommand: String) {
        var current = all
        if override.isEmpty {
            current.removeValue(forKey: defaultCommand)
        } else {
            current[defaultCommand] = override
        }
        guard let data = try? JSONEncoder().encode(current) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
