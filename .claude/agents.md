# Global Claude Code Instructions

These rules apply to ALL projects. Project-level CLAUDE.md files supplement (and may override) these.

## Child-Agent and Delegation Policy

- Use child agents as the default for high-context, multi-file, or parallelizable work.
- Delegate exploration, audits, and long-running analysis to subagents before the parent agent edits.
- Keep parent-agent direct edits narrowly scoped to synthesis, integration, and finalization.

---

# Context Management Strategy

## The Manager Pattern

**CRITICAL**: Operate as a strategic manager, not a worker. Delegate to subagents.

### Keep in Main Context
- User intent and requirements
- Strategic decisions and trade-offs
- Summaries of completed work
- Critical architectural knowledge

### Delegate to Subagents
- File exploration (>3 files)
- Pattern searches across codebase
- Multi-file implementations
- Long command sequences
- Test execution

## Delegation Quick Reference

| Need | Delegate To | Example Prompt |
|------|-------------|----------------|
| Find code patterns | `Explore` | "Find all error handling patterns" |
| Design approach | `Plan` | "Design auth implementation strategy" |
| Run commands | `Bash` | "Run test suite and report failures" |
| Multi-step implementation | `general-purpose` | "Implement and test feature X" |
| Quick isolated fix | DO NOT delegate | Handle directly |

### Parallel vs Sequential

**Parallel** (no dependencies): Launch 2-3 explore agents simultaneously for independent searches.

**Sequential** (dependent): explore -> receive summary -> plan based on findings -> implement approved plan.

## Subagent Swarm (async orchestration)

**If you have subagent/swarm capabilities:** Use them as an **async swarm**.

- **Call task agents async.** Fire tasks so that as each completes, you are reawoken to re-evaluate, spawn more agents, or do more work yourself.
- **Run a swarm.** Up to **50 concurrent task agents**. Scale up when work is well decomposed and independent.
- **Work in between.** While tasks run async, use your own context for planning, monitoring, or other work.
- **Reawaken on completion.** When idle, you will be reawoken as each agent completes. Use that to spawn more agents, do follow-up work, or consolidate results.

## Anti-Patterns

| Bad | Good |
|-----|------|
| Reading 10 files to "understand" | Delegate exploration, get summary |
| Editing files for multi-file changes | Delegate to `general-purpose` |
| Sequential explorations one-by-one | Batch parallel explores |
| Asking subagent for "all results" | Ask for "summary" or "key files" |
| Committing all dirty worktree changes in one commit | Split into targeted, provenance-based commits to preserve local auditability in concurrent-agent environments |

## Dirty-Tree Commit Discipline (Required)

In dirty worktrees, separate commits by provenance:

- `MODE 1`: user-requested implementation changes.
- `MODE 2`: pre-existing work and WIP from other actors.
- `MODE 3`: generated or temporary artifacts (benchmark runs, telemetry snapshots, repair notes).

Never mix modes in one commit. Prefer multiple small commits over one omnibus commit.

## Context Budget Rule

If task adds >2000 tokens of file content/output, **delegate it**.

---

# Optionality and Failure Behavior

**Require** dependencies where they belong; **require** clear, loud failures -- no silent or "graceful" degradation.

- **Force requirement where it belongs.** Do not make dependencies "optional" just to avoid failure. If a service or config is required for correctness, treat it as required and fail when missing.
- **Fail clearly, not silently.** Use explicit failures -- not reduced functionality, logging-only warnings, or hidden errors. Users must see *what* failed and that the process did not silently degrade.
- **Graceful in other ways.** Retries with visible feedback (e.g. "Waiting for X... (2/6)"); error messages that list each failing item; actionable messages and non-obscure stack traces. Do *not* use optionality or silent fallbacks as a substitute for fixing the real dependency.

---

# Durable Infra Placement (mandatory default)

**Rule**: Agent-built infrastructure, tooling, scrapers, runners, data pipelines, schema migrations, and any other code/script/artifact that does not need to be ephemeral MUST be placed in a stable, durable, attributable path. It is NEVER the default to write working files under `/tmp` (or `/private/tmp` on macOS) — those are wiped by `/etc/periodic/{daily,weekly}/clean-tmps` and on every reboot, and you will lose the work on the next session boundary.

**Default placement hierarchy** (first viable option wins):

1. **Phenotype infra / skills / handbook project** (`KooshaPari/phenotype-infra`, `phenotype-skills`, `phenotype-handbook`) — for ops/governance/skill-shaped tools.
2. **Phenotype working monorepo** under `KooshaPari/phenotype-org-governance/scripts/...` or a sibling `phenotype-*` repo — version-controlled, branch-tracked, code-reviewable.
3. **System's own home** (e.g. `~/.forge/...` for forge-state-derived artifacts) — colocate with the data.
4. **Stable user dir** (e.g. `~/forge_resume/`, `~/.local/share/<tool>/`) — outside any cleanup-target path.
5. **Last resort**: `/tmp/<task>/` only when the user has explicitly approved ephemeral scratch AND the job does not need to survive the next periodic run.

