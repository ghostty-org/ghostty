# OMG test selection

Use `macos/build.nu` for app-hosted Swift tests. Test selection is based on changed
modules and their direct dependents, **not the release's SemVer category**. A minor
release does not automatically require every unrelated feature suite.

## Three layers

1. **Routine module regression**: unit/policy and app-hosted integration suites;
   includes the version smoke suite. App-hosted does not mean a real foreground
   desktop is required: window fixtures and synthetic event-policy tests remain
   routine tests.
2. **Broad routine regression**: all routine Swift suites for shared host/core,
   build/test infrastructure, unmapped changes, or an explicitly requested sweep.
3. **Optional interactive desktop**: suites or individual tests tagged
   `.interactiveDesktop`: `VerticalTabMouseTests`, `VerticalTabFullscreenTests`
   (native fullscreen tab creation, framebuffer/sidebar handoff, and exit), `QuickInputFooterMouseTests`
   (icon-only History and its complete padded mouse hit target), and the visual
   `VerticalTabsIntegrationTests.appKitTabGroupDrivesVerticalTabsWithoutRecreatingSurfaces`,
   `TerminalLinkHoverTests.commandHoverRemainsStable` (Cmd-link hover in single/split panes),
   and `TerminalWorkspacePresentationTests.clickingWorkspaceButtonOpensItsNativePopover`
   (actual mouseDown/mouseUp opening the transient workspace popover), plus
   `TerminalWorkspaceManagementDesktopTests` (creation through the popover's
   form in native and non-native fullscreen), the 60-tab
   `TerminalWorkspacePopoverSwitchTests.nativeFullscreenMouseSelectionClosesAndSwitchesWithoutAnotherKey`,
   `TerminalApplicationTerminationTests.confirmedTerminationKeepsSelectedTabDuringRealSixtyTabFullscreenTeardown`
   (background tabs close without promoting fullscreen successors),
   and the borderless focus/membership methods
   `TerminalWorkspaceManagementTests.nativeTabObservationSurvivesRepeatedBorderlessStyleChanges`
   and `TerminalWorkspaceManagementTests.nonNativeFullscreenSupportsWorkspaceCreationAndReturn`.
   Real CoreDrag, menu focus routing, native window appearance, and screenshots
   need an unlocked desktop and foreground test application. Lockscreen,
   background, and unattended runs cannot establish that behavior. Other methods
   in a mixed suite remain routine tests.

The test plan provides `OMG_TESTING=1` before the application starts. Workspace
singletons use this launch marker to avoid user catalog/checkpoint reads or writes
before XCTest classes have loaded. Persistence fixtures explicitly use temporary
paths; test-like names in a user's catalog are not automatically deleted.

The wrapper excludes interactive-desktop suites by default and prints **NOT RUN**
when the chosen scope contains one. This is not a pass or a silently swallowed
failure. Pure drag-policy/lifecycle and tab integration tests still run normally.
When changing native tabs, drag/drop, focus, or event routing, schedule the desktop
regression explicitly while the desktop is available. If deferred, record that
coverage gap and its reason; unrelated releases must not be blocked by it.

XCUITest (`GhosttyUITests`) is separate and remains excluded by this CLI wrapper
because it requires a permissions-enabled workflow. `--include-desktop-tests`
does not enable XCUITest. Raw `xcodebuild` does not implement this wrapper's
selection policy; a Swift Testing tag alone does not disable a suite.

## Commands

```bash
# List modules and their direct dependents; does not build or launch apps
macos/build.nu --list-test-modules

# Select modules explicitly (including their direct dependents)
macos/build.nu --action test --test-modules git,editor

# Preview changes since a commit/tag, including the current worktree
macos/build.nu --action test --changed-since v0.15.3 --test-plan-only

# Execute that Swift selection, using the previous published tag for releases
macos/build.nu --action test --changed-since v0.15.3

# Keep the existing one-suite/method interface
macos/build.nu --action test --only-testing GhosttyTests/SSHHostRegistryTests

# Broad routine sweep; neither native desktop interaction nor XCUITest
macos/build.nu --action test --test-modules all
# Backward-compatible equivalent: macos/build.nu --action test

# Optional real native drag regression; keep desktop unlocked/test window foreground
macos/build.nu --action test \
  --only-testing GhosttyTests/VerticalTabMouseTests --include-desktop-tests

# Optional Cmd-link hover regression (single pane and split panes)
macos/build.nu --action test \
  --only-testing 'GhosttyTests/TerminalLinkHoverTests/commandHoverRemainsStable()' \
  --include-desktop-tests

# Optional visual test; Swift Testing method selectors include parentheses
macos/build.nu --action test \
  --only-testing 'GhosttyTests/VerticalTabsIntegrationTests/appKitTabGroupDrivesVerticalTabsWithoutRecreatingSurfaces()' \
  --include-desktop-tests
```

