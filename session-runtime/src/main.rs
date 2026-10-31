use std::{
    env,
    io::{self, Read, Write},
    net::Shutdown,
    os::unix::net::UnixStream,
    path::Path,
    process::{Child, Command, Stdio},
    sync::Arc,
};
fn copy(mut input: impl Read, mut output: impl Write) -> io::Result<()> {
    let mut buffer = [0; 65536];
    loop {
        let n = input.read(&mut buffer)?;
        if n == 0 {
            return Ok(());
        }
        output.write_all(&buffer[..n])?;
    }
}
fn bridge(path: &str) -> io::Result<()> {
    use std::os::fd::FromRawFd;
    let socket = UnixStream::connect(path)?;
    let input = socket.try_clone()?;
    std::thread::spawn(move || {
        let _ = copy(io::stdin().lock(), &input);
        let _ = input.shutdown(Shutdown::Write);
    });
    let fd = unsafe { libc::dup(libc::STDOUT_FILENO) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    copy(&socket, unsafe { std::fs::File::from_raw_fd(fd) })
}
struct TunnelGuard {
    child: Child,
    writer: Option<std::thread::JoinHandle<()>>,
    reader: Option<std::thread::JoinHandle<()>>,
    diagnostics: Option<std::thread::JoinHandle<()>>,
}
impl Drop for TunnelGuard {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
        if let Some(thread) = self.writer.take() {
            let _ = thread.join();
        }
        if let Some(thread) = self.reader.take() {
            let _ = thread.join();
        }
        if let Some(thread) = self.diagnostics.take() {
            let _ = thread.join();
        }
    }
}

fn tunnel(mut command: Command) -> io::Result<omg_session_runtime::client::RelayTransport> {
    tunnel_child(command.spawn()?)
}

fn tunnel_child(mut child: Child) -> io::Result<omg_session_runtime::client::RelayTransport> {
    let input = child
        .stdin
        .take()
        .ok_or_else(|| io::Error::other("SSH stdin unavailable"))?;
    let output = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("SSH stdout unavailable"))?;
    let diagnostics = child.stderr.take();
    let (socket, pipe) = UnixStream::pair()?;
    let upload = pipe.try_clone()?;
    let writer = std::thread::spawn(move || {
        let _ = copy(&upload, input);
        let _ = upload.shutdown(Shutdown::Both);
    });
    let reader = std::thread::spawn(move || {
        let _ = copy(output, &pipe);
        let _ = pipe.shutdown(Shutdown::Both);
    });
    let diagnostics = diagnostics.map(|input| {
        std::thread::spawn(move || {
            let _ = io::copy(&mut input.take(64 * 1024), &mut io::stderr());
        })
    });
    Ok(omg_session_runtime::client::RelayTransport {
        socket,
        guard: Box::new(TunnelGuard {
            child,
            writer: Some(writer),
            reader: Some(reader),
            diagnostics,
        }),
    })
}

fn batch_mode(config: &mut omg_session_runtime::deploy::Connection, interactive: bool) {
    let value = format!("BatchMode={}", if interactive { "no" } else { "yes" });
    let mut replaced = false;
    let mut index = 0;
    while index < config.arguments.len() {
        if config.arguments[index].starts_with("BatchMode=") {
            config.arguments[index] = value.clone();
            replaced = true;
        } else if config.arguments[index] == "-o"
            && config
                .arguments
                .get(index + 1)
                .is_some_and(|option| option.starts_with("BatchMode="))
        {
            config.arguments[index + 1] = value.clone();
            replaced = true;
            index += 1;
        }
        index += 1;
    }
    if !replaced {
        config.arguments.splice(0..0, ["-o".to_string(), value]);
    }
}

