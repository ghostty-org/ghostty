# 01 — research/spike — FINDINGS

**Date:** 2026-07-16 · **Base commit:** `463786bd2` (main)
**Verdict on the load-bearing assumption: ✅ PASS — a `SurfaceView` removed from the
view hierarchy keeps its pty/session alive.** Details and evidence in §3.

---

## 1. Dev build

A dev build works end-to-end on this machine, with caveats (all environmental, none
blocking):

- **Zig:** repo pins Zig 0.15.x (`build.zig.zon` `minimum_zig_version = "0.15.2"`,
  enforced major/minor by `src/build/zig.zig`). No zig was installed; Homebrew ships
  0.16.0 which is rejected. Used the official 0.15.2 aarch64-macos tarball.
- **Core build:** `zig build -Demit-macos-app=false` ✅ builds clean.
- **macOS app:** this machine's `xcode-select` points at CommandLineTools, but
  `xcodebuild`/Metal need full Xcode (installed at `/Applications/Xcode.app`,
  26.4.1). Two extra wrinkles:
  1. Zig 0.15.2 **cannot run with `DEVELOPER_DIR` or `SDKROOT` exported** — the
     build-runner fails to link (undefined `_waitpid` etc.). The env override must be
     scoped to only the xcodebuild/metal sub-steps.
  2. Xcode 26 ships the Metal compiler as a downloadable component; it was missing.
     Fixed with `xcodebuild -downloadComponent MetalToolchain` (688 MB, one-time).
- **Temporary, uncommitted build patches** (marked `// TEMPORARY (research spike)`)
  live in the `main` worktree to scope `DEVELOPER_DIR` to the right sub-steps:
  - `src/build/MetallibStep.zig` — set `DEVELOPER_DIR` on the metal/metallib RunSteps.
  - `src/build/XCFrameworkStep.zig` — same for `xcodebuild -create-xcframework`.
  - `src/build/GhosttyXcodebuild.zig` — add `DEVELOPER_DIR` to the scrubbed env.
  - `src/build/GhosttyXCFramework.zig` — **bug found:** `-Dxcframework-target=native`
    still eagerly configures the iOS/iOS-sim libs, which fails without an iOS SDK.
    Patched to skip iOS slices for `native`. This one is a candidate upstream fix.
- **Result:** `zig build -Dxcframework-target=native` produces
  `macos/build/Debug/Ghostty.app`. **App launches and behaves as stock** (windows,
  splits, tabs verified during the experiment in §3).

## 2. Code reading

### 2.1 `TerminalController` and the split tree

- `BaseTerminalController` (`macos/Sources/Features/Terminal/BaseTerminalController.swift`)
  is an `NSWindowController` + `NSWindowDelegate` + `TerminalViewDelegate`/`TerminalViewModel`.
  It owns the tree: `@Published var surfaceTree: SplitTree<Ghostty.SurfaceView>`
  (`BaseTerminalController.swift:44`). One controller ≈ one window; native macOS tabs
  are separate `NSWindow`s (one controller each) in an `NSWindowTabGroup`.
- `SplitTree` (`macos/Sources/Features/Splits/SplitTree.swift`) is an **immutable value
  type**: `root: Node?` where `Node = leaf(view:) | split(Split)`, plus `zoomed: Node?`.
  Leaves hold **strong references** to `Ghostty.SurfaceView` (an `NSView`). Every
  mutation (`inserting`, `removing`, `replacing`, `equalized`, …) returns a new tree,
  which is assigned back to `surfaceTree`.
- Rendering: `windowDidLoad` (`TerminalController.swift:1055`) sets
  `window.contentView = TerminalViewContainer { TerminalView(...) }` (SwiftUI). The
  SwiftUI chain `TerminalView` → `TerminalSplitTreeView` renders `tree.zoomed ?? tree.root`
  recursively; each leaf hosts the *existing* `SurfaceView` NSView via an
  `NSViewRepresentable`. **Attach/detach of NSViews is a pure function of the published
  tree value** — nobody adds/removes subviews manually.
- Lifecycle reactions: `surfaceTreeDidChange` clears focus/occlusion state, and in
  `TerminalController` closes the window when the tree becomes empty
  (`TerminalController.swift:184`). Split ops arrive as NotificationCenter events from
  the Zig core (`ghosttyDidNewSplit`, `ghosttyDidFocusSplit`, `ghosttyDidToggleSplitZoom`, …)
  targeted at a `SurfaceView` object; controllers filter with `surfaceTree.contains(target)`.
