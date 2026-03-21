---
status: pending
priority: p2
issue_id: 021
tags: [code-review, performance]
---

# Move buildCommand() off main thread

## Problem Statement
`buildCommand()` reads a file from disk synchronously. Called from `@MainActor` context (SessionCoordinator.createSession). Could block UI on cold disk cache or large prompt files.

## Findings
Code review identified synchronous file I/O on the main thread path. While typically fast, cold disk cache or large system prompt files could cause visible UI hitches.

## Proposed Solution
Wrap `buildCommand()` call in `Task.detached` inside `SessionCoordinator.createSession()`.

## Technical Details
**Affected files:**
- `macos/Sources/Features/Ghostties/Coordinators/SessionCoordinator.swift` (lines 103-111)

## Acceptance Criteria
- [ ] File I/O for prompt reading happens off main thread
- [ ] UI remains responsive during session creation with large prompt files
