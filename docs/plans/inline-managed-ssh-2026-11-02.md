# Inline managed SSH and workspace presentation

## Required behavior

Ordinary-looking SSH in the current pane must remain managed: remote PTYs stay
in the background, reconnect attaches the original session, splits inherit the
remote host/directory, and remote file providers keep their context. Remote exit
returns to the existing local shell without creating or closing a native tab.
Disabling the `omg +ssh` interception is explicitly not the requested solution.

## Reference review

Reference checkouts are private copies under the task evidence directory:
`herdrdev/herdr-core`, `herdrdev/herdr-app`, and the older `herdrdev/herdr`.
Herdr Core's `attach.rs`, `viewers.rs`, and `relay.rs` separate viewer lifetime
from the background terminal, stream terminal bytes, restore a screen on
reattach, filter terminal queries already answered by the authoritative VT, and
reset terminal modes when the viewer returns to its calling shell.
Herdr App's `terminal.rs` attaches its view to the same background terminal and
retains its last picture while reconnecting. Its machine connections and an
ordinary SSH process inside a local terminal are separate paths; the reference
does not justify removing OMG's managed SSH capabilities.

## Implementation direction

- Keep the current local Surface and PTY. The SSH helper becomes an inline
  viewer of the remote runtime, forwarding input, output and size changes.
  Its controlling local PTY keeps it alive across GUI detachment.
- Authenticate the existing pane-scoped handoff request, but return an approved
  connection configuration to the helper instead of opening a native tab.
- Keep relay lifetime with the inline viewer, rather than a GUI-owned temporary
  socket, so closing/restarting the GUI does not break the nested SSH viewer.
- Reuse the existing strict session identity, snapshot/ACK/writer-generation
  barrier, retry behavior and durable Close. Do not recreate a missing remote
  process or send disconnected keystrokes to a later generation.
- Preserve the local/remote context needed for split, file providers, app
  restoration and explicit pane closure. Normal remote exit releases the helper
  and returns to the same local shell.
- Respect terminal authentication, cancellation and mode restoration. Keep
  authorization and wire metadata out of visible terminal text.

## Confirmed workspace flash

The supplied 30 fps recording shows a connection banner at frames 60-61 and 88.
It consumes terminal height, disappears on readiness, and causes the terminal
to reflow again. It is not evidence that the whole window was destroyed.
Runtime status now uses a compact overlay, delays transient progress for 400 ms,
and never changes the terminal's geometry. Four focused presentation tests
cover fast attach, delayed progress, actionable failures/exit, and constant
terminal bounds across status changes.

## Verification

The implementation keeps the existing Surface and delegates active inline
terminal queries to the enclosing local VT. The remote daemon resumes reply
ownership after detach. Herdr's output filter now runs beside the authoritative
VT so answered queries are not forwarded twice. `inline-viewer/1`, a typed Open
flag and the writer claim negotiate this behavior. Snapshot sequence numbers
match the processed/forwarded stream, including buffered control boundaries.
The inline viewer waits for writer acquisition before exposing output and
inserts context metadata only at parser ground. Repaint retains the former
viewport in local scrollback; local terminal contents are never sent upstream.

Private real-host acceptance confirmed:

- One native tab and the same local pane throughout managed SSH.
- The local history remains above the remote prompt.
- Killing/restarting only the GUI preserves the inline helper and remote shell
  PID, and restores the original pane identity.
- A remote split inherits the selected remote directory.
- Files lists a file created in a private remote test directory, for both the
  original inline pane and its native remote split.
- Remote split exit removes that split automatically. Inline exit returns code
  zero to the same original local shell, leaving one tab.

The isolated profile needed the same enabled SSH plugin/host configuration as
the user's app. Its SSH wrapper restored the ordinary connection environment
instead of forwarding the profile's CFFIXED/XDG isolation variables. Test
directories/sessions were cleaned without touching user sessions.

Real resizing exposed an additional cursor-origin bug in the initial viewer:
the remote VT did not include the local history prefix. The query-ownership
repair is covered by three PTY integration cases: normal exit, transport
reconnect without process recreation or stale input, and resize with cursor
reports from the outer terminal. A subsequent real-host attempt was blocked by
the configured jump route returning connection refused; the final query repair
has not been accepted visually on that host. Transient proxy banner errors are
retryable, while malformed private keys remain actionable authentication errors.

Final validation:

- All 173 routine Swift suites were covered in 35 fresh-host batches (1,377
  tests). The only failure was the former recovery view's below-text button
  assertion; it was updated to require the compact header, bounded explanation
  and non-overlapping controls. The recovery/presentation recheck passed all
  eight tests. The batch failure and corrected recheck are recorded separately.
- 45 Rust tests passed; the Python runtime run passed 23 tests and skipped two
  environment-gated SSH/Linux containment cases. SSH-filtered Zig tests passed
  112 tests and session-filtered tests passed 106 (these filter totals overlap).
- Strict SwiftLint, Clippy, formatting, docs, test-selector and settings/plist
  checks passed. macOS arm64 and Linux x86_64/aarch64 runtime bundles validated.
- Each runtime platform includes the Herdr license/notices in its hashed
  manifest. Runtime revision inputs now also include Cargo.toml, notices and
  the build recipe so dependency/packaging edits cannot reuse a stale revision.
- The last desktop prerequisite check reported a locked desktop, so further
  interactive desktop checks are not counted as passed. The real-host and
  final-query-visual boundaries above remain explicit.
