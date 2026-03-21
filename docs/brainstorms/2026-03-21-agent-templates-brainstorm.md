# Agent Templates Brainstorm — 2026-03-21

> Replace SessionTemplate with agent-first AgentTemplate model. Every session is an "agent" — Shell is just an agent with no AI config.

## What We're Building

An agent-first template system for the Ghostties workspace sidebar. Three pillars:

1. **Reduce session setup friction** — Today you manually type `claude --append-system-prompt-file ...` or remember which flags to pass. Templates make this one-click.
2. **Enforce agent boundaries** — Different agents have different permissions, tools, and context. Templates codify "this agent is an orchestrator" or "this agent only touches frontend."
3. **Persist agent identity across relaunches** — When a session crashes or restarts, the agent comes back as the same persona without re-setup.

## Why This Approach

### Agent-first over extending SessionTemplate
Evaluated 3 options:
- **A: Extend SessionTemplate** — add optional Claude Code fields. Simple but Shell templates carry dead fields.
- **B: Separate AgentConfig layer** — two models, cleaner separation, but more complex.
- **C: Agent-first redesign** (chosen) — every session is an "agent." Unified mental model. Shell is `.shell` kind with `agent: nil`. Most opinionated but cleanest.

### Rebuild from template over snapshot
On relaunch, rebuild the CLI from the template rather than replaying a stored command string.
- Prompt file edits propagate automatically (orchestrator-prompt.md is a living document)
- Session stores `templateId`, not resolved command — simpler persistence
- Matches mental model: "this session uses the Orchestrator template"

## Key Decisions

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| 1 | Core problem | All three: friction, boundaries, persistence | The three pillars of the feature |
| 2 | Model design | Agent-first redesign (Option C) | Every session is an "agent." Unified mental model. |
| 3 | AgentConfig scope | systemPromptFile + model + additionalFlags | Prompt file for persona, model for cost/capability, flags for escape hatch |
| 4 | Kind enum | .shell, .claudeCode, .custom | Custom = any command + optional agent config |
| 5 | Default templates | Shell + Claude Code + Orchestrator | Orchestrator demonstrates the agent config pattern |
| 6 | Relaunch behavior | Rebuild CLI from template | Template is source of truth, prompt file edits propagate |
| 7 | Template scope | Global + per-project overrides | Global available everywhere, projects can add their own |
| 8 | .custom kind | Any command + optional agent config | For aider, dev servers, etc. |

## Model Design

```
AgentTemplate (replaces SessionTemplate)
┌──────────────────────────────────────┐
│  id: UUID                            │
│  name: String                        │
│  kind: Kind (.shell|.claudeCode|     │
│              .custom)                │
│  isDefault: Bool                     │
│  isGlobal: Bool (vs project-scoped)  │
│                                      │
│  ┌─ terminal ─────────────────────┐  │
│  │ command: String?               │  │
│  │ environmentVariables: [S: S]   │  │
│  │ workingDirectory: String?      │  │
│  └────────────────────────────────┘  │
│                                      │
│  ┌─ agent: AgentConfig? ──────────┐  │
│  │ systemPromptFile: String?      │  │
│  │ model: String?                 │  │
│  │ additionalFlags: [String]      │  │
│  └────────────────────────────────┘  │
└──────────────────────────────────────┘
```

### Kind Enum
```swift
enum Kind: String, Codable {
    case shell       // User's login shell, no AI
    case claudeCode  // Claude Code CLI with optional agent config
    case custom      // Any command (aider, dev servers) with optional agent config
}
```

### AgentConfig
```swift
struct AgentConfig: Codable {
    var systemPromptFile: String?    // Read file, pass via --append-system-prompt
    var model: String?               // --model (opus, sonnet, haiku)
    var permissionMode: String?      // --permission-mode (plan, auto, acceptEdits, etc.)
    var effort: String?              // --effort (low, medium, high, max)
    var allowedTools: [String]?      // --allowedTools (Bash, Edit, Read, etc.)
    var additionalFlags: [String]    // Escape hatch for any other CLI flags
}
```

