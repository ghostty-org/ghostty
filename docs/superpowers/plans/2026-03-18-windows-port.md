# Ghostty Windows Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port Ghostty terminal emulator to run natively on Windows, leveraging existing cross-platform core (terminal emulation, OpenGL renderer, FreeType fonts) and adding a Win32-based application runtime.

**Architecture:** The Windows port follows a "full runtime" approach (like GTK on Linux) where a new `win32` apprt owns the event loop, window creation, and input handling. The existing OpenGL renderer, FreeType font rasterizer, HarfBuzz shaper, and ConPTY-based PTY layer already have Windows support. The primary work is: (1) a Win32 windowing runtime, (2) WGL OpenGL context management, (3) Windows font discovery, and (4) build system integration.

**Tech Stack:** Zig (build + source), Win32 API (windowing/input), WGL (OpenGL context), ConPTY (PTY), FreeType + HarfBuzz (fonts), OpenGL 4.3+ (rendering)

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `src/apprt/win32.zig` | Win32 apprt module (re-exports App, Surface) |
| `src/apprt/win32/App.zig` | Win32 application: window class registration, message loop, action dispatch |
| `src/apprt/win32/Surface.zig` | Win32 surface: HWND wrapper, OpenGL context (WGL), input translation, clipboard |
| `src/apprt/win32/win32.zig` | Win32 API helpers: window class, message constants, DPI functions |
| `src/font/discovery/windows.zig` | Windows font discovery: enumerates fonts from `%WINDIR%\Fonts` and registry |

### Modified Files

| File | Change |
|------|--------|
| `src/apprt/runtime.zig` | Add `.win32` variant to `Runtime` enum |
| `src/apprt.zig` | Add `win32` import and wire it into the `runtime` switch |
| `src/build/Config.zig` | Default to `.win32` runtime on Windows, default to `.freetype` font backend |
| `src/font/backend.zig` | Change Windows default from `.fontconfig_freetype` to `.freetype` |
| `src/renderer/OpenGL.zig` | Add WGL context init + `.win32` arms in all 4 runtime switches (`surfaceInit`, `threadEnter`, `threadExit`, `displayRealized`) |
| `src/termio/Exec.zig` | Fix `@panic("termios timer not implemented on Windows")` → graceful no-op |
| `src/build/SharedDeps.zig` | Add `.win32` arm in app_runtime switch (line ~544), link `opengl32`/`gdi32`/`user32` on Windows |
| `src/main_ghostty.zig` | Guard `macos` import with `comptime isDarwin()` check |
| `src/global.zig` | Guard `fontconfig` import with `comptime hasFontconfig()` check |
| `src/config/Config.zig` | Add `.win32` arms to ~3 app_runtime switches (lines ~4625, ~9023, ~9738) |
| `src/apprt/structs.zig` | Add `.win32` arms to Backing type switches (lines ~47, ~53, ~81, ~87) |
| `src/apprt/surface.zig` | Add `.win32` arms to switch (lines ~122, ~129) |
| `src/apprt/action.zig` | Add `.win32` arm to switch (lines ~679, ~685) |
| `src/input/Binding.zig` | Add `.win32` arm to switch (lines ~940, ~946) |
| `src/font/face.zig` | Add `.win32` arm to switch (lines ~61, ~67) |

---

## Phase 1: Build System — Compile on Windows

### Task 1: Add `win32` Runtime Enum Variant

**Files:**
- Modify: `src/apprt/runtime.zig`

- [ ] **Step 1: Add `.win32` to the Runtime enum**

```zig
// src/apprt/runtime.zig
pub const Runtime = enum {
    none,
    gtk,
    win32,

    pub fn default(target: std.Target) Runtime {
        return switch (target.os.tag) {
            .linux, .freebsd => .gtk,
            .windows => .win32,
            else => .none,
        };
    }
};
```

- [ ] **Step 2: Verify build still works on Linux**

Run: `zig build --help 2>&1 | grep app-runtime`
Expected: Shows `app-runtime` option with `none`, `gtk`, `win32`

- [ ] **Step 3: Commit**

