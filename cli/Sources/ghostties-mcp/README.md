# ghostties-mcp

Model Context Protocol server for Ghostties tasks. Exposes the same
`.ghostties/tasks/` state the sidebar and `gt` CLI use, so any user-run agent
(Claude Code, Cursor, aider) can read and drive the workspace.

Talks MCP protocol version `2024-11-05` over stdio (JSON-RPC 2.0, one message
per line). Logs go to stderr; stdout is protocol-only.

## Install

From the repo root:

```bash
cd cli
swift build -c release
cp .build/release/ghostties-mcp /usr/local/bin/ghostties-mcp
```

## Register with Claude Code

Add to your `.mcp.json` (or `~/.claude.json` global config):

```json
{
  "mcpServers": {
    "ghostties": {
      "command": "/usr/local/bin/ghostties-mcp",
      "args": ["--tasks-dir", "/absolute/path/to/your/.ghostties/tasks"]
    }
  }
}
```

If `--tasks-dir` is omitted the server walks up from its cwd looking for
`.ghostties/tasks/`, git-style, stopping at `$HOME`.

## Tools

| Tool                 | Input                                                                                                   | Returns                        |
| -------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------ |
| `list_tasks`         | `lane?`, `project?`, `source?`                                                                          | Array of task summaries        |
| `get_task`           | `id`                                                                                                    | Full task + parsed `## Notes`  |
| `create_task`        | `title`, `source?`, `branch?`, `project?`, `project_path?`, `template?`, `lane?`, `priority?`, `notes?` | The created task               |
| `update_task_status` | `id`, `status`                                                                                          | The updated task               |
| `get_active`         | —                                                                                                       | Tasks in `running` lane        |
| `get_needs_you`      | —                                                                                                       | Tasks in `needs-you` lane      |
| `get_inbox`          | —                                                                                                       | Tasks in `inbox` lane          |
| `read_task_notes`    | `id`                                                                                                    | `{id, notes}`                  |
| `append_task_notes`  | `id`, `text`                                                                                            | `{id, notes}` after the append |

`id` accepts a unique prefix. Status values accept `graveyard` as an alias for
`done` (matches the `gt` CLI).

Results are returned as an MCP text content block whose text is JSON. Tool-level
errors return `isError: true` with a human-readable message instead of a
JSON-RPC error.

## Debugging

- All logs go to **stderr**, prefixed `[ghostties-mcp]`. Redirect stdin/stdout
  and watch stderr when reproducing a problem.
- Use `--tasks-dir` to pin the tasks directory — useful when Claude Code
  launches the server with a working directory you don't control.
- Smoke test: `cli/scripts/smoke-mcp.sh` pipes a scripted sequence of JSON-RPC
  calls through the binary and asserts on the responses.
- XCTest suite: `cd cli && swift test --filter GhosttiesMCPTests` runs the
  same protocol coverage under CI and fails loudly on regressions.
- `--version` prints the server version and exits.
