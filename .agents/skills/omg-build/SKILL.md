---
name: omg-build
description: Build, compile, test, and run Oh My Ghostty (OMG) on macOS without opening the Xcode GUI. Use when asked to build OMG, compile GhosttyKit, run tests, diagnose build errors, or run OMG from source. Covers Xcode command-line workflows, Nushell scripts, Zig core builds, and fast targeted testing.
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

`macos/build.nu` supports `--only-testing` to run specific test suites or methods without waiting for the full 300+ test suite:

```bash
# Run one test suite
macos/build.nu --action test --only-testing GhosttyTests/AgentIntegrationManagerTests

# Run multiple test suites (comma-separated)
macos/build.nu --action test --only-testing GhosttyTests/SSHHostRegistryTests,GhosttyTests/SettingsLayoutTests

# Run a single test method
macos/build.nu --action test --only-testing GhosttyTests/SSHHostRegistryTests/testRegistrationPersistsExactConnectionsAndSwitchingOnlyReadsCache
```

### B. Full Swift Test Suite

```bash
macos/build.nu --action test
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
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
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
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
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
swiftlint lint --strict --config macos/.swiftlint.yml macos

# 2. Zig formatting
git ls-files -z '*.zig' | xargs -0 mise exec zig@0.16.0 -- zig fmt --check

# 3. OMG documentation contract (checks PLUGIN_DEVELOPMENT.md & friends)
python3 dist/check_omg_docs.py

# 4. Plist & settings schema
plutil -lint macos/Ghostty-Info.plist
python3 -m json.tool docs/settings/schema.json >/dev/null

# 5. Clean up any profraw files from test runs
rm -f default.profraw
```

---

## 5. Installing to OMG Dev

To test the compiled app locally in a persistent environment:

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