**Required artifacts when shipping infra** (all three — code alone is incomplete):

1. The code in its proper repo (placement hierarchy above), committed to a topic branch.
2. A governance policy explaining the rule, the failure mode, and how to operate the tool. For Phenotype work, that goes in `phenotype-org-governance/governance/<topic>-YYYY-MM-DD.md`.
3. A memory rule (e.g. `~/.claude/memory/feedback_infra_durability.md`) so future sessions default to the right path.

**Wrap, don't hand-roll**: When the system has a CLI for the operation, use that CLI via a thin wrapper. Direct DB/config/state access is a last-resort fallback, not the default.

**Guardrail**: Any tool that writes to disk must hard-reject `/tmp` and `/private/tmp` as a destination for its output dir. See `phenotype-org-governance/scripts/forge-resume/src/forge_resume/runner.py:guard_against_tmp` for the canonical implementation.

**Smoke tests live with the code**: Every shipped tool must include a runnable smoke test that exercises the guardrails without requiring external state. The test must pass in CI and from a fresh clone.

**Reference**: `KooshaPari/phenotype-org-governance/governance/agent-infra-durability-2026-06-09.md` (the original incident response that established this rule).

---

# Phenotype Tooling Mandate (Global — Strict)

**You MUST use the Phenotype-developed tooling ecosystem for all non-trivial work across every repository.** Manual repetition, hand-rolled scripts, one-off processes, and ad-hoc coordination are prohibited. These tools exist specifically so that human operators and agents do not repeat themselves across sessions or workstreams.

## Core Required Tools

| Tool | Repository | Purpose | When to Use |
|------|------------|---------|-------------|
| **AgilePlus** | `AgilePlus/` | Spec-driven work tracking, spec harmonization, work packages | BEFORE any non-trivial work — intake specs, track work, link PRs |
| **phenodag** | `phenodag-tool/` | Multi-agent multi-project DAG coordination, atomic claims, fuzzy-duplicate detection | BEFORE picking work — check DAG status, claim repo/branch, avoid collisions |
| **agent-orchestrator** | `FocalPoint/tooling/agent-orchestrator/` | Lane-based agent dispatch with non-overlapping scopes | When dispatching parallel agents across lanes |
| **quality-gate** | `FocalPoint/tooling/quality-gate/` | Unified pre-review quality gate (build, test, lint, FR coverage, doc-link check) | BEFORE requesting review — mandatory gate |
| **fr-coverage** | `FocalPoint/tooling/fr-coverage/` | Feature-requirement coverage tracker | BEFORE claiming work complete — verify FR traceability |
| **target-pruner** | `FocalPoint/tooling/target-pruner/` | Disk reclaim by pruning stale cargo targets | Weekly or when disk < 30 GB |
| **disk-check** | `FocalPoint/tooling/disk-check/` | Pre-dispatch disk space gate | BEFORE agent dispatch — abort if < 10 GB free |
| **release-cut** | `FocalPoint/tooling/release-cut/` | End-to-end release orchestration (TestFlight, tags, CHANGELOG) | When cutting a release |

## Global Prohibitions (Do Not Repeat Yourself)

- **Do NOT** hand-write work plans, task lists, or project plans in chat, Markdown notes, or temporary files when `agileplus` or `phenodag` exist for this purpose. The tool is the canonical record.
- **Do NOT** manually bump versions, create git tags, or cut releases by hand when `release-cut` exists. Hand-rolled releases are error-prone and untraceable.
- **Do NOT** run individual `cargo test`, `cargo clippy`, `cargo fmt` checks separately when `quality-gate` unifies them. Running checks individually wastes time and skips FR coverage and doc-link validation.
- **Do NOT** dispatch multiple agents in parallel without using `agent-orchestrator` lane scoping or `phenodag` atomic claims. Unscoped dispatch causes file collisions, duplicate work, and merge conflicts.
- **Do NOT** write one-off shell scripts for disk cleanup, coverage reports, link checking, or release chores when the tooling above already covers it. If a gap exists, extend the tool and submit a PR to the tooling repo — do not bypass.
- **Do NOT** track FR coverage, test matrices, or requirement traceability manually or in spreadsheets when `fr-coverage` generates the honest matrix programmatically.

## Session-Start Checklist

At the start of every session involving non-trivial work:

1. Check `phenodag status` for fleet-wide work context.
2. If picking work, use `phenodag pick --agent <id>` and `phenodag claim`.
3. Verify disk space with `disk-check` before any heavy dispatch.
4. Confirm the work is tracked in AgilePlus (spec or issue ID exists).

## Tooling Principle

