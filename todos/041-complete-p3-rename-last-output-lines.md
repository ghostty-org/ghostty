---
status: pending
priority: p3
issue_id: 041
tags: [code-review, naming]
---
# Rename lastOutputLines
## Problem Statement
`lastOutputLines` stores one surface title per session, not multiple output lines
## Proposed Solution
Rename to `lastSurfaceTitle` to match what it actually stores
## Affected Files
- SessionCoordinator.swift
