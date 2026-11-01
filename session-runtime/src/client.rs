//! Persistent local client endpoint with one reconnecting transport per host.
use crate::{
    host::{self, inner_frame},
    record::SessionSummary,
    registry::OpenRequest,
    Frame, Peer, ACK, CLAIM, CLOSE, EXIT, INPUT, MAX_FRAME, RESIZE, SNAPSHOT,
};
use std::{
    collections::HashMap,
    io,
    os::unix::net::{UnixListener, UnixStream},
    path::Path,
    sync::{mpsc, Arc},
    thread,
    time::{Duration, Instant},
};

const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);
const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(45);
const PEER_IDLE_TIMEOUT: Duration = Duration::from_secs(30);
const STABLE_RESET: Duration = Duration::from_secs(60);
const MAX_PEERS: usize = 64;
const MAX_LIST_WAITERS: usize = 3;
const LIST_REQUEST_TIMEOUT: Duration = Duration::from_secs(60);

pub struct RelayTransport {
    pub socket: UnixStream,
    pub guard: Box<dyn Send>,
}

pub type Connector = Arc<dyn Fn(bool) -> io::Result<RelayTransport> + Send + Sync>;

#[derive(Clone, Copy, PartialEq, Eq)]
enum State {
    Connecting,
    Reconnecting,
    Online,
    Attention,
}

impl State {
    fn name(self) -> &'static str {
        match self {
            Self::Connecting => "connecting",
            Self::Reconnecting => "reconnecting",
            Self::Online => "connecting",
            Self::Attention => "attention",
        }
    }
}

struct LocalPeer {
    peer: Peer,
    generation: u64,
    open: Option<Vec<u8>>,
    initial_create: bool,
    remote_stream: Option<u64>,
    snapshot_generation: Option<u64>,
    snapshot_confirmed: bool,
    snapshot_acked: bool,
    writer_requested: bool,
    writer_ready: bool,
    retry_requested: bool,
    failed: bool,
    ended: bool,
    control: bool,
    control_done: bool,
    close_id: Option<String>,
    list_requested: bool,
}

impl LocalPeer {
    fn new(peer: Peer, generation: u64) -> Self {
        Self {
            peer,
            generation,
            open: None,
            initial_create: false,
            remote_stream: None,
            snapshot_generation: None,
            snapshot_confirmed: false,
            snapshot_acked: false,
            writer_requested: false,
            writer_ready: false,
            retry_requested: false,
            failed: false,
            ended: false,
            control: false,
            control_done: false,
            close_id: None,
            list_requested: false,
        }
    }
}

fn next_generation(generation: u64) -> u64 {
    generation.wrapping_add(1).max(1)
}

fn retry_delay(attempt: u32) -> Duration {
    let exponent = attempt.saturating_sub(1).min(6);
    Duration::from_millis((500u64 << exponent).min(30_000))
}

fn has_capability(data: &[u8], capability: &str) -> bool {
    std::str::from_utf8(data).is_ok_and(|text| text.split(',').any(|item| item == capability))
}

fn status_frame(
    generation: u64,
    state: State,
    attempt: u32,
    retry_in: Option<Duration>,
    message: Option<&str>,
) -> Frame {
    let mut value = serde_json::json!({
        "state": state.name(),
        "attempt": attempt,
    });
    if let Some(delay) = retry_in {
        value["retry_in_ms"] = serde_json::json!(delay.as_millis().min(u64::MAX as u128) as u64);
    }
    if let Some(message) = message {
        value["message"] = serde_json::json!(message);
    }
    Frame::new(b'T', generation, value.to_string().as_bytes())
}

fn set_status(
    peers: &mut HashMap<u64, LocalPeer>,
    state: State,
    attempt: u32,
    retry_in: Option<Duration>,
    message: Option<&str>,
) {
    for peer in peers
        .values_mut()
        .filter(|p| !p.control && !p.ended && (!p.failed || p.retry_requested))
    {
        peer.peer.push(status_frame(
            peer.generation,
            state,
            attempt,
            retry_in,
            message,
        ));
    }
}

fn set_peer_status(peer: &mut LocalPeer, attempt: u32) {
    if !peer.control && !peer.ended {
        peer.peer.push(status_frame(
            peer.generation,
            State::Connecting,
            attempt,
            None,
            None,
        ));
    }
}

