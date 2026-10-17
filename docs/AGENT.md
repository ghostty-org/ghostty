# Agent Integration Guide

**Observed:** 2026-09-17 · How to drive, observe, and embed Khostty from an
automated agent. Read the "Available today" section first; most of what an agent
would want from *pane control* is still a design proposal, and building against
it will not work.

---

## 1. What an agent can do right now

| Capability | Status | How |
|---|---|---|
| Parse and observe terminal output | **Available** | `libghostty-vt` via C, Rust, or WASM |
| Read screen text, styles, cursor, title, pwd | **Available** | `ghostty_terminal_get`, formatter, or `Terminal.text()` |
| Search screen and scrollback | **Available** | `search.h` / `Terminal.search()` |
| Snapshot and restore terminal state | **Available** | `snapshot.h` / `Terminal.snapshot()` |
| Encode key / mouse / focus events | **Available** | `key/encoder.h`, `mouse/encoder.h`, `focus.h` |
| Run the parser in a browser or Node | **Available** | `@khostty/libghostty-vt-wasm` |
| Open a new window / tab in a running instance | **Available (narrow)** | `khostty +new-window`, `+new-tab`, `+toggle-quick-terminal` |
| Create, write to, focus, or query a **pane** | **In-process only today** | `src/apprt/ipc/{server,app_host,pane,handler,...}.zig` are implemented; `Server.bind` is exercised by the `test-agent-ipc` build step (`build.zig:79-508`); GTK runtime wire-up is pending |
| Subscribe to terminal events over IPC | **In-process only today** | `events.zig` is implemented; no GTK runtime wires `Broker` into the runtime's title/exit/resize/bell callbacks yet |
| Drive a Windows instance over IPC | **NOT AVAILABLE** | Named-pipe stub returns `error.Unimplemented` (G3) |

**The reliable agent path today is embedding, not IPC.** An agent that needs to
understand terminal output should run `libghostty-vt` in-process (Rust, Go,
Python, or JS) rather than trying to remote-control a GUI instance.

---

## 2. Recipe: observe a program's terminal output

This is the highest-value agent workflow that works today. Spawn a program under
a PTY, feed its bytes into a `Terminal`, and read structured state.

### Rust

```rust
use khostty_vt::Terminal;

let mut term = Terminal::new(120, 40)?;

// Feed whatever comes off the PTY. Malformed bytes are safe: the parser
// keeps state consistent and vt_write does not surface input errors.
term.vt_write(chunk);

// Structured observation for an agent decision:
let (x, y)              = term.cursor_position()?;   // 0-indexed
let title: Option<String> = term.title()?;          // Ok(None) = no title set yet
let pwd:   Option<String> = term.pwd()?;            // from OSC 7
let scrollback          = term.scrollback_rows()?;
let visible             = term.cursor_visible()?;
let at_prompt           = term.cursor_at_prompt()?;
let ground              = term.vt_ground()?;        // safe to inject sequences
let screen              = term.active_screen()?;    // Primary | Alternate
```