> **CLI flag note (verified 2026-03-21):** `--append-system-prompt-file` does NOT exist.
> Only `--append-system-prompt` (inline string). The `buildCommand()` function must
> read the file contents and pass them via `--append-system-prompt`.
> Additional useful flags discovered: `--permission-mode`, `--effort`, `--allowedTools`,
> `--disallowedTools`, `--add-dir`.

## Built-in Templates

```swift
// Deterministic UUIDs for persistence stability
static let shell = AgentTemplate(
    id: UUID("00000000-0000-0000-0000-000000000001"),
    name: "Shell",
    kind: .shell,
    isDefault: true, isGlobal: true
)

static let claudeCode = AgentTemplate(
    id: UUID("00000000-0000-0000-0000-000000000002"),
    name: "Claude Code",
    kind: .claudeCode,
    command: "claude",
    isDefault: true, isGlobal: true
)

static let orchestrator = AgentTemplate(
    id: UUID("00000000-0000-0000-0000-000000000003"),
    name: "Orchestrator",
    kind: .claudeCode,
    command: "claude",
    agent: AgentConfig(
        systemPromptFile: "~/.claude/orchestrator-prompt.md",
        model: "opus"
    ),
    isDefault: true, isGlobal: true
)
```

## CLI Construction

```
func buildCommand() -> String {
    var args = [command ?? ""]

    if let agent = agent {
        if let model = agent.model {
            args += ["--model", model]
        }
        if let promptFile = agent.systemPromptFile {
            // NOTE: --append-system-prompt-file doesn't exist.
            // Must read file contents and pass via --append-system-prompt
            let contents = try String(contentsOfFile: promptFile)
            args += ["--append-system-prompt", contents]
        }
        args += agent.additionalFlags
    }

    return args.joined(separator: " ")
}
```

Examples:
```
Shell:        /bin/zsh
Claude Code:  claude
Orchestrator: claude --model opus --append-system-prompt "$(cat ~/.claude/orchestrator-prompt.md)"
Custom:       aider --model opus
```

## Relaunch Flow

```
Session exits (crash, `exit`, or user-initiated)
       │
       v
SessionCoordinator detects surface close
       │
       v
Look up session.templateId → AgentTemplate
       │
       v
AgentTemplate.buildCommand()
       │
       v
Create new SurfaceView with built command
       │
       v
Session resumes with same persona
```

## Template Scope

- **Global templates**: Available in all projects. Stored in workspace.json at the top level.
- **Per-project templates**: Only visible within their project. Stored with a `projectId` field.
- **Override behavior**: If a project has a template with the same name as a global one, the project version takes precedence in the picker.
- **Built-in templates**: Always global, `isDefault: true`, cannot be deleted.

## Open Questions (for /workflows:plan)

1. **Persistence migration** — How to backward-compat decode old SessionTemplate JSON. Existing workspace.json files must not break.
2. **CLI flag verification** — RESOLVED: `--append-system-prompt-file` doesn't exist. Must read file and pass via `--append-system-prompt`. Additional flags discovered: `--permission-mode`, `--effort`, `--allowedTools`, `--disallowedTools`, `--add-dir`.
3. **Per-project storage** — In workspace.json alongside globals (with projectId)? Or separate per-project JSON?
4. **UI for agent config** — How does the template editor expose promptFile, model, flags? Text fields? Pickers?
5. **Prompt file discovery** — Browse `~/.claude/prompts/` or raw path field?
6. **Template CRUD in sidebar** — Current TemplatePickerView and ProjectSettingsView changes needed.

## Affected Files (Current → New)

| File | Impact |
|------|--------|
| `Models/SessionTemplate.swift` | Replace with `AgentTemplate.swift` |
| `WorkspaceStore.swift` | `templates` property type changes |
| `WorkspacePersistence.swift` | Migration from old JSON, new Codable |
| `SessionCoordinator.swift` | `createSession` uses `buildCommand()` |
| `TemplatePickerView.swift` | Show agent config indicator, edit UI |
| `ProjectSettingsView.swift` | Default template picker uses new type |
| `WorkspaceSidebarView.swift` | Template display updates |
| `AgentSession.swift` | `templateId` reference unchanged but type context shifts |

---

*Next: Run `/workflows:plan` to generate implementation plan.*
