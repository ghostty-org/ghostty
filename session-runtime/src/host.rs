//! One host daemon owns all session actors; transport connections multiplex
//! framed pane streams. Session workers are threads, never daemon subprocesses.
use crate::*;
use crate::{lifecycle::Policy, registry::Registry};
use std::{
    fs,
    os::unix::{
        fs::{MetadataExt, PermissionsExt},
        net::UnixListener,
    },
    path::Path,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
const MAX_STREAMS: usize = 64;
struct HostLock(fs::File);
impl HostLock {
    fn acquire(directory: &Path) -> io::Result<Self> {
        use std::os::{fd::AsRawFd, unix::fs::OpenOptionsExt};
        let file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(directory.join("host.lock"))?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::other("host daemon already running"));
        }
        Ok(Self(file))
    }
}
impl Drop for HostLock {
    fn drop(&mut self) {
        use std::os::fd::AsRawFd;
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}
pub(crate) fn inner_frame(data: &[u8]) -> io::Result<Frame> {
    let mut input = data;
    let frame = Frame::read(&mut input)?;
    if !input.is_empty() {
        return Err(io::Error::other("trailing inner frame bytes"));
    }
    Ok(frame)
}
pub(crate) fn private(path: &Path) -> io::Result<()> {
    let m = fs::symlink_metadata(path)?;
    if !m.is_dir() || m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o077 != 0 {
        return Err(io::Error::other(
            "directory must be private and owned by current user",
        ));
    }
    Ok(())
}
pub fn valid_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
/// Outer protocol: H(stream, UUID), D(stream, encoded inner frame), E(stream,error),
/// Q(stream) detach. Outer stream IDs are local to one transport connection.
pub fn serve(directory: &Path, command: Vec<String>) -> io::Result<()> {
    private(directory)?;
    let policy_path = directory.join("policy.json");
    let policy: Policy = if policy_path.exists() {
        serde_json::from_slice(&fs::read(&policy_path)?)?
    } else {
        Policy::default()
    };
    policy.validate()?;
    let _lock = HostLock::acquire(directory)?;
    let _ = fs::remove_file(directory.join("host.sock"));
    let root = directory.join("sessions");
    fs::create_dir_all(&root)?;
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;
    private(&root)?;
    let listener = UnixListener::bind(directory.join("host.sock"))?;
    fs::set_permissions(
        directory.join("host.sock"),
        fs::Permissions::from_mode(0o600),
    )?;
    listener.set_nonblocking(true)?;
    let mut initial = Registry::new(root, command, policy.clone());
    initial.set_containment_root(crate::containment::host_root()?);
    initial.maintenance();
    let registry = Arc::new(Mutex::new(initial));
    let active = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let mut idle_since = Instant::now();
    loop {
        {
            let mut state = registry.lock().unwrap();
            state.maintenance();
            if !state.is_empty() || active.load(std::sync::atomic::Ordering::SeqCst) > 0 {
                idle_since = Instant::now();
            } else if idle_since.elapsed() > Duration::from_secs(policy.host_idle_seconds) {
                let _ = fs::remove_file(directory.join("host.sock"));
                return Ok(());
            }
        }
        let socket = match listener.accept() {
            Ok((s, _)) => s,
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(20));
                continue;
            }
            Err(e) => return Err(e),
        };
        if active.fetch_add(1, std::sync::atomic::Ordering::SeqCst) >= 8 {
            active.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            continue;
        }
        let registry = registry.clone();
        let active = active.clone();
        std::thread::spawn(move || {
            let _ = host_connection(socket, registry);
            active.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
        });
    }
}
fn host_connection(socket: UnixStream, registry: Arc<Mutex<Registry>>) -> io::Result<()> {
    let mut transport = Peer::new(socket, 0)?;
    let mut streams: std::collections::HashMap<u64, Peer> = Default::default();
    let mut last_heartbeat = Instant::now();
    loop {
        if last_heartbeat.elapsed() > Duration::from_secs(45) {
            return Err(io::Error::other("host connection lease expired"));
        }
        for f in transport.read()? {
            match f.kind {
                b'P' if f.seq == 0 => {
                    last_heartbeat = Instant::now();
                    transport.push(Frame::new(b'P', 0, b"durable-close/1,strict-open/1"));
                }
                b'K' if f.seq != 0 => {
                    let result = std::str::from_utf8(&f.data)
                        .map_err(io::Error::other)
                        .and_then(|id| registry.lock().unwrap().close(id));
                    match result {
                        Ok(done) => transport.push(Frame::new(
                            b'D',
                            f.seq,
                            &Frame::new(b'K', 0, if done { b"closed" } else { b"pending" })
                                .encode(),
                        )),
                        Err(e) => transport.push(Frame::new(b'E', f.seq, e.to_string().as_bytes())),
                    }
                }
                b'L' if f.seq == 0 => {
                    let list = registry.lock().unwrap().list()?;
                    transport.push(Frame::new(b'L', 0, &serde_json::to_vec(&list)?));
                }
                b'U' if f.seq != 0
                    && !streams.contains_key(&f.seq)
                    && streams.len() < MAX_STREAMS =>
                {
                    #[derive(serde::Deserialize)]
                    struct Request {
                        id: String,
                        generation: String,
                    }
                    let req: Request = serde_json::from_slice(&f.data)?;
                    match registry
                        .lock()
                        .unwrap()
                        .connect(&req.id, Some(&req.generation))
                    {
                        Ok(s) => {
                            streams.insert(f.seq, Peer::new(s, f.seq)?);
                        }
                        Err(e) => transport.push(Frame::new(b'E', f.seq, e.to_string().as_bytes())),
                    }
                }
                b'C' if f.seq != 0
                    && !streams.contains_key(&f.seq)
                    && streams.len() < MAX_STREAMS =>
                {
                    let request: crate::registry::OpenRequest = serde_json::from_slice(&f.data)?;
                    let result = registry.lock().unwrap().open(&request);
                    match result {
                        Ok(s) => {
                            streams.insert(f.seq, Peer::new(s, f.seq)?);
                        }
                        Err(e) => transport.push(Frame::new(b'E', f.seq, e.to_string().as_bytes())),
                    }
                }
                b'H' if f.seq != 0
                    && !streams.contains_key(&f.seq)
                    && streams.len() < MAX_STREAMS =>
                {
                    let result = std::str::from_utf8(&f.data)
                        .map_err(io::Error::other)
                        .and_then(|id| {
                            let mut state = registry.lock().unwrap();
                            if let Some(root) = state.root.parent() {
                                if let Ok(bytes) = fs::read(root.join("policy.json")) {
                                    if let Ok(policy) = serde_json::from_slice::<Policy>(&bytes) {
                                        if policy.validate().is_ok() {
                                            state.policy = policy;
                                        }
                                    }
                                }
                            }
                            state.connect(id, None)
                        });
                    match result {
                        Ok(s) => {
                            streams.insert(f.seq, Peer::new(s, f.seq)?);
                        }
                        Err(e) => transport.push(Frame::new(b'E', f.seq, e.to_string().as_bytes())),
                    }
                }
                b'D' => {
                    if let Some(p) = streams.get_mut(&f.seq) {
                        let inner = inner_frame(&f.data)?;
                        p.push(inner);
                    }
                }
                b'Q' => {
                    streams.remove(&f.seq);
                }
                _ => return Err(io::Error::other("invalid multiplex frame")),
            }
        }
        for (&id, p) in &mut streams {
            match p.read() {
                Ok(frames) => {
                    for f in frames {
                        transport.push(Frame::new(b'D', id, &f.encode()));
                    }
                }
                Err(_) => p.dead = true,
            }
            if p.flush().is_err() {
                p.dead = true;
            }
            if p.dead {
                transport.push(Frame::new(b'Q', id, &[]));
            }
        }
        streams.retain(|_, p| !p.dead);
        transport.flush()?;
        if transport.dead {
            return Err(io::Error::other("transport backlog exceeded"));
        }
        std::thread::sleep(Duration::from_millis(2));
    }
}