Test actions set `ENABLE_TESTABILITY=YES` and `ONLY_ACTIVE_ARCH=YES`, including
`--configuration Release`, so optimized app-hosted tests can use `@testable`
imports and a native-only GhosttyKit build. Normal build/archive actions retain
the configuration's original settings. Pointer-posting desktop tests additionally
require macOS event-posting permission; a failed permission prerequisite is not a
hover-latency result.

Use exactly one of `--test-modules`, `--changed-since`, and `--only-testing`.
`--test-plan-only` emits JSON without invoking Xcode. Invalid modules, unknown
suites, conflicting scopes, and invalid Git refs fail before a build. An explicit
desktop suite/method without `--include-desktop-tests` also fails with guidance,
instead of producing a misleading zero-test success. If desktop opt-in is enabled
but focus cannot be established, the test fails early with its prerequisite error;
its real-drag assertions have not been weakened.

## Module map

The single executable source of truth is `MODULES` in `dist/omg_test_plan.py`.
Suite ownership can overlap intentionally (for example SSH Git execution).
Dependents are one hop from every changed/requested module, not a recursive graph
expansion. Shared interfaces use the broad fallback instead.

| Module | Main test areas | Direct dependents |
| --- | --- | --- |
| `foundation` | Root, Helpers, Ghostty app adapters | — |
| `terminal` | Terminal history/restoration, Splits | tabs, inspector, agents, editor |
| `tabs` | Vertical tabs, drag policy, tab selection restoration | terminal |
| `git` | Git services and UI models | editor, inspector |
| `editor` | Editor and Markdown models/integration | git, terminal |
| `inspector` | Inspector registry, decks, history, providers | git, agents |
| `settings` | Settings and settings schema | foundation, terminal, tabs, editor, git, inspector |
| `plugins` | Plugin host/protocol | agents, ssh, inspector, tabs |
| `agents` | Agent integration/status/history | inspector, quick-input, tabs, terminal |
| `ssh` | SSH configuration, workspace, remote Git execution | agents, terminal, git, tabs |
| `quick-input` | Agent Quick Input | agents |
| `update` | Updater, release notes, version metadata | — |

Selection safety:

- Git comparison includes committed changes since the exact supplied ref **and**
  staged, unstaged, and non-ignored untracked files. Both sides of a rename and
  deleted paths count. Paths are NUL-delimited; no shell evaluation is used.
- Nested source namespaces use the most specific mapping (Tabs before Terminal).
- Shared Zig/C core, App/Ghostty host adapters, central TerminalController,
  Xcode/build/test infrastructure, and any unmapped code fall back to all routine
  Swift suites. This is conservative rather than pretending a precise dependency
  graph exists.
- A project-file diff containing only balanced changes to `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` selects update/version coverage instead of forcing a
  broad sweep. Any structural project-file edit still falls back broadly.
- Documentation-only/no-change selection does not invoke Xcode; it explicitly
  says no Swift tests ran. Settings schema and mapped editor resources are not
  treated as irrelevant documentation.
- Suite names are discovered from `Tests`/`Suite` type declarations in Swift test
  files. Add new areas and dependency edges to the map alongside feature changes.
  Unmapped test files or undiscoverable test types are errors, not silently omitted
  coverage. Keep each desktop-tagged test type in its own file. Method-level tags
  exclude only that method, not the remaining routine tests in its suite.

## Non-Swift and release gates

The selector runs **Swift tests only**. It does not rebuild GhosttyKit or run Zig,
Python, shell, browser, lint, code-signature, or artifact launch checks.
Continue running the checks relevant to those changed layers, strictly serially:

```bash
# Selector/CLI contract tests: no Xcode or desktop interaction
python3 -m unittest discover -s dist -p 'test_omg_test_plan.py'

# Changed Zig area (choose the affected test filter)
mise exec zig@0.16.0 -- zig build test \
  -Dversion-string=1.3.2-dev -Dtest-filter="OMG command history"

# Changed SSH transport/integration/wrappers: validate the actual rebuilt artifact
python3 dist/test_ssh_shell_integration.py \
  --omg macos/build/Debug/OMG.app/Contents/MacOS/omg
python3 -m unittest discover -s dist -p 'test_ssh_agent_wrappers.py'

# Public README/report/contribution entry points and upstream-only Vouch jobs
python3 -m unittest discover -s dist -p 'test_omg_community_docs.py'

# Always keep the OMG documentation contract
python3 dist/check_omg_docs.py
```

For releases, use the **previous published OMG tag**, inspect the plan, and record
selected modules, any broad fallback, measured results, and desktop tests not run
in the release notes. Do not select only the version bump commit. Full routine
regression remains useful for upstream syncs, cross-module refactors, and periodic
sweeps. Release apps use persistent self-signed code signatures and are not notarized;
certificate/DR continuity, Sparkle EdDSA, and artifact launch checks remain separate
gates. Run signing contracts separately:

```bash
python3 -m unittest discover -s dist -p 'test_omg_signing.py'
python3 -m unittest discover -s dist -p 'test_omg_keychain.py'
```

Full TCC permission-upgrade experiments are not a prerequisite for this policy;
report them NOT RUN if omitted. See
[RELEASING.md](RELEASING.md).
