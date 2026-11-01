---
name: omg-release
description: Builds, validates, installs, and publishes Oh My Ghostty macOS development and patch releases. Use when asked to install or replace OMG Dev, prepare a release, bump OMG versions, build arm64/x86_64/universal DMGs, generate the Sparkle appcast, tag, push, or publish a GitHub Release.
metadata:
  compatibility: macOS, Xcode, Zig 0.16.0 via mise, Nushell, SwiftLint, GitHub CLI, and Sparkle tools.
---

# OMG Build and Release

Authoritative docs: `docs/RELEASING.md`.
Use this skill in the `oh-my-ghostty` repo. Never open the Xcode GUI. Never touch `/Applications/OMG.app`.

---

## Core Rules

1. **Testing strategy by changed modules, not release type**:
   - For patch/minor/major releases, preview then execute `macos/build.nu --action test --changed-since "v<PREVIOUS_VERSION>"`. This includes all release commits and worktree changes, plus direct module dependents and version smoke coverage.
   - Shared host/core, build/test infrastructure, or unmapped changes conservatively select all routine Swift suites. Explicit broad sweeps remain available with `--test-modules all`; do not force them solely because of a minor bump.
   - `.interactiveDesktop` native drag/focus tests are optional, excluded by default, and reported **NOT RUN**, not passed. After relevant native tab/drag/focus/event changes, schedule them explicitly with `--include-desktop-tests` on an unlocked foreground desktop. XCUITest stays excluded.
   - Swift selection does not replace affected Zig/Python/shell or artifact checks. See `docs/TESTING.md`.
2. **Build and test strictly serially**: Never run multiple builds or tests concurrently (`build.db: database is locked`).
3. **Shell compatibility**: Pi shell may be Fish. Wrap multiline shell commands with `/bin/bash -lc '...'`.
4. **GitHub CLI target**: Always pass `--repo jischeng/oh-my-ghostty` when running `gh release create` (`upstream` points to `ghostty-org/ghostty`).
5. **Release signing**: Use persistent self-signing (`OMG_SIGNING_MODE=self-signed`) with the same pinned certificate on every release. Source the private `signing.env`; initialize it once with `python3 dist/macos/omg_signing.py create <private-directory>`. Never regenerate an existing identity or fall back to ad-hoc for public releases. Apps and DMGs are not notarized; Developer ID, paid membership, and notarization profiles are not prerequisites. Record persistent self-signing, no notarization, first-launch Gatekeeper behavior, and the possible one-time authorization on migration. Full TCC upgrade experiments are not a release prerequisite and must be reported NOT RUN when omitted. Sparkle EdDSA signing remains required.
6. **Rosetta**: If Rosetta 2 is not installed, the script verifies the `x86_64` Mach-O slice without launching it. Record the actual architecture checks and any unperformed launch checks in release notes.
7. **Bundle the Session Runtime**: Every release App must include `Contents/Resources/session-runtime`, containing the universal local `omgd` relay, Linux x86_64/aarch64 and macOS x86_64/aarch64 artifacts, dependencies, manifests, `revision`, `snapshot-revision`, and `askpass`. Use the existing build/sign scripts; do not ship an App-only build or require users to download/compile a separate daemon. See `docs/RELEASING.md#native-session-runtime-artifacts`.
8. **Preserve remote session ownership**: A single remote `omgd` owns session actor threads and PTYs. Deployment creates the service on the host as supported; it does not install one daemon per Session. Never replace a live remote daemon or delete a cached revision needed by existing sessions as part of release validation. New cgroup/close capabilities do not retroactively upgrade old pinned sessions.

---

## Workflow 1: Install OMG Dev (Local Testing)

```bash
.agents/skills/omg-release/scripts/install-dev.sh
```

The Dev installers resolve an installed Python interpreter and clear inherited
`SDKROOT` before running build/validation tools. For standalone checks, use
`dist/macos/dev-tool.sh python3 ...`, `... xcrun ...`, or `... swiftlint ...`.
Do not invoke `/usr/bin/python3` to probe for Python: its Apple launcher can
open a Command Line Tools installer when SDK selection is stale. This does
not change the separately pinned signing interpreter or its Keychain ACL.

**Prerequisites**:
- Working tree **must be clean** (commit changes first).
- Use `--skip-build` if the app was just compiled.
- For the `omg-workspace` checkout, use this standard installer and `/Applications/OMG Dev.app`. For an explicitly selected PTY channel, use `bash dist/macos/install-pty-dev.sh` and `/Applications/OMG Dev PTY.app`. PTY installation also packages the native relay and both Linux architectures.

---

## Workflow 2: Publish OMG Release

