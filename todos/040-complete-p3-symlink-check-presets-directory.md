---
status: pending
priority: p3
issue_id: 040
tags: [code-review, security]
---
# Symlink check on presets directory
## Problem Statement
No check if ~/.ghostties/presets is a symlink to attacker-controlled location
## Proposed Solution
Verify isDirectory and not symlink in loadPresets()
## Affected Files
- PresetLoader.swift
