# Host runtime

Each versioned remote host daemon owns multiple session threads, PTYs and children.
Local sessions use a short-lived broker plus an independent holder process per
session; each holder owns its PTY, VT state and child. Each pane has a persistent
UUID; its saved descriptor identifies its local or SSH host and runtime revision.
The App owns one multiplexed relay per connection/revision.

The local H handshake carries an explicit open request. The outer protocol routes
open/data/detach/error frames by stream ID. Remote output, resize, snapshot ACK,
writer arbitration and exit remain per Session. The M metadata frame supplies the
PTY foreground/shell cwd on attach and changes. It also reports password input
mode and child runtime; local sessions include validated foreground PID and
slave PTY name for local-only process presentation.
J version 2 includes cell and pixel dimensions, password-input state and elapsed
runtime. M repeats those metadata as they change; the final runtime M is queued
before X, whose exit-code text remains unchanged. R accepts the legacy four-byte
cell-size form and the version-two eight-byte cell-plus-pixel form.

`connect LOCAL_SOCKET CONNECTION_JSON` supports `transport: "ssh"` (also the
default for old JSON) and `transport: "local"`. The local transport uses a private,
stable `local_state_directory`; it bypasses SSH but shares the host protocol.
The relay owns the listener and pane sockets independently from its replaceable
host connection. `retry-local LOCAL_SOCKET --interactive` requests an immediate
retry with explicit interactive authentication; healthy streams remain attached.
Local startup uses the helper from the descriptor's versioned bundle. A broker
can exit while its holders continue running. A later broker verifies each holder
with its UUID, generation and private capability before adopting it. Persisted
numeric PIDs are metadata only and are never signalled.

Only local C/open requests may carry a one-time launch specification with
Ghostty's resolved argv, environment, cwd and initial terminal dimensions.
Optional initial input is sent to the new PTY once, then discarded. Launch data
is never stored in session records or replayed on transport reconnect. SSH
requests reject local launch data. `local-launch/1` advertises this support; an
older local host reports a clear error without creating a replacement shell.

`list-local SOCKET` sends the read-only L sequence-zero request through an
already running relay. It does not create or attach a session and does not
refresh detached lifetime. Concurrent catalogue requests share one host query.
The bounded JSON array contains only identity, timestamps, PID, end/recovery
state, lifetime policy and optional cwd. It excludes holder capabilities and
launch argv/environment. Older hosts already support L.

Local `T` frames carry connection state JSON and a pane attachment generation in `seq`. Clients
must pause input until a fresh snapshot is restored, acknowledged and followed
by writer confirmation. `I`, `R`, `W` and `K` carry the current generation in `seq`;
snapshot `A` keeps its output offset in `seq` and carries the generation as eight
big-endian bytes. A single-pane retry changes only its generation; a transport
loss retires every affected attachment. Relay startup uses a fresh random seed
so delayed input cannot match a restarted relay. The relay rejects stale frames and never replays disconnected
input. The remote host protocol and snapshot output offsets stay independent.
Session-level errors retain the pane; only an explicit retry reopens that stream
with `create=false`. A confirmed UUID is never silently recreated.
Before any session open, heartbeat capability negotiation must confirm
`strict-open/1`. Old runtimes without this guarantee remain running but cannot
be attached by the new supervisor. `durable-close/1` remains independently
negotiated so pending closes do not depend on opening a session.

`serve`, `host`, `host-local`, `session-holder` and `bridge` remain internal
daemon/testing operations. The fixed VPS launcher and per-process experimental
routing variables have been removed.

Output queues and active-session counts are bounded per peer and by a shared
128 MiB process budget covering queued and partial input buffers. Slow readers
disconnect when either budget is exhausted; PTY reading and lifetime enforcement
continue. Runtime revision upgrades never
restart a daemon with active sessions. Host crash, escaped descendants and
cross-core snapshot migration still have the limits documented in
RELEASE_PROGRESS.md.
