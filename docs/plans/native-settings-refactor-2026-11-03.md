# Native settings refactor

Baseline: `bc6e55a05`. Native implementation and routine parity checks completed
on November 4, 2026. The temporary compatibility form has been removed.
Foreground desktop acceptance remains pending on an unlocked Mac.

## Scope and reference

The supplied Termio screenshots establish host list/detail/Agent navigation.
The supplied Herdr screenshots establish explicit registration: SSH config
aliases are candidates in Add Host, not automatically visible registered hosts.
No credentials or host names from those screenshots are fixtures.

The old tab composition used a centered 22-point canvas inside a 26-point
footprint. The native replacement used all 26 points for split positions.
Single raster/template logos and SF Symbols also have different optical bounds.
Restore the inner canvas and validate rendered single, two-, three-, and
four-pane layouts with symbols and Agent assets.

## Feature inventory and parity gate

| Area | Existing behavior to preserve | Native disposition |
| --- | --- | --- |
| Navigation | Every category, search, direct Agent target navigation, language and appearance updates | Flat AppKit source list; no Integrations group |
| General | Language, quit confirmation, terminal close confirmation, quit after last window | Native rows |
| Appearance | System/light/dark themes, inheritance and effective values, font, opacity, blur, cursor, reset | Native rows; details as help/advanced |
| Tabs | Layout, sidebar visibility/width memory, grouping, ordering, paths, density, icon preference, shortcuts, resize, reset | Native rows and More Tab Options |
| Terminal | Shell overrides, startup restoration, both quit policies, local-session creation, session library, TTL/deadline/completion settings, pending closes, notifications | Compact primary page and Session Options |
| Controls | Quick Input height/import, history scope/insertion/retention/privacy/clear, selection, clipboard, mouse, Option | Native pages and secondary options |
| Editor | File/directory destination, keymap, wrapping, pairs, inherited/catalog/builtin theme, conditional opacity/blur, typography and reset | Native rows and editor appearance |
| Keyboard | Quick Input, inspector and workspace recorders, reset and conflicts, config link | Native recorders and secondary workspace page |
| Git | Fetch interval, Agent/model identity, add/remove/reorder routes, prompt editing | Reuse existing native route table and sheets |
| Remote Hosts | Explicit add/remove, SSH-config candidates, cached inventory, connection status, errors, automatic registration | Registered list, Add sheet, host details |
| Agent | Local/remote target identity, discovery, Hook install/remove/repair, CLI maintenance, per-Agent policies, schedule/status, export, behavior/history/alerts | Local Agent page; per-host Agent pages |
| Plugins | Official install/update/toggle/uninstall, GitHub package install, errors/status, capabilities | Native rows and detail sheets |
| Advanced | Open/reveal/reload settings, Ghostty config, precedence and save errors | Native file actions and concise status |

## Verification

- Focused native Settings, registration, maintenance, navigation, Git routes and
  icon tests passed. Action tests cover editor theme selection/reset, shortcut
  capture/cancel/reset, model ordering/removal and nested host/Agent back routes.
  A supplemental test preserves distinct popup options with identical labels.
- All 175 routine Swift suites passed in five serial fresh-host batches:
  405 + 213 + 251 + 340 + 191 = 1400 reported tests. The subsequent popup
  adjustment, label compression fix and additional test passed in the final
  native-settings run (6 routine tests).
- The first single-process sweep exposed a pre-existing ambiguous test caller:
  the workspace deletion test made the target workspace key, then attempted to
  delete it without an explicit source. It now deletes from the host that has
  switched away, preserving the product's active-workspace deletion guard.
  That test and the earlier weak-monitor/modal regression passed together.
- Rust: 52 tests, Clippy with warnings denied, and formatting passed.
  Python: 28 tests, 26 passed; real SSH and Linux containment tests skipped
  because their environments were not configured. Compatibility used the
  previous packaged OMG Dev runtime in an isolated local fixture.
- Native macOS and Linux x86_64/aarch64 runtime bundles rebuilt and verified.
  This proves cross-compilation/artifact integrity, not Linux deployment.
- SwiftLint, documentation contract and plist checks passed. Offscreen snapshots
  cover all primary pages, light/dark minimum-size forms, host detail, and
  terminal/Pi/Codex/Claude icon geometry. Offscreen native material captures
  do not establish foreground selection appearance.
- Foreground settings mouse navigation and native sidebar clicks were attempted,
  but failed their active/key-window prerequisites. Computer control confirmed
  the Mac was locked. These are not recorded as passed.
- No Dev replacement or public release was performed.
