---
title: Replace SessionTemplate with agent-first AgentTemplate model
category: model-migration
problem_type: architectural-refactor
component: macos/Sources/Features/Ghostties/Models/AgentTemplate
symptoms:
  - SessionTemplate lacked agent-specific configuration (model, permission mode, system prompt)
  - No CLI construction logic for Claude Code sessions
  - Only 2 built-in templates (Shell, Claude Code) with no Orchestrator support
  - No structured Kind enum to distinguish session types
  - Agent identity lost on session relaunch
root_cause: SessionTemplate was a generic session launcher with no awareness of agent workflows, making it impossible to configure Claude Code flags, orchestrator patterns, or project-scoped templates
solution_type: model-replacement-with-migration
technologies: [Swift, SwiftUI, AppKit, Codable, JSONDecoder]
date_solved: 2026-03-21
confidence: high
---

# SessionTemplate → AgentTemplate Migration

## Problem

`SessionTemplate` was a flat model with only `command: String?` and `environmentVariables: [String: String]`. There was no way to:
- Configure Claude Code agent personas (system prompt, model, permissions, tools)
- Persist agent identity across session relaunches
- Scope templates to specific projects
- Distinguish between session types (shell vs. AI agent vs. custom command)

Users had to manually type `claude --model opus --append-system-prompt "..."` every time. When a session crashed or restarted, the agent persona was lost.

## Investigation

1. **Brainstormed 3 model designs** — (A) extend SessionTemplate with optional fields (dead fields on shell), (B) separate AgentConfig layer (two models, more complex), (C) agent-first redesign where every session is an "agent." **Chose C** for unified mental model.

2. **Verified Claude Code CLI flags** — `--append-system-prompt-file` does NOT exist. Only `--append-system-prompt` (inline string). Also discovered `--permission-mode`, `--effort`, `--allowedTools`.

3. **Investigated SurfaceConfiguration** — Ghostty wraps all commands with `/bin/sh -c`, so arguments work as a concatenated string. No argv array needed.

4. **SpecFlow analysis** — Identified 20 gaps and 12 critical questions, including shell injection risks, prompt file path traversal, and persistence migration strategy.

## Solution

### AgentTemplate Model

```swift
struct AgentTemplate: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var kind: Kind          // .shell | .claudeCode | .custom
    var isDefault: Bool
    var isGlobal: Bool
    var projectId: UUID?    // nil = global, set = project-scoped
    var command: String?
    var environmentVariables: [String: String]
    var workingDirectory: String?
    var agent: AgentConfig? // nil for .shell

    enum Kind: String, Codable, Hashable {
        case shell, claudeCode, custom
        // Safe decoder: falls back to .shell on unknown values
    }

    struct AgentConfig: Codable, Hashable {
        var systemPromptFile: String?    // Read file, pass via --append-system-prompt
        var model: String?               // --model (opus, sonnet, haiku)
        var permissionMode: String?      // --permission-mode
        var effort: String?              // --effort
        var allowedTools: [String]?      // --allowedTools
        var additionalFlags: [String]    // Escape hatch for other CLI flags
    }
}
```

### CLI Construction (buildCommand)

```swift
func buildCommand() -> String {
    var parts: [String] = []
    if let command { parts.append(command) }
    guard let agent else { return parts.joined(separator: " ") }

    if let model = agent.model {
        parts.append("--model"); parts.append(model)
    }
    if let promptFile = agent.systemPromptFile {
        let expandedPath = (promptFile as NSString).expandingTildeInPath
        if let contents = try? String(contentsOfFile: expandedPath, encoding: .utf8) {
            let escaped = contents.replacingOccurrences(of: "'", with: "'\\''")
            parts.append("--append-system-prompt"); parts.append("'\(escaped)'")
        }
    }
    // ... permissionMode, effort, allowedTools, additionalFlags similarly
    return parts.joined(separator: " ")
}
```

### Backward-Compatible Codable Migration

The custom decoder handles three cases:

```swift
// 1. New format: kind key present with known value
if let rawKind = try container.decodeIfPresent(String.self, forKey: .kind),
   let decodedKind = Kind(rawValue: rawKind) {
    self.kind = decodedKind

// 2. Kind key present but unknown value → .shell (safe fallback)
} else if container.contains(.kind) {
    self.kind = .shell

// 3. No kind key → old SessionTemplate format, infer from command
} else {
    switch command {
    case nil: self.kind = .shell
    case "claude": self.kind = .claudeCode
    default: self.kind = .custom
    }
}
```

