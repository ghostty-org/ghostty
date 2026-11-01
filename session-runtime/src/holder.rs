//! Local-only PTY holder processes. The broker can restart without owning the
//! PTY master or terminal parser; launch data arrives over a private pipe.
use crate::{
    host,
    record::Record,
    registry::LocalLaunchSpec,
    server::{self, ManagedSession},
    Frame,
};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{self, Read, Write},
    os::fd::AsRawFd,
    os::unix::net::{UnixListener, UnixStream},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::Duration,
};

const MAX_HOLDER_REQUEST: usize = 16 * 1024 * 1024;
const MAX_CONTROL_FRAME: usize = 8 * 1024;

fn read_control_frame(stream: &mut UnixStream) -> io::Result<Frame> {
    let mut header = [0u8; 13];
    stream.read_exact(&mut header)?;
    let len = u32::from_be_bytes(header[9..13].try_into().unwrap()) as usize;
    if len > MAX_CONTROL_FRAME {
        return Err(io::Error::other("local holder control frame exceeds limit"));
    }
    let mut data = vec![0; len];
    stream.read_exact(&mut data)?;
    Ok(Frame {
        kind: header[0],
        seq: u64::from_be_bytes(header[1..9].try_into().unwrap()),
        data,
    })
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HolderRequest {
    pub session_socket: PathBuf,
    pub record_path: PathBuf,
    pub record: Record,
    pub launch: LocalLaunchSpec,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct HolderProbe {
    id: String,
    generation: String,
    capability: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct HolderStatus {
    id: String,
    generation: String,
    capability: String,
    holder_pid: u32,
    session_pid: Option<u32>,
}

struct ControlSocketGuard(PathBuf);

impl Drop for ControlSocketGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

pub fn control_path(session_socket: &Path) -> PathBuf {
    session_socket.with_extension("ctl")
}

pub fn listener_is_gone(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
    )
}

pub fn spawn(executable: &Path, request: &HolderRequest, diagnostics: Stdio) -> io::Result<Child> {
    let mut data = serde_json::to_vec(request)?;
    if data.len() > MAX_HOLDER_REQUEST {
        return Err(io::Error::other(
            "local holder launch request exceeds limit",
        ));
    }
    use std::os::unix::process::CommandExt;
    let mut command = Command::new(executable);
    command
        .arg("session-holder")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(diagnostics);
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 || libc::signal(libc::SIGHUP, libc::SIG_IGN) == libc::SIG_ERR {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command.spawn()?;
    let write_result = (|| {
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| io::Error::other("holder launch pipe unavailable"))?;
        stdin.write_all(&data)?;
        data.fill(0);
        Ok(())
    })();
    data.fill(0);
    if let Err(error) = write_result {
        let _ = child.kill();
        let _ = child.wait();
        return Err(error);
    }
    Ok(child)
}

pub fn run_from_stdin() -> io::Result<()> {
    let mut data = Vec::new();
    io::stdin()
        .take((MAX_HOLDER_REQUEST + 1) as u64)
        .read_to_end(&mut data)?;
    if data.len() > MAX_HOLDER_REQUEST {
        return Err(io::Error::other(
            "local holder launch request exceeds limit",
        ));
    }
    let request: HolderRequest = serde_json::from_slice(&data)?;
    data.fill(0);
    request.launch.validate()?;
    if !host::valid_id(&request.record.id)
        || request.record.id.is_empty()
        || request.record.generation.is_empty()
        || request
            .record
            .holder_capability
            .as_deref()
            .is_none_or(|token| {
                token.len() != 32 || !token.bytes().all(|byte| byte.is_ascii_hexdigit())
            })
        || !request.session_socket.is_absolute()
        || !request.record_path.is_absolute()
    {
        return Err(io::Error::other("invalid local holder identity"));
    }
    use sha2::{Digest, Sha256};
    let key = format!("{:x}", Sha256::digest(request.record.id.as_bytes()));
    let expected_socket = request
        .record_path
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| io::Error::other("invalid local holder record path"))?
        .join(format!("{}.sock", &key[..16]));
    let expected_record = format!("{}.json", request.record.id);
    if request.session_socket != expected_socket
        || request.record_path.file_name() != Some(std::ffi::OsStr::new(&expected_record))
    {
        return Err(io::Error::other(
            "local holder paths do not match its identity",
        ));
    }
    let directory = request
        .session_socket
        .parent()
        .ok_or_else(|| io::Error::other("holder session socket has no parent"))?;
    let record_directory = request
        .record_path
        .parent()
        .ok_or_else(|| io::Error::other("holder record has no parent"))?;
    if record_directory.file_name() != Some(std::ffi::OsStr::new("sessions"))
        || record_directory.parent() != Some(directory)
    {
        return Err(io::Error::other(
            "local holder paths do not share a state directory",
        ));
    }
    host::private(directory)?;
    host::private(record_directory)?;
    let persisted = Record::load(&request.record_path)?;
    if persisted.id != request.record.id
        || persisted.generation != request.record.generation
        || persisted.holder_capability != request.record.holder_capability
        || persisted.ended.is_some()
    {
        return Err(io::Error::other(
            "local holder record changed before launch",
        ));
    }

    let control = control_path(&request.session_socket);
    let listener = UnixListener::bind(&control)?;
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&control, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    let _control_guard = ControlSocketGuard(control);
    let confirmed = Record::load(&request.record_path)?;
    if confirmed.id != request.record.id
        || confirmed.generation != request.record.generation
        || confirmed.holder_capability != request.record.holder_capability
        || confirmed.ended.is_some()
    {
        return Err(io::Error::other(
            "local holder record changed before session startup",
        ));
    }

    let record_path = request.record_path;
    let session_socket = request.session_socket;
    let id = request.record.id.clone();
    let generation = request.record.generation.clone();
    let capability = request.record.holder_capability.clone().unwrap();
    let initial_cwd = request.launch.cwd.as_deref().map(PathBuf::from);
    let argv = request.launch.argv.clone();
    let managed = ManagedSession {
        path: record_path.clone(),
        record: request.record,
        containment_root: None,
        initial_cwd,
        local_launch: Some(request.launch),
    };
    let actor = std::thread::Builder::new()
        .name(format!("holder-session-{id}"))
        .spawn(move || server::serve_managed(&session_socket, argv, Some(managed)))?;

    loop {
        if actor.is_finished() {
            let result = actor
                .join()
                .map_err(|_| io::Error::other("local session holder actor panicked"))?;
            if result.is_err() {
                if let Ok(mut record) = Record::load(&record_path) {
                    record.pid = None;
                    record.ended = Some(crate::lifecycle::EndReason::Lost);
                    let _ = record.save(&record_path);
                }
            }
            return result;
        }
        match listener.accept() {
            Ok((mut socket, _)) => {
                // Darwin can inherit O_NONBLOCK from the listening socket.
                // The bounded control handshake uses blocking read_exact;
                // otherwise a probe arriving just after accept is closed early.
                if socket.set_nonblocking(false).is_err() {
                    continue;
                }
                let _ = socket.set_read_timeout(Some(Duration::from_secs(1)));
                let _ = socket.set_write_timeout(Some(Duration::from_secs(1)));
                if let Ok(frame) = read_control_frame(&mut socket) {
                    if frame.kind == b'V' && frame.seq == 0 && frame.data.len() <= MAX_CONTROL_FRAME
                    {
                        if let Ok(probe) = serde_json::from_slice::<HolderProbe>(&frame.data) {
                            if probe.id == id
                                && probe.generation == generation
                                && capability == probe.capability
                            {
                                if let Ok(current) = Record::load(&record_path) {
                                    if current.id == probe.id
                                        && current.generation == probe.generation
                                        && current.holder_capability.as_deref()
                                            == Some(capability.as_str())
                                        && current.ended.is_none()
                                    {
                                        let status = HolderStatus {
                                            id: current.id,
                                            generation: current.generation,
                                            capability: probe.capability,
                                            holder_pid: std::process::id(),
                                            session_pid: current.pid,
                                        };
                                        let _ = Frame::new(b'V', 0, &serde_json::to_vec(&status)?)
                                            .send(&mut socket);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                let mut descriptor = libc::pollfd {
                    fd: listener.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                let result = unsafe { libc::poll(&mut descriptor, 1, 200) };
                if result < 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() != io::ErrorKind::Interrupted {
                        return Err(error);
                    }
                }
            }
            Err(error) => return Err(error),
        }
    }
}

pub fn probe(
    session_socket: &Path,
    id: &str,
    generation: &str,
    capability: &str,
) -> io::Result<HolderStatusView> {
    probe_with_timeout(
        session_socket,
        id,
        generation,
        capability,
        Duration::from_secs(1),
    )
}

pub fn probe_with_timeout(
    session_socket: &Path,
    id: &str,
    generation: &str,
    capability: &str,
    timeout: Duration,
) -> io::Result<HolderStatusView> {
    let mut socket = UnixStream::connect(control_path(session_socket))?;
    socket.set_read_timeout(Some(timeout))?;
    socket.set_write_timeout(Some(timeout))?;
    let request = HolderProbe {
        id: id.to_string(),
        generation: generation.to_string(),
        capability: capability.to_string(),
    };
    Frame::new(b'V', 0, &serde_json::to_vec(&request)?).send(&mut socket)?;
    let response = read_control_frame(&mut socket)?;
    if response.kind != b'V' || response.seq != 0 || response.data.len() > MAX_CONTROL_FRAME {
        return Err(io::Error::other("invalid local holder response"));
    }
    let status: HolderStatus = serde_json::from_slice(&response.data)?;
    if status.id != id
        || status.generation != generation
        || status.capability != capability
        || status.holder_pid == 0
    {
        return Err(io::Error::other("local holder identity mismatch"));
    }
    Ok(HolderStatusView {
        holder_pid: status.holder_pid,
        session_pid: status.session_pid,
    })
}

pub struct HolderStatusView {
    pub holder_pid: u32,
    pub session_pid: Option<u32>,
}
