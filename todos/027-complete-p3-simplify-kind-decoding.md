---
status: pending
priority: p3
issue_id: 027
tags: [code-review, simplicity]
---

# Simplify Kind decoding in AgentTemplate.init(from:)

## Problem Statement
17-line block manually decodes Kind as String, duplicating Kind.init(from:)'s fallback logic.

## Findings
Code review found redundant manual decoding that reimplements logic already present in the Kind type's own Decodable conformance.

## Proposed Solution
Use `decodeIfPresent(Kind.self, forKey: .kind)` which invokes Kind's own decoder. Only handle nil case (migration).

## Technical Details
**Affected files:**
- `macos/Sources/Features/Ghostties/Models/AgentTemplate.swift` (init from decoder, lines 235-251)

## Acceptance Criteria
- [ ] Kind decoding uses `decodeIfPresent(Kind.self, forKey: .kind)`
- [ ] Manual string-to-Kind mapping is removed
- [ ] Migration from nil kind still works correctly
