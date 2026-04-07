# Reconnectable Terminal: Design Proposal

## Problem Statement

SSH terminal sessions are fragile. A network hiccup, laptop sleep, or IP change
kills the connection and all terminal state is lost. Tools like tmux and screen
provide reconnection by interposing a multiplexer, but they have their own
terminal emulators with imperfect compatibility, add visual artifacts, and
consume resources even when nobody is watching.

Mosh improved the situation by running a VT emulator on both sides and
synchronizing screen state, but it only syncs the visible viewport (no
scrollback), doesn't support true reconnection after extended disconnection,
and has limited VT compatibility.

This proposal describes how Ghostty's VT emulator library (`libghostty`) could
serve as the foundation for a reconnectable remote terminal that:

1. Runs the authoritative VT emulator on the remote host
2. Allows a Ghostty client to connect and fully sync terminal state at any time
3. Prioritizes visible viewport during bandwidth-constrained sync
4. Backfills scrollback history when bandwidth permits
5. Streams incremental updates in real-time once caught up
6. Handles high-throughput output without filling network buffers

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│ Remote Host                                                         │
│                                                                     │
│  ┌──────────┐     ┌───────────────────────────────────────────────┐  │
│  │  Shell    │────▶│  ghostty-server (libghostty)                 │  │
│  │  (bash,   │ pty │                                              │  │
│  │   zsh,    │◀────│  ┌────────────┐  ┌────────────────────────┐  │  │
│  │   etc.)   │     │  │ Terminal   │  │ Sync Engine            │  │  │
│  └──────────┘     │  │ (VT emu)   │  │                        │  │  │
│                    │  │            │  │ - State snapshotter    │  │  │
│                    │  │ ┌────────┐ │  │ - Delta tracker        │  │  │
│                    │  │ │Primary │ │  │ - Priority scheduler   │  │  │
│                    │  │ │Screen  │ │  │ - Bandwidth estimator  │  │  │
│                    │  │ │+scroll │ │  │                        │  │  │
│                    │  │ ├────────┤ │  └────────────────────────┘  │  │
│                    │  │ │Alt     │ │              │               │  │
│                    │  │ │Screen  │ │              │               │  │
│                    │  │ └────────┘ │              │               │  │
│                    │  └────────────┘              │               │  │
│                    └─────────────────────────────┬┘               │  │
│                                                  │                │  │
└──────────────────────────────────────────────────┼────────────────┘  │
                                                   │ network          │
                                          ┌────────┴────────┐         │
                                          │ Sync Protocol   │         │
                                          │ (UDP + TCP)     │         │
                                          └────────┬────────┘         │
                                                   │                  │
