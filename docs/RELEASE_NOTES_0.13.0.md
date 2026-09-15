# OMG 0.13.0 · Ghostty 1.3.2-dev

OMG 0.13.0 is a feature release focused on SSH host registration,
per-account agent hook management, Git batch actions, and a much quieter
terminal when titles change or repositories idle.

## Changes since 0.12.4

- **SSH host registration** — Settings → Plugins → SSH registers a ready
  OMG SSH connection, manually or by opting in after a successful
  connection. Registration captures the original executable, destination,
  options (user, port, ProxyJump), and launch directory; identity comes
  from the full connection, so the same alias with different launch
  parameters stays isolated. Registered hosts refresh their inventory on
  reconnect, and one shared OpenSSH socket namespace now serves Git,
  Agent inventory, and SFTP.
- **Per-account agent hooks** — Agent Integration selects This Mac or a
  registered SSH host, and scopes hook state plus install/update/remove
  actions to that account. Each account keeps an independent check
  interval, automatic-check preference, and optional automatic hook
  updates; CLI auto-update only applies to resolvable global npm
  packages and never downgrades.
- **SSH gating and settings layout** — automatic SSH hook checks now
  require a ready SSH pane in OMG, cancel background transport when the
  last matching connection goes away, and never leave a persistent
  ControlMaster behind. The settings surface is regrouped with the host
  picker beside the section title and per-row update controls.
- **Git batch actions** — Git change actions can be applied to a
  selected batch instead of one file at a time.
- **Quieter titles** — terminal title (OSC) updates no longer rebuild
  surface views or controller-wide publications; tab rows subscribe
  directly to titles and redraw only when the presented label changes.
- **Idle resource use** — local Git refreshes gate on real worktree and
  metadata events, fsmonitor feedback is filtered out, and worktree
  status refreshes stay read-only so monitoring no longer triggers
  extra refreshes. Sidebar windows skip native title decoration work.
- **Font shaper cache** — the Ghostty core keys the shaper font cache
  by grid generation, avoiding stale font references across regenerations.

## Ghostty core

- Version: **1.3.2-dev**
- Revision: `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`

## Signing and notarization

This release is **ad-hoc signed** and has **not been notarized** by Apple.
macOS Gatekeeper will show a warning on first launch; open the app via
System Settings → Privacy & Security or right-click → Open to proceed.

## Installation

Download the DMG for your architecture:

- `OMG-0.13.0-macos-arm64.dmg` — Apple Silicon
- `OMG-0.13.0-macos-x86_64.dmg` — Intel (tested under Rosetta 2)
- `OMG-0.13.0-macos-universal.dmg` — universal (used by the built-in
  updater)

Verify checksums with `SHA256SUMS.txt` before installing.
