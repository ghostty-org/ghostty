# tmux -CC Execution Plan

## Step 1: New `tmux` termio backend

**Goal**: Surfaces can exist without a real PTY.

### Files to modify:

**`src/termio/backend.zig`**
- Add `tmux` to `Kind` enum: `pub const Kind = enum { exec, tmux };`
- Add `tmux` to `Config` union: `tmux: termio.Tmux.Config`
- Add `tmux` to `Backend` union: `tmux: termio.Tmux`
- Add `tmux` to `ThreadData` union: `tmux: termio.Tmux.ThreadData`
- Add `.tmux` arms to all switch statements in `Backend` and `ThreadData` methods

**`src/termio/Tmux.zig`** (new file)
- Backend implementation with these methods:
  - `init(alloc, config)` — stores pane_id, host_writer, pane_terminal pointer
  - `deinit()` — no subprocess to clean up
  - `initTerminal(t)` — no-op (terminal state comes from viewer)
  - `threadEnter(alloc, io, td)` — no read loop (output arrives via viewer)
  - `threadExit(td)` — minimal cleanup
  - `queueWrite(alloc, td, data, linefeed)` — converts bytes to `send-keys -t %<pane_id> -H <hex>\n`, writes to host PTY
  - `resize(grid_size, screen_size)` — sends `resize-pane -t %<pane_id> -x <cols> -y <rows>\n`
  - `focusGained(td, focused)` — optionally sends `select-pane -t %<pane_id>`
  - `childExitedAbnormally(...)` — no-op
- Config struct:
  ```zig
  pub const Config = struct {
      pane_id: usize,
      host_write_fn: *const fn ([]const u8) void,
      pane_terminal: *terminal.Terminal,
  };
  ```

**`src/termio.zig`**
- Add `pub const Tmux = @import("termio/Tmux.zig");`

### Verification:
- `zig build` compiles without errors
- Unit test: `queueWrite("hello")` produces `send-keys -t %<id> -H 68 65 6c 6c 6f\n`

---

## Step 2: Viewer accessor + new action variant

**Goal**: Controller can access pane Terminals and know when output arrives.

### Files to modify:

**`src/terminal/tmux/viewer.zig`**
- Add public accessor:
  ```zig
  pub fn paneTerminal(self: *Viewer, pane_id: usize) ?*Terminal {
      const entry = self.panes.getEntry(pane_id) orelse return null;
      return &entry.value_ptr.terminal;
  }
  ```
- Add `pane_output: usize` variant to `Action` union (pane_id of the pane that received output)
- Emit `pane_output` from `receivedOutput()` after updating the pane's Terminal

### Verification:
- Existing viewer tests pass
- New unit test: `paneTerminal()` returns correct Terminal for known pane ID, null for unknown

---

## Step 3: TmuxController

**Goal**: Orchestration logic that maps viewer state to native surface operations.

### Files to create/modify:

**`src/terminal/tmux/controller.zig`** (new file)
- Struct fields:
  - `alloc: Allocator`
  - `host_surface: *Surface` — the surface running tmux -CC
  - `pane_surfaces: std.AutoHashMap(usize, *Surface)` — pane_id → Surface
  - `window_tabs: std.AutoHashMap(usize, TabId)` — window_id → tab
  - `viewer: *Viewer` — reference for pane Terminal lookups
  - `pending_resizes: std.AutoHashMap(usize, void)` — pane_ids with in-flight resizes (feedback loop prevention)
- Key methods:
  - `syncWindows(new_windows: []const Viewer.Window)` — diff old vs new window list, emit `tmux_sync` action
  - `layoutToSplitOps(layout: Layout) []SplitOp` — walk Layout tree, produce sequence of split operations
  - `handlePaneOutput(pane_id: usize)` — wake renderer for the pane's surface
  - `handleClose(pane_id: usize)` — send `kill-pane -t %<pane_id>` to host PTY
  - `handleExit()` — close all pane surfaces, emit `tmux_exit` action

**`src/terminal/tmux.zig`**
- Re-export: `pub const Controller = @import("tmux/controller.zig").Controller;`

### Verification:
- Unit test: `syncWindows` correctly identifies added/removed windows
- Unit test: `layoutToSplitOps` converts nested horizontal/vertical layouts to correct split sequence

---

## Step 4: New apprt actions

**Goal**: Platform layer can receive tmux lifecycle events.

### Files to modify:

**`src/apprt/action.zig`**
- Add action variants:
  ```zig
  tmux_sync: TmuxSync,
  tmux_exit,
  ```
- Define `TmuxSync` as extern struct (C ABI compatible):
  ```zig
  pub const TmuxSync = extern struct {
      controller: *anyopaque,  // pointer to TmuxController
      // Additional fields TBD based on what Swift needs
  };
  ```

**`include/ghostty.h`**
- Add enum values: `GHOSTTY_ACTION_TMUX_SYNC`, `GHOSTTY_ACTION_TMUX_EXIT`
- Add corresponding C struct `ghostty_action_tmux_sync_s`

### Verification:
- `zig build` compiles
- C header alignment tests pass

---

## Step 5: Wire stream handler to controller

