# Session Status Improvements Brainstorm — 2026-03-22

> Add a "needs attention" indicator state with purple color and layered detection for when an agent is blocked waiting for user response.

## What We're Building

A new session indicator state that tells the user at a glance: "this agent needs your input — it's not just waiting, it's blocked on YOU." Currently, all non-output silence falls under the terracotta "waiting" state, whether it's Claude Code asking a permission question or a subprocess running `less`.

## Why This Matters

The sidebar shows session status dots, but "waiting" (terracotta pulse) is ambiguous:
- Is Claude Code asking me a yes/no question? → I need to respond NOW
- Is a long build running silently? → It's fine, check back later
- Is the agent idle between tasks? → Nothing to do

Users (especially with multiple agents running) need to know which sessions need their attention without clicking into each one.

## Key Decisions

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| 1 | New state name | `.needsAttention` | Clear intent — the agent needs the user |
| 2 | Color | Purple `#A855F7` | Cool color stands out against warm palette (green/yellow/terracotta/red). Immediately eye-catching. |
| 3 | Animation | Faster pulse (1.0s vs 2.0s for waiting) | More urgent than regular waiting |
| 4 | Detection | Layered: silence heuristic + output pattern matching | Two layers of confidence, no LLM needed |
| 5 | Priority | Between `.waiting` (4) and `.error` (5) | Needs attention is more urgent than waiting but less severe than error |

## Detection Strategy (Layered)

### Layer 1: Silence + Not-at-Prompt Heuristic (baseline)
```
waiting state (no output > 2s)
  + NOT at shell prompt
  + last output character is ? or :
  = candidate for needsAttention
```

### Layer 2: Output Pattern Matching (confirmation)
```swift
// Pure regex — no LLM, no API calls, no tokens
let promptPatterns = [
    "\\[Y/n\\]", "\\[yes/no\\]", "\\[y/N\\]",
    "Allow .+\\?", "Do you want",
    "Press Enter", "Confirm",
    "approve", "permission"
]
```

If both layers match → `.needsAttention`
If only Layer 1 → stays `.waiting` (less confident)

### Where to Get Terminal Output
`SessionCoordinator` already subscribes to `surface.lastOutputSubject` for activity tracking. The same subscription can capture the last line of output for pattern matching. No new terminal integration needed.

## Updated Color Palette

| State | Color | Hex | Animation | Meaning |
|-------|-------|-----|-----------|---------|
| inactive | gray | system | none | Session ended |
| idle | medium gray | system | none | At prompt, nothing happening |
| processing | green | #34C759 | bounce | Actively outputting |
| waiting | terracotta | #C97350 | pulse 2.0s | Silent, not at prompt |
| **needsAttention** | **purple** | **#A855F7** | **pulse 1.0s** | **Blocked on user input** |
| longRunning | yellow | #FFCC00 | none | Processing > 30 min |
| error | red | #FF3B30 | none | Non-zero exit |

## Files to Modify

| File | Change |
|------|--------|
| `AgentSession.swift` | Add `.needsAttention` case to `SessionIndicatorState`, priority 4.5 |
| `WorkspaceLayout.swift` | Add `needsAttentionPurple` color token |
| `SessionDetailView.swift` | Map `.needsAttention` → purple color + 1.0s pulse |
| `SessionCoordinator.swift` | Add last-line capture + pattern matching in `indicatorState(for:)` |
| `ProjectDisclosureRow.swift` | Add case to status aggregation |

## Open Questions

1. **False positives** — what if a subprocess prints `"Do you want fries with that?"` and it's not actually waiting for input? The silence heuristic helps (must also be no output for 2s+), but edge cases exist.
2. **Claude Code-specific signals** — if Claude Code ever adds an OSC escape code for "waiting for permission," we should prefer that over pattern matching. Future-proof the detection to check for machine-readable signals first.
3. **Notification** — should `.needsAttention` trigger a macOS notification? (Probably yes for the menu bar icon feature, but not for v1 of this improvement.)

---

*Next: Plan both this and the preset gallery together via `/workflows:plan`.*
