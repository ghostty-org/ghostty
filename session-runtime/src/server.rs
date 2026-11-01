use crate::*;
use crate::{
    lifecycle::{unix_time, EndReason, Lifetime},
    record::{nonce, AgentEvent, Record},
    registry::LocalLaunchSpec,
};
use std::{
    collections::HashSet,
    ffi::{c_void, CStr},
    fs::{self, File},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            fs::{MetadataExt, PermissionsExt},
            net::{UnixDatagram, UnixListener},
            process::CommandExt,
        },
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};
static PTY_SPAWN: std::sync::Mutex<()> = std::sync::Mutex::new(());
extern "C" fn reply(context: *mut c_void, data: *const u8, len: usize) {
    let queue = unsafe { &mut *(context as *mut VecDeque<u8>) };
    if queue.len() + len <= 1024 * 1024 {
        queue.extend(unsafe { std::slice::from_raw_parts(data, len) });
    }
}
fn terminate_group(master: i32, leader: u32, signal: i32) {
    unsafe {
        let foreground = libc::tcgetpgrp(master);
        // Foreground jobs may be a different process group from the login shell.
        if foreground > 1
            && foreground != leader as i32
            && libc::getsid(foreground) == leader as i32
        {
            libc::kill(-foreground, signal);
        }
        if libc::getsid(leader as i32) == leader as i32 {
            libc::kill(-(leader as i32), signal);
        }
    }
}

fn foreground_session_group(master: i32, leader: u32) -> Option<u64> {
    let foreground = unsafe { libc::tcgetpgrp(master) };
    if foreground <= 1 || unsafe { libc::getsid(foreground) } != leader as i32 {
        return None;
    }
    Some(foreground as u64)
}

fn terminal_name(fd: i32) -> Option<String> {
    let mut buffer = [0 as libc::c_char; 4096];
    if unsafe { libc::ttyname_r(fd, buffer.as_mut_ptr(), buffer.len()) } != 0 {
        return None;
    }
    let value = unsafe { CStr::from_ptr(buffer.as_ptr()) }.to_str().ok()?;
    (value.starts_with("/dev/") && value.len() <= 4096).then(|| value.to_string())
}

fn password_input(master: i32) -> bool {
    let mut settings = unsafe { std::mem::zeroed::<libc::termios>() };
    if unsafe { libc::tcgetattr(master, &mut settings) } != 0 {
        return false;
    }
    settings.c_lflag & libc::ICANON != 0 && settings.c_lflag & libc::ECHO == 0
}

