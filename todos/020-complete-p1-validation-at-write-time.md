---
status: pending
priority: p1
issue_id: 020
tags: [code-review, security]
---

# Apply validation at write time, not just load time

## Problem Statement
`WorkspacePersistence.validate()` sanitizes additionalFlags and env vars, but only runs during `load()`. Templates created/updated via UI within the same session bypass sanitization until next app restart.

## Findings
Code review found that sanitization is only applied on deserialization. Any template created or modified through the UI during the current session is persisted without validation, leaving a window for dangerous values to be written to disk.

## Proposed Solution
Extract sanitization into a static method. Call it in both `load()` and `WorkspaceStore.addTemplate()`/`updateTemplate()`.

## Technical Details
**Affected files:**
- `macos/Sources/Features/Ghostties/Persistence/WorkspacePersistence.swift`
- `macos/Sources/Features/Ghostties/Store/WorkspaceStore.swift`

## Acceptance Criteria
- [ ] Sanitization logic is extracted into a reusable static method
- [ ] `WorkspaceStore.addTemplate()` calls sanitization before persist
- [ ] `WorkspaceStore.updateTemplate()` calls sanitization before persist
- [ ] Creating a template with dangerous additionalFlags via UI results in the flags being stripped before persist
