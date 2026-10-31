# Session Runtime release implementation contract

This extends the native PTY prototype. Shipping remains gated on artifact coverage,
authentication, real Agent recovery and cross-platform acceptance. An arbitrary SSH
endpoint is not necessarily a supported shell host (SFTP-only/appliances/noexec are
explicit errors, not a silent downgrade to a non-durable PTY).

## Automatic connection

Use the user's exact SSH identity and routing options. Probe OS/arch and platform
requirements, select a bundled versioned runtime artifact, verify hashes, upload via
SSH stdin to a private user directory, atomically publish it, and start a detached
host daemon. No root, package-manager or remote compiler dependency. Authentication
uses system SSH, including agent/config/jump-host; BatchMode-only failure must be
visible. Existing daemon versions with live sessions are not replaced or restarted.
Keep the host runtime revision in restored pane descriptors. One host connection
multiplexes native session streams; normal tabs remain local unless a runtime
connection descriptor is attached. Original shell PTY is never a relay.

A split inside a native SSH pane creates a new remote PTY on the same exact SSH
connection and passes the current remote directory as optional `cwd`. The host
validates the path and sets it on the new child command without shell evaluation
or process-wide `chdir`. Existing-session attach ignores this creation hint;
Agent resume still uses its recorded directory. New splits use current bundled
artifacts to support this request field; already running panes stay on their
pinned versions. The native remote terminal's history remains separate from the
local terminal. Handoff opens a sibling native tab in the same workspace, leaves
the original local Surface in place and returns its helper to the local prompt.
The settings connection entry follows the same native tab path when a terminal
window is available.

The relay keeps local pane sockets open across SSH loss, with one retry supervisor
per exact connection/revision. The existing Surface applies a fresh snapshot on
reattach. Transient failures retry with bounded backoff; authentication/configuration
failures wait for user attention. Automatic attempts never repeatedly invoke
askpass. A manual retry does not tear down healthy panes on that host. Generation
fencing discards stale input, resize, writer and snapshot-acknowledgement frames.
No disconnected keystrokes are queued for replay.

Before opening streams, the relay requires the host's `strict-open/1` capability.
Older cached runtimes may support the same snapshot format but implicitly resume
retired Agents on an attach request. Those versions receive a compatibility
error, with their processes preserved; use the matching earlier app to access
them. They are not silently replaced or upgraded while holding sessions.

The local background-session entry uses the same descriptor, relay and host
protocol over a Unix socket. Its versioned daemon state is private and isolated
by application channel. This does not migrate already running ordinary local PTYs.
New tabs/splits from a local runtime session use its local runtime; SSH context
and remote filesystem routing are never inferred merely from having a runtime.

Initial artifact targets: Linux x86_64/aarch64 with documented libc baseline;
macOS arm64/x86_64 via native build runners. Unsupported platforms fail explicitly.
Binaries and manifests are produced from the same checkout as the GUI snapshot
codec. No claim of arbitrary cross-version snapshot compatibility.

## Lifecycle defaults and controls

- Maximum detached lifetime: 72 hours (3 days); configurable, 0 disables only this limit.
- Optional UTC expiration deadline: applies while detached, even if output continues.
- No heartbeat for a bounded lease: considered detached even on half-open links.
- Last child exit: reap PTY/process resources immediately; retain reason/metadata.
- Close after Agent task completion [Beta]: off by default. Unsupported Agents
  remain running like ordinary processes, subject to detached TTL/deadline and
  explicit close. Existing explicit settings/session policies are preserved.
  When enabled, only detached
  sessions with a validated durable conversation resume record; grace period 60s.
  New input, working/attention/error events or reattach cancels pending completion.
  The grace period starts after both completion and detach. Completion and detached
  TTL are independent retirement conditions: either can retire a session first;
  disabling one does not disable the other.
- Graceful process termination then bounded kill escalation; PTY foreground process
  group and owned session leader are handled, never unrelated reused PIDs.
- Empty host daemon exits after 5 minutes; closed session metadata expires after
  7 days (configurable). Active session and total metadata quotas are separate.

A fresh connection/reattach is not a new command execution. Resume is an explicit
operation only for eligible retired runtime generations. Unknown/lost sessions do
not silently recreate shell/Agent processes. PID changes after resume are expected;
conversation ID and remote identity/project directory must remain stable.

## Agent recovery

Daemon persists typed resume metadata atomically before lifecycle-driven shutdown:
agent identifier, validated conversation ID, project cwd, runtime generation and
source. Do not store arbitrary executable strings from terminal output. Hook events
arrive over the private local control socket with a per-session nonce and generation;
stdout/OSC or UI guesses alone cannot authorize process termination. Bind events to
the live child session. Preserve a resume record after `end`, distinct from current
activity; a new Agent invocation must not inherit stale completion.

Start with manifest-backed Codex/Claude/Pi recovery. Validate remote conversation
store before auto-close on completion; unsupported/no-ID agents remain alive until
the detached TTL or explicit close, with recovery capability shown honestly.

## Verification gates

Real SSH automatic first deployment and existing installation reuse, failed upload
cleanup, version mismatch without restart, two hosts and pane restoration, half-open
lease expiry, detached TTL/deadline, output flood not renewing TTL, user input versus
completion race, process-group termination/reaping, empty daemon exit, closed-entry
GC/quota release, and real Agent conversation resume with a new PID but same ID.
Update docs/PLUGIN_DEVELOPMENT.md when hooks/permissions/lifecycle contracts change.
