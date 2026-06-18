I have confirmed all the line references and code paths. The findings are consistent with the source. Now I'll synthesize the consolidated report.

# Sidebar Spaces — Consolidated Review

All line references verified against the current `sidebar-spaces` HEAD. The dominant theme: **space-lifecycle mutations happen synchronously and optimistically, but tab closes are asynchronous and cancellable**, and **multiple close paths each implement their own rules** rather than converging on one. Fixing the architecture (Section B) eliminates most of the bugs in Section A at once.

---

## Section A — Bugs / weird flows (severity order)

### A1. Pre-remove-before-async-close orphans a tab into a deleted space (sidebar X / context "Close Tab")
- **Where:** `TerminalSidebarView.swift:289–292` (`close()`), interacting with `SpacesModel.sync():34–41`.
- **Repro:** Sidebar mode, two spaces. Space B has exactly one tab running a process that triggers confirm-quit (e.g. `vim`). Switch to B, click the sidebar X. The "Close Tab?" sheet appears — click **Cancel**.
- **Root cause:** `close()` calls `spaces.removeSpace(spaceID)` synchronously (line 290) *then* `rawClose(window)` → `closeTab(nil)`, which is async/cancellable (`confirmClose` in `BaseTerminalController`). On Cancel the window survives but the space is already gone; `assignments[window]` still points at the deleted id. `sync()` only prunes *dead* windows and only fills *unassigned* ones — it never re-points a live window whose space no longer exists, and `reconcileActiveSpace`→`setActive` no-ops on the unknown id (`SpacesModel.swift:118`). Tab is permanently invisible in every sidebar, reachable only via ⌘1-9. Permanent session state divergence.
- **Minimal fix:** Do not mutate space state before the close commits. Remove the `removeSpace` call from `close()` entirely and make empty-space removal a model invariant in `syncSpaces` (see B1) — that path runs only after the window is actually gone.