┌──────────────────────────────────────────────────┼────────────────┐  │
│ Client (Ghostty)                                 │                │  │
│                                                  │                │  │
│  ┌───────────────────────────────────────────────┴──────────────┐ │  │
│  │ Sync Client                                                  │ │  │
│  │                                                              │ │  │
│  │ - State receiver / applier                                   │ │  │
│  │ - Scrollback cache                                           │ │  │
│  │ - Input forwarding                                           │ │  │
│  └──────────────────────────────────┬───────────────────────────┘ │  │
│                                     │                             │  │
│  ┌──────────────────────────────────▼───────────────────────────┐ │  │
│  │ Ghostty Renderer                                             │ │  │
│  │ (GPU-accelerated, existing rendering pipeline)               │ │  │
│  └──────────────────────────────────────────────────────────────┘ │  │
│                                                                   │  │
└───────────────────────────────────────────────────────────────────┘  │
```

### Key Insight: Split the VT emulator from the renderer

Ghostty already separates its VT emulator (`src/terminal/`) from its renderer
(`src/renderer/`). The terminal library processes VT sequences and maintains
screen state; the renderer reads that state and draws pixels. This is exactly
the split we need:

- **Server**: Runs `Terminal` + pty, maintains authoritative state
- **Client**: Receives state snapshots/deltas, feeds them into a local
  `Terminal` (or directly into the renderer's data structures), and renders

## Terminal State Model

Based on analysis of Ghostty's codebase, the full terminal state that must be
synchronized consists of:

### Tier 1: Visible State (sync immediately on connect)

This is what the user sees right now. Must be transmitted first.

| State | Source | Approx Size |
|-------|--------|-------------|
| Active screen viewport (rows × cols cells) | `Screen.pages` active area | ~16KB for 80×24 (8 bytes/cell + styles) |
| Cursor position & style | `Screen.cursor` (x, y, cursor_style, pending_wrap) | 8 bytes |
| Active style (SGR state) | `Screen.cursor.style` | 32 bytes |
| Color palette (256 colors) | `Terminal.colors.palette` | 768 bytes |
| Dynamic colors (fg, bg, cursor) | `Terminal.colors.{foreground,background,cursor}` | 12 bytes |
| Terminal modes (packed bools) | `Terminal.modes.values` (8 bytes as `ModePacked`) | 8 bytes |
| Mouse mode/format | `Terminal.flags.mouse_event`, `mouse_format` | 2 bytes |
| Which screen is active | `Terminal.screens.active_key` | 1 byte |
| Terminal title | `Terminal.title` | Variable |
| Kitty keyboard flags | `Screen.kitty_keyboard` | ~32 bytes |
| Scrolling region | `Terminal.scrolling_region` | 8 bytes |
| Charset state | `Screen.charset` (G0-G3, GL, GR, single_shift) | ~12 bytes |

**Total Tier 1: ~17KB for a typical 80×24 terminal.** This can be transmitted
in a single packet on most connections.

### Tier 2: Functional State (sync soon after connect)

State that affects behavior but isn't immediately visible.

| State | Source |
|-------|--------|
| Saved cursor | `Screen.saved_cursor` |
| Tab stops | `Terminal.tabstops` |
| Protected mode | `Screen.protected_mode` |
| Alternate screen contents (if primary is active) | `Screen.pages` on inactive screen |
| Saved mode values | `Terminal.modes.saved` |
| Semantic prompt state | `Screen.semantic_prompt` |
| PWD (OSC 7) | `Terminal.pwd` |

### Tier 3: Historical State (backfill when bandwidth allows)

| State | Source |
|-------|--------|
| Scrollback buffer | `Screen.pages` (all pages above active area) |
| Kitty graphics/images | `Screen.kitty_images` |
| Hyperlink data | Page-level hyperlink maps |

## Sync Protocol Design

### Design Principles

1. **State-based, not stream-based.** Like Mosh's SSP, we synchronize terminal
   state objects, not the raw byte stream from the pty. The server can skip
   intermediate states when the client can't keep up.

2. **Idempotent updates.** Every message from server to client is a
   self-contained description of "make the state look like this." Duplicate
   delivery, reordering, and packet loss are all handled gracefully.

3. **Prioritized transmission.** The visible viewport is always the highest
   priority. Scrollback is transmitted in the background.

4. **Monotonic versioning.** Every state change increments a version counter.
   The client reports the latest version it has applied. The server only needs
   to diff from the client's version to its current version.

### Protocol Layers

```
┌─────────────────────────────────┐
│ Application: State Sync         │  Tier 1/2/3 state objects
├─────────────────────────────────┤
│ Framing: Priority Multiplexer  │  Priority channels, flow control
├─────────────────────────────────┤
│ Transport: Reliable UDP + TCP   │  Encryption, authentication,
│                                 │  roaming, congestion control
└─────────────────────────────────┘
```

### Transport Layer

Use **QUIC** (RFC 9000) rather than building a custom UDP protocol like Mosh.
QUIC gives us:

- **Multiple independent streams**: Perfect for priority channels (viewport
  stream, scrollback stream, input stream) without head-of-line blocking
- **Connection migration**: Handles IP changes natively, replacing Mosh's
  custom roaming logic
- **0-RTT reconnection**: QUIC session resumption means reconnection is fast
- **Built-in congestion control**: No need to build our own
- **Encryption**: TLS 1.3 built in

Alternatively, for simplicity in a v1, a plain TCP connection with a thin
framing layer could work, with reconnection handled by session tokens. The
key insight is that the protocol is state-based, so the transport just needs
reliable ordered delivery per-stream — the interesting logic is above.

### Stream Architecture (within QUIC or multiplexed TCP)

| Stream | Direction | Priority | Content |
|--------|-----------|----------|---------|
| **Control** | Bidirectional | Highest | Handshake, resize, capability negotiation |
| **Input** | Client → Server | Highest | Keystrokes (forwarded to pty) |
| **Viewport** | Server → Client | High | Active screen state + cursor |
| **Metadata** | Server → Client | Medium | Modes, colors, title, Tier 2 state |
| **Scrollback** | Server → Client | Low | Historical pages, backfill |
| **Images** | Server → Client | Lowest | Kitty graphics data |

### State Versioning

The server maintains a monotonically increasing **epoch counter**. Each time
the terminal state changes, the epoch advances. Different state tiers can have
independent epoch tracking:

```
ViewportEpoch: u64    // Incremented on any visible screen change
MetadataEpoch: u64    // Incremented on mode/color/title changes
ScrollbackEpoch: u64  // Incremented when pages scroll off the viewport
```

The client reports its last-applied epoch per tier. The server computes the
diff from the client's epoch to its current epoch.

### Connection Lifecycle

#### Initial Connection

```
Client                              Server
  │                                    │
  │──── ClientHello ──────────────────▶│  Session token, terminal size,
  │                                    │  capabilities
  │◀─── ServerHello ─────────────────▶│  Session ID, server capabilities
  │                                    │
  │◀─── ViewportSnapshot ────────────│  Full Tier 1 state
  │◀─── MetadataSnapshot ───────────│  Full Tier 2 state
  │                                    │
  │◀─── ViewportDelta ───────────────│  Real-time updates begin
  │◀─── ScrollbackChunk ────────────│  Background backfill begins
  │──── Input ────────────────────────▶│  Keystrokes flow
  │                                    │