```bash
git add src/apprt/runtime.zig
git commit -m "apprt: add win32 runtime variant for Windows"
```

---

### Task 2: Fix Font Backend Default for Windows

**Files:**
- Modify: `src/font/backend.zig`

- [ ] **Step 1: Change default font backend for Windows**

The current default for non-Darwin is `.fontconfig_freetype`, but fontconfig doesn't exist on Windows. Change to `.freetype` for Windows.

```zig
// src/font/backend.zig - default() function
pub fn default(
    target: std.Target,
    wasm_target: WasmTarget,
) Backend {
    if (target.cpu.arch == .wasm32) {
        return switch (wasm_target) {
            .browser => .web_canvas,
        };
    }

    if (target.os.tag.isDarwin()) return .coretext;
    if (target.os.tag == .windows) return .freetype;
    return .fontconfig_freetype;
}
```

- [ ] **Step 2: Commit**

```bash
git add src/font/backend.zig
git commit -m "font: default to bare freetype on Windows (no fontconfig)"
```

---

### Task 3: Wire Win32 Module into apprt

**Files:**
- Modify: `src/apprt.zig`
- Create: `src/apprt/win32.zig` (stub)

- [ ] **Step 1: Create stub win32 module**

```zig
// src/apprt/win32.zig
//! Win32 application runtime for Ghostty on Windows.
//! Uses native Win32 API for windowing, input, and clipboard.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../App.zig");

pub const App = struct {
    core_app: *CoreApp,

    pub const must_draw_from_app_thread = false;

    pub fn init(
        self: *App,
        core_app: *CoreApp,
        opts: struct {},
    ) !void {
        _ = opts;
        self.* = .{ .core_app = core_app };
    }

    pub fn run(self: *App) !void {
        _ = self;
        // TODO: Win32 message loop
    }

    pub fn terminate(self: *App) void {
        _ = self;
    }

    pub fn wakeup(self: *App) void {
        _ = self;
    }

    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        _ = self;
        _ = target;
        _ = value;
        return false;
    }
};

pub const Surface = struct {
    pub fn init(self: *Surface) !void {
        _ = self;
    }

    pub fn deinit(self: *Surface) void {
        _ = self;
    }
};

const internal_os = @import("../os/main.zig");
pub const resourcesDir = internal_os.resourcesDir;
```

- [ ] **Step 2: Wire into apprt.zig**

Add `win32` import and add it to the runtime switch:

```zig
// src/apprt.zig - add import
pub const win32 = @import("apprt/win32.zig");

// src/apprt.zig - update runtime switch
pub const runtime = switch (build_config.artifact) {
    .exe => switch (build_config.app_runtime) {
        .none => none,
        .gtk => gtk,
        .win32 => win32,
    },
    .lib => embedded,
    .wasm_module => browser,
};
```

- [ ] **Step 3: Commit**

```bash
git add src/apprt/win32.zig src/apprt.zig
git commit -m "apprt: add stub win32 runtime module"
```

---

### Task 4: Fix Conditional Imports and Platform Guards

**Files:**
- Modify: `src/main_ghostty.zig`
- Modify: `src/global.zig`

- [ ] **Step 1: Guard macOS import in main_ghostty.zig**

`src/main_ghostty.zig:9` has `const macos = @import("macos");` which fails on Windows because the `macos` module isn't available. Wrap it:

```zig
// src/main_ghostty.zig - line 9
const macos = if (comptime builtin.target.os.tag.isDarwin()) @import("macos") else undefined;
```

Also check `logFn` around line 126 which uses `macos.os.Log` — it's already guarded at runtime with `isDarwin()` but needs the import guarded at comptime too.

- [ ] **Step 2: Guard fontconfig import in global.zig**

`src/global.zig` unconditionally imports `fontconfig` at line ~6. The usage at line ~137 is already guarded by `comptime build_config.font_backend.hasFontconfig()`, but the import itself fails when fontconfig isn't available:

```zig
// src/global.zig - guard the import
const fontconfig = if (comptime build_config.font_backend.hasFontconfig()) @import("fontconfig") else undefined;
```