Requires a built `libghostty-vt` and `GHOSTTY_VT_LIB_DIR` or the default
`../zig-out/lib` layout. See [API.md](API.md#2-rust--khostty-vt).

> **Gap to know about:** the Rust crate has no safe wrapper for the **formatter**
> yet, so there is no `text()` / `html()` equivalent in Rust as of 2026-09-17. For
> screen text in Rust today, use the raw `ffi` bindings for
> `ghostty_formatter_*` (all `unsafe` is confined to `src/ffi.rs`), or use the
> WASM package, which does expose `text()` and `html()`.

### JavaScript / TypeScript

```js
import { Terminal } from "@khostty/libghostty-vt-wasm/api";

await using term = await Terminal.open({ cols: 120, rows: 40 });
term.write(chunk);

const snapshot = {
  cols: term.cols,
  cursor: [term.cursorX, term.cursorY],
  screen: term.screen,
  title: term.title,
  scrollbackRows: term.scrollbackRows,
  text: term.text(),
};

const search = term.search("error");
search.run();
const matches = search.totalMatches;
```

Good for agent UIs where the terminal must render in a browser and the agent runs
in the page. No native install. See [API.md](API.md#3-javascript--typescript--khosttylibghostty-vt-wasm).

### C

```c
#include <ghostty/vt.h>

GhosttyTerminal term = NULL;
if (ghostty_terminal_new(NULL, &term, 120, 40) != GHOSTTY_SUCCESS) { /* ... */ }

ghostty_terminal_vt_write(term, chunk, chunk_len);   /* never fails */

uint16_t cols = 0;
ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLS, &cols);

GhosttyString title = {0};
if (ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_TITLE, &title)
        == GHOSTTY_SUCCESS) {
  /* title.ptr / title.len — borrowed, valid until the next mutating call */
}

ghostty_terminal_free(term);
```

Borrowed pointers (`GhosttyString`, row/cell handles, search match buffers) stay
valid only until the next mutating call on the object that produced them. Copy
before you free or mutate. See [API.md](API.md#1-c-abi--libghostty-vt).

### Which artifact to link

Every language wrapper calls the same C entry points, so the conformance corpus
describes them all. Pick by runtime, not by capability:

| Runtime | Use |
|---|---|
| Rust service or agent | `khostty-vt` crate |
| Node or browser | `@khostty/libghostty-vt-wasm` |
| Go, Python, anything with cgo/ctypes | `libghostty-vt.a` / `.so` directly (`example/c-vt-*`) |

---

## 3. Recipe: drive a running instance (shipped, narrow)

Upstream IPC exposes exactly three actions. There is no pane access.

```bash
khostty +new-window          # target the detected instance
khostty +new-tab
khostty +toggle-quick-terminal
```

Targeting is by `class` (a named application instance) or `detect`. Config
overrides can be attached to `new_window` and `new_tab`:

```zig
// src/apprt/ipc.zig
NewWindow { arguments: ?[][:0]const u8 },   // per-surface config overrides
NewTab    { surface_id: u64, arguments: ?[][:0]const u8 },
```

This is a typed C ABI, not a text protocol. An agent that needs nothing more than
"open a window and run a command there" can use it and stop reading.

---

## 4. Agent IPC protocol (v1) — IN PROGRESS, not yet reachable

**The authoritative specification is [`src/apprt/ipc/protocol.md`](../src/apprt/ipc/protocol.md).**
Read that file, not this section. It is maintained next to the code and is far
more detailed than anything a summary should repeat.

This section records only the *status*, so nobody builds against an interface that
cannot yet answer.

### What exists (observed 2026-09-17 03:51 PT)

| Path | Contents |
|---|---|
| `src/apprt/ipc/protocol.md` | v1 spec: transport, framing, message shapes, 13 commands, auth, versioning, limits, worked examples |
| `src/apprt/ipc/protocol.zig` | Wire types and JSON codec |
| `src/apprt/ipc/state.zig` | Machine-readable terminal state snapshot |
| `src/apprt/ipc/events.zig` | Async event broker (title change, child exit, resize, bell) |
| `src/apprt/ipc/auth.zig` | Token authentication, fail-closed |
| `src/apprt/ipc/pane.zig` | Pane lifecycle and the `Host` vtable |
| `src/apprt/ipc/fake_host.zig` | In-process host used by tests |

Upstream `src/apprt/ipc/mod.zig` (the three-action `new_window` / `new_tab` /
`toggle_quick_terminal` channel) is unchanged. The v1 protocol is additive.

### What does not exist yet

| Missing | Consequence |
|---|---|
| `Server.bind` not invoked from any GUI runtime | The protocol is fully implemented at the module level and exercised end-to-end by `test-agent-ipc` (`build.zig:79-508`), but no running Khostty exposes the socket. GTK wire-up is Phase B1. |
| Runtime event publication | `events.zig` (`Broker`) is built and tested; the runtime's title/exit/resize/bell callbacks do not yet publish into it. Phase B4 wires the four hooks. |
| Runtime app-thread hop for `pane.write` | `app_host.zig:290-298` writes the VT bytes directly to the parser from a connection thread. This must become a `Surface.queueIo(...)` mailbox hop before a windowed build touches the surface from outside its owning thread. Phase B2. |
| `pane.focus` and `pane.search` against the GTK runtime | Both return `error.Unsupported` (`app_host.zig:177-178, 208-232`), mapped to `host_unsupported` in the protocol. The closure is upstream-core API work (no surface-by-id focus; no synchronous scan-and-return), which is out of fork-only scope. Agents should treat this as "ask the user", not as a transient failure to retry. |

**Conclusion:** the protocol is implemented at the module level and is verified
end-to-end in-process (`test-agent-ipc`). The remaining work is wiring
`Server.bind` into a real runtime (Phase B), not designing more protocol. An agent
today can connect to `test-agent-ipc` and exercise every command, including
`pane.focus` and `pane.search` against `fake_host.zig`; it cannot drive a GUI
instance, and `pane.focus` / `pane.search` will refuse under `app_host.zig`.

### Protocol outline (see the spec for detail)

Command set per `protocol.md` §4:

| `cmd` | Purpose |
|---|---|
| `ping` | Liveness and version; intentionally unauthenticated |
| `pane.create` | Split a pane (`vertical`/`horizontal`, or explicit `dir`, plus `cwd`, `title`, `focus`) |
| `pane.close` / `pane.focus` / `pane.list` | Pane lifecycle |
| `pane.write` | Inject VT bytes into a pane's parser (not into the child process) |
| `pane.state` | Cursor, title, pid, cwd, size, modes, bell count, scrollback rows |
| `pane.search` | Search screen and scrollback |
| `pane.resize_split` / `pane.equalize` / `pane.zoom` | Layout control |
| `events.subscribe` / `events.unsubscribe` | Async event stream |

Framing and transport, per `protocol.md` §2:

| Item | Value |
|---|---|
| Transport | Unix domain socket (macOS/Linux); Windows named pipe is a stated follow-up |
| Default path | macOS `~/Library/Caches/khostty/ipc.sock`; Linux/BSD `$XDG_RUNTIME_DIR/khostty/ipc.sock` (fallback `/tmp/khostty-$UID/ipc.sock`) |
| Override | `KHOSTTY_IPC_SOCKET` |
| Framing | Line-delimited JSON; integer version check, no negotiation |

Authentication, per `protocol.md` §5:

- Required for **every** command except `ping`.
- Token sources in order: `KHOSTTY_IPC_TOKEN`, then a token file
  (`KHOSTTY_IPC_TOKEN_FILE`, else `ipc.token` next to the socket).
- **Fail-closed:** with no token configured, every authenticated command is
  rejected. It never runs unauthenticated.
- Constant-time comparison; 32 random bytes hex-encoded (64 chars); token file
  expected `0600` (loose permissions are logged, not refused).

### How the design maps onto existing capability

Each command wraps something that already exists, rather than adding parser logic:

| Command | Wraps |
|---|---|
| `pane.create` / `pane.focus` / `pane.close` | `apprt.Action.new_split`, `goto_split`, `close_tab` |
| `pane.resize_split` / `pane.equalize` / `pane.zoom` | `apprt.Action.resize_split`, `equalize_splits`, `toggle_split_zoom` |
| `pane.write` | `ghostty_terminal_vt_write` |
| `pane.state` | `ghostty_terminal_get` |
| `pane.search` | `ghostty_search_*` |

One designed-in difficulty the spec calls out honestly: upstream `new_split` is
fire-and-forget and returns nothing, so the host adapter resolves the new pane by
diffing the runtime's surface registry before and after the action, and **fails**
with `internal` rather than inventing a pane id when the runtime cannot report one
within a bounded wait.

### G4 acceptance criteria (the definition of done)

- Agent can create, close, and focus panes via JSON commands
- Agent can write VT sequences to any pane
- Agent can read cursor position, title, size, and scrollback
- Agent can search scrollback text
- Concurrent pane operations do not deadlock
- Auth token required for all commands
- Protocol documented with examples

Items 2, 3, 4, and 6 are implemented at the module level. Items 1 and 5 require the
server and a real host, and remain unverified end to end. The protocol
documentation criterion is met by `src/apprt/ipc/protocol.md`.

## 5. Transport notes for the Windows path

`src/apprt/windows/ipc.zig` sketches the Windows equivalent of a Unix domain
socket:

| Item | Value |
|---|---|
| Pipe name | `\\.\pipe\khostty-{server_pid}` |
| Mode flags | `PIPE_READMODE_MESSAGE \| PIPE_WAIT` |
| Frame header | `extern struct { action: u16, length: u32 }` |
| Payload | Packed immediately after the header |
| Status | SCAFFOLD — `init`, `connect`, `acceptConnection`, `send`, `receive` all return `error.Unimplemented` |

The frame header reuses the upstream action tag (`apprt/ipc.zig`) rather than
introducing a second numbering. If G4 lands, the JSON protocol and this frame
layout need reconciling — the stub predates the draft.

---

## 6. Risks an agent integrator should know

| Risk | Why it matters | Current mitigation |
|---|---|---|
| Draft mistaken for shipped | An agent built on `pane.create` fails at runtime with nothing to call | Marked DRAFT here and in [API.md](API.md) |
| C API is unstable | Upstream says breaking changes are expected | Pin a revision; regenerate wrappers |
| ABI layout drift | Hardcoded offsets corrupt memory silently | Read `ghostty_type_json()`; Rust and WASM both assert against it |
| Borrowed buffers | Use-after-free looks like plausible data, not a crash | Copy-before-free helper; Rust RAII wrappers |
| WASM memory growth | Stale `ArrayBuffer` views read/write garbage | Views reacquired on buffer identity/length change |
| Unauthenticated IPC | Writing VT into a live shell is arbitrary code execution | Token auth is a G4 acceptance criterion, not yet built |
| Kitty graphics absent in WASM | Agents driving image protocols in a browser get nothing | Sequences parsed and safely ignored; use native for images |

---

## See also

- [API.md](API.md) — full reference for all surfaces
- [SECURITY.md](SECURITY.md) — threat model, including the IPC auth requirement
- [PLATFORMS.md](PLATFORMS.md) — per-platform availability
- [TESTING.md](TESTING.md) — how to verify an integration
- [GLOSSARY.md](GLOSSARY.md) — pane, surface, snapshot, gate
- Deep WBS §G4: [`docs/sessions/20260916-fork-assessment/02_DEEP_WBS.md`](sessions/20260916-fork-assessment/02_DEEP_WBS.md)
