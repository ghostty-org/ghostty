---
name: omg-debug
description: Diagnose and repair Oh My Ghostty (OMG Dev) runtime problems on macOS, including UI latency, hover/event routing, memory growth, CPU activity, lifecycle retention, and crashes. Uses bounded local evidence and Dev builds for verification. Never touches the user's release OMG installation.
---

# OMG debugging

Environment: macOS with an OMG Dev Debug bundle; Xcode command-line tools are
optional.

Use this skill for OMG Dev runtime diagnosis. For memory/event schema and
sampling commands, read `docs/omg-dev-memory-diagnostics.md` from the repo root.
If building, testing, or preparing a separate debuggable app, also read
`.agents/skills/omg-build/SKILL.md` **before** running commands.

## Safety

- Never quit, rebuild over, replace, or modify the release app at
  `/Applications/OMG.app`.
- A user request to diagnose or repair OMG Dev authorizes the bounded local
  observation, profiling, reproduction, Dev-only build/install, and restart
  needed to verify that task. Do not ask again for those scoped steps. This does
  not authorize deleting session data, stopping unrelated processes, changing
  the release app, public uploads, issue/PR publication, pushes, or merges.
- Treat open terminals and their running work as user state. Before a Dev
  restart, verify the current app and restoration state, preserve its session
  data, and use the normal close/install path. If a specific session cannot be
  preserved and the restart would discard it, pause for that concrete risk;
  task authorization is not permission to lose user work.
- For analysis-only requests, do not build, install, restart, or change app
  state. Inspect the live process and existing evidence only.
- Observe the *current* app/bundle/PID; old PIDs and `/tmp` files in a prior
  conversation are historical. Check process identity again before interpreting
  a later sample.
- The app logger is **off by default** and works only for Debug bundle
  `com.jischeng.omg.debug` when `OMG_DEV_MEMORY_DIAGNOSTICS=1` was in the
  environment at process launch. Setting it now does not enable an existing
  process. Never assume a source build or installed Dev is eligible without
  verifying its bundle identifier.
- Never write terminal text, commands, titles, session paths, env dumps, or
  stacks into persistent app logs. Fixed JSONL fields are time, event,
  surface-view/tab-controller/window-group counts, **not** resource bytes.
- Footprint/CPU and allocation stacks come from **external** system tools,
  not the app JSONL. CPU hot spots and coincident memory growth do not prove
  causality; a short peak or idle plateau does not establish a leak.

## Triage

1. Define the symptom, current process, workload, and task scope.
   Check current bundle/PID and log switch; inspect any existing bounded logs.
2. For memory, first check the two owner-only JSONL files under
   `~/Library/Application Support/OMG/MemoryDiagnostics/`. Sort by UTC `time`,
   keep `start` boundaries, and don't dump raw records. For CPU, distinguish
   current CPU-time delta from lifetime averages.
3. For an authorized diagnosis or repair, collect a separate **bounded,
   low-frequency** system trace
   using `python3 .agents/skills/omg-debug/scripts/observe.py sample --pid PID
   --output-dir /tmp/unique-private-dir --interval 60 --duration-minutes 120`.
   It verifies the Debug bundle, identity and private output location, stops
   automatically, and saves `system-samples.csv` with heap/graphics/IOSurface
   and CPU deltas. Use `observe.py report --csv PATH` to join action events to
   the nearest sample; the report marks timing offsets and excludes other runs.
   For a user-provided CSV, verify units/timezone/identity before joining.
4. Arrange a controlled idle baseline and relevant window/tab/split operations,
   then a quiet settling interval after each. Automate the reproduction where
   possible; request user help only for an actual missing prerequisite, such as
   an unavailable unlocked desktop. Compare *similar*
   states and report baseline, peak, post-close, sample interval, count changes
   and missing measures. Distinguish retained views from retained Zig/Metal
   resources; don't infer image/cache/scrollback bytes from view counts.
5. For reproducible CPU use, record a bounded Time Profiler trace against the
   verified OMG Dev process. For specific retained allocation call sites,
   prepare a **separately debuggable** OMG Dev and use Instruments Allocations
   or LLDB only on that build. LLDB is not a logging switch. Do not attach
   invasive profiling tools to the release app. `leaks` is incomplete for
   still-referenced memory. Keep raw traces private and do not copy stacks into
   app JSONL.
6. State evidence, uncertainty and next experiment; never claim a root cause
   solely from correlation. In particular, the `AgentLogoStatus.swift`
   TimelineView is a hypothesis, not a proven cause.

## When changing the implementation

- Run focused tests for the changed behavior. When changing the diagnostics
  logger, use:
  `macos/build.nu --action test --only-testing GhosttyTests/DevMemoryDiagnosticsTests`.
- Validate Swift lint for changed Swift code. For logger changes:
  `swiftlint lint --strict --config macos/.swiftlint.yml macos/Sources/Features/Terminal/DevMemoryDiagnostics.swift macos/Tests/Terminal/DevMemoryDiagnosticsTests.swift`.
- When changing the sampler, validate it with
  `python3 -m unittest discover -s .agents/skills/omg-debug/scripts -p 'test_*.py'`.
- Check `python3 dist/check_omg_docs.py`. The skill is not a plugin API. If
  later work changes plugin APIs, manifests, wire messages, capabilities,
  lifecycle, loading/discovery, package layout, Inspector provider behavior
  or permissions, update `docs/PLUGIN_DEVELOPMENT.md` and relevant tests in
  the same commit.

## Native hover verification

Do not accept `isHovered` changes or a successful call to `displayIfNeeded()` as
proof that row pixels followed the pointer. Reproduce with the real tracking
event delivered by AppKit; move between rows and scroll while the pointer is
stationary. Check both the outgoing and incoming row backgrounds, recycled rows,
and independent close-button hover. Keep one hover owner for row backgrounds
per table; close buttons and other row controls must derive hover from the same
row state or reconcile against the same delivered event, so a tracking child
cannot disagree with its row. Repaint only the changed rows. A test that calls
the hover setter directly does not verify event routing or the AppKit
row-background display path.
