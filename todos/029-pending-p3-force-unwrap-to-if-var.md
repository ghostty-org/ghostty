---
status: pending
priority: p3
issue_id: 029
tags: [code-review, quality]
---

# Force unwraps in validation to if-var binding

## Problem Statement
`validated.templates[i].agent!.additionalFlags` uses force unwrap guarded by `if != nil`. While safe at runtime, force unwraps are a code smell and mask intent.

## Findings
Code review flagged force unwraps that could be replaced with safer Swift patterns. The `if != nil` guard makes the force unwrap technically safe, but the pattern is fragile under refactoring.

## Proposed Solution
Use `if var agent = validated.templates[i].agent { ... validated.templates[i].agent = agent }`

## Technical Details
**Affected files:**
- `macos/Sources/Features/Ghostties/Persistence/WorkspacePersistence.swift` (validate, lines 164-166)

## Acceptance Criteria
- [ ] Force unwraps in validation are replaced with `if var` binding
- [ ] Behavior is unchanged
