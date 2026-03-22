---
status: pending
priority: p3
issue_id: 043
tags: [code-review, dead-code]
---
# Remove dead presetsDirectory property
## Problem Statement
`presetsDirectory` computed property (URL version) is never referenced
## Proposed Solution
Delete it. Only `presetsDirectoryPath` (String version) is used.
## Affected Files
- PresetLoader.swift
