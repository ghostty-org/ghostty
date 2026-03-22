---
status: pending
priority: p3
issue_id: 039
tags: [code-review, performance]
---
# Static promptPatterns array
## Problem Statement
Regex patterns allocated fresh every 1-second timer tick per session
## Proposed Solution
Move to `private static let promptPatterns` on SessionCoordinator
## Affected Files
- SessionCoordinator.swift
