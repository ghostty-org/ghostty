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

Two layers evaluated against the surface title (last known terminal title):

1. **Prompt character heuristic**: title ends with `?` or `:` and is longer than 3 characters
2. **Pattern matching**: regex against known prompt patterns (`[Y/n]`, `Allow`, `Do you want`, `Press Enter`, `Confirm`, `approve`, `permission`, `(y)`, `(yes)`)

Returns true if a pattern matches (strong signal) OR if the prompt character heuristic matches (weaker signal, but sufficient with length guard).

### Data Flow

The surface title is captured in `subscribeToOutput()` when `lastOutputSubject` fires. This reuses the existing Combine subscription without adding new terminal integrations. The title is stored in `lastOutputLines[sessionId]` and read by `isLikelyPromptingForInput()` when the indicator state computation reaches the `.waiting` branch.

## Files Changed

| File | Change |
|------|--------|
| `macos/Sources/Features/Ghostties/Models/AgentSession.swift` | Added `.needsAttention` case, priority 5; bumped `.error` to 6 |
| `macos/Sources/Features/Ghostties/WorkspaceLayout.swift` | Added `needsAttentionPurple` color token |
| `macos/Sources/Features/Ghostties/SessionDetailView.swift` | Purple color mapping, 1.0s pulse animation, semibold text weight, accessibility label |
| `macos/Sources/Features/Ghostties/SessionCoordinator.swift` | `lastOutputLines` tracking, `isLikelyPromptingForInput()` method, `.needsAttention` in `indicatorState(for:)` |
| `macos/Sources/Features/Ghostties/ProjectDisclosureRow.swift` | Purple in `projectHeaderColor` switch |
| `macos/Tests/Workspace/AgentSessionTests.swift` | Updated priority sort test, added comparison tests |

## Known Limitations

- **Title-based detection**: uses the terminal title as a proxy for the last output line. If the terminal title is set to something unrelated (e.g., a path), the heuristic may miss prompts. Future improvement: add OSC escape code support if Claude Code ever exposes a machine-readable "waiting for permission" signal.
- **False positives**: a subprocess that sets the title to something ending with `?` will trigger needsAttention even if it's not actually waiting for input. The 2-second silence threshold from the `.waiting` check provides a natural guard.
