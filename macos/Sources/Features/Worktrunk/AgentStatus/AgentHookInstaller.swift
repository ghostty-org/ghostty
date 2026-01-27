import Foundation

enum AgentHookInstaller {
    private static let notifyScriptMarker = "# Ghostree agent notification hook v1"
    private static let wrapperMarker = "# Ghostree agent wrapper v1"

    static func ensureInstalled() {
        if ProcessInfo.processInfo.environment["GHOSTREE_DISABLE_AGENT_HOOKS"] == "1" {
            return
        }

        do {
            try FileManager.default.createDirectory(at: AgentStatusPaths.hooksDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: AgentStatusPaths.binDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: AgentStatusPaths.eventsCacheDir, withIntermediateDirectories: true)
        } catch {
            return
        }

        ensureFile(
            url: AgentStatusPaths.notifyHookPath,
            mode: 0o755,
            marker: notifyScriptMarker,
            content: buildNotifyHookScript()
        )
        ensureFile(
            url: AgentStatusPaths.claudeSettingsPath,
            mode: 0o644,
            marker: "bash '",
            content: buildClaudeSettings(notifyPath: AgentStatusPaths.notifyHookPath.path)
        )
        ensureFile(
            url: AgentStatusPaths.claudeWrapperPath,
            mode: 0o755,
            marker: wrapperMarker,
            content: buildClaudeWrapper()
        )
        ensureFile(
            url: AgentStatusPaths.codexWrapperPath,
            mode: 0o755,
            marker: wrapperMarker,
            content: buildCodexWrapper()
        )
    }

    private static func ensureFile(url: URL, mode: Int16, marker: String, content: String) {
        let existing = try? String(contentsOf: url, encoding: .utf8)
        let shouldRewrite = existing == nil || (existing?.contains(marker) != true)

        if shouldRewrite {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
            } catch {
                return
            }
        } else {
            _ = try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
        }
    }

    private static func buildNotifyHookScript() -> String {
        let eventsDir = AgentStatusPaths.eventsCacheDir.path
        return """
        #!/bin/bash
        \(notifyScriptMarker)
        # Called by CLI agents (Claude Code, Codex, etc.) when they complete or need input.

        EVENTS_DIR="${GHOSTREE_AGENT_EVENTS_DIR:-\(eventsDir)}"
        [ -z "$EVENTS_DIR" ] && exit 0
        mkdir -p "$EVENTS_DIR" >/dev/null 2>&1

        if [ -n "$1" ]; then
          INPUT="$1"
        else
          INPUT=$(cat)
        fi

        EVENT_TYPE=$(echo "$INPUT" | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -oE '"[^"]*"$' | tr -d '"')
        if [ -z "$EVENT_TYPE" ]; then
          CODEX_TYPE=$(echo "$INPUT" | grep -oE '"type"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -oE '"[^"]*"$' | tr -d '"')
          if [ "$CODEX_TYPE" = "agent-turn-complete" ]; then
            EVENT_TYPE="Stop"
          elif [ "$CODEX_TYPE" = "agent-turn-start" ]; then
            EVENT_TYPE="Start"
          elif [ "$CODEX_TYPE" = "agent-turn-permission" ]; then
            EVENT_TYPE="PermissionRequest"
          fi
        fi

        [ "$EVENT_TYPE" = "UserPromptSubmit" ] && EVENT_TYPE="Start"
        [ -z "$EVENT_TYPE" ] && exit 0

        CWD="$(pwd -P 2>/dev/null || pwd)"
        TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        ESC_CWD="${CWD//\\\\/\\\\\\\\}"
        ESC_CWD="${ESC_CWD//\\\"/\\\\\\\"}"

        printf '{\"timestamp\":\"%s\",\"eventType\":\"%s\",\"cwd\":\"%s\"}\\n' "$TS" "$EVENT_TYPE" "$ESC_CWD" >> "$EVENTS_DIR/agent-events.jsonl" 2>/dev/null
        """
    }

    private static func buildClaudeSettings(notifyPath: String) -> String {
        let escapedNotifyPath = notifyPath.replacingOccurrences(of: "'", with: "'\\''")
        let command = "bash '\(escapedNotifyPath)'"
        let settings: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    ["hooks": [["type": "command", "command": command]]],
                ],
                "Stop": [
                    ["hooks": [["type": "command", "command": command]]],
                ],
                "PermissionRequest": [
                    ["matcher": "*", "hooks": [["type": "command", "command": command]]],
                ],
            ],
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: settings),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"hooks\":{}}"
        }

        return str
    }

    private static func buildClaudeWrapper() -> String {
        let binDir = AgentStatusPaths.binDir.path
        let settings = AgentStatusPaths.claudeSettingsPath.path
        return """
        #!/bin/bash
        \(wrapperMarker)
        # Wrapper for Claude Code: injects hook settings.

        find_real_binary() {
          local name="$1"
          local IFS=:
          for dir in $PATH; do
            [ -z "$dir" ] && continue
            dir="${dir%/}"
            if [ "$dir" = "\(binDir)" ]; then
              continue
            fi
            if [ -x "$dir/$name" ] && [ ! -d "$dir/$name" ]; then
              printf "%s\\n" "$dir/$name"
              return 0
            fi
          done
          return 1
        }

        REAL_BIN="$(find_real_binary "claude")"
        if [ -z "$REAL_BIN" ]; then
          echo "Ghostree: claude not found in PATH. Install it and ensure it is on PATH, then retry." >&2
          exit 127
        fi

        exec "$REAL_BIN" --settings "\(settings)" "$@"
        """
    }

    private static func buildCodexWrapper() -> String {
        let binDir = AgentStatusPaths.binDir.path
        let notifyPath = AgentStatusPaths.notifyHookPath.path
        return """
        #!/bin/bash
        \(wrapperMarker)
        # Wrapper for Codex: injects notify hook configuration.

        find_real_binary() {
          local name="$1"
          local IFS=:
          for dir in $PATH; do
            [ -z "$dir" ] && continue
            dir="${dir%/}"
            if [ "$dir" = "\(binDir)" ]; then
              continue
            fi
            if [ -x "$dir/$name" ] && [ ! -d "$dir/$name" ]; then
              printf "%s\\n" "$dir/$name"
              return 0
            fi
          done
          return 1
        }

        REAL_BIN="$(find_real_binary "codex")"
        if [ -z "$REAL_BIN" ]; then
          echo "Ghostree: codex not found in PATH. Install it and ensure it is on PATH, then retry." >&2
          exit 127
        fi

        exec "$REAL_BIN" -c 'notify=["bash","\(notifyPath)"]' "$@"
        """
    }
}
