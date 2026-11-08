# macOS SSH Session Manager Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for inline execution. Track steps below.

**Goal:** Deliver persistent macOS SSH profiles with Keychain passwords and OpenSSH certificates.

**Architecture:** SwiftUI manager opens existing Ghostty surfaces. A dedicated early-entry mode of the signed app launches system SSH and serves askpass requests, accessing Keychain directly instead of transferring secrets over IPC.

**Tech Stack:** Swift, SwiftUI, AppKit, Security.framework, system OpenSSH.

**Spec:** ../specs/2026-11-09-macos-ssh-session-manager-design.md

## Global Constraints

- macOS only; no shared Zig/C API changes.
- Passwords and key passphrases only in Keychain, never argv, environment or profile JSON.
- Explicit user action to reconnect; retain host key verification.
- Use macos/build.nu for app build/test; no issue or PR creation.

## Review Focus

- Malformed destination and shell metacharacters must never execute commands.
- Broken/newer profile files must never be overwritten.
- Wrong stored passwords must not loop or answer OTP prompts.
- Profiles using proxies must not automatically disclose target credentials to the proxy.
- Concurrent launches must have separate runtime state and cleanup.

## Task 1: Models, validation, invocation and persistence

Files: Features/SSH/SSHProfile.swift, SSHSessionStore.swift, SSHCredentialStore.swift; Tests/SSH/SSHProfileTests.swift.

Produces SSHProfile, SSHSessionDocument, SSHInvocation.arguments(for:manual:), SSHSessionStore and SSHCredentialStore.

- [x] Write tests rejecting invalid destination/port, preserving argv boundaries, building certificate arguments and versioned JSON.
- [x] Observe failures before defining implementation.
- [x] Implement Codable models, argument builder, atomic owner-only persistence and Keychain access.
- [x] Run focused standalone checks. App tests blocked by missing nu/GhosttyKit.

## Task 2: Launcher and authentication

Files: Features/SSH/SSHRuntime.swift, SSHAuthentication.swift; App/main.swift; Tests/SSH/SSHAuthenticationTests.swift.

Consumes validated profile and credential references; produces SSHRuntime.runIfRequested() and launch configuration.

- [x] Test credential prompt matching and single-use policy before implementation.
- [x] Implement dedicated launch/askpass entry points, private per-launch JSON, forced askpass, Keychain/manual AppKit prompt, exit/reconnect handling and cleanup.
- [x] Verify actual system SSH forced askpass on a PTY; test host confirmation/cancel and credential matching without real secrets.
- [x] Confirm proxy configuration disables automatic credential use and process environment contains no secrets.

## Task 3: Manager UI and app integration

Files: Features/SSH/SSHSessionManager.swift, SSHSessionEditor.swift; App/AppDelegate.swift, MainMenu.xib.

Consumes store/runtime and existing TerminalController APIs.

- [x] Add folder/filter/search/favorite manager, editor with file selection and Keychain save, duplicate/delete, tab/window actions.
- [x] Add File menu entry and retain manager controller across window closes.
- [x] Build/typecheck and test model/authentication suite; review changed code for restoration and split inheritance.

## Execution record

- User requested implementation; execute inline in current checkout without additional worktree or commits. Existing design remains uncommitted.
- Ruling: reuse the signed app executable for launch/askpass early entry and direct Keychain access. Avoid secret IPC and extra signing targets; askpass is synchronous and independent of the main app event loop.
- Ruling: runtime JSON contains profile metadata and Keychain references only. Owner-only per-launch directory and file plus a single-use claim prevent accidental repeated automatic responses. Same-user compromise remains outside the security boundary.


## Verification record

