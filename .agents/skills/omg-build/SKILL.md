---
name: omg-build
description: Build, compile, test, and run Oh My Ghostty (OMG) on macOS without opening the Xcode GUI. Use when asked to build OMG, compile GhosttyKit, run tests, diagnose build errors, or run OMG from source. Covers Xcode command-line workflows, Nushell scripts, Zig core builds, and fast targeted testing.
metadata:
  compatibility: macOS, Xcode command-line tools, Zig 0.16.0 via mise, Nushell, SwiftLint.
---

# OMG Build Guide

Use this skill in the `oh-my-ghostty` repository to build, compile, and test the macOS app and core libraries from the terminal.

## Golden Rules for AI Agents

1. **NEVER open the Xcode GUI**:
   - Do NOT run `open macos/Ghostty.xcodeproj` or `open -a Xcode`.
   - All builds and tests MUST run via command-line tools: `macos/build.nu`, `xcodebuild`, or `zig build`.
2. **NEVER modify or quit `/Applications/OMG.app`**:
   - `/Applications/OMG.app` is the stable user installation.
   - Development builds target `macos/build/Debug/OMG.app` or `/Applications/OMG Dev.app`.
3. **Use the right build tool for the layer**:
   - **macOS Swift app**: `macos/build.nu` (wraps `xcodebuild` cleanly).
   - **Ghostty Zig core / GhosttyKit**: `mise exec zig@0.16.0 -- zig build`.
   - **Dev install**: `.agents/skills/omg-release/scripts/install-dev.sh`.
4. **Resolve local tools without the Apple Python installer shim**:
   - Use `dist/macos/dev-tool.sh python3 ...`, `... xcrun ...`, and
     `... swiftlint ...` for standalone checks and diagnostic scripts.
   - `macos/build.nu` and the Dev installers use this entry point themselves.
     It removes inherited `SDKROOT`, which can reference a removed SDK after
     Xcode updates, and selects an existing interpreter without launching an
     installer. Use `sys.executable` for Python children.
   - Keep the separate signing interpreter pin; this helper does not replace
     `OMG_SIGNING_PYTHON` or alter Keychain authorization.

---

## 1. Quick Start: Build the macOS App

The macOS app uses Nushell (`macos/build.nu`) as its build runner.

```bash
# Build Debug version (output: macos/build/Debug/OMG.app)
macos/build.nu --configuration Debug --action build

# Build with a specific version string (used for dev builds)
macos/build.nu --configuration Debug --action build --marketing-version 0.13.0-dev.abcdef12

# Clean build artifacts
macos/build.nu --action clean
```

> **Note**: If `nu` is not in `PATH` or you are invoking from a bare subshell, `nu` is installed at `/opt/homebrew/bin/nu` or managed by `mise`.

---

## 2. Testing Workflows

### A. Targeted Swift Testing (Fastest)

`macos/build.nu` supports module/change-based selection and `--only-testing`.
Prefer changed modules and their direct dependents; release size alone does not
require a full sweep. See `docs/TESTING.md` for the executable mapping, fallback
rules, and non-Swift checks.

```bash
macos/build.nu --list-test-modules
macos/build.nu --action test --test-modules git,editor
macos/build.nu --action test --changed-since HEAD~1 --test-plan-only
macos/build.nu --action test --changed-since HEAD~1
```

For releases, use the previous published OMG tag rather than only the latest
commit. These selectors run Swift tests only; rebuild GhosttyKit and run affected
Zig/Python/shell tests separately. Use one scope selector per invocation.

Specific suites/methods remain available:

```bash
# Run one test suite
macos/build.nu --action test --only-testing GhosttyTests/AgentIntegrationManagerTests

# Run multiple test suites (comma-separated)
macos/build.nu --action test --only-testing GhosttyTests/SSHHostRegistryTests,GhosttyTests/SettingsLayoutTests

# Run a single test method
macos/build.nu --action test --only-testing 'GhosttyTests/SSHHostRegistryTests/registrationPersistsExactConnectionsAndSwitchingOnlyReadsCache()'
```

For Swift Testing methods, copy the exact function name and include `()`.
Check the executed test count, not just `TEST SUCCEEDED`: a mismatched method
filter can otherwise finish successfully without running the intended test.

### B. Broad Routine and Optional Desktop Tests

Shared host/core, build/test infrastructure, and unmapped changes conservatively
select all routine Swift suites. An explicit broad sweep is also available:

```bash
macos/build.nu --action test --test-modules all
# Equivalent: macos/build.nu --action test
```

