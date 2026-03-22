# Solution: Session Status — Needs Attention Indicator

**Date:** 2026-03-22
**Brainstorm:** `docs/brainstorms/2026-03-22-session-status-improvements-brainstorm.md`
**Plan:** `docs/plans/2026-03-22-feat-session-status-needs-attention-plan.md`

## Problem

The sidebar's "waiting" state (terracotta pulse) was ambiguous. It covered both "agent is blocked on user input (permission prompt, yes/no question)" and "a subprocess is running silently." Users with multiple agents couldn't tell which sessions needed immediate attention without clicking into each one.

## Solution

Added a new `SessionIndicatorState.needsAttention` case with a distinct purple indicator and faster pulse animation. The state is detected via layered heuristics on the terminal's surface title.

### Visual Treatment

| Property | Value |
|----------|-------|
| Color | Purple `#A855F7` (`WorkspaceLayout.needsAttentionPurple`) |
| Animation | Pulse at 1.0s cycle (vs 2.0s for `.waiting`) |
| Text weight | `.semibold` (vs `.medium` for `.waiting`) |
| Accessibility label | "needs your attention" |
| Priority | 5 (between `.waiting`=4 and `.error`=6) |

### Detection Logic (`SessionCoordinator.isLikelyPromptingForInput`)

Two layers evaluated against `lastSurfaceTitle[sessionId]` (the terminal's surface title, used as a proxy for the last output line):

1. **Prompt character heuristic**: title ends with `?` or `:` and is longer than 3 characters
2. **Pattern matching**: regex against `promptPatterns` — a `static let` array of known prompt patterns (`[Y/n]`, `Allow`, `Do you want`, `Press Enter`, `Confirm`, `approve`, `permission`, `(y)`, `(yes)`)

The `promptPatterns` array is declared as `private static let` on `SessionCoordinator` to avoid re-allocating on every call to `isLikelyPromptingForInput`.

Returns true if a pattern matches (strong signal) OR if the prompt character heuristic matches (weaker signal, but sufficient with length guard).

### Data Flow

The surface title is captured in `subscribeToOutput()` when `lastOutputSubject` fires. This reuses the existing Combine subscription without adding new terminal integrations. The title is stored in `lastSurfaceTitle[sessionId]` and read by `isLikelyPromptingForInput()` when the indicator state computation reaches the `.waiting` branch.

## Files Changed

| File | Change |
|------|--------|
| `macos/Sources/Features/Ghostties/Models/AgentSession.swift` | Added `.needsAttention` case, priority 5; bumped `.error` to 6 |
| `macos/Sources/Features/Ghostties/WorkspaceLayout.swift` | Added `needsAttentionPurple` color token |
| `macos/Sources/Features/Ghostties/SessionDetailView.swift` | Purple color mapping, 1.0s pulse animation, semibold text weight, accessibility label |
| `macos/Sources/Features/Ghostties/SessionCoordinator.swift` | `lastSurfaceTitle` tracking, `promptPatterns` (`static let`), `isLikelyPromptingForInput()` method, `.needsAttention` in `indicatorState(for:)` |
| `macos/Sources/Features/Ghostties/ProjectDisclosureRow.swift` | Purple in `projectHeaderColor` switch |
| `macos/Tests/Workspace/AgentSessionTests.swift` | Updated priority sort test, added comparison tests |

## Known Limitations

- **Surface title as proxy**: `lastSurfaceTitle` captures the terminal's surface title (set via escape sequences like OSC 0/2) as a proxy for the last output line. This is not the actual terminal content -- any program can set the title to arbitrary text via `\e]0;...\a`. A process that sets the title to a question mark or a pattern like `[Y/n]` will trigger a false positive. Conversely, if a prompt appears in terminal output but the title is unchanged (e.g., still showing a path), the heuristic will miss it. Future improvement: use a machine-readable signal (OSC extension or sideband) if Claude Code ever exposes one.
- **False positives from title manipulation**: a subprocess that sets the title to something ending with `?` or matching a known pattern will trigger needsAttention even if it's not actually waiting for input. The 2-second silence threshold from the `.waiting` check provides a natural guard.