### A2. Standalone→tabbed model-migration race silently wipes user-created spaces
- **Where:** `TerminalSpacesStore.swift:22–42` (`model(for:)`); consumed at `TerminalView.swift:107`.
- **Repro:** Sidebar mode, single standalone window. Create "Space 2" via the switcher `+`. Click the header `+` to add a tab. Sometimes the sidebar resets to a single default "Space 1" and Space 2 is gone.
- **Root cause:** A standalone window's model is keyed by the window itself. When it gains its first tab, parent A and new child B share one `NSWindowTabGroup`. `model(for:)` migrates the orphaned per-window model **only for the specific window passed in**. B has no standalone model, so if B's `terminalLayout` evaluates first (likely — B is made key/front), `model(for: B)` finds no tab-group model and no B-keyed model and calls `makeModel(forKey: tabGroup)` → fresh empty "Space 1". A's model (with the user's spaces) is orphaned and evicted from the weak `NSMapTable`. Order-dependent and realistic. Same mechanism makes `mergeAllWindows` keep only one window's spaces, nondeterministically (A8).
- **Minimal fix:** Make migration order-independent. In `model(for:)`, when no tab-group model exists, scan **all** `window.tabGroup.windows` for an existing per-window model and migrate the best candidate (prefer `tabGroup.selectedWindow`'s, and/or a non-default one) to the tab-group key before falling back to `makeModel`.

### A3. deleteSpace removes the space before per-tab async closes — Cancel orphans / silently re-homes surviving tabs
- **Where:** `TerminalSidebarView.swift:336–344` (`deleteSpace`); `SpacesModel.removeSpace:102–110` (leaves `assignments` untouched).
- **Repro:** Two spaces; Space A has a tab running a process. Right-click A → Delete Space → confirm. When the per-tab "Close Tab?" sheet appears, click **Cancel**.
- **Root cause:** Same shape as A1: `removeSpace(id)` (line 338) runs before the `closeTab(nil)` loop (lines 339–341). A cancelled per-tab close leaves a live window assigned to the deleted space. The next `sync()` then either keeps the dangling assignment (invisible tab) or, because the assignment is to a now-nonexistent id, the window is treated inconsistently. The "This will close N tabs" alert also misleads, because each tab can still individually refuse.
- **Minimal fix:** Close tabs first, remove the space only after all closes commit — or fold deletion into the same post-close reconcile as B1. For the already-confirmed delete-space flow, close tabs without re-prompting (use `closeTabImmediately()` / a single batched confirm), see A6.

### A4. Deleting the only space silently nukes the whole window
- **Where:** `deleteSpace:336–344` (return of `removeSpace` ignored at 338); Delete button always enabled at `SpaceSwitcherBar:688`; last-space guard at `SpacesModel.swift:103`.
- **Repro:** One space ("Space 1") with one or more tabs. Right-click the icon → Delete Space → confirm. All tabs close and the window disappears.
- **Root cause:** `removeSpace` refuses the last space (`guard spaces.count > 1`, returns `false`), but `deleteSpace` discards the return (`@discardableResult`) and unconditionally closes every tab. Closing the last tab routes `closeTab`→`closeWindow`, destroying the window. The model still claims the space exists at the moment of destruction.
- **Minimal fix:** Add `.disabled(spaces.spaces.count <= 1)` to the Delete button (line 688), mirroring the "Move to Space" guard at line 102; and/or have `deleteSpace` bail (close nothing) when `spaces.removeSpace(id)` returns `false`.

### A5. Native ⌘W / split-root close on the last tab of a space leaves a ghost empty space
- **Where:** Space removal lives only in `close():289–291`; native ⌘W (`TerminalController.closeTab`) and split-root close (`closeSurface`→`closeTab`) bypass it. `SpacesModel.sync:34–41` never removes empty spaces.
- **Repro:** Two spaces, A active with one tab. Press ⌘W. The front jumps to B (active follows correctly), but A's icon lingers in the switcher pointing at an empty space. Doing the same via the sidebar X removes A — **same user action, two outcomes**.
- **Root cause:** "Remove a space when its last live tab goes away" is a caller responsibility in one of four close paths instead of a model invariant. `sync()` prunes the dead window's assignment but never drops the now-empty space.
- **Minimal fix:** Make it a model invariant (B1): after `sync()` prunes assignments, remove any **non-active** space with zero live windows (keep ≥1 space). Then delete the `removeSpace` call in `close()` — it becomes redundant. This converges ⌘W, split-close, and sidebar X, and also fixes A1.

### A6. Sidebar bulk-close (Close Other / Close Tabs Below / Delete Space) stacks one confirm sheet and one undo per tab
- **Where:** `closeOtherTabs:304–309`, `closeTabsBelow:313–318`, `deleteSpace:339–341` — each loops `rawClose`→`closeTab(nil)`.
- **Repro:** Active space with 3 tabs each running `vim`. Right-click first → "Close Other Tabs". Two separate "Close Tab?" sheets appear instead of one combined prompt; undo restores one tab at a time.
- **Root cause:** Each `closeTab` shows its own per-controller confirm (`confirmCloseAsync`'s `alert == nil` guard is per-instance) and registers its own undo. The native `closeOtherTabs`/`closeTabsOnTheRight` pre-flight all tabs, show ONE confirm, and wrap closes in a single undo group (`closeOtherTabsImmediately`).
- **Minimal fix:** Batch one confirm up front across the targeted (space-filtered) windows, then `closeTabImmediately()` inside one `beginUndoGrouping`/`endUndoGrouping`. Where the active space == whole tab group, just delegate to the native controller method. (Folds into B2.)

### A7. Native "Close Other Tabs" / "Close Tabs to the Right" are space-blind
- **Where:** `TerminalController.closeOtherTabsImmediately:719–742`, `closeTabsOnTheRightImmediately:768–785` iterate the entire `tabGroup.windows` with no space filter; reachable via app menu / keyboard even though the native tab-bar context menu is hidden in sidebar mode.
- **Repro:** Sidebar mode, Space A active, Space B has tabs. Trigger app-menu/keyboard "Close Other Tabs". B's tabs (invisible in the sidebar) also close.
- **Root cause:** Two divergent implementations of the same command; the native one knows nothing about spaces. Silent loss of tabs the user can't see; "to the Right" also uses native order, not sidebar order.
- **Minimal fix:** When `macos-tab-bar-location == .left`, have these IBActions consult the `SpacesModel` and skip windows whose `spaceID(for:)` ≠ active space — or route them through the same space-aware path the sidebar uses (B2).

### A8. Merge All Windows collapses merged-in spaces; surviving model is nondeterministic
- **Where:** `TerminalWindow.mergeAllWindows:254–262` (only relabels tabs); `TerminalSpacesStore.model(for:):22–42`.
- **Repro:** Two standalone windows each with custom spaces → Window menu → Merge All Windows. Combined window shows one set of spaces; the other's are gone, and which set survives varies run to run.
- **Root cause:** Same single-window-migration limitation as A2; `mergeAllWindows` does nothing with `SpacesModel`. Per design, collapsing assignments is acceptable; the *nondeterminism* and *silent destruction of named spaces* are not.
- **Minimal fix:** Fixing A2 (scan all tab-group windows, prefer the key window's model) makes the survivor deterministic. Optionally re-home the front window's model explicitly in `mergeAllWindows`. Lower priority — uncommon, session-only.

### A9. Creating a space in non-native fullscreen leaves a phantom empty space
- **Where:** create branch `170–174` (`addSpace` then `switchToSpace`); `switchToSpace:469–476` nil branch; `SpacesModel.addSpace:84–90`.
- **Repro:** Non-native fullscreen (style where `supportsTabs == false`), sidebar mode. Switcher `+`, pick icon, Done → "Cannot Create New Tab" alert. A permanent empty "New Space" remains; clicking it re-fires the alert.
- **Root cause:** `addSpace` appends+activates the space *before* a tab can be made. `newTab` returns nil; the nil branch calls `reconcileActiveSpace` (restores active id) but never removes the orphaned empty space.
- **Minimal fix:** Roll back on failure — in the `newTab(...) == nil` branch, if the active space is empty, `spaces.removeSpace` it before `reconcileActiveSpace`. (Simpler: in the create case, attempt the tab first, only `addSpace` on success.)

### A10. moveTab of a background (non-selected) tab steals focus / activates the app
- **Where:** `moveTab:480–501` (branch at 494–498) → `select:259–263`.
- **Repro:** Space with selected tab A and background tab B. Right-click B → Move to Space → Space 2. Ghostty re-selects/activates even though only a background tab was re-homed.
- **Root cause:** The branch fires on `wasActiveSpace` alone, not on whether the *moved* window was the selected/front one; `selectLastActiveTab`→`select` calls `makeKeyAndOrderFront` + `NSApp.activate`.
- **Minimal fix:** Capture `window == tabGroup.selectedWindow` before the move and gate the `selectLastActiveTab` call on that, not on `wasActiveSpace`.

### A11. Context-menu "Move Up/Down" makes a background tab key
- **Where:** `move:347–361` → `TerminalSidebarTabMover.move:651` (`sourceWindow.makeKey()`).
- **Repro:** Tabs A (selected) and B. Right-click B → Move Up. B becomes the visible terminal even though only a reorder was intended.
- **Root cause:** `TerminalSidebarTabMover.move` unconditionally `makeKey()`s the moved window; the menu lets you reorder any row. (Drag-drop making the dragged tab key is fine/expected; menu reorder of a background row should preserve selection.)
- **Minimal fix:** After a menu-driven reorder, restore key status to the previously selected window unless the moved window was already selected.

### A12. Context-menu / "Move to Space" submenu can flash/rebuild on real state changes
- **Where:** `tabRows` reads `refreshNonce` (233); `.contextMenu`/submenu built inside `ForEach(rows)` (82–131); `bumpIfChanged` increments `refreshNonce` (392).
- **Repro:** Open the "Move to Space" submenu and let a background tab's title change or a bell fire. Signature changes → nonce bumps → `rows` rebuilds → the open submenu rebuilds underneath you.
- **Root cause:** The menu's identity is tied to the per-refresh `rows` array. `bumpIfChanged` only suppresses *no-op* ticks; a genuine change during interaction still tears down the open menu.
- **Minimal fix:** Build the context menu from stable data (the window + `spaces`) rather than the recomputed `rows` row. Removing the polling timer (B3) shrinks the collision window dramatically.

---

## Section B — Simplicity / consolidation plan

The feature has **three structural over-engineerings**, each the root of multiple Section-A bugs. Addressing them is the highest-leverage simplification.

### B1. One owner for "remove a space when its last tab dies" — a model invariant (fixes A1, A3, A5; simplifies A4)
Today space removal is scattered: optimistically in `close()` (289–291) and `deleteSpace()` (338), and **missing** from ⌘W/split-close. This split is the direct cause of the orphan/ghost bugs.

**Do:** After `spaces.sync(liveWindows:)` prunes assignments in `syncSpaces` (432–447), prune any **non-active** space with zero remaining assignments (keeping ≥1 space). Then:
- delete `removeSpace` from `close()` (close becomes "select sibling if any, then `rawClose`");
- in `deleteSpace`, close the tabs and let the post-close sync drop the now-empty space (no pre-remove);
- the "last space" guard (A4) still lives in `removeSpace`, but the destructive path is gone because removal is driven off the *actual* live-window set, never optimistically.

This makes every close path (sidebar X, context Close Tab, ⌘W, split-close, delete-space) converge on identical behavior and **removes the entire pre-mutate-then-async-cancel hazard class**.

### B2. Collapse the two close pipelines (fixes A6, A7; removes the `closeOtherTabs`/`closeTabsBelow` divergence)
The sidebar reimplements bulk close as per-tab `rawClose` loops, diverging from `TerminalController`'s batched confirm + grouped undo, and `Close Tabs Below` (sidebar order) vs native `to the Right` (native order) are two meanings of one command.

**Do:** Have the sidebar's bulk actions delegate to the controller's existing `closeOtherTabs`/`closeTabsOnTheRight`, passing a space filter (the only real difference). Symmetrically, make those native IBActions space-aware in sidebar mode (A7). `rawClose` itself is a fine one-liner; the loop-based bulk helpers (`closeOtherTabs`, `closeTabsBelow`) are the removable duplication (~25 lines) and the source of the confirm/undo/order divergences.

### B3. Replace the 0.5s polling timer with event-driven title updates (removes A12's root, deletes the signature subsystem)
The poll (227–229) exists solely to catch `window.title` changes (no notification is wired for those). It forces a second mechanism — `currentSignature`/`bumpIfChanged` (388–420, ~33 lines) — to exist *only to suppress the no-op re-renders the poll causes* (the code comment at 383–387 admits this). And `refresh()` runs `syncNativeTabBar()` + `syncSpaces()` **before** the signature gate, so AppKit tab-bar mutation and dict rebuilds run every tick regardless.

**Do:** Post a title-changed notification from `BaseTerminalController.applyTitleToWindow()` and observe it (exactly like the existing bell handler). With no constant polling:
- delete the `Timer.publish` driver;
- delete `currentSignature`/`bumpIfChanged`/`lastSignature` and just bump `refreshNonce` on real events (no more hand-maintained string fingerprint that must mirror `tabRows`, and no `ObjectIdentifier(window).hashValue` term at line 411);
- the `syncNativeTabBar()` per-tick churn disappears.
Net removal ~40 lines plus the whole submenu-flash class. Also collapse the near-duplicate `didBecomeKey` + `didBecomeMain` observers (218–223) into one, and ideally filter observers to the sidebar's own tab group so foreign-group sidebars don't run `syncSpaces`/`reconcile` on every app-wide key event.

### B4. Smaller cleanups
- **`SpacesModel.windowsInActiveSpace(from:):55–57`** is dead in the app (only tests call it); the identical filter is inlined at `TerminalSidebarView.swift:239, 353, 407`. Route all three through the helper *or* delete it and keep the inline filters — pick one.
- **`removeSpace` active-id reassignment (106–108)** is immediately overridden by `reconcileActiveSpace` in both real callers. Pick one owner: either let `removeSpace` own the choice (and stop reconciling right after) or drop the reassignment and make the caller responsible.
- **Default-name inconsistency:** first space is `"Space 1"` (`TerminalSpacesStore.swift:52`) vs every later space `"New Space"` (`TerminalSidebarView.swift:23`). Use one shared constant.
- **Per-tab duplicated `@State`** (`width`, signature bookkeeping) across all sidebars in a group means a resize in tab A is lost when switching to tab B. If keeping the per-tab views, hoist at least `width` onto the shared `SpacesModel` (or a per-tab-group view-state object) so resize is shared and the signature/refresh loop isn't N-fold. Lower priority; B3 already removes the signature loop.

**Is a bigger restructure worth it?** No full rewrite needed. B1–B3 are surgical and remove the bugs at their source. The single most valuable structural change is **B1 (one invariant for empty-space removal driven by the live window set)** because it eliminates A1, A3, A5 and de-fangs A4 simultaneously.

---

## Section C — Per-flow correctness checklist

| User action | Status |
|---|---|
| Create space | A9 (phantom space in non-native fullscreen) |
| Switch space | OK |
| Rename space | OK |
| Delete space | A3, A4 (last-space window destruction), A6 (per-tab prompts/undo) |
| New tab (header + / context) | A2 (migration race wipes spaces on first extra tab) |
| Close non-last tab in space | OK |
| Close last tab in space (sidebar X / context) | A1 (cancel orphans tab into deleted space) |
| Close last tab in space (native ⌘W / split-close) | A5 (ghost empty space lingers) |
| Close last tab in whole window | OK |
| Close Other Tabs (sidebar) | A6 (stacked confirms, ungrouped undo) |
| Close Tabs Below (sidebar) | A6; order semantics diverge from native (B2) |
| Close Other / to-the-Right (app menu / keyboard) | A7 (space-blind, closes hidden spaces' tabs) |
| Move tab to another space | A10 (focus/activation steal for background tab) |
| Reorder Move Up/Down (context menu) | A11 (background tab becomes key) |
| Reorder drag-drop | OK |
| Native ⌘1-9 / ⌃Tab | OK (active space follows front window by design) |
| Standalone → tabbed | A2 (race wipes user-created spaces) |
| Move tab to new window | OK (joins new window's space, by design) |
| Merge windows | A8 (nondeterministic survivor; merged-in spaces destroyed) |
| Context menu / "Move to Space" submenu while state changes | A12 (menu flash/rebuild) |

Key files: `/Users/lukastanisic/Git/ghostty-by-space/macos/Sources/Features/Terminal/TerminalSidebarView.swift`, `/Users/lukastanisic/Git/ghostty-by-space/macos/Sources/Features/Terminal/SpacesModel.swift`, `/Users/lukastanisic/Git/ghostty-by-space/macos/Sources/Features/Terminal/TerminalSpacesStore.swift`, and (for A6/A7/A8) `/Users/lukastanisic/Git/ghostty-by-space/macos/Sources/Features/Terminal/TerminalController.swift`, `/Users/lukastanisic/Git/ghostty-by-space/macos/Sources/Features/Terminal/BaseTerminalController.swift`, `/Users/lukastanisic/Git/ghostty-by-space/macos/Sources/Window Styles/TerminalWindow.swift`.