fn enable_utf8_input(master: i32) -> io::Result<()> {
    let mut settings = unsafe { std::mem::zeroed::<libc::termios>() };
    if unsafe { libc::tcgetattr(master, &mut settings) } != 0 {
        return Err(io::Error::last_os_error());
    }
    settings.c_iflag |= libc::IUTF8;
    if unsafe { libc::tcsetattr(master, libc::TCSANOW, &settings) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn runtime_millis(started: Instant) -> u64 {
    started.elapsed().as_millis().min(u64::MAX as u128) as u64
}

fn resize_dimensions(data: &[u8]) -> Option<(u16, u16, u16, u16)> {
    match data.len() {
        4 => {
            let cols = u16::from_be_bytes(data[..2].try_into().ok()?);
            let rows = u16::from_be_bytes(data[2..4].try_into().ok()?);
            Some((cols, rows, cols.saturating_mul(8), rows.saturating_mul(16)))
        }
        8 => Some((
            u16::from_be_bytes(data[..2].try_into().ok()?),
            u16::from_be_bytes(data[2..4].try_into().ok()?),
            u16::from_be_bytes(data[4..6].try_into().ok()?),
            u16::from_be_bytes(data[6..8].try_into().ok()?),
        )),
        _ => None,
    }
}

fn peer_wants_write(peer: &Peer) -> bool {
    peer.queued > 0
        && !(peer.ack.is_some()
            && peer
                .queue
                .front()
                .and_then(|frame| frame.first().copied())
                .is_some_and(|kind| matches!(kind, OUTPUT | RESIZE | EXIT | b'M')))
}

fn pty_poll_interests(eof: bool, input_pending: bool) -> libc::c_short {
    if eof {
        return 0;
    }
    libc::POLLIN | if input_pending { libc::POLLOUT } else { 0 }
}

fn queue_snapshot(peer: &mut Peer, seq: u64, snapshot: io::Result<Vec<u8>>) -> bool {
    match snapshot {
        Ok(bytes) if bytes.len() <= MAX_FRAME => {
            peer.push(Frame::new(SNAPSHOT, seq, &bytes));
            peer.ack = Some(seq);
            true
        }
        Ok(_) => {
            peer.push(Frame::new(
                b'E',
                seq,
                b"terminal snapshot exceeds the protocol size limit",
            ));
            false
        }
        Err(_) => {
            peer.push(Frame::new(b'E', seq, b"terminal snapshot is unavailable"));
            false
        }
    }
}

struct ChildGuard(Child);
impl std::ops::Deref for ChildGuard {
    type Target = Child;
    fn deref(&self) -> &Child {
        &self.0
    }
}
impl std::ops::DerefMut for ChildGuard {
    fn deref_mut(&mut self) -> &mut Child {
        &mut self.0
    }
}
impl Drop for ChildGuard {
    fn drop(&mut self) {
        if !matches!(self.0.try_wait(), Ok(Some(_))) {
            unsafe {
                libc::kill(-(self.0.id() as i32), libc::SIGKILL);
            }
            let _ = self.0.wait();
        }
    }
}
struct SocketGuard(std::path::PathBuf);
impl Drop for SocketGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
/// Prototype intentionally has one session, created explicitly at daemon startup.
/// Disconnect never touches the PTY; only Close or child exit ends the session.
pub fn serve(path: &Path, argv: &[String]) -> io::Result<()> {
    serve_managed(path, argv.to_vec(), None)
}

pub struct ManagedSession {
    pub path: PathBuf,
    pub record: Record,
    pub containment_root: Option<PathBuf>,
    pub initial_cwd: Option<PathBuf>,
    pub local_launch: Option<LocalLaunchSpec>,
}

pub fn serve_managed(
    path: &Path,
    argv: Vec<String>,
    mut managed: Option<ManagedSession>,
) -> io::Result<()> {
    let policy = managed
        .as_ref()
        .map(|m| m.record.policy.clone())
        .unwrap_or_default();
    policy.validate()?;
    let token = nonce()?;
    let event_path = path.with_extension("evt");
    if argv.is_empty() {
        return Err(io::Error::other("missing command"));
    }
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("socket needs private directory"))?;
    let meta = fs::symlink_metadata(parent)?;
    if !meta.is_dir() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
        return Err(io::Error::other(
            "socket directory must be owned by current user with mode 0700",
        ));
    }
    let events = UnixDatagram::bind(&event_path)?;
    let _event_guard = SocketGuard(event_path.clone());
    fs::set_permissions(&event_path, fs::Permissions::from_mode(0o600))?;
    events.set_nonblocking(true)?;
    let listener = UnixListener::bind(path)?;
    let _guard = SocketGuard(path.to_owned());
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    // openpty cannot atomically set CLOEXEC. Serialize every session spawn
    // across that small window so another shell cannot inherit these FDs.
    let spawn_guard = PTY_SPAWN
        .lock()
        .map_err(|_| io::Error::other("PTY spawn lock poisoned"))?;
    let mut master = -1;
    let mut slave = -1;
    let mut local_launch = managed.as_mut().and_then(|value| value.local_launch.take());
    let local_mode = local_launch.is_some();
    let scrollback_max_bytes = local_launch
        .as_ref()
        .and_then(|launch| launch.scrollback_max_bytes)
        .unwrap_or(DEFAULT_SCROLLBACK_MAX_BYTES);
    let scrollback_max_lines = local_launch
        .as_ref()
        .and_then(|launch| launch.scrollback_max_lines);
    let mut initial_input = local_launch
        .as_ref()
        .map(LocalLaunchSpec::initial_input)
        .transpose()?
        .unwrap_or_default();
    if let Some(launch) = &mut local_launch {
        launch.input_base64 = None;
    }
    let mut size = local_launch.as_ref().map_or(
        libc::winsize {
            ws_row: 24,
            ws_col: 80,
            ws_xpixel: 640,
            ws_ypixel: 384,
        },
        |launch| libc::winsize {
            ws_row: launch.rows,
            ws_col: launch.cols,
            ws_xpixel: launch.pixel_width,
            ws_ypixel: launch.pixel_height,
        },
    );
    if unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut size,
        )
    } < 0
    {
        return Err(io::Error::last_os_error());
    }
    let mut pty = unsafe { File::from_raw_fd(master) };
    let slave = unsafe { File::from_raw_fd(slave) };
    enable_utf8_input(pty.as_raw_fd())?;
    let tty_name = local_mode
        .then(|| terminal_name(slave.as_raw_fd()))
        .flatten();
    // Prevent one session's exec from retaining another session's PTY.
    if unsafe { libc::fcntl(master, libc::F_SETFD, libc::FD_CLOEXEC) } < 0
        || unsafe { libc::fcntl(slave.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } < 0
    {
        return Err(io::Error::last_os_error());
    }
    let group = managed
        .as_ref()
        .and_then(|m| {
            m.containment_root
                .as_ref()
                .map(|root| (root, &m.record.generation))
        })
        .map(|(root, generation)| crate::containment::Group::create(root, generation))
        .transpose()?;
    let membership = group.as_ref().map(|g| g.membership()).transpose()?;
    let membership_fd = membership.as_ref().map(|f| f.as_raw_fd());
    let mut command = Command::new(&argv[0]);
    if let Some(launch) = local_launch.as_ref() {
        command.env_clear().envs(launch.env.iter());
        if !launch.env.contains_key("TERM") {
            command.env("TERM", "xterm-256color");
        }
        if let Some(cwd) = launch.cwd.as_deref() {
            command.current_dir(cwd).env("PWD", cwd);
        }
    } else {
        command.env("TERM", "xterm-256color");
    }
    command
        .args(&argv[1..])
        .env("OMG_RUNTIME_EVENT_SOCKET", &event_path)
        .env("OMG_RUNTIME_EVENT_TOKEN", &token)
        .env(
            "OMG_RUNTIME_GENERATION",
            managed
                .as_ref()
                .map(|m| m.record.generation.as_str())
                .unwrap_or(&token),
        )
        .env("OMG_RUNTIME_BIN", std::env::current_exe()?)
        .stdin(Stdio::from(slave.try_clone()?))
        .stdout(Stdio::from(slave.try_clone()?))
        .stderr(Stdio::from(slave));
    if local_mode {
        command.env_remove("OMG_RUNTIME_REMOTE");
    } else {
        command.env("OMG_RUNTIME_REMOTE", "1");
    }
    if let Some(resume) = managed.as_ref().and_then(|m| m.record.resume.as_ref()) {
        command.current_dir(&resume.cwd).env("PWD", &resume.cwd);
    } else if let Some(cwd) = managed
        .as_ref()
        .and_then(|m| m.initial_cwd.as_ref())
        .filter(|_| !local_mode)
    {
        // Set cwd on this child command only; the host serves other sessions on
        // parallel threads. Treat paths as data, never a shell `cd` expression.
        command.current_dir(cwd).env("PWD", cwd);
    }
    unsafe {
        command.pre_exec(move || {
            // Join before exec/fork: "0" means this child. Only async-signal-safe
            // operations are allowed in the multithreaded host's fork child.
            if let Some(fd) = membership_fd {
                if libc::write(fd, b"0".as_ptr().cast(), 1) != 1 {
                    return Err(io::Error::last_os_error());
                }
            }
            // Background launchers/nohup may ignore SIGINT/SIGQUIT. A fresh
            // controlling terminal must not inherit that disposition or mask.
            for signal in [
                libc::SIGHUP,
                libc::SIGINT,
                libc::SIGQUIT,
                libc::SIGTERM,
                libc::SIGPIPE,
                libc::SIGCHLD,
                libc::SIGTSTP,
                libc::SIGTTIN,
                libc::SIGTTOU,
            ] {
                if libc::signal(signal, libc::SIG_DFL) == libc::SIG_ERR {
                    return Err(io::Error::last_os_error());
                }
            }
            let mut mask: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut mask);
            if libc::sigprocmask(libc::SIG_SETMASK, &mask, std::ptr::null_mut()) < 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::setsid() < 0 || libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = ChildGuard(command.spawn()?);
    let started_at = Instant::now();
    drop(command);
    drop(argv);
    drop(local_launch);
    drop(membership);
    if let Some(m) = &mut managed {
        m.record.pid = Some(child.id());
        m.record.ended = None;
        m.record.save(&m.path)?;
    }
    // Release the parent's slave handles so child exit produces EOF on the master.
    drop(spawn_guard);
    if unsafe { libc::fcntl(master, libc::F_SETFL, libc::O_NONBLOCK) } < 0 {
        let _ = child.kill();
        let _ = child.wait();
        return Err(io::Error::last_os_error());
    }
    let mut input = Box::new(VecDeque::from(std::mem::take(&mut initial_input)));
    let mut vt = Vt::with_reply_pixels_scrollback(
        size.ws_col,
        size.ws_row,
        size.ws_xpixel,
        size.ws_ypixel,
        ScrollbackLimits {
            max_bytes: scrollback_max_bytes,
            max_lines: scrollback_max_lines,
        },
        Some(reply),
        (&mut *input as *mut VecDeque<u8>).cast(),
    )?;
    let mut peers: Vec<Peer> = vec![];
    let mut close_after_flush = HashSet::new();
    let mut next_id = 1;
    let mut writer = None;
    let mut seq = 0u64;
    let id = managed
        .as_ref()
        .map(|m| m.record.id.clone())
        .unwrap_or_else(|| format!("{}-{}", std::process::id(), child.id()));
    let generation = managed
        .as_ref()
        .map(|m| m.record.generation.clone())
        .unwrap_or_else(|| token.clone());
    let mut lifetime = Lifetime::new(Instant::now());
    let mut end_reason = EndReason::ProcessExited;
    let mut agent_done = false;
    let mut completed_group = None;
    let mut recovery_checked_at = Instant::now() - Duration::from_secs(5);
    let mut recovery_available = false;
    let mut exited = None;
    let mut eof = false;
    let mut closing = None;
    let mut draining = None;
    let mut last_cwd = crate::location::session_cwd(master, child.id()).or_else(|| {
        managed
            .as_ref()
            .and_then(|session| session.record.cwd.clone())
    });
    let mut last_foreground = local_mode
        .then(|| foreground_session_group(master, child.id()))
        .flatten();
    let mut last_password_input = password_input(master);
    let mut cwd_checked = Instant::now();
    let mut password_checked = Instant::now();
    if let Some(session) = &mut managed {
        if session.record.cwd != last_cwd {
            session.record.cwd = last_cwd.clone();
            session.record.save(&session.path)?;
        }
    }
    loop {
        if closing.is_none()
            && managed
                .as_ref()
                .is_some_and(|m| m.path.with_extension("closed").exists())
        {
            end_reason = EndReason::ExplicitClose;
            terminate_group(master, child.id(), libc::SIGTERM);
            closing = Some(Instant::now());
        }
        if exited.is_none() && cwd_checked.elapsed() >= Duration::from_millis(500) {
            let cwd = crate::location::session_cwd(master, child.id());
            let foreground = local_mode
                .then(|| foreground_session_group(master, child.id()))
                .flatten();
            if cwd != last_cwd || foreground != last_foreground {
                last_cwd = cwd;
                last_foreground = foreground;
                if let Some(session) = &mut managed {
                    if session.record.cwd != last_cwd {
                        session.record.cwd = last_cwd.clone();
                        session.record.save(&session.path)?;
                    }
                }
                let metadata = serde_json::to_vec(&serde_json::json!({
                    "cwd": last_cwd,
                    "foreground_pid": foreground,
                    "tty_name": if local_mode { tty_name.as_deref() } else { None },
                    "password_input": last_password_input,
                    "runtime_ms": runtime_millis(started_at)
                }))?;
                for peer in &mut peers {
                    peer.push(Frame::new(b'M', seq, &metadata));
                }
            }
            cwd_checked = Instant::now();
        }
        if exited.is_none() && password_checked.elapsed() >= Duration::from_millis(200) {
            let password = password_input(master);
            if password != last_password_input {
                last_password_input = password;
                let metadata = serde_json::to_vec(&serde_json::json!({
                    "cwd": last_cwd,
                    "foreground_pid": if local_mode { last_foreground } else { None },
                    "tty_name": if local_mode { tty_name.as_deref() } else { None },
                    "password_input": last_password_input,
                    "runtime_ms": runtime_millis(started_at)
                }))?;
                for peer in &mut peers {
                    peer.push(Frame::new(b'M', seq, &metadata));
                }
            }
            password_checked = Instant::now();
        }
        // Hooks use an inherited per-session capability, never terminal text.
        let mut event_bytes = [0u8; 16384];
        for _ in 0..16 {
            match events.recv_from(&mut event_bytes) {
                Ok((n, source)) => {
                    if let Ok(event) = serde_json::from_slice::<AgentEvent>(&event_bytes[..n]) {
                        if event.token == token
                            && event.generation == generation
                            && event.resume.validate().is_ok()
                            && event.pid > 1
                            && event.group > 1
                            && unsafe { libc::getpgid(event.pid) } == event.group
                            && unsafe { libc::getsid(event.pid) } == child.id() as i32
                            && unsafe { libc::tcgetpgrp(master) } == event.group
                        {
                            if let Some(m) = &mut managed {
                                if matches!(
                                    event.state.as_str(),
                                    "working"
                                        | "idle"
                                        | "done"
                                        | "needsAttention"
                                        | "error"
                                        | "end"
                                ) {
                                    m.record.resume = Some(event.resume);
                                    // Persist first: a completion must never destroy its own recovery data.
                                    m.record.save(&m.path)?;
                                    agent_done = event.state == "done";
                                    completed_group = agent_done.then_some(event.group);
                                    recovery_checked_at = Instant::now() - Duration::from_secs(5);
                                    lifetime.activity(agent_done, Instant::now());
                                    if let Some(path) = source.as_pathname() {
                                        let _ = events.send_to(b"OK", path);
                                    }
                                }
                            }
                        }
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
        }
        // A bounded accept batch cannot starve PTY processing.
        for _ in 0..8 {
            match listener.accept() {
                Ok((socket, _)) => {
                    if peers.len() >= 16 {
                        continue;
                    }
                    let mut peer = Peer::new(socket, next_id)?;
                    next_id += 1;
                    let info = serde_json::json!({
                        "version": 2,
                        "session_id": id,
                        "pid": child.id(),
                        "attachment": peer.id,
                        "cols": size.ws_col,
                        "rows": size.ws_row,
                        "pixel_width": size.ws_xpixel,
                        "pixel_height": size.ws_ypixel,
                        "generation": generation,
                        "detached_ttl_seconds": policy.detached_ttl_seconds,
                        "experimental": true,
                        "foreground_pid": if local_mode { last_foreground } else { None },
                        "tty_name": if local_mode { tty_name.as_deref() } else { None },
                        "password_input": last_password_input,
                        "runtime_ms": runtime_millis(started_at)
                    });
                    peer.push(Frame::new(INFO, seq, info.to_string().as_bytes()));
                    if queue_snapshot(&mut peer, seq, vt.snapshot()) {
                        peer.push(Frame::new(
                            b'M',
                            seq,
                            &serde_json::to_vec(&serde_json::json!({
                                "cwd": last_cwd,
                                "foreground_pid": if local_mode { last_foreground } else { None },
                                "tty_name": if local_mode { tty_name.as_deref() } else { None },
                                "password_input": last_password_input,
                                "runtime_ms": runtime_millis(started_at)
                            }))?,
                        ));
                    } else {
                        close_after_flush.insert(peer.id);
                    }
                    if !close_after_flush.contains(&peer.id) {
                        if let Some(code) = exited {
                            peer.push(Frame::new(EXIT, seq, format!("{code}").as_bytes()));
                        }
                    }
                    peers.push(peer);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
        }
        let mut resizes = Vec::new();
        for peer in &mut peers {
            if close_after_flush.contains(&peer.id) {
                continue;
            }
            let frames = match peer.read() {
                Ok(f) => f,
                Err(_) => {
                    peer.dead = true;
                    continue;
                }
            };
            for f in frames {
                if f.kind == ACK && peer.ack == Some(f.seq) {
                    peer.ack = None;
                    continue;
                }
                if peer.ack.is_some() {
                    peer.dead = true;
                    break;
                }
                match f.kind {
                    CLAIM if writer.is_none() || writer == Some(peer.id) => {
                        writer = Some(peer.id);
                        peer.push(Frame::new(CLAIM, seq, &[]));
                    }
                    CLAIM => peer.push(Frame::new(b'B', seq, b"writer occupied")),
                    INPUT if writer == Some(peer.id) && exited.is_none() => {
                        agent_done = false;
                        completed_group = None;
                        lifetime.activity(false, Instant::now());
                        if input.len() + f.data.len() > 1024 * 1024 {
                            peer.dead = true;
                        } else {
                            input.extend(f.data);
                        }
                    }
                    RESIZE if writer == Some(peer.id) => {
                        let Some((cols, rows, pixel_width, pixel_height)) =
                            resize_dimensions(&f.data)
                        else {
                            peer.dead = true;
                            continue;
                        };
                        if cols == 0
                            || rows == 0
                            || cols > 500
                            || rows > 300
                            || pixel_width > 16_000
                            || pixel_height > 16_000
                        {
                            peer.dead = true;
                            continue;
                        }
                        size.ws_col = cols;
                        size.ws_row = rows;
                        size.ws_xpixel = pixel_width;
                        size.ws_ypixel = pixel_height;
                        vt.resize_pixels(cols, rows, pixel_width, pixel_height)?;
                        if unsafe { libc::ioctl(pty.as_raw_fd(), libc::TIOCSWINSZ, &size) } < 0 {
                            return Err(io::Error::last_os_error());
                        }
                        resizes.push(f.data);
                    }
                    CLOSE if writer == Some(peer.id) && closing.is_none() => {
                        end_reason = EndReason::ExplicitClose;
                        terminate_group(master, child.id(), libc::SIGTERM);
                        closing = Some(Instant::now());
                    }
                    _ => {
                        peer.dead = true;
                    }
                }
            }
        }
        for dimensions in resizes {
            for p in &mut peers {
                p.push(Frame::new(RESIZE, seq, &dimensions));
            }
        }
        if !input.is_empty() && !eof {
            let bytes = input.make_contiguous();
            let n = bytes.len().min(65536);
            match pty.write(&bytes[..n]) {
                Ok(n) => {
                    bytes[..n].fill(0);
                    input.drain(..n);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(_) => {
                    input.make_contiguous().fill(0);
                    input.clear();
                }
            }
        }
        // Never gate this read on the number or speed of attachments.
        if !eof {
            let mut bytes = [0; 65536];
            match pty.read(&mut bytes) {
                Ok(0) => eof = true,
                Ok(n) => {
                    vt.write(&bytes[..n]);
                    seq += n as u64;
                    for peer in &mut peers {
                        peer.push(Frame::new(OUTPUT, seq, &bytes[..n]));
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(e) if e.raw_os_error() == Some(libc::EIO) => eof = true,
                Err(e) => return Err(e),
            }
        }
        // Keep the session leader unreaped during termination escalation. A
        // zombie retains its PID/SID, so foreground jobs can still be validated
        // and killed even if they outlive the shell after SIGTERM.
        let may_reap = closing.is_none_or(|start: Instant| {
            start.elapsed() > Duration::from_secs(policy.terminate_grace_seconds)
        });
        if exited.is_none() && may_reap {
            if closing.is_some() {
                terminate_group(master, child.id(), libc::SIGKILL);
            }
            if let Some(status) = child.try_wait()? {
                exited = Some(status.code().unwrap_or(-1));
            }
        }
        if let Some(start) = closing {
            if start.elapsed() > Duration::from_secs(policy.terminate_grace_seconds)
                && !eof
                && exited.is_none()
            {
                terminate_group(master, child.id(), libc::SIGKILL);
                // Escaped descendants retaining a slave cannot keep our actor forever.
                if start.elapsed() > Duration::from_secs(policy.terminate_grace_seconds + 2) {
                    eof = true;
                }
            }
        }
        for peer in &mut peers {
            if peer.flush().is_err() {
                peer.dead = true;
            }
        }
        let mut removed_peers = Vec::new();
        for peer in &mut peers {
            if close_after_flush.contains(&peer.id) && peer.queued == 0 {
                peer.dead = true;
            }
            if peer.dead {
                removed_peers.push(peer.id);
            }
        }
        for id in removed_peers {
            close_after_flush.remove(&id);
        }
        peers.retain(|p| !p.dead);
        lifetime.attached(peers.len(), Instant::now());
        if closing.is_none() && exited.is_none() {
            // A completed Agent may have exited and yielded its PTY to a new
            // command. Its old completion must not terminate that new job.
            if agent_done && completed_group != Some(unsafe { libc::tcgetpgrp(master) }) {
                agent_done = false;
                completed_group = None;
                lifetime.activity(false, Instant::now());
            }
            if agent_done && recovery_checked_at.elapsed() >= Duration::from_secs(5) {
                recovery_available = managed
                    .as_ref()
                    .and_then(|m| m.record.resume.as_ref())
                    .is_some_and(|r| r.store_exists());
                recovery_checked_at = Instant::now();
            }
            let can_resume = agent_done && recovery_available;
            if let Some(reason) = lifetime.reason(&policy, Instant::now(), unix_time(), can_resume)
            {
                end_reason = reason;
                if let Some(m) = &mut managed {
                    m.record.ended = Some(reason);
                    m.record.save(&m.path)?;
                }
                terminate_group(master, child.id(), libc::SIGTERM);
                closing = Some(Instant::now());
            }
        }
        if exited.is_some() && closing.is_none() {
            closing = Some(Instant::now());
        }
        // Once the owned leader has been reaped, its numeric PID may be reused.
        // Finish draining instead of signaling any process by that stale ID.
        if exited.is_some() && closing.is_some_and(|start| start.elapsed() > Duration::from_secs(2))
        {
            eof = true;
        }
        if writer.is_some_and(|id| !peers.iter().any(|p| p.id == id)) {
            writer = None;
        }
        if let (Some(code), true) = (exited, eof) {
            if draining.is_none() {
                let metadata = serde_json::to_vec(&serde_json::json!({
                    "cwd": last_cwd,
                    "foreground_pid": None::<u64>,
                    "tty_name": if local_mode { tty_name.as_deref() } else { None },
                    "password_input": false,
                    "runtime_ms": runtime_millis(started_at)
                }))?;
                for peer in &mut peers {
                    peer.push(Frame::new(b'M', seq, &metadata));
                    peer.push(Frame::new(EXIT, seq, format!("{code}").as_bytes()));
                }
                draining = Some(Instant::now());
            }
            let start = draining.as_ref().unwrap();
            if peers.iter().all(|p| p.queued == 0) || start.elapsed() > Duration::from_secs(2) {
                let _ = child.wait();
                if let Some(group) = &group {
                    group.finish()?;
                }
                if let Some(m) = &mut managed {
                    m.record.pid = None;
                    m.record.ended = Some(end_reason);
                    m.record.save(&m.path)?;
                }
                return Ok(());
            }
        }
        let mut descriptors = Vec::with_capacity(peers.len() + 3);
        if !eof {
            descriptors.push(libc::pollfd {
                fd: master,
                events: pty_poll_interests(eof, !input.is_empty()),
                revents: 0,
            });
        }
        descriptors.push(libc::pollfd {
            fd: listener.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        });
        descriptors.push(libc::pollfd {
            fd: events.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        });
        for peer in &peers {
            let mut interests = libc::POLLIN;
            if peer_wants_write(peer) {
                interests |= libc::POLLOUT;
            }
            descriptors.push(libc::pollfd {
                fd: peer.socket.as_raw_fd(),
                events: interests,
                revents: 0,
            });
        }
        let result = unsafe {
            libc::poll(
                descriptors.as_mut_ptr(),
                descriptors.len() as libc::nfds_t,
                200,
            )
        };
        if result < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resize_accepts_legacy_and_pixel_aware_payloads() {
        assert_eq!(
            resize_dimensions(&[0, 100, 0, 40]),
            Some((100, 40, 800, 640))
        );
        assert_eq!(
            resize_dimensions(&[0, 100, 0, 40, 0x07, 0x80, 0x03, 0x20]),
            Some((100, 40, 1920, 800))
        );
        assert_eq!(resize_dimensions(&[0, 100, 0, 40, 1]), None);
    }

    #[test]
    fn pending_pty_input_wakes_on_write_readiness_without_masking_output() {
        assert_ne!(pty_poll_interests(false, true) & libc::POLLOUT, 0);
        assert_ne!(pty_poll_interests(false, true) & libc::POLLIN, 0);
        assert_eq!(pty_poll_interests(true, true), 0);
    }

    #[test]
    fn oversized_snapshot_queues_error_without_a_partial_snapshot() {
        let (socket, _remote) = UnixStream::pair().unwrap();
        let mut peer = Peer::new(socket, 1).unwrap();
        let snapshot = vec![0; MAX_FRAME + 1];

        assert!(!queue_snapshot(&mut peer, 7, Ok(snapshot)));
        assert_eq!(peer.queue.len(), 1);
        let error = Frame::read(&mut &peer.queue.front().unwrap()[..]).unwrap();
        assert_eq!(error.kind, b'E');
        assert_eq!(error.seq, 7);
        assert!(error.data.starts_with(b"terminal snapshot exceeds"));
    }

    #[test]
    fn password_input_requires_canonical_mode_without_echo() {
        let mut master = -1;
        let mut slave = -1;
        let mut size = unsafe { std::mem::zeroed::<libc::winsize>() };
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut size,
                )
            },
            0
        );
        let mut settings = unsafe { std::mem::zeroed::<libc::termios>() };
        assert_eq!(unsafe { libc::tcgetattr(slave, &mut settings) }, 0);
        settings.c_lflag |= libc::ICANON;
        settings.c_lflag &= !libc::ECHO;
        assert_eq!(
            unsafe { libc::tcsetattr(slave, libc::TCSANOW, &settings) },
            0
        );
        assert!(password_input(master));
        settings.c_lflag &= !libc::ICANON;
        assert_eq!(
            unsafe { libc::tcsetattr(slave, libc::TCSANOW, &settings) },
            0
        );
        assert!(!password_input(master));
        unsafe {
            libc::close(master);
            libc::close(slave);
        }
    }

    #[test]
    fn pty_enables_utf8_input_mode() {
        let mut master = -1;
        let mut slave = -1;
        let mut size = unsafe { std::mem::zeroed::<libc::winsize>() };
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut size,
                )
            },
            0
        );
        enable_utf8_input(master).unwrap();
        let mut settings = unsafe { std::mem::zeroed::<libc::termios>() };
        assert_eq!(unsafe { libc::tcgetattr(slave, &mut settings) }, 0);
        assert_ne!(settings.c_iflag & libc::IUTF8, 0);
        unsafe {
            libc::close(master);
            libc::close(slave);
        }
    }

    #[test]
    fn runtime_duration_uses_elapsed_milliseconds() {
        let started = Instant::now();
        std::thread::sleep(Duration::from_millis(25));
        let elapsed = runtime_millis(started);
        assert!((20..1000).contains(&elapsed));
    }
}