- **Precedent for retained-but-detached trees:** `replaceSurfaceTree`
  (`BaseTerminalController.swift:484`) registers undo holding the *old tree* —
  Ghostty's own "undo close split/tab/window" keeps whole trees, with live ptys,
  detached from any view hierarchy until undo expiration (`undoTimeout`). Our
  workspace-switching design is the same mechanism with a different owner.

**Implication for M3:** switching workspaces can literally be
`controller.surfaceTree = workspace.tree` (direct assignment, *not*
`replaceSurfaceTree`, to avoid undo registration and the empty-tree/close-window path).
SwiftUI detaches the old NSViews and attaches the new ones, same as zoom does today.
Focus restore = `Ghostty.moveFocus(to:)` + the existing `syncFocusToSurfaceTree()`.

### 2.2 Surface creation and lifetime

- `Ghostty.SurfaceView` (AppKit: `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`)
  calls `ghostty_surface_new()` **in its initializer** (line ~371) — pty + IO threads
  start immediately, before the view is ever in a window. The C handle is wrapped in
  `Ghostty.Surface` (`Ghostty.Surface.swift`), whose `deinit` calls
  `ghostty_surface_free()`.
- **Therefore surface lifetime is governed by ARC on the `SurfaceView` object, not by
  view-hierarchy membership.** `removeFromSuperview` has no pty side effects; only
  dropping the last strong reference (usually: the last `SplitTree` holding the leaf,
  plus any undo entries) frees the surface and kills the session.
- Corollary for teardown: a `WorkspaceManager` retaining background trees must drop
  them on window close, or ptys leak. (M3 verify step: `ps` after closing a window
  with 3 live workspaces.)
- Nice-to-have: `syncSurfaceTreeOcclusionState()` calls `ghostty_surface_set_occlusion`
  per surface; background workspaces should be marked occluded so the renderer idles.

### 2.3 Per-surface working directory

- Core → Swift: OSC 7 / shell integration produces `GHOSTTY_ACTION_PWD` →
  `Ghostty.App.pwdChanged` (`Ghostty.App.swift:1751`) sets the published property
  `surfaceView.pwd`.
- Swift reads it anywhere as `surfaceView.pwd` (String path, `@Published`, observable
  via Combine — good hook for lazy repo-root resolution). `TerminalView` forwards the
  *focused* surface's pwd to `BaseTerminalController.pwdDidChange` (sets
  `window.representedURL`).