fn relay_connector(
    config: omg_session_runtime::deploy::Connection,
) -> omg_session_runtime::client::Connector {
    use omg_session_runtime::deploy::TransportKind;
    match config.transport {
        TransportKind::Ssh => Arc::new(move |interactive| {
            let mut attempt = config.clone();
            batch_mode(&mut attempt, interactive);
            match omg_session_runtime::deploy::fast_connect(&attempt, interactive) {
                Ok(child) => tunnel_child(child),
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    let (binary, state) =
                        omg_session_runtime::deploy::prepare(&attempt, interactive)?;
                    tunnel(omg_session_runtime::deploy::command(
                        &attempt,
                        &binary,
                        &state,
                        interactive,
                    )?)
                }
                Err(error) => Err(error),
            }
        }),
        TransportKind::Local => {
            let root = config.local_state_directory.clone();
            let shell = config.local_shell.clone();
            Arc::new(move |_| {
                let root = root
                    .as_ref()
                    .ok_or_else(|| io::Error::other("local runtime state directory is missing"))?;
                if !root.is_absolute() || root.as_os_str().to_string_lossy().contains('\0') {
                    return Err(io::Error::other("invalid local runtime state directory"));
                }
                let shell = shell
                    .clone()
                    .or_else(|| env::var("SHELL").ok())
                    .unwrap_or_else(|| "/bin/sh".into());
                ensure_host(&root.to_string_lossy(), Some(&shell))?;
                let path = root.join("host.sock");
                if path.as_os_str().as_encoded_bytes().len() >= 104 {
                    return Err(io::Error::other("local runtime socket path is too long"));
                }
                Ok(omg_session_runtime::client::RelayTransport {
                    socket: UnixStream::connect(path)?,
                    guard: Box::new(()),
                })
            })
        }
    }
}

