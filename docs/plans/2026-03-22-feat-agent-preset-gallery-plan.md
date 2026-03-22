# Agent Preset Gallery — Implementation Plan

**Date:** 2026-03-22
**Feature:** Agent Preset Gallery with file-based presets
**Branch:** feat/agent-preset-gallery

## Overview

Replace the raw agent config form with a curated preset picker. Presets are `.md` files with YAML frontmatter stored in `~/.ghostties/presets/`. Six MVP presets are bundled and seeded on first launch.

## Deliverables

### 1. PresetLoader.swift (new file)
- `PresetLoader` struct with static methods
- `seedIfNeeded()` — creates `~/.ghostties/presets/` and writes bundled presets on first launch
- `loadPresets()` — scans directory for `.md` files, parses each into `AgentTemplate`
- `parsePreset(at:)` — splits on `---` boundaries, extracts YAML frontmatter key-value pairs, body becomes inline system prompt
- Manual YAML parsing (no external dependency) — handles both inline `[a, b]` and multi-line list syntax for `allowedTools`
- Stable UUIDs generated from filename hash (deterministic across launches)
- Bundled preset content embedded as Swift string constants (avoids pbxproj modification)

### 2. AgentTemplate.swift (modifications)
- Add `description` property to `AgentTemplate` for preset descriptions
- Add `icon` property for SF Symbol name
- Add `systemPrompt` property for inline system prompts (alternative to `systemPromptFile`)
- Update `buildCommand()` to support inline `systemPrompt` (uses `--append-system-prompt`)
- Add `isPreset` computed property to distinguish file-based presets from hardcoded defaults

### 3. TemplatePickerView.swift (modifications)
- Section headers: "PRESETS" and "YOUR TEMPLATES"
- Richer rows: SF Symbol icon + name + description subtitle
- Preview card on click with model, access level, description preview
- "Don't show previews" checkbox stored in UserDefaults (`ghostties.skipPresetPreview`)
- Launch button in preview card
- Presets use icon from frontmatter, custom templates use existing icon logic

### 4. WorkspaceStore.swift (modifications)
- On init: call `PresetLoader.seedIfNeeded()` then `PresetLoader.loadPresets()`
- Merge preset templates with built-in defaults and custom templates
- Preset templates: `isDefault: true`, `isGlobal: true`
- Template ordering: presets first, then built-in defaults (Shell, Claude Code), then custom

### 5. Six MVP Preset .md Files (embedded in PresetLoader)
Written to `~/.ghostties/presets/` on first launch:

| File | Preset | Model | Access |
|------|--------|-------|--------|
| pair-programmer.md | Pair Programmer | sonnet | full |
| architect.md | Architect | opus | read-only |
| code-reviewer.md | Code Reviewer | sonnet | read-only |
| test-writer.md | Test Writer | sonnet | scoped write |
| debugger.md | Debugger | opus | read + run |
| orchestrator.md | Orchestrator | opus | delegate |

## File Ownership

**May modify:**
- `AgentTemplate.swift` — add description, icon, systemPrompt fields
- `TemplatePickerView.swift` — update picker UI with sections and preview
- `WorkspaceStore.swift` — integrate preset loading on init

**New files:**
- `PresetLoader.swift` — preset parsing and seeding logic

**Do NOT modify:**
- `AgentSession.swift`, `SessionDetailView.swift`, `SessionCoordinator.swift`
- `WorkspaceLayout.swift`, `ProjectDisclosureRow.swift`

## Key Design Decisions

1. **Embed preset content in Swift** rather than Xcode Resources — avoids pbxproj changes, simpler build
2. **Inline system prompt** via `--append-system-prompt` flag — presets carry their prompt in the `.md` body
3. **Manual YAML parsing** — frontmatter is simple key:value, no need for a YAML library
4. **Stable UUIDs from filename** — `UUID(name: filename, namespace: .url)` style deterministic generation
5. **Preview card gating** — UserDefaults checkbox, power users skip it after first use
