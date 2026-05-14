---
date: 2026-05-13
topic: phase-c-wordmark
focus: Visual direction for Ghostties empty-state Phase C — GHOSTTIES wordmark Breakout wall
mode: repo-grounded
---

# Ideation: Phase C Wordmark Direction

## Grounding Context

**Codebase context.** Phase A of the empty-state physics layer shipped 2026-05-13 on `experiment/empty-state-physics` (commit `f27a82dc9`): ambient ghost drift with elastic collisions and wall reflection, behind the Metal terminal surface, dismissing on first PTY output. Phase C is a stretch goal: render the **GHOSTTIES** wordmark in the empty pane as a Breakout-style brick wall that the existing drifting ghosts chip away at, then reassemble. Hidden config, off by default.

**Aesthetic posture.** Bold-content, restrained chrome, terracotta accent **reserved for activity state**. Tokens: chrome `#F0E9E6/#242424`, canvas `#FAF7F3/#2D2D2D`, terracotta `#C97350` (off-limits for this feature). Pixel-grid Mac UI, no anti-aliasing, no gradients, no shadows outside the terminal card. Tool-not-game; retro Mac, not arcade.

**Pacing.** Ambient drift 0.22–0.40 px/frame, max ambient 0.6, max chase 1.3. Autonomous interactions ~15–20% probability. User-initiated may be punchy. Must not compete with the terminal — entire layer fades on first PTY output.

**Prior art.** Codrops stagger reveal (~14ms stagger, ~500ms per letter, Power3 easing); bijanbwb Breakout particle pattern (opacity-fade brick degradation gentler than instant removal); Slynyrd 12×12 pixel-brick precedent; macOS Aerial screensaver as calm-system-motion reference. Demoscene/arcade aesthetics are explicitly inverted.

**Past learnings.** `GeometryReader + Path.fill()` is the established pixel-art rendering pattern. Reduce-motion respect mandatory. Metal terminal sits behind SwiftUI overlays — no fight for the canvas. No prior brick/Breakout work in this codebase.

## Ranked Ideas

### 1. Archaeology / Patient Restoration **— Selected for brainstorm**

**Description:** Inverts the destruction loop. The wall starts fully chipped — pixel rubble scattered around the canvas. Drifting ghosts patiently _deposit_ pixels back into letter positions as they pass through, slowly assembling GHOSTTIES over ~45 seconds. Once whole, the wall begins eroding again at ambient pace, ghosts picking pixels back up. No "destruction event" or "reassembly event" — one continuous patient cycle, paced entirely by ghost drift.

**Rationale:** Tool-not-game posture maxed out. No arcade dopamine, no reset moment, no game mechanic at all — just slow accumulation. Most "high-trust empty state" of the candidates (Stripe/Linear instinct). Ghosts become coworkers, not bullets. Pairs cleanly with the established physics — the ambient drift IS the animation system.

**Downsides:** Slow. First-time viewer may not realize anything is happening or that the wordmark will ever appear. The "appearance moment" loses spectacle. Hard to design a satisfying "fully assembled" beat without violating calm-by-default.

**Confidence:** 78% · **Complexity:** Low-to-Medium · **Status:** Explored

### 2. Hidden Command — `~ $ ghostties`

**Description:** Wordmark is the literal prompt rendered in SF Mono at brick-scale (5×7 brick glyphs aligned to 4pt grid). Ghosts chip the prompt; reassembly is a TTY draw — character-by-character left-to-right at ~80ms cadence. Cursor blink preserved as the only "alive" element while whole.

**Rationale:** Most on-brand. Reframes the wordmark as a terminal-native artifact rather than a logo placement. Zero new typography. TTY-draw reassembly is conceptually correct — a terminal renders text by writing it.

**Downsides:** Loses the "wordmark as identity" beat. Some users may parse it as instructional ("type this!"). Mitigated by ambient layer dismissing on keystroke.

**Confidence:** 80% · **Complexity:** Medium · **Status:** Unexplored

### 3. Negative-Space Cut-Out

**Description:** Chrome plate covers the pane; GHOSTTIES is a hole punched through it. Ghosts drift behind, visible only through the letterform openings. Collisions chip the plate around the wordmark, gradually revealing more visible drift area. Full chip = whole plate gone = pane fully empty. Reassembly snaps the plate back over 250ms stagger.

**Rationale:** Inverts destruction into revelation. Single visual idea drives the entire system. Strongest pure-Mac restraint. Uses only chrome + canvas tokens.

**Downsides:** Heavyweight visual element may compete with the terminal title bar / chrome on first impression. Reassembly snap may feel abrupt. Initial solid plate may read as a load screen.

**Confidence:** 75% · **Complexity:** Medium · **Status:** Unexplored

### 4. Sub-Pixel Erosion Field

