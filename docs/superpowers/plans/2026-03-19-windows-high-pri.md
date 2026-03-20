# Windows Port High Priority Tasks

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix selection drag, detect process exit, fix clean shutdown, and add full font discovery for the Windows port.

**Architecture:** Four independent improvements to the Win32 apprt and supporting modules. Task 1 (selection) is a quick win. Task 2 (process exit) enables Task 3 (clean shutdown). Task 4 (font discovery) is independent and largest — adds DirectWrite COM bindings for system font enumeration with FreeType rendering.

**Tech Stack:** Win32 API, DirectWrite COM, FreeType, HarfBuzz, Zig

---

### Task 1: Fix Mouse Drag Selection with SetCapture

**Files:**
- Modify: `src/apprt/win32/Surface.zig:586-606` (handleMouseButton)
- Modify: `src/apprt/win32/win32.zig` (add SetCapture/ReleaseCapture externs)

- [ ] **Step 1: Add Win32 API declarations for mouse capture**

In `src/apprt/win32/win32.zig`, add:

```zig
pub extern "user32" fn SetCapture(
    hWnd: HWND,
) callconv(.c) ?HWND;

pub extern "user32" fn ReleaseCapture() callconv(.c) i32;
```

- [ ] **Step 2: Call SetCapture on mouse button press, ReleaseCapture on release**

In `src/apprt/win32/Surface.zig`, modify `handleMouseButton`:

```zig
pub fn handleMouseButton(
    self: *Surface,
    button: input.MouseButton,
    action: input.MouseButtonState,
    lparam: isize,
) void {
    if (!self.core_surface_ready) return;
    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
    const y: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));

    const mods = getModifiers();

    // Capture mouse on press so drag selection continues outside the window.
    if (action == .press) {
        if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
    } else {
        _ = w32.ReleaseCapture();
    }

    // Update cursor position first
    self.core_surface.cursorPosCallback(.{ .x = x, .y = y }, mods) catch |err| {
        log.err("cursor pos callback error: {}", .{err});
    };

    _ = self.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
        log.err("mouse button callback error: {}", .{err});
    };
}
```

- [ ] **Step 3: Build and verify**

Run: `zig build -Doptimize=Debug`
Expected: Builds without errors.

- [ ] **Step 4: Manual test**

Launch ghostty, select text by clicking and dragging outside the window boundary. Selection should continue tracking mouse position outside the window.

- [ ] **Step 5: Commit**

```bash
git add src/apprt/win32/Surface.zig src/apprt/win32/win32.zig
git commit -m "fix: mouse drag selection with SetCapture/ReleaseCapture on Win32"
```

---

### Task 2: Process Exit Detection

**Files:**
- Modify: `src/termio/Exec.zig:104-182` (threadEnter — spawn process watcher)
- Modify: `src/termio/Exec.zig:199-231` (threadExit — join watcher thread)
- Modify: `src/termio/Exec.zig:494-558` (ThreadData — add watcher thread field)
- Modify: `src/apprt/win32/win32.zig` (add WaitForSingleObject, GetExitCodeProcess)

- [ ] **Step 1: Verify Win32 API availability**

`WaitForSingleObject` and `GetExitCodeProcess` are already available via `std.os.windows.kernel32` (confirmed: used in `src/Command.zig:406,412`). No new externs needed. The `windows` import in Exec.zig (`internal_os.windows`) provides access to these.

- [ ] **Step 2: Add watcher thread field to ThreadData**

In `src/termio/Exec.zig`, in the `ThreadData` struct, add a field for the Windows process watcher thread:

```zig
/// Windows-only: a thread that waits for the child process to exit.
process_watcher_thread: if (builtin.os.tag == .windows) ?std.Thread else void =
    if (builtin.os.tag == .windows) null else {},
```

- [ ] **Step 3: Add the watcher thread function**

In `src/termio/Exec.zig`, add a new function near `processExit`/`processExitCommon`:

```zig
/// Windows-specific: thread that waits for the child process handle to
/// become signaled (i.e. the process exits), then pushes a child_exited
/// message to the surface mailbox.
///
/// SAFETY: `exited_flag` and `surface_mailbox` point into the ThreadData
/// struct, which outlives this thread (threadExit joins us before freeing
/// ThreadData). The process_handle is passed by value (a HANDLE is just
/// a pointer-sized value), so no lifetime concern there.
fn processExitWindows(
    process_handle: windows.HANDLE,
    exited_flag: *std.atomic.Value(bool),
    surface_mailbox: *apprt.surface.Mailbox,
    start: std.time.Instant,
) void {
    // Block until the process exits.
    const result = windows.kernel32.WaitForSingleObject(process_handle, windows.INFINITE);
    if (result == windows.WAIT_FAILED) {
        log.err("WaitForSingleObject failed for process watcher", .{});
        return;
    }

    // Get the exit code.
    var exit_code: windows.DWORD = undefined;
    if (windows.kernel32.GetExitCodeProcess(process_handle, &exit_code) == 0) {
        log.err("GetExitCodeProcess failed", .{});
        return;
    }

    // Mark as exited (read by threadExit to decide externalExit vs stop).
    exited_flag.store(true, .release);

    // Compute runtime.
    const runtime_ms: u64 = runtime: {
        const process_end = std.time.Instant.now() catch break :runtime 0;
        break :runtime process_end.since(start) / std.time.ns_per_ms;
    };

    log.debug("child process exited status={} runtime={}ms", .{ exit_code, runtime_ms });

    // Notify the surface. surface_mailbox is thread-safe.
    _ = surface_mailbox.push(.{
        .child_exited = .{
            .exit_code = exit_code,
            .runtime_ms = runtime_ms,
        },
    }, .{ .forever = {} });
}
```

Note: We cannot call `processExitCommon` directly because it accesses `td.backend.exec` fields that are not atomic. Instead, we set the atomic `exited` flag and push directly to the surface mailbox (which is thread-safe).

- [ ] **Step 4: Make `exited` flag atomic for cross-thread access**

On POSIX, `processExitCommon` sets `execdata.exited = true` from the xev event loop callback (same thread that reads it in `threadExit`). On Windows, the watcher thread sets it. So we need atomic access.

In `ThreadData` (line 501 of Exec.zig), change:
```zig
exited: bool = false,
```
to:
```zig
exited: if (builtin.os.tag == .windows) std.atomic.Value(bool) else bool =
    if (builtin.os.tag == .windows) std.atomic.Value(bool).init(false) else false,
```

Update `threadExit` (line 203 of Exec.zig) to read atomically on Windows:
```zig
if (comptime builtin.os.tag == .windows) {
    if (exec.exited.load(.acquire)) self.subprocess.externalExit();
} else {
    if (exec.exited) self.subprocess.externalExit();
}
```

Update `queueWrite` (line 415) which checks `exec.exited`:
```zig
if (comptime builtin.os.tag == .windows) {
    if (exec.exited.load(.acquire)) return;
} else {
    if (exec.exited) return;
}
```

**Invariant:** `td.backend` is set exactly once in `threadEnter` and not reassigned until `threadExit`, so pointers into `td.backend.exec` (like `&exec.exited`) are stable for the lifetime of the watcher thread.

- [ ] **Step 5: Spawn the watcher thread in threadEnter**

In `src/termio/Exec.zig`, in `threadEnter`, after setting up `td.backend`, add the Windows watcher:

```zig
// On Windows, spawn a thread to watch for process exit since we
// can't use xev.Process (posix.pid_t is void on Windows).
if (comptime builtin.os.tag == .windows) {
    if (self.subprocess.process) |proc| {
        switch (proc) {
            .fork_exec => |cmd| {
                if (cmd.pid) |handle| {
                    const exec = &td.backend.exec;
                    exec.process_watcher_thread = try std.Thread.spawn(
                        .{},
                        processExitWindows,
                        .{
                            handle,
                            &exec.exited,
                            &td.surface_mailbox,
                            exec.start,
                        },
                    );
                    if (exec.process_watcher_thread) |t|
                        t.setName("proc-watcher") catch {};
                }
            },
            else => {},
        }
    }
}
```

Note: Uses `exec.start` (from ThreadData, set at line 152) rather than the local `process_start` — they hold the same value, but `exec.start` is the canonical location. The `surface_mailbox` pointer is taken from `td` (the `termio.Termio.ThreadData`), which outlives the watcher thread since `threadExit` joins it before `td` is freed.

- [ ] **Step 6: Join the watcher thread in threadExit**

In `src/termio/Exec.zig`, in `threadExit`, after joining the read thread, join the watcher:

```zig
if (comptime builtin.os.tag == .windows) {
    if (exec.process_watcher_thread) |t| t.join();
}
```

Note: The watcher thread will naturally exit when the process exits. When we kill the process in `stop()`, the handle becomes signaled, so `WaitForSingleObject` returns immediately.

- [ ] **Step 7: Update ThreadData.deinit**

Add cleanup for the watcher thread field if needed (the thread itself is joined in threadExit, so no extra cleanup needed in deinit).

- [ ] **Step 8: Build and verify**

Run: `zig build -Doptimize=Debug`
Expected: Builds without errors.

- [ ] **Step 9: Manual test**

Launch ghostty, type `exit` in cmd.exe or PowerShell. Terminal should display "Process exited. Press any key to close the terminal." and pressing a key should close the window.