**Wrap, extend, or fix — never bypass.** If a tool is missing a feature, the correct action is to extend the tool (or file an issue) and then use it. The wrong action is to hand-roll a workaround that only you know about, which forces the next agent to rediscover the same gap.

---

# Planner Agents: No Code in Docs or Plans

**Planner agents** (PM, Analyst, Architect, etc.) must **never write code** in documentation and plans. Their job is to equip implementers. Write specs, acceptance criteria, architecture decisions, and clear handoffs. Prefer references, file paths, or brief pseudocode when necessary.

---

# Phased WBS and Plans with DAGs

When generating **plans**, **roadmaps**, or **implementation breakdowns**:

- **Phases:** Structure into ordered phases (Discovery, Design, Build, Test/Validate, Deploy/Handoff). Each phase contains deliverable-oriented work packages.
- **DAG:** Tasks have explicit **predecessors**; no cycles. List dependencies so execution order is unambiguous.
- **Output:** Phased WBS (hierarchy by phase) plus dependency list or DAG. Optionally: **Phase | Task ID | Description | Depends On** table.

---

# Timescales: Agent-Led, Aggressive Estimates

**Assume an agent-driven environment.** No user or external human intervention beyond prompts.

- **Forbidden in plans:** "Schedule external audit", "Stakeholder Presentation", "Team Kickoff", "Human checkpoint", "Get approval from X", or any step assigning work to a human.
- **Effort in agent terms only:** Agent actions (tool calls, subagent batches). Aggressive wall-clock -- err on the lower bound.
- **Rough mapping:**
  - Trivial change: 1-2 tool calls, <1 min
  - Small feature: 3-6 tool calls, 1-3 min
  - Cross-stack feature: 8-15 tool calls or 2-3 parallel subagents, 3-8 min
  - Major refactor: 15-30 tool calls or 3-5 parallel subagents, 8-20 min
  - Multi-phase initiative: decompose into agent batches; each batch 10-20 min max
- **Forbidden phrasing:** "This will take 2 days", "Schedule a review", "Assign owners", "Present to stakeholders". Use: "N tool calls", "N parallel subagents", "~M min wall clock".

---

# Documentation Organization

**CRITICAL**: All project documentation follows a strict organization structure.

### Root-Level Files (Keep in Root)
- `README.md` -- Main project documentation
- `CHANGELOG.md` -- Project changelog
- `AGENTS.md` -- AI agent instructions
- `CLAUDE.md` -- Claude-specific instructions
- `00_START_HERE.md` -- Getting started guide (if applicable)
- Spec docs: `PRD.md`, `ADR.md`, `FUNCTIONAL_REQUIREMENTS.md`, `PLAN.md`, `USER_JOURNEYS.md`

### Documentation Structure

All other `.md` files must be organized in `docs/` subdirectories:

```
docs/
  guides/              # Implementation guides and how-tos
    quick-start/       # Quick start guides
  reports/             # Completion reports, summaries, status reports
  research/            # Research summaries, indexes, analysis
  reference/           # Quick references, API references, trackers
  checklists/          # Implementation checklists, verification lists
  changes/             # Per-change proposal/design/task docs
    archive/           # Completed change docs
```

### File Organization Rules

1. **Quick Starts** -> `docs/guides/quick-start/` (`*QUICK_START*.md`, `*QUICKSTART*.md`)
2. **Quick References** -> `docs/reference/` (`*QUICK_REFERENCE*.md`, `*QUICK_REF*.md`)
3. **Implementation Guides** -> `docs/guides/` (`*GUIDE*.md`)
4. **Completion Reports** -> `docs/reports/` (`*COMPLETE*.md`, `*SUMMARY*.md`, `*REPORT*.md`, `PHASE_*.md`, `*TEST*.md`)
5. **Research Files** -> `docs/research/` (`*RESEARCH*.md`, `*INDEX*.md`)
6. **Checklists** -> `docs/checklists/` (`*CHECKLIST*.md`)
7. **Trackers** -> `docs/reference/` (`*TRACKER*.md`, `*STATUS*.md`, `*MAP*.md`)

### AI Agent Instructions

- **NEVER** create `.md` files in the project root (except allowed root-level files above)
- **ALWAYS** place new documentation in the appropriate `docs/` subdirectory
- **VERIFY** file location before creating documentation
- **MOVE** misplaced files to correct subdirectories if found

---

# Opinionated Quality Enforcement

- Enforce opinionated styling to a strict degree.
- Programmatic enforcement must guard against bad quality and antipatterns.
- Rather than disables or ignores, fix code properly.
- Use project linters, formatters, and type checkers. Never bypass them.

---

# Specification Documentation System

## Required Project Documentation

Every non-trivial project SHOULD maintain these spec docs (root level):

