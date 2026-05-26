# Agent Hook Loading State Implementation

## Goal

Replace the sidebar spinner's current terminal-output heuristic with explicit agent lifecycle events for Claude Code and Codex CLI.

The desired behavior is:

- The sidebar tab status slot remains `title -> spacer -> spinner/bell`.
- Claude/Codex doing work shows the spinner.
- Claude/Codex waiting for user input shows the bell.
- Idle terminals do not show the spinner.
- Resizing the sidebar, resizing the terminal, TUI redraws, and repaint-heavy output do not activate the spinner.
- Generic terminal activity can remain as a fallback later, but Claude/Codex should not depend on output activity.

## Why This Change

The current spinner path is driven by PTY output:

- `src/termio/Termio.zig` calls `terminalActivityUnlocked`.
- `src/termio/stream_handler.zig` throttles `.terminal_activity`.
- `src/Surface.zig`, `src/apprt/surface.zig`, and `include/ghostty.h` forward that to the app.
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` sets `recentTerminalActivity`.
- `macos/Sources/Features/Terminal/TerminalSidebar.swift` treats `recentTerminalActivity` as `isWorking`.

That signal is not semantic. A resize or TUI redraw can produce output even when Claude/Codex is waiting at an input prompt. This caused false spinner activation and may have contributed to fragile behavior around Claude's full-screen TUI redraws.

CMUX solves this by using agent hook events, not terminal output. The useful reference points in the local CMUX clone are:

- `/Users/scott/Developer/cmux/Resources/bin/claude`
- `/Users/scott/Developer/cmux/CLI/CMUXCLI+AgentHookDefinitions.swift`
- `/Users/scott/Developer/cmux/CLI/cmux.swift`
- `/Users/scott/Developer/cmux/Sources/TerminalController.swift`
- `/Users/scott/Developer/cmux/Sources/Workspace+PanelLifecycle.swift`

Important CMUX findings:

- Claude is launched through a tiny wrapper that injects hook settings, then `exec`s the real `claude` binary.
- Codex uses installed native hooks in `~/.codex/hooks.json` plus enabled hooks in `~/.codex/config.toml`.
- Hook callbacks send pane-scoped status updates.
- Those hook callbacks are also how CMUX shows sidebar status indicators. The hook handler sends commands such as `set_status claude_code Running --icon=bolt.fill ...` or `set_status codex Running --icon=bolt.fill ...`; the sidebar renders that explicit status entry.
- CMUX stores session id, surface id, pid, prompt depth, and runtime status to avoid stale/nested hook events clearing newer state.
- The UI renders explicit state. It does not infer agent state from PTY output.

## Recommended Architecture

Use a small local hook bridge:

```text
Claude/Codex native hook event
-> bundled Ghostty hook helper
-> per-surface event channel
-> SurfaceView agent activity state
-> sidebar status indicator
```

Do not replace the real Claude or Codex process. The hook wrapper/helper only reports state. The real CLIs still run normally.

## Sidebar Status Indicators

The implementation should include the sidebar status indicator path in the same pass as the hook bridge. Do not build only the hook bridge and leave the sidebar on `recentTerminalActivity`.

CMUX's useful pattern is:

```text
agent lifecycle hook
-> normalize to Running / Needs input / Idle / Error
-> send pane-scoped status mutation
-> sidebar renders the status for that pane/tab
```

For this repo, the equivalent should be:

```text
TerminalAgentActivityEvent
-> TerminalAgentActivityState
-> TerminalSidebarStatusIndicatorState
-> TerminalSidebarStatusIndicator
```

Recommended sidebar indicator enum:

```swift
enum TerminalSidebarStatusIndicatorState: Equatable {
    case none
    case spinner(agent: String)
    case bell(agent: String)
    case error(agent: String)
}
```

Initial visual mapping:

- `.spinner` -> existing custom ring spinner.
- `.bell` -> existing bell/dot indicator, or a small bell icon if one is introduced.
- `.error` -> use the bell slot initially, preferably with a warning/error tint if the theme supports it.
- `.none` -> empty 12x12 status slot.

State mapping:

| Agent state | Sidebar indicator | Notes |
| --- | --- | --- |
| `running` | spinner | Claude/Codex is actively doing work. |
| `needsInput` | bell | The agent is waiting for approval, a question, or user input. |
| `error` | error/bell | The agent stopped because of an error or failed permission/tool state. |
| `idle` | none | Clear spinner and agent-specific bell. |

Tab-level precedence:

1. Any surface has `running` -> show spinner.
2. Else any surface has `error` -> show error/bell.
3. Else any surface has `needsInput` -> show bell.
4. Else existing terminal bell -> show bell.
5. Else no indicator.

This keeps the current layout:

```text
title -> spacer -> spinner/bell/error slot
```

The slot should remain fixed-size so title truncation and row layout do not shift while the state changes.

Optional later: add a CMUX-like text status row or tooltip such as `Claude Running`, `Codex needs input`, or `Codex error`. That is not required for the first pass; the first pass should keep the subtle tab-title-side indicator.

### State Model

Add a pane-scoped state enum on macOS:

```swift
enum TerminalAgentActivityState: Equatable {
    case idle
    case running(agent: String)
    case needsInput(agent: String)
    case error(agent: String)
}
```

Suggested state precedence for a tab:

1. Any surface in the tab is `.running` -> show spinner.
2. Else any surface is `.error` -> show error/bell.
3. Else any surface is `.needsInput` -> show bell.
4. Else existing terminal bell -> show bell.
5. Else no status indicator.

This keeps the existing `title -> Spacer -> TerminalSidebarStatusIndicator` layout in `TerminalSidebar.swift`.

### Event Schema

The bridge should write normalized events like:

```json
{
  "version": 1,
  "surface_id": "UUID-or-generated-surface-id",
  "agent": "claude",
  "event": "prompt-submit",
  "state": "running",
  "status_title": "Claude Code",
  "status_value": "Running",
  "session_id": "optional",
  "turn_id": "optional",
  "pid": 12345,
  "timestamp": 1770000000.123
}
```

Keep the reducer fail-open:

- Unknown event: ignore.
- Missing session id: still apply if the event targets the current surface.
- Stop/session-end with a stale session id: ignore if a newer session is active.
- Malformed JSON line: ignore and keep the current state.
- `status_title` and `status_value` are optional display metadata. The reducer should derive a sensible title/value from `agent` and `state` if they are missing.

## Bridge Transport

Use a file-backed event bridge for the first implementation. It is simple, fast, and avoids adding a socket server.

Per surface:

- Generate a stable `agentSurfaceID` when the `SurfaceView` is created.
- Create a per-surface JSONL event file under a private temp directory, for example:

```text
$TMPDIR/ghostty-agent-hooks-$UID/<surface-id>.jsonl
```

- Watch the file or containing directory with `DispatchSourceFileSystemObject`.
- On change, read only appended bytes, split into lines, decode events, and update the surface state on the main actor.

The helper writes one JSON line using `O_APPEND` and exits. Hook events are rare, so this is much cheaper and less fragile than watching terminal output.

Alternative later: replace the JSONL transport with a Unix domain socket if we need request/response behavior. The state reducer and hook definitions should not depend on the transport.

## Environment Injection

Each terminal surface needs these environment variables:

```text
GHOSTTY_AGENT_SURFACE_ID=<stable surface id>
GHOSTTY_AGENT_EVENT_FILE=<absolute path to per-surface jsonl file>
GHOSTTY_AGENT_HOOK_HELPER=<absolute path to bundled helper executable>
GHOSTTY_AGENT_HOOKS_DISABLED=0/1
```

For Claude wrapper discovery, also prepend the bundled helper directory to `PATH`, but only in Ghostty-created terminals.

Relevant Ghostty files:

- `macos/Sources/Ghostty/Surface View/SurfaceView.swift`
  - `SurfaceConfiguration.environmentVariables`
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
  - surface creation currently uses `let surface_cfg = baseConfig ?? SurfaceConfiguration()`
- `src/termio/Exec.zig`
  - currently sets `GHOSTTY_RESOURCES_DIR` and adjusts `PATH`

Implementation detail:

- Enrich the surface configuration before `ghostty_surface_new`.
- Do this before the PTY child starts. These env vars cannot be added after the terminal process is already running.

## Hook Helper

Add a tiny bundled executable named `ghostty-agent-hook`.

Recommended implementation: a small Zig executable, because this repo already builds Zig and the helper should not depend on `jq`, Python, or Swift being available in the user's shell.

CLI contract:

```text
ghostty-agent-hook <agent> <event>
```

Examples:

```text
ghostty-agent-hook claude prompt-submit
ghostty-agent-hook claude stop
ghostty-agent-hook codex prompt-submit
ghostty-agent-hook codex permission-request
```

Behavior:

- Read stdin to EOF. It may contain hook JSON.
- Parse useful fields if present:
  - `session_id`, `sessionId`
  - `turn_id`, `turnId`
  - `cwd`
  - `transcript_path`, `transcriptPath`
  - `hook_event_name`, `hookEventName`
- Determine normalized state:
  - `prompt-submit`, `user-prompt-submit`, `pre-tool-use` -> `running`
  - `notification`, `permission-request`, `ask-user-question` -> `needsInput`
  - `stop`, `idle` -> `idle`
  - `session-end` -> `idle` plus clear active session
  - explicit error/failure signals -> `error`
- Include display metadata in the emitted event:
  - `running` -> `status_value: "Running"`
  - `needsInput` -> `status_value: "Needs input"`
  - `error` -> `status_value: "Error"` or a short agent-specific error label
  - `idle` -> `status_value: "Idle"` only for state bookkeeping; the sidebar should hide idle agent indicators
- Write the JSONL event to `$GHOSTTY_AGENT_EVENT_FILE`.
- Always print `{}` to stdout and exit 0 unless invoked with a setup command.
- Never block on app state. If the event file/env is missing, print `{}` and exit 0.

The stdout rule matters. Agent hook systems may interpret stdout as hook output, so status reporting must not break the agent.

## Claude Implementation

Add a bundled `claude` shim, similar to CMUX's `/Users/scott/Developer/cmux/Resources/bin/claude`.

Runtime flow:

```text
user types claude
-> Ghostty-bundled claude shim is found first on PATH
-> shim verifies it is inside a Ghostty terminal with hook env vars
-> shim finds the real claude binary, skipping its own directory
-> shim builds --settings JSON with hook definitions
-> shim execs the real claude binary
```

The wrapper should pass through unchanged when:

- Not inside a Ghostty terminal.
- `GHOSTTY_AGENT_HOOKS_DISABLED=1`.
- The real `claude` cannot be resolved.
- The invocation is a non-session subcommand such as `claude --help`, `claude --version`, `claude config`, etc.

The wrapper should use `exec`, not spawn and wait. There should not be an extra long-running wrapper process.

Claude hook settings should include:

```text
SessionStart      -> ghostty-agent-hook claude session-start
UserPromptSubmit  -> ghostty-agent-hook claude prompt-submit
PreToolUse        -> ghostty-agent-hook claude pre-tool-use
Notification      -> ghostty-agent-hook claude notification
Stop              -> ghostty-agent-hook claude stop
SessionEnd        -> ghostty-agent-hook claude session-end
```

Optional later:

- `PermissionRequest` can be used for richer "needs input" state, but do not implement blocking approval/feed behavior unless that is explicitly in scope.
- `AskUserQuestion` can be detected from `PreToolUse` payload and mapped to `needsInput`.

Use a generated `--session-id` only when the user did not already pass resume/session flags. This mirrors CMUX and helps stale-event filtering.

## Codex Implementation

Codex should use native installed hooks instead of a PATH wrapper.

Add an install path, either:

- `ghostty-agent-hook install codex`
- or a macOS setting/action that runs the same installer.

The installer should update:

```text
~/.codex/hooks.json
~/.codex/config.toml
```

Preserve existing user hooks. Remove/replace only Ghostty-owned hook entries using clear marker strings.

Suggested Codex hook events:

```text
SessionStart      -> ghostty-agent-hook codex session-start
UserPromptSubmit  -> ghostty-agent-hook codex prompt-submit
Stop              -> ghostty-agent-hook codex stop
PreToolUse        -> ghostty-agent-hook codex pre-tool-use
PermissionRequest -> ghostty-agent-hook codex permission-request
```

The installed shell command should no-op outside Ghostty:

```sh
ghostty_hook="${GHOSTTY_AGENT_HOOK_HELPER:-$(command -v ghostty-agent-hook 2>/dev/null || true)}"
if [ -n "${GHOSTTY_AGENT_SURFACE_ID:-}" ] && [ -n "$ghostty_hook" ]; then
  "$ghostty_hook" codex prompt-submit
