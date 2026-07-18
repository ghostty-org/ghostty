# 01 — research/spike

**Base:** `main` · **Status:** ✅ complete — see [`01-research-spike-findings.md`](./01-research-spike-findings.md) (detachment assumption: **PASS**) · **Blocks:** the whole milestone chain
**Read first:** [`plan.md`](../../plan.md) §"Before writing code" and [`00-OVERVIEW.md`](./00-OVERVIEW.md)

## Purpose

This branch produces **notes, not shipping code**. Confirm the design's load-bearing
assumptions before anyone builds M1–M4. If an assumption is wrong, stop and report a
revised approach.

## Tasks

1. Get a local dev build running and confirm the app launches unchanged.
   - `zig build -Demit-macos-app=false` for a fast core build; the macOS app builds
     via Xcode in `macos/`.
2. Read and summarize back:
   - `macos/Sources/Features/Terminal/` — how `TerminalController` owns/installs the
     split tree and reacts to tab/window lifecycle.
   - `SplitTree` / `SurfaceView`: how surfaces are created, how a tree attaches to the
     window content view.
   - **THE load-bearing check:** what happens to a `SurfaceView` when removed from the
     view hierarchy — **does its pty/session survive detachment?** The entire
     workspace-switching design depends on "yes." Verify empirically (detach a view,
     confirm the process keeps running), not just by reading.
   - How per-surface working directory (OSC 7 / pwd) is tracked and where Swift reads it.
   - How a keybind flows `src/input/Binding.zig` → apprt action interface → Swift, using
     `goto_split` as the reference trace.
3. Check upstream for anything relevant added since `plan.md` was written (sidebar config,
   scripting API, workspace concepts). Skim Discussion #2549 / aflat's `vert_tabs` branch
   for sidebar plumbing prior art — reference only, don't inherit code.

## Deliverable

A findings doc (append to this file or a sibling) covering each item above, an explicit
PASS/FAIL on the pty-survives-detachment assumption, and — if anything failed — a revised
approach. Present to the human before M1 starts.

## Done when

- Human has reviewed findings and confirmed the milestone chain may proceed.
