# Local sessions and runtime completeness

Date: 2026-11-01. Delivery target: 2026-11-02.
Branch: `cjs/ssh-session-runtime`.

The SSH transport/UI work is committed as `a34d98f03`. The related workspace
window fix from main (`1b9a05a04`) is separately backported as `c408f28f9`; neither
commit is rewritten and the main checkout is not edited.

## Initial review findings

The first local entry shared transport and snapshots, but was not a complete
replacement for normal Ghostty local sessions:

- The daemon starts its own login shell instead of consuming Ghostty's resolved
  command, environment, shell integration, initial input and initial dimensions.
- `OMG_RUNTIME_REMOTE=1` incorrectly marks local Agent hooks as remote.
- The backend exposes no local foreground-process metadata.
- Handoff and Quick Input use app-lifetime directories/capabilities, which cannot
  serve an existing local shell after the app restarts.
- Runtime archives bypass startup-mode policy; layout-only restoration can attach
  an old SSH/local process, and workspace restoration can override new-terminal mode.
- The host owns PTYs in its own threads; losing a local broker loses the PTY owner.
- Existing daemon inventory is not available in a user-facing recovery interface.

The Herdr desktop/core reference remains pinned to
`herdr-app@07ba77e87a8d809ef5a486e09e4ac44cade2c39a` and
`herdr-core@572fdf5c82ef2de5d725b0161f1bdc2ebfe3fee0`. Its local path, independent
PTY holders, machine inventory and view/process lifetime split are the reference.
Its code is Apache-2.0; an actual source port must retain the applicable notices.
This implementation retains the full Ghostty host, its launch preparation and
native VT/rendering rather than importing a second terminal UI.

Herdr closes windows by detaching viewers and ends processes on explicit pane/tab
close. OMG already follows that useful distinction; the older design sentence
claiming every view close detaches must be corrected rather than changing the
working close contract.

## Implementation plan

1. Prepare a local launch request using Ghostty's existing `Exec` setup without
   spawning a local PTY. Send argv/environment/cwd/dimensions and one-time initial
   input only for creation. Never serialize environment into workspace or session
   metadata, never send local launch data to SSH, and never replay it on reattach.
2. Make new local windows/tabs/splits persistent by default, with a setting to use
   classic local PTYs. Preserve live classic sessions. Respect custom commands,
   startup modes and configured directories. Tests and unpackaged developer builds
   must not accidentally connect to user endpoints.
3. Give local sessions stable private Handoff/Quick Input scopes and versioned
   helper paths. Restore the same capability when reconnecting an existing shell.
   Local foreground PID/TTY metadata must never treat remote PIDs as Mac processes.
4. Separate local broker lifetime from local PTY/VT holder lifetime. Re-adopt a
   live holder using UUID, generation and a private capability; never signal an
   arbitrary persisted PID. Preserve the existing remote Linux systemd/cgroup
   ownership contract.
5. Add a native background-session library with endpoint inventory, explicit
   attachment and durable termination. Query only on demand, cancel stale loads,
   keep unknown/ended sessions distinct from fresh shells, and preserve private
   endpoint metadata without storing launch environments.
6. Review error, cancellation, queue-budget, upgrade and close paths again after
   implementation. Validate actual PTYs, app-hosted behavior, cross-platform
   artifacts and the complete changed source tree, then commit the result.

Builds and tests remain serial. The release OMG installation and user sessions
must remain intact. Foreground desktop and real SSH/Linux supervision acceptance
will be reported separately from local fixtures and compilation.

## Implementation interfaces

All agents use the explicit worktree path
`/Users/chengjisheng/.codex/worktrees/ssh-session-runtime/oh-my-ghostty`; a tool's
default working directory may still point at main.

Swift sets `OMG_RUNTIME_LOCAL=1` only for local descriptors.
`OMG_RUNTIME_ATTACH_EXISTING=1` is explicit attach intent; it is independent of
whether the UI Surface was given a UUID. `configureAttachExisting` writes it for
archive/catalog attachment. A fresh local launch has no attach flag.

Zig decorates the base open request only for local creation:

```json
{
  "id": "session UUID",
  "policy": {},
  "create": true,
  "cwd": "/initial/path",
  "launch": {
    "argv": ["/resolved/executable", "argument"],
    "env": {"NAME": "value"},
    "cwd": "/initial/path",
    "cols": 80,
    "rows": 24,
    "pixel_width": 640,
    "pixel_height": 384,
    "input_base64": "optional one-time input"
  }
}
```

`launch` is omitted (not null) for reattach. It must not be forwarded to an SSH
host. It is never saved into a session record or workspace archive. The new local
broker advertises `local-launch/1`; old strict hosts can still attach compatible
saved sessions without this creation payload.

Metadata keeps the exact field names `cwd`, `foreground_pid` and `tty_name`.
`foreground_pid` is the validated foreground process-group ID returned by
`tcgetpgrp`; `tty_name` is a slave PTY path string, not a boolean. Local backend
getProcessInfo exposes these values; the SSH backend never treats them as Mac
process IDs. Disconnect/error/exit clears validity.

