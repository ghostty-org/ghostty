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

    /// Ghostty reads XDG first on macOS; prefer an existing XDG dir, then
    /// an existing Application Support dir, then default to creating XDG.
    private static func defaultConfigDir() -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let xdgBase = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        let xdg = xdgBase.appendingPathComponent("ghostty", isDirectory: true)
        if fm.fileExists(atPath: xdg.path) { return xdg }

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        if fm.fileExists(atPath: appSupport.appendingPathComponent("config").path) {
            return appSupport
        }

        return xdg
    }

    func string(_ key: String) -> String? {
        values[key]
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