| File | Purpose |
|------|---------|
| `PRD.md` | Product Requirements Document: epics, user stories, acceptance criteria |
| `ADR.md` | Architecture Decision Records: decisions with context, rationale, alternatives |
| `FUNCTIONAL_REQUIREMENTS.md` | Functional Requirements: SHALL statements, traces to PRD |
| `PLAN.md` | Phased WBS with DAG dependencies |
| `USER_JOURNEYS.md` | User journeys with ASCII flow diagrams |

## Required Tracker Documentation

Projects with spec docs SHOULD maintain trackers in `docs/reference/`:

| File | Purpose |
|------|---------|
| `PRD_TRACKER.md` | Epic/story status, progress %, code locations |
| `ADR_STATUS.md` | ADR implementation status, code artifacts |
| `FR_TRACKER.md` | FR implementation status, test coverage |
| `PLAN_STATUS.md` | Phase/task completion status |
| `JOURNEY_VALIDATION.md` | Journey validation status, gaps |
| `CODE_ENTITY_MAP.md` | Forward and reverse mapping: code entities <-> requirements |

## Auto-Detection Behavior

**On session start:**
- If spec docs are missing, acknowledge it and offer to generate them
- Greenfield project: offer to scaffold all spec docs from project analysis
- Brownfield project: offer to analyze existing codebase and generate docs mapping to what exists
- Do NOT auto-generate without user confirmation -- offer, don't force

## VitePress Docsite Setup (Greenfield/Brownfield)

**MUST include docsite setup in any new project initialization:**

For greenfield projects:
- Copy VitePress template from `thegent/templates/vitepress-full/` to new project
- Run `pnpm install && pnpm docs:build` to verify setup
- Document in project CLAUDE.md

For brownfield projects (existing projects without docsites):
- Check if `docs-dist/index.html` exists -- if not, propose adding docsite
- Use same template from `thegent/templates/vitepress-full/`
- Run `pnpm install && pnpm docs:build` to verify

**Quick setup (30 seconds):**
```bash
cp -r thegent/templates/vitepress-full myproject/docs/.vitepress
# Rename .template files, edit config.ts placeholders
cd myproject && pnpm install && pnpm docs:build
open docs-dist/index.html
```

**Why:** All projects should have statically viewable docs that can be opened via `file://` in browser. This enables:
- Team documentation browsing without deployment
- Cross-project links between portfolio docs (`~project:/path`)
- Versioned docs via git branches

---

## Project Setup Checklist (Greenfield/Brownfield)

**MUST initialize these for ALL new projects:**

### 1. Docsite (VitePress)
- [ ] Copy `thegent/templates/vitepress-full/` to `docs/.vitepress/`
- [ ] Run `pnpm install && pnpm docs:build`
- [ ] Verify `docs-dist/index.html` opens in browser
- [ ] Add to CLAUDE.md

### 2. Taskfile (NOT Make)
- [ ] Create `Taskfile.yml` with standard tasks:
  - `lint` - Run all linters
  - `test` - Run tests
  - `quality` - Run quality gates
  - `docs:build` - Build docsite
- [ ] Use Taskfile includes from `thegent/templates/` if available

### 3. Linters (Language-Specific)
| Stack | Linter | Formatter | Config Template |
|-------|--------|-----------|---------------|
| Python | ruff | ruff format | `thegent/templates/python/pyproject.template.toml` |
| TypeScript | oxlint | oxfmt/prettier | `thegent/templates/typescript/oxlint.config.json` |
| Go | golangci-lint | gofumpt | `thegent/templates/go/.golangci.yml` |
| Rust | clippy | rustfmt | `thegent/templates/rust/clippy.toml` |
| Ruby | rubocop | rubocop | `thegent/templates/ruby/.rubocop.yml` |
| Java | checkstyle + spotbugs | google-java-format | `thegent/templates/java/checkstyle.xml` |
| C/C++ | clang-tidy | clang-format | `thegent/templates/cpp/.clang-tidy` |
| PHP | phpstan + psalm | PHP CS Fixer | `thegent/templates/php/phpstan.neon` |
| Bash | shellcheck | shfmt | `thegent/templates/bash/.shellcheckrc` |

### 4. Project Scaffolding Tools (CLI/App Frameworks)
| Stack | CLI Framework | Web Framework | Config |
|-------|--------------|---------------|--------|
| Python | typer | FastAPI/starlette | `pyproject.toml` |
| TypeScript | commander.js | Express/Fastify/Hono | `package.json` |
| Rust | clap | axum/actix | `Cargo.toml` |
| Go | cobra/urfave/cli | gin/echo/fiber | `go.mod` |
| Ruby | thor | RailsHanami | `Gemfile` |
| Java | picocli | Spring Boot | `pom.xml`/`build.gradle` |
| C# | commandline | ASP.NET Core | `.csproj` |

### 5. Pre-commit Hooks
- [ ] Add `.pre-commit-config.yaml`
- [ ] Include: ruff-check, ruff-format, gitleaks, trailing-whitespace
- [ ] Run `pre-commit install`

