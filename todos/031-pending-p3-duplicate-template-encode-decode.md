---
status: pending
priority: p3
issue_id: 031
tags: [code-review, architecture]
---

# Replace duplicateTemplate manual copy with encode/decode

## Problem Statement
`duplicateTemplate` manually copies every field. Fragile when fields are added -- new fields will be silently dropped from duplicates.

## Findings
Code review identified the same fragile manual-copy pattern seen in other parts of the codebase. An encode/decode round-trip leverages existing Codable conformance and automatically picks up new fields.

## Proposed Solution
Encode/decode round-trip with fresh UUID: `var copy = try JSONDecoder().decode(AgentTemplate.self, from: JSONEncoder().encode(original)); copy.id = UUID()`

## Technical Details
**Affected files:**
- `macos/Sources/Features/Ghostties/Store/WorkspaceStore.swift` (duplicateTemplate, lines 242-251)

## Acceptance Criteria
- [ ] `duplicateTemplate` uses encode/decode round-trip instead of manual field copy
- [ ] Duplicated template gets a fresh UUID
- [ ] All fields including nested AgentConfig are preserved in the duplicate
