# Plan: Write Agent Templates Brainstorm Document

## Context

Brainstorming session about replacing `SessionTemplate` with an agent-first `AgentTemplate` model in Ghostties. All key decisions made through 6 rounds of dialogue. This plan captures the full output and delegates writing the brainstorm doc.

## Complete Decision Log

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| 1 | Core problem | All three equally: reduce setup friction, enforce agent boundaries, persist identity across relaunches | These are the three pillars of the feature |
| 2 | Model design | Agent-first redesign (Option C) — replace `SessionTemplate` with `AgentTemplate` | Every session is an "agent." Shell is just an agent with no AI config. Unified mental model. |
| 3 | AgentConfig scope | `systemPromptFile` + `model` + `additionalFlags` (3 knobs) | Prompt file for persona, model for cost/capability, flags for escape hatch. Covers power users without over-engineering. |
| 4 | Kind enum | `.shell`, `.claudeCode`, `.custom` | Custom = any command + optional agent config (aider, dev servers, etc.) |
| 5 | Default templates | Shell + Claude Code + Orchestrator (3 built-ins) | Orchestrator demonstrates the agent config pattern. Users create their own variants. |
| 6 | Relaunch behavior | Rebuild CLI from template every time | Template is source of truth. Prompt file edits propagate automatically. Session stores `templateId`, not resolved command. |
| 7 | Template scope | Global + per-project overrides | Global templates available everywhere. Projects can create project-specific templates (e.g., "Frontend" only for web projects). |
| 8 | .custom kind | Any command + optional agent config | For non-Claude AI tools or dev servers. Same AgentConfig fields available but optional. |

## Model Diagram

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

Built-in defaults (deterministic UUIDs):
  ...001  Shell        kind: .shell,      agent: nil
  ...002  Claude Code  kind: .claudeCode, agent: nil
  ...003  Orchestrator kind: .claudeCode, agent: AgentConfig(
            systemPromptFile: "~/.claude/orchestrator-prompt.md",
            model: "opus", additionalFlags: [])
```

## Open Questions (for /workflows:plan)

1. **Persistence migration** — How to backward-compat decode old `SessionTemplate` JSON into new `AgentTemplate`. Existing workspace.json files must not break.
2. **CLI flag verification** — Do `--model`, `--append-system-prompt-file`, `--allowedTools` exist as Claude Code CLI flags? Need to verify before hardcoding field names.
3. **Per-project storage** — Where do project-specific templates live? In workspace.json alongside global ones (with a projectId field)? Or in a separate per-project JSON?
4. **UI for agent config** — How does the template editor expose promptFile, model, flags? Text fields? Picker for model? File browser for prompt file?
5. **Prompt file discovery** — Should the UI help browse `~/.claude/prompts/` or is it a raw path field?
6. **Template CRUD in sidebar** — How does creating/editing/deleting templates work in the current UI? What needs to change?

## Brainstorm Document Outline

Target: `docs/brainstorms/2026-03-21-agent-templates-brainstorm.md`

### Sections:
1. **What We're Building** — agent-first template model, the 3 pillars (friction, boundaries, persistence)
2. **Why This Approach** — why agent-first over extend/separate, why rebuild-from-template over snapshot
3. **Key Decisions** — the 8-row decision table above
4. **Model Design** — AgentTemplate + AgentConfig structs, Kind enum, ASCII diagram
5. **Built-in Templates** — Shell, Claude Code, Orchestrator with full config
6. **CLI Construction** — how AgentTemplate → command line string
7. **Relaunch Flow** — session exit → look up templateId → rebuild CLI → launch surface
8. **Template Scope** — global vs per-project, how overrides work
9. **Open Questions** — deferred to plan phase
10. **Affected Files** — current SessionTemplate.swift + all consumers

## Subagent Delegation

### Agent 1: Verify Claude Code CLI flags (Explore)
- Check what CLI flags `claude` actually supports (--model, --append-system-prompt-file, --allowedTools, etc.)
- Verify flag names match our AgentConfig field names
- Report any flags we should add to AgentConfig or any that don't exist

### Agent 2: Write brainstorm document (general-purpose)
- Receives: full decision log, model diagram, open questions, document outline
- Writes: `docs/brainstorms/2026-03-21-agent-templates-brainstorm.md`
- Must include ASCII diagrams, decision table, CLI construction example, relaunch flow

### Agent 3: Update session notes + ORCHESTRATOR.md (general-purpose)
- Add brainstorm session to SESSION_NOTES.md
- Update ORCHESTRATOR.md in-flight work section (agent templates now in brainstorm phase)
- Update ORCHESTRATOR.md decision log with key decisions from this session

## Verification

- Brainstorm doc has all 8 decisions with reasoning
- Model diagram matches what was agreed in dialogue
- Open questions clearly deferred to plan phase
- CLI flag names verified against actual Claude Code CLI
- Session notes and ORCHESTRATOR.md updated
- Document ready for `/workflows:plan` handoff
