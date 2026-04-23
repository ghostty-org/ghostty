#!/usr/bin/env bash
# smoke-mcp.sh — exercise ghostties-mcp stdio surface end-to-end.
#
# 1. Build a fresh release binary.
# 2. Create a clean working dir with no .ghostties/.
# 3. Pipe a scripted sequence of JSON-RPC calls on stdin.
# 4. Assert the responses look right and the task file was written.
#
# Exits 0 on success, non-zero on any failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI_DIR="$REPO_ROOT/cli"
BIN="$CLI_DIR/.build/release/ghostties-mcp"
WORKDIR="${MCP_SMOKE_DIR:-/tmp/mcp-smoke}"

echo "[smoke] building release binary"
(cd "$CLI_DIR" && swift build -c release) >&2

if [[ ! -x "$BIN" ]]; then
  echo "[smoke] FAIL: binary not found at $BIN" >&2
  exit 1
fi

echo "[smoke] resetting workdir $WORKDIR"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/.ghostties/tasks"

echo "[smoke] driving server with scripted JSON-RPC"

# Each line is one JSON-RPC request. `notifications/initialized` has no id
# (it's a notification) so it expects no response.
OUTPUT="$(cd "$WORKDIR" && "$BIN" --tasks-dir "$WORKDIR/.ghostties/tasks" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0.0.1"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"create_task","arguments":{"title":"MCP smoke","project":"ghostties","lane":"backlog"}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_tasks","arguments":{}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"append_task_notes","arguments":{"id":"mcp-smoke","text":"a note from the smoke test"}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_task","arguments":{"id":"mcp-smoke"}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"read_task_notes","arguments":{"id":"mcp-smoke"}}}
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"update_task_status","arguments":{"id":"mcp-smoke","status":"running"}}}
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_active","arguments":{}}}
EOF
)"

RESULT_FILE="$WORKDIR/smoke-output.jsonl"
printf '%s\n' "$OUTPUT" > "$RESULT_FILE"
echo "[smoke] captured $(wc -l < "$RESULT_FILE") response lines → $RESULT_FILE"

# --- Assertions ----------------------------------------------------------

fail() { echo "[smoke] FAIL: $1" >&2; exit 1; }

# Small helper: extract response for a given id using python (no jq dep).
jq_id() {
  local id="$1"
  python3 - "$RESULT_FILE" "$id" <<'PY'
import json, sys
path, target = sys.argv[1], int(sys.argv[2])
for line in open(path):
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("id") == target:
        print(json.dumps(obj))
        break
PY
}

# 1. initialize → protocolVersion present
init_resp="$(jq_id 1)"
[[ -n "$init_resp" ]] || fail "no response for initialize"
echo "$init_resp" | grep -q '"protocolVersion"' || fail "initialize missing protocolVersion: $init_resp"
echo "$init_resp" | grep -q '"serverInfo"' || fail "initialize missing serverInfo"
echo "[smoke] ok  initialize"

# 2. tools/list → 9 tools
tools_resp="$(jq_id 2)"
count="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d['result']['tools']))" "$tools_resp")"
[[ "$count" == "9" ]] || fail "expected 9 tools, got $count"
echo "[smoke] ok  tools/list (9 tools)"

# 3. create_task → success, not isError
create_resp="$(jq_id 3)"
python3 - "$create_resp" <<'PY' || fail "create_task failed: $create_resp"
import json, sys
d = json.loads(sys.argv[1])
res = d["result"]
assert res.get("isError") is False, res
text = res["content"][0]["text"]
payload = json.loads(text)
assert payload["title"] == "MCP smoke", payload
assert payload["lane"] == "backlog", payload
PY
echo "[smoke] ok  create_task"

# Verify file on disk
files="$(ls "$WORKDIR/.ghostties/tasks")"
echo "$files" | grep -q '^mcp-smoke-.*\.md$' || fail "created file missing: saw [$files]"
echo "[smoke] ok  file written: $(echo "$files" | head -1)"

# 4. list_tasks sees the new task
list_resp="$(jq_id 4)"
python3 - "$list_resp" <<'PY' || fail "list_tasks missing new task: $list_resp"
import json, sys
d = json.loads(sys.argv[1])
arr = json.loads(d["result"]["content"][0]["text"])
titles = [t["title"] for t in arr]
assert "MCP smoke" in titles, titles
PY
echo "[smoke] ok  list_tasks"

# 5. append_task_notes landed in file
append_resp="$(jq_id 5)"
python3 - "$append_resp" <<'PY' || fail "append_task_notes returned no notes: $append_resp"
import json, sys
d = json.loads(sys.argv[1])
payload = json.loads(d["result"]["content"][0]["text"])
assert "a note from the smoke test" in payload["notes"], payload
PY
# Also grep the actual file to prove on-disk persistence.
smoke_file="$(ls "$WORKDIR/.ghostties/tasks"/mcp-smoke-*.md)"
grep -q "a note from the smoke test" "$smoke_file" || fail "note not persisted to $smoke_file"
echo "[smoke] ok  append_task_notes"

# 6. get_task round-trip
get_resp="$(jq_id 6)"
python3 - "$get_resp" <<'PY' || fail "get_task failed: $get_resp"
import json, sys
d = json.loads(sys.argv[1])
payload = json.loads(d["result"]["content"][0]["text"])
assert payload["title"] == "MCP smoke", payload
assert "a note from the smoke test" in payload["notes"], payload
PY
echo "[smoke] ok  get_task"

# 7. read_task_notes
read_resp="$(jq_id 7)"
python3 - "$read_resp" <<'PY' || fail "read_task_notes failed: $read_resp"
import json, sys
d = json.loads(sys.argv[1])
payload = json.loads(d["result"]["content"][0]["text"])
assert "a note from the smoke test" in payload["notes"], payload
PY
echo "[smoke] ok  read_task_notes"

# 8. update_task_status → running
upd_resp="$(jq_id 8)"
python3 - "$upd_resp" <<'PY' || fail "update_task_status failed: $upd_resp"
import json, sys
d = json.loads(sys.argv[1])
payload = json.loads(d["result"]["content"][0]["text"])
assert payload["lane"] == "running", payload
PY
echo "[smoke] ok  update_task_status → running"

# 9. get_active now contains the task
active_resp="$(jq_id 9)"
python3 - "$active_resp" <<'PY' || fail "get_active missing task: $active_resp"
import json, sys
d = json.loads(sys.argv[1])
arr = json.loads(d["result"]["content"][0]["text"])
titles = [t["title"] for t in arr]
assert "MCP smoke" in titles, titles
PY
echo "[smoke] ok  get_active"

echo "[smoke] PASS"
