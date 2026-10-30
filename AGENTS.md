# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Workspace checkout development target

For this `omg-workspace` checkout, install development builds with
`.agents/skills/omg-release/scripts/install-dev.sh` to `/Applications/OMG Dev.app`.
Development installs replace OMG Dev, never the release OMG app.
See [.agents/WORKSPACE_DEV.md](.agents/WORKSPACE_DEV.md) for identity and data paths.

## Commands

- **Build:** `zig build`
  - If you're on macOS and don't need to build the macOS app, use
    `-Demit-macos-app=false` to skip building the app bundle and speed up
    compilation.
- **Test (Zig):** `zig build test`
  - Prefer to run targeted tests with `-Dtest-filter` because the full
    test suite is slow to run.
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Test (Swift modules)**: `macos/build.nu --action test --test-modules git,editor`
- **Test (Swift changes)**: `macos/build.nu --action test --changed-since <base-ref>`
  - Inspect with `--test-plan-only`; releases use the previous published OMG tag.
  - Shared host/core, build/test infrastructure, or unmapped changes fall back to
    all routine Swift suites. Release size alone does not require a full sweep.
- **Test (Swift routine full)**: `macos/build.nu --action test --test-modules all`
  - Interactive-desktop tests are optional and excluded by default, not passed.
  - After native tab/drag/focus changes, run relevant desktop tests explicitly on
    an unlocked foreground desktop with `--include-desktop-tests`.
  - Swift selection does not replace affected Zig/Python/shell/artifact checks.
- **Test selector contract**: `python3 -m unittest discover -s dist -p 'test_omg_test_plan.py'`
  - Test tiers and mappings: `docs/TESTING.md`. Build and test strictly serially.
- **Formatting (Zig)**: `zig fmt .`
- **Formatting (Swift)**: `swiftlint lint --strict --fix`
- **Formatting (other)**: `prettier -w .`
- **OMG documentation contract:** `python3 dist/check_omg_docs.py`
- **OMG release signing:** Use persistent self-signed code signing
  (`OMG_SIGNING_MODE=self-signed`) with the same pinned certificate on every
  release. Source the private `signing.env`; never regenerate an existing identity
  or fall back to ad-hoc for public releases. Apps and DMGs are not notarized;
  Developer ID and Apple membership are not prerequisites. Keep code-signature,
  identity continuity, launch, DMG, and Sparkle EdDSA checks; see
  `docs/RELEASING.md`.

Any change to plugin APIs, manifests, wire messages, capabilities, lifecycle,
loading/discovery, package layout, Inspector provider behavior, or permissions
must update `docs/PLUGIN_DEVELOPMENT.md` and relevant tests in the same commit.

## libghostty-vt

- Build: `zig build -Demit-lib-vt`
- Build WASM: `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`
- Test: `zig build test-lib-vt -Dtest-filter=<filter>`
  - Prefer this when the change is in a libghostty-vt file
- All C enums in `include/ghostty/vt/` must have a `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE`
  sentinel as the last entry to force int enum sizing (pre-C23 portability).

## Directory Structure

- Shared Zig core: `src/`
- macOS app: `macos/`
- GTK (Linux and FreeBSD) app: `src/apprt/gtk`

## Public Reporting and Contributions

- Public policy lives in `docs/REPORTING.md` and `docs/CONTRIBUTING.md`;
  skills are execution aids, not independent policy or authority.
- Do not publish issues/PRs, push, or merge without explicit user authorization.
- An explicit `/skill:omg-issue-report <description>` invocation authorizes only
  the dedicated helper's local-`gh` submission to `jischeng/oh-my-ghostty`, without
  a second confirmation. It does not authorize raw-log uploads, upstream reports,
  PR creation/merging, or changing existing app state. Follow higher-priority rules.
- Keep public reports factual and redacted; retain complete evidence locally.

## OMG Architecture Principles

- Keep the complete Ghostty macOS app as the host; do not rewrite OMG around
  `libghostty-internal` or `libghostty-vt` without a separately approved
  migration to a stable, public, full embedder API.
- Put OMG features and business logic in fork-owned files.
- Limit edits to upstream-owned files to small adapters, registration points,
  or the minimum missing lower-level capability.
- Gradually compress OMG changes to `TerminalController`, `AppDelegate`, and
  `TerminalView` into protocols, extensions, or centralized adapters.
- Sync `upstream` frequently and resolve conflicts in small batches.

See `docs/oh-my-ghostty-architecture.md` for the detailed architecture baseline.


## Local task checkpoints

At task start, inspect the working tree and commit completed, authorized work
from the preceding task before starting unrelated changes. At task completion,
commit the task's scoped implementation, tests and documentation. Do not amend,
push, or silently include unrelated edits. Preserve and identify concurrent
work instead of staging it indiscriminately.
