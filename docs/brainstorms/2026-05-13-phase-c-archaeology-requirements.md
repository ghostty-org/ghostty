---
date: 2026-05-13
topic: phase-c-archaeology
---

# Phase C — Archaeology / Patient Restoration

## Problem Frame

A fresh Ghostties terminal pane is a black void until the user types. Phase A (shipped 2026-05-13, commit `f27a82dc9` on `experiment/empty-state-physics`) introduced ambient ghost drift behind the Metal terminal surface, but the empty pane has no brand presence. Phase C adds the **GHOSTTIES** wordmark — slowly built up and worn down by the same drifting ghosts — turning idle time into a quiet, recurring brand moment **for users who opt in.**

The aesthetic direction is **Archaeology / Patient Restoration** (chosen from `docs/ideation/2026-05-13-phase-c-wordmark-ideation.md` after a 48-idea ce-ideate pass). The feature is off by default behind a hidden config (`ghostties.emptyStatePhysics.wordmark`). The experience belongs to users who notice and enable it.

---

## Key Flows

- F1. Full cycle on an idle empty pane
  - **Trigger:** a terminal pane has no PTY output, has no title, the hidden config is enabled, and Reduce Motion is OFF.
  - **Actors:** the SwiftUI empty-state layer; the user (passive observer).
  - **Steps:**
    1. Rubble pixels appear scattered randomly across the pane at ambient opacity (frame 1).
    2. Drifting ghosts begin transitioning to **carrier** state, in cycle phase "assembly." Multiple carriers may be active concurrently, capped per R10b.
    3. A carrier moves toward a rubble pixel, picks it up, ferries it to its assigned slot in the wordmark, deposits it, and returns to drifting.
    4. Over ~30s, the wordmark assembles pixel by pixel.
    5. When the last pixel is placed, the wordmark holds at brand opacity for ~3–5s.
    6. Erosion begins. Carriers pick pixels OFF the wordmark and deposit them back into the canvas as rubble, mirroring assembly over ~30s.
    7. When the wordmark is fully eroded, the cycle restarts.
  - **Outcome:** a slow breath-like loop (~65s per cycle) visible only when the user is not engaged with the pane.
  - **Covered by:** R1–R12

- F2. Cycle interrupted by first keystroke
  - **Trigger:** a PTY byte arrives mid-cycle.
  - **Steps:** the entire empty-state layer (Phase A + Phase C) fades out over 250ms (existing Phase A behavior). The cycle state is discarded — no resume, no save.
  - **Outcome:** the layer dismounts; no idle CPU on the active pane.
  - **Covered by:** R3

- F3. Reduce Motion enabled
  - **Trigger:** the user has system Reduce Motion on, the hidden config is enabled, the pane is empty.
  - **Steps:** the wordmark renders statically at brand opacity, fully assembled, no motion. No rubble. Phase A's static-decorative fallback continues to apply for the ghosts.
  - **Outcome:** the brand moment is present but motionless.
  - **Covered by:** R11

---

## Requirements

**Activation & lifecycle**

- R1. The wordmark layer activates only when `ghostties.emptyStatePhysics.wordmark` is true AND the existing empty-state visibility predicate is true (`title.isEmpty && !hasReceivedOutput`).
- R2. Phase C is layered on top of Phase A. Phase A's drifters are the same bodies that perform Phase C's assembly work; no second swarm.
- R3. On first PTY output, the entire empty-state layer fades out over 250ms (existing Phase A behavior), the TimelineView dismounts, and the cycle state is discarded — no frame work continues on active panes.

**Cycle behavior**

- R5. The cycle has three phases: **assembly** (~30–45s, depending on final brick-pixel count), **hold** (~3–5s), **erosion** mirrors assembly. One full loop is ~65–95s.
- R6. Cycle phases are continuous — there is no event-driven beat (no flash, no shake, no sound) at the transitions between assembly/hold/erosion.
- R7. The wordmark's completed assembly state holds at **brand opacity** (target: 60–80% of text-primary tint). Ambient drifters and rubble remain at ~22% secondary tint. Brightening of placed pixels happens continuously as they're deposited — not as a separate fade.
- R8. Erosion is the visual mirror of assembly — same cadence, same per-pixel handling, in reverse.

**Ghost roles (state machine)**

- R9. Each ghost is in one of: `drifting`, `carrying`, `depositing`. Default state is `drifting` (Phase A behavior).
- R10. A drifting ghost may transition to `carrying` when (a) the cycle is in assembly or erosion phase AND (b) a target pixel is available (rubble pixel during assembly; placed pixel during erosion) AND (c) a per-ghost timer/probability allows pickup. Implementation may use proximity, attraction, or scheduled assignment — that is a planning decision.
- R10b. At most 3 of the 7 ghosts may be in `carrying` or `depositing` state simultaneously. The remaining 4+ continue ambient drifting with full ghost-ghost collision behavior, preserving Phase A's swarm dance.
- R11. While `carrying` or `depositing`, a ghost does NOT collide with other ghosts — it passes through. Wall reflection still applies.
- R12. The carried pixel renders attached to the ghost. During carry, the pixel is at brand opacity (the in-transit pixel is already brightening toward its placed state), making the carry visually distinguishable from the ghost body it rides on. After deposit, the ghost returns to `drifting`.

