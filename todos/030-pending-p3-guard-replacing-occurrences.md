---
status: pending
priority: p3
issue_id: 030
tags: [code-review, performance]
---

# Guard replacingOccurrences with contains check

## Problem Statement
`replacingOccurrences(of: "'")` creates a full string copy even when no single quotes exist.

## Findings
Code review noted an unnecessary string allocation on every call. While minor, the fix is trivial and avoids copies for the common case where no single quotes are present.

## Proposed Solution
`contents.contains("'") ? contents.replacingOccurrences(...) : contents`

## Technical Details
**Affected files:**
- `macos/Sources/Features/Ghostties/Models/AgentTemplate.swift` (buildCommand, line 178)

## Acceptance Criteria
- [ ] `replacingOccurrences` is only called when the string contains single quotes
- [ ] Behavior is unchanged for strings with and without single quotes
