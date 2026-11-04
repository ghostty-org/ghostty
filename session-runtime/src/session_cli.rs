//! User-facing management uses the existing host catalogue/close protocol.
//! It never opens a PTY or deploys a remote runtime.
use omg_session_runtime::{client::RelayTransport, deploy, record::SessionSummary, Frame};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    env, fs, io,
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};

const HELP: &str = "\
Usage: omg +sessions [list | close --all --yes] [options]

  list                 Show all saved local and SSH session endpoints
  close --all --yes    End the running sessions found by a fresh inventory
  --local              Include only this Mac
  --host DESTINATION   Include one saved SSH destination
  --json               Print structured sessions, endpoint errors and close count
  --app-support PATH   Override this app channel's Application Support directory

Examples:
  omg +sessions list
  omg +sessions list --local --json
  omg +sessions close --all --yes

Release and Dev are isolated. Close requires --yes, aborts before any close if
inventory is incomplete, and does not delete saved layouts or kill omgd by PID.
";

#[derive(Deserialize)]
struct Archive {
    version: u32,
    endpoints: Vec<Endpoint>,
}
#[derive(Deserialize)]
struct Endpoint {
    descriptor: Descriptor,
}
#[derive(Deserialize)]
struct Descriptor {
    connection: Option<Ssh>,
    revision: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Ssh {
    destination: String,
    options: Vec<String>,
    #[serde(rename = "workspaceID")]
    workspace_id: String,
    executable_path: String,
    local_working_directory: String,
}
#[derive(Serialize)]
pub struct Entry {
    endpoint_id: String,
    host: String,
    revision: String,
    #[serde(flatten)]
    session: SessionSummary,
}
#[derive(Serialize)]
struct Failure {
    host: String,
    message: String,
}
#[derive(Default, Serialize)]
struct Inventory {
    sessions: Vec<Entry>,
    errors: Vec<Failure>,
    closed: usize,
}

fn digest(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}
fn valid_revision(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
}
fn default_support() -> io::Result<PathBuf> {
    let executable = env::current_exe()?;
    let contents = executable
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .ok_or_else(|| io::Error::other("Use --app-support outside an OMG app bundle"))?;
    let output = Command::new("/usr/bin/plutil")
        .args(["-extract", "CFBundleIdentifier", "raw"])
        .arg(contents.join("Info.plist"))
        .output()?;
    let name = match String::from_utf8_lossy(&output.stdout).trim() {
        "com.jischeng.omg" => "OMG",
        "com.jischeng.omg.debug" => "OMG Dev",
        "com.jischeng.omg.debug.pty" => "OMG Dev PTY",
        "com.jischeng.omg.debug.workspace" => "OMG Dev Workspace",
        _ => {
            return Err(io::Error::other(
                "Unknown app channel; supply --app-support",
            ))
        }
    };
    Ok(home()?.join("Library/Application Support").join(name))
}
fn home() -> io::Result<PathBuf> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .ok_or_else(|| io::Error::other("HOME must be an absolute directory"))
}
impl Descriptor {
    fn name(&self) -> String {
        self.connection
            .as_ref()
            .map(|s| s.destination.clone())
            .unwrap_or_else(|| "This Mac".into())
    }
    fn identity(&self, support: &Path) -> String {
        let endpoint = if let Some(ssh) = &self.connection {
            let mut fields = vec![
                ssh.destination.as_str(),
                ssh.workspace_id.as_str(),
                ssh.executable_path.as_str(),
                ssh.local_working_directory.as_str(),
            ];
            fields.extend(ssh.options.iter().map(String::as_str));
            fields.join("\0")
        } else {
            format!("local:{}", support.display())
        };
        digest(&format!("{endpoint}\0{}", self.revision))
    }
    fn connect(&self, support: &Path) -> io::Result<Option<RelayTransport>> {
        if !valid_revision(&self.revision) {
            return Err(io::Error::other("Invalid runtime revision"));
        }
        if let Some(ssh) = &self.connection {
            if ssh.destination.is_empty()
                || ssh.destination.starts_with('-')
                || ssh
                    .destination
                    .chars()
                    .any(|c| c.is_whitespace() || c == '\0')
                || !Path::new(&ssh.executable_path).is_absolute()
                || !Path::new(&ssh.local_working_directory).is_absolute()
            {
                return Err(io::Error::other("Invalid saved SSH endpoint"));
            }
            let mut arguments = [
                "-T",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=10",
                "-o",
                "ServerAliveInterval=5",
                "-o",
                "ServerAliveCountMax=2",
                "-o",
                "ClearAllForwardings=yes",
                "-o",
                "PermitLocalCommand=no",
                "-o",
                "SessionType=default",
                "-o",
                "RemoteCommand=none",
                "-o",
                "RequestTTY=no",
                "-o",
                "StdinNull=no",
                "-o",
                "ControlMaster=no",
                "-o",
                "ControlPersist=no",
            ]
            .map(str::to_owned)
            .to_vec();
            arguments.extend(ssh.options.clone());
            arguments.extend(["--".into(), ssh.destination.clone()]);
            let connection = deploy::Connection {
                auto_install: false,
                transport: deploy::TransportKind::Ssh,
                executable: ssh.executable_path.clone(),
                arguments,
                cwd: ssh.local_working_directory.clone(),
                bundle: PathBuf::new(),
                policy: Default::default(),
                revision: Some(self.revision.clone()),
                local_state_directory: None,
                local_shell: None,
                hooks: None,
                tty_authentication: false,
            };
            return super::tunnel_child(deploy::fast_connect(&connection, false)?).map(Some);
        }
        let key = digest(&format!("{}\0{}", support.display(), self.revision));
        let root = home()?.join(".omg/run").join(&key[..20]);
        if !root.exists() {
            return Ok(None);
        }
        {
            use std::os::unix::fs::MetadataExt;
            let metadata = fs::symlink_metadata(&root)?;
            if !metadata.is_dir()
                || metadata.uid() != unsafe { libc::geteuid() }
                || metadata.mode() & 0o077 != 0
            {
                return Err(io::Error::other(
                    "Runtime directory must be private and owned by the current user",
                ));
            }
        }
        let socket = root.join("host.sock");
        if UnixStream::connect(&socket).is_err() {
            // Re-adopt existing holders with their pinned broker, never create
            // a session or upgrade a live daemon as part of listing.
            let binary = support
                .join("session-runtime/versions")
                .join(&self.revision)
                .join("omgd");
            super::ensure_host_with(&root.to_string_lossy(), Some("/bin/sh"), &binary, true)?;
        }
        Ok(Some(RelayTransport {
            socket: UnixStream::connect(socket)?,
            guard: Box::new(()),
        }))
    }
}
fn request(transport: &mut RelayTransport, frame: Frame) -> io::Result<Frame> {
    transport
        .socket
        .set_read_timeout(Some(Duration::from_secs(15)))?;
    transport
        .socket
        .set_write_timeout(Some(Duration::from_secs(3)))?;
    Frame::new(b'P', 0, &[]).send(&mut transport.socket)?;
    frame.send(&mut transport.socket)?;
    loop {
        let response = Frame::read(&mut transport.socket)?;
        if response.kind == b'P' {
            continue;
        }
        if response.kind == b'E' {
            return Err(io::Error::other(
                String::from_utf8_lossy(&response.data)
                    .chars()
                    .take(1024)
                    .collect::<String>(),
            ));
        }
        return Ok(response);
    }
}
fn list(transport: &mut RelayTransport) -> io::Result<Vec<SessionSummary>> {
    let response = request(transport, Frame::new(b'L', 0, &[]))?;
    if response.kind != b'L' || response.seq != 0 || response.data.len() > 8 * 1024 * 1024 {
        return Err(io::Error::other("Invalid host inventory response"));
    }
    let sessions: Vec<SessionSummary> = serde_json::from_slice(&response.data)?;
    if sessions.len() > 2048
        || sessions
            .iter()
            .any(|s| !omg_session_runtime::host::valid_id(&s.id))
    {
        return Err(io::Error::other("Invalid host inventory entries"));
    }
    Ok(sessions)
}
fn close(transport: &mut RelayTransport, id: &str) -> io::Result<bool> {
    let outer = request(transport, Frame::new(b'K', 1, id.as_bytes()))?;
    if outer.kind == b'D' && outer.seq == 1 {
        let inner = Frame::read(&mut outer.data.as_slice())?;
        if inner.kind == b'K' {
            if inner.data == b"closed" {
                return Ok(true);
            }
            if inner.data == b"pending" {
                return Ok(false);
            }
        }
    }
    Err(io::Error::other(
        "Close was not acknowledged; refresh before retrying",
    ))
}
fn text(value: &str) -> String {
    value
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect()
}
pub fn run(arguments: &[String]) -> io::Result<u8> {
    if arguments.iter().any(|a| a == "--help" || a == "-h") {
        println!("{HELP}");
        return Ok(0);
    }
    let mut action = "list";
    let (mut all, mut yes, mut json, mut local) = (false, false, false, false);
    let (mut support, mut host) = (None, None);
    let mut args = arguments.iter().peekable();
    if args.peek().is_some_and(|a| !a.starts_with('-')) {
        action = args.next().unwrap();
    }
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--all" => all = true,
            "--yes" => yes = true,
            "--json" => json = true,
            "--local" => local = true,
            "--app-support" => {
                support = Some(PathBuf::from(
                    args.next()
                        .ok_or_else(|| io::Error::other("Missing support path"))?,
                ))
            }
            "--host" => {
                host = Some(
                    args.next()
                        .ok_or_else(|| io::Error::other("Missing host"))?
                        .clone(),
                )
            }
            _ => return Err(io::Error::other(format!("Unknown option: {arg}"))),
        }
    }
    if !["list", "close"].contains(&action)
        || (action == "close" && !(all && yes))
        || (action == "list" && (all || yes))
        || (local && host.is_some())
    {
        return Err(io::Error::other(
            "Use list, or close --all --yes; --local and --host are exclusive",
        ));
    }
    let support = support.map(Ok).unwrap_or_else(default_support)?;
    if !support.is_absolute() {
        return Err(io::Error::other("Support path must be absolute"));
    }
    let path = support.join("session-runtime/endpoints.json");
    let endpoints = if path.exists() {
        if fs::metadata(&path)?.len() > 4 * 1024 * 1024 {
            return Err(io::Error::other("Catalogue is too large"));
        }
        let archive: Archive = serde_json::from_slice(&fs::read(path)?)?;
        if archive.version != 1 || archive.endpoints.len() > 512 {
            return Err(io::Error::other("Invalid catalogue"));
        }
        archive.endpoints
    } else {
        Vec::new()
    };
    let mut selected = BTreeMap::new();
    for endpoint in endpoints {
        let d = endpoint.descriptor;
        if local && d.connection.is_some()
            || host
                .as_ref()
                .is_some_and(|h| d.connection.as_ref().map(|s| &s.destination) != Some(h))
        {
            continue;
        }
        selected.insert(d.identity(&support), d);
    }
    let mut inventory = Inventory::default();
    let mut transports = BTreeMap::new();
    for (id, descriptor) in &selected {
        let result = descriptor.connect(&support).and_then(|transport| {
            if let Some(mut transport) = transport {
                let sessions = list(&mut transport)?;
                if action == "close" {
                    transports.insert(id.clone(), transport);
                }
                Ok(sessions)
            } else {
                Ok(Vec::new())
            }
        });
        match result {
            Ok(sessions) => inventory
                .sessions
                .extend(sessions.into_iter().map(|session| Entry {
                    endpoint_id: id.clone(),
                    host: descriptor.name(),
                    revision: descriptor.revision.clone(),
                    session,
                })),
            Err(error) => inventory.errors.push(Failure {
                host: descriptor.name(),
                message: error.to_string(),
            }),
        }
    }
    // Different SSH aliases/cwds can reach the same session incarnation.
    let mut unique = BTreeMap::<(String, String), Entry>::new();
    for entry in inventory.sessions {
        let key = (entry.session.id.clone(), entry.session.generation.clone());
        if unique
            .get(&key)
            .is_none_or(|old| old.session.updated_at < entry.session.updated_at)
        {
            unique.insert(key, entry);
        }
    }
    inventory.sessions = unique.into_values().collect();
    // Two-phase close: never silently claim "all" after a partial inventory.
    if action == "close" && inventory.errors.is_empty() {
        let mut pending: Vec<_> = inventory
            .sessions
            .iter()
            .filter(|e| e.session.ended.is_none())
            .collect();
        let deadline = std::time::Instant::now() + Duration::from_secs(30);
        while !pending.is_empty() {
            // Start every close before waiting for graceful process termination.
            pending.retain(|entry| {
                let result = transports
                    .get_mut(&entry.endpoint_id)
                    .ok_or_else(|| io::Error::other("Endpoint connection was lost"))
                    .and_then(|transport| close(transport, &entry.session.id));
                match result {
                    Ok(true) => {
                        inventory.closed += 1;
                        false
                    }
                    Ok(false) => true,
                    Err(error) => {
                        inventory.errors.push(Failure {
                            host: entry.host.clone(),
                            message: error.to_string(),
                        });
                        false
                    }
                }
            });
            if std::time::Instant::now() >= deadline {
                for entry in pending {
                    inventory.errors.push(Failure {
                        host: entry.host.clone(),
                        message: format!(
                            "Session {} still has a pending close; refresh before retrying",
                            entry.session.id
                        ),
                    });
                }
                break;
            }
            if !pending.is_empty() {
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
    if json {
        println!("{}", serde_json::to_string(&inventory)?);
    } else {
        println!("HOST\tSESSION\tPID\tSTATUS\tDIRECTORY");
        for entry in &inventory.sessions {
            println!(
                "{}\t{}\t{}\t{}\t{}",
                text(&entry.host),
                entry.session.id,
                entry
                    .session
                    .pid
                    .map(|v| v.to_string())
                    .unwrap_or_else(|| "-".into()),
                if entry.session.ended.is_some() {
                    "ended"
                } else {
                    "running"
                },
                text(entry.session.cwd.as_deref().unwrap_or(""))
            );
        }
        if action == "close" {
            println!("Closed {} sessions.", inventory.closed);
        }
        for error in &inventory.errors {
            eprintln!("{}: {}", text(&error.host), text(&error.message));
        }
    }
    Ok(if inventory.errors.is_empty() { 0 } else { 1 })
}
