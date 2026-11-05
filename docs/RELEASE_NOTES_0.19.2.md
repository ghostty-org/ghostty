# OMG 0.19.2 · Ghostty 1.3.2-dev

OMG 0.19.2 improves Git History, split focus, workspace navigation, and Quick
Input. The Ghostty base is unchanged.

## Highlights

- **Compare favorite Git branches.** The History picker can show the combined
  graph of favorite local and remote branches. Star `HEAD` to follow the current
  worktree's checked-out commit, including in detached HEAD. Current, Favorites,
  and All switch without closing the picker, and stars follow row hover.
- **See the focused split.** A rounded accent line marks the top of the selected
  pane. Its thickness and visibility are configurable in Appearance settings.
  While the marker is enabled, unfocused pane text and ANSI colors are not dimmed;
  disabling it restores Ghostty's configured unfocused-split behavior.
- **Switch adjacent workspaces.** Press Control-Command-Left or
  Control-Command-Right to move through workspaces in their sidebar order.
- **Use Control-J in Quick Input.** An optional setting inserts a newline with
  Control-J. It is disabled by default.
- **Keep split Surfaces attached during layout changes.** Surface presentation
  ownership and resize transactions now follow the active controller and Surface
  lifecycle, preventing retired wrappers from reclaiming or resizing a pane.

## Version and distribution

- OMG **0.19.2**, bundle version **48**.
- Ghostty **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`.
- Includes the changes since the published `v0.19.1` tag.
- Release apps use the existing persistent self-signed identity and are **not
  notarized**. Gatekeeper may block the first launch; users who trust the
  download can review and allow it in System Settings > Privacy & Security.
  Sparkle updates retain their separate EdDSA signature.
- The arm64, x86_64, and universal apps include the local and remote session
  runtime artifacts.

## Validation

- The release's focused Swift selection passed **160 tests in 17 suites**,
  covering the changed Git History, split, workspace, Quick Input, settings,
  and version behavior. An earlier run had seven Git History timeouts; the
  affected suites passed separately and the same focused selection passed on
  retry. The underlying cause of the initial failures was not established.
- Before release preparation, **1434 routine Swift tests in 178 suites** passed
  on the same feature implementation; the subsequent feature commit added
  test coverage only. Native interactive-desktop suites were not run.
- SwiftLint and the settings, documentation, plist, and menu checks passed.
  Signing policy tests passed with **3 optional tests skipped**.
