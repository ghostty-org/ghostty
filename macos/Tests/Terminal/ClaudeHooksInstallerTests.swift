import Foundation
@testable import Ghostty
import Testing

/// Exercises the JSON-shape half of `ClaudeHooksInstaller.isInstalled`
/// against in-memory fixtures. The path-resolution half (`claudeDir`,
/// derived from `homeDirectoryForCurrentUser`) has no injectable seam, and
/// adding one only for this would mean either mutable test-only state on a
/// production singleton or touching the user's real `~/.claude/settings.json`
/// during tests — both worse than the gap. What's covered here is exactly
/// the class of bug that shipped: `isInstalled` searching raw file text for
/// an unescaped path against JSON where `JSONSerialization` escapes `/`.
@MainActor
struct ClaudeHooksInstallerTests {
    private let scriptName = ClaudeHooksInstaller.scriptName

    private func hooksSettings(registeredCommand: String?) -> [String: Any] {
        var hooks: [String: Any] = [:]
        if let registeredCommand {
            hooks["Stop"] = [
                [
                    "hooks": [
                        ["type": "command", "command": registeredCommand],
                    ]
                ]
            ]
        }
        return ["hooks": hooks]
    }

    @Test func detectsARegisteredHookRegardlessOfJSONEscaping() {
        // JSONSerialization escapes "/" as "\/" on disk; the parsed dict
        // handed to this function always has it unescaped, same as this.
        let path = "/Users/isac.petinate/.claude/hooks/\(scriptName)"
        let settings = hooksSettings(registeredCommand: "'\(path)' done")
        #expect(ClaudeHooksInstaller.isRegistered(in: settings, scriptName: scriptName))
    }

    @Test func noHooksKeyIsNotRegistered() {
        #expect(!ClaudeHooksInstaller.isRegistered(in: [:], scriptName: scriptName))
    }

    @Test func emptyHooksAreNotRegistered() {
        let settings = hooksSettings(registeredCommand: nil)
        #expect(!ClaudeHooksInstaller.isRegistered(in: settings, scriptName: scriptName))
    }

    @Test func aDifferentCommandIsNotRegistered() {
        let settings = hooksSettings(registeredCommand: "'/some/other/script.sh' done")
        #expect(!ClaudeHooksInstaller.isRegistered(in: settings, scriptName: scriptName))
    }

    /// `readSettings()` returns nil when the file is missing or the JSON
    /// fails to parse; this is what every caller sees in that case.
    @Test func missingOrInvalidSettingsIsNotRegistered() {
        #expect(!ClaudeHooksInstaller.isRegistered(in: nil, scriptName: scriptName))
    }

    @Test func aRegisteredHookAmongUnrelatedKeysIsStillDetected() {
        var settings = hooksSettings(registeredCommand: "'\(scriptName)' done")
        settings["env"] = ["SOME_VAR": "value"]
        settings["theme"] = "dark"
        #expect(ClaudeHooksInstaller.isRegistered(in: settings, scriptName: scriptName))
    }
}
