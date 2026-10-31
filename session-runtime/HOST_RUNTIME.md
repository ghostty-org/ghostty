# Host runtime

Each versioned host daemon owns multiple session threads, PTYs and children. Each
pane has a persistent UUID; its saved descriptor identifies its local or SSH host
and runtime revision. The App owns one multiplexed relay per connection/revision.

The local H handshake carries an explicit open request. The outer protocol routes
open/data/detach/error frames by stream ID. Remote output, resize, snapshot ACK,
writer arbitration and exit remain per Session. The M metadata frame supplies the
remote foreground/shell cwd on attach and changes; the GUI uses that path with its
saved SSH identity for sidebar presentation.

`connect LOCAL_SOCKET CONNECTION_JSON` supports `transport: "ssh"` (also the
default for old JSON) and `transport: "local"`. The local transport uses a private,
stable `local_state_directory`; it bypasses SSH but shares the host protocol.
The relay owns the listener and pane sockets independently from its replaceable
host connection. `retry-local LOCAL_SOCKET --interactive` requests an immediate
retry with explicit interactive authentication; healthy streams remain attached.

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

`serve`, `host` and `bridge` remain internal daemon/testing operations. The fixed
VPS launcher and per-process experimental routing variables have been removed.

Output queues and active-session counts are bounded. Slow readers disconnect;
PTY reading and lifetime enforcement continue. Runtime revision upgrades never
restart a daemon with active sessions. Host crash, escaped descendants and
cross-core snapshot migration still have the limits documented in
RELEASE_PROGRESS.md.