**Goal**: The `// TODO` at `stream_handler.zig:456` is implemented.

### Files to modify:

**`src/termio/stream_handler.zig`**
- Add `tmux_controller` field (optional `*TmuxController`)
- `.windows` handler (line 456):
  ```zig
  .windows => |windows| {
      if (self.tmux_controller == null) {
          self.tmux_controller = try TmuxController.init(self.alloc, ...);
      }
      try self.tmux_controller.?.syncWindows(windows);
  },
  ```
- `.pane_output` handler:
  ```zig
  .pane_output => |pane_id| {
      if (self.tmux_controller) |ctrl| {
          ctrl.handlePaneOutput(pane_id);
      }
  },
  ```
- `.exit` handler: call `controller.handleExit()`, destroy controller
- On viewer DCS close: also clean up controller

### Verification:
- Build succeeds
- Running `tmux -CC` logs show controller receiving window data

---

## Step 6: Surface dual-path initialization

**Goal**: Surfaces can be created with tmux backend instead of exec.

### Files to modify:

**`src/Surface.zig`** (~line 635)
- Add tmux config to Surface options/config
- Branch in init:
  ```zig
  const backend: termio.Backend = if (config.tmux) |tmux_cfg| blk: {
      var tmux_backend = try termio.Tmux.init(alloc, tmux_cfg);
      errdefer tmux_backend.deinit();
      break :blk .{ .tmux = tmux_backend };
  } else blk: {
      var io_exec = try termio.Exec.init(alloc, exec_cfg);
      errdefer io_exec.deinit();
      break :blk .{ .exec = io_exec };
  };
  ```
- For tmux surfaces, the renderer's terminal pointer should reference the viewer's pane Terminal

**`src/apprt/embedded.zig`**
- Extend surface config struct with optional tmux fields (pane_id, host reference)

**`include/ghostty.h`**
- Add tmux fields to `ghostty_surface_config_s`

### Verification:
- Can create a surface with tmux backend without crash
- Build and C header alignment tests pass

---

## Step 7: macOS Swift integration

**Goal**: Native tabs and splits appear for tmux windows/panes.

### Files to modify:

**`macos/Sources/Ghostty/Ghostty.App.swift`**
- Handle `GHOSTTY_ACTION_TMUX_SYNC` in action switch → post `ghosttyTmuxSync` notification
- Handle `GHOSTTY_ACTION_TMUX_EXIT` → post `ghosttyTmuxExit` notification

**`macos/Sources/Features/Terminal/BaseTerminalController.swift`**
- Handle `ghosttyTmuxSync` notification:
  - Create new tabs for each tmux window
  - Recursively create splits matching the Layout tree:
    - `Layout.horizontal([a, b])` → surface for a, `new_split(.right)` for b
    - `Layout.vertical([a, b])` → surface for a, `new_split(.down)` for b
    - `Layout.pane(id)` → leaf surface with tmux backend config (pane_id, host ref)
  - Each SurfaceView is created with tmux config passed through to `ghostty_surface_new`
- Handle `ghosttyTmuxExit` notification:
  - Close all tmux pane tabs/splits
  - Unhide the host surface's tab

### Verification:
- Run `tmux -CC` → native tabs/splits appear
- Content renders correctly in each pane
- Typing in a pane sends keystrokes to tmux (visible in tmux output)

---

## Step 8: Host surface hiding + keybinding interception

**Goal**: Clean UX — host hidden, shortcuts route through tmux.

### Files to modify:

**macOS Swift (BaseTerminalController or AppDelegate)**
- On tmux entry: hide the host surface's tab (keep Surface alive)
- On tmux exit: restore the host surface's tab

**`src/terminal/tmux/controller.zig`** (or stream handler)
- When tmux mode is active, intercept these actions:
  - `new_tab` → send `new-window\n` to host PTY
  - `new_split(.right)` → send `split-window -h\n` to host PTY
  - `new_split(.down)` → send `split-window -v\n` to host PTY
  - `close_surface` → send `kill-pane -t %<pane_id>\n` to host PTY
- The resulting tmux notifications will trigger the controller to update native UI

### Verification:
- Cmd+T creates a new tmux window (appears as new native tab)
- Cmd+D creates a new tmux pane (appears as new native split)
- Cmd+W sends `kill-pane` (pane closes in both tmux and native UI)
- Detaching restores the original host surface

---

## Step 9: Edge cases + polish

### Resize feedback loop
- When user resizes a split, tmux backend sends `resize-pane`, which triggers `%layout-change`
- Controller tracks `pending_resizes` set — ignores `%layout-change` for panes with in-flight resizes

### Session switch
- `%session-changed` already handled by viewer (resets and re-fetches)
- Controller closes all pane surfaces and recreates for the new session

### Scrollback
- Viewer captures pane history on init via `capture-pane -p -S -`
- Shared Terminal holds scrollback; renderer displays it normally

### Mouse (deferred)
- Convert mouse events to tmux mouse protocol in a future iteration

### Verification:
- `tmux -CC attach` to existing multi-window/pane session works correctly
- Resizing splits doesn't cause infinite loop
- Session switching cleanly transitions UI
- Scrollback works in tmux panes
