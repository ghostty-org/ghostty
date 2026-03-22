# Agent Preset Gallery Brainstorm — 2026-03-22

> Replace the raw agent config form with a curated preset picker. Presets are `.md` files with YAML frontmatter, seeded to `~/.ghostties/presets/` on first launch. Community presets can be added by dropping files in the folder.

## What We're Building

A preset-driven agent picker for the Ghostties sidebar. Instead of manually configuring system prompt files, model selection, and CLI flags, users pick from a gallery of curated agent presets — each one ready to launch with one click.

**Three pillars:**
1. **One-click agents** — select "Code Reviewer" and get a read-only Sonnet agent with a battle-tested review prompt. No config needed.
2. **Tool-agnostic** — presets work with any CLI agent (Claude Code, Codex, Aider) via a `command` field in the frontmatter.
3. **Community-extensible** — drop a `.md` file in `~/.ghostties/presets/` and it appears in the picker. No app update needed.

## Why This Approach

### Presets over raw config
The full agent config form (6 fields: model, prompt file, permission mode, effort, allowed tools, additional flags) is too complex for the template picker. Users don't want to wire up CLI flags — they want to pick "Architect" and start planning.

### File-based presets over hardcoded
Presets as `.md` files with YAML frontmatter means:
- Users can read and edit preset prompts directly
- Community presets are just file drops — no plugin system needed
- Prompt content and config live in one file (not separate JSON + prompt file)
- App bundles defaults, seeds them to disk on first launch

### Tool-agnostic over Claude-specific
Each preset specifies its own `command` (claude, codex, aider). The same gallery works for any CLI agent tool. A "Codex Reviewer" preset is just a file with `command: codex`.

## Key Decisions

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| 1 | Picker UX | Enhanced list in existing 200px popover | Minimal change, familiar pattern, fits sidebar width |
| 2 | Prompt storage | `~/.ghostties/presets/` with first-launch seeding | Editable, community-extensible, no app bundle dependency |
| 3 | File format | `.md` with YAML frontmatter (config) + body (prompt) | One file = config + prompt. Human-readable. |
| 4 | Community import | Drop files in presets folder, app scans on launch | Simplest possible — no UI needed for import |
| 5 | Tool scope | Tool-agnostic (command field in frontmatter) | Works for Claude, Codex, Aider, any CLI |
| 6 | Shell placement | Stays in picker alongside presets | Shell is a valid option, just not an agent |
| 7 | Launch flow | Preview card on click, "don't show again" option | Quick preview shows what you're getting. Power users skip it. |
| 8 | Customization | Right-click → "Edit" opens config form | Advanced config still accessible, just not the primary path |

## Preset File Format

```markdown
---
name: Code Reviewer
description: Reviews code for bugs, security issues, and guideline violations
command: claude
model: sonnet
permissionMode: plan
effort: high
icon: magnifyingglass       # SF Symbol name
access: read-only           # Display label in picker
allowedTools:               # Optional
  - Read
  - Grep
  - Glob
---

You are an expert code reviewer. Review code against project guidelines
with high precision. Use confidence scoring (0-100), only report issues
with confidence >= 80. Categorize as Critical or Important. Provide
file:line references and concrete fix suggestions.

Focus on:
- Logic errors and edge cases
- Security vulnerabilities (OWASP Top 10)
- Performance bottlenecks
- Convention violations
```

## MVP Presets (6)

| Preset | Command | Model | Access | Icon |
|--------|---------|-------|--------|------|
| Pair Programmer | claude | sonnet | full | star |
| Architect | claude | opus | read-only | building.2 |
| Code Reviewer | claude | sonnet | read-only | magnifyingglass |
| Test Writer | claude | sonnet | scoped write | flask |
| Debugger | claude | opus | read + run | ant |
| Orchestrator | claude | opus | delegate | scope |

## Picker Layout

```
┌──────────────────────────┐
│  PRESETS                 │
│  ⭐ Pair Programmer       │
│     Full coding partner  │
│                          │
│  🏗  Architect            │
│     Plans, no code       │
│                          │
│  🔍 Code Reviewer        │
│     Read-only review     │
│                          │
│  🧪 Test Writer          │
│     Generates tests      │
│                          │
│  🐛 Debugger             │
│     Traces bugs          │
│                          │
│  🎯 Orchestrator         │
│     Delegates work       │
│──────────────────────────│
│  YOUR TEMPLATES          │
│  ⚙  My Custom Agent      │
│──────────────────────────│
│  + New Template          │
└──────────────────────────┘
```

Clicking a preset shows a preview card:
```
┌──────────────────────────────┐
│  🔍 Code Reviewer            │
│                              │
│  Model: sonnet               │
│  Access: read-only           │
│  Reviews code for bugs,      │
│  security issues, and        │
│  guideline violations.       │
│                              │
│  [ ] Don't show previews     │
│                              │
│  [Cancel]    [Launch]        │
└──────────────────────────────┘
```

## Preset Discovery Flow

```
First launch:
  App bundles 6 .md files in Resources/Presets/
       │
       v
  ~/.ghostties/presets/ doesn't exist
       │
       v
  Create directory, copy bundled presets
       │
       v
  App scans folder → 6 presets appear in picker

Adding community preset:
  User downloads rails-specialist.md
       │
       v
  Drops in ~/.ghostties/presets/
       │
       v
  Next app launch → scans folder → 7 presets

Editing a preset:
  Right-click → "Edit in Editor" → opens .md in default editor
  OR right-click → "Edit" → opens in-app config form
```

## Relationship to AgentTemplate Model

Presets are loaded into `AgentTemplate` objects at runtime:
- Parse YAML frontmatter → populate `name`, `kind`, `command`, `agent` (AgentConfig)
- Parse markdown body → becomes `agent.systemPromptFile` content (or inline prompt)
- Built-in presets: `isDefault: true`, deterministic UUIDs
- Community presets: `isDefault: false`, UUID generated from filename hash (stable across launches)
- Custom templates from workspace.json: loaded separately, shown in "YOUR TEMPLATES" section

## Open Questions

1. **Preset updates** — when the app updates and ships new preset versions, should it overwrite user-edited presets? Probably not. Maybe add a "Reset to default" option per preset.
2. **Inline prompt vs file reference** — should `buildCommand()` read the prompt from the `.md` body, or should presets reference external prompt files? Body is simpler (one file), external ref is more flexible (share prompts across presets).
3. **Preset validation** — what happens if a preset file has invalid YAML or missing required fields? Skip with warning? Show error in picker?
4. **Icon rendering** — SF Symbols work great on macOS. Should the frontmatter support custom icon paths for community presets that want distinctive visuals?

---

*Next: Run `/workflows:plan` when ready to implement.*
