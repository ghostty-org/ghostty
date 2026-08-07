import Foundation
import Combine

/// Owns the GUI-managed slice of the Ghostty configuration.
///
/// Settings edited through the settings window are written to a dedicated
/// file (`gui-settings`) inside the user's config directory, which is
/// included from the main config via a `config-file` directive. The main
/// config file is never rewritten beyond appending that single include,
/// so hand-edited configuration always survives.
@MainActor
final class GuiConfigStore: ObservableObject {
    static let shared = GuiConfigStore()

    static let fileName = "gui-settings"

    @Published private(set) var values: [String: String] = [:]

    private let configDir: URL

    var guiFileURL: URL { configDir.appendingPathComponent(Self.fileName) }
    var mainConfigURL: URL { configDir.appendingPathComponent("config") }
    var themesDirURL: URL { configDir.appendingPathComponent("themes", isDirectory: true) }

    init(configDir: URL? = nil) {
        self.configDir = configDir ?? Self.defaultConfigDir()
        load()

        // Fork defaults, applied only when the user hasn't set the key:
        // the sidebar is the point of this fork, and session restore is
        // expected behavior with it.
        var needsSave = false
        // The appearance model is theme -> effect + intensity + opacity;
        // a background color override no longer exists.
        if values["background"] != nil {
            values.removeValue(forKey: "background")
            needsSave = true
        }
        if values["sidebar"] == nil {
            values["sidebar"] = "true"
            needsSave = true
        }
        if values["window-save-state"] == nil {
            values["window-save-state"] = "always"
            needsSave = true
        }
        if needsSave { save() }
    }

    /// The main config file the Ghostty core should load, resolved without
    /// touching the shared instance so it can be read before the app (and
    /// thus the main actor) is up — see `AppDelegate.init`.
    ///
    /// Creates the file when it is missing: the core logs an error and falls
    /// back to built-in defaults for a path that doesn't exist, which on a
    /// first launch would silently discard the user's configuration until
    /// something happened to write it.
    nonisolated static func bootstrapMainConfigPath() -> String {
        let dir = defaultConfigDir()
        let url = dir.appendingPathComponent("config")
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data().write(to: url)
        }
        return url.path
    }

    /// Phantom is a distinct app from Ghostty and keeps its own config
    /// directory so the two never collide on the same machine — even
    /// though Phantom reads XDG first on macOS same as Ghostty does.
    nonisolated private static func defaultConfigDir() -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let xdgBase = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        let xdg = xdgBase.appendingPathComponent("phantom", isDirectory: true)
        if fm.fileExists(atPath: xdg.path) { return xdg }

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("com.ipetinate.phantom", isDirectory: true)
        if fm.fileExists(atPath: appSupport.appendingPathComponent("config").path) {
            return appSupport
        }

        return xdg
    }

    func string(_ key: String) -> String? {
        values[key]
    }

    // MARK: Theme

    /// Points the theme setting at a theme file Phantom owns.
    ///
    /// Written as an absolute path, not a name: the core resolves a bare
    /// name against its own `themes` directory and its bundle, neither of
    /// which is Phantom's, so a name here fails to load. An absolute path
    /// it loads directly.
    func setTheme(_ theme: TerminalTheme) {
        switch theme.source {
        case .user: set("theme", theme.url.path)
        case .builtin: set("theme", theme.name)
        }
    }

    /// The current theme's display name, for matching against the catalog.
    var currentThemeName: String? {
        guard let value = string("theme"), !value.isEmpty else { return nil }
        guard value.hasPrefix("/") else { return value }
        return (value as NSString).lastPathComponent
    }

    /// The file the theme setting resolves to, by path or by name.
    var currentThemeURL: URL? {
        guard let value = string("theme"), !value.isEmpty else { return nil }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value) }

        let user = themesDirURL.appendingPathComponent(value)
        if FileManager.default.fileExists(atPath: user.path) { return user }

        return Bundle.main.resourceURL?
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
            .appendingPathComponent(value)
    }

    func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        guard let raw = values[key] else { return defaultValue }
        return raw == "true" || raw == "1"
    }

    func double(_ key: String, default defaultValue: Double) -> Double {
        values[key].flatMap(Double.init) ?? defaultValue
    }

    /// Sets (or removes, when nil) a key and persists the file.
    func set(_ key: String, _ value: String?) {
        if let value, !value.isEmpty {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        save()
    }

    /// Posted after settings are applied and the config hot-reloaded.
    static let didApply = Notification.Name("PhantomGuiConfigDidApply")

    /// Persists pending values and hot-reloads the app configuration.
    func apply(ghostty: Ghostty.App) {
        save()
        ghostty.reloadConfig(soft: false)
        NotificationCenter.default.post(name: Self.didApply, object: nil)
    }

    // MARK: Persistence

    private func load() {
        guard let content = try? String(contentsOf: guiFileURL, encoding: .utf8)
        else { return }

        var parsed: [String: String] = [:]
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            parsed[key] = value
        }
        values = parsed
    }

    private func save() {
        let fm = FileManager.default
        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)

        var content = "# Managed by the Ghostty settings window.\n"
        content += "# Manual edits are overwritten; use the main config file instead.\n\n"
        for key in values.keys.sorted() {
            content += "\(key) = \(values[key]!)\n"
        }
        try? content.write(to: guiFileURL, atomically: true, encoding: .utf8)

        ensureIncluded()
    }

    /// Appends the `config-file` include to the main config once.
    private func ensureIncluded() {
        let existing = (try? String(contentsOf: mainConfigURL, encoding: .utf8)) ?? ""

        let isIncluded = existing.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("config-file") else { return false }
            return trimmed.hasSuffix(Self.fileName)
        }
        guard !isIncluded else { return }

        var updated = existing
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
        updated += "config-file = \(Self.fileName)\n"
        try? updated.write(to: mainConfigURL, atomically: true, encoding: .utf8)
    }
}