### Step 0: Signing Preflight (Before Version Bump or Build)

Source the existing private configuration, then run:
```bash
source "<private-signing-directory>/signing.env"
bash dist/macos/signing-python.sh unlock
```
The launcher uses `signing-python.pin` next to the private Keychain (canonical
Python executable + SHA-256, no secret). Never use bare `python3` for credential
setup/unlock: PATH can select Python 3.12 while the existing ACL trusts 3.14.
A successful actual credential unlock records the initial pin; an already-unlocked
Keychain alone does not prove credential access and does not create a pin.

For this machine's legacy setup, the previously authorized interpreter was
Homebrew **3.14.7**. If no pin exists, explicitly choose that installed executable:
```bash
export OMG_SIGNING_PYTHON="/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/bin/python3.14"
bash dist/macos/signing-python.sh unlock
```
Do not substitute another installed Python automatically. A missing executable,
fingerprint change, or OSStatus -25293 requires stopping before builds. Report
the executable path/version (not secrets). If the original runtime is unavailable
or denied, the owner performs one-time reauthorization from an interactive terminal:
```bash
# Explicitly choose the intended runtime first; keep the existing certificate.
export OMG_SIGNING_PYTHON="/absolute/path/to/chosen/python3"
bash dist/macos/signing-python.sh store-password
bash dist/macos/signing-python.sh unlock
```
This saves the runtime pin only after successful setup. No allow-all ACL,
identity regeneration, ad-hoc fallback, password retrieval CLI, or shell tracing.
`build-release.sh` and `package-release.sh` repeat the preflight automatically;
resume packaging existing apps after recovery, do not rebuild just for an ACL error.

### Step 1: Version & Release Notes
1. Ensure on `main` branch, synced with `origin/main`.
2. Update version in `macos/Ghostty.xcodeproj/project.pbxproj` (all 3 configs: update `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION`).
3. Update `macos/Tests/Helpers/OhMyGhosttyVersionTests.swift` with expected version strings.
4. Create `docs/RELEASE_NOTES_<OMG_VERSION>.md`.

### Step 2: Quality Gates
Run sequentially:
```bash
# 1. Lint, schema & docs
swiftlint lint --strict --config macos/.swiftlint.yml macos
git ls-files -z '*.zig' | xargs -0 mise exec zig@0.16.0 -- zig fmt --check
python3 -m json.tool docs/settings/schema.json >/dev/null
python3 dist/check_omg_docs.py
plutil -lint macos/Ghostty-Info.plist
xcrun ibtool --warnings --errors --notices --output-format human-readable-text macos/Sources/App/MainMenu.xib
rm -f default.profraw

# Signing policy contracts (separate from app-hosted Swift tests)
python3 -m unittest discover -s dist -p 'test_omg_signing.py'
python3 -m unittest discover -s dist -p 'test_omg_keychain.py'

# 2. Swift tests for all commits since the previous published OMG version
macos/build.nu --action test --changed-since "v<PREVIOUS_VERSION>" --test-plan-only
macos/build.nu --action test --changed-since "v<PREVIOUS_VERSION>"

# Explicit modules or an intentional broad routine sweep
# macos/build.nu --action test --test-modules git,editor
# macos/build.nu --action test --test-modules all

# Optional real native drag regression after relevant changes; desktop must be unlocked
# macos/build.nu --action test --only-testing GhosttyTests/VerticalTabMouseTests --include-desktop-tests

# Selector changes need offline contract tests too
python3 -m unittest discover -s dist -p 'test_omg_test_plan.py'
```

### Step 3: Build Release Binaries
```bash
.agents/skills/omg-release/scripts/build-release.sh <OMG_VERSION>
```
Output placed under `.release-build/<OMG_VERSION>/`.

The script already invokes `dist/macos/build-session-runtime.py --macos all`
and copies its output into **each** arm64, x86_64 and universal App. Keep builds
serial; `TMPDIR=/tmp` may be used when the invoking environment has a short-lived
temporary directory. Rust/Cargo, the corresponding Rust targets and Zig are
required by the runtime builder.

For runtime changes, run these checks serially before packaging:
```bash
cargo fmt --manifest-path session-runtime/Cargo.toml --check
cargo clippy --manifest-path session-runtime/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path session-runtime/Cargo.toml -- --test-threads=1
cargo build --manifest-path session-runtime/Cargo.toml
python3 -m unittest discover -s session-runtime/tests -p 'test_*.py'
macos/build.nu --action test --only-testing GhosttyTests/SessionRuntimeConnectionTests
```
These supplement, not replace, Step 2's change-selected suites. Python discovery
skips environment-dependent SSH and Linux containment tests unless configured;
report those skips explicitly. For lifecycle/containment changes, run
`test_containment_linux.py` on an authorized disposable Linux runtime using
`OMG_CONTAINMENT_TEST_BINARY` pointing to the **packaged** target binary. It
creates two sessions, verifies detach retention and isolated Close including
setsid/double-fork descendants, then SIGKILLs its test host to verify supervisor
cleanup. Never aim fault injection at an existing work daemon or use a permanent
hard-coded test host.

