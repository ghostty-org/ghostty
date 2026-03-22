---
status: pending
priority: p3
issue_id: 038
tags: [code-review, simplicity]
---
# Merge presetRow/templateRow
## Problem Statement
Two near-identical row builders in TemplatePickerView (~35 LOC duplication)
## Proposed Solution
Single parameterized function with onTap closure
## Affected Files
- TemplatePickerView.swift
