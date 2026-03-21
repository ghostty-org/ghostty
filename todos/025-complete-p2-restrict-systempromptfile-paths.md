---
status: pending
priority: p2
issue_id: 025
tags: [code-review, security]
---

# Restrict systemPromptFile paths + size cap

## Problem Statement
systemPromptFile accepts any path. Could read arbitrary files (SSH keys, etc.). No size limit -- multi-megabyte files could cause issues.

## Findings
Code review identified that there are no restrictions on which files can be read via systemPromptFile. An unrestricted path allows reading sensitive files. Lack of a size cap could cause performance or memory issues.

## Proposed Solution
Restrict to `~/.claude/` directory and project rootPath. Add 1MB file size cap.

## Technical Details
**Affected files:**
- `macos/Sources/Features/Ghostties/Models/AgentTemplate.swift` (buildCommand)

## Acceptance Criteria
- [ ] Paths outside `~/.claude/` and project rootPath are rejected
- [ ] Files larger than 1MB are skipped with a warning logged
- [ ] Valid paths within allowed directories continue to work