fn open_request(peer: &LocalPeer) -> io::Result<(u8, Vec<u8>)> {
    let bytes = peer
        .open
        .as_ref()
        .ok_or_else(|| io::Error::other("missing open request"))?;
    let mut request: OpenRequest = serde_json::from_slice(bytes)?;
    // A confirmed or explicitly retried UUID is attach-only. It can never
    // silently launch a shell or replay an Agent after daemon loss.
    request.create = request.create && !peer.snapshot_confirmed && !peer.retry_requested;
    if !request.create {
        request.launch = None;
    }
    Ok((b'C', serde_json::to_vec(&request)?))
}

fn clear_launch_data(peer: &mut LocalPeer) {
    let Some(bytes) = peer.open.as_ref() else {
        return;
    };
    let Ok(mut request) = serde_json::from_slice::<OpenRequest>(bytes) else {
        return;
    };
    request.create = false;
    request.launch = None;
    if let Ok(bytes) = serde_json::to_vec(&request) {
        peer.open = Some(bytes);
    }
}

fn begin_list(remote: &mut Peer, peers: &HashMap<u64, LocalPeer>, in_flight: &mut bool) {
    if !*in_flight
        && peers
            .values()
            .any(|peer| peer.list_requested && !peer.control_done)
    {
        remote.push(Frame::new(b'L', 0, &[]));
        *in_flight = true;
    }
}

fn begin_open(
    remote: &mut Peer,
    peers: &mut HashMap<u64, LocalPeer>,
    remote_streams: &mut HashMap<u64, u64>,
    next_stream: &mut u64,
) -> io::Result<()> {
    let ids: Vec<_> = peers
        .iter()
        .filter(|(_, p)| {
            !p.control
                && !p.ended
                && p.open.is_some()
                && p.remote_stream.is_none()
                && (!p.failed || p.retry_requested)
        })
        .map(|(id, _)| *id)
        .collect();
    for id in ids {
        let (kind, data) = {
            let peer = peers.get(&id).unwrap();
            open_request(peer)?
        };
        let stream = *next_stream;
        *next_stream = next_generation(*next_stream);
        remote_streams.insert(stream, id);
        peers.get_mut(&id).unwrap().remote_stream = Some(stream);
        peers.get_mut(&id).unwrap().snapshot_generation = None;
        peers.get_mut(&id).unwrap().snapshot_acked = false;
        remote.push(Frame::new(kind, stream, &data));
    }
    Ok(())
}

fn begin_controls(
    remote: &mut Peer,
    peers: &mut HashMap<u64, LocalPeer>,
    remote_streams: &mut HashMap<u64, u64>,
    next_stream: &mut u64,
) {
    let ids: Vec<_> = peers
        .iter()
        .filter(|(_, p)| p.control && p.close_id.is_some() && p.remote_stream.is_none())
        .map(|(id, _)| *id)
        .collect();
    for id in ids {
        let peer = peers.get_mut(&id).unwrap();
        let stream = *next_stream;
        *next_stream = next_generation(*next_stream);
        remote_streams.insert(stream, id);
        peer.remote_stream = Some(stream);
        remote.push(Frame::new(
            b'K',
            stream,
            peer.close_id.as_deref().unwrap().as_bytes(),
        ));
    }
}

fn attention_required(error: &io::Error) -> bool {
    let text = error.to_string().to_ascii_lowercase();
    [
        "permission denied",
        "host key verification failed",
        "remote host identification has changed",
        "bad configuration option",
        "unknown option",
        "no matching host key type",
        "no matching key exchange method",
        "too many authentication failures",
        "invalid format",
        "load key",
        "unsupported ssh host",
        "runtime revision unavailable",
        "cannot stat",
        "not a directory",
    ]
    .iter()
    .any(|marker| text.contains(marker))
}

fn send_outer_open(remote: &mut Peer, id: u64, kind: u8, data: &[u8]) {
    remote.push(Frame::new(kind, id, data));
}

fn discard_queued_output(peer: &mut Peer) {
    peer.discard_queued_output();
}

fn reset_remote_streams(peers: &mut HashMap<u64, LocalPeer>, discard_output: bool) {
    for peer in peers.values_mut() {
        peer.remote_stream = None;
        peer.snapshot_generation = None;
        peer.snapshot_acked = false;
        peer.writer_requested = false;
        peer.writer_ready = false;
        if !peer.failed && !peer.ended && !peer.control {
            peer.retry_requested = false;
            if discard_output {
                discard_queued_output(&mut peer.peer);
            }
        }
    }
}