- [ ] **Step 10: Commit**

```bash
git add src/termio/Exec.zig src/apprt/win32/win32.zig
git commit -m "feat: detect child process exit on Windows via watcher thread"
```

---

### Task 3: Fix Clean Shutdown

**Files:**
- Modify: `src/apprt/win32/Surface.zig:127-153` (deinit)
- Modify: `src/apprt/win32/Surface.zig:441-462` (handleDestroy)
- Modify: `src/apprt/win32/App.zig:210-220` (quit_timer)

- [ ] **Step 1: Set core_surface_ready = false before deinit**

In `src/apprt/win32/Surface.zig`, in `handleDestroy`, add the guard before calling deinit:

```zig
pub fn handleDestroy(self: *Surface) void {
    const hwnd = self.hwnd;
    self.hwnd = null;

    // Prevent any further message handlers from touching core_surface
    // during teardown. Messages can arrive during DestroyWindow and
    // deinit (e.g. WM_SETFOCUS, WM_SIZE from style changes).
    self.core_surface_ready = false;

    if (hwnd) |h| {
        _ = w32.SetWindowLongPtrW(h, w32.GWLP_USERDATA, 0);
    }

    const alloc = self.app.core_app.alloc;
    self.deinit();
    alloc.destroy(self);
}
```

- [ ] **Step 2: Guard deinit against uninitialized core_surface**

Add a `core_surface_initialized` flag to `Surface` (separate from `core_surface_ready` which is cleared during shutdown):

In `src/apprt/win32/Surface.zig`, add field after `core_surface_ready` (line 45):
```zig
/// Whether core_surface.init() completed successfully (ever).
/// Different from core_surface_ready which is cleared during shutdown.
core_surface_initialized: bool = false,
```

In `init()`, at line 124 (right after `self.core_surface_ready = true`), add:
```zig
self.core_surface_initialized = true;
```

In `deinit()`, guard the core_surface cleanup:
```zig
pub fn deinit(self: *Surface) void {
    if (self.core_surface_initialized) {
        self.core_surface.deinit();
        self.app.core_app.deleteSurface(self);
    }

    // GL context and DC cleanup are guarded by their own null checks,
    // so they are safe to run regardless of core_surface state.
    if (self.hglrc) |hglrc| {
        _ = w32.wglMakeCurrent(null, null);
        _ = w32.wglDeleteContext(hglrc);
        self.hglrc = null;
    }

    if (self.hdc) |hdc| {
        if (self.hwnd) |hwnd| {
            _ = w32.ReleaseDC(hwnd, hdc);
        }
        self.hdc = null;
    }

    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}
```

- [ ] **Step 3: Reproduce and fix the alignment panic**

**Hypothesis:** The panic occurs because `handleDestroy` → `deinit` → `core_surface.deinit()` frees the IO thread's data, but the read thread (or new process watcher thread) is still running and references freed memory. On POSIX, `threadExit` writes to the quit pipe and then joins the read thread. On Windows, `threadExit` calls `CancelIoEx` then joins. If the ordering in `core_surface.deinit()` doesn't properly stop all threads before freeing, we crash.

**Concrete steps:**

1. Build debug: `zig build -Doptimize=Debug`
2. Launch ghostty, close window, capture the stack trace from the panic
3. Check the stack trace to identify which freed memory is being accessed:
   - If it's in the xev event loop: the IO thread's loop is still running completions after `threadExit` returns. Fix: ensure `threadExit` fully drains the loop before returning.
   - If it's in the renderer thread: the GL context is deleted before the renderer thread exits. Fix: join the renderer thread before deleting the WGL context in `Surface.deinit()`.
   - If it's in Win32 message dispatch: a WM_NCDESTROY or similar arrives after `alloc.destroy(self)`. Fix: the `GWLP_USERDATA = 0` guard (already present) should prevent this. If not, add a `PostQuitMessage` or similar to break the message loop.

4. If the crash is from the process watcher thread (Task 2): ensure `threadExit` joins the watcher thread BEFORE freeing any ThreadData. The join in Step 6 of Task 2 should handle this.

5. **Most likely fix:** Ensure the read thread is joined and the process watcher thread is joined in `threadExit` BEFORE any ThreadData fields are freed. Verify by checking that `exec.read_thread.join()` completes before `ThreadData.deinit()` runs.

**Success criteria:** Close the window 10 times without a panic. Test all close methods (X button, Alt+F4, `exit` command).

- [ ] **Step 4: Build and verify**

Run: `zig build -Doptimize=Debug`
Expected: Builds without errors.

- [ ] **Step 5: Manual test**

Launch ghostty, close the window. Should close cleanly without panic. Also test:
- Close via X button
- Close via Alt+F4
- Close via `exit` command (process exits, then window closes)
- Open multiple windows, close each one

