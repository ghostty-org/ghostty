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

- [ ] **B1.** `quit-after-last-window-closed-delay` does nothing on natural close (`MainWindow.cpp:255`). Delay timer only fires when libghostty issues `QUIT_TIMER`, but closing the last window via the title-bar X keeps the process alive forever (since Qt's `quitOnLastWindowClosed` was set false to allow the delay path). macOS handles via `applicationShouldTerminateAfterLastWindowClosed`; GTK wires last-window-close → `startQuitTimer` (`application.zig:820-862`).
- [ ] **B2.** `CLOSE_ALL_WINDOWS` always force-terminates (`MainWindow.cpp:1367-1370`, `:602-621`). Qt collapses `QUIT` and `CLOSE_ALL_WINDOWS` into the same path, both calling `qApp->quit()`. macOS keeps them distinct (close-all doesn't terminate). User binds close-all-windows → app quits unexpectedly.
- [ ] **B3.** `m_skipCloseConfirm` never cleared (`MainWindow.cpp:577-585`, `:454`, `:474`, `:509`). After one skip-confirmed close, if the window is re-shown via `toggleVisibility`, the next close also skips confirmation. macOS resets per-action.
- [ ] **B4.** `confirm-close-surface` config option ignored (`MainWindow.cpp:587-599`). Qt always uses libghostty's `needs_confirm_quit`. User setting `false` / `always` / `always-cwd` has no effect.
- [ ] **B5.** `closeAllWindows` ignores `quit-after-last-window-closed=false` — windowless keep-alive impossible after close-all.

### Action coverage

- [ ] **B6.** `CLOSE_TAB` ignores `close_tab_mode` (`MainWindow.cpp:1241-1247`). Always treats as `mode=THIS`. "Close other tabs" / "Close tabs to the right" keybinds silently close only the current tab.
- [ ] **B7.** `INITIAL_SIZE` halves window on HiDPI (`MainWindow.cpp:1429-1433`). Width/height from libghostty are already logical pixels; Qt divides by `devicePixelRatioF()` again. macOS uses unmodified.
- [ ] **B8.** `MOUSE_VISIBILITY` clobbers cursor shape on un-hide (`MainWindow.cpp:1512-1520`). Sets `Qt::ArrowCursor` on un-hide, destroying the previous shape from `MOUSE_SHAPE`. macOS preserves shape.
- [ ] **B9.** Performable-action-returns-true: `MOVE_TAB`, `GOTO_TAB`, `GOTO_SPLIT`, `RESIZE_SPLIT`, `EQUALIZE_SPLITS`, `TOGGLE_SPLIT_ZOOM` all unconditionally return `true`, swallowing chords on unsplit/single-tab surfaces. macOS returns false; GTK gates on `tree.getIsSplit()`.
- [ ] **B10.** `MOVE_TAB` with target=APP moves a tab in arbitrary first window (`MainWindow.cpp:1504`). macOS returns false for app target.
- [ ] **B11.** `RELOAD_CONFIG` only reloads ONE window (`MainWindow.cpp:1410-1414`). Other windows stay on stale config. macOS reloads globally.
- [ ] **B12.** `CONFIG_CHANGE` only refreshes chrome (`MainWindow.cpp:1416-1421`). Doesn't push the new config to running surfaces. `applyWindowConfig` only updates tab-bar + theme — `window-decoration`, `fullscreen`, `maximize` changes don't propagate to existing windows.
- [ ] **B13.** `OPEN_URL` ignores `kind` (`MainWindow.cpp:1471-1480`). `.text` payloads (e.g. config files) open with whatever the desktop says is default for `.txt` (usually a browser). macOS routes `.text` to a text editor.
- [ ] **B14.** `OPEN_CONFIG` opens via `QDesktopServices::openUrl` without `text` kind hint — same problem.
- [ ] **B15.** `SHOW_CHILD_EXITED` fires unconditionally (`MainWindow.cpp:1379-1387`, `GhosttySurface.cpp:466-498`). macOS gates on `runtime_ms > 0` and `abnormalCommandExitRuntime` config; Qt shows the banner for fast `exit 0` cases.
- [ ] **B16.** `COPY_TITLE_TO_CLIPBOARD` copies the WINDOW title (`MainWindow.cpp:1280-1284`, `:552`), not the surface title. On a multi-tab window, the wrong title gets copied. macOS copies per-surface.
- [ ] **B17.** `PROMPT_TITLE` with target=APP is no-op (`MainWindow.cpp:1271`). macOS promotes to `NSApp.mainWindow`.
- [ ] **B18.** Many actions in `default: return false;` (`MainWindow.cpp:1603-1604`):
  - `PWD` — breaks new tab/split working-dir inheritance.
  - `GOTO_WINDOW` — multi-window cycle.
  - `PRESENT_TERMINAL` — bring-to-front.
  - `KEY_TABLE` — bindable mode tables silent.
  - `READONLY` — read-only state silent.
  - `COLOR_CHANGE` — OSC 4/10/11/12 routing silent.
  - `RENDER_INSPECTOR` — inspector won't repaint between frames.
  - `CELL_SIZE` — window won't snap to cell grid.
  - `SIZE_LIMIT` — never honors min-size from libghostty.
  - `TOGGLE_BACKGROUND_OPACITY`, `FLOAT_WINDOW`, `SECURE_INPUT`, `UNDO`/`REDO`, `CHECK_FOR_UPDATES`, `TOGGLE_TAB_OVERVIEW`, `TOGGLE_WINDOW_DECORATIONS` — feature gaps (mostly matching GTK).

### Input / keyboard / mouse

- [ ] **B19.** Mouse buttons 4-11 not delivered (`GhosttySurface.cpp:710-715`). Only Left/Right/Middle mapped; back/forward buttons silently dropped. macOS + GTK both handle 4-11.
- [ ] **B20.** Modifier release doesn't synthesize event (`sendKey`). Bare Shift/Ctrl/Alt presses don't produce kitty progressive-enhancement events. macOS uses `flagsChanged`; GTK derives from physical_key.
- [ ] **B21.** `consumed_mods` only computed for printable events (`GhosttySurface.cpp:699-701`). Keypad/function/Backspace/arrows lose consumed-mods info. macOS + GTK compute unconditionally.
- [ ] **B22.** Caps Lock + Num Lock state never set in mods (`translateMods`). Kitty CSI-u relies on these bits.
- [ ] **B23.** Sided modifiers (left vs right) not reported. `left_shift` vs `right_shift` keybinds can't fire. macOS + GTK both populate `mods.sides.*`.
- [ ] **B24.** No mouse-enter/leave callback to libghostty (`GhosttySurface.cpp:927-930`). Hover state, OSC-8 link arming, mouse-report sequences stay armed after pointer leaves. macOS + GTK both notify libghostty.
- [ ] **B25.** `MOUSE_SHAPE` action not honored at all. Cursor stays OS default regardless of what the running program (e.g. `vim`) requests. macOS + GTK both implement.
- [ ] **B26.** `MOUSE_VISIBILITY` (hide-on-typing) not honored. macOS + GTK both implement.
- [ ] **B27.** Right-click swallowed when program isn't mouse-capturing (`GhosttySurface.cpp:742-745`, `:782-787`). Qt opens its context menu without ever sending the right-press to libghostty. macOS + GTK send press first, only show menu if core didn't consume — so word-select-then-menu can fire.
- [ ] **B28.** Click-to-focus also reports the click to libghostty. macOS + GTK suppress the matching mouse-up. Qt sends both, so a focus-grabbing click is visible to running programs.
- [ ] **B29.** `XkbState` uses default layout, not the live one (`GhosttySurface.cpp:629-641`). User with us+ru layouts gets us-only `unshifted_codepoint` regardless of active group. GTK uses `event.getLayout()`.
- [ ] **B30.** Wheel: `pixelDelta` ignored, momentum/precision unset (`GhosttySurface.cpp:919-925`). Trackpad on Wayland is notchy; kitty smooth-scroll never engages. macOS uses precise + momentum flags.
- [ ] **B31.** Drag-drop URL escaping uses bash-only `'\''` (`GhosttySurface.cpp:889-894`). macOS + GTK use a unified `Shell.escape` / `ShellEscapeWriter` that handles backslashes, newlines, and non-POSIX shells.
- [ ] **B32.** Plain URL drop not distinguished from file drop. `http://...` becomes a quoted argument instead of pasted text.

### Window / tab / split

- [ ] **B33.** No new-window cascade or position restore. Every Ghastty window opens at 800×600 stacked on top of the previous on X11. Doesn't read `window-position-x/y`, `window-width/height`. macOS cascades + restores; GTK reads the size from the surface.
- [ ] **B34.** Tab tear-off can't be dropped on another window's bar (`TabWidget.cpp:165-173`). macOS + GTK both natively support cross-window tab adoption.
- [ ] **B35.** Split focus order sorts by widget center, not split tree (`MainWindow.cpp:809-858`). Nested unbalanced trees cycle in a different order than macOS+GTK use.
- [ ] **B36.** QSplitter handle drag bypasses libghostty (`MainWindow.cpp:381`). Mouse-drag updates Qt's splitter ratios but never tells libghostty; "split equalize" later won't restore correctly.
- [ ] **B37.** Split equalize is per-splitter, not tree-aware (`MainWindow.cpp:886-896`). 3-pane vertical next to 1-pane gets 1:1 instead of 3:1. macOS + GTK use `surfaceTree.equalized()` which weights by leaf count.
- [ ] **B38.** No `split-preserve-zoom` config. macOS persists zoom across focus moves with `navigation` setting.
- [ ] **B39.** Tab right-click context menu absent. macOS + GTK have full menu (Close/Close-Others/Close-Right/Rename/Pin).
- [ ] **B40.** `window-decoration` only handles `none` (`MainWindow.cpp:268`). `auto`/`client`/`server` all collapse.
- [ ] **B41.** `window-theme` partial (`MainWindow.cpp:1040`). `ghostty` mode (luminance-detected from background color) and full OS-scheme follow not implemented; pre-Qt 6.8 has zero theming.

### Quick terminal

- [ ] **B42.** No animation (slide-in/out). macOS uses `NSAnimationContext`.
- [ ] **B43.** `quick-terminal-screen` not honored. macOS resolves which monitor.
- [ ] **B44.** `quick-terminal-position = center` not handled (`MainWindow.cpp:700`).
- [ ] **B45.** `quick-terminal-space-behavior` not honored.
- [ ] **B46.** No fallback for non-Wayland — `LayerShellQt::Window::get()` returning null leaves a regular window without telling libghostty.

### Misc

- [ ] **B47.** `reload-config` doesn't propagate `window-decoration` / `fullscreen` / `maximize` to existing windows.
- [ ] **B48.** `s_quitDelayMs` cached at init — runtime config reload doesn't update it.
- [ ] **B49.** Inspector window: hard-coded 800×600 each time — no autosave.

---

## 🟡 Inconsistent (works, but feels wrong)

- [ ] **I1.** Close-confirmation buttons "Yes/No" instead of "Cancel/Close" with destructive style. Not localized. macOS uses native NSAlert; GTK uses Adw.MessageDialog with `close-response: cancel`.
- [ ] **I2.** Bell mark `"● "` prefix vs macOS 🔔 vs GTK `setNeedsAttention`.
- [ ] **I3.** `MOVE_TAB` clamps; GTK wraps. Qt matches macOS but mismatches GTK.
- [ ] **I4.** `GOTO_TAB:99` does nothing; macOS clamps to last tab; GTK clamps via `@min`.
- [ ] **I5.** `MOUSE_OVER_LINK` becomes a Qt tooltip; macOS+GTK use a dedicated overlay.
- [ ] **I6.** `PROGRESS_REPORT` collapses ERROR/PAUSE/INDETERMINATE to a boolean.
- [ ] **I7.** `COMMAND_FINISHED` ignores `notify-on-command-finish` config (`.never`/`.unfocused`/`.always`), `notify-on-command-finish-after`, and bell mode.
- [ ] **I8.** `DESKTOP_NOTIFICATION` is app-target only; `requireFocus` not honored.
- [ ] **I9.** Bell `attention` fallback hardcoded (`MainWindow.cpp:910`) — `configGet` failing silently falls back to `BellAttention`, ignoring user config.
- [ ] **I10.** Cross-window split DnD unsupported. GTK matches; macOS has it.

---

## ⚪ Missing config options (silently dropped)

- [ ] **C1.** `window-save-state`
- [ ] **C2.** `window-step-resize`
- [ ] **C3.** `window-width`, `window-height`
- [ ] **C4.** `window-position-x`, `window-position-y`
- [ ] **C5.** `window-padding-balance`, `window-padding-color`
- [ ] **C6.** `window-colorspace`
- [ ] **C7.** `window-inherit-working-directory`
- [ ] **C8.** `window-inherit-font-size`
- [ ] **C9.** `window-title-font-family`
- [ ] **C10.** `bell-audio-path`, `bell-audio-volume`
- [ ] **C11.** `quick-terminal-screen`
- [ ] **C12.** `quick-terminal-animation-duration`
- [ ] **C13.** `mouse-hide-while-typing`
- [ ] **C14.** `background-image*`
- [ ] **C15.** `split-divider-color`
- [ ] **C16.** `clipboard-trim-trailing-spaces`
- [ ] **C17.** `clipboard-paste-protection`
- [ ] **C18.** `progress-style`
- [ ] **C19.** `split-preserve-zoom`
- [ ] **C20.** `initial-window`
- [ ] **C21.** `app-notifications` (per-category gating)

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

- Undo close-tab/window
- Window save/restore
- Cross-window tab/split DnD
- Inspector autosave + presentation
- Many of the action `default: return false;` items (PWD, GOTO_WINDOW, PRESENT_TERMINAL, KEY_TABLE, COLOR_CHANGE, etc.)

---

## How to use this document

1. Pick an item and tick `[ ]` → `[x]` when the commit lands.
2. Append the commit hash next to the line: `[x] **B7.** ... — fixed in abc1234`.
3. If a finding turns out to be wrong on closer inspection, strike it through with `~~B7.~~ ...` and add a one-line explanation.
4. New parity issues discovered during implementation: add to the appropriate section with the next ID in sequence.
