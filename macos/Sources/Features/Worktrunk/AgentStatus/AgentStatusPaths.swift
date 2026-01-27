import Foundation

enum AgentStatusPaths {
    private static var appIdentifier: String { "dev.sidequery.Ghostree" }

    static var baseSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appIdentifier, isDirectory: true)
    }

    static var hooksSupportDir: URL {
        baseSupportDir.appendingPathComponent("agent-hooks", isDirectory: true)
    }

    static var hooksDir: URL {
        hooksSupportDir.appendingPathComponent("hooks", isDirectory: true)
    }

    static var binDir: URL {
        hooksSupportDir.appendingPathComponent("bin", isDirectory: true)
    }

    static var eventsCacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appIdentifier, isDirectory: true)
            .appendingPathComponent("agent-events", isDirectory: true)
    }

    static var eventsLogURL: URL {
        eventsCacheDir.appendingPathComponent("agent-events.jsonl")
    }

    static var notifyHookPath: URL {
        hooksDir.appendingPathComponent("notify.sh")
    }

    static var claudeSettingsPath: URL {
        hooksDir.appendingPathComponent("claude-settings.json")
    }

    static var claudeWrapperPath: URL {
        binDir.appendingPathComponent("claude")
    }

    static var codexWrapperPath: URL {
        binDir.appendingPathComponent("codex")
    }
}