- [ ] **Step 3: Commit**

```bash
git add src/main_ghostty.zig src/global.zig
git commit -m "build: guard platform-specific imports (macos, fontconfig) with comptime checks"
```

---

### Task 5: Fix All app_runtime Switch Statements

**Files:**
- Modify: ~12 files with exhaustive `switch (build_config.app_runtime)` or `switch (apprt.runtime)`

Adding `.win32` to the `Runtime` enum breaks every exhaustive switch that only handles `.none` and `.gtk`. These must all be updated before the project compiles.

- [ ] **Step 1: Audit and fix all app_runtime switches**

The following files have exhaustive switches that need a `.win32` arm. In most cases, `.win32` should behave like `.none` (no GObject types, no GTK-specific features):

| File | Line(s) | Pattern | Win32 behavior |
|------|---------|---------|----------------|
| `src/config/Config.zig` | ~4625 | `.gtk => {...}, .none => {}` | Same as `.none` |
| `src/config/Config.zig` | ~9023 | `getGObjectType` | Return `void` like `.none` |
| `src/config/Config.zig` | ~9738 | Same pattern | Return `void` like `.none` |
| `src/apprt/structs.zig` | ~47, ~53 | Backing type | Same as `.none` |
| `src/apprt/structs.zig` | ~81, ~87 | Same pattern | Same as `.none` |
| `src/apprt/surface.zig` | ~122, ~129 | Platform type | Same as `.none` |
| `src/apprt/action.zig` | ~679, ~685 | GtkWidget type | `void` like `.none` |
| `src/input/Binding.zig` | ~940, ~946 | Same pattern | Same as `.none` |
| `src/font/face.zig` | ~61, ~67 | Same pattern | Same as `.none` |
| `src/datastruct/split_tree.zig` | ~1314, ~1355 | Same pattern | Same as `.none` |

For each: add `.win32` arm matching the `.none` arm behavior.

- [ ] **Step 2: Fix SharedDeps.zig app_runtime switch**

At `src/build/SharedDeps.zig` line ~544:

```zig
switch (self.config.app_runtime) {
    .none => {},
    .gtk => try self.addGtkNg(step),
    .win32 => {
        // Link Windows system libraries for OpenGL rendering
        step.linkSystemLibrary2("opengl32", .{});
        step.linkSystemLibrary2("gdi32", .{});
        step.linkSystemLibrary2("user32", .{});
    },
}
```

- [ ] **Step 3: Fix OpenGL.zig runtime switches**

`src/renderer/OpenGL.zig` has 4 switch statements on `apprt.runtime` with `@compileError` else arms. Add `.win32` branches to all four:
- `surfaceInit()` (~line 165) — WGL context setup
- `threadEnter()` (~line 201) — `wglMakeCurrent`
- `threadExit()` (~line 223) — `wglMakeCurrent(null, null)`
- `displayRealized()` (~line 240) — no-op (GTK-specific)

For now, use stub implementations that return without doing anything (WGL will be fully implemented in Phase 2).

- [ ] **Step 4: Fix termios panic in Exec.zig**

Replace the `@panic` at line ~327 with a graceful no-op:

```zig
if (comptime builtin.os.tag == .windows) {
    // Windows ConPTY doesn't support termios mode queries.
    // Password input detection is not available on Windows.
    return;
}
```

- [ ] **Step 5: Attempt cross-compilation to Windows**

Run: `zig build -Dtarget=x86_64-windows-gnu -Dapp-runtime=win32 2>&1 | head -50`
Expected: Either succeeds or shows specific remaining compilation errors.

- [ ] **Step 6: Fix any remaining compilation errors iteratively**

There may be additional switches or platform-specific code not identified above. Fix each one.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "build: add .win32 arms to all exhaustive switches, link Windows libs, fix termios panic"
```

---

## Phase 2: Minimal Win32 Window

### Task 6: Win32 Window Class and Message Loop

**Files:**
- Create: `src/apprt/win32/App.zig`
- Create: `src/apprt/win32/win32.zig`
- Update: `src/apprt/win32.zig` (re-export from subdirectory)

- [ ] **Step 1: Create Win32 API helpers**

```zig
// src/apprt/win32/win32.zig
//! Thin wrappers around Win32 API types and functions used by the apprt.
const std = @import("std");
const windows = std.os.windows;