else
  echo '{}'
fi
```

Codex hook format should mirror CMUX's nested hook format from:

```text
/Users/scott/Developer/cmux/CLI/CMUXCLI+AgentHookDefinitions.swift
```

CMUX also enables Codex hooks in `config.toml` by writing `[features] hooks = true` and handles hook trust. Check the local Codex CLI behavior while implementing. If current Codex requires trusted hook hashes, mirror CMUX's approach before calling the implementation complete.

## Swift App Integration

Add a small app-side component, for example:

```text
macos/Sources/Features/Terminal/TerminalAgentActivity.swift
```

Responsibilities:

- Define `TerminalAgentActivityEvent`.
- Define `TerminalAgentActivityState`.
- Define `TerminalSidebarStatusIndicatorState` or a nearby equivalent.
- Parse JSONL events.
- Reduce events into per-surface state.
- Derive the sidebar indicator state from all surfaces in a tab.
- Expose a published state from `SurfaceView`.

`SurfaceView_AppKit.swift` should own:

- `agentSurfaceID`
- `agentEventFileURL`
- event file watcher
- `@Published private(set) var agentActivityState`

`TerminalSidebar.swift` should stop using `recentTerminalActivity` for Claude/Codex work state. Suggested replacement:

```swift
private func tabAgentIndicatorState(_ controller: BaseTerminalController) -> TerminalSidebarStatusIndicatorState {
    for surfaceView in controller.surfaceTree {
        if case .running(let agent) = surfaceView.agentActivityState {
            return .spinner(agent: agent)
        }
    }
    for surfaceView in controller.surfaceTree {
        if case .error(let agent) = surfaceView.agentActivityState {
            return .error(agent: agent)
        }
    }
    for surfaceView in controller.surfaceTree {
        if case .needsInput(let agent) = surfaceView.agentActivityState {
            return .bell(agent: agent)
        }
    }
    return controller.bell ? .bell(agent: "terminal") : .none
}
```

Then store that indicator state directly on `TerminalSidebarSession` instead of only storing `isWorking` and `hasBell`:

```swift
let indicatorState = tabAgentIndicatorState(controller)
```

If `progressReport` is already used for real terminal progress reports, it can still force `.spinner(agent: "terminal")` when there is no higher-priority agent indicator. Do not let raw recent terminal output set the spinner.

Update `TerminalSidebarStatusIndicator` to accept the enum:

```swift
private struct TerminalSidebarStatusIndicator: View {
    let state: TerminalSidebarStatusIndicatorState
    let spinnerColor: NSColor
    let bellColor: NSColor
    let errorColor: NSColor
}
```

Accessibility labels should also reflect the hook state:

- `Claude running`
- `Codex needs input`
- `Codex error`
- no extra status for `.none`

## What To Do With Current Terminal Activity Code

Short term:

- Leave the Zig `.terminal_activity` path in place if removing it is risky.
- Remove `surfaceView.recentTerminalActivity` from `TerminalSidebarModel.tabIsWorking`.
- Keep `recentTerminalActivity` unused or behind a clearly named fallback setting.

Long term:

- Delete the `.terminal_activity` action path if no other feature uses it.
- If generic process activity is still desired, implement shell integration using `preexec`/`precmd` style events. CMUX has examples in:
  - `/Users/scott/Developer/cmux/Resources/shell-integration/cmux-zsh-integration.zsh`
  - `/Users/scott/Developer/cmux/Resources/shell-integration/cmux-bash-integration.bash`

Generic shell activity should be a separate state from AI-agent lifecycle.

## Stale State Handling

Avoid stuck spinners:

- Track active session id per surface and agent when available.
- Ignore `stop`/`session-end` for an older session if a newer session is running.
- Include PID when available:
  - Claude wrapper can export the real Claude PID because it uses `exec`.
  - Codex hook helper can record parent PID as a weaker fallback.
- Clear agent state when the surface closes.
- Add a defensive long TTL for `running` states, such as 6 hours, only as a last-resort cleanup. Do not use a short timeout for normal idle detection because long-running agent tasks are valid.

## Testing Plan

Unit tests:

- JSON event parsing.
- State reducer:
  - prompt-submit -> running
  - notification -> needsInput
  - stop -> idle
  - stale stop ignored
  - malformed event ignored
- Hook installer preserves non-Ghostty Codex hooks.
- Claude wrapper real-binary resolution skips its own directory.
- Sidebar indicator derivation:
  - any running surface wins over needs-input/error/terminal bell
  - error wins over needs-input
  - needs-input wins over terminal bell
  - idle clears the agent indicator

Manual fake-hook test inside a Ghostty tab:

```sh
printf '{}\n' | "$GHOSTTY_AGENT_HOOK_HELPER" claude prompt-submit
sleep 2
printf '{}\n' | "$GHOSTTY_AGENT_HOOK_HELPER" claude stop
```

Expected:

- Spinner appears after `prompt-submit`.
- Spinner disappears after `stop`.
- Resizing the sidebar or terminal does not change state.
- If the fake event is `notification` or `permission-request`, the status slot shows the bell instead of the spinner.

Claude manual test:

```sh
claude
```

Then submit a real prompt. Expected:

- Spinner starts when Claude begins work.
- Spinner stops on completion.
- Bell appears when Claude needs user input or permission.

Codex manual test:

```sh
ghostty-agent-hook install codex
codex
```

Then submit a real prompt. Expected:

- Spinner starts on `UserPromptSubmit`.
- Spinner stops on `Stop`.
- Permission/input waits map to bell if hook coverage allows it.

Regression tests:

- Run a command with lots of output:

```sh
for i in $(seq 1 200); do echo active-spinner-$i; sleep 0.02; done
```

Expected:

- This should not activate the Claude/Codex spinner unless generic shell activity is deliberately enabled.

- Open Claude, do not submit a prompt, resize the sidebar and terminal.

Expected:

- No spinner activation.
- Claude TUI remains visually intact.

Build/verification:

```sh
zig build -Dxcframework-target=native
zig build run
```

Use Peekaboo to verify the sidebar indicator visually after the app launches.

## Implementation Order

1. Add the event model and reducer with unit tests.
2. Add the sidebar status indicator enum and update `TerminalSidebarStatusIndicator` to render spinner/bell/error from explicit state.
3. Add the file-backed event watcher to `SurfaceView_AppKit.swift`.
4. Inject per-surface hook environment variables before `ghostty_surface_new`.
5. Add the `ghostty-agent-hook` helper and bundle it.
6. Change `TerminalSidebar.swift` to use agent status state instead of `recentTerminalActivity`.
7. Add the Claude wrapper and PATH injection.
8. Add Codex hook install/uninstall.
9. Run fake-hook tests for spinner, bell, error, and idle clearing.
10. Test real Claude.
11. Test real Codex.
12. Remove or demote the old terminal-output activity spinner path.

## Risks And Guardrails

- Do not block agent hooks. Status updates must be fire-and-forget.
- Do not write noisy output from hook commands. Print `{}` and exit 0.
- Do not silently overwrite user Codex config. Preserve unknown hooks and use Ghostty markers.
- Avoid wrapper recursion. The Claude wrapper must find the real `claude` while skipping its own directory.
- Keep status pane-scoped. A hook event from one terminal must not update another tab.
- Do not use terminal output as the source of truth for Claude/Codex running state.