- [ ] **Step 6: Commit**

```bash
git add src/apprt/win32/Surface.zig src/apprt/win32/App.zig
git commit -m "fix: clean shutdown on Windows — guard core_surface during teardown"
```

---

### Task 4: Font Discovery via DirectWrite

This is the largest task. It adds a full font discovery backend using DirectWrite COM APIs, allowing users to use any installed system font via `font-family` config.

**Files:**
- Create: `src/font/directwrite.zig` (DirectWrite COM interface definitions)
- Create: `src/font/discovery/DirectWrite.zig` (discovery implementation)
- Modify: `src/font/discovery.zig` (wire DirectWrite into Discover switch)
- Modify: `src/font/DeferredFace.zig` (add DirectWrite deferred face type)
- Modify: `src/font/backend.zig` (no change needed — keep `.freetype`, discovery is conditional)
- Modify: `src/font/main.zig` (export directwrite module if on windows)

#### Sub-task 4a: DirectWrite COM Interface Definitions

- [ ] **Step 1: Create `src/font/directwrite.zig` with COM interface definitions**

This file defines the Zig representations of the DirectWrite COM interfaces needed for font discovery. Each COM interface is an `extern struct` with a vtable pointer. Only the methods we actually call are included.

The full `src/font/directwrite.zig` file defines all COM interfaces needed. Each COM interface is an `extern struct` with a vtable pointer. **Critical: vtable method indices must exactly match the Windows SDK `dwrite.h` header.** Cross-reference with the SDK to verify.

The file contains:
- Enums: `DWRITE_FONT_WEIGHT`, `DWRITE_FONT_STYLE`, `DWRITE_FONT_STRETCH`, `DWRITE_FACTORY_TYPE`
- GUIDs: `IID_IDWriteFactory`
- COM interfaces with vtables (method indices noted from `dwrite.h`):
  - `IDWriteFactory` — vtable index 3: `GetSystemFontCollection`
  - `IDWriteFontCollection` — vtable index 3: `GetFontFamilyCount`, index 4: `FindFamilyName`, index 5: `GetFontFamily`
  - `IDWriteFontFamily` (inherits IDWriteFontList) — index 3: `GetFontCount`, index 4: `GetFont`, index 5: `GetFamilyNames`
  - `IDWriteFont` — index 3: `GetFontFamily`, index 4: `GetWeight`, index 5: `GetStyle`, index 6: `GetStretch`, index 7: `HasCharacter`, index 8: `CreateFontFace`
  - `IDWriteFontFace` — index 3: `GetType`, index 4: `GetFiles`, index 5: `GetIndex`
  - `IDWriteFontFile` — index 3: `GetReferenceKey`, index 4: `GetLoader`
  - `IDWriteLocalFontFileLoader` (inherits IDWriteFontFileLoader) — index 3+: `GetFilePathLengthFromKey`, `GetFilePathFromKey`
  - `IDWriteLocalizedStrings` — index 3: `GetCount`, index 4: `FindLocaleName`, index 5: `GetLocaleNameLength`, index 6: `GetLocaleName`, index 7: `GetStringLength`, index 8: `GetString`
- Helper: `queryInterface` generic function
- Entry point: `DWriteCreateFactory` extern

**Important vtable padding:** For interfaces where we skip methods, we must insert `*const fn() callconv(.c) void` padding entries at the correct indices. For example, `IDWriteFont` inherits from `IUnknown` (3 methods), then has its own methods. If `GetWeight` is at real vtable index 5 (after 3 IUnknown + 2 IDWriteFont methods we skip), we need 2 padding entries.

Key constants:
```zig
pub const IID_IDWriteFactory = windows.GUID{
    .Data1 = 0xb859ee5a,
    .Data2 = 0xd838,
    .Data3 = 0x4b5b,
    .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 },
};

pub const IID_IDWriteLocalFontFileLoader = windows.GUID{
    .Data1 = 0xb2d9f3ec,
    .Data2 = 0xc9fe,
    .Data3 = 0x4a11,
    .Data4 = .{ 0xa2, 0xec, 0xd8, 0x62, 0x08, 0xf7, 0xc0, 0xa2 },
};
```

Helper for COM QueryInterface:
```zig
pub fn queryInterface(comptime T: type, obj: anytype, iid: *const windows.GUID) ?*T {
    var result: ?*anyopaque = null;
    const unknown: *IUnknown = @ptrCast(obj);
    const hr = unknown.vtable.QueryInterface(unknown, iid, &result);
    if (hr != S_OK or result == null) return null;
    return @ptrCast(@alignCast(result.?));
}
```

