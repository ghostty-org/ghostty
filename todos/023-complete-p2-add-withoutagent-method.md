---
status: pending
priority: p2
issue_id: 023
tags: [code-review, architecture]
---

# Add withoutAgent() method on AgentTemplate

## Problem Statement
`ProjectDisclosureRow.relaunchSession()` reconstructs a full AgentTemplate by copying every field manually to clear the agent config. Fragile -- new fields will be silently dropped.

## Findings
Code review identified a manual field-by-field copy pattern that will break silently when new fields are added to AgentTemplate.

## Proposed Solution
Add `func withoutAgent() -> AgentTemplate` on the model itself. One-liner that returns a copy with `agent: nil`.

## Technical Details
**Affected files:**
- `macos/Sources/Features/Ghostties/Models/AgentTemplate.swift`
- `macos/Sources/Features/Ghostties/Views/Sidebar/ProjectDisclosureRow.swift`

## Acceptance Criteria
- [ ] `withoutAgent()` method exists on AgentTemplate
- [ ] No manual field-by-field copy of AgentTemplate anywhere outside the model
- [ ] ProjectDisclosureRow uses the new method
