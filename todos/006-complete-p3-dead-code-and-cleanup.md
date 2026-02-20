---
status: complete
priority: p3
issue_id: "006"
tags: [code-review, cleanup, yagni]
dependencies: []
---

# Dead Code and Minor Cleanup Items

## Problem Statement

Several small YAGNI violations and dead code identified across the Phase 4 commit.

## Findings

### A. Unused menu item stored properties (Code Simplicity)
`AppDelegate.swift`: `menuToggleSidebar`, `menuNextProject`, `menuPreviousProject` are stored but never read. NSMenu retains the items.

### B. Dead `setSidebarVisible(_:)` method (Code Simplicity)
`WorkspaceViewContainer.swift`: method exists but is never called. Initial state is set via constraint constants in `setup()`.

### C. Two-step State construction (Data Integrity + Code Simplicity)
`WorkspaceStore.persist()`: State is constructed with defaults then overwritten. Add `sidebarVisible` and `lastSelectedProjectId` to `State.init` params.

### D. Id vs ID naming inconsistency (Pattern Recognition)
`selectedProjectID` (uppercase) vs `lastSelectedProjectId`, `activeSessionId`, `projectId` (lowercase). Pick one convention.

## Proposed Solutions

All are small, independent fixes:
- Delete 3 stored properties + 3 assignments in AppDelegate (~6 lines)
- Delete `setSidebarVisible` method (~4 lines)
- Add init params to `WorkspacePersistence.State`
- Standardize on `Id` (matches majority of codebase)

## Acceptance Criteria

- [ ] No dead code in AppDelegate menu properties
- [ ] No uncalled public methods in WorkspaceViewContainer
- [ ] State construction is single-step
- [ ] Build succeeds with no warnings

## Work Log

| Date | Action | Result |
|------|--------|--------|
| 2026-02-20 | Identified by Code Simplicity + Pattern Recognition + Data Integrity | P3 batch |