Real native drag/focus tests tagged `.interactiveDesktop` are optional, excluded
by default, and reported as **NOT RUN**, not passed. After relevant native tab,
drag/drop, focus, or event-routing changes, explicitly schedule them on an
unlocked desktop with the test app in foreground:

```bash
macos/build.nu --action test --only-testing GhosttyTests/VerticalTabMouseTests --include-desktop-tests
```

An explicit desktop test without opt-in fails with guidance. An opted-in test
without a foreground key window fails early on its prerequisite, not a misleading
drag assertion. XCUITest remains excluded; this flag does not enable it. Raw
`xcodebuild` does not apply the wrapper's selection policy.

Validate selector changes without launching Xcode:

```bash
dist/macos/dev-tool.sh python3 -m unittest discover -s dist -p 'test_omg_test_plan.py'
```

### C. Zig Core Testing

When modifying Zig files under `src/`:

```bash
# Always pass -Dversion-string to avoid the upstream tag check assertion
mise exec zig@0.16.0 -- zig build test -Dversion-string=1.3.2-dev

# Run targeted Zig tests with a filter
mise exec zig@0.16.0 -- zig build test -Dtest-filter="font cache invalidates" -Dversion-string=1.3.2-dev

# libghostty-vt tests (when editing include/ghostty/vt or src/vt)
mise exec zig@0.16.0 -- zig build test-lib-vt -Dversion-string=1.3.2-dev
```

---

## 3. Rebuilding the Zig Core (GhosttyKit.xcframework)

The Swift app links against `macos/GhosttyKit.xcframework`. When Zig files (`src/**`) or C headers change, rebuild the framework first:

### Native (Current Architecture, Fast for Development)

```bash
env -u SDKROOT -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  -u ALL_PROXY -u all_proxy \
  mise exec zig@0.16.0 -- zig build \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=true \
    -Dxcframework-target=native \
    -Demit-macos-app=false \
    -Dversion-string="1.3.2-dev"
```

### Universal (arm64 + x86_64, Required for Release)

```bash
env -u SDKROOT -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  -u ALL_PROXY -u all_proxy \
  mise exec zig@0.16.0 -- zig build \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=true \
    -Dxcframework-target=universal \
    -Demit-macos-app=false \
    -Dversion-string="1.3.2-dev"
```

---

## 4. Verification and Pre-Commit Checks

Before committing changes or installing to OMG Dev, run the validation gate:

```bash
# 1. Swift formatting and linting
dist/macos/dev-tool.sh swiftlint lint --strict --config macos/.swiftlint.yml macos

# 2. Zig formatting
git ls-files -z '*.zig' | xargs -0 mise exec zig@0.16.0 -- zig fmt --check

# 3. OMG documentation contract (checks PLUGIN_DEVELOPMENT.md & friends)
dist/macos/dev-tool.sh python3 dist/check_omg_docs.py

# 4. Plist & settings schema
plutil -lint macos/Ghostty-Info.plist
dist/macos/dev-tool.sh python3 -m json.tool docs/settings/schema.json >/dev/null

# 5. Clean up any profraw files from test runs
rm -f default.profraw
```

---

## 5. Installing to OMG Dev

To test the compiled app locally in a persistent environment, including from the
`omg-workspace` checkout, install to `/Applications/OMG Dev.app`:

1. **Commit your changes first**: The tree MUST be clean. Dev installs link to a specific commit hash.
2. **Run the installer**:
   ```bash
   .agents/skills/omg-release/scripts/install-dev.sh
   ```
3. **If already compiled**: If you just built with the correct version stamp, pass `--skip-build`:
   ```bash
   .agents/skills/omg-release/scripts/install-dev.sh --skip-build
   ```

---

## 6. Common Troubleshooting

| Issue | Cause | Fix |
|---|---|---|
| Agent opens Xcode GUI | Command `open ...xcodeproj` used | Use `macos/build.nu --action build` instead. |
| `tagged releases must be in vX.Y.Z format matching build.zig` | Running `zig build` on an OMG tag without `-Dversion-string` | Add `-Dversion-string=1.3.2-dev` to any `zig build` call. |
| `Debug app version is X, expected Y` during dev install | Code was built before commit, missing dev commit suffix | Let `install-dev.sh` rebuild, or commit first. |
| Undefined `_ghostty_*` symbols | Missing or mismatched `GhosttyKit.xcframework` | Rebuild GhosttyKit with `zig build -Demit-xcframework=true`. |
| Uncommitted `default.profraw` | Created by Xcode test coverage | `rm -f default.profraw` before installing or committing. |