### Built-in Templates (Deterministic UUIDs)

```swift
static let shell = AgentTemplate(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, ...)
static let claudeCode = AgentTemplate(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, command: "claude", ...)
static let orchestrator = AgentTemplate(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, command: "claude",
    agent: AgentConfig(systemPromptFile: "~/.claude/orchestrator-prompt.md", model: "opus"), ...)
```

Built-in templates are **code-defined, never persisted**. Only custom templates are written to workspace.json. On startup, `WorkspaceStore` merges: `AgentTemplate.defaults + customTemplates`.

## Files Changed

| File | Change |
|------|--------|
| `Models/AgentTemplate.swift` | **New** — model, Kind enum, AgentConfig, buildCommand(), backward-compat decoder |
| `Models/SessionTemplate.swift` | **Deleted** |
| `WorkspacePersistence.swift` | Templates type → `[AgentTemplate]`, orphan cleanup, flag sanitization |
| `WorkspaceStore.swift` | Templates property + CRUD updated, `templates(for:)` project filtering |
| `SessionCoordinator.swift` | `createSession()` calls `buildCommand()`, resolves base command via PATH |
| `ProjectDisclosureRow.swift` | Relaunch uses AgentTemplate, error handling for deleted templates |
| `TemplatePickerView.swift` | Kind-based icons, AgentTemplate type, "Duplicate and Edit" for defaults |
| `WorkspaceSidebarView.swift` | `AgentTemplate.shell` fallback |
| `AgentTemplateTests.swift` | **New** — 22 tests (built-ins, Codable, backward compat, buildCommand) |

## Prevention Strategies

### 1. Never let synthesized Decodable guard persisted state

Any `Codable` struct written to `~/Library/Application Support` gets a custom decoder. Every field uses `decodeIfPresent` with an explicit default. Swift's synthesized decoder throws `DecodingError` on missing keys, which wipes the entire workspace.json.

### 2. Decode enums as raw primitives first, then construct

```swift
// WRONG — throws on unknown value, wipes state
self.kind = try container.decode(Kind.self, forKey: .kind)

// RIGHT — safe fallback
let rawKind = try container.decodeIfPresent(String.self, forKey: .kind)
self.kind = rawKind.flatMap(Kind.init(rawValue:)) ?? .shell
```

Use `String` raw values (not `Int`) for enums that touch disk — `Int` raw values break if cases are reordered.

### 3. Use deterministic UUIDs for built-in constants

The `00000000-0000-0000-0000-` prefix is reserved for built-ins. UUIDv4 random generation never produces this prefix. Test the exact UUID strings to catch accidental edits.

### 4. Validate referential integrity on load

`WorkspacePersistence.validate()` runs on every `load()` and prunes orphaned sessions (missing template or project), orphaned project-scoped templates, and dangerous flags. Every new foreign-key relationship must have a validation clause.

### 5. Shell command construction is a security boundary

Every value in `buildCommand()` should be shell-escaped. The `additionalFlags` allowlist should use regex validation, not a blocklist of known-bad characters.

## Test Patterns

Four categories for any model that touches disk:

1. **Round-trip** — encode, decode, assert all fields match
2. **Old JSON without new fields** — hand-crafted JSON missing new keys, assert defaults
3. **Invalid/unknown values** — enum raw values that don't match any case, assert fallback
4. **Cross-version forward compat** — JSON with extra unknown keys, assert decoding succeeds

## Cross-References

- [Codable Enum State-Wipe Bug](../logic-errors/codable-enum-raw-value-wipes-state.md) — safe enum decoding pattern
- [Two-Layer State Architecture](two-layer-state-architecture-swiftui-appkit-session-management.md) — WorkspaceStore + SessionCoordinator separation
- [Code Review Remediation](../logic-errors/sidebar-code-review-remediation.md) — API design, env var validation
- [Brainstorm](../../brainstorms/2026-03-21-agent-templates-brainstorm.md) — design decisions and model diagram
- [Implementation Plan](../../plans/2026-03-21-feat-agent-template-system-plan.md) — phased implementation roadmap

## Verification

- Build passes: `zig build -Doptimize=ReleaseFast`
- 215 tests pass (22 new AgentTemplate tests)
- Backward compatibility: old SessionTemplate JSON decodes correctly
- Unknown Kind values degrade to `.shell` (no state wipe)
- 5-agent code review completed: architecture, security, performance, patterns, simplicity
- 13 review findings documented in `todos/019-031`
