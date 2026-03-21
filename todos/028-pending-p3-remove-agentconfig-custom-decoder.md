---
status: pending
priority: p3
issue_id: 028
tags: [code-review, simplicity]
---

# Remove unnecessary AgentConfig custom decoder

## Problem Statement
Custom decoder exists only to provide `?? []` for `additionalFlags`. 23 lines of boilerplate.

## Findings
Code review found that the entire custom Decodable implementation exists solely to default one optional array to empty. This is disproportionate boilerplate.

## Proposed Solution
Make `additionalFlags: [String]?`, use `?? []` at call sites. Drop custom decoder and explicit init.

## Technical Details
**Affected files:**
- `macos/Sources/Features/Ghostties/Models/AgentTemplate.swift` (AgentConfig, lines 58-83)

## Acceptance Criteria
- [ ] Custom decoder is removed from AgentConfig
- [ ] `additionalFlags` is optional with `?? []` at call sites
- [ ] Existing persisted data with and without additionalFlags decodes correctly
