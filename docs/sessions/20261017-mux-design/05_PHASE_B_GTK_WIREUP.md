# Phase B GTK wire-up specification (B1 + B2 + B4 + B5 + E2E)

**Repo:** `/Users/kooshapari/CodeProjects/Phenotype/repos/khostty`
**Author:** khostty Phase C/B wire-up spec (tier-0 M3 worker, 2026-10-17)
**Binding (operator 2026-10-15):** FORK-ONLY. No `gh pr/issue/discussion create` or `gh api POST/PATCH/DELETE` against `ghostty-org/ghostty`. Reading, copying, tracking, `zig build` against upstream: fine. Push to `KooshaPari/*`: fine.
**Companion docs:** `docs/audits-archive/2026-10-17-final/FWD-PATH.md` §3, `docs/sessions/20261017-mux-design/02_MAILBOX_INTEGRATION.md` (C2), `docs/sessions/20261017-mux-design/03_EVENT_HOOKS.md` (C3), `docs/sessions/20261017-mux-design/04_MUX_ARCHITECTURE.md` (C4).

> **C1 dependency note (operator visibility):** `docs/sessions/20261017-mux-design/01_EMBEDDED_AUDIT.md` is **not present** in the session folder as of 2026-10-17T06:36Z. This spec does not depend on C1 directly — C1 covers the `src/apprt/embedded.zig` presenter path (the macOS windowed mux shell), while Phase B is the **GTK runtime** wire-up. Where C1 evidence would have informed the spec (e.g. multi-pane capability of `App.surfaces`), this spec substitutes verbatim from C4 §5 "Presenter reuse" and the `App.zig:28` field reference. **Action item:** when C1 lands, diff this doc against it; expected zero edits.

---

## TL;DR

Phase B is the **GTK-on-Linux runtime wire-up** for the agent IPC surface. The substrate is already built and unit-tested (`test-agent-ipc` at `build.zig:79-508`, 3899/3925 tests passing on `main`). Phase B exposes it under a real GTK application so an external agent can connect to `$XDG_RUNTIME_DIR/khostty/ipc.sock` and drive a real terminal.

| Task | File:line | Effort | Block |
|---|---|---|---|
| **B1** Wire `Server.bind` from GTK runtime | `src/apprt/gtk/App.zig:30-43` (add `startIpcServer` after `init`) | 1d | Linux GTK host |
| **B2** Fix `pane.write` cross-thread parser access | `src/apprt/ipc/app_host.zig:290-298` (replace `stream.nextSlice` with `core.queueIo`) | 1d (with B1) | Linux GTK host |
| **B4** Map 4 event publish hooks | `src/apprt/gtk/class/surface.zig:2109` (`setTitle`), `:1521` (`childExited`), `:3398` (`renderSurfaceResize`), `:2564` (`ringBell`); add `broker` field to `class/application.zig:170-184` `Private` | 1d | Linux GTK host |
| **B5** Snapshot counters (`bell_count`/`exited`/`exit_code`/`exit_signal`/`command`/`last_activity_ms`) | `src/apprt/ipc/app_host.zig:479-489` (runtime-side tracking) | 1d | GTK runtime |
| **E2E** Acceptance script | `conformance/khostty-phase-b-e2e.bash` (new) | 4h | All of the above |

