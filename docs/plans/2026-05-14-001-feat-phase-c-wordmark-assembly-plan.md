---
title: "feat: Phase C — Archaeology wordmark assembly for empty-state physics"
type: feat
status: active
date: 2026-05-14
origin: docs/brainstorms/2026-05-13-phase-c-archaeology-requirements.md
---

# feat: Phase C — Archaeology Wordmark Assembly

## Overview

Extends the existing Phase A ambient ghost drift layer (`SurfaceEmptyStatePhysics`) with a slow wordmark assembly cycle. Scattered rubble pixels are patiently ferried by carrier ghosts into the "GHOSTTIES" wordmark over ~30–45 s, the assembled mark holds at brand opacity for ~3–5 s, then erodes back to rubble over the same span. The cycle is gated behind `@AppStorage("ghostties.emptyStatePhysics.wordmark")` (hidden config, off by default). The entire layer dismisses on the first PTY byte — identical to Phase A behavior.

---

## Problem Frame

A fresh Ghostties terminal pane shows ambient ghost drift (Phase A). Phase C adds a brand moment for the niche of users who discover and enable the hidden config: a recurring, breath-like cycle that reads as "chaos resolving into order." The aesthetic direction is Archaeology / Patient Restoration — slow labor, found objects, accumulated meaning.

See origin doc for full problem frame, flows (F1–F3), and acceptance examples (AE1–AE5).

---

## Requirements Trace

- R1. Wordmark layer activates only when `ghostties.emptyStatePhysics.wordmark = true` AND Phase A's empty-state predicate holds (`title.isEmpty && !hasReceivedOutput`).
- R2. Phase C uses the same 7 Phase A ghosts — no second swarm.
- R3. First PTY output dismounts the entire layer (250 ms fade, existing Phase A behavior).
- R5. Cycle: assembly (~30–45 s) → hold (~3–5 s) → erosion (mirrors assembly). Full loop ~65–95 s.
- R6. Cycle phase transitions are continuous — no flash or beat.
- R7. Placed pixels hold at brand opacity (target 0.60–0.80 of `.primary`). Ambient drifters and rubble at ~22% secondary tint. Brightening is per-pixel at deposit time.
- R8. Erosion is the temporal mirror of assembly.
- R9. Ghost states: `drifting`, `approaching`, `ferrying`. Default: `drifting`.
- R10. Carrier assignment: drifting ghost may transition to approaching when (a) phase is assembling or eroding AND (b) an unassigned target pixel exists AND (c) per-ghost probability gate passes.
- R10b. At most 3 of 7 ghosts may be in approaching or ferrying state simultaneously.
- R11. Approaching/ferrying ghosts pass through other ghosts — no ghost-ghost collision. Wall reflection still applies.
- R12. Carried pixel renders attached to ghost at brand opacity during ferry.
- R13. Rubble pixels at ~22% secondary tint, one brick cell in size.
- R14. Brick cell aligns to 12×12 ghost grid scale (~one ghost pixel). Exact brick dimensions determined at implementation time via pacing math.
- R15. Wordmark uses chrome, canvas, secondary, and text-primary tokens only. Terracotta (`#C97350`) is off-limits.
- R16. No anti-aliasing, no gradients, no shadows. Filled rectangles via `Path.addRect`.
- R17. Wordmark scales to ~60% of pane width.
- R18. Minimum wordmark width ~200 pt; maximum ~600 pt. Below minimum, Phase C inactive.
- R19. Wordmark centered horizontally and vertically.
- R20. Reduce Motion: render wordmark fully assembled at brand opacity, no motion, no rubble.
- R21. Pane resize during cycle: cycle resets, rubble re-scatters, slot positions recompute. Resize across R18 threshold: Phase C activates/deactivates on next frame.

**Origin flows:** F1 (full idle cycle), F2 (cycle interrupted by keystroke), F3 (Reduce Motion static)
**Origin acceptance examples:** AE1 (covers R5, R7, R8), AE2 (covers R3), AE3 (covers R11), AE4 (covers R18), AE5 (covers R20)

---

## Scope Boundaries

- Wordmark string is fixed: "GHOSTTIES". Not configurable.
- No audio, no user interaction during the cycle, no drag/tap on wordmark pixels.
- No persistence across sessions or panes. State is per-pane, per-launch.
- No alternate color themes, custom glyphs, or shape variants.
- Phase B (drag/throw, tap) and Phase D (idle screensaver) remain out of scope for this plan.
- Letter pixel grids are hand-authored at implementation time — the exact grid design is a craft decision, not resolved here.

---

## Context & Research

### Relevant Code and Patterns

- **Phase A files** — the direct base; read before implementing any unit:
  - `macos/Sources/Features/Ghostties/EmptyState/SurfaceEmptyStatePhysics.swift` — view, isEmpty predicate, Reduce Motion branch, opacity animation, `DispatchQueue.main.async` tick deferral
  - `macos/Sources/Features/Ghostties/EmptyState/PhysicsWorld.swift` — `GhostBody` struct, `PhysicsWorld.initial(in:count:radius:)`, `stepped(by:bounds:)`
  - `macos/Sources/Features/Ghostties/EmptyState/PhysicsCollision.swift` — pure `enum PhysicsCollision` with `reflectAgainstWalls(body:in:)` and `resolvePair(_:_:)`
  - `macos/Tests/Ghostties/EmptyStatePhysicsTests.swift` — test structure, `makeBody` helper, `eps` accuracy, `@testable import Ghostty`

