---
status: pending
priority: p2
issue_id: 024
tags: [code-review, security]
---

# Replace additionalFlags blocklist with allowlist

## Problem Statement
`dangerousFlagCharacters` only blocks `;&|`. Misses backticks, `$()`, newlines, redirects, parentheses.

## Findings
Code review found that the current blocklist approach is insufficient. Multiple shell metacharacter classes are not covered, leaving injection vectors open.

## Proposed Solution
Validate flags match `^--?[a-zA-Z][a-zA-Z0-9_-]*(=\S+)?$`. Reject anything else.

## Technical Details
**Affected files:**
- `macos/Sources/Features/Ghostties/Persistence/WorkspacePersistence.swift` (validate method)

## Acceptance Criteria
- [ ] Flags are validated against an allowlist regex pattern
- [ ] Flags with backticks are rejected
- [ ] Flags with `$()` are rejected
- [ ] Flags with newlines are rejected
- [ ] Flags with redirects (`>`, `<`) are rejected
- [ ] Valid flags like `--model=gpt-4` still pass
