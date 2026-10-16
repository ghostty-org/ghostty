## Cockpit tick format

For substantive multi-agent work, every coordinator cockpit tick must show:

- Pacific-local timestamp;
- total, active, queued, and completed task counts;
- owner of every dispatched task;
- an ASCII progress bar for each active stage/gate;
- items remaining in each stage;
- ETA to finish each goal and overall ETA;
- any ETA revision as `old ETA -> new ETA` with an evidence-based reason.
- a compact dependency graph showing stage order and the current blocking edge;
- a per-goal finish estimate, not only a task ETA, plus one overall finish estimate.

Use ASCII-only bars and graphs, for example:

```text
Stage 2 Review fixes [=====>....] 50% | 2/4 items | ETA 12m
Overall critical path: [===>......] 30% | 6/20 gates | ETA 45m
```

For each tick, include both views when work is active:

```text
Stage gates: [Done] -> [Active] -> [Blocked] -> [Pending]
Goal A:      [=====>....] 50% | 3/6 gates | ETA 20m
Goal B:      [==>.......] 20% | 1/5 gates | ETA 35m
Overall:     [===>......] 30% | 4/11 gates | ETA 35m
```

If no work is active, render the same graph with `PAUSED` and state the exact
input or approval required to resume. Keep bars ASCII-only and estimates
evidence-based.

## Orchestrator / ledger / cockpit split (operator, 2026-10-02)

- Base chat is the ORCHESTRATOR and stays clean: decisions, dispatch,
  synthesis, ledger writes only. Never surface raw tool output (gh JSON,
  greps, logs, long diffs) in base chat.
- Ledger = durable state: mem/agents.md, the todo tool, evidence files,
  session docs. Subagents write findings into files; the orchestrator
  records only compact verdicts.
- Cockpit = the tick view defined above, rendered whenever work is active.
- ALL context-polluting actions run in subagents: polling loops, CI
  watching, repo greps, bulk reads/writes, evidence collection, downloads.
  The orchestrator dispatches and consumes compact reports only.
- Parallelize and DAGify every dispatch: independent branches spawn
  simultaneously; dependent steps chain inside a single agent; never
  serialize what can run concurrently.

## Ledger resilience note (2026-10-02)

Between 19:32:03Z and 19:32:24Z a concurrent process deleted the project
`.codex/` directory and `.claude/agents.md` (untracked/ignored files). This
file was restored verbatim from a contemporaneous read plus the appended
protocol. If it vanishes again, treat that as a config-GC ownership conflict,
not data loss: the canonical protocol copy also lives in the harness memory
store under tag `agents-orchestration`.

## Durable-report rule (operator lesson, 2026-10-04)

Worker sessions are reaped during orchestrator idle gaps, and any report that
was not delivered (or failed the >240-char tldr gate) is lost with them. Every
dispatch that produces a verdict MUST write it to a file FIRST (evidence dir or
scratch), then send the short chat report. Chat reports over 240 chars must
start with a `tldr:` line under 200 chars. The coordinator reads the file if
the chat report is missing. Observed losses: tiger (sentinel v1), parrot
(verdict); durable pattern proven by cat's sentinel log directive.
