---
status: pending
priority: p3
issue_id: 026
tags: [code-review, duplication]
---

# Extract dangerousEnvKeys to shared constant

## Problem Statement
Same env key blocklist duplicated in WorkspacePersistence.swift and TemplatePickerView.swift.

## Findings
Code review found identical blocklist arrays maintained in two separate files. Changes to one will not propagate to the other, creating a consistency risk.

## Proposed Solution
Move to `AgentTemplate.dangerousEnvKeys` or a shared validation namespace.

## Technical Details
**Affected files:**
- `macos/Sources/Features/Ghostties/Persistence/WorkspacePersistence.swift`
- `macos/Sources/Features/Ghostties/Views/TemplatePicker/TemplatePickerView.swift`
- `macos/Sources/Features/Ghostties/Models/AgentTemplate.swift`

## Acceptance Criteria
- [ ] A single shared constant defines the dangerous env keys list
- [ ] Both WorkspacePersistence and TemplatePickerView reference the shared constant
- [ ] No duplicate env key lists exist in the codebase