Entry point:
```zig
pub extern "dwrite" fn DWriteCreateFactory(
    factoryType: DWRITE_FACTORY_TYPE,
    iid: *const windows.GUID,
    factory: *?*anyopaque,
) callconv(.c) HRESULT;
```

**Reference:** The exact vtable indices for each interface MUST be verified against `dwrite.h` from the Windows SDK (typically at `C:\Program Files (x86)\Windows Kits\10\Include\<version>\um\dwrite.h`). The indices listed above are from the SDK but should be re-verified during implementation. A single off-by-one causes a crash.

- [ ] **Step 2: Build and verify COM definitions compile**

Run: `zig build -Doptimize=Debug`
Expected: Builds (file imported but not yet used).

- [ ] **Step 3: Commit COM interface definitions**

```bash
git add src/font/directwrite.zig
git commit -m "feat: add DirectWrite COM interface definitions for font discovery"
```

#### Sub-task 4b: DirectWrite Discovery Implementation

- [ ] **Step 4: Create the discovery implementation**

Create `src/font/discovery/DirectWrite.zig` (or add `DirectWrite` struct directly into `src/font/discovery.zig` following the pattern of `Fontconfig` and `CoreText`).

Following the existing pattern (Fontconfig/CoreText are defined inline in discovery.zig), add the `DirectWrite` struct to `discovery.zig`:

```zig
pub const DirectWrite = struct {
    const dw = @import("directwrite.zig");

    factory: *dw.IDWriteFactory,
    collection: *dw.IDWriteFontCollection,

    pub fn init() DirectWrite {
        var factory: ?*dw.IDWriteFactory = null;
        const hr = dw.DWriteCreateFactory(
            .shared,
            &dw.IID_IDWriteFactory,
            &factory,
        );
        if (hr != dw.S_OK or factory == null) {
            // If DirectWrite is unavailable, this is a fatal error on Windows.
            @panic("Failed to create DirectWrite factory");
        }

        const collection = factory.?.getSystemFontCollection() catch
            @panic("Failed to get system font collection");

        return .{
            .factory = factory.?,
            .collection = collection,
        };
    }

    pub fn deinit(self: *DirectWrite) void {
        self.collection.release();
        self.factory.release();
    }

    pub fn discover(
        self: *const DirectWrite,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        // If a family name is specified, find it in the collection.
        // Otherwise, enumerate all font families (fallback search).
        var results = std.ArrayList(FontResult).init(alloc);
        errdefer results.deinit();

        if (desc.family) |family| {
            // Find the specific family
            try self.findFamily(alloc, family, desc, &results);
        } else {
            // Enumerate all families for fallback
            try self.enumerateAll(alloc, desc, &results);
        }

        // Sort results by match quality
        sortResults(desc, results.items);

        return DiscoverIterator{
            .alloc = alloc,
            .results = results.toOwnedSlice() catch &.{},
            .variations = desc.variations,
            .i = 0,
        };
    }

    pub fn discoverFallback(
        self: *const DirectWrite,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = collection;
        return try self.discover(alloc, desc);
    }

    /// Enumerate all font families in the system collection, filtering
    /// by the descriptor's codepoint requirement. Used for fallback
    /// discovery when no family name is specified.
    fn enumerateAll(
        self: *const DirectWrite,
        alloc: Allocator,
        desc: Descriptor,
        results: *std.ArrayList(FontResult),
    ) !void {
        const family_count = self.collection.getFontFamilyCount();
        for (0..family_count) |fi| {
            const font_family = self.collection.getFontFamily(@intCast(fi)) catch continue;
            defer font_family.release();

            const font_count = font_family.getFontCount();
            for (0..font_count) |i| {
                const font_obj = font_family.getFont(@intCast(i)) catch continue;
                defer font_obj.release();

                // For fallback, we must have the requested codepoint
                if (desc.codepoint > 0) {
                    var has_char: dw.BOOL = dw.FALSE;
                    _ = font_obj.hasCharacter(desc.codepoint, &has_char);
                    if (has_char == dw.FALSE) continue;
                }

                if (self.extractFontPath(alloc, font_obj)) |result| {
                    try results.append(result);
                } else |_| continue;
            }
        }
    }

    fn findFamily(
        self: *const DirectWrite,
        alloc: Allocator,
        family: [:0]const u8,
        desc: Descriptor,
        results: *std.ArrayList(FontResult),
    ) !void {
        // Convert family name to UTF-16 for DirectWrite
        const family_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, family);
        defer alloc.free(family_w);

        var index: u32 = 0;
        var exists: dw.BOOL = dw.FALSE;
        const hr = self.collection.findFamilyName(family_w, &index, &exists);
        if (hr != dw.S_OK or exists == dw.FALSE) return;

        const font_family = try self.collection.getFontFamily(index);
        defer font_family.release();

        // Enumerate all fonts in this family
        const count = font_family.getFontCount();
        for (0..count) |i| {
            const font = font_family.getFont(@intCast(i)) catch continue;
            defer font.release();

            // Check codepoint if requested
            if (desc.codepoint > 0) {
                var has_char: dw.BOOL = dw.FALSE;
                _ = font.hasCharacter(desc.codepoint, &has_char);
                if (has_char == dw.FALSE) continue;
            }

            // Extract file path
            if (self.extractFontPath(alloc, font)) |result| {
                try results.append(result);
            } else |_| continue;
        }
    }

    fn extractFontPath(
        self: *const DirectWrite,
        alloc: Allocator,
        font: *dw.IDWriteFont,
    ) !FontResult {
        _ = self;

        const face = try font.createFontFace();
        defer face.release();

        // Get the font file
        var file_count: u32 = 0;
        var hr = face.getFiles(&file_count, null);
        if (hr != dw.S_OK or file_count == 0) return error.DirectWriteFailed;

        var files: [1]*dw.IDWriteFontFile = undefined;
        hr = face.getFiles(&file_count, &files);
        if (hr != dw.S_OK) return error.DirectWriteFailed;
        defer files[0].release();

        // Get the file path via the local file loader
        var ref_key: *const anyopaque = undefined;
        var ref_key_size: u32 = 0;
        hr = files[0].getReferenceKey(&ref_key, &ref_key_size);
        if (hr != dw.S_OK) return error.DirectWriteFailed;

        var loader: ?*dw.IDWriteFontFileLoader = null;
        hr = files[0].getLoader(&loader);
        if (hr != dw.S_OK or loader == null) return error.DirectWriteFailed;

        // Try to cast to local file loader via QueryInterface
        const local_loader = dw.queryInterface(
            dw.IDWriteLocalFontFileLoader,
            loader.?,
            &dw.IID_IDWriteLocalFontFileLoader,
        ) orelse return error.DirectWriteFailed;
        defer local_loader.release();

        // Get the file path
        var path_len: u32 = 0;
        hr = local_loader.getFilePathLengthFromKey(ref_key, ref_key_size, &path_len);
        if (hr != dw.S_OK) return error.DirectWriteFailed;

        const path_buf = try alloc.alloc(u16, path_len + 1);
        defer alloc.free(path_buf);
        hr = local_loader.getFilePathFromKey(ref_key, ref_key_size, path_buf.ptr, path_len + 1);
        if (hr != dw.S_OK) return error.DirectWriteFailed;

        // Convert UTF-16 path to UTF-8
        const path_utf8 = try std.unicode.utf16LeToUtf8AllocZ(alloc, path_buf[0..path_len]);

        // Get font names via IDWriteFont → IDWriteFontFamily → GetFamilyNames
        // and IDWriteFont → GetInformationalStrings for full name.
        // (Implementation: use IDWriteLocalizedStrings to extract en-us name,
        //  convert from UTF-16 to UTF-8 via std.unicode.utf16LeToUtf8AllocZ)
        const family_name = self.getFontFamilyName(alloc, font) catch try alloc.dupeZ(u8, "");
        const full_name = self.getFontFullName(alloc, font) catch try alloc.dupeZ(u8, "");

        return FontResult{
            .path = path_utf8,
            .face_index = face.getIndex(),
            .weight = font.getWeight(),
            .style = font.getStyle(),
            .has_codepoint = true, // already filtered
            .family_name = family_name,
            .full_name = full_name,
        };
    }

    const FontResult = struct {
        path: [:0]const u8,
        face_index: u32,
        weight: dw.DWRITE_FONT_WEIGHT,
        style: dw.DWRITE_FONT_STYLE,
        has_codepoint: bool,
        family_name: [:0]const u8,
        full_name: [:0]const u8,
    };

    fn sortResults(desc: Descriptor, results: []FontResult) void {
        // Sort by match quality: prefer exact weight/style match
        std.mem.sortUnstable(FontResult, results, &desc, struct {
            fn lessThan(d: *const Descriptor, a: FontResult, b: FontResult) bool {
                const a_score = scoreResult(d, a);
                const b_score = scoreResult(d, b);
                return a_score > b_score;
            }
        }.lessThan);
    }

    fn scoreResult(desc: *const Descriptor, result: FontResult) u32 {
        var score: u32 = 0;
        const is_bold = @intFromEnum(result.weight) >= 600;
        const is_italic = result.style != .normal;
        if (desc.bold == is_bold) score += 2;
        if (desc.italic == is_italic) score += 2;
        if (result.has_codepoint) score += 4;
        // Prefer normal weight when no bold requested
        if (!desc.bold and @intFromEnum(result.weight) == 400) score += 1;
        return score;
    }

    pub const DiscoverIterator = struct {
        alloc: Allocator,
        results: []FontResult,
        variations: []const Variation,
        i: usize,

        pub fn deinit(self: *DiscoverIterator) void {
            for (self.results) |r| {
                self.alloc.free(r.path);
            }
            self.alloc.free(self.results);
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            if (self.i >= self.results.len) return null;
            defer self.i += 1;

            const result = &self.results[self.i];
            const deferred = DeferredFace{
                .dw = .{
                    .path = result.path,
                    .face_index = result.face_index,
                    .variations = self.variations,
                    .family_name = result.family_name,
                    .full_name = result.full_name,
                },
            };
            // Transfer ownership: mark result as consumed so deinit
            // doesn't free paths that are now owned by the DeferredFace.
            result.path = "";
            result.family_name = "";
            result.full_name = "";
            return deferred;
        }
    };
};
```