```

#### Reconnection (after disconnection)

```
Client                              Server
  │                                    │
  │──── ClientHello ──────────────────▶│  Same session token,
  │     (session_token, last_epochs)   │  last-seen epochs per tier
  │                                    │
  │◀─── ServerHello ─────────────────│  Confirms session, current epochs
  │                                    │
  │  [If epochs are close: delta sync]
  │◀─── ViewportDelta ───────────────│  Diff from client's epoch
  │                                    │
  │  [If epochs are far apart: full snapshot]
  │◀─── ViewportSnapshot ────────────│  Full Tier 1 state
  │                                    │
  │◀─── ScrollbackChunk ────────────│  Resume backfill from where
  │                                    │  client left off
  │──── Input ────────────────────────▶│
  │                                    │
```

The server can decide whether to send a delta or full snapshot based on how
many epochs have passed. If the gap is small (the client was disconnected
briefly), a delta is more efficient. If the gap is large (the client was
disconnected for hours), a full snapshot is cheaper than replaying thousands
of deltas.

## State Serialization Format

### Option A: VT Escape Sequence Replay (simplest)

Ghostty already has a `TerminalFormatter` with `.vt` format (`formatter.zig`)
that can serialize terminal state as VT escape sequences. This includes:

- Color palette (OSC 4 sequences)
- Terminal modes (CSI ?Nh / CSI ?Nl for each non-default mode)
- Scrolling region (DECSTBM, DECSLRM)
- Tab stops (clear all + set each)
- Keyboard state (modifyOtherKeys)
- PWD (OSC 7)
- Screen contents (with SGR styling, cursor positioning)

**Advantages:**
- Already implemented and tested
- The client can just feed these bytes into a local `Terminal` instance
- No new serialization format to define
- Naturally handles all the edge cases that VT sequences handle

**Disadvantages:**
- Verbose: SGR sequences repeat redundant state between cells
- No binary compression
- Scrollback would need to be sent row by row

### Option B: Binary State Protocol (more efficient)

A custom binary format that maps directly to Ghostty's internal structures.

```
ViewportSnapshot {
    epoch: u64
    terminal_size: { rows: u16, cols: u16 }
    active_screen: enum { primary, alternate }
    cursor: { x: u16, y: u16, style: u8, pending_wrap: bool }
    modes: [8]u8           // Raw ModePacked bytes
    palette: [256 * 3]u8   // RGB values
    dynamic_colors: { fg: ?RGB, bg: ?RGB, cursor_color: ?RGB }
    scrolling_region: { top: u16, bottom: u16, left: u16, right: u16 }
    charset: { g0-g3: u8, gl: u8, gr: u8 }
    mouse: { event: u8, format: u8 }
    title_len: u16
    title: [title_len]u8
    // Screen content follows
    rows: [num_rows]RowData
}

