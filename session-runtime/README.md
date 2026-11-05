# Native Session Runtime

The GUI uses a per-pane local/SSH host descriptor. Local windows have no remote routing.
There is no fixed host, global experimental socket override or legacy VPS launcher.

Open **Settings → Remote Hosts → Add** to register an SSH alias or user@host.
Open a registered host to connect, configure its Agents, or choose automatic
installation of `omgd` and Agent Hooks independently. SSH config aliases appear
only in the Add sheet. **Settings → Shell & Sessions** contains local/SSH quit
policies, the Session Library and secondary retention options.
The Session Library reattaches background sessions. **Window -> Browse Sessions** opens
the same native library without going through settings. New local windows, tabs and splits use
the runtime by default; `sessions.localRuntimeEnabled` opts new local terminals
back into ordinary Ghostty PTYs. Deployment uses versioned artifacts bundled with the signed
app. Connections open in the current window's native tab group when available.
SSH command handoff leaves the source local tab and shell available. Splits inherit
their runtime host; restored panes attach by their saved identity.

See [TEST_RELEASE_PATH.md](TEST_RELEASE_PATH.md) for current acceptance steps and
[RELEASE_PROGRESS.md](RELEASE_PROGRESS.md) for remaining public-release gates.

## Runtime architecture

Agent presentation follows the session rather than the GUI connection. New
`agent-state/1` runtimes retain the latest OSC 3008/7501 contexts while detached,
send their bounded state alongside attachment snapshots, and remove ended
contexts. Inline SSH viewers also transfer this state into the outer local
holder, so reopening the GUI does not require restarting the remote Agent.
Restoring state updates icons/status without repeating completion actions.
Existing sessions on pinned older helpers keep their original behavior.

One remote host daemon manages multiple session actors/PTYs. Locally, a broker
connects independent holders that own each PTY, child and VT state; losing the
broker does not kill those sessions. A new broker authenticates and adopts the
same holders. A per-host relay multiplexes
all panes over one SSH connection or local Unix socket. It retains native pane
connections during transport loss, retries transient failures with bounded backoff
and reports authentication/configuration failures for attention. Retry Now does
not replace the Surface or interrupt healthy panes. Confirmed sessions reattach
with the same UUID; disconnected input is discarded and stale generation frames
are rejected. Snapshot plus live output restores the terminal. Remote cwd metadata
comes from the PTY foreground process, falling back to its owning shell, rather
than the Mac launch directory.

The process name alone does not identify an `omgd` role. On this Mac,
`host-local` is a shared broker and `session-holder` is one process per local
PTY, so a broker restart can preserve each shell. On an SSH host, `host` owns
multiple session workers in threads. `connect` is an app-side shared relay;
`handoff`/`handoff-cwd` are attached SSH viewers. Release, Dev and still-used
runtime revisions remain isolated. Closing a session uses its UUID and durable
close protocol; killing every process named `omgd` is not session management.

Local sessions use the same protocol and private channel-scoped state. Ghostty
prepares the actual shell/custom command, environment, directory, initial input
and terminal dimensions. Only first creation consumes that launch configuration.
Foreground PID/TTY and password-input state preserve the native local behavior.
Existing ordinary Ghostty Exec terminals keep their original PTYs.

Persistent terminal history has a **4 MiB logical byte ceiling**, including
active-screen storage. Local sessions preserve a lower Ghostty byte limit
(including zero) and the configured line limit. This differs from Ghostty's
native 50,000,000-byte default; choose ordinary PTYs when larger history is
needed. Snapshot and attachment sizes remain bounded, and an unrepresentable
snapshot is reported as an error rather than restored partially.

Closing a window or quitting OMG detaches sessions. Closing a tab/pane, or
confirming End in the Session Library, durably ends the affected session.
`restoreSessions` reconnects saved runtime UUIDs; `restoreTabs` opens fresh local
processes in the saved layout, and `newTerminal` skips the old layout entirely.
Inventory lookup is read-only and does not reset detached-session expiry.

## Host setup preferences

Newly registered hosts enable runtime installation and leave automatic Hook
installation off. Existing registrations without either preference preserve
their previous behavior. Disabling runtime installation still permits a warm
connection to an existing matching daemon; a missing runtime produces an
actionable error without probing or deploying artifacts.

`install-runtime CONNECTION_JSON` explicitly installs the bundled runtime for
an SSH host, even when automatic installation is disabled. Deployment remains
versioned and preserves sessions on pinned older daemons. The GUI tracks and
cancels these bounded installation jobs on shutdown or host removal.

The GUI writes the private `CONNECTION_JSON.setup.json` sidecar with
`{"auto_install": false}` (or `true`). The main connection JSON retains its old
schema because cached inline viewers reject unknown fields. A missing sidecar
uses legacy behavior; a malformed sidecar fails closed. This is a local
deployment preference, not a daemon wire-protocol change.

## Session management CLI

The bundled OMG executable exposes these actions in `omg --help`:

```sh
omg +sessions list
omg +sessions list --local --json
omg +sessions list --host user@example.com
omg +sessions close --all --yes
```

The default scope is this app channel's saved endpoint catalogue, including
local and SSH sessions pinned to older revisions. Dev never silently includes
release sessions. `--app-support PATH` explicitly selects a different catalogue
for tooling and disposable fixtures. An absent catalogue returns an empty list
without creating it. Inventory reuses or restarts the existing pinned broker
without creating a terminal session; it never deploys remote artifacts.

JSON output contains `sessions`, `errors` and `closed`. Exit 1 can accompany a
partial inventory; callers must inspect errors and must not treat it as an empty
host. Bulk close requires `--all --yes`, first queries every selected endpoint,
and performs no close when that inventory is incomplete. It closes only the
snapshot's running UUIDs, waits for durable close acknowledgements, and reports
partial close errors without killing daemons or deleting layouts.

Settings → Shell & Sessions → View all sessions uses the same helper and adds a
native confirmation before bulk close. The exit switches explicitly mean
**Close local/SSH sessions on quit**; their values invert the existing persisted
`sessions.keepLocalOnQuit` / `sessions.keepSSHOnQuit` booleans without migration.

## Remote Quick Input

New managed SSH PTYs receive a private external-editor bridge under
`STATE/draft`. It reuses the ordinary SSH editor-file protocol and delegates
normal editor invocations to the previous editor. An explicit short-lived
request copies the draft without changing the Agent's input file.

The bridge is bound to the runtime pane UUID, generation and PTY. GUI imports
resolve those fields from the saved runtime record rather than requiring a
transient `+ssh` bootstrap connection ID. Requests from an earlier generation
are rejected, and teardown only removes its own generation's data. The embedded
Python source participates in the runtime artifact revision.

Python 3 and an Agent honoring `VISUAL`/`EDITOR` are required. Previously launched
remote Agents do not gain new environment variables when the Mac app updates.
Keep their current work running; start a new SSH session and resume the Agent
when ready to enable this bridge. Existing pinned daemons are preserved.

## Tests

Build the matching libghostty-vt first, then run serially:

```sh
cargo test --manifest-path session-runtime/Cargo.toml -- --test-threads=1
cargo build --manifest-path session-runtime/Cargo.toml
python3 session-runtime/tests/test_sessions.py
python3 session-runtime/tests/test_location.py
python3 session-runtime/tests/test_lifecycle.py
python3 session-runtime/tests/test_agent_recovery.py
python3 session-runtime/tests/test_local_runtime.py
```

The optional SSH test takes an explicit connection JSON via
`OMG_SSH_TEST_CONFIG`; it never chooses a fixed host.
