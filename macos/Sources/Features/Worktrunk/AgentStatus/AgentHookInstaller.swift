import Foundation

enum AgentHookInstaller {
    private static let notifyScriptMarker = "# Ghostree agent notification hook v3"
    private static let wrapperMarker = "# Ghostree agent wrapper v2"

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

        do {
            try FileManager.default.createDirectory(
                at: AgentStatusPaths.opencodeGlobalPluginPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            // Best-effort only
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

        ensureFile(
            url: AgentStatusPaths.opencodeGlobalPluginPath,
            mode: 0o644,
            marker: AgentStatusPaths.opencodePluginMarker,
            content: buildOpenCodePlugin()
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
          if [ -z "$CODEX_TYPE" ]; then
            CODEX_TYPE=$(echo "$INPUT" | grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -oE '"[^"]*"$' | tr -d '"')
          fi
          if [ -z "$CODEX_TYPE" ]; then
            CODEX_TYPE=$(echo "$INPUT" | grep -oE '"event"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -oE '"[^"]*"$' | tr -d '"')
          fi
          CODEX_TYPE_LC=$(printf "%s" "$CODEX_TYPE" | tr '[:upper:]' '[:lower:]')
          case "$CODEX_TYPE_LC" in
            *permission*|*input*|*prompt*|*confirm*)
              EVENT_TYPE="PermissionRequest"
              ;;
            *start*|*begin*|*busy*|*running*|*work*)
              EVENT_TYPE="Start"
              ;;
            *complete*|*stop*|*end*|*idle*|*error*|*fail*|*cancel*|*done*|*finish*|*finished*|*success*|*exit*|*exited*)
              EVENT_TYPE="Stop"
              ;;
          esac
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

    /// Shell snippet that augments PATH with system paths and common binary locations.
    /// macOS GUI apps inherit a minimal PATH from launchd; this ensures we find
    /// user-installed binaries like claude and codex.
    private static func pathAugmentSnippet() -> String {
        return """
        # Augment PATH: macOS GUI apps only get /usr/bin:/bin:/usr/sbin:/sbin
        if [ -x /usr/libexec/path_helper ]; then
          eval "$(/usr/libexec/path_helper -s)" 2>/dev/null
        fi
        for _d in "$HOME/.local/bin" "$HOME/.bun/bin" "/opt/homebrew/bin" "/opt/homebrew/sbin" "/usr/local/bin" "$HOME/.cargo/bin"; do
          if [ -d "$_d" ]; then
            case ":$PATH:" in
              *":$_d:"*) ;;
              *) PATH="$_d:$PATH" ;;
            esac
          fi
        done
        """
    }

    private static func buildClaudeWrapper() -> String {
        let binDir = AgentStatusPaths.binDir.path
        let settings = AgentStatusPaths.claudeSettingsPath.path
        return """
        #!/bin/bash
        \(wrapperMarker)
        # Wrapper for Claude Code: injects hook settings.

        \(pathAugmentSnippet())

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

        \(pathAugmentSnippet())

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

    private static func buildOpenCodePlugin() -> String {
        let marker = AgentStatusPaths.opencodePluginMarker
        return """
        \(marker)
        /**
         * Ghostree notification plugin for OpenCode.
         *
         * Only active when run inside Ghostree (checks GHOSTREE_AGENT_EVENTS_DIR).
         * Emits Start/Stop/PermissionRequest events by appending to agent-events.jsonl.
         */
        import fs from "node:fs";
        import path from "node:path";
        
        export const GhostreeNotifyPlugin = async ({ client }) => {
          if (globalThis.__ghostreeOpencodeNotifyPluginV2) return {};
          globalThis.__ghostreeOpencodeNotifyPluginV2 = true;
        
          const eventsDir = process?.env?.GHOSTREE_AGENT_EVENTS_DIR;
          if (!eventsDir) return {};
          const logPath = path.join(eventsDir, "agent-events.jsonl");
        
          const append = (eventType) => {
            try {
              fs.mkdirSync(eventsDir, { recursive: true });
              const payload = {
                timestamp: new Date().toISOString(),
                eventType,
                cwd: process.cwd(),
              };
              fs.appendFileSync(logPath, JSON.stringify(payload) + "\\n");
            } catch {
              // Best-effort only
            }
          };
        
          let currentState = "idle"; // 'idle' | 'busy'
          let rootSessionID = null;
          let stopSent = false;
        
          const childSessionCache = new Map();
          const isChildSession = async (sessionID) => {
            if (!sessionID) return false;
            if (!client?.session?.list) return false;
            if (childSessionCache.has(sessionID)) return childSessionCache.get(sessionID);
            try {
              const sessions = await client.session.list();
              const session = sessions.data?.find((s) => s.id === sessionID);
              const isChild = !!(session?.parentID ?? session?.parentId ?? session?.parent_id);
              childSessionCache.set(sessionID, isChild);
              return isChild;
            } catch {
              return false;
            }
          };
        
          const normalizeSessionID = (sessionID) => sessionID ?? "unknown";
        
          const getSessionID = (event) => {
            const props = event?.properties ?? {};
            return props.sessionID ?? props.sessionId ?? props.session_id ?? props.session ?? props.id ?? null;
          };
        
          const handleBusy = async (sessionID) => {
            const sid = normalizeSessionID(sessionID);
            if (!rootSessionID) rootSessionID = sid;
            if (sid !== rootSessionID) return;
            if (currentState === "idle") {
              currentState = "busy";
              stopSent = false;
              append("Start");
            }
          };
        
          const handleStop = async (sessionID) => {
            const sid = normalizeSessionID(sessionID);
            if (rootSessionID && sid !== rootSessionID) return;
            if (currentState === "busy" && !stopSent) {
              currentState = "idle";
              stopSent = true;
              append("Stop");
              rootSessionID = null;
            }
          };
        
          return {
            event: async ({ event }) => {
              const sessionID = getSessionID(event);
        
              if (await isChildSession(sessionID)) return;
        
              if (event.type === "session.status") {
                const status = event.properties?.status;
                if (status?.type === "busy") await handleBusy(sessionID);
                if (status?.type === "idle") await handleStop(sessionID);
              }
        
              if (event.type === "session.busy") await handleBusy(sessionID);
              if (event.type === "session.idle") await handleStop(sessionID);
              if (event.type === "session.error") await handleStop(sessionID);
            },
            "permission.ask": async (_permission, output) => {
              if (output.status === "ask") append("PermissionRequest");
            },
          };
        };
        
        export default GhostreeNotifyPlugin;
        """
    }
}
