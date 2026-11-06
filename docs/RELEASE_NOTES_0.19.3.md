# OMG 0.19.3 · Ghostty 1.3.2-dev

OMG 0.19.3 is a bug-fix release for Agent session restoration, Agent History,
terminal link detection, native tab presentation, and session runtime recovery.
The Ghostty base is unchanged.

## Highlights

- **Restore Agent sessions with usable titles.** History resumes immediately show
  the saved working directory, keep it through runtime hydration, and avoid
  displaying the local SSH launcher directory in remote tabs. Live directories
  and explicit user tab names retain their existing priority.
- **Restore SSH Agent splits correctly.** A resumed SSH Agent can split into a
  new remote shell without starting another Agent or depending on a local
  runtime descriptor.
- **Find wrapped directory links.** Command-click recognizes relative directory
  names wrapped across terminal lines, including enclosed paths and up to eight
  continuation rows.
- **Keep Agent History complete and readable.** Injected system context and
  Codex compaction summaries are hidden without truncating conversation text;
  large histories use bounded single-pass parsing.
- **Preserve complete Quick Input messages.** Draft imports, queued messages,
  acknowledgements, and restored resume commands are handled without dropping
  content or leaving stale feedback.
- **Improve native tab and sidebar presentation.** Selected tab icons update
  consistently without redundant redraws, workspace pickers select the current
  workspace, and the translucent sidebar uses native blending.

## Version and distribution

- OMG **0.19.3**, bundle version **49**.
- Ghostty **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`.
- Includes the changes since the published `v0.19.2` tag.
- Release apps use the existing persistent self-signed identity and are **not
  notarized**. Gatekeeper may block the first launch; users who trust the
  download can review and allow it in System Settings > Privacy & Security.
  Sparkle updates retain their separate EdDSA signature.
- The arm64, x86_64, and universal apps include the local and remote session
  runtime artifacts.

## Validation

- The release's Swift selection passed **1477 tests in 178 suites**. Native
  interactive-desktop suites remained optional and were not run.
- Session runtime Rust tests passed **58 tests**; its Python suite passed **35
  tests with 4 environment-dependent skips**. Signing and Keychain policy tests
  passed with **3 optional tests skipped**.
- Targeted Zig checks for OMG path/link handling, restored OSC 7 directories,
  and the new context-signal callback passed. SwiftLint, Zig formatting, the
  settings schema, documentation, plist, Interface Builder, and remote helper
  checks passed.
