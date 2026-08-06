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
        ("SessionEnd", "clear"),
    ]

    private static let scriptBody = """
    #!/bin/bash
    # Reports the Claude Code session state to the Phantom sidebar.
    # No-op outside Phantom (env var only exists in Phantom terminals).
    # The atomic write-then-rename is what triggers the directory watch.
    [ -n "$GHOSTTY_TAB_STATE_FILE" ] || exit 0

    STATE="$1"

    if [ "$STATE" = "clear" ]; then
      rm -f "$GHOSTTY_TAB_STATE_FILE"
      exit 0
    fi

    printf '%s' "$STATE" > "$GHOSTTY_TAB_STATE_FILE.tmp" \\
      && mv "$GHOSTTY_TAB_STATE_FILE.tmp" "$GHOSTTY_TAB_STATE_FILE"
    exit 0

    """

    static var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return text.contains(scriptURL.path)
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
            return false
        }

        guard var settings = readSettings() else { return false }
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
        return writeSettings(settings)
    }

    @discardableResult
    static func uninstall() -> Bool {
        guard var settings = readSettings() else { return false }

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
        return writeSettings(settings)
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
