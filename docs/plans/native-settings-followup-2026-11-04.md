# Native settings follow-up

Baseline: `fa7ad8a23`.

## Add Host

The regression test reproduced an attached modal sheet with frame
`(258, 765, 385, 0)`: assigning a scroll-backed content controller discarded the
panel's requested height. The parent became modal while its sheet was invisible.
Size the sheet after installing/populating its controller, retain a usable
minimum size, support Cancel/Escape, and show address validation inline.
The test now verifies the sheet dimensions and usable parent after Cancel.

## Appearance

Sidebar and cards use shades of the same terminal palette, removing the mixture
of behind-window material and unrelated system card colors. Native canvas drawing
is bounded to its own bounds; a rendered-color regression caught sidebar paint
leaking into the main canvas.

The AppKit theme gallery previews named themes through Ghostty's own config
parser, without application CLI arguments or final overlays. A selection changes
only the sample until Use Theme is clicked. Light/dark overrides remain separate,
and font/opacity/cursor settings update the sample. Cursor controls are inline.

## Sessions

The UI now says Close local/SSH sessions on quit, with inverse bindings to the
existing keep-on-quit keys. No preference migration changes user behavior.
View all sessions opens an AppKit overview with refresh, reattach and confirmed
bulk close. It uses the same bundled helper as `omg +sessions`.

The CLI defaults to the invoking bundle's channel and reads saved endpoint
descriptors, including older pinned revisions. It never deploys a remote runtime
or creates a PTY. Different routes to the same UUID/generation are deduplicated.
The CLI resolves its helper from its own executable bundle, so an inherited
`GHOSTTY_RESOURCES_DIR` cannot redirect Dev management to the release channel.
Close requires `--all --yes`; all selected endpoints must first return inventory.
Close requests use the existing durable protocol, start before waiting for
graceful termination, maintain the transport lease, and report partial failures.
The command does not use process-name kills or delete session/layout records.

Local processes comprise a shared per-channel/revision broker plus one holder
per PTY. Remote host daemons multiplex sessions using worker threads. Relays and
attached SSH viewers are separate processes; the `omgd` name alone is not a
session count.

## Verification

- Swift: 176 routine suites, 1406 tests passed in five serial fresh-host batches.
- Zig CLI selection, bundle routing and dependency tests: 77 passed.
- Rust: 52 tests, strict Clippy and formatting passed.
- Python runtime tests: 31 run, 29 passed. Real SSH and Linux containment require
  external environments and were skipped, not counted as passed.
- New disposable-process tests cover Dev/release isolation, missing confirmation,
  incomplete inventory blocking all closes, duplicate SSH aliases, warm SSH
  protocol management, and read-only empty catalogues.
- The optional previous-runtime fixture verified current relay compatibility.
- Native Settings tests cover the zero-height sheet, inverse quit bindings,
  preview-before-apply behavior, inline cursor controls and shared palette.
- CLI/table tests never close actual user sessions. Installed-app validation
  uses read-only local UUID/PID comparisons; foreground checks require an
  unlocked desktop.
