---
status: pending
priority: p2
issue_id: 035
tags: [code-review, architecture]
---
# Eliminate preset string duplication
## Problem Statement
270 LOC of preset content duplicated as Swift strings AND .md files in Resources
## Proposed Solution
Load bundled presets from Bundle.main at seed time. Remove inline string constants from PresetLoader.
## Affected Files
- PresetLoader.swift
