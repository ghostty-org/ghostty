//! Host session registry with durable tombstones, bounded retention and safe resume.
use crate::{
    host::valid_id,
    lifecycle::{unix_time, EndReason, Policy},
    record::{nonce, Record},
    server::{self, ManagedSession},
};
use std::{
    collections::{BTreeMap, HashMap},
    fs, io,
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    process::{Child, Stdio},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};
const MAX_RUNNING: usize = 64;
const MAX_RECORDS: usize = 2048;
const MAX_OPEN_REQUEST_BYTES: usize = 16 * 1024 * 1024;
const LOCAL_HOLDER_STARTUP_GRACE_SECONDS: u64 = 10;
const LOCAL_MAINTENANCE_PROBE_TIMEOUT: Duration = Duration::from_millis(30);
const MAX_LOCAL_MAINTENANCE_PROBES: usize = MAX_RUNNING;
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum RuntimeMode {
    Remote,
    Local,
}

struct LocalHolder {
    capability: String,
    child: Option<Child>,
}

pub const MAX_LOCAL_LAUNCH_INPUT: usize = 10 * 1024 * 1024;
pub const MAX_LOCAL_SCROLLBACK_BYTES: usize = crate::DEFAULT_SCROLLBACK_MAX_BYTES;

#[derive(Clone, serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
pub struct LocalLaunchSpec {
    pub argv: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub cwd: Option<String>,
    pub cols: u16,
    pub rows: u16,
    pub pixel_width: u16,
    pub pixel_height: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scrollback_max_bytes: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scrollback_max_lines: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_base64: Option<String>,
}

impl LocalLaunchSpec {
    pub fn validate(&self) -> io::Result<()> {
        if self.argv.is_empty()
            || self.argv.len() > 128
            || self.argv[0].is_empty()
            || self
                .argv
                .iter()
                .any(|value| value.len() > 64 * 1024 || value.contains('\0'))
        {
            return Err(io::Error::other("invalid local launch arguments"));
        }
        if self.cols == 0
            || self.rows == 0
            || self.cols > 500
            || self.rows > 300
            || self.pixel_width > 16_000
            || self.pixel_height > 16_000
        {
            return Err(io::Error::other("invalid local launch terminal size"));
        }
        if self
            .scrollback_max_bytes
            .is_some_and(|bytes| bytes > MAX_LOCAL_SCROLLBACK_BYTES)
        {
            return Err(io::Error::other(
                "local session scrollback exceeds the runtime limit",
            ));
        }
        let mut size = self.argv.iter().map(String::len).sum::<usize>();
        for (key, value) in &self.env {
            if key.len() > 256 || key.contains('=') || key.contains('\0') || value.contains('\0') {
                return Err(io::Error::other("invalid local launch environment"));
            }
            size = size.saturating_add(key.len()).saturating_add(value.len());
        }
        if let Some(cwd) = &self.cwd {
            if !cwd.starts_with('/') || cwd.len() > 4096 || cwd.contains('\0') {
                return Err(io::Error::other("invalid local launch working directory"));
            }
            if !fs::metadata(cwd)?.is_dir() {
                return Err(io::Error::other(
                    "local launch working directory is not a directory",
                ));
            }
            size = size.saturating_add(cwd.len());
        }
        if let Some(encoded) = &self.input_base64 {
            if encoded.len() > 4 * MAX_LOCAL_LAUNCH_INPUT.div_ceil(3) {
                return Err(io::Error::other("local startup input exceeds limit"));
            }
            let decoded =
                base64::Engine::decode(&base64::engine::general_purpose::STANDARD, encoded)
                    .map_err(|_| io::Error::other("invalid local startup input encoding"))?;
            if decoded.len() > MAX_LOCAL_LAUNCH_INPUT {
                return Err(io::Error::other("local startup input exceeds limit"));
            }
            size = size.saturating_add(decoded.len());
        }
        if size > crate::MAX_FRAME {
            return Err(io::Error::other("local launch specification exceeds limit"));
        }
        Ok(())
    }