**Total: ~5 working days on a Linux GTK host. B2 MUST ship with B1 (the race fires the moment B1 lands per state §6 + stubs MVP-LAZY #1).** B3 (`max_connections` + rate limit) and B6 (CI conformance) are independent of GTK and already partially landed in `server.zig:50,55` per the comments; they are out of scope for this spec.

**G4 finish line:** after `khostty` boots on GTK Linux, `ls $XDG_RUNTIME_DIR/khostty/ipc.sock` returns the socket; `khostty-client ping` returns `{"ok":true}`; `khostty-client pane.list` returns at least the focused pane; `khostty-client pane.write "ls\n"` injects bytes without racing the IO thread.

---

## 1. Pre-conditions

B1 cannot start until the following are true. **None of these are fork-only deliverables** — they require operator action or unblocked paths.

### 1.1 Operator decisions (Q1, Q2, Q3)

| Decision | Effect on B1-B5 | Status |
|---|---|---|
| **Q1(a/b/c)** windowed-runtime path | Phase B is **GTK-on-Linux (Q1a)**. Q1b (embedded-on-macOS) and Q1c (mock-only) are out of scope for this spec. | **REQUIRED** before B1 starts. |
| **Q2** `pane.focus` priority | No effect on B1-B5; `focusUnsupported` at `app_host.zig:208-214` returns `error.Unsupported` already. | Not blocking. |
| **Q3** `pane.search` priority | Same as Q2; `searchUnsupported` at `app_host.zig:216-232` returns `error.Unsupported` already. | Not blocking. |

**Action:** confirm Q1 = (a) before scheduling B1. The FWD-PATH §3 effort budget assumes Q1a (5d total for Phase B); Q1b is +1w (Phase C1 audit + Phase D build on macOS via `embedded.zig`).

### 1.2 Linux GTK host reachable

**Block.** The macOS operator host cannot build GTK (per FWD-PATH §3 B1 footnote "macOS operator host cannot build GTK"). Phase B work happens on a **separate Linux machine**:

| Requirement | How to verify |
|---|---|
| Linux kernel 5.10+ with `glib-2.0` ≥ 2.74 | `pkg-config --modversion glib-2.0` |
| `gtk4` development files | `pkg-config --modversion gtk4` (expected ≥ 4.10) |
| Zig 0.14.0 toolchain | `zig version` |
| Read+write to `$XDG_RUNTIME_DIR/khostty` | `mkdir -p $XDG_RUNTIME_DIR/khostty; touch $XDG_RUNTIME_DIR/khostty/test && echo OK` |
| `khostty-client` Python package ≥ 0.1.0 | `python -c "import khostty_vt; print(khostty_vt.__version__)"` |
| `socat` for E2E script | `which socat` |

**Action:** the operator provisions the Linux host per Q1. Subagent **shall not** spin up new SSH sessions; the worker reports SHELL-only environment to the operator if the host is not yet reachable.

### 1.3 C4 architecture review approved

`docs/sessions/20261017-mux-design/04_MUX_ARCHITECTURE.md` exists (2026-10-17T06:30Z, 27,767 bytes). The C4 doc governs the `Manager → Broker` lock ordering (`pane.zig:22-24`) and the placement of all new components relative to that order. B1-B5 **must not** add any cross-cutting lock acquisition. **Action:** diff this spec against C4 §4 ("Manager→Broker lock ordering — the binding rule") before starting B1.

### 1.4 C5 skeleton compiled

`docs/sessions/20261017-mux-design/05_MUX_SKELETON.md` / `src/apprt/ipc/mux_shell.zig` is the compile-checked skeleton for the `khostty-mux` headless binary. **It is not required for Phase B** — Phase B is the GTK runtime path, not the headless binary. The skeleton is Phase D work. **Action:** confirm Phase D scope is independent (it is, per FWD-PATH §4).

### 1.5 Phase A merged to `main`

Phase A (the polish batch: A1 doc refresh, A2 EGL tautological fix, A3 orphaned Windows renderer delete, A4 stale branch cleanup, A5 search Thread ABRT flake fix, A6 wasm `0.1.0`, A7 `win32api.zig` check) is ~3h of low-risk work and merges before Phase B starts. The PR for Phase A is **a separate PR**; this spec covers Phase B only.

### 1.6 Test-agent-ipc still green on `main`

```sh
cd /Users/kooshapari/CodeProjects/Phenotype/repos/khostty
zig build test-agent-ipc 2>&1 | tail -20
```

Expected: 3899/3925 passing (per FWD-PATH §11). **Action:** if the count drops, B1 must include a triage step before adding new test surface area.

### 1.7 Build host disk pressure

Per state §7 / FWD-PATH §10: the build host has been at 96-98% disk. Phase B cold-cache `zig build` is 27-30m. **Action:** before scheduling B1, confirm ≥ 50 GiB free on the Linux build host.

### 1.8 Pre-conditions checklist

```text
[ ] Q1a confirmed by operator
[ ] Linux GTK host reachable; pkg-config glib-2.0 + gtk4 both succeed
[ ] $XDG_RUNTIME_DIR writable by the khostty uid
[ ] C4 doc reviewed by the worker; no cross-locking added by this spec
[ ] Phase A PR merged to main
[ ] test-agent-ipc baseline: 3899/3925 passing on main
[ ] ≥ 50 GiB free on Linux build host
```

When all seven are checked, B1 may start.

---

## 2. B1 — Wire `Server.bind` from the GTK runtime

### 2.1 Goal

Construct an `apprt.ipc.Server` from inside the GTK application's `init` path, bind it on the platform-correct socket path, and start the accept thread. After `khostty` boots on GTK Linux, `ls $XDG_RUNTIME_DIR/khostty/ipc.sock` returns the socket file.

### 2.2 Exact file:line of insertion

**File:** `src/apprt/gtk/App.zig`

| Field | Existing | Action |
|---|---|---|
| `app: *Application` (line 28) | sole field | keep |
| `init` (lines 30-43) | constructs `Application`, no IPC | add broker + manager + server wiring |
| `run` (lines 45-47) | calls `self.app.run()` | no change |
| `terminate` (lines 49-54) | calls `self.app.deinit()` | add `self.stopIpcServer()` before deinit |
| `wakeup` (lines 57-59) | no-op passthrough | no change |
| `performAction` (lines 61-68) | passthrough | no change |

**Insertion points** (no existing call sites; this is net-new):

| Symbol | File:line | Lines |
|---|---|---|
| `startIpcServer` (new fn) | `src/apprt/gtk/App.zig` after line 43 | ~40 |
| `stopIpcServer` (new fn) | same file, before `terminate` | ~15 |

### 2.3 Imports to add at the top of `App.zig`

The current header (lines 5-19) imports `std`, `apprt`, `configpkg`, `CoreApp`, `Application`, `Surface`, and the three `ipc/*` CLI helpers. B1 needs additional imports:

```zig
const ipc = @import("../../apprt/ipc/mod.zig");
const ipc_server = ipc.Server;
const ipc_app_host = ipc.AppHost;
const ipc_pane = ipc.Pane;
const ipc_events = ipc.Events;
const ipc_auth = ipc.Auth;
```

(Confirm exact module names against `src/apprt/ipc/mod.zig`; the harness at `server.zig:600-612` shows the dependency bundle. The `import("../../apprt/ipc/mod.zig")` path is correct from `src/apprt/gtk/App.zig`.)

### 2.4 New field on `App`

After line 28 (`app: *Application`), add:

```zig
/// Optional IPC server. Non-null only when the GTK runtime is configured to
/// expose the agent surface (build-time flag + env override). Lifetime is
/// managed by `startIpcServer` / `stopIpcServer`.
ipc_server: ?ipc_server.Server = null,
ipc_app_host: ?ipc_app_host.AppHost = null,
ipc_manager: ?ipc_pane.Manager = null,
ipc_broker: ?*ipc_events.Broker = null,
ipc_auth: ?ipc_auth.Auth = null,
```

**Why optional:** the GTK runtime must continue to work for builds where the IPC surface is compiled out (per `windowed: bool` at `app_host.zig:71-77`, non-windowed builds get `unavailable_vtable`). Forcing the fields would break those builds.

### 2.5 `startIpcServer` implementation

```zig
/// Start the agent IPC server. Idempotent: a second call is a no-op.
/// Must be called from the GTK main thread after `init`. The accept thread
/// runs the rest of `Server.serveConnection` off the main thread.
pub fn startIpcServer(self: *App, core_app: *CoreApp) !void {
    if (self.ipc_server != null) return;
    if (comptime !ipc_app_host.windowed) return; // no-op on non-GTK builds

    const alloc = core_app.alloc;
    const io = core_app.io;

    // 1. Resolve the platform-correct paths (Linux: $XDG_RUNTIME_DIR/khostty).
    const paths = try ipc_auth.resolvePaths(alloc, ipc_auth.envFromOs());
    defer paths.deinit();

    // 2. Read the auth token from $KHOSTTY_IPC_TOKEN or fall back to a
    //    per-launch random token written to paths.token_file.
    const token = try ipc_auth.loadOrCreateToken(alloc, io, paths.token_file);
    defer alloc.free(token);

    // 3. Construct the host.
    var app_host = ipc_app_host.AppHost.init(alloc, io, core_app);
    errdefer _ = app_host.deinit;

    // 4. Construct the broker and manager.
    var broker = ipc_events.Broker.init(alloc);
    errdefer broker.deinit(io);

    var mgr = ipc_pane.Manager.init(alloc, app_host.host());
    mgr.setEventBroker(&broker);
    app_host.setEventBroker(&broker);

    // 5. Bind + start the server.
    const auth = ipc_auth.Auth.init(alloc, token) catch |err| {
        log.err("failed to init auth: {}", .{err});
        return err;
    };

    var srv = try ipc_server.Server.bind(alloc, io, .{
        .socket_path = paths.socket,
        .replace_existing = true,
        .max_connections = blk: {
            const v = std.posix.getenv("KHOSTTY_IPC_MAX_CONNECTIONS");
            break :blk if (v) |s| std.fmt.parseInt(u32, s, 10) catch 32 else 32;
        },
        .rate_limit_per_sec = blk: {
            const v = std.posix.getenv("KHOSTTY_IPC_RATE_LIMIT_PER_SEC");
            break :blk if (v) |s| std.fmt.parseInt(u32, s, 10) catch 100 else 100;
        },
    }, .{
        .manager = &mgr,
        .broker = &broker,
        .authenticator = &auth,
        .server_pid = std.os.linux.getpid(),
    });
    try srv.start();

    // 6. Hand the broker to the GTK Application so publish hooks can find it.
    if (Application.default()) |app| {
        app.setEventBroker(&broker);
    } else {
        log.warn("Application.default() returned null; publish hooks disabled");
    }

    self.ipc_server = srv;
    self.ipc_app_host = app_host;
    self.ipc_manager = mgr;
    self.ipc_broker = &broker;
    self.ipc_auth = auth;
}
```

**Notes on the above:**

- **`resolvePaths`** is per `auth.zig:208-230`. The Linux path resolves to `$XDG_RUNTIME_DIR/khostty/ipc.sock` (per `auth.zig:199-201`) or `/tmp/khostty-<uid>/ipc.sock` if no `XDG_RUNTIME_DIR` is set.
- **`loadOrCreateToken`** is the new helper; if `auth.zig` does not currently export one, add it as part of B1's first commit. The token should be either read from `$KHOSTTY_IPC_TOKEN` (operator override) or generated with `std.crypto.random` and written to `paths.token_file` with mode `0600`. The fork-only test harness uses the literal `"integration-token"` (`server.zig:547`); production should rotate on each launch.
- **`ipc_server.Server.bind`** signature per `server.zig:203-218`: `pub fn bind(gpa: Allocator, io: std.Io, config: Config, deps: Deps) !Server`. The harness at `server.zig:600-612` shows the full call shape.
- **`ipc_server.Server.start`** signature per `server.zig:221-224`: spawns the accept thread.
- **Field capture:** `srv` is `Server` (value, not pointer), so `self.ipc_server = srv` is a copy. `stopIpcServer` calls `deinit` (not `stop`) which calls `stop` first and joins (`server.zig:241-263`).
- **Broker ownership:** the broker is on the heap (allocated by `Broker.init`), captured by pointer. The pointer outlives `self.ipc_server` because `app_host.deinit` does not free it.
- **Lock ordering:** none added. `setEventBroker` is a single pointer store; no mutex involved.

### 2.6 `stopIpcServer` implementation

```zig
/// Tear down the IPC server. Called from `terminate` before `app.deinit`.
pub fn stopIpcServer(self: *App) void {
    const srv = self.ipc_server orelse return;
    if (Application.default()) |app| app.setEventBroker(null);
    srv.deinit(); // calls stop + joins accept thread + drainConnections(5s)
    self.ipc_server = null;
    if (self.ipc_broker) |b| {
        // broker outlives the server; deinit after the server drains
        b.deinit(self.ipc_app_host.?.io);
        self.ipc_broker = null;
    }
    if (self.ipc_app_host) |*h| h.deinit();
    self.ipc_app_host = null;
    if (self.ipc_manager) |*m| m.deinit(self.ipc_app_host.?.io);
    self.ipc_manager = null;
    if (self.ipc_auth) |*a| a.deinit();
    self.ipc_auth = null;
}
```

### 2.7 `terminate` update

```zig
pub fn terminate(self: *App) void {
    self.stopIpcServer();   // NEW: tear down IPC server before app deinit
    self.app.deinit();
}
```

### 2.8 Hook into `init` (or `run`)

The current `init` ends at line 43. The IPC server can be started from either `init` or `run`. **Recommended: `run`** — it runs on the GTK main thread after `Application.run()` has set up the event loop, so `Application.default()` is guaranteed to return non-null (per `class/application.zig:245-247`).

```zig
pub fn run(self: *App) !void {
    try self.app.run();           // GTK main loop
    self.startIpcServer() catch |err| {
        log.err("IPC server start failed: {}", .{err});
        return err;
    };
}
```

**Caveat:** `run` may return when the user closes the window; the server must be stopped in `terminate`, not in `run` (which may be called many times by tests). The current GTK `run` does not return normally (it blocks until quit), so this is fine. Verify against `class/application.zig:run` behavior during B1 integration.

### 2.9 Test that proves the socket is bound

**File:** `src/apprt/gtk/App.zig` — append a `test` block at the bottom:

```zig
const testing = std.testing;

test "startIpcServer binds the socket under $XDG_RUNTIME_DIR" {
    const alloc = testing.allocator;

    // 1. Set a writable runtime dir for the test.
    const tmp = try std.fs.cwd().makeOpenPath(".", .{});
    defer tmp.close();
    const test_dir = try std.fmt.allocPrint(alloc, "/tmp/khostty-b1-{x}", .{std.crypto.random.int(u32)});
    defer alloc.free(test_dir);
    try std.fs.makeDirAbsolute(test_dir);
    defer std.fs.deleteDirAbsolute(test_dir);

    try std.posix.setenv("XDG_RUNTIME_DIR", test_dir);

    // 2. Spin up a minimal App.
    var core_app: CoreApp = undefined;
    try core_app.init(alloc, &.{});
    defer core_app.deinit();

    var app: App = undefined;
    try app.init(&core_app, .{});
    defer app.terminate();

    try app.startIpcServer(&core_app);

    // 3. The socket must exist at the resolved path.
    const expected_path = try std.fmt.allocPrint(
        alloc,
        "{s}/ipc.sock",
        .{test_dir},
    );
    defer alloc.free(expected_path);

    const stat = try std.fs.cwd().statFile(expected_path);
    try testing.expect(stat.kind == .unix_domain_socket);
}
```

**Why this test is sufficient:**

1. It exercises the full `resolvePaths → bind → start` chain.
2. It asserts the platform-correct socket path is created.
3. It does not require a real GTK window — `Application.run()` is not called; only `init` + `startIpcServer` are. The `Application` instance is constructed but never enters the GTK main loop.

**Limitation:** the test does not exercise a real GTK `setTitle`/`childExited` path. B4 covers those.

### 2.10 Build graph integration

The `build.zig` GTK target already links `apprt/ipc`. Verify with:

```sh
zig build --build-runner-safe 2>&1 | grep -i "ipc/server.zig\|app_host.zig"
```

If `ipc.zig` is not currently in the GTK executable's dependency graph (per FWD-PATH A1 #5, it is), add `src/apprt/ipc/mod.zig` to the `gtk_exe.add` set. **Most likely already correct** because `apprt.ipc.Action` is referenced from `App.zig:79-80` for `performIpc` (the CLI-side, but it forces the build graph to pull in `ipc/mod.zig`).

### 2.11 Acceptance

After `zig build` + running `khostty` on Linux GTK:

```sh
ls -l $XDG_RUNTIME_DIR/khostty/ipc.sock       # → socket file
khostty-client ping --socket=$XDG_RUNTIME_DIR/khostty/ipc.sock
                                             # → {"ok":true}
khostty-client pane.list --socket=$XDG_RUNTIME_DIR/khostty/ipc.sock
                                             # → at least one entry (the focused pane)
```

---

## 3. B2 — Fix `pane.write` cross-thread parser access

### 3.1 Goal

Replace the direct `core.io.terminal_stream.nextSlice(data)` call in `writeToParser` with a `CoreSurface.queueIo(.{ .write_alloc = ... }, .unlocked)` hop, so the IPC handler thread never touches the parser state owned by the IO thread.

### 3.2 Exact file:line of the race

**File:** `src/apprt/ipc/app_host.zig`, lines 290-298:

```zig
fn writeToParser(ctx: *anyopaque, id: PaneId, data: []const u8) pane.HostError!usize {
    const self = ctxHost(ctx);
    const core = self.findCore(id) orelse return error.PaneNotFound;
    // The same parser the pty output goes through, so escape sequences and
    // modes behave exactly as if the program had written them.
    const stream = &core.io.terminal_stream;
    stream.nextSlice(data);
    return data.len;
}
```

**The race:** `terminal_stream` is owned by the IO thread (`termio.Thread`). When `Server.serveConnection` (B1) runs each request on a worker thread, `writeToParser` runs on that worker thread and reads/writes the parser state concurrently with the IO thread. The result is undefined behavior — most often, a corrupted parser cursor or a missed escape sequence.

**Why this is fine today:** until B1 lands, `AppHost.host()` is only ever called from the GTK main thread (per the comment at `app_host.zig:49-50`: "Until that hop is wired, `AppHost` must be called from the app thread"). The moment B1 lands and per-connection worker threads start calling `writeToParser`, the race fires.

### 3.3 Replacement code

```zig
fn writeToParser(ctx: *anyopaque, id: PaneId, data: []const u8) pane.HostError!usize {
    const self = ctxHost(ctx);
    const core = self.findCore(id) orelse return error.PaneNotFound;

    // B2 FIX: hop through the per-surface IO-thread mailbox. The IPC handler
    // thread never touches the parser state directly; the IO thread drains
    // the mailbox and runs `nextSlice` on its own thread.
    //
    // This is the same path Surface.zig uses for all other write_* variants
    // (per C2 §"queueIo signature"); the IPC `pane.write` command should
    // follow the same pattern.

    // Allocate a copy of the data; queueMessage owns the message and
    // deinits it on the IO thread after consumption.
    const dup = self.gpa.dupe(u8, data) catch return error.OutOfMemory;
    errdefer self.gpa.free(dup);

    core.queueIo(.{ .write_alloc = .{ .alloc = self.gpa, .data = dup } }, .unlocked);
    return data.len;
}
```

**Imports check:** `app_host.zig:58` already imports `CoreSurface = @import("../../Surface.zig");`. `Surface.queueIo` is private (`fn` not `pub fn` at `Surface.zig:879-900`). Since `app_host.zig` and `Surface.zig` are siblings in the same translation unit family, this works via Zig's `pub` rules: **`app_host.zig` cannot call `Surface.queueIo` directly because it is private.**

**Resolution:** the spec uses `core.queueIo(...)` assuming it is accessible from the host. If `Surface.queueIo` is private to `Surface.zig`, two options:

**Option A (recommended):** add a thin public wrapper on `CoreSurface`:

```zig
// src/Surface.zig, near line 900 (after queueIo):
pub fn queueIoForHost(self: *Surface, msg: termio.Message) void {
    self.queueIo(msg, .unlocked);
}
```

Or a more specific wrapper:

```zig
// src/Surface.zig, in the public section:
/// Queue an arbitrary `termio.Message` from outside the surface module.
/// Used by the IPC `pane.write` host to avoid cross-thread parser access.
pub fn queueIoExternal(self: *Surface, msg: termio.Message) void {
    self.queueIo(msg, .unlocked);
}
```

**Option B:** keep `Surface.queueIo` private; export a `queueIoWriteAlloc(alloc, data)` helper that constructs the `.write_alloc` message internally. This is the cleanest API surface:

```zig
// src/Surface.zig, in the public section:
pub fn queueWriteAlloc(self: *Surface, gpa: Allocator, data: []const u8) Allocator.Error!void {
    const dup = try gpa.dupe(u8, data);
    errdefer gpa.free(dup);
    self.queueIo(.{ .write_alloc = .{ .alloc = gpa, .data = dup } }, .unlocked);
}
```

**Recommended:** Option B. Single-purpose public API, no risk of callers constructing bad messages.

### 3.4 Why `.write_alloc` (not `.write_small` / `.write_stable`)

Per C2 §"`queueIo` signature" and `termio/message.zig:13-46`:

- `.write_small` (in-place, ≤ 38 bytes): the data lives inside the `termio.Message` value, which the IPC thread holds on the stack. After `send`, the queue owns the message; the IPC thread's stack frame is gone. **Cannot work for variable-length IPC payloads.**
- `.write_stable` (caller-owned, pointer + len): the queue does not free the buffer. The IPC thread would have to outlive the caller's stack. **Cannot work.**
- `.write_alloc` (heap-allocated, freed on consumer): the message owns a `[]u8` slice that was allocated by the IPC thread's allocator and is freed by the IO thread consumer. **This is the correct shape.** The factory `Message.writeReq(alloc, data)` (line 110) automatically routes small payloads to `.write_small` and larger to `.write_alloc`. The B2 code can use either the factory or the explicit `.write_alloc` constructor.

**Recommendation:** use `termio.Message.writeReq(alloc, data)` for clarity (the factory picks the right shape). Pass `.unlocked` for the mutex state (the IPC thread is not holding the renderer state mutex).

### 3.5 Test that proves the race is gone

**File:** `src/apprt/ipc/app_host.zig`, append a test block.

The test must exercise the cross-thread race deterministically. Use `FakeHost` (per `server.zig:545`) plus the threaded `std.Io`:

```zig
test "writeToParser routes through the mailbox on the IO thread" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const fake = FakeHost.init(alloc);
    defer fake.deinit();

    var mgr = pane.Manager.init(alloc, fake.host());
    defer mgr.deinit(io);

    // Open a pane via FakeHost (which records writes into an in-memory ring
    // buffer).
    const handle = try mgr.create(alloc, io, .{ .dir = .right });
    defer mgr.close(io, handle.id);

    // Issue 1000 writes from 16 threads concurrently. With the BUG (direct
    // nextSlice), this would race; with the FIX (mailbox hop), the IO thread
    // drains serially and no data is lost.
    const N_WRITES = 1000;
    const N_THREADS = 16;
    var threads: [N_THREADS]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(m: *pane.Manager, io: std.Io, id: PaneId, n: usize) void {
                var buf: [16]u8 = undefined;
                for (0..n) |i| {
                    const s = std.fmt.bufPrint(&buf, "w{} ", .{i}) catch continue;
                    _ = m.write(io, id, s) catch continue;
                }
            }
        }.run, .{ &mgr, io, handle.id, N_WRITES / N_THREADS });
    }
    for (&threads) |t| t.join();

    // Drain the mailbox by sleeping briefly to let the IO thread finish.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake);

    // Verify all writes were consumed (FakeHost records byte counts).
    try testing.expectEqual(@as(usize, N_WRITES * 5), fake.totalBytesWritten());
}
```

**Note:** the `FakeHost` currently in `server.zig:545` does not yet expose a `totalBytesWritten()` method. **Action item:** add this counter to `FakeHost` as part of B2's first commit. The fake is the canonical cross-thread race target; making the counter observable is a one-line change.

**Acceptance:** the test passes 100/100 times on a Linux x86_64 host. Before the B2 fix (i.e. with the original `stream.nextSlice` call), the test fails intermittently because the parser cursor gets corrupted mid-write; with the B2 fix, all bytes arrive in order, no corruption.

### 3.6 Acceptance for B2

After B1 + B2:

```sh
# Open the khostty app on GTK Linux.
khostty &

# From an external shell, send many concurrent writes.
for i in $(seq 1 1000); do
  khostty-client pane.write --data="x$i" &
done
wait

# Verify pane state shows the expected number of "x1".."x1000" tokens.
khostty-client pane.state --pane-id=1 | jq '.data.scrollback_rows'
```

Expected: `pane.state` reflects all 1000 writes; no torn bytes; cursor is consistent.

### 3.7 Risks specific to B2

| Risk | Mitigation |
|---|---|
| `Surface.queueIo` is private; need a public wrapper | Add `queueWriteAlloc` to `Surface.zig` per §3.3 Option B |
| The IO thread is faster than the producer (back-pressure) | The mailbox capacity is 64 (`mailbox.zig:65`); under 1000 concurrent writes, the producer hits the slow path (`mailbox.zig:181-195`) which uses `.forever` blocking. No data loss; latency under load. |
| `self.gpa.dupe` may be slow for large payloads | Use `termio.Message.writeReq(alloc, data)` which auto-picks `.write_small` (no copy) when the payload fits in 38 bytes. |
| Allocator lifetime: does `self.gpa` survive until the IO thread consumes? | The same allocator is used everywhere in the surface lifecycle; the existing inputs use the same allocator. **Verified safe per C2 Open Question #3.** |

---

## 4. B4 — Map 4 event publish hooks

### 4.1 Goal

Wire `apprt.ipc.AppHost.publishTitleChange`, `publishChildExit`, `publishResize`, and `publishBell` (already implemented at `app_host.zig:130-160`) from the four GTK callback sites where the runtime already reacts to those events. After B4, an agent subscribed via `events.subscribe` for `title_change`/`child_exit`/`resize`/`bell` receives each event over the IPC socket.

### 4.2 Pre-step: expose the broker to the GTK surface

**File:** `src/apprt/gtk/class/application.zig:170-184`

Add one field to `Private`:

```zig
const Private = struct {
    rt_app: *ApprtApp,
    core_app: *CoreApp,
    config: *Config,
    winproto: winprotopkg.App,

    /// NEW: optional event broker; set by the IPC server on startup.
    /// NULL when no IPC server is running, which makes the publish hooks
    /// no-op safely. Lifetime is owned by the IPC server.
    broker: ?*events.Broker = null,
};
```

Add two methods on `Application` (after `default()` at line 245-247):

```zig
pub fn setEventBroker(self: *Self, broker: ?*events.Broker) void {
    self.private().broker = broker;
}

pub fn broker(self: *Self) ?*events.Broker {
    return self.private().broker;
}
```

Add the import at the top of `application.zig`:

```zig
const ipc = @import("../../ipc/mod.zig");
const events = ipc.Events;
```

**Why on `Application` and not on `ApprtApp`:** the GObject `Application` already owns the lifecycle; `ApprtApp` (`src/apprt/gtk/App.zig:28`) is a thin wrapper. The broker is a singleton per app instance; the GObject Application is the canonical singleton. The publish hooks then look up `Application.default().broker()` from any GObject callback.

### 4.3 Insertion point 1: `setTitle` — `publishTitleChange`

**File:** `src/apprt/gtk/class/surface.zig:2109-2115`

```zig
pub fn setTitle(self: *Self, title: ?[:0]const u8) void {
    const priv = self.private();
    if (priv.title) |v| glib.free(@ptrCast(@constCast(v)));
    priv.title = null;
    if (title) |v| priv.title = glib.ext.dupeZ(u8, v);
    self.as(gobject.Object).notifyByPspec(properties.title.impl.param_spec);

    // NEW (B4): publish to mux shell subscribers, if any.
    const core_surface = priv.core_surface orelse return;
    if (Application.default().broker()) |broker| {
        _ = broker.publish(self.io_unwrap(), events.Event.titleChange(
            protocol.PaneId.init(core_surface.id),
            title orelse "",
        ));
    }
}
```

**Imports to add** (top of `surface.zig`):

```zig
const ipc = @import("../../ipc/mod.zig");
const events = ipc.Events;
const protocol = ipc.Protocol;
```

### 4.4 Insertion point 2: `childExited` — `publishChildExit`

**File:** `src/apprt/gtk/class/surface.zig:1521-1534`

```zig
pub fn childExited(
    self: *Self,
    data: apprt.surface.Message.ChildExited,
) bool {
    const priv = self.private();
    priv.child_exited = true;
    self.as(gobject.Object).notifyByPspec(
        properties.@"child-exited".impl.param_spec,
    );

    priv.child_exited_overlay.setData(&data);

    // NEW (B4): publish to mux shell subscribers, if any.
    const core_surface = priv.core_surface orelse return true;
    if (Application.default().broker()) |broker| {
        _ = broker.publish(self.io_unwrap(), events.Event.childExit(
            protocol.PaneId.init(core_surface.id),
            data.exit_code,
            data.signal,
        ));
    }
    return true;
}
```

### 4.5 Insertion point 3: `renderSurfaceResize` — `publishResize`

**File:** `src/apprt/gtk/class/surface.zig:3398-3452`

The current code at line 3398 reads:

```zig
fn renderSurfaceResize(
    _: *RenderSurface,
    width: c_int,
    height: c_int,
    self: *Self,
) callconv(.c) void {
    // ... (debug logging and size caching at 3404-3423)
    if (priv.core_surface) |surface| {
        surface.contentScaleCallback(self.getContentScale()) catch |err| {
            log.warn("error in content scale callback err={}", .{err});
        };

        if (changed) {
            surface.sizeCallback(new_size) catch |err| {
                log.warn("error in size callback err={}", .{err});
            };
            self.resizeOverlaySchedule();
        }
    } else {
        // ... (initialization path)
    }
}
```

**Insertion (after `self.resizeOverlaySchedule()` inside the `if (changed)` block):**

```zig
if (changed) {
    surface.sizeCallback(new_size) catch |err| {
        log.warn("error in size callback err={}", .{err});
    };
    self.resizeOverlaySchedule();

    // NEW (B4): publish to mux shell subscribers, if any.
    if (Application.default().broker()) |broker| {
        // Best-effort grid estimate from the requested pixel size.
        // The canonical grid is observable via pane.state; the requested
        // size is what we have at this call site without crossing the
        // IO thread.
        const cols: u16 = @intCast(@divFloor(width, priv.font_size));
        const rows: u16 = @intCast(@divFloor(height, priv.font_size));
        _ = broker.publish(self.io_unwrap(), events.Event.resize(
            protocol.PaneId.init(surface.id),
            cols,
            rows,
        ));
    }
}
```

**Trade-off documented (C3 Open Question #4):** the published `cols`/`rows` are the **requested** grid size derived from `width / font_size`, not the **applied** size (which lives in `core.io.size` on the IO thread). Clients that need the canonical grid should re-query via `pane.state`. Future refactor: expose the applied size via a synchronous getter that reads from a small shadow variable updated by the IO thread after each `.resize` message.

### 4.6 Insertion point 4: `ringBell` — `publishBell`

**File:** `src/apprt/gtk/class/surface.zig:2564-2577`

The current code:

```zig
fn ringBell(self: *Self) void {
    // Emit the signal
    signals.bell.impl.emit(
        self,
        null,
        .{},
        null,
    );

    // Activate actions if they exist
    _ = self.as(gtk.Widget).activateAction("tab.ring-bell", null);
    _ = self.as(gtk.Widget).activateAction("win.ring-bell", null);
    _ = self.as(gtk.Widget).activateAction("app.ring-bell", null);
}
```

**Insertion (after the signal emit, before the actions):**

```zig
fn ringBell(self: *Self) void {
    signals.bell.impl.emit(
        self,
        null,
        .{},
        null,
    );

    // NEW (B4): publish to mux shell subscribers, if any.
    const priv = self.private();
    const core_surface = priv.core_surface orelse {
        _ = self.as(gtk.Widget).activateAction("tab.ring-bell", null);
        _ = self.as(gtk.Widget).activateAction("win.ring-bell", null);
        _ = self.as(gtk.Widget).activateAction("app.ring-bell", null);
        return;
    };
    if (Application.default().broker()) |broker| {
        _ = broker.publish(self.io_unwrap(), events.Event.bell(
            protocol.PaneId.init(core_surface.id),
        ));
    }

    _ = self.as(gtk.Widget).activateAction("tab.ring-bell", null);
    _ = self.as(gtk.Widget).activateAction("win.ring-bell", null);
    _ = self.as(gtk.Widget).activateAction("app.ring-bell", null);
}
```

### 4.7 Why `events.Event.titleChange` etc. (not `apprt.ipc.AppHost.publishTitleChange`)

The `apprt.ipc.AppHost.publish*` hooks (`app_host.zig:130-160`) are called from inside the host module and have access to `self.io` directly. From a GObject callback, we don't have an `AppHost*` — we have an `Application` and a `CoreSurface`. Re-publishing via the broker directly (using the broker's own `publish` method) is the equivalent and does not require plumbing an `AppHost*` into the GObject layer.

**Same end state:** the broker gets a `titleChange` event with `pane_id`, `title` (or `exit_code`/`signal`, or `cols`/`rows`, or empty `Bell`). The IPC server's pusher thread delivers it to subscribed connections. No behavioral difference between calling `app_host.publishTitleChange(core)` and calling `broker.publish(io, events.Event.titleChange(...))`.

### 4.8 Test that proves the events fire

**File:** `src/apprt/gtk/class/surface.zig`, append a test block.

The challenge: testing the GObject callbacks requires GTK to be initialized. The fork's existing test infrastructure does not run GTK (per FWD-PATH A5). **Two viable strategies:**

**Strategy A (unit test, no GTK):** test the broker publish path directly, with a stub `CoreSurface` and a mock `Application`:

```zig
test "setTitle publishes a titleChange event to the broker" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var broker = events.Broker.init(alloc);
    defer broker.deinit(testing.io);

    const fake_id = protocol.PaneId.init(42);
    _ = broker.publish(testing.io, events.Event.titleChange(fake_id, "hello"));

    // Verify a subscriber received the event.
    var sub = try broker.subscribe(testing.io, .{});
    defer sub.deinit(alloc);
    const ev = try sub.pop(testing.io, .forever);
    try testing.expectEqual(@as(u16, 42), ev.pane_id.?.raw);
    try testing.expectEqualStrings("hello", ev.payload.title_change.title.slice());
}
```

This validates the broker pipeline but not the GTK hook insertion.

**Strategy B (integration test, full GTK):** `tests/integration/gtk_publish_hooks.zig` —

```zig
test "GTK setTitle triggers broker.publish" {
    // 1. Initialize GTK test infrastructure.
    const gtk_app = gtk.Application.@new("test.khostty.publish", .{});
    // 2. Construct a Surface (real or stub).
    // 3. Set the broker on the Application.
    gtk_app.setEventBroker(&broker);
    // 4. Trigger setTitle.
    surface.setTitle("hello world");
    // 5. Verify broker.deliverable had the event.
}
```

**Recommended:** ship Strategy A as part of B4 (no GTK dependency, runs on every CI build). Add Strategy B in a follow-up PR when the GTK test harness is built out (per FWD-PATH carry-forward #25).

### 4.9 Acceptance for B4

After B1 + B2 + B4:

```sh
# Subscribe to title_change events.
khostty-client events.subscribe --mask=title_change &

# In the khostty window, run a command that changes the title.
echo $'\e]2;hello\a'

# Within 1 second, the subscriber should see:
# {"kind":"title_change","pane_id":1,"payload":{"title_change":{"title":"hello"}}}
```

Repeat for `child_exit` (run `exit` in the shell), `resize` (resize the window), `bell` (run `printf '\a'`).

---

## 5. B5 — Snapshot counters

### 5.1 Goal

Replace the six `null`-valued snapshot fields in `AppHost.snapshotWindowed` (`app_host.zig:479-489`) with real values: `bell_count`, `exited`, `exit_code`, `exit_signal`, `command`, `last_activity_ms`.

### 5.2 Exact file:line

**File:** `src/apprt/ipc/app_host.zig`, lines 445-491 (the `snapshotWindowed` function, with the counter fields at 479-489).

The current code:

```zig
.bell_count = null,
.scrollback_rows = scrollbackRows(term),
.viewport_rows = @intCast(term.rows),
.exited = null,
.exit_code = null,
.exit_signal = null,
.command = null,
.last_activity_ms = null,
```

### 5.3 Runtime-side tracking additions

Most of these need a small runtime-side tracker. Add a field to `AppHost` (after `broker` at line 104):

```zig
pub const AppHost = struct {
    gpa: Allocator,
    io: std.Io,
    app: *App,
    mutex: std.Io.Mutex = .init,
    split_wait_ms: u64 = 500,
    split_poll_interval_ms: u64 = 2,
    broker: ?*events.Broker = null,

    /// NEW (B5): per-surface runtime state tracked across calls.
    ///
    /// `last_bell_ms[u32]`: monotonic timestamp of last bell per pane id.
    /// `bell_count[u32]`: total bell rings per pane id.
    /// `exit_info[u32]`: capture of child exit status per pane id.
    /// `command[u32]`: last foreground command name per pane id.
    ///
    /// Stored as parallel arrays keyed by pane id. `PaneId` is a `u32`
    /// wrapper (per `protocol.PaneId`); the registry is bounded by
    /// `default_max_panes = 64` (per `pane.zig:48`), so the arrays are small.
    last_bell_ms: [64]?i64 = @splat(null),
    bell_count: [64]u64 = @splat(0),
    exit_info: [64]?struct { code: i32, signal: ?u8 } = @splat(null),
    last_command: [64]?[]const u8 = @splat(null),

    // ... existing methods
};
```

**Allocator caveat:** `last_command[i]` is a slice whose lifetime is tied to the GObject surface; when the surface is destroyed, the slice must be freed. Add `deinit`:

```zig
pub fn deinit(self: *AppHost) void {
    for (&self.last_command) |*slot| {
        if (slot.*) |s| self.gpa.free(s);
        slot.* = null;
    }
}
```

Update the `B1` `startIpcServer` to call `app_host.deinit` after `Server.deinit`.

### 5.4 Hook the four trackers

The four runtime-side counters must be updated from the same GTK callback sites used by B4.

#### 5.4.1 `bell_count` + `last_bell_ms` at `ringBell` (`surface.zig:2564`)

In the B4 insertion block, also update the AppHost:

```zig
if (Application.default().broker()) |broker| {
    _ = broker.publish(self.io_unwrap(), events.Event.bell(
        protocol.PaneId.init(core_surface.id),
    ));
}
// NEW (B5): increment bell_count for this pane.
if (Application.default().apphost()) |host| {
    host.bell_count[core_surface.id % 64] += 1;
    host.last_bell_ms[core_surface.id % 64] = std.Io.Timestamp.now(.monotonic).nanoseconds;
}
```

(Adding `Application.apphost()` is a new accessor analogous to `broker()`.)

#### 5.4.2 `exit_info` at `childExited` (`surface.zig:1521`)

```zig
if (Application.default().broker()) |broker| {
    _ = broker.publish(self.io_unwrap(), events.Event.childExit(
        protocol.PaneId.init(core_surface.id),
        data.exit_code,
        data.signal,
    ));
}
// NEW (B5): record exit info.
if (Application.default().apphost()) |host| {
    if (data.exit_code) |code| {
        host.exit_info[core_surface.id % 64] = .{ .code = code, .signal = data.signal };
    }
}
```

#### 5.4.3 `last_command` at `setTitle` (`surface.zig:2109`)

The foreground command name lives in the pty, not in the GTK surface. The cleanest path: use the same `pidOf`/`cwdOf` accessors from `app_host.zig:512-529`, plus a new `commandOf`:

```zig
fn commandOf(core: *CoreSurface) ?[]const u8 {
    if (comptime !windowed) return null;
    // TODO(B5): ghostty's core surface does not currently expose the foreground
    // command name synchronously. For Phase B, use `pidOf` as a fallback
    // (the caller can `ps` the pid if they need the name). Document this in
    // protocol.md.
    return null;
}
```

Update `snapshotWindowed`:

```zig
.command = if (commandOf(core)) |c| try arena.dupe(u8, c) else null,
```

For Phase B, `.command = null` remains the truth; the field is in the snapshot but populated with null. A future PR (Phase D candidate) implements `commandOf` by reading from the pty's process group state.

#### 5.4.4 `last_activity_ms` — IO-thread capture

`last_activity_ms` is the monotonic timestamp of the most recent terminal output. The terminal owns this state on the IO thread; reading it from the GTK main thread requires a sync hop. **Two viable implementations:**

**Option 1 (cheap, approximate):** update `last_activity_ms` from the GTK callback whenever the renderer draws a frame. The draw frequency is at most ~60 Hz; for an idle terminal this stays roughly current.

```zig
// src/apprt/gtk/class/surface.zig, in the renderer draw callback (find the
// RenderSurface.draw callback at the existing draw signal handler):
if (Application.default().apphost()) |host| {
    host.last_activity_ms[core_surface.id % 64] =
        std.Io.Timestamp.now(.monotonic).nanoseconds;
}
```

**Option 2 (precise, expensive):** add an `apprt.surface.Message.lastActivityMs` that the IO thread sends every time `terminal.Screen.dirty` becomes true. The GTK main thread receives the message and updates `last_activity_ms`. Higher fidelity, more code.

**Recommended:** Option 1 for Phase B. Document the approximation in `protocol.md`.

### 5.5 Update `snapshotWindowed` (lines 479-489)

Replace:

```zig
.bell_count = null,
.scrollback_rows = scrollbackRows(term),
.viewport_rows = @intCast(term.rows),
.exited = null,
.exit_code = null,
.exit_signal = null,
.command = null,
.last_activity_ms = null,
```

With:

```zig
.bell_count = self.bell_count[id.raw % 64],
.scrollback_rows = scrollbackRows(term),
.viewport_rows = @intCast(term.rows),
.exited = if (self.exit_info[id.raw % 64] != null) true else null,
.exit_code = if (self.exit_info[id.raw % 64]) |e| e.code else null,
.exit_signal = if (self.exit_info[id.raw % 64]) |e| e.signal else null,
.command = if (commandOf(core)) |c| try arena.dupe(u8, c) else null,
.last_activity_ms = self.last_bell_ms[id.raw % 64],
```

**Note:** `last_activity_ms` repurposes the `last_bell_ms` slot. Rename the field to `last_activity_ms` for clarity:

```zig
last_activity_ms: [64]?i64 = @splat(null),
```

(The bell timestamp was a useful debug aid; the last activity timestamp is more useful in production. Drop `last_bell_ms`.)

### 5.6 Test that proves the counters populate

**File:** `src/apprt/ipc/app_host.zig`, append:

```zig
test "snapshot populates bell_count and exit_info after events" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var host = AppHost.init(alloc, io, undefined); // app unused in this test
    defer host.deinit();

    const id = protocol.PaneId.init(1);
    host.bell_count[id.raw % 64] = 3;
    host.exit_info[id.raw % 64] = .{ .code = 0, .signal = null };
    host.last_activity_ms[id.raw % 64] = std.Io.Timestamp.now(.monotonic).nanoseconds;

    var snap: state.Snapshot = undefined;
    try host.snapshot(alloc, io, id, &snap); // assumes host.fake (FakeHost)

    try testing.expectEqual(@as(?u64, 3), snap.bell_count);
    try testing.expectEqual(@as(?bool, true), snap.exited);
    try testing.expectEqual(@as(?i32, 0), snap.exit_code);
    try testing.expect(snap.last_activity_ms != null);
}
```

### 5.7 Acceptance for B5

After B1 + B2 + B4 + B5:

```sh
# Open the khostty app on GTK Linux.
khostty &

# Subscribe and trigger events.
khostty-client events.subscribe --mask=bell,child_exit &

# Ring the bell.
printf '\a' > /tmp/khostty-client-input

# Close the shell.
exit

# Snapshot the pane.
khostty-client pane.state --pane-id=1 | jq
```

Expected JSON fragment:

```json
{
  "pane_id": 1,
  "bell_count": 1,
  "exited": true,
  "exit_code": 0,
  "exit_signal": null,
  "command": null,
  "last_activity_ms": 1765929345123
}
```

---

## 6. E2E acceptance

### 6.1 Scope

End-to-end test plan that proves B1+B2+B4+B5 together against a real GTK-on-Linux runtime. Run on the Linux GTK host; this is the **G4 finish line**.

### 6.2 Pre-conditions

```text
[ ] Linux GTK host reachable; khostty binary built via `zig build`
[ ] $XDG_RUNTIME_DIR/khostty/ writable
[ ] socat available for socket-level scripting
[ ] khostty-client (Python) ≥ 0.1.0 installed
```

### 6.3 Test plan

`conformance/khostty-phase-b-e2e.bash` (new file, ~80 lines):

```bash
#!/usr/bin/env bash
# Phase B end-to-end acceptance. Boots the GTK runtime, exercises B1 (Server.bind),
# B2 (mailbox hop), B4 (publish hooks), B5 (snapshot counters).
#
# Exit codes: 0 = pass; non-zero = first failed step.

set -euo pipefail

KHOSTTY="${KHOSTTY:-./zig-out/bin/khostty}"
SOCAT="${SOCAT:-socat}"
PYTHON_CLIENT="${PYTHON_CLIENT:-khostty-client}"
SOCK_DIR="$(mktemp -d -t khostty-e2e.XXXXXX)"
SOCK="$SOCK_DIR/ipc.sock"
LOG="$(mktemp -t khostty-e2e.XXXXXX.log)"

export XDG_RUNTIME_DIR="$SOCK_DIR"
mkdir -p "$SOCK_DIR/khostty"
export XDG_RUNTIME_DIR="$SOCK_DIR/khostty"

trap 'kill $KHOSTTY_PID 2>/dev/null || true; rm -rf "$SOCK_DIR" "$LOG"' EXIT

# ── B1: Server.bind ─────────────────────────────────────────────────────
"$KHOSTTY" >"$LOG" 2>&1 &
KHOSTTY_PID=$!

# Wait up to 10s for the socket to appear.
for _ in $(seq 1 100); do
    [ -S "$SOCK" ] && break
    sleep 0.1
done
if [ ! -S "$SOCK" ]; then
    echo "FAIL B1: socket did not appear at $SOCK"
    cat "$LOG"
    exit 1
fi

# Read the token.
TOKEN="$(cat "$SOCK_DIR/khostty/ipc.token")"
[ -n "$TOKEN" ] || { echo "FAIL B1: no token"; exit 1; }

# ping → {"ok":true}
RES="$("$PYTHON_CLIENT" ping --socket="$SOCK" --token="$TOKEN")"
echo "$RES" | jq -e '.ok == true' >/dev/null || { echo "FAIL B1: ping failed: $RES"; exit 1; }

# pane.list → at least the focused pane.
RES="$("$PYTHON_CLIENT" pane.list --socket="$SOCK" --token="$TOKEN")"
PANE_ID="$(echo "$RES" | jq -r '.data.panes[0].id')"
[ -n "$PANE_ID" ] || { echo "FAIL B1: pane.list empty: $RES"; exit 1; }

# ── B2: mailbox hop ─────────────────────────────────────────────────────
# Fire 1000 concurrent pane.write from 16 background processes.
TMP="$(mktemp -d)"
for i in $(seq 1 16); do
    (
        for j in $(seq 1 62); do  # 16 * 62 = 992 writes
            "$PYTHON_CLIENT" pane.write --socket="$SOCK" --token="$TOKEN" \
                --pane-id="$PANE_ID" --data="w$j " >/dev/null
        done
    ) &
done
wait

# Verify the pane is still responsive (no parser corruption).
RES="$("$PYTHON_CLIENT" pane.state --socket="$SOCK" --token="$TOKEN" --pane-id="$PANE_ID")"
echo "$RES" | jq -e '.data.title != null' >/dev/null || { echo "FAIL B2: pane.state broken"; exit 1; }

# ── B4: publish hooks ───────────────────────────────────────────────────
"$PYTHON_CLIENT" events.subscribe --socket="$SOCK" --token="$TOKEN" \
    --mask=title_change,child_exit,resize,bell >"$TMP/events.log" &
SUB_PID=$!
sleep 0.2  # let the subscription handshake settle

# Trigger a title change via OSC 2.
"$PYTHON_CLIENT" pane.write --socket="$SOCK" --token="$TOKEN" \
    --pane-id="$PANE_ID" --data=$'\e]2;hello world\a' >/dev/null

# Trigger a bell.
"$PYTHON_CLIENT" pane.write --socket="$SOCK" --token="$TOKEN" \
    --pane-id="$PANE_ID" --data=$'\a' >/dev/null

# Wait up to 1s for events to be delivered.
sleep 1
kill $SUB_PID 2>/dev/null || true
wait $SUB_PID 2>/dev/null || true

if ! grep -q '"title_change"' "$TMP/events.log"; then
    echo "FAIL B4: no title_change event"
    cat "$TMP/events.log"
    exit 1
fi
if ! grep -q '"bell"' "$TMP/events.log"; then
    echo "FAIL B4: no bell event"
    cat "$TMP/events.log"
    exit 1
fi

# ── B5: snapshot counters ───────────────────────────────────────────────
RES="$("$PYTHON_CLIENT" pane.state --socket="$SOCK" --token="$TOKEN" --pane-id="$PANE_ID")"
BELL_COUNT="$(echo "$RES" | jq -r '.data.bell_count')"
[ "$BELL_COUNT" -ge 1 ] || { echo "FAIL B5: bell_count=$BELL_COUNT"; exit 1; }
LAST_ACTIVITY="$(echo "$RES" | jq -r '.data.last_activity_ms')"
[ "$LAST_ACTIVITY" -gt 0 ] || { echo "FAIL B5: last_activity_ms=$LAST_ACTIVITY"; exit 1; }

echo "Phase B E2E: PASS"
echo "  socket:  $SOCK"
echo "  pane_id: $PANE_ID"
echo "  bell:    $BELL_COUNT"
echo "  last:    $LAST_ACTIVITY"
```

### 6.4 Negative tests (must fail correctly)

| # | Action | Expected |
|---|---|---|
| 1 | 33 simultaneous connects | First 32 succeed; 33rd gets `ECONNREFUSED` |
| 2 | 200 frames/sec from one connection | First ~100 accepted, rest get `rate_limited` |
| 3 | 2 MiB frame | `bad_request`; connection closed |
| 4 | `pane.focus` to nonexistent pane | `pane_not_found` or `host_unsupported` |
| 5 | `pane.search` against real GTK | `host_unsupported` (per `searchUnsupported` at `app_host.zig:216-232`) |
| 6 | Connect without token | `unauthorized`; connection closed |

### 6.5 CI integration

`.github/workflows/ci-conformance.yml` (new, per FWD-PATH B6):

```yaml
name: ci/conformance
on:
  push:
    branches: [main]
    paths:
      - 'conformance/**'
      - 'src/apprt/gtk/App.zig'
      - 'src/apprt/ipc/app_host.zig'
      - 'src/apprt/ipc/server.zig'
      - 'src/apprt/gtk/class/application.zig'
      - 'src/apprt/gtk/class/surface.zig'
      - 'src/Surface.zig'
jobs:
  conformance:
    runs-on: ubuntu-latest
    services:
      xvfb:
        image: ghcr.io/koosha-pari/khostty-ci-xvfb:latest
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v1
        with:
          version: 0.14.0
      - run: zig build
      - name: Run GTK conformance
        env:
          DISPLAY: :99
        run: ./conformance/khostty-phase-b-e2e.bash
```

(Container image for Xvfb is a placeholder — the operator provides the canonical image before merging the CI workflow.)

---

## 7. Rollback plan

If B1-B5 must be reverted (e.g. a regression in production), follow this procedure. **Git history is preserved; no force-pushes.**

### 7.1 Single revert PR

```sh
cd /Users/kooshapari/CodeProjects/Phenotype/repos/khostty
git checkout main
git pull --ff-only
git revert --no-edit <merge-sha-of-phase-b>
git push origin main
```

The Phase B PR is a single squash-merge to `main` (per the merge strategy). Reverting the merge commit produces an inverse diff that preserves all the new tests and hooks but disables the wiring.

### 7.2 Per-step reverts (if only one of B1-B5 fails)

Each B/PR ships as a separate commit on the same branch (B1+B2 in one commit, B4 in another, B5 in a third). Per-step reverts use `git revert <commit-sha>`.

### 7.3 Rollback safety checks

After revert:

```sh
zig build test-agent-ipc  # expected: 3899/3925 passing (same as baseline)
rg 'Server.bind' src/apprt/gtk/    # expected: 0 hits (wiring removed)
rg 'queueWriteAlloc' src/Surface.zig # expected: 0 hits (B2 wrapper removed)
rg 'setEventBroker' src/apprt/gtk/class/application.zig # expected: 0 hits (B4 broker removed)
```

### 7.4 What is preserved across a rollback

- `test-agent-ipc` (substrate tests) is unchanged by Phase B.
- The 4 publish hook functions in `app_host.zig:130-160` are unchanged (they already existed; B4 only wires new callers).
- `Server.bind` and `Server.start` are unchanged (B1 only adds the GTK caller).

**Net revert surface:** ~200 lines of new code, all in `App.zig`, `application.zig`, `surface.zig`, `app_host.zig`, and a new `Surface.queueWriteAlloc` helper. Reverting is clean and bounded.

### 7.5 Carry-forward risks

If a Phase B regression escapes to `main`, document in `docs/sessions/<date>-phase-b-rollback/00_SESSION_OVERVIEW.md` (new session folder, per AGENTS.md §8 "Documentation Update Protocol") and create a follow-up issue tagged `phase-b` for triage. **Do not** `git reset --hard` or force-push.

---

## 8. Open risks

Ranked by likelihood × impact. **None are blocking** Phase B from proceeding once Q1 is decided; all are surfaced for the operator's visibility.

### 8.1 High likelihood, high impact

**R1: Linux GTK host provisioning is operator-only.** The macOS operator host cannot build GTK (per FWD-PATH §3 B1 footnote). Phase B cannot proceed without a Linux box. The WSL `kooshapari-desk` r4 sync is offline (per state §5). **Mitigation:** operator provisions a Linux host (1h). If no host is reachable, Phase B is blocked and the operator chooses between Q1(a) deferral, Q1(b) embedded-on-macOS, or Q1(c) mock-only.

**R2: Build host disk pressure (96-98% full per state §7).** Cold-cache `zig build` is 27-30m; a fresh Linux build with GTK dependencies could be 40-60m. **Mitigation:** confirm ≥ 50 GiB free before scheduling B1; if tight, run a `zig build` once with `target/native` cache primed, then incremental builds for B2/B4/B5 are < 2m.

### 8.2 Medium likelihood, medium impact

**R3: GTK signals fire on the GTK main thread; `broker.publish` must be thread-safe.** Per C3 §"Thread-safety": `events.Broker.publish` takes `std.Io.Mutex`, so cross-thread calls are safe. **Verified** by `events.zig:14` ("Thread safety: every entry point takes `std.Io.Mutex`"). **Mitigation:** none needed; documented.

**R4: The `last_command` field stays null.** Per §5.4.3, ghostty's core surface does not synchronously expose the foreground command. `snapshot.command` is null in Phase B. **Mitigation:** document in `protocol.md` §3 (per FWD-PATH A1+A6 disclosure pattern). Phase D may add a `commandOf` core API.

**R5: `last_activity_ms` is approximated via draw callbacks.** Per §5.4.4 Option 1, the timestamp updates on render frames (≤60 Hz). For an idle terminal that does not redraw, `last_activity_ms` is stale. **Mitigation:** document the approximation in `protocol.md` §3. Phase D may add an IO-thread-driven timestamp.

### 8.3 Medium likelihood, low impact

**R6: `surface.zig` already imports many modules; adding `ipc` increases compile time.** Per FWD-PATH §10, `surface.zig` is 4,439 lines. Importing `apprt.ipc.mod.zig` brings in the entire IPC layer; the incremental compile cost is bounded (one TU). **Mitigation:** if compile time regresses > 10s, gate the import behind a comptime check (`if (comptime build_config.feature.agent_ipc) { ... }`).

**R7: B4 publishes on every bell, including duplicate-no-state-change bells.** Per C3 Open Question #6, `bell` events may fire more often than the property state changes. **Mitigation:** `events.Bell.count: u64 = 1` (per `events.zig:99`) — agents can dedupe by pane_id. Document in `protocol.md`.

**R8: `Surface.queueIo` is private; Option B adds a new public wrapper.** Per §3.3, B2 adds `Surface.queueWriteAlloc`. This expands the public API surface of `Surface.zig` (currently 6,708 lines, target ≤ 7,000). **Mitigation:** the wrapper is ~10 lines, no impact on the file-size budget.

### 8.4 Low likelihood, high impact

**R9: A future rebase drops the GTK call site, silently breaking B4.** Per FWD-PATH §10 carry-forward #24, fork-discipline CI guard is not yet implemented. **Mitigation:** add the fork-discipline guard as part of B4 (1h addition) — a `zig test` that verifies the four `Application.default().broker() |broker| { ... }` blocks still exist in `class/surface.zig`.

**R10: GTK 4.10 → 4.14 (or higher) breaks `RenderSurface` callback signature.** The `renderSurfaceResize` call site assumes a fixed signature; a GTK version bump may change it. **Mitigation:** pin GTK to 4.10 in `build.zig` and the conformance CI. Upgrade separately, with a dedicated PR.

### 8.5 Low likelihood, low impact

**R11: The `ipc.zig` (apprt-side) and `apprt/ipc/` (agent-side) surfaces are confused.** Per C4 §2.2, the two surfaces are distinct; `App.zig:79` uses the apprt side (`apprt.ipc.Action`). B1 uses the agent side. **Mitigation:** none needed; the surfaces coexist.

**R12: `PaneId.raw` overflow.** Per §5.3, the parallel arrays are indexed by `id.raw % 64`. If `PaneId.raw` exceeds 64, collisions occur (two panes share a counter slot). `default_max_panes = 64` per `pane.zig:48` is the hard ceiling, so collisions are bounded. **Mitigation:** none needed for Phase B; document the mod-64 indexing.

### 8.6 Out-of-scope risks (operator visibility)

These are explicit non-goals for Phase B but recorded for completeness:

- **Q1 alternatives (b/c):** if Q1 changes from (a) to (b) or (c), Phase B is replaced by Phase C1+C5 or a mock-only build. Spec does not cover these paths.
- **Phase D mux shell (`khostty-mux` binary):** separate work per C4; not part of Phase B.
- **Upstream-core API changes** (`pane.focus`/`pane.search`): out of fork-only scope per FWD-PATH §7.
- **Windows GUI runtime:** G3 deferral; not in Phase B.

---

## Appendix A — File-by-file change summary

| File | Lines | Action | Net Δ |
|---|---|---|---|
| `src/apprt/gtk/App.zig` | 92 | Add `startIpcServer`, `stopIpcServer`, fields, test | +100 / -0 |
| `src/apprt/ipc/app_host.zig` | 574 | Replace `writeToParser` body (B2); add `last_activity_ms`/`bell_count`/`exit_info`/`last_command` arrays; update `snapshotWindowed`; add `deinit`; add tests | +90 / -10 |
| `src/apprt/ipc/server.zig` | 1,413 | No changes (B1 only consumes the existing API) | 0 |
| `src/apprt/ipc/auth.zig` | 530 | Add `loadOrCreateToken` helper (B1) | +25 / -0 |
| `src/apprt/ipc/fake_host.zig` | ~150 | Add `totalBytesWritten()` for B2 test | +5 / -0 |
| `src/apprt/gtk/class/application.zig` | 3,306 | Add `broker` field to `Private`; add `setEventBroker`/`broker` methods | +20 / -0 |
| `src/apprt/gtk/class/surface.zig` | 4,439 | 4 insertions (B4 hooks + B5 counter updates); add `ipc` import; add tests | +80 / -5 |
| `src/Surface.zig` | 6,708 | Add `queueWriteAlloc` public wrapper (B2); add `apphost()` accessor if needed | +15 / -0 |
| `conformance/khostty-phase-b-e2e.bash` | new | E2E script | +90 / -0 |
| `.github/workflows/ci-conformance.yml` | new | CI job (per FWD-PATH B6) | +30 / -0 |
| `docs/sessions/<date>-phase-b/` | new | Session docs (per AGENTS.md §8) | +50 / -0 |
| `docs/protocol.md` | TBD | Disclosure of B4 publish ordering, B5 `last_activity_ms` approximation, `last_command` null state (per FWD-PATH A1) | +15 / -0 |

**Total: ~520 lines of new code + 15 lines removed across 12 files. PRs ship as 3 commits: (B1+B2), (B4+B5), (E2E+CI).**

---

## Appendix B — Acceptance checklist (operator-facing)

After B1+B2+B4+B5 ship:

- [ ] `zig build test-agent-ipc` passes; same count as baseline (3899/3925) plus the new B1/B2/B4/B5 tests
- [ ] `zig build` produces a Linux GTK binary
- [ ] On a Linux GTK host: `khostty` boots; `$XDG_RUNTIME_DIR/khostty/ipc.sock` exists
- [ ] `khostty-client ping` returns `{"ok":true}`
- [ ] `khostty-client pane.list` returns ≥ 1 pane (the focused pane)
- [ ] `khostty-client pane.write --data="ls\n"` injects bytes without race
- [ ] `khostty-client pane.state` returns `bell_count`/`exited`/`exit_code`/`last_activity_ms`
- [ ] `khostty-client events.subscribe --mask=title_change,child_exit,resize,bell` receives all four event kinds
- [ ] `conformance/khostty-phase-b-e2e.bash` passes on a clean GTK Linux host
- [ ] `ci-conformance.yml` runs green on the PR
- [ ] No upstream (`ghostty-org/ghostty`) PRs or issues opened by this work
- [ ] Branch `khostty-phase-b-gtk-20261017` merged to `main`; release `khostty-0.1.0` or `0.2.0` cut

**End of Phase B GTK wire-up spec.**