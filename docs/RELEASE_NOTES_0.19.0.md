# OMG 0.19.0 · Ghostty 1.3.2-dev

OMG 0.19.0 turns the session runtime into a first-class subsystem, completes the native AppKit migration of the tab sidebar and controls, and reworks workspace management and fullscreen switching.

- Ship the session runtime as a unified subsystem: local sessions now survive broker restarts, local hosts are detached from the app coalition through launchd, and SSH relays stop when the app quits while pane working directories are preserved. Inline SSH stays managed, and legacy open requests are preserved for pinned session hosts.
- Complete the native AppKit migration: the tab sidebar is a native outline view, shell and interactive UI ownership moved to AppKit, and Git controls, Agent History controls, the SSH host picker, the editor file picker, theme surfaces, and popups are native and consistent.
- Rework workspace management: workspaces can be edited, deleted without closing their sessions, and keep an independent layout preference. Fullscreen workspace switch requests are coalesced across native callbacks, and the restored workspace is presented only after app activation.
- Improve performance on large workspaces: local Hermes status probes are shared across tabs, workspace switching work is reduced and coalesced, inspector refresh is bounded to visible tabs, hook checks moved off the UI thread, and native control updates are trimmed.
- Fix native rendering and interaction regressions: row hover is routed through AppKit selectors and repainted correctly, terminal theme and restored workspace presentation are preserved, tab visibility feedback is stable, and Dock, retained tab selection, checkpoint foreground, and cold window anchors restore correctly.

OMG version: **0.19.0**. Ghostty base: **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`.

Real automatic Agent recovery after process termination has not been validated for this release. Intel macOS launch and end-to-end SSH on every target architecture were not run. Native desktop drag/focus regression suites were not run for this release.

Validation limitation: the 1,383-test routine Swift sweep has unresolved order-dependent failures involving workspace transitions, popover completion, and modal button event delivery. Focused retries pass, but do not establish a passing full sweep. One synthetic fullscreen notification cleanup has been corrected; remaining test isolation and timing failures are deferred to follow-up work. These failures have not been established as product defects.

The application is persistently self-signed and **not notarized**. macOS Gatekeeper may block its first launch; users who trust the download can review it in System Settings → Privacy & Security. Permission migration and full TCC upgrade experiments were not run.