    pub fn initial_input(&self) -> io::Result<Vec<u8>> {
        self.input_base64.as_deref().map_or_else(
            || Ok(Vec::new()),
            |encoded| {
                let bytes =
                    base64::Engine::decode(&base64::engine::general_purpose::STANDARD, encoded)
                        .map_err(|_| io::Error::other("invalid local startup input encoding"))?;
                if bytes.len() > MAX_LOCAL_LAUNCH_INPUT {
                    return Err(io::Error::other("local startup input exceeds limit"));
                }
                Ok(bytes)
            },
        )
    }
}

#[derive(serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
pub struct OpenRequest {
    pub id: String,
    pub policy: Policy,
    pub create: bool,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch: Option<LocalLaunchSpec>,
}

pub struct Registry {
    pub root: PathBuf,
    pub command: Vec<String>,
    pub policy: Policy,
    workers: HashMap<String, JoinHandle<()>>,
    local_holders: HashMap<String, LocalHolder>,
    mode: RuntimeMode,
    containment_root: Option<PathBuf>,
    last_maintenance: Instant,
}
impl Registry {
    pub fn new(root: PathBuf, command: Vec<String>, policy: Policy) -> Self {
        Self {
            root,
            command,
            policy,
            workers: HashMap::new(),
            local_holders: HashMap::new(),
            mode: RuntimeMode::Remote,
            containment_root: None,
            last_maintenance: Instant::now() - Duration::from_secs(30),
        }
    }

    pub fn new_local(root: PathBuf, command: Vec<String>, policy: Policy) -> Self {
        let mut registry = Self::new(root, command, policy);
        registry.mode = RuntimeMode::Local;
        registry
    }