**Visual treatment**

- R13. Rubble pixels are rendered at the same secondary tint as the drifting ghosts, ~22% opacity, sized to one brick cell.
- R14. Brick cell resolution should align to the existing 12×12 ghost grid scale (one brick cell ≈ one ghost pixel) so the wordmark and the ghost characters share a coherent pixel language. Exact brick dimensions are a planning decision.
- R15. The assembled wordmark uses **only chrome, canvas, secondary, and text-primary tokens**. Terracotta is reserved for activity state and must not appear in this feature.
- R16. No anti-aliasing, no gradients, no shadows. Pixels are filled rectangles via the established `GeometryReader + Path.fill()` pattern.

**Sizing**

- R17. The wordmark scales proportionally with pane width, targeting ~60% of pane width.
- R18. The wordmark width is clamped: minimum ~200pt, maximum ~600pt. Below the minimum, Phase C does not activate (Phase A drift continues normally; rubble does not appear).
- R19. The wordmark is centered horizontally and vertically in the pane.
- R21. On pane resize during a cycle, the cycle resets: rubble re-scatters across the new bounds, slot positions recompute for the new wordmark size, and assembly restarts. If the resize crosses the R18 activation threshold, the layer behaves per the new state on the next frame.

**Accessibility**

- R20. When system Reduce Motion is enabled, render the wordmark statically at brand opacity, fully assembled, with no motion. No rubble, no cycle, no carriers. Phase A's existing Reduce Motion fallback for the ghosts continues to apply. When the pane is below R18's minimum width AND Reduce Motion is enabled, the wordmark also does not render — Phase C remains entirely inactive on tiny panes regardless of motion preference.

---

## Acceptance Examples

- AE1. **Covers R5, R7, R8.** Given a fresh pane with the feature enabled, when 60 seconds have elapsed, then the wordmark has assembled from rubble, held briefly at brand opacity, and is now ~halfway through erosion back to rubble.
- AE2. **Covers R3, R4.** Given a pane in mid-assembly, when the user types a single character, then within 250ms the empty-state layer is invisible and no further frames are produced by the TimelineView.
- AE3. **Covers R11.** Given two carrying ghosts on intersecting paths, when their bounding circles overlap, then they pass through each other without deflection and each continues toward its target slot.
- AE4. **Covers R18.** Given a pane 180pt wide (below minimum), when the feature is enabled, then no rubble appears and no wordmark assembles — Phase A drift continues normally.
- AE5. **Covers R20.** Given Reduce Motion is on and the feature is enabled, when a fresh pane appears, then the wordmark is rendered fully assembled and motionless at brand opacity, with no rubble visible.

---

## Success Criteria

- A user with the hidden config enabled and the app idle for ~60s sees the GHOSTTIES wordmark assemble, hold briefly as a recognizable brand moment, and erode back to rubble — without the cycle ever feeling like a game, an animation demo, or a distraction.
- Typing into a pane mid-cycle never produces a "wait for the animation to finish" moment. The fade is instant-feeling.
- Performance: an idle pane with Phase C running uses no more frame work than Phase A alone plus the per-cycle bookkeeping. An active pane (post-fade) uses zero empty-state frame work.
- A downstream agent picking up this brainstorm can write a plan without inventing product behavior — every cycle phase, ghost state, sizing rule, and accessibility behavior is stated above. Open items are tagged `Deferred to Planning`.
- Acknowledged constraint: empty panes are usually vacated within seconds (the natural use is to type into them). The cycle is designed for users who genuinely idle; most observed sessions will see partial cycles, not full ones. This is not a defect — it's the reality of an idle-only feature.

---

## Scope Boundaries

