---
status: complete
priority: p2
issue_id: "003"
tags: [code-review, data-integrity, persistence]
dependencies: []
---

# Orphaned lastSelectedProjectId Not Cleaned Up on Project Deletion

## Problem Statement

When a project is deleted, `lastSelectedProjectId` is not cleared in `WorkspaceStore.removeProject(id:)` and not validated in `WorkspacePersistence.validate()`. The stale UUID persists in `workspace.json` indefinitely. The view layer handles this gracefully (falls back to first project), but the persistence layer violates referential integrity.

## Findings

- **Security Sentinel**: Finding 1 (Medium) — "persisted state remains inconsistent"
- **Data Integrity Guardian**: Finding 3 (Medium) — "one gap in the validation pipeline"

## Proposed Solutions

### Fix (Small effort)

1. Add cleanup to `removeProject`:
```swift
func removeProject(id: UUID) {
    sessions.removeAll { $0.projectId == id }
    projects.removeAll { $0.id == id }
    if lastSelectedProjectId == id { lastSelectedProjectId = nil }
    persist()
}
```

2. Add validation to `WorkspacePersistence.validate()`:
```swift
if let lastId = validated.lastSelectedProjectId,
   !knownProjectIds.contains(lastId) {
    validated.lastSelectedProjectId = nil
}
```

**Effort:** Small (2 additions, ~5 lines total)
**Risk:** None

## Acceptance Criteria

- [ ] Deleting a project clears `lastSelectedProjectId` if it matches
- [ ] Loading a workspace.json with stale `lastSelectedProjectId` cleans it up
- [ ] Sidebar still falls back to first project when selection is nil

## Work Log

| Date | Action | Result |
|------|--------|--------|
| 2026-02-20 | Identified by Security Sentinel + Data Integrity Guardian | Consensus |
