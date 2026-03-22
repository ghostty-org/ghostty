---
title: Agent Preset Gallery — File-Based Presets
date: 2026-03-22
status: implemented
category: architecture
tags: [presets, templates, agent-config, yaml-parsing]
---

## Problem

The template picker required users to manually configure 6+ fields (model, system prompt file, permission mode, effort, allowed tools, additional flags) to set up an agent session. This was too complex for the primary launch flow — most users want to pick "Code Reviewer" and start working, not wire up CLI flags.

The hardcoded built-in templates (Shell, Claude Code, Orchestrator) covered only 3 use cases and couldn't be extended without app updates.

## Solution

File-based agent presets stored in `~/.ghostties/presets/` as `.md` files with YAML frontmatter. The app seeds 6 MVP presets on first launch and loads any `.md` files in the directory on every launch.

### Architecture

```
~/.ghostties/presets/
  pair-programmer.md     # Full coding partner (sonnet, full access)
  architect.md           # Plans, never writes code (opus, read-only)
  code-reviewer.md       # Confidence-scored review (sonnet, read-only)
  test-writer.md         # Generates tests (sonnet, scoped write)
  debugger.md            # Traces bugs (opus, read + run)
  orchestrator.md        # Delegates to subagents (opus, delegate)
```

### File Format

Each preset is a single `.md` file with YAML frontmatter (config) and markdown body (system prompt):

```markdown
---
name: Code Reviewer
description: Reviews code for bugs and security issues
command: claude
model: sonnet
permissionMode: plan
effort: high
icon: magnifyingglass
access: read-only
allowedTools:
  - Read
  - Grep
  - Glob
---

You are an expert code reviewer...
```

### Key Components

1. **PresetLoader.swift** — Parses `.md` files with manual YAML frontmatter extraction (no external dependency). Generates deterministic UUIDs from filenames via SHA-256 so IDs persist across launches.

2. **AgentTemplate.swift** — Extended with `templateDescription`, `icon`, `accessLabel` properties and `systemPrompt` field in `AgentConfig` for inline prompts (vs. file references).

3. **TemplatePickerView.swift** — Enhanced with section headers (PRESETS / YOUR TEMPLATES), richer rows (SF Symbol + name + description), and a preview card with model/access/description shown on click (gated by `ghostties.skipPresetPreview` UserDefaults key).

4. **WorkspaceStore.swift** — Seeds presets on first launch, loads them on every launch, merges with built-in defaults and custom templates.

5. **WorkspacePersistence.swift** — Validation includes preset template IDs so sessions referencing presets survive across app restarts.

### Data Flow

```
First Launch:
  WorkspaceStore.init()
    -> PresetLoader.seedIfNeeded()
       -> Creates ~/.ghostties/presets/
       -> Writes 6 bundled .md files from embedded Swift strings
    -> PresetLoader.loadPresets()
       -> Scans directory for .md files
       -> Parses frontmatter + body
       -> Returns [AgentTemplate] with isDefault=true, deterministic UUIDs
    -> Merges: presets + defaults + custom templates

Subsequent Launches:
  WorkspaceStore.init()
    -> PresetLoader.seedIfNeeded() (no-op, directory exists)
    -> PresetLoader.loadPresets() (scans, parses, returns templates)
    -> Merges: presets + defaults + custom templates

Community Preset:
  User drops rails-specialist.md in ~/.ghostties/presets/
    -> Next launch: loadPresets() picks it up automatically
```

### Preset Embedding Strategy

Preset content is embedded as Swift string constants in `PresetLoader.swift` rather than Xcode bundle resources. This avoids modifying the Xcode project's `project.pbxproj` file and keeps the build simpler. The same content is also stored as standalone `.md` files in `macos/Resources/Presets/` for reference.

### UUID Stability

Presets use deterministic UUIDs generated from `SHA256("com.ghostties.presets:<filename>")` with UUID v5 version/variant bits. This ensures:
- The same preset file always produces the same UUID
- Sessions created from presets can find their template after app restart
- Community presets get stable IDs without coordination

## Prevention

- New preset fields should be added to both `parseFrontmatter()` and the `AgentTemplate` initializer
- The `WorkspacePersistence.validate()` method must include preset IDs in the known template set
- Preset templates are `isDefault: true` so they can't be deleted or edited through the standard UI

## Verification

1. Delete `~/.ghostties/presets/` and launch the app — 6 preset files should be created
2. Verify all 6 presets appear in the template picker under "PRESETS" section
3. Click a preset — preview card should show with model, access, and description
4. Check "Don't show previews" — subsequent clicks should launch directly
5. Create a session from a preset, quit, relaunch — session should still reference the preset template
6. Drop a custom `.md` file in `~/.ghostties/presets/` — it should appear on next launch

### Files Changed

- `macos/Sources/Features/Ghostties/PresetLoader.swift` (new)
- `macos/Sources/Features/Ghostties/Models/AgentTemplate.swift` (modified)
- `macos/Sources/Features/Ghostties/TemplatePickerView.swift` (modified)
- `macos/Sources/Features/Ghostties/WorkspaceStore.swift` (modified)
- `macos/Sources/Features/Ghostties/WorkspacePersistence.swift` (modified)
- `macos/Resources/Presets/*.md` (6 new reference files)