- The wordmark is **GHOSTTIES** as a glyph composition; not a configurable string, not a custom user inscription.
- No audio. (Sean's parked sound-effects palette is a separate, later conversation.)
- No interaction during the cycle. User cannot grab a ghost, redirect a carrier, or "help" the assembly. (Drag/tap belong to Phase B.)
- No persistence across sessions. Cycle state is per-pane, per-session. (Long-Session Ritual was idea #6 in ideation; deferred as a separate decision.)
- No first-launch / onboarding integration. The "wall builds itself before OnboardingSheet appears" idea is a separate compound move; out of scope for Phase C v1.
- No idle screensaver mode (Phase D) — this brainstorm covers only the empty-pane cycle.
- No alternate wordmark shapes, color overrides, or theme variants.

---

## Key Decisions

- **Brand-moment cycle over continuous flux.** The wordmark holds visibly at brand opacity for 3–5s rather than perpetually mid-cycle. Rationale: Sean's pick; the layer dismisses on keystroke anyway, so the brand moment lands only when the user is idle.
- **Symmetric breath-rhythm (~30s + 5s + 30s).** Rationale: matches Phase A's drift timescale (a ghost crosses the pane in ~30s at ambient pace). Asymmetric rhythms felt either rushed or melodramatic.
- **State-machine carriers, not a separate swarm.** Same 7 Phase A ghosts transition through `drifting` → `carrying` → `depositing` states. Rationale: single physics system; emergent coherence between Phase A and Phase C; lower implementation surface.
- **Carriers pass through other ghosts.** Rationale: cleanest motion during assembly; "ferrying a pixel" should not result in clumsy mid-air drops.
- **Random scatter rubble.** Maximum labor feel — ghosts traverse real distance. Rationale: Sean's pick over clustered/sediment/debris variants; reads as "chaos resolving into order."
- **Wordmark brightens continuously during assembly.** Each placed pixel brightens toward brand opacity at the moment it's deposited. By the time the cycle reaches hold, all pixels are already at brand opacity together. Rationale: a distinct land moment built up over time rather than a separate flash.
- **Carriers move faster than drifters.** Carriers travel at up to 1.3 px/frame (Phase A's chase ceiling); drifters stay at 0.22–0.40 px/frame. Rationale: at drift speed, 7 ghosts can't deposit ~315–500 pixels in 30s without producing frenetic motion. Carrying is task-state, not ambient — slightly faster motion reads as "on a mission," not "urgent."
- **Easter egg, not public brand moment.** The hidden-config gating is intentional: this feature belongs to users who notice and enable it, not to the general first-impression. The "brand moment" framing in the Problem Frame describes what those users experience, not who the feature reaches. If Phase C ever earns on-by-default status, that's a separate decision after observing the implementation on Sean's daily-driver.
- **Proportional sizing with min/max clamp.** Below ~200pt pane width, the feature doesn't activate. Rationale: tiny panes already cramped; better to defer than render tiny.
- **Reduce Motion = static assembled wordmark.** Not "skip the feature entirely" — the brand moment is still present, just motionless.

---

## Dependencies / Assumptions

- Phase A is shipped and provides: the drifting-ghost physics, the empty-state visibility signal (`title.isEmpty && !hasReceivedOutput`), the fade-on-output behavior, and the Reduce Motion fallback. Phase C extends Phase A's physics by adding a carrier state machine on top of the existing drifters. Ambient drift speed and wall reflection are preserved. Ghost-ghost collision becomes state-aware: only `drifting` ghosts collide; carriers pass through (R11).
- Phase C uses `@AppStorage("ghostties.emptyStatePhysics.wordmark")` following the existing `ghostties.*` convention used elsewhere in the codebase (e.g., `WorkspaceSidebarView.swift:39`, `TaskRowView.swift:98`). No new config layer is required. **Verified.**
- `GhostCharacter`'s 12×12 pixel grid is the canonical pixel scale; brick cells should align to it.
- The existing `GeometryReader + Path.fill()` rendering pattern is sufficient performance-wise for ~315–500 brick pixels animated at 60fps. This is an assumption; performance verification belongs in planning.

---

## Outstanding Questions

### Resolve Before Planning

_(none — Sean's product decisions are captured above. Anything Sean would change about the cycle/states/scaling/visual relationship should be raised in conversation before `/ce-plan`.)_

### Deferred to Planning

- [Affects R14][Technical] Exact brick cell dimensions: one brick = one 12×12 ghost pixel (~1.67pt at 20pt-rendered ghost size)? Or finer (e.g., 1pt cells)? Choice affects pixel count per letter, which affects cycle pacing math.
- [Affects R7][Technical] Exact opacity targets: secondary-tint ambient = 0.22 (Phase A precedent). Wordmark brand opacity = 0.6? 0.7? 0.8 of text-primary? Needs eyeballing on the live build.
- [Affects R17, R18][Technical] Concrete pane-size thresholds and target wordmark width. Sean's stated ranges (~200pt min, ~600pt max, ~60% of pane) are reasonable starting points; refine during prototyping.
- [Affects R14][Needs research] Font/glyph shape for the wordmark. Options: rasterize SF Mono uppercase at brick resolution; design a custom pixel typeface; reuse the upstream Ghostty wordmark glyphs if any exist. Recommend reusing/rasterizing SF Mono since it already matches the terminal's typographic system.
- [Affects R10][Technical] Carrier-selection algorithm: nearest unassigned pixel, scheduled assignment by slot index, proximity attraction force, etc. Planning decision based on what produces calm-looking motion.
- [Affects all][Technical] Performance budget: target frame loop cost per pane while Phase C is active. Sanity-check via Instruments before merging.
- [Affects sequencing][Strategic] Is Phase C the correct next bet vs. Phase B (drag/tap interaction)? Phase B is interactive and ships without hidden-config gating. This brainstorm captures Phase C's design assuming it's the next phase; revisit ordering with Sean before `ce-plan` if the strategic question hasn't been settled.

---

## Next Steps

`-> /ce-plan` for structured implementation planning.