- [ ] **Step 5: Wire DirectWrite into the Discover switch**

In `src/font/discovery.zig`, modify the `Discover` type:

```zig
const builtin = @import("builtin");

pub const Discover = switch (options.backend) {
    .freetype => if (builtin.os.tag == .windows) DirectWrite else void,
    .fontconfig_freetype => Fontconfig,
    .web_canvas => void,
    .coretext, .coretext_freetype, .coretext_harfbuzz, .coretext_noshape => CoreText,
};
```

- [ ] **Step 6: Add DirectWrite deferred face type to DeferredFace.zig**

In `src/font/DeferredFace.zig`, add:

```zig
const directwrite = if (@import("builtin").os.tag == .windows) @import("directwrite.zig") else struct {};

/// DirectWrite (Windows)
dw: if (@import("builtin").os.tag == .windows and font.Discover == font.discovery.DirectWrite)
    ?DirectWriteFace
else
    void = if (@import("builtin").os.tag == .windows and font.Discover == font.discovery.DirectWrite)
    null
else {},

pub const DirectWriteFace = struct {
    /// Path to the font file (UTF-8, null-terminated).
    path: [:0]const u8,
    /// Face index within the font file (for .ttc collections).
    face_index: u32,
    /// Variation axes to apply.
    variations: []const font.face.Variation,

    pub fn deinit(self: *DirectWriteFace) void {
        // Path is owned by the discovery iterator's results,
        // which is freed when the iterator is deinited.
        // Nothing to free here.
        self.* = undefined;
    }
};
```

**All switch statements in DeferredFace.zig that have `.freetype` arms must be updated.** Here is every switch that needs changes:

**`deinit` (line 87):** Change `.freetype => {},` to:
```zig
.freetype => if (@import("builtin").os.tag == .windows) {
    if (self.dw) |*dw_face| dw_face.deinit();
} else {},
```

**`familyName` (line 101):** Change `.freetype => {},` to:
```zig
.freetype => if (@import("builtin").os.tag == .windows) {
    if (self.dw) |dw_face| return dw_face.family_name;
} else {},
```
(This requires adding `family_name: [:0]const u8` to `DirectWriteFace` — see below.)

**`name` (line 131):** Change `.freetype => {},` to:
```zig
.freetype => if (@import("builtin").os.tag == .windows) {
    if (self.dw) |dw_face| return dw_face.full_name;
} else {},
```
(This requires adding `full_name: [:0]const u8` to `DirectWriteFace` — see below.)

**`load` (line 165):** Change `.freetype => unreachable,` to:
```zig
.freetype => if (@import("builtin").os.tag == .windows)
    try self.loadDirectWrite(lib, opts)
else
    unreachable,
```

Add the load function:
```zig
fn loadDirectWrite(self: *DeferredFace, lib: Library, opts: font.face.Options) !Face {
    const dw_face = self.dw.?;
    var face = try Face.initFile(lib, dw_face.path, @intCast(dw_face.face_index), opts);
    errdefer face.deinit();
    try face.setVariations(dw_face.variations, opts);
    return face;
}
```

**`hasCodepoint` (line 266):** Change `.freetype => {},` to:
```zig
.freetype => if (@import("builtin").os.tag == .windows) {
    if (self.dw) |dw_face| {
        // Load the font with FreeType to check glyph coverage.
        // This is the slow path — only called during fallback resolution.
        var face = Face.initFile(
            @import("main.zig").Library.init(std.heap.page_allocator) catch return false,
            dw_face.path,
            @intCast(dw_face.face_index),
            .{ .size = .{ .points = 12 } },
        ) catch return false;
        defer face.deinit();
        return face.glyphIndex(cp) != null;
    }
} else {},
```

Note: The `hasCodepoint` FreeType approach is expensive (loads the entire font). A better approach for production is to cache the FreeType face or store a codepoint bitmap during discovery. For the initial implementation, this works but should be optimized later.