### 5. Quality Gates
- [ ] Create `hooks/quality-gate.sh` with:
  - Lint check (0 errors)
  - Test check (all pass)
  - Coverage >= 80%
  - Security scan (0 high/critical)
- [ ] Add to Stop hook or pre-commit

### 6. Test Infrastructure (Per Language)
| Stack | Test Runner | Coverage | Test Config |
|-------|-------------|----------|-------------|
| Python | pytest + pytest-xdist | coverage.py | `pyproject.toml` [tool.pytest] |
| TypeScript | vitest | v8 | `vitest.config.ts` |
| Rust | cargo test | tarpaulin/grcov | `Cargo.toml` |
| Go | go test | gocov/coverprofile | `_test.go` files |
| Ruby | rspec | simplecov | `.rspec` |
| Java | JUnit 5 | JaCoCo | `pom.xml`/`build.gradle` |
| C++ | catch2/doctest | lcov | `CMakeLists.txt` |
| PHP | phpunit | phpunit-coverage | `phpunit.xml` |
| Bash | bats-core | - | `*.bats` files |

### 7. Full Traceability Setup
- [ ] Create `FUNCTIONAL_REQUIREMENTS.md` with FR-{CAT}-NNN IDs
- [ ] Create `docs/reference/FR_TRACKER.md` to track FR implementation status
- [ ] Create `docs/reference/CODE_ENTITY_MAP.md` mapping code <-> requirements
- [ ] Add FR ID tags to all test functions:
  - Python: `@pytest.mark.requirement("FR-XXX-NNN")`
  - TypeScript: `describe("FR-XXX-NNN: description", () => {...})`
  - Rust: `#[test] fn test_FR_XXX_NNN() {...}`
  - Add docstring: `Traces to: FR-XXX-NNN`
- [ ] Verify: `grep -r "FR-" tests/` shows all FRs have tests
- [ ] Run: `task quality` to verify spec verification

### 8. CLAUDE.md Project Instructions
Create project-specific `CLAUDE.md` with:
- Project name, description, stack
- Library preferences table
- Domain-specific patterns
- Where to add new functionality

---

## Quick Project Initialization Commands

```bash
# NEW PROJECT - Full setup:
cd myproject
mkdir -p docs hooks

# 1. Docsite
cp -r thegent/templates/vitepress-full/* docs/.vitepress/
mv docs/package.json.template docs/package.json

# 2. Install deps
pnpm install   # docs
# OR for Python:
uv sync

# 3. Build & verify
pnpm docs:build
open docs-dist/index.html

# 4. Pre-commit
pip install pre-commit
pre-commit install

# 5. Verify quality
task lint
task test
task quality
```

**During work:**
- When making significant code changes (new modules, features, architecture changes), note which spec docs would need updating
- When completing a task, mentally check if trackers should be updated
- If you add new functions/modules, note they should be added to CODE_ENTITY_MAP.md

**On session end:**
- If there are unmapped code changes, acknowledge and update trackers if appropriate
- Treat session end as a documentation checkpoint

## Change Documentation (per-change, for significant changes)

For significant changes (new features, major refactors, architecture changes):
- Create `docs/changes/{change-name}/` with:
  - `proposal.md` -- What and why
  - `design.md` -- Technical approach, affected components
  - `tasks.md` -- Implementation checklist
- Archive completed changes to `docs/changes/archive/`
- NOT required for small fixes, typos, or minor adjustments

## Doc Format Standards

- **ID systems:** E{n}.{m}.{k} for epics/stories, FR-{CAT}-{NNN} for requirements, ADR-{NNN} for decisions, P{n}.{m} for plan tasks, UJ-{N} for journeys
- **Cross-reference** between docs (FR traces to PRD epics, code maps to FRs and ADRs)
- **ASCII diagrams** for flows and architecture (not images)
- **Tables** for tracking, matrices, and summaries
- Templates are available at `~/.claude/templates/` for consistent formatting (if present)

### Global Reference Docs for Code Generation

**Use these references when generating code:**

| Domain | Reference Path |
|--------|---------------|
| UI Design | `docs/reference/UI_DESIGN_PRINCIPLES_REFERENCE.md` |
| Architecture | `docs/reference/SOFTWARE_ARCHITECTURE_REFERENCE.md` |
| Design Patterns | `docs/reference/SOFTWARE_DESIGN_PATTERNS_REFERENCE.md` |
| Performance | `docs/reference/performance/PERFORMANCE_OPTIMIZATION.md` |
| Testing | `docs/reference/testing/TESTING_STRATEGIES.md` |
| Security | `docs/reference/security/SECURITY_BEST_PRACTICES.md` |
| **Full Index** | `docs/reference/INDEX.md` |

For thegent-specific agents, see `docs/reference/INDEX.md` for agent ↔ reference mappings.

## Session State Continuity

