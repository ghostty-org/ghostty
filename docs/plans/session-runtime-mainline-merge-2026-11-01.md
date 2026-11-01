# Session runtime integration into main

## Scope

The user authorized merging the completed runtime work from
`cjs/ssh-session-runtime` into the main checkout.

- Main before integration: `21477837bcab7004e916416a08f7d30e1da0df74`.
- Incoming tip: `fb5315de5d641feb6cafd0ad979888476f5243d9`.
- Shared base: `58ced12abee5d679fde75c50c948fc3b7f36bf80`.
- Runtime commits: `a34d98f03` and `fb5315de5`.
- The incoming `c408f28f9` is patch-equivalent to main's `1b9a05a04`.

This integrates both SSH and local persistent sessions: retained native
surfaces during reconnect, explicit attachment lifetime, local PTY holders,
startup-policy handling, stable bridges and the native Session Library.

## Conflict resolution

Ten paths needed conflict resolution. The backported fullscreen tests and
test-selector file were identical to the older main commit, so current main
versions were retained after comparing file contents. This preserves the
newer native fullscreen, hover, workspace and termination regressions.

`TerminalController` and the workspace adapter retain main's termination
guards, coordinator-owned refresh cancellation, ordered background-tab close,
retained-window selection and frame preparation. Runtime window close still
suspends attachment through the base controller; explicit tab/pane close
still ends the session. Workspace parking does not detach sessions.

Quick Input combines the incoming stable per-pane bridge directories with
main's resolved Python interpreter and shell launcher. Private file writes
retain no-follow checks. The merged regression recreates a persistent local
bridge, invokes its editor with an invalid inherited SDK setting and verifies
that draft import works without modifying the original draft.

Executable Python fixtures added by the runtime branch now resolve an installed
interpreter through `LocalPythonInterpreter`; data-only command-preservation
fixtures continue to accept arbitrary user command strings.

## Validation

Builds and tests ran serially against the combined working tree:

- 103 targeted Zig tests passed. All 86 build steps succeeded.
- A native ReleaseFast GhosttyKit framework and matching VT library were rebuilt.
- Rust: 38 tests passed; rustfmt and strict Clippy passed.
- Python runtime integration: 22 discovered, 20 passed, two environment-gated
  SSH/Linux tests skipped.
- All 169 routine Swift suites passed in 30 fresh test-host batches. The runner
  reported 1,365 tests; a disabled example was reported separately as skipped.
- Five foreground desktop tests passed across four suites: 60-tab native
  fullscreen teardown, fullscreen workspace mouse switching, parameterized
  horizontal/vertical fullscreen behavior and native tab clicks.
- After switching the executable Python fixtures to the guarded interpreter,
  49 focused native/runtime/Quick Input tests passed again. The 42 test-selector
  checks, two bundle-contract checks, development-tool shell checks, strict
  SwiftLint, settings/plist/menu validation and documentation checks also passed.
- macOS arm64 and Linux x86_64/aarch64 runtime artifacts were built with revision
  `e620b434be80c3e8e636`. This is compilation of the Linux artifacts, not execution
  on Linux hosts.

The native local integration test executed with the packaged helper. It checks
real PTY launch configuration, one-time initial input, early input, PID/TTY and
cwd, retained-Surface detach, attachment from another view, Undo resume and
refusal to reopen an explicitly closed session. It was not merely counted as
an enabled test without running.

Private logs and machine-readable results are under
`/var/folders/2z/zl8wrct518v_n3zcgjmc07200000gn/T/omg-runtime-merge-w0u1386k/`.

## Delivery and remaining boundaries

This is a local source merge and build validation. It does not replace a
running OMG installation or a live local/remote daemon, and does not publish
or push the branch.

Real SSH password authentication, network interruption/sleep-wake and Linux
systemd containment remain external acceptance work. Runtime binaries and
their revision-pinned hosts must stay paired; manually mixing old relays and
new hosts is unsupported. In particular, old relays do not parse the new
multi-capability heartbeat as a durable-close capability.

Review also noted a pre-existing build identity limitation: the runtime source
digest does not cover every build input, including `Cargo.toml` and build
recipes. This merge also changes hashed Rust sources and `Cargo.lock`, so its
runtime revision changes correctly. A future manifest-only/build-recipe change
needs explicit cache-identity coverage; that packaging-policy expansion is not
part of this integration.