- Core suite: 14 Swift Testing tests pass, including failed-before-fix process group regression.
- Actual macOS OpenSSH 10.2p1: disposable local sshd certificate authentication, host confirmation and forced askpass under PTY pass.
- Signed helper integration: actual product helper sources compile; disposable Keychain create/read/delete, untrusted caller rejection, certificate authentication and interactive foreground PTY input pass.
- All new Swift feature sources typecheck together using minimal stubs for the existing Ghostty app/surface/controller types. This is not a full app build.
- MainMenu.xib XML parses and git diff --check passes.
- Full app build attempted with macos/build.nu --action build: unavailable because nu is not installed; macos/GhosttyKit.xcframework is also absent. SwiftLint is not installed. Full GUI and Keychain denial/OTP/tab-close checks remain.
- Final review: fresh reviewer found a P1 Foundation.Process foreground group defect. Reproduced in a failing test, fixed with posix_spawn, core suite and signed foreground PTY integration pass.
- Ruling: canonicalize executable paths using libc realpath; Foundation preserves /var aliases on this macOS version, causing a legitimate helper to fail caller validation. Signed helper integration reproduced and verifies the fix.
- Ruling: Keychain cleanup failures are surfaced to the user; persistent cleanup retry journaling is deferred. A failed cleanup can leave an unused credential item requiring removal in Keychain Access.
- Deferred: automatic removal of metadata-only runtime directories left by SIGKILL; normal exit, HUP and TERM clean up. Launch specs expire and are single-use.
- No commit, issue, PR, or release was created.


## Full macOS validation follow-up

- Installed Nushell 0.116.1, compatible Zig 0.17.1, and Xcode Metal Toolchain 17F109.
- `zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native`: PASS. Native arm64 GhosttyKit generated.
- `macos/build.nu --action build`: BUILD SUCCEEDED. App: macos/build/Debug/Ghostty.app.
- `macos/build.nu --action test`: 303 test cases passed, 1 failed, 1 skipped (Xcode summary; 441 parameterized runs passed). All 14 SSH tests passed within the actual app test target.
- Existing unrelated KeyboardLayoutTests.characterAppliesModifiers failed because current Korean layout returned ㅁ for both shifted and unmodified KeyA. No input-source setting or unrelated test was changed.
- Launched the built debug app. Computer Use inventory confirms com.mitchellh.ghostty.debug running, but attaching to the app accessibility tree repeatedly timed out. Interactive manager/dialog GUI validation remains unconfirmed.
- Prior entries about missing nu/GhosttyKit describe the initial attempt; those build blockers are resolved. SwiftLint remains unavailable.

## Connection settings and text editing follow-up

- Increase manager and editor width by 15%; show username and host separately.
- New profiles default to password; preserve older profiles' authentication.
- Add persistent terminal and encoding choices with xterm-256color / UTF-8 defaults.
- Use system iconv and a separate PTY for legacy encoding; C child startup performs only async-signal-safe operations before execve. UTF-8 remains on the direct path.
- Use nonblocking PTY writes and bounded paste buffering to avoid bidirectional I/O deadlocks; propagate terminal size and restore the outer terminal state.
- Scope native clipboard/select-all/undo handling to all manager and sheet inputs, including secure fields, as explicitly requested. Assign Command-S to the manager menu.
- Preserve character locale instead of forcing LC_ALL=C; force only LC_MESSAGES for authentication prompts.
- Fresh code review found missing command modifier and blocking PTY input writes; both corrected. ReleaseLocal Universal build passed. Tests not run at the user's explicit request; runtime/GUI validation of these new options remains unconfirmed.


## Modal presentation and further width increase

- Increase manager width from 1085 to 1302, minimum width from 900 to 1080, and editor width from 741 to 890 (20%, rounded up).
- Present the connection manager app-modally. Guard Command-S reentry, provide Close/Escape dismissal, and stop modality on titlebar close.
- Preserve the original terminal parent. Validate and prepare the connection while the manager is visible, then launch only after the modal loop returns.
- Code review corrected list Escape interception and deferred terminal activation until after modal unwind. Tests omitted at user request; validate via optimized app build.