- The hooks system (if configured) tracks file changes per session via `.claude/session-changes.log`
- On stop, changes are reconciled against trackers
- This provides session-to-session continuity for documentation maintenance

---

# Generalized Dev Environment Pattern

## Service Management

- **The user runs a dev TUI/dashboard in their own terminal.** This is their primary observation interface. **Never** start, stop, or restart the entire dev stack (`make dev`, `make dev-tui`, `make dev-down`) — only the user does that.
- **Use CLI introspection and per-service manipulation commands** to interact with the running stack without disrupting the user's TUI session. Process orchestrators (e.g. `process-compose`) expose a CLI/API that operates on the same running instance.
- **Assume services use hot reload** (file watchers, HMR, etc.). Save files and let watchers pick up changes — do not restart services just because you edited files.
- **When a service needs restarting** (e.g. config change, dependency update, crash), restart only that specific service via CLI, not the whole stack.
- **Read logs via CLI or log files** — never attach to or interfere with the user's TUI terminal.
- Before starting dev yourself, verify processes are not already up (check health endpoints, status commands, or log files) to avoid duplicate stacks.

## Package Manager

**Use the project's preferred package manager.** Detect from lockfiles:
- `bun.lockb` or `bun.lock` -> use `bun`
- `pnpm-lock.yaml` -> use `pnpm`
- `yarn.lock` -> use `yarn`
- `package-lock.json` -> use `npm`
- If unclear, check `package.json` `packageManager` field or project CLAUDE.md

## Native Over Docker

**Prefer native services over Docker** for local development. Run databases, caches, reverse proxies as native processes. Use Docker only when native install is not feasible or explicitly required.

## OSS and Free First

**Strictly prefer local, OSS, and free tools** over paid SaaS. If a feature requires external services, prefer OSS/self-hosted or free options first. Document paid options only as labeled fallback.

## Multi-Actor Coordination (generalized)

When multiple agents or actors share a dev environment:
- **Debounce commands:** Use project-provided wrappers (Makefile targets, scripts) that prevent concurrent execution conflicts.
- **Shared service management:** Use the project's process orchestrator as source of truth for service health.
- **Hold-if-running logic:** Prefer wrappers that allow multiple actors to share processes without force-killing.
- **Consolidated targets:** Prefer consolidated build/lint/test targets over a multitude of specialized ones.

---

# Plugin Ecosystem Awareness

Documentation and workflow frameworks (BMAD, OpenSpec, GSD, etc.) may be available as plugins or slash commands.

- Check available slash commands (`/`) for documentation workflows
- These complement the auto-detection system -- invoke explicitly for deeper workflows
- Auto-detection hooks handle common cases; plugins handle advanced scenarios
- If BMAD agents are installed (`.claude/commands/bmad/`), they can be activated via slash commands for specialized agent personas
- Start a new conversation to switch agent personas

---

# QA Governance

## Test-First Mandate

- Write tests BEFORE implementation. Test file must exist before source file for new modules.
- For bug fixes, write a failing test that reproduces the bug first, then fix.
- Test naming: descriptive, includes the FR ID when applicable.

## Suppression Policy

- **Zero new suppressions** without inline justification comment.
- Acceptable format: `# noqa: E501 -- line is a long URL` (note the `--` reason separator).
- The `suppression-blocker.sh` hook will BLOCK any Write/Edit that introduces new suppressions.
- If a suppression is genuinely needed, include the specific rule code AND a reason.

## Spec Traceability

- All test functions MUST reference an FR ID via one of:
  - Tag: `# @trace FR-XXX-NNN` in test file or function
  - Marker: `@pytest.mark.requirement("FR-XXX-NNN")`
  - Docstring: `Traces to: FR-XXX-NNN`
  - Test name: `@test "FR-XXX-NNN: description"` (BATS)
- Orphaned FRs (no test) and orphaned tests (no FR) are reported by the quality gate.

## Quality Gate Awareness

- `quality-gate.sh` runs on every Stop event -- it reports lint, security, and traceability findings.
- **Proactively run linters** before finishing work to avoid surprises at the quality gate.
- The gate is advisory (does not block Stop) but findings should be addressed.

## Static Analysis Config

- When scaffolding a new project, copy relevant templates from `~/.claude/templates/quality/` for detected stacks.
- Available templates: ruff.toml, ty-config.toml, oxlintrc.json, tsconfig-strict.json, golangci.yml, clippy.toml, shellcheckrc, pre-commit-config.yaml, pytest-config.toml, coverage-config.toml.

## Test Pyramid Targets

- **Unit**: 70% (tolerance: +/-5%)
- **Integration**: 20% (tolerance: +/-5%)
- **E2E**: 10% (tolerance: +/-5%)
- Projects may override in `.qa-config.json` or `.claude/quality.json`.

## Hook Pipeline Summary (v3)