### Step 4: Sign & Package DMGs
```bash
source "<private-signing-directory>/signing.env"
# One-time interactive setup (not required on every release):
# bash dist/macos/signing-python.sh store-password
# The signing script automatically unlocks from the dedicated login-Keychain item.
# If access fails, stop; never read/print credentials or fall back to ad-hoc.
# After the first persistent release, preserve its app and set:
# export OMG_PREVIOUS_SIGNED_APP="<previous-persistent-release>/OMG.app"
PREVIOUS_TAG=v<PREVIOUS_VERSION> \
.agents/skills/omg-release/scripts/package-release.sh <OMG_VERSION>
```
Produces `arm64`, `x86_64`, and `universal` DMGs, `SHA256SUMS.txt`, and `appcast.xml`.

Before publishing, inspect the final signed App in each packaged DMG:
- Require all runtime platform directories, matching manifest revisions and all
  listed dependencies; recompute manifest SHA-256 hashes **after signing**.
- Verify the universal local relay and the intended Mach-O/ELF architectures.
  `sign_omg_app.sh` signs nested Mach-O files and refreshes their hashes before
  sealing the App; do not modify runtime resources after App signing.
- Check the local relay launches (`omgd version`) and run remote acceptance with
  packaged artifacts. A cross-build proves compilation, not execution on that
  OS/CPU. Distinguish key/password SSH, first deployment/reuse, detach/reconnect,
  pending Close across disconnect/restart, expiry and real Agent conversation
  recovery in the validation report. Follow the acceptance gates in
  `docs/RELEASING.md`; record any outstanding cases rather than claiming them passed.
- Linux cgroup cleanup requires supported systemd/cgroup v2: root uses a system
  transient service; non-root needs an accessible lingering user manager. Do not
  enable linger, request privilege escalation or disable SELinux to make a gate
  pass. Unsupported environments and macOS retain process-group-only cleanup.
  Daemon-crash cleanup is not preservation of the original PTY/Agent process.
- Old hosts without `durable-close/1` cannot acknowledge durable Close; their
  requests may remain pending. Keep this compatibility limit visible.

The DMGs already carry `omgd`; a separate public daemon asset is not required.

### Step 5: Commit, Tag & Push
```bash
git add macos/Ghostty.xcodeproj/project.pbxproj macos/Tests/Helpers/OhMyGhosttyVersionTests.swift docs/RELEASE_NOTES_<OMG_VERSION>.md
git commit -m "release: prepare OMG <OMG_VERSION>"
git push origin main

git tag -a "v<OMG_VERSION>" -m "OMG <OMG_VERSION> · Ghostty 1.3.2-dev"
git push origin "refs/tags/v<OMG_VERSION>"
```

### Step 6: Publish GitHub Release
```bash
gh release create "v<OMG_VERSION>" \
  .release-build/<OMG_VERSION>/artifacts/OMG-<OMG_VERSION>-macos-arm64.dmg \
  .release-build/<OMG_VERSION>/artifacts/OMG-<OMG_VERSION>-macos-x86_64.dmg \
  .release-build/<OMG_VERSION>/artifacts/OMG-<OMG_VERSION>-macos-universal.dmg \
  .release-build/<OMG_VERSION>/artifacts/SHA256SUMS.txt \
  .release-build/<OMG_VERSION>/artifacts/appcast.xml \
  --repo jischeng/oh-my-ghostty \
  --title "OMG <OMG_VERSION>" \
  --notes-file docs/RELEASE_NOTES_<OMG_VERSION>.md
```

---

## Completion Report Checklist
- Commit SHAs and tag name (`vX.Y.Z`).
- Architectures built (`arm64`, `x86_64`, `universal`).
- Persistent certificate/DR verification, launch-probe evidence, and explicit not-notarized status.
- Prior persistent app compatibility if supplied; report migration/omitted desktop TCC verification honestly.
- Runtime revision/snapshot revision, bundled platform matrix and post-sign manifest checks.
- Packaged-runtime SSH/lifecycle/containment results, actual supervisor mode, and unexecuted platform/Agent recovery cases. Report broad-suite failures and isolated retries separately.
- GitHub Release URL and list of 5 uploaded assets.