fn ensure_host(directory: &str, shell_override: Option<&str>) -> io::Result<()> {
    use std::os::unix::{fs::PermissionsExt, process::CommandExt};
    let root = Path::new(directory);
    std::fs::create_dir_all(root)?;
    std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700))?;
    if let Some(shell) = shell_override {
        let metadata = std::fs::metadata(shell)?;
        if !Path::new(shell).is_absolute()
            || metadata.is_dir()
            || metadata.permissions().mode() & 0o111 == 0
        {
            return Err(io::Error::other(
                "local shell must be an executable absolute path",
            ));
        }
    }
    let socket = root.join("host.sock");
    if UnixStream::connect(&socket).is_ok() {
        return Ok(());
    }
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(root.join("host.log"))?;
    let shell = shell_override
        .map(str::to_string)
        .or_else(|| env::var("SHELL").ok())
        .unwrap_or_else(|| "/bin/sh".into());
    if omg_session_runtime::supervision::start(root, &shell)? {
        for _ in 0..100 {
            if UnixStream::connect(&socket).is_ok() {
                return Ok(());
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        return Err(io::Error::other("supervised host failed to become ready"));
    }
    eprintln!("runtime supervision unavailable; process-group cleanup only");
    let mut c = Command::new(env::current_exe()?);
    c.arg("host")
        .arg(root)
        .args(["--", &shell, "-l"])
        .stdin(Stdio::null())
        .stdout(Stdio::from(log.try_clone()?))
        .stderr(Stdio::from(log));
    unsafe {
        c.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            libc::signal(libc::SIGHUP, libc::SIG_IGN);
            Ok(())
        });
    }
    let mut child = c.spawn()?;
    for _ in 0..100 {
        if UnixStream::connect(&socket).is_ok() {
            return Ok(());
        }
        if child.try_wait()?.is_some() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    Err(io::Error::other("host daemon failed to start"))
}
fn report(agent: &str, state: &str, conversation: &str, cwd: &str) -> io::Result<()> {
    use omg_session_runtime::record::{AgentEvent, Resume};
    let path = env::var("OMG_RUNTIME_EVENT_SOCKET").map_err(io::Error::other)?;
    let event = AgentEvent {
        token: env::var("OMG_RUNTIME_EVENT_TOKEN").map_err(io::Error::other)?,
        generation: env::var("OMG_RUNTIME_GENERATION").map_err(io::Error::other)?,
        pid: unsafe { libc::getpid() },
        group: unsafe { libc::getpgrp() },
        state: state.into(),
        resume: Resume {
            agent: agent.into(),
            conversation_id: conversation.into(),
            cwd: cwd.into(),
        },
    };
    event.resume.validate()?;
    use std::os::unix::fs::PermissionsExt;
    let local = Path::new(&path)
        .parent()
        .unwrap()
        .join(format!("r-{}.sock", std::process::id()));
    let socket = std::os::unix::net::UnixDatagram::bind(&local)?;
    std::fs::set_permissions(&local, std::fs::Permissions::from_mode(0o600))?;
    let result = (|| {
        socket.set_read_timeout(Some(std::time::Duration::from_millis(750)))?;
        socket.connect(path)?;
        socket.send(&serde_json::to_vec(&event)?)?;
        let mut ack = [0; 2];
        socket.recv(&mut ack)?;
        if &ack != b"OK" {
            return Err(io::Error::other("hook rejected"));
        }
        Ok(())
    })();
    let _ = std::fs::remove_file(local);
    result
}
fn main() -> io::Result<()> {
    let a: Vec<String> = env::args().collect();
    match a.get(1).map(String::as_str) {
        Some("serve") if a.len() >= 5 && a[3] == "--" => {
            omg_session_runtime::server::serve(Path::new(&a[2]), &a[4..])
        }
        Some("host") if a.len() >= 5 && a[3] == "--" => {
            omg_session_runtime::host::serve(Path::new(&a[2]), a[4..].to_vec())
        }
        Some("bridge") if a.len() == 3 => bridge(&a[2]),
        Some("connect") if a.len() == 4 => {
            let config = omg_session_runtime::deploy::load(Path::new(&a[3]))?;
            let interactive_first = config.transport
                == omg_session_runtime::deploy::TransportKind::Ssh
                && config.arguments.iter().any(|arg| arg == "BatchMode=no");
            omg_session_runtime::client::supervise(
                Path::new(&a[2]),
                relay_connector(config),
                interactive_first,
            )
        }
        Some("retry-local") if a.len() >= 3 => {
            let interactive = a.iter().skip(2).any(|arg| arg == "--interactive");
            let socket = a
                .iter()
                .skip(2)
                .find(|arg| arg.as_str() != "--interactive")
                .ok_or_else(|| io::Error::other("missing local socket"))?;
            omg_session_runtime::client::retry_local(Path::new(socket), interactive)
        }
        Some("close-local") if a.len() == 4 => {
            let mut socket = UnixStream::connect(&a[2])?;
            socket.set_read_timeout(Some(std::time::Duration::from_secs(15)))?;
            socket.set_write_timeout(Some(std::time::Duration::from_secs(2)))?;
            omg_session_runtime::Frame::new(b'K', 0, a[3].as_bytes()).send(&mut socket)?;
            let response = loop {
                let response = omg_session_runtime::Frame::read(&mut socket)?;
                if response.kind != b'T' {
                    break response;
                }
            };
            if response.kind == b'K' && response.data == b"closed" {
                Ok(())
            } else {
                Err(io::Error::other("remote close pending or unavailable"))
            }
        }
        Some("ensure-host") if a.len() == 3 => ensure_host(&a[2], None),
        Some("report") if a.len() == 6 => report(&a[2], &a[3], &a[4], &a[5]),
        Some("handoff-check") if a.len() >= 3 => {
            if unsafe { libc::isatty(libc::STDIN_FILENO) } == 1
                && unsafe { libc::isatty(libc::STDOUT_FILENO) } == 1
                && omg_session_runtime::handoff::interactive(&a[2..])
            {
                Ok(())
            } else {
                std::process::exit(64)
            }
        }
        Some("handoff") if a.len() >= 4 => omg_session_runtime::handoff::request(&a[2], &a[3..]),
        Some("version") => {
            println!("omg-session-runtime/2 snapshot/1");
            Ok(())
        }
        _ => {
            eprintln!("usage: omgd host DIRECTORY -- SHELL... | serve SOCKET -- COMMAND... | bridge SOCKET | connect LOCAL_SOCKET CONNECTION_JSON | retry-local SOCKET [--interactive]");
            std::process::exit(2)
        }
    }
}