| Event | Hooks (execution order) |
|-------|------------------------|
| SessionStart | spec-preflight, qa-preflight |
| UserPromptSubmit | prompt-submit-guard |
| PreToolUse:Write | doc-location-guard, pre-write-validator, suppression-blocker |
| PreToolUse:Edit | pre-write-validator, suppression-blocker |
| PostToolUse:Edit\|Write | change-doc-tracker, post-edit-checker, async-test-runner |
| SubagentStart | subagent-quality-gate (start) |
| SubagentStop | subagent-quality-gate (stop) |
| TaskCompleted | task-completion-verifier |
| PreCompact | pre-compact-snapshot |
| Stop | quality-gate, stop-reconcile, spec-verifier, complexity-ratchet, security-pipeline, test-maturity |
| SessionEnd | session-cleanup |

## Test-First Development (TDD/BDD)

### TDD Mandate
- For NEW modules: test file MUST exist before implementation file
- For BUG FIXES: failing test MUST be written before the fix
- For REFACTORS: existing tests must pass before AND after

### BDD Requirements
- Feature files (*.feature / *.bdd) map to user stories in PRD
- Given/When/Then steps must be traceable to FRs
- BDD test names reference FR IDs: "Feature: FR-AUTH-001 User Login"

### Test Type Requirements (by project maturity)

| Test Type | New Project | Established | Critical System |
|-----------|-------------|-------------|-----------------|
| Unit | Required | Required | Required |
| Integration | Required | Required | Required |
| E2E | Optional | Required | Required |
| Property-based | Optional | Optional | Required |
| Contract | Optional | Required (if APIs) | Required |
| Mutation | Optional | Optional | Required |
| Security (SAST) | Required | Required | Required |
| Accessibility | Optional | Required (if UI) | Required |
| Performance | Optional | Optional | Required |
| Snapshot/Golden | Optional | Optional (if UI) | Required |

### Smart Contract Pattern (Spec Verification)
Specs (PRD/FR) -> Tests (must reference FR IDs) -> Checks (must be green) = Verified
- Every FR-XXX-NNN in FUNCTIONAL_REQUIREMENTS.md MUST have >=1 test referencing it
- Every test MUST reference >=1 FR-XXX-NNN (no orphan tests)
- All linters + type checkers + security scanners MUST pass (0 errors)
- Coverage MUST meet threshold (default 80%)
- If ALL checks green AND ALL FRs have tests -> spec is "programmatically verified"

### Architecture Enforcement
- Python: import-linter config enforces layer boundaries
- Go: depguard in golangci.yml enforces package dependency rules
- TypeScript: eslint-plugin-boundaries enforces module boundaries
- When scaffolding: always add architecture enforcement config

### Universal Language Support

The QA system supports 25+ language stacks. See `~/.claude/qa-config.json` for the full list.
Stack detection is automatic via marker files (package.json, go.mod, Cargo.toml, etc.).
Quality templates for all supported languages are in `~/.claude/templates/quality/`.

## Subagent Quality Enforcement

Subagents and tasks are NOT exempt from quality gates. The following hooks fire on subagent lifecycle:
- SubagentStart: tracks subagent scope and expected file changes
- SubagentStop: runs lint/syntax/security on all files the subagent modified
- TaskCompleted: verifies task output meets quality standards (test files, lint, syntax)

## Specification Verification ("Smart Contract")

The spec-verifier runs on Stop and produces a verification verdict:
- VERIFIED: all FRs have tests, all checks green, coverage met
- GAPS: lists uncovered FRs, orphan tests, failing checks
This is the "if green, it works" guarantee — programmatic proof that specs are implemented.

## Complexity Ratchet

Complexity must never increase. The ratchet enforcer:
- Measures cyclomatic complexity, cognitive complexity, maintainability index
- Compares against baseline — any increase is flagged
- Baseline auto-updates downward (tighter over time)
- Max function: 40 lines. Max cyclomatic: 10. Max cognitive: 15.

## Security Pipeline

4-layer security scanning on every Stop:
1. Secret detection (gitleaks + regex patterns)
2. SAST (Semgrep, bandit, gosec, brakeman, psalm)
3. Dependency audit (pip-audit, npm audit, govulncheck, cargo audit)
4. Infrastructure (tfsec, hadolint, trivy)

## Test Maturity Model

Projects are assessed on a 5-level scale:
- Level 1 — MVP: tests exist and are runnable
- Level 2 — Production-Ready: coverage >= 60%, integration tests, no bare suppressions
- Level 3 — Scale: coverage >= 80%, FR traceability >= 50%, security scanning, strict linters
- Level 4 — High-Reliability: FR traceability >= 80%, architecture enforcement, complexity ratchet
- Level 5 — Mission-Critical: 100% FR traceability, mutation testing, chaos tests, runtime verification
Target: Level 3 for all projects, Level 4+ for critical systems.

## Runtime Verification

