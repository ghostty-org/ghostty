# Shared local and SSH session runtime

Date: 2026-11-01. Branch: `cjs/ssh-session-runtime`, based on `58ced12ab`.
The main checkout's concurrent workspace/tab changes are outside this worktree.

## Reference and diagnosis

The reference is the Herdr desktop application and core, inspected from their
official Git repositories:

- `herdrdev/herdr-app`, `07ba77e87a8d809ef5a486e09e4ac44cade2c39a`:
  `src/window.rs` keeps machine-qualified terminals in the window model;
  `src/terminal.rs` retains a terminal view while attaching asynchronously.
- `herdrdev/herdr-core`, `572fdf5c82ef2de5d725b0161f1bdc2ebfe3fee0`:
  `crates/herdr-core/src/remote.rs` owns a multiplexed connection per machine,
  reports connection/login/update states, reconnects retained viewers to the
  same terminal address, and rejects input while disconnected.
- The older `herdrdev/herdr` CLI also has endpoint supervisors, but its TUI
  projection model is not the desktop implementation.

These are design references, not imported implementations or compatible wire
protocols. OMG retains the full Ghostty macOS host and native terminal rendering.

The existing OMG host already owns persistent PTYs. The missing boundary is the
client connection lifetime: `connect` exits with SSH, `SessionBackend.reader`
exits on EOF, and the GUI's recovery action replaces the Surface. The SSH command
handoff also removes the local Surface from the split tree and keeps it hidden
until the remote process exits. The settings connection entry opens a separate
window. Those behaviors explain the discontinuity without implying that the
remote daemon destroyed its session.

## Implementation contract

- The relay owns a stable local listener and client connections. SSH loss changes
  endpoint state, preserves the current terminal display and retries with bounded
  backoff. Authentication/configuration failures require attention; background
  retries do not repeatedly invoke askpass.
- A per-pane attachment generation retires in-flight input/resize/writer requests. Input
  is never buffered for replay after reconnect. Snapshot acknowledgement and
  writer acquisition precede new input.
- Reconnection attaches the original pane UUID. Once a snapshot confirms a
  session, reconnect uses `create=false`; failure never silently substitutes a
  fresh shell. The existing explicit Agent resume policy remains separate.
- SSH command handoff and settings launch use a sibling native tab in the current
  workspace. The source local Surface, shell, history and selection remain
  available. Successful handoff returns the local shell immediately.
- Local background sessions use the same descriptor, relay, host daemon,
  snapshot and close lifecycle. Only transport establishment differs. Existing
  ordinary Ghostty Exec sessions are not migrated or restarted.
- Retry Now asks the existing relay to retry. It does not replace a Surface,
  change its UUID, or terminate a shared connection with healthy panes.
- Existing saved SSH descriptors continue to decode. Local runtime sessions stay
  local for Git, files, history and Agent context routing.

## Validation

Required coverage includes transport loss with two attached panes and unchanged
PTY PIDs, stale input/ACK rejection, retry/attention behavior, independent session
exit, local attach/detach, lost-session refusal, handoff acknowledgement, retained
native tabs, state restoration and compatibility with existing close policy.

Build and test runs are serial. Native desktop interaction, real SSH password
authentication, suspend/resume, and long-running real Agent workloads are separate
acceptance checks; fixture tests cannot establish those outcomes.

Final focused validation:

| Check | Result |
| --- | --- |
| Zig snapshot, reattach, mailbox ownership and input-generation selection | 75 passed |
| Rust unit and native PTY integration tests | 19 passed |
| Python runtime integration discovery | 16 passed; 2 skipped |
| Packaged macOS runtime/SSH/context suites | 66 passed; 0 skipped |
| Swift test-selector contract | 41 passed |
| Runtime bundle contract tests | 2 passed |
| SwiftLint, Rust formatting, documentation and diff checks | Passed |
| Native GhosttyKit and Debug App build | Passed |
| Runtime artifacts: macOS arm64, Linux x86_64, Linux aarch64 | Built and manifest-verified |
| Debug App deep/strict code-signature verification | Passed |

The runtime artifact revision is `ce85017e0f3c9da4cf89`; it was recomputed from
the final runtime/snapshot sources and matches the packaged revision. The
packaged app is `macos/build/Debug/OMG.app` in this worktree. No application in
`/Applications` was replaced.

Real PTY fixtures verify two panes surviving an interrupted SSH bridge with the
same sockets, UUIDs and PIDs; stale input/resize/ACK rejection; healthy-sibling
isolation during retry and close; authentication attention without a retry loop;
missing UUID refusal; local cold daemon startup and relay restart with the same
PTY PID; and handoff releasing the original shell on acceptance. The fake SSH
bridge uses temporary local sockets and does not log into a user host.

The two skipped Python cases require an explicit real SSH configuration and a
disposable Linux systemd host. Real password/host-key interaction, suspend/resume
and vendor Agent workloads remain separate acceptance work.

The whole-repository Swift run is not green. An initial broad run reported 1,290
passes, 3 failures and 2 skips. The runtime split fixture failure was fixed and
passes in the final focused run; the modal-event case passed when isolated.
`TerminalWorkspaceManagementTests.nativeTabObservationSurvivesRepeatedBorderlessStyleChanges()`
still fails in isolation, outside the runtime paths. Another broad attempt
stalled in a Git test; a bounded sample showed 75 dispatch workers blocked in
AppKit animation loops, and only that task-owned test process was stopped.
The explicit native visual tab test failed its foreground/key-window prerequisite,
so physical desktop interaction is not accepted as passed.

Evidence logs are retained locally:

- `/tmp/omg-runtime-zig-tests.log`
- `/tmp/omg-runtime-rust-tests.log`
- `/tmp/omg-runtime-python-tests.log`
- `/tmp/omg-runtime-swift-final-targeted.log`
- `/tmp/omg-runtime-swift-final-summary.json`
- `/tmp/omg-runtime-swift-summary.json` (initial broad run)
- `/tmp/omg-runtime-existing-regressions.log`
- `/tmp/omg-runtime-test-hang.sample`
- `/tmp/omg-runtime-artifact-build.log`
- `/tmp/omg-runtime-artifact-check.log`
- `/tmp/omg-runtime-codesign-check.log`
