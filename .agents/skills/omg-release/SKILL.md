---
name: omg-release
description: Builds, validates, installs, and publishes Oh My Ghostty macOS development and patch releases. Use when asked to install or replace OMG Dev, prepare a release, bump OMG versions, build arm64/x86_64/universal DMGs, generate the Sparkle appcast, tag, push, or publish a GitHub Release.
compatibility: macOS, Xcode, Zig 0.16.0 via mise, Nushell, SwiftLint, GitHub CLI, and Sparkle tools.
---

# OMG Build and Release

Use this skill only from the `oh-my-ghostty` repository. Read these files before changing or publishing anything:

- `AGENTS.md`
- `macos/AGENTS.md`
- `docs/RELEASING.md`
- `.agents/skills/omg-build/SKILL.md`

The repository documentation remains authoritative. This skill records the safe execution order and recurring local pitfalls.

## Choose a workflow

- **Build, compile, or test OMG from CLI:** use the `omg-build` skill or `macos/build.nu`.
- **Install a test build into OMG Dev:** use [Install OMG Dev](#install-omg-dev).
- **Prepare or publish a release:** use [Release OMG](#release-omg).

Never open the Xcode GUI (`open ...xcodeproj`). Never create a GitHub issue or pull request. Never replace, quit, sign, or otherwise modify `/Applications/OMG.app` during development work.

## Shell rule

Pi background commands run under the user's shell, which may be Fish. Bash `for ...; do` blocks fail when passed directly.

For multiline release commands, either invoke the bundled Bash scripts or wrap the whole command with `/bin/bash -lc '...'`. Do not pass raw Bash loops directly to `bg_run`.

When using `ctx_execute(language: "shell")`, start inline `if` or `for` blocks with a harmless command such as `true`; its preload environment assignment cannot directly prefix a shell compound statement. Prefer the bundled scripts for long workflows.

## Install OMG Dev

Run:

```bash
.agents/skills/omg-release/scripts/install-dev.sh
```

Before invoking the script, require the exact code intended for testing to be committed. If the current task has uncommitted changes, the agent must:

1. review the diff and exclude generated files, secrets, and unrelated user changes;
2. run the checks appropriate to the changed code;
3. use the `writing-commit-messages` skill and create a commit;
4. confirm `HEAD` contains the test changes and the worktree is completely clean;
5. only then run the installer.

Do not bypass this rule by stashing, discarding, or silently including unrelated changes. If unrelated modifications prevent a clean tree and their ownership is unclear, stop and ask the user how to separate them. The installer never creates commits itself; it fails closed so the agent must perform and report the commit first.

The script requires that clean committed worktree so the installed binary maps to one commit. It then:

1. reads the release `MARKETING_VERSION` and derives the short version `<release>-dev.<8-char-commit>`;
2. builds with `macos/build.nu --configuration Debug --action build --marketing-version <dev-version>`;
3. requires bundle ID `com.jischeng.omg.debug`, the derived version, and a `.ReleaseFast` GhosttyKit core;
4. quits only the debug bundle;
5. replaces only `/Applications/OMG Dev.app` using `ditto`;
6. verifies the signature and binary hash;
7. creates or reuses the local annotated tag `dev-v<release>-<8-char-commit>`;
8. launches the installed app.

The `dev-` tag namespace is intentionally disjoint from release tags (`vX.Y.Z`) and does not invoke the OMG release workflow. Tags are local by default to avoid remote tag/CI noise. Push exactly the generated tag only when a remotely resolvable issue reference is needed:

```bash
.agents/skills/omg-release/scripts/install-dev.sh --push-tag
```

Never move or force-update a Dev tag. Never tag a dirty tree: a Git tag identifies a commit and cannot represent uncommitted source. The agent must create a reviewed commit for the intended test state before installation; the installer itself must not manufacture an automatic snapshot commit or silently tag `HEAD` for a dirty build.

Use `--skip-build` only when `macos/build/Debug/OMG.app` is the exact already-tested artifact:

```bash
.agents/skills/omg-release/scripts/install-dev.sh --skip-build
```

After installation, report the source and installed hashes, bundle ID, OMG Dev version, Dev tag and scope, full commit, Ghostty version, build mode, and launch status. When preparing an issue, prefer the complete Dev version and tag over the base release version alone.

## Release OMG

### 1. Establish the version

Fetch `origin` and require `main` to be based on current `origin/main`. Never force-push.

OMG and Ghostty versions are independent:

- OMG patch releases advance `MARKETING_VERSION` (for example `0.5.1` to `0.5.2`).
- `CURRENT_PROJECT_VERSION` is Sparkle's monotonically increasing integer.
- `GhosttyBaseVersion`, `GhosttyBaseRevision`, and `build.zig.zon` do not change for an OMG-only bug fix.
- Never infer a `1.0.0` product milestone.

Before editing, ensure the new tag and GitHub Release do not already exist.

Update all three main-app configurations in `macos/Ghostty.xcodeproj/project.pbxproj`, the current-value assertions in `macos/Tests/Helpers/OhMyGhosttyVersionTests.swift`, and create `docs/RELEASE_NOTES_<version>.md`.

Any SSH replay, lifecycle, loading, discovery, or plugin-facing behavior change must also update `docs/PLUGIN_DEVELOPMENT.md` and relevant tests.

### 2. Validate source and tests

Run the complete gate before committing:

```bash
swiftlint lint --strict --config macos/.swiftlint.yml macos
git ls-files -z '*.zig' | xargs -0 mise exec zig@0.16.0 -- zig fmt --check
python3 -m json.tool docs/settings/schema.json >/dev/null
python3 dist/check_omg_docs.py
plutil -lint macos/Ghostty-Info.plist
xcrun ibtool --warnings --errors --notices \
  --output-format human-readable-text macos/Sources/App/MainMenu.xib
rm -f default.profraw
macos/build.nu --action test
```

> **Tip for targeted testing during development:** `macos/build.nu --action test --only-testing GhosttyTests/<SuiteName>` runs a subset of tests quickly. For final release validation, run the full test suite above.
>
> **Zig command tip:** Whenever running `zig build` or `zig build test`, always pass `-Dversion-string=1.3.2-dev` to prevent Zig's upstream tag validation from aborting on OMG's `v0.x.y` release tags.

Also verify Debug, Release, and ReleaseLocal report the intended `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.

Do not leave `default.profraw` or other generated files in the worktree.

### 3. Build release apps

Run the bundled build script:

```bash
.agents/skills/omg-release/scripts/build-release.sh <OMG_VERSION>
```

It always:

- rebuilds a universal ReleaseFast `GhosttyKit.xcframework` first;
- uses the Ghostty base version, not the OMG version, for `-Dversion-string`;
- builds isolated arm64, x86_64, and universal app roots;
- checks architectures, bundle IDs, short versions, and bundle versions.

The package script performs the executable `.ReleaseFast` probes after all nested components have consistent signatures; launching the freshly built ad-hoc app before that step can fail in dyld because of hardened-runtime library validation.

Output is under `.release-build/<OMG_VERSION>/`.

### 4. Sign, package, and generate the appcast

Check signing prerequisites before claiming a public notarized build:

```bash
security find-identity -v -p codesigning
```

- For a public notarized release, set a Developer ID Application identity and follow the notarization sections in `docs/RELEASING.md`.
- If no Developer ID identity exists, use `OMG_SIGNING_IDENTITY=-`, skip notarization, and explicitly state that artifacts are ad-hoc signed and not Apple-notarized.

Package with the previous published OMG tag:

```bash
OMG_SIGNING_IDENTITY=- \
PREVIOUS_TAG=v<previous-version> \
.agents/skills/omg-release/scripts/package-release.sh <OMG_VERSION>
```

For Developer ID signing, replace `-` with the Keychain identity without storing it in source or logs.

Important Sparkle rule: generate the appcast in a staging directory containing the previous `appcast.xml` and **only the universal DMG**. Passing arm64, x86_64, and universal DMGs together causes Sparkle's duplicate-bundle-version error. The architecture-specific DMGs remain manual-download assets.

The script validates the latest appcast entry's short version, bundle version, EdDSA signature, universal URL, and minimum system version. It also mounts every DMG and runs the x86_64 binary under Rosetta.

### 5. Commit and tag

Prefer two commits when both code and release metadata changed:

```text
macos: <bug-fix summary>
release: prepare OMG <version>
```

Follow the project's commit-message skill. Re-run the documentation/diff gate on the final tree. Push `main`, then create and push exactly one annotated OMG tag:

```bash
git tag -a "v$OMG_VERSION" \
  -m "OMG $OMG_VERSION · Ghostty $GHOSTTY_VERSION"
git push origin "refs/tags/v$OMG_VERSION"
```

Never run `git push --tags`; local Ghostty tags are upstream synchronization history.

### 6. Publish GitHub Release

Create the verified tag release and upload exactly:

- `OMG-<version>-macos-arm64.dmg`
- `OMG-<version>-macos-x86_64.dmg`
- `OMG-<version>-macos-universal.dmg`
- `SHA256SUMS.txt`
- `appcast.xml`

Use `docs/RELEASE_NOTES_<version>.md` as the release body. Verify the final release title, tag, asset set, latest appcast entry, and published asset sizes before marking the task complete.

## Completion report

Always include:

- commits and tag;
- tests and validation gates;
- all built architectures and Rosetta evidence;
- ReleaseFast confirmation;
- signing/notarization status;
- GitHub Release URL and exact asset set;
- any residual limitation.