// Window class name
pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");

// Window messages
pub const WM_CREATE: u32 = 0x0001;
pub const WM_DESTROY: u32 = 0x0002;
pub const WM_SIZE: u32 = 0x0005;
pub const WM_PAINT: u32 = 0x000F;
pub const WM_CLOSE: u32 = 0x0010;
pub const WM_QUIT: u32 = 0x0012;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_KEYUP: u32 = 0x0101;
pub const WM_CHAR: u32 = 0x0102;
pub const WM_MOUSEMOVE: u32 = 0x0200;
pub const WM_LBUTTONDOWN: u32 = 0x0201;
pub const WM_LBUTTONUP: u32 = 0x0202;
pub const WM_MOUSEWHEEL: u32 = 0x020A;
pub const WM_DPICHANGED: u32 = 0x02E0;
pub const WM_USER: u32 = 0x0400;
pub const WM_APP_WAKEUP: u32 = WM_USER + 1;

// Use Zig's std.os.windows for the core types, extend as needed.
pub const HWND = windows.HWND;
pub const HINSTANCE = windows.HINSTANCE;
pub const LPARAM = windows.LPARAM;
pub const WPARAM = windows.WPARAM;
pub const LRESULT = windows.LRESULT;
```

- [ ] **Step 2: Create App.zig with window class registration and message loop**

```zig
// src/apprt/win32/App.zig
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

pub const must_draw_from_app_thread = false;

core_app: *CoreApp,
hwnd: ?w32.HWND = null,

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;
    self.* = .{ .core_app = core_app };
    // Window class registration happens here
    log.info("Win32 app initialized", .{});
}

pub fn run(self: *App) !void {
    // Create initial window
    // Enter Win32 message loop
    _ = self;
    log.info("Win32 message loop started", .{});
}

pub fn terminate(self: *App) void {
    _ = self;
    log.info("Win32 app terminated", .{});
}

pub fn wakeup(self: *App) void {
    // Post WM_APP_WAKEUP to the message queue
    _ = self;
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    _ = self;
    _ = target;
    _ = value;
    return false;
}
```

- [ ] **Step 3: Restructure win32.zig as module re-export**

```zig
// src/apprt/win32.zig - becomes a module that re-exports
pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");

