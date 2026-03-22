---
status: pending
priority: p2
issue_id: 036
tags: [code-review, security]
---
# Presets directory permissions
## Problem Statement
~/.ghostties/presets/ created with 0o755 (world-readable). Prompt content may be sensitive.
## Proposed Solution
Change to 0o700 (owner-only)
## Affected Files
- PresetLoader.swift
