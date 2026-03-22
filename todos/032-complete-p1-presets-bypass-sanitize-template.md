---
status: pending
priority: p1
issue_id: 032
tags: [code-review, security]
---
# Presets bypass sanitizeTemplate
## Problem Statement
PresetLoader templates inserted into WorkspaceStore.templates without sanitization
## Proposed Solution
Add `WorkspacePersistence.sanitizeTemplate()` call in WorkspaceStore.init() after loading presets
## Affected Files
- WorkspaceStore.swift