    pub fn supports_local_launch(&self) -> bool {
        self.mode == RuntimeMode::Local
    }
    pub fn set_containment_root(&mut self, root: Option<PathBuf>) {
        self.containment_root = root;
    }
    fn session_socket(&self, id: &str) -> PathBuf {
        use sha2::{Digest, Sha256};
        let key = format!("{:x}", Sha256::digest(id.as_bytes()));
        self.root
            .parent()
            .unwrap()
            .join(format!("{}.sock", &key[..16]))
    }
    fn probe_and_adopt(
        &mut self,
        record: &Record,
        timeout: Duration,
        verify_owned_child: bool,
    ) -> io::Result<()> {
        let Some(capability) = record.holder_capability.as_deref() else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "local holder capability is missing",
            ));
        };
        let owned_child_status = self
            .local_holders
            .get_mut(&record.id)
            .filter(|holder| holder.capability == capability)
            .and_then(|holder| holder.child.as_mut())
            .map(Child::try_wait)
            .transpose();
        match owned_child_status {
            Ok(Some(None)) if !verify_owned_child => return Ok(()),
            Ok(Some(Some(_))) => {
                self.local_holders.remove(&record.id);
            }
            Err(error) if !verify_owned_child => return Err(error),
            _ => {}
        }
        let session_socket = self.session_socket(&record.id);
        let record_path = self.root.join(format!("{}.json", record.id));
        let attempts = if verify_owned_child { 3 } else { 1 };
        for attempt in 0..attempts {
            match crate::holder::probe_with_timeout(
                &session_socket,
                &record.id,
                &record.generation,
                capability,
                timeout,
            ) {
                Ok(probe) => {
                    let current = Record::load(&record_path)?;
                    if current.id != record.id
                        || current.generation != record.generation
                        || current.holder_capability.as_deref() != Some(capability)
                    {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "local holder record identity changed",
                        ));
                    }
                    if let Some(ended) = current.ended {
                        return Err(io::Error::new(
                            io::ErrorKind::UnexpectedEof,
                            format!("local session ended: {ended:?}"),
                        ));
                    }
                    if current.pid.is_some() && probe.session_pid != current.pid {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "local holder process identity did not match its record",
                        ));
                    }
                    if !self.local_holders.get(&record.id).is_some_and(|holder| {
                        holder.capability == capability && holder.child.is_some()
                    }) {
                        self.local_holders.insert(
                            record.id.clone(),
                            LocalHolder {
                                capability: capability.to_string(),
                                child: None,
                            },
                        );
                    }
                    return Ok(());
                }
                Err(error)
                    if verify_owned_child
                        && attempt + 1 < attempts
                        && matches!(
                            error.kind(),
                            io::ErrorKind::UnexpectedEof
                                | io::ErrorKind::ConnectionReset
                                | io::ErrorKind::ConnectionAborted
                                | io::ErrorKind::BrokenPipe
                        ) =>
                {
                    let current = Record::load(&record_path)?;
                    if current.id != record.id
                        || current.generation != record.generation
                        || current.holder_capability.as_deref() != Some(capability)
                    {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "local holder record identity changed",
                        ));
                    }
                    if let Some(ended) = current.ended {
                        return Err(io::Error::new(
                            io::ErrorKind::UnexpectedEof,
                            format!("local session ended: {ended:?}"),
                        ));
                    }
                    thread::sleep(Duration::from_millis(20));
                }
                Err(error) => return Err(error),
            }
        }
        Err(io::Error::other("local holder probe failed"))
    }

    fn local_holder_startup_grace_elapsed(&self, record: &Record) -> bool {
        unix_time().saturating_sub(record.updated_at) >= LOCAL_HOLDER_STARTUP_GRACE_SECONDS
    }

    fn mark_local_lost(&mut self, record: &mut Record, path: &std::path::Path) -> io::Result<bool> {
        let mut current = Record::load(path)?;
        if current.id != record.id
            || current.generation != record.generation
            || current.ended.is_some()
        {
            *record = current;
            return Ok(false);
        }
        current.pid = None;
        current.ended = Some(EndReason::Lost);
        current.save(path)?;
        *record = current;
        self.local_holders.remove(&record.id);
        let socket = self.session_socket(&record.id);
        let _ = fs::remove_file(socket.with_extension("evt"));
        let _ = fs::remove_file(crate::holder::control_path(&socket));
        let _ = fs::remove_file(socket);
        Ok(true)
    }
    pub fn maintenance(&mut self) {
        let finished: Vec<_> = self
            .workers
            .iter()
            .filter(|(_, h)| h.is_finished())
            .map(|(id, _)| id.clone())
            .collect();
        for id in finished {
            if let Some(h) = self.workers.remove(&id) {
                let _ = h.join();
            }
        }
        if self.mode == RuntimeMode::Local {
            let finished: Vec<_> = self
                .local_holders
                .iter_mut()
                .filter_map(|(id, holder)| {
                    holder
                        .child
                        .as_mut()
                        .and_then(|child| child.try_wait().ok().flatten())
                        .map(|_| id.clone())
                })
                .collect();
            for id in finished {
                self.local_holders.remove(&id);
            }
        }
        if self.last_maintenance.elapsed() < Duration::from_secs(30) {
            return;
        }
        self.last_maintenance = Instant::now();
        let now = unix_time();
        let mut local_probes = 0;
        if let Ok(entries) = fs::read_dir(&self.root) {
            for entry in entries.flatten() {
                if entry.path().extension().is_some_and(|s| s == "json") {
                    if let Ok(mut record) = Record::load(&entry.path()) {
                        if !valid_id(&record.id) || self.workers.contains_key(&record.id) {
                            continue;
                        }
                        if self.mode == RuntimeMode::Local {
                            if record.ended.is_none() {
                                if local_probes >= MAX_LOCAL_MAINTENANCE_PROBES {
                                    continue;
                                }
                                local_probes += 1;
                                match self.probe_and_adopt(
                                    &record,
                                    LOCAL_MAINTENANCE_PROBE_TIMEOUT,
                                    false,
                                ) {
                                    Ok(()) => continue,
                                    Err(error)
                                        if crate::holder::listener_is_gone(&error)
                                            && self.local_holder_startup_grace_elapsed(&record) =>
                                    {
                                        if self.mark_local_lost(&mut record, &entry.path()).is_err()
                                        {
                                            continue;
                                        }
                                    }
                                    Err(_) => continue,
                                }
                            }
                            if record.ended.is_some()
                                && now.saturating_sub(record.updated_at)
                                    > record.policy.record_retention_seconds
                            {
                                let _ = fs::remove_file(entry.path());
                            }
                            continue;
                        }
                        if record.ended.is_none() || record.pid.is_some() {
                            if let Some(root) = &self.containment_root {
                                if crate::containment::Group::finish_generation(
                                    root,
                                    &record.generation,
                                )
                                .is_err()
                                {
                                    continue;
                                }
                            }
                            record.pid = None;
                            record.ended = Some(EndReason::Lost);
                            if record.save(&entry.path()).is_err() {
                                continue;
                            }
                        }
                        // We hold the host lock and there is no actor for this UUID.
                        // Never signal the numeric PID stored by a previous host.
                        use sha2::{Digest, Sha256};
                        let key = format!("{:x}", Sha256::digest(record.id.as_bytes()));
                        if let Some(parent) = self.root.parent() {
                            let socket = parent.join(format!("{}.sock", &key[..16]));
                            let _ = fs::remove_file(socket.with_extension("evt"));
                            let _ = fs::remove_file(socket);
                        }
                        if record.ended.is_some()
                            && now.saturating_sub(record.updated_at)
                                > record.policy.record_retention_seconds
                        {
                            let _ = fs::remove_file(entry.path());
                        }
                    }
                }
            }
        }
    }
    /// Durable close intent, independent of attachments. UUIDs are never reused:
    /// the permanent marker also prohibits an automatic Agent resume/new generation.
    pub fn close(&mut self, id: &str) -> io::Result<bool> {
        if !valid_id(id) {
            return Err(io::Error::other("invalid session identity"));
        }
        let marker = self.root.join(format!("{id}.closed"));
        let file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .open(marker)?;
        file.sync_all()?;
        fs::File::open(&self.root)?.sync_all()?;
        if self.workers.get(id).is_some_and(|w| !w.is_finished()) {
            return Ok(false);
        }
        self.maintenance();
        let path = self.root.join(format!("{id}.json"));
        if let Ok(mut record) = Record::load(&path) {
            if self.mode == RuntimeMode::Local && (record.ended.is_none() || record.pid.is_some()) {
                match self.probe_and_adopt(&record, Duration::from_secs(1), true) {
                    Ok(()) => return Ok(false),
                    Err(error)
                        if crate::holder::listener_is_gone(&error)
                            && self.local_holder_startup_grace_elapsed(&record) =>
                    {
                        if self.mark_local_lost(&mut record, &path)? {
                            return Err(io::Error::other(
                                "local holder is unavailable; cleanup is unconfirmed",
                            ));
                        }
                        if record.pid.is_some() {
                            return Err(io::Error::other(
                                "local session is still ending; cleanup is unconfirmed",
                            ));
                        }
                        if record.ended.is_none() {
                            return Err(io::Error::other(
                                "local session identity changed; cleanup is unconfirmed",
                            ));
                        }
                        record.ended = Some(EndReason::ExplicitClose);
                        record.save(&path)?;
                        return Ok(true);
                    }
                    Err(error) if crate::holder::listener_is_gone(&error) => {
                        return Err(io::Error::other(
                            "local holder may still be starting; cleanup is unconfirmed",
                        ));
                    }
                    Err(error) => {
                        let current = Record::load(&path)?;
                        if current.generation == record.generation && current.ended.is_some() {
                            if current.pid.is_some() {
                                return Err(io::Error::other(
                                    "local session is still ending; cleanup is unconfirmed",
                                ));
                            }
                            record = current;
                            record.ended = Some(EndReason::ExplicitClose);
                            record.save(&path)?;
                            return Ok(true);
                        }
                        return Err(io::Error::other(format!(
                            "local holder did not confirm cleanup ({:?}); session preserved",
                            error.kind()
                        )));
                    }
                }
            }
            if record.ended == Some(EndReason::Lost) {
                // Only an owned cgroup provides evidence for cleanup after loss.
                if !record.contained {
                    return Err(io::Error::other("legacy session loss; cleanup unconfirmed"));
                }
                let root = self.containment_root.as_ref().ok_or_else(|| {
                    io::Error::other("session lost; cleanup could not be confirmed")
                })?;
                crate::containment::Group::finish_generation(root, &record.generation)?;
            }
            record.pid = None;
            record.ended = Some(EndReason::ExplicitClose);
            record.save(&path)?;
        }
        Ok(true)
    }
    pub fn is_empty(&self) -> bool {
        self.mode == RuntimeMode::Local || self.workers.is_empty()
    }

    pub fn is_local(&self) -> bool {
        self.mode == RuntimeMode::Local
    }
    pub fn list(&self) -> io::Result<Vec<Record>> {
        let mut records = vec![];
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            if entry.path().extension().is_some_and(|s| s == "json") {
                if let Ok(r) = Record::load(&entry.path()) {
                    records.push(r);
                }
            }
        }
        Ok(records)
    }

    pub fn catalogue(&mut self) -> io::Result<Vec<Record>> {
        if self.mode == RuntimeMode::Local {
            self.last_maintenance = Instant::now() - Duration::from_secs(30);
            self.maintenance();
        }
        self.list()
    }
    pub fn connect(&mut self, id: &str, resume_generation: Option<&str>) -> io::Result<UnixStream> {
        self.connect_with(id, resume_generation, None, true, None, None)
    }
    pub fn open(&mut self, request: &OpenRequest) -> io::Result<UnixStream> {
        request.policy.validate()?;
        let request_size = serde_json::to_vec(request)?.len();
        if request_size > MAX_OPEN_REQUEST_BYTES {
            return Err(io::Error::other("session open request exceeds limit"));
        }
        let mut local_launch = request.launch.clone();
        match (self.mode, request.create, local_launch.as_mut()) {
            (RuntimeMode::Remote, _, Some(_)) => {
                return Err(io::Error::other(
                    "local launch specifications are forbidden on SSH sessions",
                ));
            }
            (RuntimeMode::Local, true, Some(launch)) => {
                launch.validate()?;
            }
            (RuntimeMode::Local, true, None) => {
                return Err(io::Error::other(
                    "local session launch specification required",
                ));
            }
            (RuntimeMode::Local, false, Some(_)) => {
                return Err(io::Error::other(
                    "reattaching a local session cannot send a launch specification",
                ));
            }
            _ => {}
        }
        self.connect_with(
            &request.id,
            None,
            Some(request.policy.clone()),
            request.create,
            request.cwd.as_deref(),
            local_launch,
        )
    }
    fn connect_with(
        &mut self,
        id: &str,
        resume_generation: Option<&str>,
        policy: Option<Policy>,
        create: bool,
        initial_cwd: Option<&str>,
        local_launch: Option<LocalLaunchSpec>,
    ) -> io::Result<UnixStream> {
        if !valid_id(id) {
            return Err(io::Error::other("invalid session identity"));
        }
        self.maintenance();
        if self.root.join(format!("{id}.closed")).exists() {
            return Err(io::Error::other("session explicitly closed"));
        }
        use sha2::{Digest, Sha256};
        let key = format!("{:x}", Sha256::digest(id.as_bytes()));
        let socket = self
            .root
            .parent()
            .unwrap()
            .join(format!("{}.sock", &key[..16]));
        let path = self.root.join(format!("{id}.json"));
        if self.workers.contains_key(id) {
            return UnixStream::connect(socket);
        }
        if self.mode == RuntimeMode::Local {
            return self.connect_local(
                id,
                &socket,
                &path,
                create && local_launch.is_some(),
                policy,
                local_launch,
            );
        }
        if self.workers.len() >= MAX_RUNNING {
            return Err(io::Error::other("active session quota exceeded"));
        }
        let mut argv = self.command.clone();
        let mut working_directory = None;
        let mut record = if path.exists() {
            let mut record = Record::load(&path)?;
            if record.ended.is_none() {
                record.pid = None;
                record.ended = Some(EndReason::Lost);
                record.save(&path)?;
            }
            if resume_generation != Some(record.generation.as_str())
                || !record.ended.is_some_and(EndReason::resumable)
            {
                return Err(io::Error::other(format!(
                    "session ended: {:?}; inspect its record before resuming",
                    record.ended
                )));
            }
            let resume = record
                .resume
                .as_ref()
                .ok_or_else(|| io::Error::other("session has no Agent recovery descriptor"))?;
            if !resume.store_exists() {
                return Err(io::Error::other(
                    "Agent conversation store unavailable; refusing new conversation",
                ));
            }
            let args = resume.arguments()?;
            let quote = |s: &str| format!("'{}'", s.replace('\'', "'\\''"));
            let script = format!(
                "exec {}",
                args.iter().map(|s| quote(s)).collect::<Vec<_>>().join(" ")
            );
            let shell = self
                .command
                .first()
                .ok_or_else(|| io::Error::other("missing shell"))?
                .clone();
            argv = vec![shell, "-l".into(), "-i".into(), "-c".into(), script];
            record.generation = nonce()?;
            record.ended = None;
            record.pid = None;
            record
        } else {
            if resume_generation.is_some() || !create {
                return Err(io::Error::other("unknown session; cannot resume"));
            }
            if self.list()?.len() >= MAX_RECORDS {
                return Err(io::Error::other("session metadata quota exceeded"));
            }
            if let Some(cwd) = initial_cwd {
                if !cwd.starts_with('/') || cwd.len() > 4096 || cwd.contains('\0') {
                    return Err(io::Error::other("invalid initial working directory"));
                }
                if !fs::metadata(cwd)?.is_dir() {
                    return Err(io::Error::other(
                        "initial working directory is not a directory",
                    ));
                }
                working_directory = Some(PathBuf::from(cwd));
            }
            // A compact permanent marker distinguishes a new pane from an
            // expired/deleted recovery record, avoiding silent recreation.
            fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(self.root.join(format!("{id}.created")))?;
            Record::new(id, policy.unwrap_or_else(|| self.policy.clone()))?
        };
        record.contained = self.containment_root.is_some();
        record.save(&path)?;
        // This host owns the runtime directory exclusively; stale sockets cannot
        // be a still-running worker. Remove only our validated session paths.
        let _ = fs::remove_file(&socket);
        let _ = fs::remove_file(socket.with_extension("evt"));
        let p = socket.clone();
        let record_path = path.clone();
        let containment_root = self.containment_root.clone();
        let worker = thread::Builder::new()
            .name(format!("session-{id}"))
            .spawn(move || {
                if let Err(error) = server::serve_managed(
                    &p,
                    argv,
                    Some(ManagedSession {
                        path: record_path.clone(),
                        record,
                        containment_root,
                        initial_cwd: working_directory,
                        local_launch: None,
                    }),
                ) {
                    if let Ok(mut r) = Record::load(&record_path) {
                        r.pid = None;
                        r.ended = Some(EndReason::Lost);
                        let _ = r.save(&record_path);
                    }
                    eprintln!("session worker failed: {error}");
                }
            })?;
        self.workers.insert(id.into(), worker);
        let start = Instant::now();
        loop {
            match UnixStream::connect(&socket) {
                Ok(s) => return Ok(s),
                Err(_) if start.elapsed() < Duration::from_secs(2) => {
                    thread::sleep(Duration::from_millis(5))
                }
                Err(e) => return Err(e),
            }
        }
    }

    fn connect_local(
        &mut self,
        id: &str,
        socket: &Path,
        path: &Path,
        create: bool,
        policy: Option<Policy>,
        launch: Option<LocalLaunchSpec>,
    ) -> io::Result<UnixStream> {
        if path.exists() {
            let mut record = Record::load(path)?;
            if record.ended.is_none() {
                match self.probe_and_adopt(&record, Duration::from_secs(1), true) {
                    Ok(()) => return UnixStream::connect(socket),
                    Err(error)
                        if crate::holder::listener_is_gone(&error)
                            && self.local_holder_startup_grace_elapsed(&record) =>
                    {
                        self.mark_local_lost(&mut record, path)?;
                    }
                    Err(error) if crate::holder::listener_is_gone(&error) => {
                        return Err(io::Error::other(
                            "local session holder may still be starting; retry the attach",
                        ));
                    }
                    Err(error) => {
                        let current = Record::load(path)?;
                        if current.generation == record.generation && current.ended.is_some() {
                            return Err(io::Error::other(format!(
                                "local session ended: {:?}; it will not be recreated",
                                current.ended
                            )));
                        }
                        return Err(io::Error::other(format!(
                            "local session holder did not confirm ({:?}); session preserved",
                            error.kind()
                        )));
                    }
                }
            }
            return Err(io::Error::other(format!(
                "local session ended: {:?}; it will not be recreated",
                Record::load(path)?.ended
            )));
        }
        if !create {
            return Err(io::Error::other("unknown local session; cannot attach"));
        }
        if self.root.join(format!("{id}.created")).exists() {
            return Err(io::Error::other(
                "local session identity was already used; refusing to create a new shell",
            ));
        }
        if socket.exists() || crate::holder::control_path(socket).exists() {
            return Err(io::Error::other(
                "unregistered local session endpoint exists; refusing to replace it",
            ));
        }
        let launch = launch
            .ok_or_else(|| io::Error::other("local session launch specification required"))?;
        launch.validate()?;
        let records = self.list()?;
        if records.len() >= MAX_RECORDS {
            return Err(io::Error::other("session metadata quota exceeded"));
        }
        if records
            .iter()
            .filter(|record| record.ended.is_none())
            .count()
            >= MAX_RUNNING
        {
            return Err(io::Error::other("active session quota exceeded"));
        }
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(self.root.join(format!("{id}.created")))?;
        let mut record = Record::new(id, policy.unwrap_or_else(|| self.policy.clone()))?;
        record.holder_capability = Some(nonce()?);
        record.cwd = launch.cwd.clone();
        record.save(path)?;

        let executable = std::env::current_exe()?;
        let request = crate::holder::HolderRequest {
            session_socket: socket.to_path_buf(),
            record_path: path.to_path_buf(),
            record: record.clone(),
            launch,
        };
        let diagnostics_path = self.root.parent().unwrap().join("host.log");
        let diagnostics = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&diagnostics_path)?;
        fs::set_permissions(&diagnostics_path, fs::Permissions::from_mode(0o600))?;
        let child = match crate::holder::spawn(&executable, &request, Stdio::from(diagnostics)) {
            Ok(child) => child,
            Err(error) => {
                record.ended = Some(EndReason::Lost);
                let _ = record.save(path);
                return Err(error);
            }
        };
        self.local_holders.insert(
            id.into(),
            LocalHolder {
                capability: record.holder_capability.clone().unwrap(),
                child: Some(child),
            },
        );

        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let holder_exited = self
                .local_holders
                .get_mut(id)
                .and_then(|holder| holder.child.as_mut())
                .map(Child::try_wait)
                .transpose()?
                .flatten()
                .is_some();
            if holder_exited {
                self.local_holders.remove(id);
                record.pid = None;
                record.ended = Some(EndReason::Lost);
                record.save(path)?;
                return Err(io::Error::other(
                    "local session holder exited during startup",
                ));
            }
            match crate::holder::probe(
                socket,
                id,
                &record.generation,
                record.holder_capability.as_deref().unwrap(),
            ) {
                Ok(status) if status.session_pid.is_some() => {
                    if let Ok(stream) = UnixStream::connect(socket) {
                        return Ok(stream);
                    }
                }
                _ => {}
            }
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "local session holder started but did not become attachable",
                ));
            }
            thread::sleep(Duration::from_millis(20));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn launch(argv: Vec<String>, env: BTreeMap<String, String>) -> LocalLaunchSpec {
        LocalLaunchSpec {
            argv,
            env,
            cwd: None,
            cols: 80,
            rows: 24,
            pixel_width: 640,
            pixel_height: 384,
            scrollback_max_bytes: None,
            scrollback_max_lines: None,
            input_base64: None,
        }
    }

    #[test]
    fn local_launch_preserves_empty_nonzero_arguments_and_native_environment_names() {
        let mut env = BTreeMap::new();
        env.insert("BASH_FUNC_example%%".into(), "() { echo ok; }".into());
        let spec = launch(vec!["/bin/sh".into(), "".into(), "tail".into()], env);
        assert!(spec.validate().is_ok());
    }

    #[test]
    fn local_launch_without_scrollback_fields_uses_legacy_defaults() {
        let bytes = br#"{"argv":["/bin/sh"],"env":{},"cwd":null,"cols":80,"rows":24,"pixel_width":640,"pixel_height":384}"#;
        let spec: LocalLaunchSpec = serde_json::from_slice(bytes).unwrap();
        assert_eq!(spec.scrollback_max_bytes, None);
        assert_eq!(spec.scrollback_max_lines, None);
        assert!(spec.validate().is_ok());
    }

    #[test]
    fn local_launch_rejects_empty_argv_zero_and_unrepresentable_environment_keys() {
        let empty_argv0 = launch(vec!["".into(), "argument".into()], BTreeMap::new());
        assert!(empty_argv0.validate().is_err());

        let mut env = BTreeMap::new();
        env.insert("BAD=KEY".into(), "value".into());
        assert!(launch(vec!["/bin/sh".into()], env).validate().is_err());
    }

    #[test]
    fn local_launch_preserves_zero_scrollback_and_caps_bytes() {
        let mut spec = launch(vec!["/bin/sh".into()], BTreeMap::new());
        spec.scrollback_max_bytes = Some(0);
        spec.scrollback_max_lines = Some(0);
        assert!(spec.validate().is_ok());

        spec.scrollback_max_bytes = Some(MAX_LOCAL_SCROLLBACK_BYTES);
        assert!(spec.validate().is_ok());
        spec.scrollback_max_bytes = Some(MAX_LOCAL_SCROLLBACK_BYTES + 1);
        assert!(spec.validate().is_err());
    }

    fn local_test_root() -> PathBuf {
        let path = PathBuf::from(format!("/tmp/omg-local-{}", &nonce().unwrap()[..8]));
        fs::create_dir_all(path.join("sessions")).unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(path.join("sessions"), fs::Permissions::from_mode(0o700)).unwrap();
        path
    }

    fn save_stale_control_record(
        registry: &Registry,
        id: &str,
        updated_at: u64,
    ) -> (PathBuf, PathBuf) {
        let mut record = Record::new(id, Policy::default()).unwrap();
        record.pid = Some(std::process::id());
        record.holder_capability = Some(nonce().unwrap());
        record.updated_at = updated_at;
        let record_path = registry.root.join(format!("{id}.json"));
        fs::write(&record_path, serde_json::to_vec(&record).unwrap()).unwrap();
        let session_socket = registry.session_socket(id);
        let listener =
            std::os::unix::net::UnixListener::bind(crate::holder::control_path(&session_socket))
                .unwrap();
        drop(listener);
        (record_path, session_socket)
    }

    #[test]
    fn catalogue_marks_stale_holder_socket_lost_after_startup_grace() {
        let root = local_test_root();
        let mut registry = Registry::new_local(
            root.join("sessions"),
            vec!["/bin/sh".into()],
            Policy::default(),
        );
        let id = "11111111-1111-1111-1111-111111111111";
        let (record_path, session_socket) = save_stale_control_record(&registry, id, 1);
        let entries = registry.catalogue().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].ended, Some(EndReason::Lost));
        assert_eq!(entries[0].pid, None);
        assert!(!crate::holder::control_path(&session_socket).exists());
        assert!(record_path.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn catalogue_preserves_a_recent_unconfirmed_holder_during_startup_grace() {
        let root = local_test_root();
        let mut registry = Registry::new_local(
            root.join("sessions"),
            vec!["/bin/sh".into()],
            Policy::default(),
        );
        let id = "22222222-2222-2222-2222-222222222222";
        let (record_path, session_socket) = save_stale_control_record(&registry, id, unix_time());
        let entries = registry.catalogue().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].ended, None);
        assert!(entries[0].pid.is_some());
        assert!(crate::holder::control_path(&session_socket).exists());
        assert!(Record::load(&record_path).unwrap().ended.is_none());
        fs::remove_dir_all(root).unwrap();
    }
}