RowData {
    flags: u8  // wrap, wrap_continuation, semantic_prompt
    cells: [num_cols]CellData
}

CellData {
    codepoint: u21
    style_id: u16    // Index into a style table sent separately
    wide: u2
    semantic_content: u2
    // Grapheme clusters sent separately for cells that have them
}

// Style table (deduplicated)
StyleTable {
    count: u16
    styles: [count]StyleData
}

StyleData {
    fg: Color       // enum { default, palette(u8), rgb(RGB) }
    bg: Color
    underline_color: Color
    flags: u16      // bold, italic, underline, etc.
}
```

**Advantages:**
- Compact: a typical 80×24 viewport with few unique styles is ~5-8KB
- Styles are deduplicated (most terminals use <10 unique styles at a time)
- Easy to delta-compress between versions
- Maps directly to Ghostty's internal representation

**Disadvantages:**
- New format to define, implement, and version
- Must handle format evolution as Ghostty adds features

### Recommendation: Hybrid Approach

Use **Option B (binary) for the viewport and metadata** (compact, fast,
delta-friendly) and **Option A (VT sequences) for scrollback backfill**
(simpler, already works, scrollback doesn't need to be fast).

## Delta Encoding

### Viewport Deltas

When the client is connected and keeping up, the server sends incremental
viewport deltas rather than full snapshots. The delta format leverages the
fact that most screen updates are localized:

```
ViewportDelta {
    epoch: u64
    base_epoch: u64    // Client's epoch this delta applies to
    changes: []Change
}

Change = union {
    // A contiguous run of cells changed at a position
    CellRun: {
        row: u16, col: u16
        cells: []CellData
    }

    // A row was scrolled (common case: new line at bottom)
    ScrollUp: {
        top: u16, bottom: u16  // scroll region
        count: u16
        new_rows: []RowData    // the new rows at the bottom
    }

    // Cursor moved
    CursorMove: { x: u16, y: u16, style: u8 }

    // Mode changed
    ModeChange: { mode: u16, value: bool }

    // Title changed
    TitleChange: { title: []u8 }

    // Palette entry changed
    PaletteChange: { index: u8, rgb: RGB }
}
```

The server tracks which rows and cells have been modified since the last
frame sent to the client. This mirrors how Ghostty's renderer already
tracks dirty state — the Page's `serial` counter and the row/cell dirty
tracking can serve this purpose.

### Scrollback Transmission

Scrollback pages are sent as chunks, newest first (since the user is most
likely to scroll up to recent history). Each chunk is tagged with the page's
`serial` number:

```
ScrollbackChunk {
    page_serial: u64
    row_offset: u16        // Within the page
    row_count: u16
    rows: []RowData        // Or VT-formatted text
    has_more: bool
}
```

The client acknowledges received chunks. The server only sends scrollback
data when the viewport stream has spare bandwidth.

## Bandwidth Management

### The Core Problem

When a process is spewing output (e.g., `cat /dev/urandom | xxd`), the server's
terminal state is changing faster than the network can transmit. We must:

1. Never buffer unbounded output toward the client
2. Always prioritize the current visible state
3. Make Ctrl-C work within one RTT

### Frame Rate Adaptation (borrowing from Mosh)

The server maintains a **frame budget** based on estimated bandwidth:

```
frame_interval = max(SRTT / 2, MIN_FRAME_INTERVAL)
max_frame_size = estimated_bandwidth * frame_interval
```

When the terminal is changing rapidly:

1. The server accumulates changes for `collection_interval` (8ms, matching
   Mosh's empirically derived value)
2. It then computes the delta from the last acknowledged client epoch
3. If the delta fits in `max_frame_size`, send it as a delta
4. If not, send a full viewport snapshot (which is bounded by terminal size)
5. Drop all intermediate state — the client jumps to the current state

This ensures:
- Network buffers never grow unboundedly
- The client always sees the latest state, not stale queued data
- Ctrl-C (sent on the input stream, which is always highest priority) arrives
  within one RTT

### Priority Scheduling

The server allocates bandwidth across streams using weighted fair queuing:

```
During initial sync:
    Viewport:   80% of bandwidth
    Metadata:   15%
    Scrollback:  5%
    Images:      0%

