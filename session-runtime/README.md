# Native Session Runtime

The GUI uses a per-pane local/SSH host descriptor. Local windows have no remote routing.
There is no fixed host, global experimental socket override or legacy VPS launcher.

Open **OMG Dev → Settings → Shell & Sessions → Session Runtime**, select the
retention policy, enter an SSH alias or user@host and connect, or create a local
background session. Deployment uses versioned artifacts bundled with the signed
app. Connections open in the current window's native tab group when available.
SSH command handoff leaves the source local tab and shell available. Splits inherit
their runtime host; restored panes attach by their saved identity.

See [TEST_RELEASE_PATH.md](TEST_RELEASE_PATH.md) for current acceptance steps and
[RELEASE_PROGRESS.md](RELEASE_PROGRESS.md) for remaining public-release gates.

## Runtime architecture

One host daemon manages multiple session actors/PTYs. A per-host relay multiplexes
all panes over one SSH connection or local Unix socket. It retains native pane
connections during transport loss, retries transient failures with bounded backoff
and reports authentication/configuration failures for attention. Retry Now does
not replace the Surface or interrupt healthy panes. Confirmed sessions reattach
with the same UUID; disconnected input is discarded and stale generation frames
are rejected. Snapshot plus live output restores the terminal. Remote cwd metadata
comes from the PTY foreground process, falling back to its owning shell, rather
than the Mac launch directory.

Local background sessions use the same daemon/protocol and private channel-scoped
state. Existing ordinary Ghostty Exec terminals keep their original PTYs.

## Tests

Build the matching libghostty-vt first, then run serially:

```sh
cargo test --manifest-path session-runtime/Cargo.toml -- --test-threads=1
cargo build --manifest-path session-runtime/Cargo.toml
python3 session-runtime/tests/test_sessions.py
python3 session-runtime/tests/test_location.py
python3 session-runtime/tests/test_lifecycle.py
python3 session-runtime/tests/test_agent_recovery.py
```

The optional SSH test takes an explicit connection JSON via
`OMG_SSH_TEST_CONFIG`; it never chooses a fixed host.
