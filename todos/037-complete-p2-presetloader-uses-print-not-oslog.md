---
status: pending
priority: p2
issue_id: 037
tags: [code-review, quality]
---
# PresetLoader uses print() not OSLog
## Problem Statement
print() calls invisible in Console.app. WorkspacePersistence uses Logger.
## Proposed Solution
Add `private static let logger = Logger(subsystem:category:)`, replace print() with logger.warning/error
## Affected Files
- PresetLoader.swift
- AgentTemplate.swift
