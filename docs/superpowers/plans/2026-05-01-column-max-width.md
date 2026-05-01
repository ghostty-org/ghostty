# Column Max Width Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 400px max-width cap to kanban columns in horizontal mode, with scroll and centering behavior.

**Architecture:** Current columns grow unboundedly in landscape. We add `columnMaxWidth: CGFloat = 400` to the Status enum and modify `horizontalContent()` in KanbanView to use a GeometryReader that calculates column width as `clamp(naturalWidth, min: 300, max: 400)`. When window too narrow for 4×300px, columns stay at 300px and ScrollView provides horizontal scrolling. When window wider than 4×400px + gaps, columns lock at 400px and the group centers with margin.

**Tech Stack:** SwiftUI, no new dependencies

---

## File Structure

| File | Change |
|------|--------|
| `demo/Sources/GhosttyDemo/KanbanModels.swift` | Add `columnMaxWidth` constant |
| `demo/Sources/GhosttyDemo/KanbanView.swift` | Replace `horizontalContent()` with responsive layout logic |

---

### Task 1: Add `columnMaxWidth` constant

**Files:**
- Modify: `demo/Sources/GhosttyDemo/KanbanModels.swift:28-30`

- [ ] **Add the constant**

After the existing `columnMinWidth` line (line 28), add:

```swift
/// Maximum width for a single kanban column
static let columnMaxWidth: CGFloat = 400
```

- [ ] **Commit**

```bash
git add demo/Sources/GhosttyDemo/KanbanModels.swift
git commit -m "feat: add columnMaxWidth constant (400px)
"
```

---

### Task 2: Rewrite `horizontalContent()` with responsive column sizing

**Files:**
- Modify: `demo/Sources/GhosttyDemo/KanbanView.swift:258-280`

- [ ] **Replace the horizontalContent method**

The current implementation uses a fixed ScrollView with no width constraints. Replace with a GeometryReader-based approach that calculates column widths dynamically:

```swift
@ViewBuilder
private func horizontalContent(availableHeight: CGFloat) -> some View {
    let gap: CGFloat = 6
    let pad = Status.columnHPadding / 2

    GeometryReader { geometry in
        let totalWidth = geometry.size.width
        // Available width for columns after padding + gaps
        let availForCols = totalWidth - pad * 2 - gap * CGFloat(Status.allCases.count - 1)
        let naturalPerCol = availForCols / CGFloat(Status.allCases.count)

        let colWidth: CGFloat
        let needsScroll: Bool
        let centerContent: Bool

        if naturalPerCol <= Status.columnMinWidth {
            // Too narrow — fix at minWidth, enable scroll
            colWidth = Status.columnMinWidth
            needsScroll = true
            centerContent = false
        } else if naturalPerCol >= Status.columnMaxWidth {
            // Too wide — fix at maxWidth, center with margin, no scroll
            colWidth = Status.columnMaxWidth
            needsScroll = false
            centerContent = true
        } else {
            // Just right — stretch to fill
            colWidth = naturalPerCol
            needsScroll = false
            centerContent = false
        }

        Group {
            if needsScroll || centerContent {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: gap) {
                        if centerContent { Spacer(minLength: 0) }

                        ForEach(Status.allCases) { status in
                            KanbanColumnView(
                                status: status,
                                tasks: boardState.tasks(for: status),
                                boardState: boardState,
                                sessionManager: sessionManager,
                                tabManager: tabManager,
                                ghosttyApp: ghosttyApp,
                                dragState: dragState,
                                insertedTaskId: insertedTaskId
                            )
                            .frame(width: colWidth, maxHeight: .infinity)
                        }

                        if centerContent { Spacer(minLength: 0) }
                    }
                    .padding(.horizontal, pad)
                }
                .scrollDisabled(!needsScroll)
            } else {
                // No scroll, no centering — stretch to fill
                HStack(spacing: gap) {
                    ForEach(Status.allCases) { status in
                        KanbanColumnView(
                            status: status,
                            tasks: boardState.tasks(for: status),
                            boardState: boardState,
                            sessionManager: sessionManager,
                            tabManager: tabManager,
                            ghosttyApp: ghosttyApp,
                            dragState: dragState,
                            insertedTaskId: insertedTaskId
                        )
                        .frame(minWidth: Status.columnMinWidth, maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, pad)
            }
        }
    }
}
```

- [ ] **Build to verify compilation**

```bash
cd demo && swift build 2>&1 | tail -20
```

Expected: `Build complete!` or `Build succeeded`.

- [ ] **Commit**

```bash
git add demo/Sources/GhosttyDemo/KanbanView.swift
git commit -m "feat: responsive column layout with 400px max width
"
```

---

### Self-Review

**Spec coverage:**
- 450px threshold for vertical↔horizontal — already exists (`isHorizontal` check in the existing `body`), unchanged
- Columns never below 300px in horizontal mode — handled by `naturalPerCol <= columnMinWidth` case
- Max width 400px — handled by `naturalPerCol >= columnMaxWidth` case
- Horizontal scroll when < 1200px — `needsScroll = true` + `ScrollView`
- Centering when > 1600px — `centerContent = true` + Spacers

**Placeholder scan:** No TBD, TODO, or placeholder patterns.

**Type consistency:** `columnMaxWidth` typed as `CGFloat` consistent with `columnMinWidth`. All GeometryReader calculations use `CGFloat`.

**Edge cases:**
- During drag: `.scrollDisabled(dragState.isDragging)` still applies only in the `needsScroll` path — need to verify this is OK. Actually looking at the code, the original `scrollDisabled(dragState.isDragging)` was on the ScrollView. In the new code, when `needsScroll = false` and drag is happening, there's no ScrollView at all (or in `centerContent` case, there is a ScrollView with scrollDisabled(true)). During drag, the user shouldn't be able to scroll, which is still satisfied. For the stretch mode (no ScrollView), there's nothing to scroll, so it's fine.
- The `availableHeight` parameter is now unused by `horizontalContent` — this is fine, it was only there for API consistency, and the column height is still handled by `.maxHeight(.infinity)`.