**Description:** No bricks. Wordmark rendered as ~10,000 quarter-point pixel cells (4× finer than the 4pt grid). Ghost collisions don't smash bricks — they sand off dust, one or two sub-pixel cells per pass. From normal viewing distance you see the wordmark slowly fading; up close it's pixel weather. Full erosion takes minutes. Reassembly is a single sub-pixel stagger from the centroid outward (~400ms).

**Rationale:** Texture-led restraint. The aesthetic claim is "this is not a game, this is geology." Distinguishes from any other terminal empty state. Premium-grade craft.

**Downsides:** May be too subtle — if users never notice degradation, the feature has no signal. 10k cells stretches `Path` performance. Hard to make ghosts feel "agentful" when their effect is sub-perceptual per collision.

**Confidence:** 70% · **Complexity:** Medium-High · **Status:** Unexplored

### 5. Density Gradient — No Glyphs (RADICAL)

**Description:** Eliminate the wordmark as a discrete element. Ambient ghosts bias their drift to congregate in letter silhouettes. From the right distance, silhouette is legible; up close, just ghosts being ghosts. The "Breakout mechanic" disappears too. Phase C dissolves into Phase A as "more intentional ghost flocking."

**Rationale:** Maximally restrained. Phase C stops being a separate feature. Recognition lives at the edge of legibility.

**Downsides:** No interactive moment. May be invisible. Hardest to make satisfying without overdoing the flocking force.

**Confidence:** 65% · **Complexity:** Low · **Status:** Unexplored

### 6. Long-Session Ritual — Patina Across Launches (overlay)

**Description:** Orthogonal to mechanic choice. Wall chip state persists in UserDefaults across Ghostties sessions. Each launch the ghosts pick up where they left off; full reassembly happens only once every ~week. Same brick primitive doubles as the first-launch onboarding hero. Identity moment compounds across sessions. Can layer over any of #1–4.

**Rationale:** Pure compound-engineering posture. One primitive, three use-cases. Ties feature to actual usage rather than a screensaver.

**Downsides:** Adds privacy/state surface. Users who never close Ghostties never see reassembly. Weekly timing is opaque.

**Confidence:** 82% · **Complexity:** Low (incremental over any chosen mechanic) · **Status:** Unexplored

## Rejection Summary

| #                                                | Idea                                                       | Reason Rejected |
| ------------------------------------------------ | ---------------------------------------------------------- | --------------- |
| Mortar gaps not borders                          | Table-stakes detail; folds into any chosen direction       |
| Two-value brick palette                          | Table-stakes constraint already in the brief               |
| Gravity-drop reassembly                          | Implementation choice, not a direction                     |
| Drift accel through cleared zones                | Too subtle to perceive; physics tell ≠ design direction    |
| Ghost vector deflects toward erosion             | Clever but obscure; users won't read it                    |
| First-pane-only fades on focus                   | Implementation detail, not a direction                     |
| Wordmark as ghost-mass dissolving                | Overlaps with Density Gradient (purer expression)          |
| Earned reveal via collision counter              | Rules out the everyday case; users would miss it           |
| Debossed shadow, ghost-lit                       | Below legibility floor; too subtle to land                 |
| Chipped letters fill with PTY text               | Surprises user by tying ornament to typed output           |
| Surviving ghosts rebuild                         | Folded into Archaeology                                    |
| Fallen brick becomes ghost                       | Population mechanic = scope creep                          |
| Pixel-cluster letterforms                        | Table-stakes detail; folds into chosen direction           |
| ASCII compile reveal                             | Folded into Hidden Command (the TTY-draw beat)             |
| Ligature decomposition                           | Too clever; reads as costume more than system              |
| Prompt line at bottom                            | Overlaps Hidden Command but loses centered identity moment |
| BrickGrid primitive (and 7 other compound moves) | Execution choices, not aesthetic directions                |
| Carved in stone                                  | Overlaps Archaeology                                       |
| Music box cylinder                               | Folded into Archaeology pacing                             |
| Scriptio continua                                | Adds typographic vocabulary not in the system              |
| Phototropic lean                                 | Too subtle to perceive                                     |
| Punch-card cycle                                 | Reads as costume; conceptually cool, visually busy         |
| Suminagashi disturbance                          | Hard to render tastefully at pixel-grid scale              |
| Knitted wordmark                                 | Analogy without distinctive visual claim                   |
| Lichtenberg regrowth                             | Beautiful but visually busy; competes with terminal        |
| Patient stonemason 30s/brick                     | Folded into Long-Session Ritual                            |
| One brick per letter (8 total)                   | Too sparse; no granularity for ghost interactions          |
| Invisible until struck                           | Overlaps Negative-Space                                    |
| Sisyphean wall                                   | No perceivable arc; effectively invisible                  |
| Opacity-tint chipping                            | Weaker version of Sub-Pixel Erosion                        |
| Audio-only demolition                            | Provocative but abandons the visual feature                |
| Drag-a-ghost-onto-a-letter types it              | Belongs in Phase B (drag mechanic), not Phase C aesthetic  |
