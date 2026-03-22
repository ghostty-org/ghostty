# Plan: Session Status — Needs Attention Indicator

**Date:** 2026-03-22
**Brainstorm:** `docs/brainstorms/2026-03-22-session-status-improvements-brainstorm.md`

## Goal

Add a `.needsAttention` indicator state (purple, faster pulse) that distinguishes "agent is blocked on user input" from generic "waiting." This helps users with multiple agents identify which sessions need immediate action.

## Changes

### 1. AgentSession.swift — Add `.needsAttention` case

- Insert `.needsAttention` between `.waiting` and `.error` in `SessionIndicatorState`
- Priority: 5 (bump `.error` to 6)
- Update existing `indicatorStatePriority` test expectations

### 2. WorkspaceLayout.swift — Add purple color token

- Add `needsAttentionPurple = Color(red: 0.659, green: 0.333, blue: 0.969)` (#A855F7)

### 3. SessionDetailView.swift — Map to visual treatment

- `statusColor`: `.needsAttention` -> `WorkspaceLayout.needsAttentionPurple`
- Animation: use pulse like `.waiting` but faster (1.0s cycle vs 2.0s)
- Add `isAttentionPulsing` state var with separate animation modifier
- `statusLabel`: "needs your attention"
- Text weight: `.semibold` for `.needsAttention`
- `sessionTextColor`: `.primary` (same as waiting/processing)

### 4. SessionCoordinator.swift — Detection logic

- Add `lastOutputLines: [UUID: String]` dictionary to track last terminal output line
- In `subscribeToOutput()`: capture last line from surface title (proxy for output)
- Add `isLikelyPromptingForInput(sessionId:)` method with:
  - Layer 1: last output ends with `?` or `:`
  - Layer 2: regex pattern matching for known prompt patterns (`[Y/n]`, `Allow`, `Do you want`, etc.)
  - Return true if pattern matches OR (ends with prompt char AND line length > 3)
- In `indicatorState(for:)`: before returning `.waiting`, check `isLikelyPromptingForInput` and return `.needsAttention` if true
- Clean up `lastOutputLines` entries in `clearRuntime(id:)`

### 5. ProjectDisclosureRow.swift — Status aggregation

- Add `.needsAttention` case to `projectHeaderColor` switch (returns purple)
- Comparable ordering handles aggregation automatically (priority 5 > waiting's 4)

### 6. Tests — AgentSessionTests.swift

- Update existing `indicatorStatePriority` test to include `.needsAttention`
- Add `needsAttentionPriorityHigherThanWaiting` test
- Add `needsAttentionPriorityLowerThanError` test

## Files Modified

| File | Type |
|------|------|
| `AgentSession.swift` | Model — new enum case |
| `WorkspaceLayout.swift` | Layout — new color token |
| `SessionDetailView.swift` | View — color, animation, label |
| `SessionCoordinator.swift` | Coordinator — detection logic |
| `ProjectDisclosureRow.swift` | View — aggregation case |
| `AgentSessionTests.swift` | Tests — priority verification |

## Not Changing

- `AgentTemplate.swift` (different agent)
- `TemplatePickerView.swift` (different agent)
- `WorkspaceStore.swift` (different agent)
