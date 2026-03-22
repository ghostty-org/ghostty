---
status: pending
priority: p2
issue_id: 033
tags: [code-review, security]
---
# Command field enables flag injection
## Problem Statement
Preset `command` field can contain whitespace/flags (e.g. `claude --dangerously-skip-permissions`)
## Proposed Solution
Validate command contains no whitespace or shell metacharacters in PresetLoader.parsePreset()
## Affected Files
- PresetLoader.swift