- **Ghost character pattern** — `macos/Sources/Features/Ghostties/Models/GhostCharacter.swift`: 12×12 `[[Bool]]` pixel grids, `parseGrid(_:)` compact-string parser, `drawPath(in:)` using `path.addRect` per filled cell. The wordmark glyph data follows this exact structure.

- **Rendering pattern** — `macos/Sources/Features/Ghostties/GhostCharacterView.swift`: `GeometryReader { geo in let path = character.drawPath(in: CGRect(origin: .zero, size: geo.size)); path.fill(color) }`. Each wordmark pixel is an `addRect` into a single `Path`, rendered with one `path.fill()` call per opacity tier — no per-pixel views.

- **PixelChevronView** — `macos/Sources/Features/Ghostties/PixelChevronView.swift`: same GeometryReader + Path pattern with a `Pixel { x, y, w, h }` struct. A direct model for `WordmarkPixel`.

- **@AppStorage convention** — declare `private`, use `"ghostties."` prefix, provide default. Example: `@AppStorage("ghostties.emptyStatePhysics.wordmark") private var wordmarkEnabled = false`.

- **Reduce Motion** — use `@Environment(\.accessibilityReduceMotion)` (SwiftUI path), not `NSWorkspace.shared...`. Already established in `SurfaceEmptyStatePhysics`.

### Institutional Learnings

- Design review of the sidebar pixel-art layer caught: animation not gated on Reduce Motion (now fixed in Phase A), hardcoded colors instead of semantic tokens, spacing off 4-pt grid. Apply the same checklist to Phase C before shipping.
- `DispatchQueue.main.async` is the established fix for "modifying state during view update" inside `TimelineView` content closures — do not synchronously mutate `@State` inside the `TimelineView` update block.
- `dt` is clamped to `1/30` in `PhysicsWorld.stepped()` to prevent teleporting on tab resume or system hitch. Carrier motion should inherit the same clamp.
- The `if isEmpty { ... }` branch gates `TimelineView` — it dismounts entirely when the pane becomes active, producing zero frame work. Do not move any Phase C state outside this branch.

---

## Key Technical Decisions

- **Hand-authored pixel grids**: Each letter of "GHOSTTIES" is defined as a compact `X`/`.` string matching `GhostCharacter`'s `parseGrid` format (or equivalent). This is zero-dependency, design-controllable, and fully testable. The `parseGrid` helper in `GhostCharacter.swift` is private — duplicate the 3-line function into `WordmarkGlyphs.swift` rather than making it `internal`. (Rationale: avoids touching upstream-sensitive `GhostCharacter.swift`; the function is trivial.)

- **`GhostRole` enum on `GhostBody`**: Add `var role: GhostRole` to the existing `GhostBody` struct. `PhysicsWorld.stepped(by:bounds:)` skips ghost-ghost collision for bodies whose role is not `.drifting`, while still applying wall reflection to all bodies. (Rationale: one physics step covers all bodies; `WordmarkWorld` sets roles before the step, reads them after. Cleaner than a separate locked-ID set parameter.)

- **`WordmarkWorld` as a parallel pure value type**: A separate `struct WordmarkWorld` owns cycle phase, pixel states, and role assignments. Its `stepped(updating:dt:bounds:) -> (WordmarkWorld, [GhostBody])` function takes the current ghost bodies, moves carriers toward their targets, returns updated bodies + a new world state. `PhysicsCanvas` calls `WordmarkWorld.stepped` first, then passes the resulting bodies into `PhysicsWorld.stepped`. (Rationale: clean concern separation; `PhysicsWorld` stays unaware of wordmark semantics.)

- **Two-phase carrier motion — `approaching` → `ferrying`**: Carrier first moves toward the rubble pixel's current position (`approaching`); within a pickup radius (~12 pt) it transitions to `ferrying(pixelIndex:, targetPosition:)` and moves toward the target slot (assembly) or scatter position (erosion). Pixel renders at carrier position during both sub-phases. (Rationale: produces the "move toward, pick up, carry" visual behavior specified in F1; a single `carrying` state with an internal flag is equivalent but less readable.)

- **Carrier speed via seek, not constant velocity**: Each frame, the carrier velocity vector is set directly toward the target at `min(distance / dt, maxSpeed)` where `maxSpeed = 1.3 px/frame × 60`. When the carrier is far away it moves at max speed; when close it decelerates naturally. (Rationale: prevents overshooting the target on the final frame; smooth deceleration is more legible than a hard stop.)

- **Single `Path.fill()` call per opacity tier per frame**: All rubble pixels share one path (filled at ~22% `.secondary`); all placed pixels share another (filled at brand opacity); all in-transit pixels share a third. Three `path.fill()` calls total, regardless of pixel count. (Rationale: matches `GhostCharacter.drawPath` precedent; avoids a `ForEach` of pixel views which would create O(n) SwiftUI nodes.)

