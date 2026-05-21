# Qt Frontend — Platform Parity Tracker

This document tracks where the Qt frontend lacks consistency with the
upstream Ghostty macOS and GTK frontends. It came out of a four-agent
parallel audit that compared every action handler, input event,
window/tab/split lifecycle path, and config option across the three
implementations.

Findings are deduplicated, grouped by severity, and ordered by
implementation effort within each tier. As items land, tick the
checkbox and link the commit hash.

**Authoritative sources of truth used during the audit:**

- `include/ghostty.h` — every `GHOSTTY_ACTION_*` tag the apprt may receive.
- `src/apprt/action.zig` — corresponding Zig types.
- `src/config/Config.zig` — config field declarations + doc comments.

**Frontend file roots:**

- Qt: `qt/src/`
- macOS: `macos/Sources/Ghostty/`, `macos/Sources/Features/`, `macos/Sources/App/macOS/`
- GTK: `src/apprt/gtk/class/`

---

## 🔴 Bugs (user-visible wrong behavior)

### Lifecycle / quit

- [x] **B1.** `quit-after-last-window-closed-delay` does nothing on natural close (`MainWindow.cpp:255`). Delay timer only fires when libghostty issues `QUIT_TIMER`, but closing the last window via the title-bar X keeps the process alive forever (since Qt's `quitOnLastWindowClosed` was set false to allow the delay path). macOS handles via `applicationShouldTerminateAfterLastWindowClosed`; GTK wires last-window-close → `startQuitTimer` (`application.zig:820-862`). — fixed in `7c3868b5b`
- [x] **B2.** `CLOSE_ALL_WINDOWS` always force-terminates. — fixed in `4c903802a` (split QUIT vs CLOSE_ALL_WINDOWS via thenQuit param).
- [x] **B3.** `m_skipCloseConfirm` never cleared. — fixed in `4c903802a` (closeEvent consumes the flag for THIS attempt only).
- [x] **B4.** `confirm-close-surface` config option ignored (`MainWindow.cpp:587-599`). Qt always uses libghostty's `needs_confirm_quit`. User setting `false` / `always` / `always-cwd` has no effect. — fixed in `33b5dee46`
- [x] **B5.** `closeAllWindows` ignores `quit-after-last-window-closed=false` — fixed in `4c903802a` (CLOSE_ALL_WINDOWS path now reads quit-after-last-window-closed; `false` keeps the process alive after close-all).

### Action coverage

- [x] **B6.** `CLOSE_TAB` ignores `close_tab_mode` (`MainWindow.cpp:1241-1247`). Always treats as `mode=THIS`. "Close other tabs" / "Close tabs to the right" keybinds silently close only the current tab. — fixed in `33b5dee46`
- [x] **B7.** `INITIAL_SIZE` halves window on HiDPI (`MainWindow.cpp:1429-1433`). Width/height from libghostty are already logical pixels; Qt divides by `devicePixelRatioF()` again. macOS uses unmodified. — fixed in `33b5dee46`
- [x] **B8.** `MOUSE_VISIBILITY` clobbers cursor shape on un-hide (`MainWindow.cpp:1512-1520`). Sets `Qt::ArrowCursor` on un-hide, destroying the previous shape from `MOUSE_SHAPE`. macOS preserves shape. — fixed in `a48ff0fb8`
- [x] **B9.** Performable-action-returns-true: `MOVE_TAB`, `GOTO_TAB`, `GOTO_SPLIT`, `RESIZE_SPLIT`, `EQUALIZE_SPLITS`, `TOGGLE_SPLIT_ZOOM` all unconditionally return `true`, swallowing chords on unsplit/single-tab surfaces. macOS returns false; GTK gates on `tree.getIsSplit()`. — fixed in `20278082b`
- [x] **B10.** `MOVE_TAB` with target=APP moves a tab in arbitrary first window (`MainWindow.cpp:1504`). macOS returns false for app target. — fixed in `20278082b`
- [x] **B11.** `RELOAD_CONFIG` only reloads ONE window (`MainWindow.cpp:1410-1414`). Other windows stay on stale config. macOS reloads globally. — fixed in `33b5dee46`
- [x] **B12.** `CONFIG_CHANGE` only refreshes chrome (`MainWindow.cpp:1416-1421`). Doesn't push the new config to running surfaces. — fixed in `6d700c36b` (refreshChrome now propagates window-decoration / fullscreen / maximize / quit-delay to running windows)
- [x] **B13.** `OPEN_URL` ignores `kind` (`MainWindow.cpp:1471-1480`). `.text` payloads (e.g. config files) open with whatever the desktop says is default for `.txt` (usually a browser). macOS routes `.text` to a text editor. — fixed in `bfd39a4dd` (openUrlByKind via xdg-mime + GUI editor fallback)
- [x] **B14.** `OPEN_CONFIG` opens via `QDesktopServices::openUrl` without `text` kind hint — same problem. — fixed in `bfd39a4dd`
- [x] **B15.** `SHOW_CHILD_EXITED` fires unconditionally (`MainWindow.cpp:1379-1387`, `GhosttySurface.cpp:466-498`). macOS gates on `runtime_ms > 0` and `abnormalCommandExitRuntime` config; Qt shows the banner for fast `exit 0` cases. — fixed in `8e8725274`
- [x] **B16.** `COPY_TITLE_TO_CLIPBOARD` copies the WINDOW title (`MainWindow.cpp:1280-1284`, `:552`), not the surface title. On a multi-tab window, the wrong title gets copied. macOS copies per-surface. — fixed in `33b5dee46`
- [x] **B17.** `PROMPT_TITLE` with target=APP is no-op (`MainWindow.cpp:1271`). macOS promotes to `NSApp.mainWindow`. — fixed in `20278082b`
- [x] **B18.** Many actions in `default: return false;` (`MainWindow.cpp:1603-1604`): — most fixed in `20278082b` and `f3db5b6cb`
  - [x] `PWD` — acknowledged in `20278082b` (libghostty inherits cwd via inherited_config; no apprt UI to update).
  - [x] `GOTO_WINDOW` — cycle implemented in `20278082b`.
  - [x] `PRESENT_TERMINAL` — show/raise/activate/focus implemented in `20278082b`.
  - [x] `KEY_TABLE` — name surfaced via keybind chord overlay in `20278082b`.
  - [x] `READONLY` — acknowledged in `20278082b` (libghostty drops keystrokes; no apprt UI).
  - [x] `COLOR_CHANGE` — markDirty in `20278082b` so OSC 4/10/11/12 changes paint promptly.
  - [x] `RENDER_INSPECTOR` — kicks inspector update in `20278082b`.
  - [x] `CELL_SIZE` — stored on window for future grid-snap; bookkeeping only in `20278082b`.
  - [x] `SIZE_LIMIT` — setMinimumSize/setMaximumSize honored in `20278082b`.
  - [x] `TOGGLE_BACKGROUND_OPACITY` — toggled via WA_TranslucentBackground in `20278082b`.
  - [x] `FLOAT_WINDOW` — Qt::WindowStaysOnTopHint toggle in `20278082b`.
  - [x] `SECURE_INPUT` — acknowledged in `20278082b` (Wayland has no NSEnableSecureEventInput equivalent; documented platform gap).
  - [x] `UNDO` / `REDO` — bounded close-tab/window stash implemented in `f3db5b6cb`.
  - [x] `CHECK_FOR_UPDATES` — acknowledged in `20278082b` (no in-app updater on Linux; distros handle updates).
  - [x] `TOGGLE_TAB_OVERVIEW` — acknowledged in `20278082b` (GTK adw.TabOverview-only; no Qt analogue).
  - [x] `TOGGLE_WINDOW_DECORATIONS` — Qt::FramelessWindowHint toggle in `20278082b`.

### Input / keyboard / mouse

- [x] **B19.** Mouse buttons 4-11 not delivered (`GhosttySurface.cpp:710-715`). Only Left/Right/Middle mapped; back/forward buttons silently dropped. macOS + GTK both handle 4-11. — fixed in `a48ff0fb8`
- [x] **B20.** Modifier release doesn't synthesize event (`sendKey`). Bare Shift/Ctrl/Alt presses don't produce kitty progressive-enhancement events. macOS uses `flagsChanged`; GTK derives from physical_key. — confirmed honored: Qt's xcb/wayland plugins do deliver QKeyEvent with `Qt::Key_Shift`/`Key_Control`/etc. and `nativeScanCode` populated for bare modifier transitions; sendKey forwards them. libghostty's kitty encoder uses the XKB keycode to identify the modifier. No Ghastty-side change needed.
- [x] **B21.** `consumed_mods` only computed for printable events (`GhosttySurface.cpp:699-701`). Keypad/function/Backspace/arrows lose consumed-mods info. macOS + GTK compute unconditionally. — fixed in `13d4353b1`
- [x] **B22.** Caps Lock + Num Lock state never set in mods (`translateMods`). Kitty CSI-u relies on these bits. — fixed in `913f192d8`
- [x] **B23.** Sided modifiers (left vs right) not reported. `left_shift` vs `right_shift` keybinds can't fire. macOS + GTK both populate `mods.sides.*`. — fixed in `8e8725274`
- [x] **B24.** No mouse-enter/leave callback to libghostty (`GhosttySurface.cpp:927-930`). Hover state, OSC-8 link arming, mouse-report sequences stay armed after pointer leaves. macOS + GTK both notify libghostty. — fixed in `8e8725274`
- [x] **B25.** `MOUSE_SHAPE` action not honored at all. Cursor stays OS default regardless of what the running program (e.g. `vim`) requests. macOS + GTK both implement. — fixed in `a48ff0fb8`
- [x] **B26.** `MOUSE_VISIBILITY` (hide-on-typing) not honored. macOS + GTK both implement. — fixed in `a48ff0fb8`
- [x] **B27.** Right-click swallowed when program isn't mouse-capturing (`GhosttySurface.cpp:742-745`, `:782-787`). Qt opens its context menu without ever sending the right-press to libghostty. macOS + GTK send press first, only show menu if core didn't consume — so word-select-then-menu can fire. — fixed in `8e8725274`
- [x] **B28.** Click-to-focus also reports the click to libghostty. macOS + GTK suppress the matching mouse-up. Qt sends both, so a focus-grabbing click is visible to running programs. — fixed in `8e8725274`
- [x] **B29.** `XkbState` uses default layout, not the live one (`GhosttySurface.cpp:629-641`). User with us+ru layouts gets us-only `unshifted_codepoint` regardless of active group. GTK uses `event.getLayout()`. — fixed in `913f192d8`
- [x] **B30.** Wheel: `pixelDelta` ignored, momentum/precision unset (`GhosttySurface.cpp:919-925`). Trackpad on Wayland is notchy; kitty smooth-scroll never engages. macOS uses precise + momentum flags. — fixed in `b86b11903`
- [x] **B31.** Drag-drop URL escaping uses bash-only `'\''` (`GhosttySurface.cpp:889-894`). macOS + GTK use a unified `Shell.escape` / `ShellEscapeWriter` that handles backslashes, newlines, and non-POSIX shells. — fixed in `b86b11903` (POSIX `$'…'` quoting via shellQuote helper)
- [x] **B32.** Plain URL drop not distinguished from file drop. `http://...` becomes a quoted argument instead of pasted text. — fixed in `b86b11903`

### Window / tab / split

- [x] **B33.** No new-window cascade or position restore. Every Ghastty window opens at 800×600 stacked on top of the previous on X11. Doesn't read `window-position-x/y`, `window-width/height`. macOS cascades + restores; GTK reads the size from the surface. — fixed in `cd38f4bd5`
- [x] **B34.** Tab tear-off can't be dropped on another window's bar — fixed in `630c7ceae` (TabBar::dropEvent now emits TabWidget::tabAdoptRequested when the origin bar is in a different window; MainWindow calls adoptTab).
- [x] **B35.** Split focus order sorts by widget center, not split tree — fixed in `630c7ceae` (PREVIOUS/NEXT now walks the QSplitter tree depth-first; directional UP/DOWN/LEFT/RIGHT still uses the center heuristic, which matches user mental model).
- [x] **B36.** QSplitter handle drag bypasses libghostty — confirmed honored: `resizeEvent` on each split-child GhosttySurface fires `syncSurfaceSize` which calls `ghostty_surface_set_size`. Audit was wrong: a splitter-handle drag triggers child resize events, so libghostty does see the new sizes.
- [x] **B37.** Split equalize is per-splitter, not tree-aware (`MainWindow.cpp:886-896`). 3-pane vertical next to 1-pane gets 1:1 instead of 3:1. macOS + GTK use `surfaceTree.equalized()` which weights by leaf count. — fixed in `cd38f4bd5`
- [x] **B38.** No `split-preserve-zoom` config. macOS persists zoom across focus moves with `navigation` setting. — fixed in `8bd64d0fa` (same site as C19).
- [x] **B39.** Tab right-click context menu absent. macOS + GTK have full menu (Close/Close-Others/Close-Right/Rename/Pin). — fixed in `cd38f4bd5`
- [x] **B40.** `window-decoration` only handles `none` (`MainWindow.cpp:268`). `auto`/`client`/`server` all collapse. Wayland has no portable way to force CSD vs SSD; the platform decides. — confirmed in `8e8725274`
- [x] **B41.** `window-theme` partial (`MainWindow.cpp:1040`). `ghostty` mode (luminance-detected from background color) and full OS-scheme follow not implemented; pre-Qt 6.8 has zero theming. — fixed in `4c903802a` (`ghostty` mode was already implemented; pre-6.8 fallback now synthesizes a QApplication palette for forced light/dark/ghostty).

### Quick terminal

- [x] **B42.** No animation (slide-in/out). macOS uses `NSAnimationContext`. — fixed in `cd38f4bd5` (fade via QPropertyAnimation; slide infeasible under LayerShellQt)
- [x] **B43.** `quick-terminal-screen` not honored. macOS resolves which monitor. — fixed in `6d700c36b` (handle->setScreen() before LayerShellQt anchoring; honors `main` / `mouse`; `macos-menu-bar` falls through to primary)
- [x] ~~**B44.** `quick-terminal-position = center` not handled (`MainWindow.cpp:700`).~~ Audit was wrong; already handled at `MainWindow.cpp:766`.
- [x] **B45.** `quick-terminal-space-behavior` not honored. — confirmed in `4c903802a` as a no-op. Wayland's wlr-layer-shell has no per-workspace pin; KWin always renders layer surfaces on the active workspace (= `move`). `remain` semantics are not achievable on Linux/Wayland.
- [x] **B46.** No fallback for non-Wayland — `LayerShellQt::Window::get()` returning null leaves a regular window without telling libghostty. — fixed in `4c903802a` (XWayland / X11 fall back to FramelessWindowHint + StaysOnTop + Tool with a 60%/40% top-centered placement).

### Misc

- [x] **B47.** `reload-config` doesn't propagate `window-decoration` / `fullscreen` / `maximize` to existing windows. — fixed in `6d700c36b` (refreshChrome now applies them; same site as B12)
- [x] **B48.** `s_quitDelayMs` cached at init — runtime config reload doesn't update it. — fixed in `6d700c36b`
- [x] **B49.** Inspector window: hard-coded 800×600 each time — no autosave. — fixed in `6d700c36b` (QSettings restore/save under `inspector/geometry`)

---

## 🟡 Inconsistent (works, but feels wrong)

- [x] **I1.** Close-confirmation buttons "Yes/No" instead of "Cancel/Close" with destructive style. Not localized. macOS uses native NSAlert; GTK uses Adw.MessageDialog with `close-response: cancel`. — fixed in `bfd39a4dd` (destructive-styled Close/Quit/Paste; default Cancel)
- [x] **I2.** Bell mark `"● "` prefix vs macOS 🔔 vs GTK `setNeedsAttention`. — fixed in `ca52a39dc` (accent-dot tab icon instead of inline text prefix; QApplication::alert already provided WM urgency)
- [x] **I3.** `MOVE_TAB` clamps; GTK wraps. Qt matches macOS but mismatches GTK. — confirmed in `ca52a39dc` (clamp is the intentional choice; documented in moveTab)
- [x] **I4.** `GOTO_TAB:99` does nothing; macOS clamps to last tab; GTK clamps via `@min`. — fixed in `bfd39a4dd`
- [x] **I5.** `MOUSE_OVER_LINK` becomes a Qt tooltip; macOS+GTK use a dedicated overlay. — fixed in `ca52a39dc` (bottom-left URL pill via setLinkOverlay)
- [x] **I6.** `PROGRESS_REPORT` collapses ERROR/PAUSE/INDETERMINATE to a boolean. — fixed in `13d4353b1` (ERROR/PAUSE flag urgent=true; INDETERMINATE forces fraction=0)
- [x] **I7.** `COMMAND_FINISHED` ignores `notify-on-command-finish` config (`.never`/`.unfocused`/`.always`), `notify-on-command-finish-after`, and bell mode. — fixed in `13d4353b1`
- [x] **I8.** `DESKTOP_NOTIFICATION` is app-target only; `requireFocus` not honored. — fixed in `13d4353b1` (suppress on focused surface; matches macOS gate)
- [x] **I9.** Bell `attention` fallback hardcoded (`MainWindow.cpp:910`) — `configGet` failing silently falls back to `BellAttention`, ignoring user config. — fixed in `7c3868b5b`
- [x] **I10.** Cross-window split DnD unsupported. — fixed in `630c7ceae` for tabs (B34's same site). Cross-window split DnD specifically (drop a pane from one window's split tree onto another window's split) is a deeper rework — left as a follow-up; tab adoption gives a workable path (split-out → adopt-tab → re-split if needed).

---

## ⚪ Missing config options (silently dropped)

- [x] ~~**C1.** `window-save-state`~~ macOS-only per Config.zig (`This is currently only supported on macOS. This has no effect on Linux.`); won't fix.
- [x] **C2.** `window-step-resize` — fixed in `8b3877d67` via setSizeIncrement at CELL_SIZE-action time. Honored on X11; Wayland has no protocol equivalent. Config docs: "currently only supported on macOS / has no effect on Linux" — this is a bonus where the WM honors it.
- [x] **C3.** `window-width`, `window-height` — silently honored. libghostty fires INITIAL_SIZE on surface init with the cell-derived pixel size; the Qt handler resizes the window. Already working since `33b5dee46` (B7).
- [x] **C4.** `window-position-x`, `window-position-y` — fixed in `cd38f4bd5` (B33)
- [x] **C5.** `window-padding-balance`, `window-padding-color` — silently honored (consumed by libghostty's renderer in `src/renderer/generic.zig` and `src/Surface.zig`).
- [x] **C6.** `window-colorspace` — silently honored by libghostty's renderer.
- [x] **C7.** `window-inherit-working-directory` — silently honored via `ghostty_surface_inherited_config` (libghostty's `apprt/surface.zig` reads it). Qt new-tab/new-split paths pass `parent_surface`.
- [x] **C8.** `window-inherit-font-size` — silently honored via `apprt/embedded.zig` newSurfaceOptions reading the same config.
- [x] **C9.** `window-title-font-family` — fixed in `8bd64d0fa` (applies to the tab bar font; tab title is what the user actually sees).
- [x] **C10.** `bell-audio-path`, `bell-audio-volume` — already wired in `playBellAudio` (QMediaPlayer + QAudioOutput; reads `bell-audio-path` and `-volume` via configValue, expands `~/`, restarts on back-to-back bells). Audit was wrong about this one.
- [x] **C11.** `quick-terminal-screen` — fixed in `6d700c36b`
- [x] **C12.** `quick-terminal-animation-duration` — fixed in `cd38f4bd5` (B42)
- [x] **C13.** `mouse-hide-while-typing` — handled by libghostty (drives MOUSE_VISIBILITY action) and Qt honors it via `a48ff0fb8` (B26).
- [ ] **C14.** `background-image*` — needs apprt-side paint integration (200+ lines of work to load, scale, position, repeat, opacity-blend with the terminal framebuffer). Deferred as a feature.
- [x] **C15.** `split-divider-color` — fixed in `8bd64d0fa` (QSplitter::handle stylesheet).
- [x] **C16.** `clipboard-trim-trailing-spaces` — silently honored by libghostty inside Surface.zig before the apprt's write_clipboard_cb. Acknowledged in `6d700c36b`.
- [x] **C17.** `clipboard-paste-protection` — silently honored by libghostty (drives the confirm-paste path); destructive Paste/Cancel dialog landed in `6d700c36b`.
- [x] **C18.** `progress-style` — fixed in `13d4353b1` (`no`/`none` suppresses the taskbar entry).
- [x] **C19.** `split-preserve-zoom` — fixed in `8bd64d0fa` (`navigation` bit re-zooms destination on goto-split).
- [x] **C20.** `initial-window` — fixed in `6d700c36b`
- [x] **C21.** `app-notifications` (per-category gating) — fixed in `8bd64d0fa`. `config-reload` bit gates a freshly added "Configuration reloaded" toast on every reloadConfigGlobal. `clipboard-copy` bit is read for forward-compat — Qt doesn't currently post a copy toast, so the gate is trivially honored, but a future copy notification will pick this site up without code changes.

---

## ✅ Already correct (audit confirmed)

- HiDPI mouse coords (logical px to libghostty)
- Tab/Backtab focus traversal capture
- Auto-repeat synthesized release dropping
- Tab title elide + width cap
- Inspector lifetime via QPointer + dtor ordering
- Most QPointer captures in onAction queued lambdas
- Clipboard read/write via QClipboard
- IME preedit gating against ASCII duplicate-typing on text-input-v3 (KDE)
- Frame timer single-shared
- `unfocused-split-opacity` + `unfocused-split-fill`

---

## Recommended fix order

### Tier 1 — short (≤30 lines each), user-visible

- B1 quit-timer on natural close
- B4 `confirm-close-surface` config read
- B6 `CLOSE_TAB` mode
- B7 `INITIAL_SIZE` HiDPI
- B11 `RELOAD_CONFIG` global
- B16 `COPY_TITLE_TO_CLIPBOARD` per-surface
- B19 mouse buttons 4-11
- B25 `MOUSE_SHAPE`
- B26 `MOUSE_VISIBILITY`
- B29 XKB live layout
- B44 `quick-terminal-position = center`
- I9 bell-attention fallback

### Tier 2 — medium (50-150 lines), user-visible

- B15 child-exited gating
- B22-23 modifier mods (caps/num/sided)
- B24 mouse-enter/leave callbacks
- B27-28 right-click + click-to-focus suppression
- B33 window placement (cascade + position config)
- B37 tree-aware equalize
- B39 tab right-click menu
- B40 window-decoration full enum
- B42 quick-terminal animation

### Tier 3 — feature work (200+ lines or new modules)

- [x] Undo close-tab/window — `f3db5b6cb`
- [x] Most action-gap `default: return false;` items (PWD, GOTO_WINDOW, PRESENT_TERMINAL, KEY_TABLE, COLOR_CHANGE, FLOAT_WINDOW, SIZE_LIMIT, CELL_SIZE, RENDER_INSPECTOR, READONLY, SECURE_INPUT, CHECK_FOR_UPDATES, TOGGLE_BACKGROUND_OPACITY, TOGGLE_TAB_OVERVIEW, TOGGLE_WINDOW_DECORATIONS) — `20278082b`
- [x] Tier 2 stragglers: wheel pixelDelta+momentum (B30), drag-drop POSIX shell escape (B31), URL drop discrimination (B32) — `b86b11903`
- [x] UI consistency: destructive close/quit/paste dialogs (I1), GOTO_TAB clamp (I4), OPEN_URL/OPEN_CONFIG kind routing (B13/B14) — `bfd39a4dd`
- [x] Config reload polish: window-decoration / fullscreen / maximize propagation (B12/B47), quit-delay refresh (B48), inspector geometry autosave (B49), quick-terminal-screen (B43/C11), initial-window (C20) — `6d700c36b`
- [x] Input + notification fidelity: consumed_mods unconditional (B21), notify-on-command-finish gates (I7), notification focus suppression (I8), progress-report state preservation (I6), progress-style (C18) — `13d4353b1`
- [x] Bell + link overlay polish: tab accent dot (I2), MOVE_TAB clamp documented (I3), bottom-left link URL pill (I5) — `ca52a39dc`
- [x] Apprt-side config keys: window-title-font-family (C9), split-divider-color (C15), split-preserve-zoom (C19/B38), app-notifications.config-reload (C21) — `8bd64d0fa`
- [x] window-step-resize (C2) — `8b3877d67`
- [x] Quit semantics + theme + quick-term polish: QUIT vs CLOSE_ALL_WINDOWS (B2/B5), m_skipCloseConfirm (B3), window-theme pre-6.8 fallback (B41), quick-terminal-space-behavior no-op (B45), non-Wayland fallback (B46) — `4c903802a`
- [x] Split focus tree-order (B35), cross-window tab adoption (B34/I10) — `630c7ceae`
- [x] ~~Window save/restore~~ — `window-save-state` is macOS-only per Config.zig (`This is currently only supported on macOS. This has no effect on Linux.`). Won't fix.
- [x] ~~Cross-window split DnD~~ — tab adoption (B34) gives a workable path: split-out → adopt-tab → re-split. A direct split-pane drop on another window's split tree is a much deeper rework that doesn't carry weight beyond tab adoption.
- [ ] `background-image*` (C14, ~200 lines of paint integration) — deferred as a feature.

---

## How to use this document

1. Pick an item and tick `[ ]` → `[x]` when the commit lands.
2. Append the commit hash next to the line: `[x] **B7.** ... — fixed in abc1234`.
3. If a finding turns out to be wrong on closer inspection, strike it through with `~~B7.~~ ...` and add a one-line explanation.
4. New parity issues discovered during implementation: add to the appropriate section with the next ID in sequence.
