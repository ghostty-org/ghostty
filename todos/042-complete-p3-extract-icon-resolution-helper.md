---
status: pending
priority: p3
issue_id: 042
tags: [code-review, duplication]
---
# Extract icon resolution helper
## Problem Statement
`template.icon ?? iconName(for: template)` repeated 3 times in TemplatePickerView
## Proposed Solution
Extract to `resolvedIcon(for:)` method or computed property on AgentTemplate
## Affected Files
- TemplatePickerView.swift