fn advance_peer_generations(peers: &mut HashMap<u64, LocalPeer>, generation_counter: &mut u64) {
    for peer in peers
        .values_mut()
        .filter(|p| !p.control && !p.ended && !p.failed)
    {
        *generation_counter = next_generation(*generation_counter);
        peer.generation = *generation_counter;
    }
}

/// Bind the stable local endpoint before starting any network or deployment
/// work. Local Ghostty surfaces therefore survive every SSH transport attempt.
pub fn supervise(local: &Path, connector: Connector, interactive_first: bool) -> io::Result<()> {
    host::private(
        local
            .parent()
            .ok_or_else(|| io::Error::other("missing socket parent"))?,
    )?;
    let listener = UnixListener::bind(local)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(local, std::fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    let nonce = crate::record::nonce()?;
    let initial_generation = u64::from_str_radix(&nonce[..16], 16)
        .map_err(io::Error::other)?
        .max(1);

    let mut peers: HashMap<u64, LocalPeer> = HashMap::new();
    let mut next_peer = 1u64;
    let mut next_stream = 1u64;
    let mut remote_streams: HashMap<u64, u64> = HashMap::new();
    let mut remote: Option<Peer> = None;
    let mut _transport_guard: Option<Box<dyn Send>> = None;
    let mut capabilities_received = false;
    let mut strict_open = false;
    let mut durable_close = false;
    let mut local_launch = false;
    let mut list_in_flight = false;
    let mut generation_counter = initial_generation;
    let mut state = State::Connecting;
    let mut attempt = 0u32;
    let mut retry_at = Instant::now();
    let mut stable_since: Option<Instant> = None;
    let mut last_heartbeat = Instant::now() - HEARTBEAT_INTERVAL;
    let mut last_pong = Instant::now();
    let mut had_transport = false;
    let mut interactive_next = interactive_first;
    let mut attempt_pending = false;
    let mut attempt_rx = None;
    let mut attempt_tx_id = 0u64;
    let mut idle_since = Instant::now();

    loop {
        if peers.values().any(|p| {
            !p.ended
                && (!p.control
                    || p.close_id.is_some() && !p.control_done
                    || p.list_requested && !p.control_done)
        }) {
            idle_since = Instant::now();
        } else if idle_since.elapsed() > PEER_IDLE_TIMEOUT {
            return Ok(());
        }

        if remote.is_some() {
            if let Some(since) = stable_since {
                if since.elapsed() >= STABLE_RESET {
                    attempt = 0;
                    stable_since = None;
                }
            }
        }

        if remote.is_some() && last_pong.elapsed() > HEARTBEAT_TIMEOUT {
            remote = None;
            _transport_guard = None;
            remote_streams.clear();
            reset_remote_streams(&mut peers, true);
            list_in_flight = false;
            advance_peer_generations(&mut peers, &mut generation_counter);
            stable_since = None;
            state = State::Reconnecting;
            let delay = retry_delay(attempt.max(1));
            set_status(&mut peers, state, attempt, Some(delay), None);
            retry_at = Instant::now() + delay;
            had_transport = true;
        }

        if !attempt_pending && remote.is_none() && Instant::now() >= retry_at {
            attempt += 1;
            attempt_tx_id = next_generation(attempt_tx_id);
            let attempt_id = attempt_tx_id;
            let connect = connector.clone();
            let interactive = interactive_next;
            interactive_next = false;
            let (tx, rx) = mpsc::channel();
            thread::spawn(move || {
                let _ = tx.send((attempt_id, connect(interactive)));
            });
            attempt_rx = Some(rx);
            attempt_pending = true;
            state = if had_transport {
                State::Reconnecting
            } else {
                State::Connecting
            };
            set_status(&mut peers, state, attempt, None, None);
        }

        if let Some(rx) = &attempt_rx {
            match rx.try_recv() {
                Ok((id, result)) if id == attempt_tx_id => {
                    attempt_pending = false;
                    attempt_rx = None;
                    match result {
                        Ok(transport) => {
                            let peer = Peer::new(transport.socket, 0)?;
                            _transport_guard = Some(transport.guard);
                            remote_streams.clear();
                            next_stream = 1;
                            remote = Some(peer);
                            last_pong = Instant::now();
                            capabilities_received = false;
                            strict_open = false;
                            durable_close = false;
                            local_launch = false;
                            list_in_flight = false;
                            remote.as_mut().unwrap().push(Frame::new(b'P', 0, &[]));
                            last_heartbeat = Instant::now();
                            stable_since = None;
                            had_transport = true;
                            state = State::Online;
                            for peer in peers.values_mut().filter(|p| !p.control && !p.ended) {
                                if peer.open.is_some() {
                                    peer.peer.push(status_frame(
                                        peer.generation,
                                        State::Connecting,
                                        attempt,
                                        None,
                                        None,
                                    ));
                                }
                            }
                        }
                        Err(error) => {
                            let attention = attention_required(&error);
                            state = if attention {
                                State::Attention
                            } else {
                                State::Reconnecting
                            };
                            let delay = retry_delay(attempt.max(1));
                            set_status(
                                &mut peers,
                                state,
                                attempt,
                                (!attention).then_some(delay),
                                attention.then_some(
                                    "SSH authentication or runtime setup needs attention.",
                                ),
                            );
                            if attention {
                                retry_at = Instant::now() + Duration::from_secs(365 * 24 * 3600);
                            } else {
                                retry_at = Instant::now() + delay;
                            }
                            eprintln!("session runtime connect failed: {error}");
                        }
                    }
                }
                Ok(_) => {}
                Err(mpsc::TryRecvError::Empty) => {}
                Err(mpsc::TryRecvError::Disconnected) => {
                    attempt_pending = false;
                    attempt_rx = None;
                    state = State::Attention;
                    set_status(
                        &mut peers,
                        state,
                        attempt,
                        None,
                        Some("The connection attempt could not be started."),
                    );
                    retry_at = Instant::now() + Duration::from_secs(365 * 24 * 3600);
                }
            }
        }

        for _ in 0..8 {
            match listener.accept() {
                Ok((socket, _)) if peers.len() < MAX_PEERS => {
                    generation_counter = next_generation(generation_counter);
                    let mut peer =
                        LocalPeer::new(Peer::new(socket, next_peer)?, generation_counter);
                    next_peer = next_generation(next_peer);
                    peer.peer
                        .push(status_frame(peer.generation, state, attempt, None, None));
                    peers.insert(peer.peer.id, peer);
                }
                Ok((_socket, _)) => {}
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) => return Err(error),
            }
        }

        let ids: Vec<_> = peers.keys().copied().collect();
        let mut manual_retry = None;
        for id in ids {
            let list_waiters = peers
                .values()
                .filter(|candidate| candidate.list_requested && !candidate.control_done)
                .count();
            let has_failed_stream = peers.values().any(|p| !p.control && p.failed && !p.ended);
            let has_observer = peers.values().any(|p| {
                !p.control
                    && !p.failed
                    && !p.ended
                    && p.snapshot_acked
                    && p.remote_stream.is_some()
                    && !p.writer_ready
            });
            let Some(peer) = peers.get_mut(&id) else {
                continue;
            };
            match peer.peer.read() {
                Ok(frames) => {
                    for frame in frames {
                        if peer.control {
                            continue;
                        }
                        if peer.open.is_none() {
                            if frame.kind == b'L' {
                                peer.control = true;
                                if frame.seq != 0 || !frame.data.is_empty() {
                                    peer.peer.push(Frame::new(b'E', 0, b"invalid list request"));
                                    peer.control_done = true;
                                } else if list_waiters >= MAX_LIST_WAITERS {
                                    peer.peer.push(Frame::new(
                                        b'E',
                                        0,
                                        b"too many pending catalogue requests",
                                    ));
                                    peer.control_done = true;
                                } else {
                                    peer.list_requested = true;
                                }
                                continue;
                            }
                            if frame.kind == b'y' {
                                peer.control = true;
                                let interactive = frame.data == b"interactive/1";
                                if frame.seq != 0 || (!frame.data.is_empty() && !interactive) {
                                    peer.peer.push(Frame::new(
                                        b'y',
                                        peer.generation,
                                        b"invalid request",
                                    ));
                                    peer.control_done = true;
                                } else if !attempt_pending
                                    && (state != State::Online || has_failed_stream || has_observer)
                                {
                                    manual_retry = Some(interactive);
                                    peer.peer
                                        .push(Frame::new(b'y', peer.generation, b"accepted"));
                                    peer.control_done = true;
                                } else {
                                    peer.peer.push(Frame::new(
                                        b'y',
                                        peer.generation,
                                        if attempt_pending {
                                            &b"connect attempt already running"[..]
                                        } else {
                                            &b"endpoint online"[..]
                                        },
                                    ));
                                    peer.control_done = true;
                                }
                                continue;
                            }
                            if frame.kind == CLOSE
                                && frame.data.len() == 36
                                && std::str::from_utf8(&frame.data).is_ok_and(host::valid_id)
                            {
                                peer.control = true;
                                peer.close_id =
                                    Some(String::from_utf8(frame.data).expect("validated UUID"));
                                if capabilities_received && !durable_close {
                                    peer.peer.push(Frame::new(
                                        b'E',
                                        0,
                                        b"remote runtime does not support confirmed close",
                                    ));
                                    peer.control_done = true;
                                }
                                continue;
                            }
                            if frame.kind != b'H' || frame.data.len() > MAX_FRAME {
                                peer.peer.push(Frame::new(b'E', 0, b"invalid open request"));
                                peer.failed = true;
                                continue;
                            }
                            match serde_json::from_slice::<OpenRequest>(&frame.data) {
                                Ok(request) if host::valid_id(&request.id) => {
                                    peer.initial_create = request.create;
                                    peer.open = Some(frame.data);
                                    if capabilities_received
                                        && request.launch.is_some()
                                        && !local_launch
                                    {
                                        peer.failed = true;
                                        peer.peer.push(Frame::new(
                                            b'E',
                                            0,
                                            b"runtime does not support persistent local launches; no session was created",
                                        ));
                                    } else if capabilities_received && !strict_open {
                                        peer.failed = true;
                                        peer.peer.push(Frame::new(
                                            b'E',
                                            0,
                                            b"remote runtime is too old for safe session attach; remote process was preserved",
                                        ));
                                    }
                                }
                                _ => {
                                    peer.peer.push(Frame::new(
                                        b'E',
                                        0,
                                        b"invalid session open request",
                                    ));
                                    peer.failed = true;
                                }
                            }
                            continue;
                        }

                        if peer.ended || peer.control_done {
                            continue;
                        }
                        if frame.kind == ACK {
                            if frame.data.len() != 8
                                || u64::from_be_bytes(frame.data[..8].try_into().unwrap())
                                    != peer.generation
                                || peer.snapshot_generation != Some(peer.generation)
                                || peer.remote_stream.is_none()
                                || state != State::Online
                            {
                                continue;
                            }
                            peer.snapshot_acked = true;
                        } else if matches!(frame.kind, INPUT | RESIZE | CLAIM | CLOSE) {
                            if frame.seq != peer.generation
                                || state != State::Online
                                || peer.remote_stream.is_none()
                                || !peer.writer_ready && frame.kind != CLAIM
                            {
                                continue;
                            }
                            if frame.kind == CLAIM {
                                if peer.snapshot_generation != Some(peer.generation)
                                    || !peer.snapshot_acked
                                {
                                    continue;
                                }
                                peer.writer_requested = true;
                                peer.writer_ready = false;
                            }
                        } else {
                            continue;
                        }
                        if let (Some(remote), Some(stream)) = (remote.as_mut(), peer.remote_stream)
                        {
                            remote.push(Frame::new(b'D', stream, &frame.encode()));
                        }
                    }
                }
                Err(_) => peer.peer.dead = true,
            }
        }

        if let Some(interactive) = manual_retry {
            let failed: Vec<_> = peers
                .iter_mut()
                .filter(|(_, p)| !p.control && !p.ended && p.failed)
                .map(|(id, p)| {
                    p.retry_requested = true;
                    p.writer_requested = false;
                    p.writer_ready = false;
                    *id
                })
                .collect();
            let observers: Vec<_> = peers
                .iter()
                .filter(|(_, p)| {
                    !p.control
                        && !p.ended
                        && !p.failed
                        && p.open.is_some()
                        && p.remote_stream.is_some()
                        && p.snapshot_acked
                        && !p.writer_ready
                        && !p.writer_requested
                })
                .map(|(id, _)| *id)
                .collect();
            for id in &failed {
                if let Some(peer) = peers.get_mut(id) {
                    generation_counter = next_generation(generation_counter);
                    peer.generation = generation_counter;
                    set_peer_status(peer, attempt);
                }
            }
            if let Some(remote) = remote.as_mut() {
                for id in &failed {
                    if let Some(peer) = peers.get_mut(id) {
                        if !strict_open {
                            peer.peer.push(Frame::new(
                                b'E',
                                0,
                                b"remote runtime is too old for safe session attach; remote process was preserved",
                            ));
                            continue;
                        }
                        match open_request(peer) {
                            Ok((kind, data)) => {
                                let stream = next_stream;
                                next_stream = next_generation(next_stream);
                                peer.remote_stream = Some(stream);
                                peer.snapshot_generation = None;
                                peer.snapshot_acked = false;
                                remote_streams.insert(stream, *id);
                                send_outer_open(remote, stream, kind, &data);
                            }
                            Err(error) => {
                                peer.peer
                                    .push(Frame::new(b'E', 0, error.to_string().as_bytes()));
                            }
                        }
                    }
                }
                for id in observers {
                    if let Some(peer) = peers.get_mut(&id) {
                        peer.writer_requested = true;
                        peer.writer_ready = false;
                        if let Some(stream) = peer.remote_stream {
                            remote.push(Frame::new(
                                b'D',
                                stream,
                                &Frame::new(CLAIM, peer.generation, &[]).encode(),
                            ));
                        }
                    }
                }
            } else if !attempt_pending {
                interactive_next = interactive;
                retry_at = Instant::now();
                state = State::Connecting;
                set_status(&mut peers, state, attempt, None, None);
            }
        }

        let remote_frames = if let Some(remote) = remote.as_mut() {
            if capabilities_received && strict_open {
                if let Err(error) =
                    begin_open(remote, &mut peers, &mut remote_streams, &mut next_stream)
                {
                    eprintln!("session runtime open failed: {error}");
                }
            }
            if capabilities_received && durable_close {
                begin_controls(remote, &mut peers, &mut remote_streams, &mut next_stream);
            }
            if last_heartbeat.elapsed() >= HEARTBEAT_INTERVAL {
                remote.push(Frame::new(b'P', 0, &[]));
                last_heartbeat = Instant::now();
            }
            if capabilities_received {
                begin_list(remote, &peers, &mut list_in_flight);
            }
            Some(remote.read())
        } else {
            None
        };
        if let Some(remote_frames) = remote_frames {
            match remote_frames {
                Ok(frames) => {
                    for frame in frames {
                        if frame.kind == b'P' && frame.seq == 0 {
                            let first_capabilities = !capabilities_received;
                            last_pong = Instant::now();
                            capabilities_received = true;
                            strict_open = has_capability(&frame.data, "strict-open/1");
                            durable_close = has_capability(&frame.data, "durable-close/1");
                            local_launch = has_capability(&frame.data, "local-launch/1");
                            if first_capabilities {
                                for peer in peers
                                    .values_mut()
                                    .filter(|p| !p.control && !p.ended && p.open.is_some())
                                {
                                    let requires_local_launch = peer
                                        .open
                                        .as_ref()
                                        .and_then(|bytes| {
                                            serde_json::from_slice::<OpenRequest>(bytes).ok()
                                        })
                                        .is_some_and(|request| request.launch.is_some());
                                    if requires_local_launch && !local_launch {
                                        peer.failed = true;
                                        peer.remote_stream = None;
                                        peer.peer.push(Frame::new(
                                            b'E',
                                            0,
                                            b"runtime does not support persistent local launches; no session was created",
                                        ));
                                    } else if !strict_open {
                                        peer.failed = true;
                                        peer.remote_stream = None;
                                        peer.peer.push(Frame::new(
                                            b'E',
                                            0,
                                            b"remote runtime is too old for safe session attach; remote process was preserved",
                                        ));
                                    }
                                }
                            }
                            if first_capabilities && !strict_open {
                                for peer in peers.values_mut().filter(|p| {
                                    p.control && !p.control_done && p.close_id.is_some()
                                }) {
                                    peer.peer.push(Frame::new(
                                        b'E',
                                        0,
                                        b"remote runtime does not support confirmed close",
                                    ));
                                    peer.control_done = true;
                                }
                            }
                            continue;
                        }
                        if frame.kind == b'L' && frame.seq == 0 {
                            list_in_flight = false;
                            if frame.data.len() > 8 * 1024 * 1024 {
                                for peer in peers
                                    .values_mut()
                                    .filter(|peer| peer.list_requested && !peer.control_done)
                                {
                                    peer.peer.push(Frame::new(
                                        b'E',
                                        0,
                                        b"session catalogue exceeds size limit",
                                    ));
                                    peer.control_done = true;
                                }
                            } else {
                                for peer in peers
                                    .values_mut()
                                    .filter(|peer| peer.list_requested && !peer.control_done)
                                {
                                    peer.peer.push(Frame::new(b'L', 0, &frame.data));
                                    peer.control_done = true;
                                }
                            }
                            continue;
                        }
                        if frame.kind == b'E' && frame.seq == 0 && list_in_flight {
                            list_in_flight = false;
                            for peer in peers
                                .values_mut()
                                .filter(|peer| peer.list_requested && !peer.control_done)
                            {
                                peer.peer.push(Frame::new(b'E', 0, &frame.data));
                                peer.control_done = true;
                            }
                            continue;
                        }
                        if frame.kind == b'E' {
                            if let Some(id) = remote_streams.remove(&frame.seq) {
                                if let Some(peer) = peers.get_mut(&id) {
                                    peer.remote_stream = None;
                                    if peer.control && peer.close_id.is_some() {
                                        peer.peer.push(Frame::new(b'E', 0, &frame.data));
                                        peer.control_done = true;
                                        continue;
                                    }
                                    peer.snapshot_generation = None;
                                    peer.writer_ready = false;
                                    peer.writer_requested = false;
                                    peer.retry_requested = false;
                                    peer.failed = true;
                                    peer.peer.push(Frame::new(b'E', 0, &frame.data));
                                }
                            }
                            continue;
                        }
                        if frame.kind == b'Q' {
                            if let Some(id) = remote_streams.remove(&frame.seq) {
                                if let Some(peer) = peers.get_mut(&id) {
                                    peer.remote_stream = None;
                                    if peer.control {
                                        peer.control_done = true;
                                        continue;
                                    }
                                    if !peer.ended && !peer.failed {
                                        peer.failed = true;
                                        peer.peer.push(Frame::new(
                                            b'E',
                                            0,
                                            b"remote session stream ended",
                                        ));
                                    }
                                }
                            }
                            continue;
                        }
                        if frame.kind != b'D' {
                            return Err(io::Error::other("invalid host response"));
                        }
                        let Some(id) = remote_streams.get(&frame.seq).copied() else {
                            continue;
                        };
                        let Some(peer) = peers.get_mut(&id) else {
                            continue;
                        };
                        let mut inner = inner_frame(&frame.data)?;
                        if peer.control && peer.close_id.is_some() {
                            remote_streams.remove(&frame.seq);
                            if inner.kind == CLOSE {
                                peer.peer.push(inner);
                                peer.control_done = true;
                                peer.remote_stream = None;
                            } else {
                                peer.peer
                                    .push(Frame::new(b'E', 0, b"invalid close confirmation"));
                                peer.control_done = true;
                            }
                            continue;
                        }
                        match inner.kind {
                            SNAPSHOT => {
                                peer.snapshot_generation = Some(peer.generation);
                                peer.snapshot_confirmed = true;
                                clear_launch_data(peer);
                                peer.failed = false;
                                peer.retry_requested = false;
                                peer.snapshot_acked = false;
                                peer.writer_requested = false;
                                peer.writer_ready = false;
                            }
                            CLAIM => {
                                if peer.writer_requested
                                    && peer.snapshot_generation == Some(peer.generation)
                                {
                                    peer.writer_ready = true;
                                    if stable_since.is_none() {
                                        stable_since = Some(Instant::now());
                                    }
                                }
                                inner.seq = peer.generation;
                            }
                            b'B' => {
                                peer.writer_requested = false;
                                peer.writer_ready = false;
                                inner.seq = peer.generation;
                            }
                            EXIT => {
                                peer.ended = true;
                                peer.writer_ready = false;
                            }
                            _ => {}
                        }
                        peer.peer.push(inner);
                    }
                }
                Err(_) => {
                    remote = None;
                    _transport_guard = None;
                    remote_streams.clear();
                    reset_remote_streams(&mut peers, true);
                    list_in_flight = false;
                    advance_peer_generations(&mut peers, &mut generation_counter);
                    stable_since = None;
                    capabilities_received = false;
                    strict_open = false;
                    durable_close = false;
                    state = State::Reconnecting;
                    let delay = retry_delay(attempt.max(1));
                    set_status(&mut peers, state, attempt, Some(delay), None);
                    retry_at = Instant::now() + delay;
                }
            }
        }

        for peer in peers.values_mut() {
            if peer.peer.flush().is_err() {
                peer.peer.dead = true;
            }
        }
        let remove: Vec<_> = peers
            .iter()
            .filter(|(_, peer)| {
                peer.peer.dead
                    || peer.control_done && peer.peer.queued == 0
                    || peer.ended && peer.peer.queued == 0
            })
            .map(|(id, peer)| (*id, peer.remote_stream))
            .collect();
        if let Some(remote) = remote.as_mut() {
            for (id, stream) in remove {
                if let Some(stream) = stream {
                    remote.push(Frame::new(b'Q', stream, &[]));
                    remote_streams.remove(&stream);
                } else {
                    let _ = id;
                }
            }
        }
        peers.retain(|_, p| {
            !(p.peer.dead || p.control_done && p.peer.queued == 0 || p.ended && p.peer.queued == 0)
        });

        let remote_dead = remote
            .as_mut()
            .is_some_and(|peer| peer.flush().is_err() || peer.dead);
        if remote_dead {
            remote = None;
            _transport_guard = None;
            remote_streams.clear();
            reset_remote_streams(&mut peers, true);
            list_in_flight = false;
            advance_peer_generations(&mut peers, &mut generation_counter);
            stable_since = None;
            capabilities_received = false;
            strict_open = false;
            durable_close = false;
            state = State::Reconnecting;
            let delay = retry_delay(attempt.max(1));
            set_status(&mut peers, state, attempt, Some(delay), None);
            retry_at = Instant::now() + delay;
        }

        thread::sleep(Duration::from_millis(2));
    }
}