During steady state:
    Viewport:   90% (but usually uses much less)
    Metadata:    5%
    Scrollback:  5% (if any pending)
    Images:      0% (background)

During spewing:
    Viewport:  100% (everything else paused)
    Scrollback and images resume when viewport is idle
```

When viewport is idle (no changes for >100ms), the spare bandwidth is
reallocated to scrollback backfill and image transfer.

### Scrollback Backfill Strategy

After initial connection and viewport sync, scrollback is backfilled in
reverse chronological order (newest pages first):

```
Phase 1: Sync viewport (Tier 1)         ~17KB, <1 frame
Phase 2: Sync metadata (Tier 2)          ~1KB,  <1 frame
Phase 3: Backfill scrollback             Pages newest→oldest
Phase 4: Transfer images                 As bandwidth allows
```

During Phase 3, if new viewport data arrives:
- Pause scrollback transmission immediately
- Send viewport update
- Resume scrollback after viewport is idle

The client can begin scrolling through history as soon as it receives any
scrollback data, even if backfill is incomplete. The UI should indicate
which portions are available vs. still loading.

## Server-Side Design

### `ghostty-server` Process

A lightweight daemon that:

1. Creates a pty and spawns the user's shell
2. Instantiates a `Terminal` (libghostty) to process pty output
3. Listens for client connections
4. Runs the sync engine to transmit state

```zig
const Server = struct {
    terminal: Terminal,
    pty: Pty,
    
    // Sync state
    viewport_epoch: u64,
    metadata_epoch: u64,
    scrollback_epoch: u64,
    
    // Connected clients (usually 1, could support read-only viewers)
    clients: []Client,
    
    // Bandwidth estimation
    srtt: u64,      // Smoothed round-trip time
    bandwidth: u64, // Estimated bytes/sec
    
    // Collection interval timer
    collection_timer: Timer,
};