- **Requires shell integration**: a surface running a bare command (verified with
  `/bin/sleep`) reports no pwd. The sidebar's repo pinning must handle `pwd == nil`
  (fall back to the surface's configured `working-directory`, then to empty state).

### 2.4 Keybind → action flow (reference: `goto_split`)

1. **Parse/config:** `src/input/Binding.zig` — `Action` enum member
   `goto_split: SplitFocusDirection` (`Binding.zig:634`).
2. **Core dispatch:** `src/Surface.zig:5318` — `performBindingAction` maps it to
   `rt_app.performAction(.{ .surface = self }, .goto_split, direction)`.
3. **Apprt interface:** `src/apprt/action.zig` — `goto_split: GotoSplit` in the
   `Action` union (+ `Key` enum) with a C-ABI `cval()` conversion.
4. **C boundary:** `include/ghostty.h` — `GHOSTTY_ACTION_GOTO_SPLIT` +
   `ghostty_action_goto_split_e` payload. `src/apprt/embedded.zig` `App.performAction`
   forwards the C struct to the embedder's registered action callback.
5. **Swift:** `Ghostty.App.swift:521` — switch on `GHOSTTY_ACTION_GOTO_SPLIT` →
   `gotoSplit()` → posts `Ghostty.Notification.ghosttyFocusSplit` with the target
   `SurfaceView` → `BaseTerminalController.ghosttyDidFocusSplit` acts on its tree.
6. Command palette entries live in `src/input/command.zig`.

Adding `toggle_worktree_sidebar` / `goto_worktree:{next,previous}` is **mechanical,
not invasive**: one small hunk each in Binding.zig, Surface.zig (or App.zig for
app-target actions), action.zig, ghostty.h, embedded.zig docs, Ghostty.App.swift,
plus a controller handler. ~6 files, all following an existing template. The plan's
"proper Zig actions" approach stands; no need for the Swift-menu fallback.
Note the CLAUDE.md rule: new C enums in `include/ghostty/vt/` need the
`_MAX_VALUE` sentinel — `ghostty.h` action enums follow their own existing pattern.

## 3. Load-bearing check: pty survives view detachment — ✅ PASS (empirical)

**Method** (fully scripted; Ghostty's new AppleScript API made this precise):

1. Dev-built app running. Created a window whose surface runs `/bin/sleep 98765`
   (`new window with configuration {command: "/bin/sleep 98765", wait after command: true}`).
   Recorded `pid` (foreground pid, via `ghostty_surface_foreground_pid`) and `tty`.
2. `split t1 direction right` → second surface, focus moves to it.
3. `perform action "toggle_split_zoom" on t2` → **`TerminalSplitTreeView` renders only
   the zoomed node**, so t1's `SurfaceView` is dismantled out of the NSView hierarchy
   (same detach path the workspace switcher would use; the view object stays retained
   by the `SplitTree`).
4. Kept it detached >10 s, polling from a separate shell.

**Evidence:**

```
pid_before=83816 tty=/dev/ttys009 pid_while_detached=83816   # queried via libghostty while detached
$ ps -o pid,stat,command -p 83816
83816 Ss+  /usr/bin/login -flp eugene ... exec -l /bin/sleep 98765   # alive, still attached to ttys009
$ ps -ef | grep "sleep 98765"
501 83817 83816  -/bin/sleep 98765                                    # child alive
STILL ALIVE after 10+s detached
reattached: pid=83816 wd=            # after un-zoom; surface fully functional
alive after reattach
```

The session survived detach → 10+ s detached → reattach, remained queryable through
libghostty the whole time, and the process tree (login → sleep) never received SIGHUP.
This is consistent with §2.2's reading (pty lifetime = ARC, not view hierarchy) and
with the shipped undo-close feature that depends on the same property.

**The milestone chain may proceed. No revised approach needed.**

## 4. Upstream check (new since plan.md)

- **AppleScript scripting API** (`macos/Ghostty.sdef`, `macos/Sources/Features/AppleScript/`)
  — new, and significant for us: full window/tab/terminal object model,
  `new window`/`new tab`/`split`/`close`/`focus`, `perform action <keybind string>`,
  `input text`, `send key`, and per-terminal `id`/`pid`/`tty`/`working directory`.
  This is how §3 was automated, and it's an excellent harness for M1–M4 verification
  scripts. It does *not* provide sidebar/workspace concepts.
- **App Intents** (`macos/Sources/Features/App Intents/`) — `NewTerminalIntent`
  supports split placement; `KeybindIntent` performs arbitrary actions. Another
  automation surface; again no workspace concept.
- **No sidebar/workspace config upstream**: `grep -i "sidebar\|workspace"` over
  `src/config/Config.zig` is empty.
- **Discussion #2549 (vertical tabs):** maintainer (mitchellh) has stated upstream
  remains closed on the feature — vertical tabs on macOS need custom tab bars, which
  are "planned eventually" with no timeline; users are pointed at community forks.
  Confirms this stays fork-side. Prior art: **aflat `vert_tabs`** (macOS, mostly
  AI-assisted, factored GTK out), tomreinert's opinionated sidebar with project-level
  workspaces (closest in spirit to our design), 8bittts' collapsible sidebar,
  PR #9931 (thumbnail grid), and cmux (separate Ghostty-based terminal). None
  implement worktree-scoped workspaces; reference only, as planned.
- Housekeeping: this fork already carries the scaffold branches from
  `00-OVERVIEW.md` (`feat/wt-keybinds`, `feat/wt-git-model`, `feat/wt-sidebar-shell`, …)
  as git worktrees — the two `feat/wt-*` branches with commits predate this spike.

## 5. Plan adjustments (small; nothing structural)

1. **M3 mechanism:** implement switching as direct `surfaceTree` assignment on the
   controller (bypassing `replaceSurfaceTree`'s undo + empty-tree handling); guard
   `TerminalController.surfaceTreeDidChange`'s "empty → close window" path so an
   in-flight swap can't trip it.
2. **Occlusion:** mark background-workspace surfaces occluded on detach, visible on
   attach (mirrors `syncSurfaceTreeOcclusionState`).
3. **Teardown:** on window close, explicitly drop all background trees; add the
   `ps`-based orphan check to M3's verify script (AppleScript can drive all of it).
4. **pwd:** treat `surfaceView.pwd` as optional; fall back to the workspace's
   configured `working-directory`.
5. **Verification harness:** write M1–M4 verify steps as AppleScript against the dev
   build (precedent in `.dev/` would be scaffolding, stripped before upstream PRs).
6. **Build docs for contributors to this fork:** note the Zig 0.15.x pin, the
   `DEVELOPER_DIR` scoping issue, the MetalToolchain download, and the
   `-Dxcframework-target=native` iOS bug (upstreamable fix).
