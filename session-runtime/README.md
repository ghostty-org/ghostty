# Native Session Runtime

The GUI uses a per-pane local/SSH host descriptor. Local windows have no remote routing.
There is no fixed host, global experimental socket override or legacy VPS launcher.

Open **OMG Dev → Settings → Shell & Sessions → Session Runtime**, select the
retention policy, enter an SSH alias or user@host and connect, or open the Session
Library to reattach a background session. **Window -> Browse Sessions** opens
the same native library without going through settings. New local windows, tabs and splits use
the runtime by default; `sessions.localRuntimeEnabled` opts new local terminals
back into ordinary Ghostty PTYs. Deployment uses versioned artifacts bundled with the signed
app. Connections open in the current window's native tab group when available.
SSH command handoff leaves the source local tab and shell available. Splits inherit
their runtime host; restored panes attach by their saved identity.

See [TEST_RELEASE_PATH.md](TEST_RELEASE_PATH.md) for current acceptance steps and
[RELEASE_PROGRESS.md](RELEASE_PROGRESS.md) for remaining public-release gates.

## Runtime architecture

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