const Client = struct {
    connection: QuicConnection,
    
    // Last acknowledged epochs per tier
    viewport_ack: u64,
    metadata_ack: u64,
    scrollback_ack: u64,
    
    // Scrollback backfill progress
    scrollback_cursor: ?PageList.Pin,
};
```

### Hooking into Terminal State Changes

The sync engine needs to know when terminal state changes. Rather than
modifying every terminal operation, we can leverage several existing
mechanisms:

1. **Page serial numbers**: `PageList.Node.serial` is already incremented
   when pages are created. We can extend this to track modifications.

2. **Dirty flags**: `Terminal.Dirty` and `Screen.Dirty` already track
   palette changes, reverse colors, clear events, and selection changes.

3. **Collection interval**: Like Mosh, batch changes for 8ms before
   computing a delta. This naturally coalesces burst output.

The cleanest approach is a **post-write hook** on the terminal: after each
call to `Terminal.processOutput()` (which feeds pty data through the
parser/stream/handler), bump the viewport epoch if any visible cells or
cursor state changed.

### Handling Output Spew

When the pty is producing output faster than we can sync:

```
loop {
    // Read from pty (non-blocking, batch)
    const data = pty.readNonBlocking();
    terminal.processOutput(data);
    
    // Check if we should send a frame
    if (collection_timer.expired()) {
        if (client.viewport_ack < viewport_epoch) {
            // Client is behind — send snapshot, not delta
            sendViewportSnapshot(client);
        } else {
            // Client is caught up — send delta
            sendViewportDelta(client);
        }
        collection_timer.reset();
    }
}
```

The key insight: **we always process all pty output through the terminal
emulator** (keeping the authoritative state up to date), but we only send
the *current* state to the client, skipping all intermediate frames. The
terminal emulator processes data at memory speed; the bottleneck is only
the network.

## Client-Side Design

### Two Approaches

**Approach A: Shadow Terminal**

The client maintains its own `Terminal` instance. Viewport snapshots/deltas
are applied by generating equivalent VT sequences and feeding them to the
client's terminal. The client's renderer draws from this local terminal.

- **Pro**: Existing renderer works unchanged. Local scrollback works.
- **Con**: Two terminal emulators in the loop. Potential fidelity issues
  with VT sequence round-tripping.

**Approach B: Direct Rendering from Wire State**

The client deserializes the binary viewport data directly into page/cell
structures that the renderer can consume. No local terminal emulator.

- **Pro**: Perfect fidelity. Single source of truth.
- **Con**: Requires renderer changes to accept externally-provided pages.
  Local scrollback is "remote scrollback" until backfilled.

**Recommendation**: Start with **Approach A** for simplicity. The
`TerminalFormatter` with `.vt` output already exists and handles the
complex edge cases. Move to Approach B only if round-trip fidelity becomes
a problem or performance demands it.

### Client State Management

```
ClientState {
    // Local terminal fed by server state
    terminal: Terminal,
    
    // Scrollback cache — persists across reconnections
    scrollback_cache: ScrollbackCache,
    
    // Connection state
    connection: ?Connection,
    session_token: [32]u8,
    
    // Epochs
    viewport_epoch: u64,
    metadata_epoch: u64,
    scrollback_epoch: u64,
}
```

The `ScrollbackCache` stores backfilled scrollback pages locally. On
reconnection, the client reports which pages it already has, and the server
skips those during backfill. This means reconnecting to a long-running
session doesn't require re-transmitting all scrollback.

### Input Handling

User input is sent immediately on the input stream. Unlike Mosh, we do NOT
do speculative local echo in v1. Reasons:

1. Ghostty's cursor and rendering is already optimized for low latency
2. Speculative echo adds complexity and can produce visual artifacts
3. Modern networks are fast enough for most use cases
4. Can be added later as an optional enhancement

Input is sent as raw bytes (what would normally go to the pty):

```
InputMessage {
    sequence: u64    // For acknowledgment/ordering
    data: []u8       // Raw bytes to write to pty
}
```

## Resize Handling

Terminal resize is a critical operation that must be synchronized:

1. Client sends resize request: `ResizeMessage { rows, cols, width_px, height_px }`
2. Server calls `terminal.resize()` and sends `SIGWINCH` to the pty
3. Server immediately sends a full viewport snapshot (since all rows may reflow)
4. Client applies the snapshot

If the client and server are temporarily different sizes (e.g., during
reconnection from a differently-sized window), the server resizes to match
the client. The server always authoritative tracks the current size.

## Session Management

### Session Persistence

`ghostty-server` maintains sessions on disk so they survive server restarts:

```
~/.local/share/ghostty-server/sessions/
    <session-id>/
        session.json    # Session metadata (pty fd, shell pid, etc.)
        terminal.state  # Serialized terminal state (for crash recovery)
```

### Session Discovery

When a Ghostty client connects, it can list available sessions:

```
Client ──── ListSessions ────▶ Server
Client ◀─── SessionList ────── Server
    [{id: "abc123", title: "vim ~/project", created: "...", shell_pid: 1234}, ...]