`omgd list-local SOCKET` queries a relay without opening a terminal. Its JSON
array is a projection of id/generation/times/pid/ended/resume/policy/cwd and must
exclude holder capabilities, environments and argv. The native library uses
`SessionRuntimeCatalog.shared.remember(descriptor)` and
`SessionRuntimeLibrary.show()`; Connections and Settings own the integration
calls, while the catalog owns its new files and cancellable queries.

## Implementation and validation

The local implementation and system review are complete in the specified
worktree. No installed OMG application was replaced or restarted.

- Local windows/tabs/splits default to persistent sessions. Ghostty prepares the
  actual command, environment, cwd, shell integration, initial input and size.
  Native PID/TTY, password input, command-exit behavior and cwd inheritance are
  preserved. Window close and Undo control attachment explicitly; tab/pane End
  still durably terminates the UUID.
- The native Session Library is available in Window and Settings, with selected
  endpoint queries, cancellation, existing-pane focus, attach and durable End.
  Restore Tabs uses new pane IDs and remaps focus in both workspace and native
  NSWindow archives; Restore Sessions attaches saved IDs; New Terminal skips
  saved workspace ownership.
- Runtime version pins and stable private bridges survive App restart. New local
  sessions use the current runtime revision/default policy without modifying old
  sessions. The classic PTY option preserves native launch configuration.
- Zig: 91 targeted tests passed, including early-input ordering/cancellation,
  generation and attachment epochs, bounded history, snapshot presentation and
  shutdown. The native ReleaseFast GhosttyKit framework was built successfully.
- Rust: 38 tests passed (33 library, 4 integration, 1 VT fixture). Strict Clippy
  and rustfmt pass. Peer buffers share a 128 MiB per-process budget and retain
  their charge until the actual allocation is released.
- Python: 22 integration tests executed, 20 passed and 2 environment-dependent
  tests skipped (real SSH and Linux containment). Tests cover real PTYs, broker
  restart/adoption with unchanged PID, initial input exactly once, delayed
  control-probe bytes, metadata, password mode, resize and relay recovery.
- App-hosted acceptance: all 37 tests in the focused native integration,
  connection and restoration selection passed. The real native fixture checks
  launch/env/cwd/initial and early input, PID/TTY, native inherited cwd, retained
  Surface detach, a second view attaching the same process, original Surface
  resume, normal child exit and refusal to reopen an explicitly closed view.
- All 166 routine Swift suites were covered successfully. The monolithic run
  completed 53 suites before stalling without a failed assertion; a bounded
  sample showed many workers blocked in AppKit NSAnimation while the test host
  had no valid display link. The remaining 113 suites passed in 12 fresh test
  App batches. Two disabled example tests were skipped. Optional interactive
  desktop tests were not run; this is not physical mouse/drag/sleep-wake acceptance.
- Native macOS arm64 and Linux x86_64/aarch64 runtime artifacts were built with
  revision `e620b434be80c3e8e636`, and manifests/launch checks pass. Cross-building
  Linux is not execution on those hosts. The packaged worktree Debug App is
  signed with the existing development identity.
- Documentation, plist, native menu, artifact contracts (2 tests), test-selection
  contracts (41 tests), SwiftLint and whitespace/format checks are included in
  the final checks. Private evidence is under `/tmp/omg-local-*.log` and
  `/tmp/omg-local-full-diagnostics/`; raw diagnostic data is not committed.

The installed OMG Dev was observed running `0.18.0-dev.1b9a05a0`, with potentially
live legacy PTYs. The deliverable is `macos/build/Debug/OMG.app` in this worktree;
installation is separate from the source/build validation. Real SSH
sleep/wake/authentication, Linux supervision and foreground desktop interaction
remain separate acceptance gates rather than inferred passes.

## Final review findings and product boundary

- The intermittent holder-control EOF was reproduced deterministically by
  connecting and delaying the first probe bytes by 100 ms. On this macOS host,
  the accepted socket retained the listener's nonblocking flag and `read_exact`
  returned before the probe arrived. The holder now explicitly switches accepted
  control sockets to blocking mode with bounded read/write timeouts. The new
  delayed-probe fixture failed before the fix and passes with it.
- The daemon's fixed 4 MiB history cap was materially different from Ghostty's
  native default of 50,000,000 bytes and ignored stricter user byte/line limits.
  Local creation now passes the effective byte limit (minimum of user setting
  and 4 MiB, including zero) and optional line limit into the authoritative VT.
  Settings and user documentation disclose the persistent-history ceiling;
  ordinary PTYs remain available for larger histories. The byte ceiling is a
  logical terminal-storage limit, not a resident-memory guarantee.
- Wire snapshots remain bounded at 16 MiB. Oversized/failed snapshots must report
  a clear error; they are never partially restored or used to recreate a process.
- The App-hosted reattachment fixture exposed that closing a window can retain
  its Surface for Undo. Relying on ARC alone left the invisible attachment
  holding the writer. Runtime attachment suspension/resumption is now an
  explicit host operation: closing detaches even a retained Surface, Undo can
  reconnect it, and workspace parking remains attached. The fixture keeps the
  original Surface alive deliberately and checks that a new view can acquire
  the same session writer immediately after window close.
