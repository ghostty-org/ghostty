import Foundation

/// Installs the Claude Code integration from inside Phantom: a hook
/// script that reports the session state (working / awaiting input /
/// done) into the tab-state file each terminal exports, plus the hook
/// registrations in `~/.claude/settings.json`.
///
/// The settings file is merged, never rewritten: existing hooks and
/// unrelated keys are preserved, and legacy registrations (the
/// ghostty-named script) are migrated on install.
@MainActor
enum ClaudeHooksInstaller {
    static let scriptName = "phantom-tab-state.sh"
    static let legacyScriptName = "ghostty-tab-state.sh"

    static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    static var scriptURL: URL {
        claudeDir
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent(scriptName)
    }

    static var settingsURL: URL {
        claudeDir.appendingPathComponent("settings.json")
    }

    /// Hook events and the state each one reports.
    static let eventStates: [(event: String, state: String)] = [
        ("UserPromptSubmit", "working"),
        ("PreToolUse", "working"),
        ("PostToolUse", "working"),
        ("PermissionRequest", "awaiting"),
        ("Stop", "done"),
        ("SessionEnd", "ended"),
    ]

    private static let scriptBody = """
    #!/bin/bash
    # Reports the Claude Code session state to the Phantom sidebar.
    # No-op outside Phantom (env var only exists in Phantom terminals).
    # The atomic write-then-rename is what triggers the directory watch.
    [ -n "$GHOSTTY_TAB_STATE_FILE" ] || exit 0

    STATE="$1"

    printf '%s' "$STATE" > "$GHOSTTY_TAB_STATE_FILE.tmp" \\
      && mv "$GHOSTTY_TAB_STATE_FILE.tmp" "$GHOSTTY_TAB_STATE_FILE"
    exit 0

    """

    /// Human-readable detail of the last failure, for the settings UI.
    static private(set) var lastError: String?

    private static func fail(_ stage: String, _ error: Error? = nil) -> Bool {
        let detail = error.map { "\(stage): \($0.localizedDescription)" } ?? stage
        lastError = detail
        log("FAIL \(detail)")
        return false
    }

    private static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/phantom-hooks.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Logs each component of the install check, for diagnosis.
    static func logStatus() {
        let scriptExists = FileManager.default.fileExists(atPath: scriptURL.path)
        let readable = (try? Data(contentsOf: settingsURL)) != nil
        log("status script=\(scriptExists) settingsRead=\(readable) registered=\(isRegistered) home=\(FileManager.default.homeDirectoryForCurrentUser.path)")
    }

    /// Whether the hook script is registered for at least one event.
    ///
    /// Checked against the parsed JSON rather than the raw file text: the
    /// serializer's escaping of the path is an implementation detail, and a
    /// substring search would also match the path appearing under some
    /// unrelated key.
    private static var isRegistered: Bool {
        isRegistered(in: readSettings(), scriptName: scriptName)
    }

    /// The JSON-shape half of `isRegistered`, pulled out so it can be
    /// tested against fixtures — a registered hook, a settings file with no
    /// hooks at all, invalid JSON (`readSettings()` returns nil for that,
    /// same as this taking `nil`) — without touching the real `~/.claude`
    /// directory. File I/O and path resolution are unchanged; this is the
    /// same check `isRegistered` always did, just named.
    static func isRegistered(in settings: [String: Any]?, scriptName: String) -> Bool {
        guard let hooks = settings?["hooks"] as? [String: Any] else { return false }

        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { entry in
                commandsIn(entry).contains { $0.contains(scriptName) }
            }
        }
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: scriptURL.path) && isRegistered
    }

    @discardableResult
    static func install() -> Bool {
        let fm = FileManager.default

        do {
            try fm.createDirectory(
                at: scriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            return fail("writing hook script", error)
        }

        guard var settings = readSettings() else {
            return fail("settings.json unreadable or not an object")
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for (event, state) in eventStates {
            var entries = hooks[event] as? [[String: Any]] ?? []

            entries.removeAll { entry in
                commandsIn(entry).contains {
                    $0.contains(scriptName) || $0.contains(legacyScriptName)
                }
            }

            entries.append([
                "hooks": [
                    [
                        "type": "command",
                        "command": "'\(scriptURL.path)' \(state)",
                    ]
                ]
            ])
            hooks[event] = entries
        }

        settings["hooks"] = hooks
        guard writeSettings(settings) else {
            return fail("writing settings.json")
        }

        // Re-read from disk rather than trusting the write: another process
        // owns this file too (Claude Code rewrites it when its own settings
        // change) and can land a stale copy over ours.
        guard isInstalled else {
            return fail("settings.json was written but the hooks are not registered")
        }

        lastError = nil
        log("install ok")
        return true
    }

    @discardableResult
    static func uninstall() -> Bool {
        guard var settings = readSettings() else {
            return fail("settings.json unreadable or not an object")
        }

        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard var entries = value as? [[String: Any]] else { continue }
                entries.removeAll { entry in
                    commandsIn(entry).contains {
                        $0.contains(scriptName) || $0.contains(legacyScriptName)
                    }
                }
                hooks[event] = entries
            }
            settings["hooks"] = hooks
        }

        try? FileManager.default.removeItem(at: scriptURL)
        guard writeSettings(settings) else {
            return fail("writing settings.json")
        }
        guard !isRegistered else {
            return fail("settings.json was written but the hooks are still registered")
        }
        lastError = nil
        log("uninstall ok")
        return true
    }

    private static func commandsIn(_ entry: [String: Any]) -> [String] {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return [] }
        return inner.compactMap { $0["command"] as? String }
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else {
            return [:]
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeSettings(_ settings: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        do {
            try data.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
