//! Host session registry with durable tombstones, bounded retention and safe resume.
use crate::{
    host::valid_id,
    lifecycle::{unix_time, EndReason, Policy},
    record::{nonce, Record},
    server::{self, ManagedSession},
};
use std::{
    collections::HashMap,
    fs, io,
    os::unix::net::UnixStream,
    path::PathBuf,
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};
const MAX_RUNNING: usize = 64;
const MAX_RECORDS: usize = 2048;
#[derive(serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
pub struct OpenRequest {
    pub id: String,
    pub policy: Policy,
    pub create: bool,
    #[serde(default)]
    pub cwd: Option<String>,
}

pub struct Registry {
    pub root: PathBuf,
    pub command: Vec<String>,
    pub policy: Policy,
    workers: HashMap<String, JoinHandle<()>>,
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
            containment_root: None,
            last_maintenance: Instant::now() - Duration::from_secs(30),
        }
    }
    pub fn set_containment_root(&mut self, root: Option<PathBuf>) {
        self.containment_root = root;
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
        if self.last_maintenance.elapsed() < Duration::from_secs(30) {
            return;
        }
        self.last_maintenance = Instant::now();
        let now = unix_time();
        if let Ok(entries) = fs::read_dir(&self.root) {
            for entry in entries.flatten() {
                if entry.path().extension().is_some_and(|s| s == "json") {
                    if let Ok(mut record) = Record::load(&entry.path()) {
                        if !valid_id(&record.id) || self.workers.contains_key(&record.id) {
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
        self.workers.is_empty()
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
    pub fn connect(&mut self, id: &str, resume_generation: Option<&str>) -> io::Result<UnixStream> {
        self.connect_with(id, resume_generation, None, true, None)
    }
    pub fn open(&mut self, request: &OpenRequest) -> io::Result<UnixStream> {
        request.policy.validate()?;
        self.connect_with(
            &request.id,
            None,
            Some(request.policy.clone()),
            request.create,
            request.cwd.as_deref(),
        )
    }
    fn connect_with(
        &mut self,
        id: &str,
        resume_generation: Option<&str>,
        policy: Option<Policy>,
        create: bool,
        initial_cwd: Option<&str>,
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
                    &argv,
                    Some(ManagedSession {
                        path: record_path.clone(),
                        record,
                        containment_root,
                        initial_cwd: working_directory,
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
}
