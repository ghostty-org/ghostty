# Local Python tooling and refactor follow-up

## Confirmed installation-prompt trigger

The CPU investigation's ad hoc local probe invoked `/usr/bin/python3` with an
inherited `SDKROOT` pointing to the removed `MacOSX27.0.sdk`. Its recorded error
shows Apple's launcher trying `xcodebuild -sdk ... -find python3`, failing to
resolve that SDK, and requesting installation of Command Line Tools.

This machine already has Xcode and Command Line Tools interpreters. The active
Xcode contains `MacOSX27.2.sdk` and the current `MacOSX.sdk` alias. The failure
does not demonstrate that developer tools are absent. The installed Dev process
in the CPU baseline did not contain `SDKROOT`; the directly evidenced prompt
came from the diagnostic command, rather than the app's sampled idle workload.

## Repair scope

- `dist/macos/dev-tool.sh` removes ambient SDK selection and resolves an
  installed Python without executing the Apple installer shim. It handles PATH
  entries, Xcode bundles, Command Line Tools and absent dependencies. The test
  planner and Dev installers use it; nested installation checks inherit the
  selected interpreter. The pinned signing interpreter and Keychain ACL are
  unchanged.
- Local Hermes status probes and the Agent CLI manager select an installed
  interpreter by absolute path. File identity checks reject direct, symbolic
  and hard-link aliases of the Apple shim. Missing Python is an error, not an
  installation request. Login-shell-only Python discovery reads PATH without
  running a candidate, then uses the same validation. Remote Python remains
  owned by the SSH account.
- Quick Input installs a shell entry point plus its Python body instead of a
  `/usr/bin/python3` shebang. Quoted absolute paths support spaces and quotes.
  Without Python, the existing editor environment remains intact.
- The debug, build and release skills document the tool entry point. The
  build skill's stale single-test example now names an existing Swift Testing
  method with `()`, and requires checking the executed count.
- `TerminalShellLayoutContainer` no longer subscribes to the entire Agent
  activity store merely to forward it to the native sidebar, which already
  owns that subscription. This removes unnecessary shell updates while
  retaining sidebar status refresh.
- Refactor leftovers are cleaned up where semantics are clear: unused optional
  bindings retain their existence guards, MainActor defaults are evaluated in
  actor-isolated bodies, UI callback types keep their actor contract, and
  editor test fixtures explicitly retain their mounted hosts.

The work does not change system Xcode selection, install Command Line Tools,
or rewrite the release OMG application. It does not replace Python commands
inside external Agents' existing hook configurations or remote accounts.
Those commands continue to use the environment chosen for those processes.

## Validation

- The development-tool shell contract and all 42 test-planner checks passed.
  The fixtures cover relative/empty PATH, installer-shim aliases, Xcode bundle
  paths, CLT-only paths and failure without starting an installation.
- All three modified skills passed their format validator. The corrected
  single-method build-skill example executed exactly one test successfully.
- The focused Swift run passed 135 tests in nine suites. Coverage includes
  interpreter file-identity checks, isolated login-shell PATH discovery without
  executing the candidate, Quick Input's real shell launcher with spaces/quotes,
  unavailable-Python editor preservation, and native sidebar status rendering.
- The final routine regression passed 1,324 tests across 166 suites in 16 serial
  batches. The new interpreter suite was included in the inventory comparison.
- All 14 Hermes Python probe tests and strict SwiftLint for 31 changed Swift
  files passed, along with shell syntax, documentation, plist, settings JSON
  and diff checks.

Evidence is private under `/tmp/omg-tooling-followup-dix_b61o/`. Earlier compiler
failures and fixture failures remain in the local investigation history; their
fixes precede the final successful routine sweep. Skill-validator dependencies
were installed only under that temporary directory, not into the user's Python.

## Remaining diagnostic boundaries

Passing routine tests does not mean the build is warning-free. Existing
`NSDisableScreenUpdates`/`NSEnableScreenUpdates` uses remain in native window
handoff paths; replacing that atomicity mechanism needs its own fullscreen and
visual acceptance. Some older KVO/appearance/concurrency annotations also
remain, rather than introducing unproven thread assertions to suppress them.
Native desktop drag/fullscreen acceptance was not rerun for this follow-up.

Xcode's CoreSimulator version mismatch and system WindowManager/Shortcuts
service messages were observed during the test hosts' window fixtures. They
are separate from the proven Python launcher/SDK failure. This change does
not repair or reinstall those system components.