**Updated `DirectWriteFace` struct** (adds name fields for `familyName`/`name` support):
```zig
pub const DirectWriteFace = struct {
    path: [:0]const u8,
    face_index: u32,
    variations: []const font.face.Variation,
    family_name: [:0]const u8,
    full_name: [:0]const u8,

    pub fn deinit(self: *DirectWriteFace) void {
        // Note: path, family_name, and full_name are owned by the
        // DiscoverIterator results (allocated during discovery).
        // The DeferredFace does NOT own this memory — it borrows it.
        // The DiscoverIterator must outlive the DeferredFace, which is
        // guaranteed by the font collection's lifecycle.
        self.* = undefined;
    }
};
```

**Memory ownership clarification:** The `path`, `family_name`, and `full_name` strings are allocated during discovery by the `DirectWrite.extractFontPath` method using the allocator passed to `discover()`. The `DiscoverIterator.deinit()` frees all `FontResult` paths. However, once a `DeferredFace` is returned from `next()`, the font collection takes ownership. **The DiscoverIterator must NOT free paths for results that were returned via `next()`.** Fix: track which results were consumed:

```zig
pub fn next(self: *DiscoverIterator) !?DeferredFace {
    if (self.i >= self.results.len) return null;
    const result = self.results[self.i];
    self.results[self.i].path = ""; // Mark as consumed (deinit skips empty paths)
    defer self.i += 1;
    return DeferredFace{ .dw = .{ ... } };
}

pub fn deinit(self: *DiscoverIterator) void {
    for (self.results) |r| {
        if (r.path.len > 0) self.alloc.free(r.path);
        // Also free family_name, full_name if not consumed
    }
    self.alloc.free(self.results);
}
```

- [ ] **Step 7: Add dwrite to the build system**

In `src/build/SharedDeps.zig`, line 547-554, in the `.win32 => { ... }` block, add `dwrite` alongside the existing Windows libraries:

```zig
.win32 => {
    // Link Windows system libraries for Win32 runtime
    if (step.rootModuleTarget().os.tag == .windows) {
        step.linkSystemLibrary2("opengl32", .{});
        step.linkSystemLibrary2("gdi32", .{});
        step.linkSystemLibrary2("user32", .{});
        step.linkSystemLibrary2("dwrite", .{});  // <-- ADD THIS
    }
},
```

This is required because `extern "dwrite"` in directwrite.zig needs the linker to find `dwrite.lib`.

- [ ] **Step 8: Build and verify**

Run: `zig build -Doptimize=Debug`
Expected: Builds without errors. DirectWrite factory creation happens at runtime.

- [ ] **Step 9: Manual test — system font**

Set in `%APPDATA%\ghostty\config`:
```
font-family = Consolas
```

Launch ghostty. Text should render in Consolas instead of JetBrains Mono.

- [ ] **Step 10: Manual test — bold/italic**

Set config:
```
font-family = Cascadia Code
```

Run `echo -e "\e[1mbold\e[0m \e[3mitalic\e[0m \e[1;3mbold italic\e[0m"` in a shell. Bold, italic, and bold-italic should render with correct font variants.

- [ ] **Step 11: Manual test — fallback for codepoint**

Type or cat a file with emoji (e.g., `echo 🎉`). The emoji should render using a fallback font discovered via DirectWrite (e.g., Segoe UI Emoji).

- [ ] **Step 12: Commit**

```bash
git add src/font/directwrite.zig src/font/discovery.zig src/font/DeferredFace.zig src/font/main.zig
git commit -m "feat: add DirectWrite font discovery for Windows"
```

---

## Implementation Notes

### Build requirements
- No new external dependencies. DirectWrite ships with Windows 7+.
- `dwrite.dll` is loaded at link time via `extern "dwrite"`.
- FreeType and HarfBuzz are already linked for the `.freetype` backend.

### Testing strategy
- Tasks 1-3: manual testing (Win32 message loop and process lifecycle don't lend to unit tests)
- Task 4: the discovery code can be unit tested by searching for known system fonts (e.g., "Consolas", "Arial") on any Windows machine

### Risk areas
- **COM vtable layout**: DirectWrite COM vtables must have methods at exact indices. A single wrong index means calling the wrong method (likely crash). The vtable definitions must match the official DirectWrite headers exactly. Reference: `dwrite.h` from the Windows SDK.
- **Thread safety in Task 2**: The `exited` flag is written from the watcher thread and read from the IO thread's exit path. Using `std.atomic.Value(bool)` ensures correctness.
- **Task 3 debugging**: The alignment panic may require runtime debugging to identify the exact crash site. The plan includes investigation steps but the fix may differ from what's outlined.
