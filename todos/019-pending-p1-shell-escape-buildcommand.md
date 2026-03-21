---
status: pending
priority: p1
issue_id: 019
tags: [code-review, security]
---

# Shell-escape all buildCommand() parts

## Problem Statement
`buildCommand()` in `AgentTemplate.swift` concatenates `model`, `permissionMode`, `effort`, `command`, and `allowedTools` directly into a shell command string with no escaping. Only `systemPromptFile` contents are escaped. The resulting string goes to `/bin/sh -c`, enabling shell injection.

## Findings
Code review identified that user-controlled values flow unsanitized into a shell command string. An attacker-controlled model name or tool name containing shell metacharacters could execute arbitrary commands.

## Proposed Solution
Wrap every value appended to `parts[]` in single quotes with internal single-quote escaping (same pattern used for prompt content). Example: `parts.append("'\(value.replacingOccurrences(of: "'", with: "'\\''"))'")`. Extract a `shellEscape(_ value: String) -> String` helper.

## Technical Details
**Affected files:**
- `macos/Sources/Features/Ghostties/Models/AgentTemplate.swift` (buildCommand, lines 168-200)

## Acceptance Criteria
- [ ] All buildCommand() output values are shell-escaped
- [ ] A `shellEscape()` helper is extracted and used consistently
- [ ] Test with metacharacter-containing model name confirms no injection
