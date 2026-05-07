# Full-Loop Smoke Test

Run this checklist before tagging each beta release to verify the entire task loop works: Linear sync → click row → Claude spawns → work completes → status updates.

## Prerequisites

- Ghostties.app built in Release configuration and installed at `/Applications/Ghostties.app`
- `ghostties-mcp` server registered in Claude Code's `~/.mcp.json` (local MCP server for task context)
- Linear MCP registered in Claude Code's `~/.mcp.json` (for `linear-sync` preset)
- `ghostties` project added to the Workspace sidebar (project name: `ghostties`, path: `~/Code/ghostties`)

## Steps

**1. Launch without banner**  
Open Ghostties.app from Finder (not terminal).  
**You'll see:** no yellow/orange callout at the top of the Tasks sidebar. The sidebar shows your zones directly.

**2. Sync Linear inbox**  
Open any terminal pane. Run Claude Code with the `linear-sync` preset (or ask Claude to sync your Linear inbox).  
**You'll see:** at least one task card appears in the Inbox zone. Run `cat .ghostties/tasks/<id>.md` and confirm `template: Claude Code` and `project-path:` are present.

**3. Click task row and verify spawn**  
Click any Inbox task with project context (skip orphan triage cards).  
**You'll see:** (a) your default editor opens the task file, (b) the task row moves to the Active zone within 1–2 seconds, (c) a new terminal session opens at the project directory, (d) the session banner shows `task: <id> · file: <path> · cwd: <dir>`. Run `echo $GHOSTTIES_TASK_FILE` to confirm.

**4. Generate test artifact**  
In the spawned Claude session, ask: "Write `docs/hello.md` containing the task title and today's date."  
**You'll see:** `docs/hello.md` appears in Finder at the project path. Run `cat docs/hello.md` to verify it contains the task title and today's date.

**5. Mark done**  
Run `gt done <task-id>` in the same terminal.  
**You'll see:** terminal prints `✓ marked done: <title> (NNms)`. The task row moves from Active to Graveyard within 1–2 seconds.

**6. Offline self-check**  
Run `gt smoke` from inside the project directory (any directory with a `.ghostties/tasks/` ancestor).  
**You'll see:** `OK — smoke passed`. If you see `FAIL:`, report the step that failed.

## Failure Handling

If any step fails, note the step number and failure mode in the release notes. Steps 1–5 are release blockers (no ship). Step 6 (offline self-check) is a developer signal — if it fails with no `.ghostties/tasks/` directory present, it will print a friendly error rather than crash; run it from inside the project root.

## Clean Up

After smoke test passes, remove the test artifact:

```bash
rm docs/hello.md
```

## Notes

- AppKit terminal spawn and Claude CLI behavior cannot be tested in CI; this manual verification is the only gate for steps 3–5.
- Run `xcodebuild test` (or Cmd+U in Xcode) for automated test coverage before running this checklist.
- `gt smoke` (step 6) runs fully offline — no app running, no Linear needed. It creates, verifies, and deletes a temp task file automatically.