For projects that opt in (via qa-config.json `runtime_verification`):
- Python: beartype (O(1) type checking at runtime), deal (Design by Contract)
- Go: goleak (goroutine leak detection), race detector
- Resilience: toxiproxy (network fault injection), chaos-toolkit (experiments)
Templates available in `~/.claude/templates/quality/runtime/`.

## QA Governance v3.1 — Deep Enforcement Enhancements

### Cognitive Complexity Enforcement
The complexity-ratchet hook now measures both cyclomatic AND cognitive complexity:
- Cognitive complexity weights branching by nesting depth (branch at nesting level N = score 1+N)
- Max cognitive complexity per function: 15 (configurable in qa-config.json)
- Code duplication detection via jscpd (max 5% duplication)
- Dead code detection via vulture (Python) and knip (JS/TS)

### AI Slop Detection
The post-edit-checker now scans every Write/Edit for AI-generated antipatterns:
- Placeholder TODOs ("TODO: implement", "TODO: add")
- Lorem ipsum filler text
- Placeholder domains (example.com in non-test files)
- LLM leakage ("As an AI", "I cannot", "I apologize")
- Lazy AI comments ("This function does...", "This is a helper...")
- Placeholder bodies (pass # TODO, throw new Error("not implemented"))
Advisory only — prints warnings, does not block.

### Dead Import & Dead Code Detection
Quality-gate.sh (Stop) and post-edit-checker.sh (PostToolUse) now detect:
- Dead imports: ruff F401 (Python), oxlint no-unused-vars (JS/TS)
- Dead code: vulture --min-confidence 80 (Python), knip --no-progress (JS/TS)
- Code duplication: jscpd with 5% threshold

### Supply Chain Security (Layer 5)
Security pipeline expanded from 4 to 5 layers:
1. Secrets (gitleaks + regex patterns)
2. SAST (semgrep, bandit, gosec)
3. Dependencies (pip-audit, npm audit, govulncheck, cargo-audit, osv-scanner)
4. Infrastructure (hadolint, tfsec, trivy)
5. **Supply Chain** (syft SBOM generation, OSV-Scanner, opengrep)

### Enhanced Test Maturity Model
Test maturity expanded from 16 to 20 criteria across 5 levels:
- **L4 new**: Snapshot/golden tests (3pts), Approval tests (2pts)
- **L5 new**: Chaos/resilience tests (3pts), Fuzz testing (3pts)
- Enhanced property-based test detection: hypothesis, fast-check, gopter, proptest
- Points rebalanced: 20pts per level, 100pts total

### Hook Stderr Convention
All hooks that exit non-zero now write descriptive failure messages to stderr.
Format: `HOOK_NAME FAIL: reason` (e.g., "SUPPRESSION BLOCKER FAIL: 2 new lint suppression(s)")
This ensures Claude Code displays the actual failure reason instead of "No stderr output".

---

## Global governance file hierarchy (mandatory)

Treat these files as **authoritative cross-repo governance** (same priority as project-level `CLAUDE.md` / `AGENTS.md` when not overridden by a stricter project rule):

| Priority | Path | Role |
|----------|------|------|
| 1 | `~/.claude/AGENTS.md` (this file) | Global agent behavior, QA hooks, delegation |
| 2 | `~/.claude/CLAUDE.md` | Short index + pointers to CodeProjects / AgilePlus |
| 3 | `/Users/kooshapari/CodeProjects/CLAUDE.md` | CodeProjects root: worktrees, reuse protocols, **billing**, git alignment |
| 4 | `/Users/kooshapari/CodeProjects/AGENTS.md` | CodeProjects root: safety, canonical vs worktree usage |

**Other agent runtimes** (Cursor Composer, Codex factory/droid wrappers, thegent/forge-style orchestration) must load the same hierarchy: project docs first, then CodeProjects root, then this file.

## Git: land work and align `main` without `git reset --hard`

- Prefer **topic branch → push → PR → merge** to integrate commits. Do not tell users to **hard reset** local `main` to match remote as the default fix.
- After a **squash merge** on GitHub, local `main` may still contain pre-squash commits. **Do not** push a redundant **merge commit** onto `origin/main` if the repo policy forbids merge commits on `main`.
- **Align local `main` to `origin/main` without hard reset:** `git fetch origin && git pull --rebase origin main` (resolve conflicts; `git rebase --skip` if a commit is empty duplicate of remote).
- **Clean read-only tracking:** `git fetch origin && git checkout -B main-tracking origin/main` (use `main-tracking` for verification when local `main` is messy).
- **Undo only the last merge:** `git reset --merge HEAD~1` (when the last operation was an accidental merge), not a blanket discard of all local work.
- **GitHub Actions billing:** when CI cannot run due to account limits, do not block delivery on green checks; verify **locally** (build, lint, test); use `gh pr merge --admin` when branch protection allows. Full policy: `/Users/kooshapari/CodeProjects/CLAUDE.md` (GitHub Actions Billing Constraint).
