# OMG 0.19.1 · Ghostty 1.3.2-dev

OMG 0.19.1 is a fixes release for Agent status across SSH sessions, native tab
dragging, Quick Input, and split Surface ownership. It also carries the native
settings rebuild and session-retention preferences that were committed after
0.19.0 was published. The Ghostty base is unchanged.

## Highlights

- **Show Agent status for SSH sessions in the sidebar.** Inline viewers publish
  working-directory and terminal-mode metadata while attaching. Those updates no
  longer read as "the remote Agent returned to its shell", so a Codex or Claude
  Agent running inside a managed SSH pane keeps its sidebar badge. Fixes #35.
- **Read program status from the code itself.** Codex-family Agents that publish
  native program status on the terminal stream now report idle/working/done to
  the shared status reducer, alongside the existing Agent Hook reporting.
- **Keep tab dragging predictable.** Tab reorder, attach, and surface moves are
  committed after the drag session completes instead of inside AppKit's tracking
  loop, an early drag release is preserved rather than dropped, and the native
  order is republished before the drag preview settles.
- **Match Agent badges between the tab icon and the sidebar.** Symbol and color
  derivation now lives in one semantic badge used by the tab icon and both tab
  orientations, so vertical tabs keep the question bubble, permission shield,
  and tinting instead of following the terminal accent color.
- **Make Quick Input work in managed SSH sessions.** Each runtime provisions the
  Python editor protocol under its own private draft directory before the PTY
  starts, so a remote Agent has editor/session registration and its unsent draft
  can be imported. Queued messages are dispatched after an import settles, and
  dock frames are published before the hosted terminal leaves move.
- **Stop retired split wrappers from resizing the Surface.** Only the wrapper
  whose document view currently contains a Surface may change geometry, scroll
  position, or core resize state, so a remounted Surface cannot be overwritten
  by the wrapper SwiftUI is retiring.
- **Native settings and session retention.** Preferences are rebuilt as AppKit
  pages with registered host details, separate runtime and Agent Hook
  installation preferences, theme previews, and a shared local/SSH session
  overview. Quit-accepted retention policies persist owned Close intents and
  drain remote sessions before local carriers.

## Version and scope

- OMG version: **0.19.1**; bundle version: **47**.
- Ghostty base: **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`, unchanged from 0.19.0.
- Covers all changes since the published `v0.19.0` tag.

## Validation status

* Strict SwiftLint passed across **591 Swift files**; Zig formatting, settings JSON, documentation contract, plist, and MainMenu XIB checks passed.
* Signing contracts: **17 tests passed, 2 optional smoke tests skipped**. Keychain contracts: **15 tests passed, 1 optional test skipped**. Test-selector contracts: **44 tests passed**.
* The change-selected Swift plan resolved to scope **all** because shared host/core and build infrastructure changed, covering **178 suites**. Two full runs executed **1418** and **1421** tests; both failed only `NativeHoverRoutingTests.stationaryPointerReconcilesHoverAfterClipViewScroll()` with three hover-reconciliation issues. The same test passes when run alone (**3 tests passed**), and no hover, Inspector, or event-routing source or test changed since 0.19.0; the failure is order-dependent and not reproducible in isolation. The full selection did not pass cleanly in this environment.
* Session runtime: `cargo fmt --check`, `cargo clippy -D warnings`, `cargo build`, and **52 Rust tests** passed. The Python runtime suite ran **33 tests, 4 skipped**; the skips require a disposable Linux systemd host, a previous packaged runtime, previous and current native VT libraries, and an explicit SSH deployment configuration. `GhosttyTests/SessionRuntimeConnectionTests` passed **31 tests**.
* GhosttyKit built as ReleaseFast with both `arm64` and `x86_64` slices. The **arm64**, **x86_64**, and **universal** Release apps report OMG **0.19.1 / build 47**, bundle identifier `com.jischeng.omg`, and Ghostty base **1.3.2-dev**.
* All three apps use the persistent self-signed identity with designated requirement `com.jischeng.omg` and certificate leaf `9b2e176c03e5458e6fdaf73392cd9d79203972c6`, identical to the published 0.19.0 app, so the existing authorization carries over. arm64 and universal apps launched with `.ReleaseFast`; x86_64 execution was **NOT RUN** because Rosetta 2 is unavailable and its slice was verified statically instead.
* All three DMGs passed `hdiutil` verification and mounted read-only; arm64 and universal apps launched from their mounted DMGs with `.ReleaseFast`. Every packaged DMG contains the four runtime platform directories plus the universal local relay, manifest revisions match `04456c18a85c470514d3` (snapshot `59c5cc7b4d1fe408faf5`), post-signing SHA-256 hashes of all listed dependencies recompute correctly, and the packaged `omgd version` runs.
* Sparkle appcast verifies **0.19.1 / build 47**, minimum macOS **13.0**, the universal enclosure URL, and its EdDSA signature. The numeric bundle version advances from 46 to 47.
* Remote SSH deployment, detach/reconnect, pending Close, and Linux cgroup containment acceptance were **NOT RUN** because no authorized disposable SSH or Linux host is configured here. Native desktop drag/focus regression suites were **NOT RUN** by choice; those tests still require an unlocked foreground desktop.

Full Desktop/Documents/Downloads and Sparkle upgrade permission experiments are **NOT RUN**. They are not release prerequisites; static signature verification and launch probes do not establish end-to-end TCC behavior.

## Signing and distribution

Release apps reuse the **persistent self-signed identity; not notarized**. This
is not Apple Developer ID distribution. Gatekeeper may block the first launch;
users who trust the download can review and allow it in System Settings >
Privacy & Security. Do not disable Gatekeeper globally. DMGs are not notarized.
Sparkle updates retain their separate EdDSA signature.

Release assets are arm64, x86_64, and universal DMGs, `SHA256SUMS.txt`, and
`appcast.xml`. The universal DMG is the single Sparkle updater enclosure.
