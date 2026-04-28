# Full-Loop Smoke Test

Run this checklist before tagging each beta release to verify the entire task loop works: Linear sync → click row → Claude spawns → work completes → status flows back to Linear.

## Prerequisites

- Ghostties.app built in Release configuration and installed at `/Applications/Ghostties.app`
- `ghostties-mcp` server registered in Claude Code's `~/.mcp.json` (local MCP server for task context)
- Linear MCP registered in Claude Code's `~/.mcp.json` (for `linear-sync` preset)
- `ghostties` project added to the Workspace sidebar (project name: `ghostties`, path: `~/Code/ghostties`)

## Steps

**1. Launch without banner**  
Open Ghostties.app from Finder (not terminal). **Pass:** app launches cleanly, no debug banner visible at the top of the sidebar.

**2. Sync Linear inbox**  
Open any terminal pane. Run Claude Code with the `linear-sync` preset (or ask Claude to sync your Linear inbox). **Pass:** at least one task appears in the Inbox lane. Inspect its file at `.ghostties/tasks/<id>.md` — confirm frontmatter has `template: Claude Code` and `project-path:` set.

**3. Click task row and verify spawn**  
Click any Inbox task with project context (skip orphan triage cards). **Pass:** (a) task file opens in your default editor, (b) row moves to Running lane within 1 second, (c) Claude Code session spawns in terminal at `~/Code/ghostties`, (d) running `echo $GHOSTTIES_TASK_FILE` prints the absolute path to the task `.md`.

**4. Generate test artifact**  
In the spawned Claude session, ask: "Write `docs/hello.md` containing the task title and today's date." **Pass:** file appears at `~/Code/ghostties/docs/hello.md` within 30 seconds.

**5. Mark done and verify sync**  
Run `gt done <task-id>` in the same terminal. **Pass:** row moves from Running to Graveyard within 1–2 seconds (file-watcher trigger).

**6. Flow back to Linear**  
Re-run the sync: ask Claude to sync your Linear inbox. **Pass:** completion report mentions the task was marked Done in Linear. Open Linear and confirm the issue shows Done state.

## Failure Handling

If any step fails, note the step number and failure mode in the release notes. Steps 1–5 are release blockers (no ship). Step 6 (Linear flow-back) is degraded-mode: ship with a documented note if only this step fails, since the core loop (steps 1–5) works offline.

## Clean Up

After smoke test passes, remove the test artifact:

```bash
rm docs/hello.md
```

## Notes

- AppKit terminal spawn and Claude CLI behavior cannot be tested in CI; this manual verification is the only gate for steps 3–6.
- Run `xcodebuild test` (or Cmd+U in Xcode) for automated test coverage before running this checklist.
