---
status: pending
priority: p2
issue_id: 022
tags: [code-review, performance, duplication]
---

# Remove redundant buildCommand() call in ProjectDisclosureRow

## Problem Statement
`buildCommand()` is called in ProjectDisclosureRow.relaunchSession() AND again in SessionCoordinator.createSession(). Two file reads for one relaunch.

## Findings
Code review found duplicate invocations of `buildCommand()` in the relaunch flow. The pre-check in ProjectDisclosureRow is unnecessary since SessionCoordinator handles command building and fallback.

## Proposed Solution
Remove the buildCommand() pre-check from ProjectDisclosureRow. Let SessionCoordinator handle command building and fallback in one place.

## Technical Details
**Affected files:**
- `macos/Sources/Features/Ghostties/Views/Sidebar/ProjectDisclosureRow.swift` (lines 270-289)
- `macos/Sources/Features/Ghostties/Coordinators/SessionCoordinator.swift`

## Acceptance Criteria
- [ ] `buildCommand()` called exactly once per relaunch
- [ ] Relaunch flow still works correctly with fallback behavior
