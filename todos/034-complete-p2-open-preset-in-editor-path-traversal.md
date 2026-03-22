---
status: pending
priority: p2
issue_id: 034
tags: [code-review, security]
---
# openPresetInEditor path traversal
## Problem Statement
Template name used to reconstruct filename — `../../.ssh/authorized_keys` possible
## Proposed Solution
Validate resolved path stays within presets directory via standardizingPath prefix check
## Affected Files
- TemplatePickerView.swift