```

### Multi-client Support

Multiple clients can connect to the same session:

- **One writer** (receives input focus)
- **N readers** (view-only, useful for pair programming or monitoring)
- Clients can request/transfer write access via the control stream

## Security Model

### Authentication

1. Initial connection is bootstrapped via SSH (like Mosh):
   - Client SSHs to the server and runs `ghostty-server --new`
   - Server prints a session token and port
   - Client connects directly using the token
2. All subsequent communication is encrypted (QUIC/TLS or a symmetric cipher
   like AES-GCM with the session key)
3. Session tokens are single-use for initial connection, then upgraded to
   session keys

### Authorization

- The session token grants full access to the terminal session
- Token is scoped to one session, one server
- Tokens expire after a configurable idle timeout

## Implementation Phases

### Phase 1: Core Protocol (MVP)

- `ghostty-server` binary: pty management, terminal emulation, basic TCP server
- Full viewport snapshot on connect (VT format, using existing `TerminalFormatter`)
- Incremental viewport updates (VT sequences for changed regions)
- Input forwarding
- Resize handling
- Simple reconnection (full re-snapshot)
- No scrollback sync

This is roughly equivalent to Mosh's functionality but with full Ghostty
VT compatibility and reconnection support.

### Phase 2: Efficient Sync

- Binary viewport format (replace VT sequences for viewport)
- Delta encoding for viewport updates
- Epoch-based versioning with smart delta-vs-snapshot decisions
- Bandwidth estimation and frame rate adaptation
- Collection interval batching

### Phase 3: Scrollback Backfill

- Reverse-chronological scrollback transmission
- Client-side scrollback cache with persistence
- Incremental backfill (resume from where you left off on reconnect)
- Priority scheduling (viewport > scrollback)
- UI indication of backfill progress

### Phase 4: Advanced Features

- QUIC transport with connection migration
- Kitty graphics image sync
- Speculative local echo (like Mosh)
- Multi-client sessions
- Session persistence across server restarts

## Comparison with Prior Art

| Feature | SSH | Mosh | tmux/screen | This Proposal |
|---------|-----|------|-------------|---------------|
| Survives disconnect | No | Partial | Yes | Yes |
| Survives IP change | No | Yes | No* | Yes (QUIC) |
| Scrollback sync | N/A | No | Yes (own emu) | Yes (backfill) |
| VT compatibility | Full** | Limited | Limited | Full (Ghostty) |
| Bandwidth efficient | No (TCP) | Yes (SSP) | No (TCP) | Yes |
| Local echo prediction | No | Yes | No | Planned |
| Ctrl-C under load | Delayed | Instant | Delayed | Instant |
| State sync after hours | N/A | Drift*** | Yes | Yes (snapshot) |

\* tmux requires re-SSH.
\** SSH passes raw bytes, so compatibility depends on the local terminal.
\*** Mosh can desync on features it doesn't understand (OSC, etc.)

## Implementation Leverage Points

Analysis of Ghostty's internals reveals several existing mechanisms that the
sync engine can directly reuse, reducing implementation effort significantly:

### 1. Page Memory Model Enables Zero-Copy Serialization

Pages use **offset-based addressing** (`Offset(T)` relative to the `memory`
base pointer), not raw pointers. This means an entire Page can be `memcpy`'d
and all internal references remain valid. For the binary protocol, we can
transmit raw page memory (or compressed page memory) without any
serialization/deserialization — the client just maps the received bytes
and the data structures are immediately usable.

This is a massive advantage over approaches that require walking every cell
and encoding it. A typical page is ~512KB and contains ~215 rows. With
zstd compression on terminal text (which is highly repetitive), this could
compress to ~50-100KB per page.

### 2. RenderState Pattern = Sync Engine Pattern

The existing `RenderState.update()` (`src/terminal/render.zig`) already
implements exactly the pattern the sync engine needs:

- Takes a terminal mutex lock
- Checks dirty flags at three levels (Terminal, Screen, Row/Page)
- Copies only changed state into a snapshot
- Clears dirty flags after consumption
- Produces a `.full` / `.partial` / `.false` dirty result

The sync engine is essentially a second "renderer" that produces network
frames instead of GPU frames. It can reuse the same dirty tracking
infrastructure. The key difference: the sync engine produces wire-format
snapshots/deltas instead of GPU cell buffers.

### 3. Existing Dirty Tracking is Sufficient

The three-layer dirty tracking already in place provides exactly the change
detection the delta protocol needs:

| Dirty Layer | Sync Use |
|---|---|
| `Terminal.Dirty.palette` | Triggers palette re-sync |
| `Terminal.Dirty.reverse_colors` | Triggers mode re-sync |
| `Terminal.Dirty.clear` | Triggers full viewport snapshot |
| `Screen.Dirty.selection` | Triggers selection state update |
| `Row.dirty` | Identifies which rows need delta encoding |
| `Page.dirty` | Identifies bulk-modified pages |
| `PageList.Node.serial` | Identifies new vs. existing scrollback pages |
| `kitty_images.dirty` | Triggers image re-sync |

No new dirty tracking needs to be added to the core terminal code.

### 4. Style Deduplication Already Exists

Styles are ref-counted and deduplicated in per-page `StyleSet`. The binary
protocol's "style table" concept maps directly to this — we can transmit the
page's style set entries (typically <10 unique styles for a viewport) and
reference them by ID in the cell data, exactly as the internal representation
does.

### 5. TerminalFormatter Handles the Hard Cases

The existing `TerminalFormatter` with `.vt` and `.extra = .all` already
handles serializing: palette (all 256 entries as OSC 4), non-default modes
(iterates all `ModePacked` fields), scrolling region (DECSTBM/DECSLRM),
tabstops (clear all + set each), keyboard state (modifyOtherKeys), PWD
(OSC 7), and full screen contents with styles. This is the Phase 1 wire
format with zero additional implementation work.

### 6. Parser State Does Not Need Syncing

The VT parser state machine lives on the `Stream` handler, not on
`Terminal`. It's ephemeral state that exists only during byte processing.
Since the server fully processes all pty output through the terminal
emulator, there is never a case where parser state needs to cross the wire.
Similarly, the APC handler (for in-progress Kitty graphics uploads) is
ephemeral.

### 7. Colors Survive fullReset()

One subtle detail: `Terminal.colors` (the 256-entry palette and dynamic
fg/bg/cursor colors) survive a terminal `fullReset()` (RIS). This means
color state can persist across shell restarts within the same session and
must always be synced as part of Tier 1 state.

## Open Questions

1. **Should the server support multiple simultaneous shells per session?**
   This would make it a tmux replacement. v1 should be 1:1 (one session, one
   shell) to keep it simple, but the architecture should not preclude this.

2. **How to handle the alternate screen (e.g., when vim is running)?** The
   alternate screen is typically small (viewport only, no scrollback). We
   should sync it fully as part of Tier 1 metadata. When the program exits
   and switches back to primary, we need to sync the primary screen's full
   scrollback again.

3. **Should the client cache terminal state to disk for instant reconnect?**
   The client could write periodic snapshots to disk so that on reconnect,
   it can show the last-known state immediately while fetching updates from
   the server. This provides a "last known good" experience even before
   the network comes up.

4. **Should scrollback be compressed?** Scrollback is mostly text, which
   compresses extremely well (10-20x with zstd). Given that scrollback is
   the bulk of what we transmit, compression could significantly reduce
   backfill time. zstd streaming compression would be natural here.

5. **How to handle the server running on a different OS or architecture?**
   The binary format must be endian-independent and version-tagged. The VT
   format (Phase 1) is inherently portable since it's just text.

6. **How to handle `SIGWINCH` race conditions?** If the client resizes while
   disconnected, on reconnect the server must resize to the new dimensions.
   If two clients connect with different sizes, the server must pick one
   (the writer's size) and the reader must adapt (or use a viewport
   transformation).