/// One-shot local control request. It never opens a session or writes terminal
/// input; the supervisor decides which offline stream can be attached again.
pub fn retry_local(socket: &Path, interactive: bool) -> io::Result<()> {
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    Frame::new(b'y', 0, if interactive { b"interactive/1" } else { &[] }).send(&mut stream)?;
    let response = loop {
        let response = Frame::read(&mut stream)?;
        if response.kind != b'T' {
            break response;
        }
    };
    if response.kind == b'y' && response.data == b"accepted" {
        Ok(())
    } else {
        Err(io::Error::other(
            String::from_utf8_lossy(&response.data).into_owned(),
        ))
    }
}

/// Read the session catalogue through an existing relay without opening a pane.
pub fn list_local(socket: &Path) -> io::Result<Vec<SessionSummary>> {
    let deadline = Instant::now() + LIST_REQUEST_TIMEOUT;
    let mut last_error = None;
    for attempt in 0..3 {
        let mut stream = match UnixStream::connect(socket) {
            Ok(stream) => stream,
            Err(error) => {
                last_error = Some(error);
                if attempt < 2 {
                    thread::sleep(Duration::from_millis(100));
                    continue;
                }
                break;
            }
        };
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "session catalogue request timed out",
            ));
        }
        stream.set_read_timeout(Some(remaining))?;
        stream.set_write_timeout(Some(Duration::from_secs(2)))?;
        Frame::new(b'L', 0, &[]).send(&mut stream)?;
        loop {
            match Frame::read(&mut stream) {
                Ok(frame) if frame.kind == b'T' || frame.kind == b'P' && frame.seq == 0 => {}
                Ok(frame) if frame.kind == b'L' && frame.seq == 0 => {
                    if frame.data.len() > 8 * 1024 * 1024 {
                        return Err(io::Error::other("session catalogue exceeds size limit"));
                    }
                    let sessions: Vec<SessionSummary> = serde_json::from_slice(&frame.data)?;
                    if sessions.len() > 2048 {
                        return Err(io::Error::other("session catalogue exceeds entry limit"));
                    }
                    return Ok(sessions);
                }
                Ok(frame) if frame.kind == b'E' => {
                    let message = String::from_utf8_lossy(&frame.data);
                    return Err(io::Error::other(
                        message.chars().take(1024).collect::<String>(),
                    ));
                }
                Ok(_) => {
                    return Err(io::Error::other("invalid session catalogue response"));
                }
                Err(error)
                    if attempt < 2
                        && matches!(
                            error.kind(),
                            io::ErrorKind::UnexpectedEof
                                | io::ErrorKind::ConnectionReset
                                | io::ErrorKind::BrokenPipe
                                | io::ErrorKind::NotConnected
                        ) =>
                {
                    last_error = Some(error);
                    break;
                }
                Err(error) => return Err(error),
            }
        }
        if attempt < 2 {
            thread::sleep(Duration::from_millis(100));
        }
    }
    Err(last_error.unwrap_or_else(|| {
        io::Error::new(
            io::ErrorKind::TimedOut,
            "session catalogue request timed out",
        )
    }))
}