- **Brick cell size as a derived constant**: `brickSize = wordmarkWidth / totalWordmarkColumns`. `totalWordmarkColumns` is computed once from the sum of letter widths + inter-letter spacing. The wordmark aspect ratio is fixed; the brick size adapts to the pane. At implementation time, calibrate letter widths so the ~30–45 s assembly window is achievable with 3 carriers at 1.3 px/frame. (Rationale: deferred per requirements doc; the plan records the algorithm, not the exact numbers.)

- **Opacity animation is per-pixel and immediate at deposit**: When a pixel transitions to `.placed`, its `displayOpacity` is set to `brandOpacity` in the same `WordmarkWorld.stepped()` call. SwiftUI's `animation` modifier on the pixel layer animates this change over ~0.3 s. No separate hold-phase flash. (Rationale: R7 specifies continuous brightening during assembly, not a transition on hold.)

---

## Open Questions

### Resolved During Planning

- **CoreGraphics rasterization vs. hand-authored grids**: Resolved in favor of hand-authored grids (see Key Technical Decisions). Rasterizing SF Mono would require `NSFont`/`CoreText` and produces output that needs design review anyway; hand-authored grids are directly designable and match the existing precedent.
- **Separate swarm vs. same 7 ghosts**: Resolved by R2 — same 7 ghosts, no second swarm. `GhostRole` extends `GhostBody`.
- **`PhysicsWorld` modification surface**: One new field (`role: GhostRole`) on `GhostBody`, and one added condition in `PhysicsCollision.resolvePair` (skip if either body's role is non-drifting). No architectural change to `PhysicsWorld`.

### Deferred to Implementation

- **Exact brick cell dimensions and letter pixel widths**: Must be calibrated empirically. Start with 8-row-tall letters at 5–6 columns wide per letter, then adjust until the assembly cycle fits 30–45 s at 3 carriers/78 pt per second carrier speed. Target ~120–180 total filled pixels across the wordmark.
- **Exact brand opacity value**: Requirements specify 0.60–0.80 of `.primary`. Start at 0.70; calibrate on the live build under dark and light mode.
- **Carrier assignment probability gate (R10)**: Whether to use a uniform per-frame probability, a min-time-since-last-pickup cooldown, or proximity attraction is left to the implementer. The plan does not specify; any approach that produces calm, non-frantic assignment behavior is acceptable.
- **Pixel scatter distribution (R13)**: Uniform random within pane bounds. Guard: scatter position must be outside the wordmark bounding rect by ≥ one brick cell.
- **Pickup and deposit radii**: Suggested starting point: ~12 pt (3× brick at typical pane width). Tune for natural-looking transitions.
- **Hold duration**: Target 4 s. Implementer may adjust within the 3–5 s window.

---

## Output Structure

```
macos/Sources/Features/Ghostties/EmptyState/
├── SurfaceEmptyStatePhysics.swift   ← MODIFY (add wordmark branch, @AppStorage guard)
├── PhysicsWorld.swift               ← MODIFY (add GhostRole to GhostBody; skip carrier collision)
├── PhysicsCollision.swift           ← MODIFY (carrier-aware collision guard)
├── WordmarkGlyphs.swift             ← NEW (pixel grids, layout math)
├── WordmarkWorld.swift              ← NEW (cycle model, pixel states, carrier assignment)
└── WordmarkPhysics.swift            ← NEW (carrier seek motion, pickup/deposit logic)

macos/Tests/Ghostties/
├── EmptyStatePhysicsTests.swift     ← unchanged
└── WordmarkPhysicsTests.swift       ← NEW (unit tests)
```

---

## High-Level Technical Design

> _This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce._

### Ghost role state machine (per GhostBody)

```
         [drifting] ────────────────────────────────────────────────────────┐
              │                                                             │
   (carrier assigned; target pixel available; ≤3 active carriers)         │
              ▼                                                             │
       [approaching(pixelIndex)]                                           │
              │                                                             │
   (within pickup radius of rubble/placed pixel)                          │
              ▼                                                             │
       [ferrying(pixelIndex, targetPosition)]                              │
              │                                                             │
   (within deposit radius of targetPosition)                               │
              │                                                             │
          deposit ──────────────────────────────────────────────────────── ┘
```

At most 3 ghosts may be in `approaching` or `ferrying` simultaneously (R10b). Ghost-ghost collision is skipped for all non-drifting ghosts (R11).

### Cycle phase machine (WordmarkWorld)

```
        [assembling] ──(all pixels placed)──▶ [holding(elapsed)]
             ▲                                       │
             │                              (elapsed ≥ holdDuration ~4s)
             │                                       ▼
             └──────(all pixels rubble)───── [eroding]
```

Phase transitions are checked in `WordmarkWorld.stepped()` on each frame.

### Pixel state machine (per WordmarkPixel)

```
Assembly path:
  [rubble] ──(carrier approaches)──▶ [inTransit] ──(deposit)──▶ [placed]

Erosion path:
  [placed] ──(carrier approaches)──▶ [inTransit] ──(deposit)──▶ [rubble]
```

`displayOpacity` is `~0.22` for rubble; `brandOpacity (0.70)` for inTransit and placed. Opacity change at deposit is immediate (SwiftUI animates the resulting opacity delta automatically).

### Frame step order (PhysicsCanvas)

```
TimelineView tick
  1. wordmarkWorld.stepped(bodies, dt, bounds)
     → updates carrier positions (seek motion, pickup/deposit)
     → assigns new carriers (up to max-3-active)
     → advances cycle phase
     → returns updatedBodies, newWordmarkWorld
  2. physicsWorld.stepped(updatedBodies, dt, bounds)
     → wall reflection for all bodies
     → ghost-ghost collision only for .drifting bodies
     → returns newPhysicsWorld
  3. Render: drifter pass (opacity 0.22) + rubble pass + placed pass + inTransit pass
```

---

## Implementation Units

- [ ] U1. **Wordmark glyph data and layout math**

**Goal:** Define the pixel-grid data for each letter in "GHOSTTIES" and provide a function that computes slot positions for a given wordmark bounding rect.

**Requirements:** R14, R15, R16, R17, R18, R19

**Dependencies:** None

**Files:**

- Create: `macos/Sources/Features/Ghostties/EmptyState/WordmarkGlyphs.swift`
- Test: `macos/Tests/Ghostties/WordmarkPhysicsTests.swift`

**Approach:**

- Define each letter as a compact `X`/`.` multiline string; parse into `[[Bool]]` via a file-local `parseGrid(_:)` (duplicate of `GhostCharacter.parseGrid`, 3 lines).
- All grids are the same row count (the implementation-time calibrated height, initially 8 rows).
- `WordmarkLayout` takes a `targetWidth: CGFloat` and returns: `brickSize: CGFloat`, `slotPositions: [CGPoint]` (one per filled pixel), `totalFilledPixels: Int`. Computes `brickSize = targetWidth / totalColumns`. Slots are computed as the top-left corner of each filled cell in the assembled wordmark rect, centered in the pane via an offset parameter.
- `WordmarkLayout.targetWidth(for paneWidth: CGFloat) -> CGFloat?` implements the R18 gate: `paneWidth * 0.6` clamped to `200...600`, returns `nil` if `paneWidth * 0.6 < 200`.
- No SwiftUI imports in this file — pure CoreGraphics math.

**Patterns to follow:**

- `GhostCharacter.swift`: `parseGrid`, `drawPath(in:)` for the grid-to-Path pattern.
- `PhysicsCollision.swift`: pure enum/struct with static functions, no SwiftUI.

**Test scenarios:**

- Happy path: `WordmarkLayout(targetWidth: 300)` produces `slotPositions.count == totalFilledPixels` and each slot is within the wordmark bounding rect.
- Happy path: slot positions are horizontally centered — leftmost slot x ≈ `(wordmarkWidth - totalColumns * brickSize) / 2` within tolerance.
- Edge case: `targetWidth(for: 300)` returns `300 * 0.6 = 180 < 200`, returns `nil`.
- Edge case: `targetWidth(for: 340)` returns `204`, not nil.
- Edge case: `targetWidth(for: 1200)` returns `600` (clamped).
- Happy path: pixel count is consistent — calling `WordmarkLayout` twice with the same input returns the same `slotPositions` (deterministic).

**Verification:**

- All slot positions lie within the expected bounding rect.
- `targetWidth(for:)` returns `nil` exactly at and below the 333 pt pane-width threshold (200 / 0.6).
- The letter grids for "GHOSTTIES" visually resemble the expected letterforms when printed as ASCII.

---

- [ ] U2. **WordmarkWorld pure model**

**Goal:** Implement the cycle state machine and pixel ownership logic as a pure value type that produces a new `WordmarkWorld` and updated ghost bodies each frame.

**Requirements:** R5, R6, R7, R8, R9, R10, R10b, R12

**Dependencies:** U1 (WordmarkLayout for slot positions)

**Files:**

- Create: `macos/Sources/Features/Ghostties/EmptyState/WordmarkWorld.swift`
- Modify: `macos/Sources/Features/Ghostties/EmptyState/PhysicsWorld.swift` (add `var role: GhostRole` to `GhostBody`; default `.drifting`)
- Test: `macos/Tests/Ghostties/WordmarkPhysicsTests.swift`

**Approach:**

- `GhostRole` enum (add to `PhysicsWorld.swift` adjacent to `GhostBody`):
  - `.drifting`
  - `.approaching(pixelIndex: Int)`
  - `.ferrying(pixelIndex: Int, targetPosition: CGPoint)`
- `WordmarkPixel` struct: `index: Int`, `slotPosition: CGPoint`, `rubblePosition: CGPoint`, `currentPosition: CGPoint`, `displayOpacity: Double`, `state: PixelState { rubble | inTransit(carrierId: UUID) | placed }`.
- `WordmarkCyclePhase` enum: `.assembling`, `.holding(elapsed: TimeInterval)`, `.eroding`.
- `struct WordmarkWorld`: `phase`, `pixels: [WordmarkPixel]`, `holdDuration: TimeInterval = 4.0`. The `stepped(bodies:dt:bounds:) -> (WordmarkWorld, [GhostBody])` function:
  1. Move carriers toward their targets (delegate to `WordmarkPhysics` — U3).
  2. Check pickup threshold → transition `approaching` → `ferrying`.
  3. Check deposit threshold → transition `ferrying` → `drifting`, update pixel state.
  4. Assign new carriers from drifting pool (up to `3 - activeCarrierCount`), per R10 probability gate.
  5. Advance cycle phase: assembling → holding if all pixels placed; holding → eroding if elapsed ≥ `holdDuration`; eroding → assembling if all pixels rubble.
  6. Return `(newWorld, updatedBodies)`.
- `WordmarkWorld.initial(layout:bounds:bodies:)` — static factory: scatters rubble positions randomly within `bounds` excluding the wordmark rect, assigns all ghosts `.drifting`.
- On cycle restart (eroding → assembling): re-scatter rubble positions for all pixels.

**Patterns to follow:**

- `PhysicsWorld.stepped(by:bounds:)` — pure value-type step returning a new world; frame-rate-independent `dt * 60` velocity scaling.
- `PhysicsWorld.initial(in:count:radius:)` — static factory with bounds guard.

**Test scenarios:**

- Happy path: `stepped()` with all 7 ghosts drifting and 3 unassigned pixels assigns exactly 3 carriers on the first eligible frame.
- R10b: `stepped()` with 3 carriers already active does not assign additional carriers regardless of available pixels.
- R10b: `stepped()` with 2 active carriers and 5 available pixels assigns exactly 1 more (cap at 3 total).
- Happy path: a carrier within deposit radius transitions to drifting; the pixel's `state` transitions to `.placed`; `displayOpacity` is set to `brandOpacity`.
- Happy path: cycle advances from `.assembling` to `.holding(elapsed: 0)` on the frame when the last pixel is deposited.
- Happy path: `.holding` advances elapsed each frame; transitions to `.eroding` when `elapsed >= holdDuration`.
- Happy path: `.eroding` transitions to `.assembling` when all pixels are `.rubble`; rubble positions are re-scattered (new random positions differ from hold-phase positions).
- Edge case: `initial(layout:bounds:bodies:)` with bounds too small for min wordmark width → `nil` (caller handles deactivation).
- Integration: `stepped()` returns updated bodies where carrier body positions have moved toward target; drifting body positions are unchanged by this function (movement applied later by PhysicsWorld).
- Covers AE1: after full assembly + hold, eroding phase is active and ~halfway through (pixel count check).

**Verification:**

- Max active carriers never exceeds 3 across 1000 consecutive `stepped()` calls with all pixels unassigned at start.
- Cycle phase sequence `assembling → holding → eroding → assembling` fires in order with correct guard conditions.

---

- [ ] U3. **Carrier physics: seek motion and collision exemption**

**Goal:** Implement the carrier seek/decelerate motion (approach and ferry phases) and teach `PhysicsCollision` to skip ghost-ghost collision for non-drifting bodies.

**Requirements:** R9, R10, R11

**Dependencies:** U2 (GhostRole, WordmarkWorld)

**Files:**

- Create: `macos/Sources/Features/Ghostties/EmptyState/WordmarkPhysics.swift`
- Modify: `macos/Sources/Features/Ghostties/EmptyState/PhysicsCollision.swift` (guard in `resolvePair`)

**Approach:**

- `WordmarkPhysics` (pure enum, no SwiftUI):
  - `seekStep(body: GhostBody, toward target: CGPoint, maxSpeed: CGFloat, dt: CGFloat) -> GhostBody` — sets velocity toward `target` at `min(distance / (dt * 60), maxSpeed)` px/frame; returns updated body with new position.
  - `isWithinRadius(_ body: GhostBody, of point: CGPoint, radius: CGFloat) -> Bool` — Euclidean distance check.
- In `PhysicsCollision.resolvePair(_:_:)`: add early return `guard lhs.role == .drifting, rhs.role == .drifting else { return (lhs, rhs) }`. Wall reflection in `reflectAgainstWalls(body:in:)` requires no change (applies to all bodies).
- `PhysicsWorld.stepped(by:bounds:)` — no structural change; the collision guard inside `resolvePair` is sufficient since carrier bodies will already have updated positions from `WordmarkWorld.stepped` by the time `PhysicsWorld.stepped` runs.

**Patterns to follow:**

- `PhysicsCollision.resolvePair(_:_:)` — guard-and-return pattern; no SwiftUI imports.
- Velocity scaling convention: velocities in px/frame at 60 fps, multiplied by `dt * 60`.

**Test scenarios:**

- Happy path: `seekStep` with body at (0,0) and target at (100,0), `dt=1/60`, `maxSpeed=1.3` → body moves 1.3 pt toward target.
- Happy path: `seekStep` with body 5 pt from target, `maxSpeed=1.3` → body moves ≤ 5 pt (decelerates, doesn't overshoot).
- Happy path: `seekStep` result body does not overshoot target (position x ≤ 100 in the above scenario).
- Edge case: `seekStep` with body already at target → velocity near zero, position unchanged within floating-point tolerance.
- Happy path (R11): `resolvePair` with one body `.approaching` and one `.drifting` → returns bodies unchanged (pass-through).
- Happy path (R11): `resolvePair` with both bodies `.drifting` → resolves collision normally (existing behavior preserved).
- Covers AE3: two ferrying ghosts on intersecting paths pass through each other without deflection.

**Verification:**

- A carrier seeking a target 200 pt away at `maxSpeed = 1.3` reaches the target within `ceil(200 / 1.3) = 154` frames.
- `resolvePair` with non-drifting bodies returns identical body positions and velocities.

---

- [ ] U4. **WordmarkRenderLayer: pixel rendering and proportional sizing**

**Goal:** Draw rubble, in-transit, and placed pixels using the established `Path.addRect` pattern; handle proportional sizing, min/max clamping, and the Reduce Motion static path.

**Requirements:** R13, R14, R15, R16, R17, R18, R19, R20

**Dependencies:** U1 (WordmarkLayout, slot positions), U2 (WordmarkPixel, displayOpacity)

**Files:**

- Create: (rendering logic lives inside `SurfaceEmptyStatePhysics.swift` as a private `WordmarkRenderLayer` view, or as rendering functions called from `PhysicsCanvas`; prefer inline private struct to avoid a new file for a pure rendering concern)
- Modify: `macos/Sources/Features/Ghostties/EmptyState/SurfaceEmptyStatePhysics.swift`

**Approach:**

- Inside the `if wordmarkEnabled` branch (added in U5), add a rendering pass after the ghost pass:
  - Build `rubblePath`: `path.addRect(brickRect(for: pixel.currentPosition))` for each `.rubble` pixel.
  - Build `placedPath`: same, for each `.placed` pixel.
  - Build `inTransitPath`: same, for each `.inTransit` pixel.
  - `rubblePath.fill(Color.secondary.opacity(0.22))`
  - `placedAndInTransitPath.fill(Color.primary.opacity(brandOpacity))` — both use brand opacity per R12.
  - `brickRect(for point:)` = `CGRect(x: point.x, y: point.y, width: brickSize, height: brickSize)` centered on the point.
- **Proportional sizing**: inside `GeometryReader`, compute `let wordmarkWidth = WordmarkLayout.targetWidth(for: geo.size.width)`. If `nil`, render only the ghost drift pass (Phase A). Otherwise compute `brickSize` and pass to `WordmarkWorld`.
- **Reduce Motion static path** (R20): in the `reduceMotion` branch inside `SurfaceEmptyStatePhysics`, after the static ghost arrangement, add a static wordmark render: compute slot positions via `WordmarkLayout`, fill all slots at brand opacity with no animation. No rubble, no carriers, no `WordmarkWorld`.
- **Color tokens**: use `Color.primary`, `Color.secondary`, `Color(.label)`, or semantic SwiftUI colors only. No hardcoded hex values, no terracotta.
- **No individual pixel views**: single `Path` per opacity tier, rendered with `.fill()`. No `ForEach` over pixel views.

**Patterns to follow:**

- `GhostCharacter.drawPath(in:)` — `path.addRect` loop, single fill call.
- `GhostCharacterView` — `GeometryReader` + `path.fill(color)`.
- Phase A's `ZStack { ... }.opacity(0.22)` — opacity applied at layer level, not per-element.

**Test scenarios:**

- Test expectation: none — rendering logic is visual. Cover the sizing math in U1 unit tests. Verify visually per Verification below.

**Verification:**

- With a 500 pt wide pane: wordmark renders at ~300 pt wide, centered, with pixels visually aligned to the 12×12 ghost pixel scale.
- With a 300 pt wide pane: wordmark renders at ~180 pt wide — falls below 200 pt minimum → Phase C does not activate; Phase A drift continues normally. Covers AE4.
- Reduce Motion on: wordmark renders fully assembled and motionless at brand opacity. No rubble visible. Covers AE5.
- Terracotta does not appear in any pixel render call — confirmed by grep for `#C97350`, `waitingTerracotta`, `C97350`.

---

- [ ] U5. **SurfaceEmptyStatePhysics integration: @AppStorage guard, wordmark branch, resize reset**

**Goal:** Wire `WordmarkWorld` into the existing `PhysicsCanvas` frame loop; add the `@AppStorage` hidden-config guard; handle pane-resize cycle reset (R21) and the activation threshold (R18).

**Requirements:** R1, R2, R3, R5, R21

**Dependencies:** U2 (WordmarkWorld), U3 (carrier physics), U4 (rendering)

**Files:**

- Modify: `macos/Sources/Features/Ghostties/EmptyState/SurfaceEmptyStatePhysics.swift`

**Approach:**

- Add `@AppStorage("ghostties.emptyStatePhysics.wordmark") private var wordmarkEnabled = false` to `SurfaceEmptyStatePhysics` (or `PhysicsCanvas`).
- In `PhysicsCanvas`:
  - Add `@State private var wordmarkWorld: WordmarkWorld? = nil` — `nil` when Phase C is inactive.
  - In the frame step (`DispatchQueue.main.async` block):
    1. Compute `wordmarkWidth` via `WordmarkLayout.targetWidth(for: bounds.width)`.
    2. If `wordmarkEnabled && wordmarkWidth != nil`:
       - If `wordmarkWorld == nil` (first activation or pane resize): `wordmarkWorld = WordmarkWorld.initial(...)`. Re-initialize rubble scatter.
       - Call `(newWordmarkWorld, updatedBodies) = wordmarkWorld!.stepped(bodies: world.bodies, dt: dt, bounds: bounds)`.
       - Set `worldmarkWorld = newWordmarkWorld`, `world.bodies = updatedBodies`.
       - Then call `world = world.stepped(by: dt, bounds: bounds)` (Phase A, carrier-collision-exempt).
    3. If `wordmarkEnabled && wordmarkWidth == nil`: `wordmarkWorld = nil` (pane too small).
    4. If `!wordmarkEnabled`: `wordmarkWorld = nil`.
  - **Resize reset (R21)**: `wordmarkWorld` is already `@State` inside a `GeometryReader`-driven view. When `bounds` changes, detect via `onChange(of: bounds.size)` and set `wordmarkWorld = nil` to force re-initialization on the next frame.
  - Dismount remains unchanged (Phase A): the `if isEmpty` branch gates the entire `PhysicsCanvas`, so `wordmarkWorld` is deallocated with the view (R3).

**Patterns to follow:**

- Existing `@State private var world: PhysicsWorld` — same pattern for `wordmarkWorld`.
- Existing `DispatchQueue.main.async { ... }` tick deferral — Phase C state updates go in the same block.

**Test scenarios:**

- Test expectation: none — integration behavior is verified visually and through the unit tests in U2/U3.

**Verification:**

- With `wordmarkEnabled = false`: no rubble pixels visible, no wordmark assembles; Phase A behavior unchanged.
- With `wordmarkEnabled = true` and pane ≥ 334 pt wide: rubble appears on first frame; cycle begins.
- Type any character mid-cycle: layer fades out within 250 ms, no further frame work. Covers AE2.
- Resize pane during assembly: cycle resets (rubble re-scatters, partial assembly disappears). Covers R21.
- Split pane (⌘D): each new empty pane initializes its own independent `PhysicsCanvas` and `WordmarkWorld`; active pane has no physics overhead.

---

- [ ] U6. **Unit tests: WordmarkPhysicsTests**

**Goal:** Cover the new pure-logic units with focused tests following the established `EmptyStatePhysicsTests` pattern.

**Requirements:** All (verification harness)

**Dependencies:** U1, U2, U3

**Files:**

- Create: `macos/Tests/Ghostties/WordmarkPhysicsTests.swift`

**Approach:**

- `@testable import Ghostty`, `import CoreGraphics` only. No SwiftUI in this file.
- Helper functions: `makeWordmarkPixel(index:at:slot:state:)`, `makeDriftingBody(at:)`, `makeCarryingBody(at:toward:)`.
- Tests grouped by type: WordmarkLayout math, WordmarkWorld cycle phases, carrier cap enforcement, WordmarkPhysics seek motion, collision exemption.
- Mirror the `eps: CGFloat = 1e-6` accuracy convention from `EmptyStatePhysicsTests`.

**Test scenarios (all should be greenfield XCTest cases):**

- **WordmarkLayout**:
  - Threshold: `targetWidth(for: 333)` returns nil; `targetWidth(for: 334)` returns non-nil.
  - Clamping: `targetWidth(for: 1200)` ≤ 600.
  - Slot count: `slotPositions.count == totalFilledPixels` for a known test glyph.
  - Centering: first slot x ≥ 0; last slot x ≤ `wordmarkWidth`; midpoint of all x coords ≈ `wordmarkWidth / 2`.
- **WordmarkWorld carrier cap (R10b)**:
  - Stepped with 0 carriers, 10 unassigned pixels: exactly 3 carriers assigned after step.
  - Stepped with 3 carriers, 10 unassigned pixels: 0 additional carriers assigned.
  - Stepped with 2 carriers, 0 unassigned pixels: 0 additional carriers assigned.
- **WordmarkWorld cycle phase**:
  - All pixels placed → phase transitions to `.holding` on next step.
  - Hold elapsed ≥ holdDuration → phase transitions to `.eroding`.
  - All pixels rubble → phase transitions to `.assembling`; rubble positions differ from slot positions.
- **WordmarkWorld pixel state**:
  - Carrier within deposit radius → pixel transitions from `.inTransit` to `.placed`; `displayOpacity == brandOpacity`.
  - Erosion phase deposit → pixel transitions from `.inTransit` to `.rubble`; `displayOpacity` drops to rubble opacity.
- **WordmarkPhysics seek motion**:
  - Body 100 pt from target at maxSpeed 1.3 → moves exactly 1.3 pt toward target.
  - Body 0.5 pt from target → does not overshoot (final position ≤ target ± eps).
  - Body at target → position unchanged within eps.
- **Collision exemption (R11)**:
  - `resolvePair` with one `.approaching` body and one `.drifting` body → velocities unchanged.
  - `resolvePair` with both `.drifting`, overlapping, head-on → velocities swapped (existing behavior).
  - Covers AE3.

**Verification:**

- `swift test` (or ⌘U in Xcode) passes all new tests with zero failures.
- No new `import SwiftUI` in `WordmarkPhysicsTests.swift` — pure CoreGraphics only.

---

## System-Wide Impact

- **Interaction graph:** `SurfaceEmptyStatePhysics` → `PhysicsCanvas` → `WordmarkWorld` + `PhysicsWorld` in sequence each frame. `SurfaceView.swift` untouched (Phase C is entirely within the existing Phase A view hierarchy). Upstream `GhosttyKit` untouched.
- **Error propagation:** `WordmarkWorld.initial` returns `nil` on undersized bounds; caller (`PhysicsCanvas`) treats nil as Phase C inactive — Phase A drift continues. No unchecked optionals at render time.
- **State lifecycle risks:** `wordmarkWorld` is `@State` scoped to `PhysicsCanvas`, which dismounts inside the `if isEmpty` branch. No state persists when the pane becomes active. No serialization. `wordmarkWorld = nil` on resize is the full reset.
- **API surface parity:** `SurfaceView.swift` ZStack is unchanged. No public API added. `@AppStorage` key `"ghostties.emptyStatePhysics.wordmark"` is the only new persistent surface.
- **Integration coverage:** Visual smoke test is the primary integration check — unit tests cover pure logic; the full cycle (rubble → assembly → hold → erosion → repeat) must be verified manually on the live build.
- **Unchanged invariants:** Phase A fade-on-output behavior (250 ms `.easeOut`) is untouched. `allowsHitTesting(false)` remains. `TimelineView` dismount-on-dismiss pattern is preserved. `GhostCharacter` and `GhostCharacterView` are not modified.

---

## Risks & Dependencies

| Risk                                                                                                                                 | Mitigation                                                                                                                                                         |
| ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Pixel count too high for 30–45 s cycle at 3 carriers                                                                                 | Calibrate in U1: target 120–180 filled pixels; adjust letter height/width or inter-letter spacing until pacing fits                                                |
| Carrier seek creates frenetic motion (carrier count × speed feels busy)                                                              | Start with per-frame probability gate of 15–20% per drifting ghost for carrier assignment (R10 precedent from Phase A interaction probability); tune on live build |
| Brick size misalignment with ghost pixel grid produces visible seam                                                                  | Verify `brickSize ≈ ghostRadius * 2 / 12` at target pane width during implementation; adjust if jarring                                                            |
| `DispatchQueue.main.async` back-pressure with two sequential world steps                                                             | Monitor with Xcode Instruments Time Profiler on idle pane; if frame drops appear, merge the two step calls into one coordinated function                           |
| `PhysicsWorld.stepped` and `WordmarkWorld.stepped` called sequentially sharing `world.bodies` array could cause subtle ordering bugs | Enforce in code review: `WordmarkWorld.stepped` returns a new bodies array; `PhysicsWorld.stepped` receives that array as input — never the other direction        |
| `parseGrid` duplication in `WordmarkGlyphs.swift` drifts from `GhostCharacter.swift`                                                 | Function is 3 lines; add a comment pointing to the origin. If `GhostCharacter.parseGrid` is ever made `internal`, consolidate then                                 |
| Reduce Motion path renders assembled wordmark but `WordmarkLayout` not yet initialized                                               | `reduceMotion` branch computes `WordmarkLayout` inline (no `wordmarkWorld` state needed) — pure function call, no lifecycle dependency                             |

---

## Documentation / Operational Notes

- The `@AppStorage("ghostties.emptyStatePhysics.wordmark")` key is undocumented by design (easter egg). No changelog entry needed for Phase C ship.
- After Phase C ships on the experiment branch, verify with Xcode Instruments → CPU Profiler that an active (non-empty) pane shows zero CPU from the empty-state layer (TimelineView dismount regression test).
- Phase B (drag/throw/tap) remains queued; its `.allowsHitTesting` change will interact with Phase C's carrier render layer — note in Phase B planning that Phase C pixel hit areas must remain non-interactive.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-05-13-phase-c-archaeology-requirements.md](docs/brainstorms/2026-05-13-phase-c-archaeology-requirements.md)
- Phase A base: `macos/Sources/Features/Ghostties/EmptyState/` (all 3 files)
- Pattern source: `macos/Sources/Features/Ghostties/Models/GhostCharacter.swift` — `parseGrid`, `drawPath`
- Pattern source: `macos/Sources/Features/Ghostties/GhostCharacterView.swift` — GeometryReader + Path.fill
- Pattern source: `macos/Sources/Features/Ghostties/PixelChevronView.swift` — pixel struct + Path rendering
- Test pattern: `macos/Tests/Ghostties/EmptyStatePhysicsTests.swift`