const internal_os = @import("../os/main.zig");
pub const resourcesDir = internal_os.resourcesDir;
```

- [ ] **Step 4: Commit**

```bash
git add src/apprt/win32/ src/apprt/win32.zig
git commit -m "apprt/win32: scaffold Win32 App with window class and message loop"
```

---

### Task 7: Win32 Surface with HWND and WGL OpenGL Context

**Files:**
- Create: `src/apprt/win32/Surface.zig`
- Modify: `src/renderer/OpenGL.zig` (add WGL context init)

- [ ] **Step 1: Create Surface.zig with HWND management**

The Surface wraps an HWND and manages the WGL OpenGL context for rendering. It must implement the methods called on `rt_surface` by `src/Surface.zig`:
- `getSize()` → `apprt.SurfaceSize`
- `getContentScale()` → `apprt.ContentScale`
- `getCursorPos()` → `apprt.CursorPos`
- `getTitle()` → `?[:0]const u8`
- `close(process_alive: bool)` → void
- `supportsClipboard(apprt.Clipboard)` → `bool`
- `clipboardRequest(...)` → clipboard support
- `setClipboard(...)` → clipboard write
- `defaultTermioEnv()` → env vars for child process

Note: `draw()` and `refresh()` are called on the renderer, NOT on the Surface directly.

- [ ] **Step 2: Implement WGL OpenGL context creation**

The OpenGL renderer needs a platform-specific context. Add a Win32/WGL path in `src/renderer/OpenGL.zig`'s `surfaceInit()` method that:
1. Gets the device context (HDC) from the surface's HWND
2. Chooses a pixel format with `ChoosePixelFormat`/`SetPixelFormat`
3. Creates a WGL context with `wglCreateContext`
4. Makes it current with `wglMakeCurrent`

- [ ] **Step 3: Commit**

```bash
git add src/apprt/win32/Surface.zig src/renderer/OpenGL.zig
git commit -m "apprt/win32: Surface with HWND and WGL OpenGL context"
```

---

## Phase 3: Terminal Rendering Pipeline

### Task 8: Connect Renderer to Win32 Surface

**Files:**
- Modify: `src/apprt/win32/Surface.zig`
- Modify: `src/apprt/win32/App.zig`

- [ ] **Step 1: Integrate CoreSurface initialization**

When a window is created, the Win32 Surface must:
1. Create a `CoreSurface` (from `src/Surface.zig`)
2. Initialize the OpenGL renderer for this surface
3. Start the terminal I/O thread (via `termio.Exec`)
4. Connect PTY output to the terminal state machine

- [ ] **Step 2: Handle WM_PAINT → draw cycle**

Wire `WM_PAINT` to call `CoreSurface.draw()` which renders the terminal grid via OpenGL.

- [ ] **Step 3: Handle WM_SIZE → resize**

Wire `WM_SIZE` to update surface dimensions and notify the PTY of the new terminal size.

- [ ] **Step 4: Test with a static terminal grid**

Launch ghostty.exe on Windows. Expected: A window appears with a terminal grid (may be blank or garbled — that's fine at this stage).

- [ ] **Step 5: Commit**

```bash
git add src/apprt/win32/
git commit -m "apprt/win32: connect renderer pipeline, handle paint and resize"
```

---

## Phase 4: Input and PTY Connection

### Task 9: Keyboard Input

**Files:**
- Modify: `src/apprt/win32/Surface.zig`

- [ ] **Step 1: Translate Win32 key messages to Ghostty key events**

Handle `WM_KEYDOWN`, `WM_KEYUP`, `WM_CHAR`, and `WM_SYSKEYDOWN`:
1. Map Win32 virtual key codes to `input.Key` enum values
2. Extract modifier state (Shift, Ctrl, Alt) from `GetKeyState()`
3. Call `CoreSurface.keyCallback()` with the translated event
4. For text input, use `WM_CHAR` → `CoreSurface.textCallback()`

- [ ] **Step 2: Mouse input**

Handle `WM_MOUSEMOVE`, `WM_LBUTTONDOWN/UP`, `WM_RBUTTONDOWN/UP`, `WM_MOUSEWHEEL`:
1. Translate coordinates to surface-relative positions
2. Map button IDs to `input.MouseButton`
3. Call `CoreSurface.mouseButtonCallback()`, `cursorPosCallback()`, `scrollCallback()`

- [ ] **Step 3: Test typing in terminal**

Launch ghostty.exe on Windows with a cmd.exe shell. Expected: Can type characters and see output.

- [ ] **Step 4: Commit**

```bash
git add src/apprt/win32/Surface.zig
git commit -m "apprt/win32: keyboard and mouse input translation"
```

---

### Task 10: PTY and Shell Spawning

**Files:**
- Modify: `src/apprt/win32/Surface.zig`
- Verify: `src/pty.zig` (WindowsPty already implemented)
- Verify: `src/Command.zig` (startWindows already implemented)

- [ ] **Step 1: Verify PTY and Command work end-to-end**

The WindowsPty and Command.startWindows() are already implemented. Verify they work by:
1. Tracing through `termio.Exec` initialization with Windows branching
2. Ensuring the read thread (threadMainWindows) starts correctly
3. Confirming output from the child process reaches the terminal state machine

- [ ] **Step 2: Configure default shell**

Set up `defaultTermioEnv()` in Surface to provide:
- `TERM=xterm-256color` (or `ghostty` if terminfo is installed)
- `HOME` from `USERPROFILE` environment variable
- Default shell: `cmd.exe` or `powershell.exe` from `COMSPEC`/`WINDIR`

- [ ] **Step 3: Test interactive shell session**

Launch ghostty.exe. Expected: cmd.exe or PowerShell starts, can run commands, see output, navigate with arrows.

- [ ] **Step 4: Commit**

```bash
git add src/apprt/win32/
git commit -m "apprt/win32: PTY shell spawning and environment setup"
```

---

## Phase 5: Essential Features

### Task 11: Clipboard Support

**Files:**
- Modify: `src/apprt/win32/Surface.zig`

- [ ] **Step 1: Implement clipboard read**

Use Win32 clipboard API:
1. `OpenClipboard(hwnd)`
2. `GetClipboardData(CF_UNICODETEXT)`
3. Convert UTF-16LE to UTF-8
4. Complete the clipboard request via `CoreSurface`
5. `CloseClipboard()`

- [ ] **Step 2: Implement clipboard write**

1. `OpenClipboard(hwnd)`
2. `EmptyClipboard()`
3. Convert UTF-8 to UTF-16LE
4. `SetClipboardData(CF_UNICODETEXT, ...)`
5. `CloseClipboard()`

- [ ] **Step 3: Test copy/paste**

In ghostty, select text → Ctrl+Shift+C → Ctrl+Shift+V. Expected: Text is copied and pasted correctly.

- [ ] **Step 4: Commit**

```bash
git add src/apprt/win32/Surface.zig
git commit -m "apprt/win32: clipboard read/write via Win32 API"
```

---

### Task 12: DPI Awareness and Content Scaling

**Files:**
- Modify: `src/apprt/win32/Surface.zig`
- Modify: `src/apprt/win32/App.zig`

- [ ] **Step 1: Enable per-monitor DPI awareness**

The manifest file (`dist/windows/ghostty.manifest`) already declares DPI awareness. Implement:
1. `getContentScale()` using `GetDpiForWindow()` → scale = dpi / 96.0
2. Handle `WM_DPICHANGED` to update scale and resize window

- [ ] **Step 2: Test on high-DPI display**

Expected: Text renders crisply at 150%/200% scaling without blurriness.

- [ ] **Step 3: Commit**

```bash
git add src/apprt/win32/
git commit -m "apprt/win32: per-monitor DPI awareness and content scaling"
```

---

### Task 13: Window Title and Basic Actions

**Files:**
- Modify: `src/apprt/win32/App.zig`
- Modify: `src/apprt/win32/Surface.zig`

- [ ] **Step 1: Implement `performAction` for essential actions**

Handle key actions in `App.performAction()`:
- `set_title` → `SetWindowTextW(hwnd, title)`
- `quit` → `PostQuitMessage(0)`
- `close_window` → `DestroyWindow(hwnd)`
- `toggle_fullscreen` → Toggle between windowed and borderless fullscreen
- `new_window` → Create a new top-level window with a new surface
- `ring_bell` → `MessageBeep(0xFFFFFFFF)`

- [ ] **Step 2: Implement window title updates from shell**

Wire `set_title` from OSC sequences to `SetWindowTextW`.

- [ ] **Step 3: Test**

Run a command that sets the title (e.g., in bash: `echo -ne '\033]0;Hello\007'`). Expected: Window title changes.

- [ ] **Step 4: Commit**

```bash
git add src/apprt/win32/
git commit -m "apprt/win32: window title, quit, close, fullscreen actions"
```

---

## Phase 6: Font Discovery (Optional Enhancement)

### Task 14: Windows Font Discovery

**Files:**
- Create: `src/font/discovery/windows.zig`
- Modify: `src/font/discovery.zig`

- [ ] **Step 1: Implement registry-based font discovery**

Windows stores font file paths in `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts`. Create a discovery backend that:
1. Reads the registry key to get font name → file path mappings
2. Constructs full paths relative to `%WINDIR%\Fonts`
3. Matches requested font families against registry entries
4. Falls back to a default monospace font (Consolas, Cascadia Code)

- [ ] **Step 2: Wire into font backend selection**

Add a new font backend variant (e.g., `.windows_freetype`) or use the existing `.freetype` backend with a Windows-specific discovery plugin.

- [ ] **Step 3: Test font rendering with system fonts**

Configure `font-family = "Cascadia Code"` in ghostty config. Expected: Font loads and renders correctly.

- [ ] **Step 4: Commit**

```bash
git add src/font/discovery/windows.zig src/font/discovery.zig
git commit -m "font: Windows font discovery via registry"
```

---

## Phase 7: Polish and Distribution

### Task 15: Configuration Paths

**Files:**
- Modify: `src/config/` (as needed)

- [ ] **Step 1: Set up Windows config file location**

Ghostty config on Windows should live at `%APPDATA%\ghostty\config`. Ensure the config loader checks this path on Windows.

- [ ] **Step 2: Commit**

```bash
git add src/config/
git commit -m "config: Windows config file paths (%APPDATA%\\ghostty)"
```

---

### Task 16: CI Build for Windows

**Files:**
- Modify: `.github/workflows/test.yml` (or create new workflow)

- [ ] **Step 1: Update CI to build Windows target**

Change `continue-on-error: true` to a proper Windows build step:
```yaml
- name: Build Windows
  run: zig build -Dtarget=x86_64-windows-gnu -Dapp-runtime=win32
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/
git commit -m "ci: enable Windows build in CI"
```

---

## Dependency Summary

```
Phase 1 (Tasks 1-5): Build system & compilation fixes → must complete first
Phase 2 (Tasks 6-7): Minimal window → depends on Phase 1
Phase 3 (Task 8): Rendering pipeline → depends on Phase 2
Phase 4 (Tasks 9-10): Input/PTY → depends on Phase 3
Phase 5 (Tasks 11-13): Features → depends on Phase 4
Phase 6 (Task 14): Font discovery → independent, can start after Phase 1
Phase 7 (Tasks 15-16): Polish → after Phase 4
```

## Key References

- **Win32 runtime interface**: Must match signatures in `src/apprt/gtk/App.zig` (init, run, terminate, wakeup, performAction)
- **Surface interface**: Must match methods called on `rt_surface` by `src/Surface.zig` (getSize, getContentScale, getCursorPos, getTitle, close, supportsClipboard, clipboardRequest, setClipboard, defaultTermioEnv)
- **Action system**: See `src/apprt/action.zig` for all actions the runtime can receive
- **Existing Windows code**: `src/pty.zig` (WindowsPty), `src/os/windows.zig` (API wrapper), `src/Command.zig` (startWindows)
- **GTK reference**: `src/apprt/gtk/` is the reference implementation for a full runtime
- **Embedded reference**: `src/apprt/embedded.zig` shows the C ABI interface (alternative approach)

## Risk Areas

1. **libxev IOCP support**: The termio system depends on `libxev` for async I/O (process management, streaming, timers). libxev uses IOCP on Windows, but `xev.Process`, `xev.Stream`, and `xev.Timer` may behave differently or have limitations. Verify early in Phase 3 — if broken, this blocks the entire PTY pipeline.
2. **OpenGL context on Windows**: WGL setup can be tricky — need correct pixel format, possibly a temp context to load modern GL extensions via `wglCreateContextAttribsARB`. The GLAD loader needs `opengl32.dll` linked.
3. **Exhaustive switch statements**: Adding `.win32` to the Runtime enum breaks ~15+ switch statements across the codebase. Task 5 enumerates known locations, but there may be more. Cross-compilation testing is essential.
4. **Input method (IME)**: CJK input requires `ImmGetContext`/`WM_IME_*` messages — defer to later
5. **Multi-window**: Win32 supports multiple HWNDs easily, but thread safety with OpenGL contexts needs care
6. **Font fallback**: Without proper discovery, users must specify exact font paths — Phase 6 addresses this
7. **Shell integration**: bash/zsh integration scripts won't work on Windows — PowerShell integration is a separate effort
8. **Font discovery structure**: `src/font/discovery.zig` is a single file, not a directory. Windows font discovery may need to be added inline or the file restructured.
