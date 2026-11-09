//! Presentation facts only. Terminal output never authorizes recovery or cleanup.
use serde::{Deserialize, Serialize};
use std::io;

pub const FRAME: u8 = b'G';
pub const SYNC: &str = "omg-agent-sync";
pub const MAX_RECORDS: usize = 64;
pub const MAX_SNAPSHOT: usize = 2 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Signal {
    pub id: String,
    pub metadata: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    pub version: u32,
    pub revision: u64,
    pub records: Vec<Signal>,
    pub pending: Option<Vec<Signal>>,
}
impl Snapshot {
    pub fn decode(bytes: &[u8]) -> io::Result<Self> {
        if bytes.len() > MAX_SNAPSHOT {
            return Err(io::Error::other("activity snapshot too large"));
        }
        let value: Self = serde_json::from_slice(bytes)?;
        if value.version != 1
            || value.records.len() > MAX_RECORDS
            || value
                .pending
                .as_ref()
                .is_some_and(|r| r.len() > MAX_RECORDS)
            || value
                .records
                .iter()
                .chain(value.pending.iter().flatten())
                .any(|s| !valid(s))
        {
            return Err(io::Error::other("invalid activity snapshot"));
        }
        Ok(value)
    }

    /// The inline viewer uses the existing context bridge, at a parser ground
    /// boundary. This transaction also lets the outer local holder retain it.
    pub fn inline_bytes(&self) -> Vec<u8> {
        let mut bytes = format!("\x1b]3008;start={SYNC};begin\x07").into_bytes();
        for signal in &self.records {
            bytes.extend_from_slice(
                format!("\x1b]3008;start={};{}\x07", signal.id, signal.metadata).as_bytes(),
            );
        }
        bytes.extend_from_slice(format!("\x1b]3008;start={SYNC};end\x07").as_bytes());
        if let Some(pending) = &self.pending {
            bytes.extend_from_slice(format!("\x1b]3008;start={SYNC};begin\x07").as_bytes());
            for signal in pending {
                bytes.extend_from_slice(
                    format!("\x1b]3008;start={};{}\x07", signal.id, signal.metadata).as_bytes(),
                );
            }
        }
        bytes
    }
}

#[derive(Clone)]
struct Record {
    signal: Signal,
    key: String,
    remote: bool,
    // Only meaningful on the machine actually owning this process.
    owner: Option<(i32, bool)>,
}

#[derive(Default)]
pub struct State {
    records: Vec<Record>,
    revision: u64,
    pending: Option<Vec<Record>>,
    remote: bool,
    remote_id: Option<String>,
    pub local: bool,
    pub foreground: Option<i32>,
}

fn field<'a>(metadata: &'a str, separator: char, key: &str) -> Option<&'a str> {
    metadata
        .split(separator)
        .filter_map(|s| s.trim().split_once('='))
        .filter(|(k, _)| *k == key)
        .map(|(_, v)| v.trim())
        .next_back()
}
fn valid(signal: &Signal) -> bool {
    (signal.id.starts_with("omg-agent-") && signal.id != SYNC || signal.id == "omg-program-status")
        && !signal.id.is_empty()
        && signal.id.len() <= 64
        && signal
            .id
            .bytes()
            .all(|b| (32..127).contains(&b) && b != b';')
        && signal.metadata.len() <= 4096
        && signal.metadata.chars().all(|c| !c.is_control())
}
impl State {
    pub fn replace(&mut self, snapshot: Snapshot) {
        self.records.clear();
        self.pending = None;
        for signal in snapshot.records {
            self.consume(false, &signal.id, &signal.metadata);
        }
        if let Some(pending) = snapshot.pending {
            self.consume(false, SYNC, "begin");
            for signal in pending {
                self.consume(false, &signal.id, &signal.metadata);
            }
        }
        self.revision = snapshot.revision;
    }
    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            version: 1,
            revision: self.revision,
            records: self.records.iter().map(|r| r.signal.clone()).collect(),
            pending: self
                .pending
                .as_ref()
                .map(|r| r.iter().map(|r| r.signal.clone()).collect()),
        }
    }
    pub fn consume(&mut self, ended: bool, id: &str, metadata: &str) {
        if id == SYNC {
            match metadata {
                "begin" => self.pending = Some(Vec::new()),
                "end" => {
                    if let Some(records) = self.pending.take() {
                        self.records = records;
                        self.revision = self.revision.saturating_add(1);
                    }
                }
                _ => {}
            }
            return;
        }
        if id.starts_with("omg-ssh-") {
            if ended {
                if self
                    .remote_id
                    .as_deref()
                    .is_some_and(|current| current != id)
                {
                    return;
                }
                self.remote = false;
                self.remote_id = None;
                self.pending = None;
                self.clear_remote();
            } else {
                self.remote = true;
                self.remote_id = Some(id.into());
                // Prompt cwd signals clear remote contexts. Runtime attachment
                // metadata is explicitly marked and never means shell return.
                if !id.starts_with("omg-ssh-inline-")
                    && (field(metadata, ';', "cwd").is_some()
                        || field(metadata, ';', "cwdhex").is_some())
                {
                    self.pending = None;
                    self.clear_remote();
                }
            }
            return;
        }
        let signal = Signal {
            id: id.into(),
            metadata: metadata.into(),
        };
        if !valid(&signal) {
            return;
        }
        let native = id == "omg-program-status";
        if native
            && !matches!(
                field(metadata, ':', "state"),
                Some("idle" | "working" | "done" | "blocked" | "error" | "clear")
            )
        {
            return;
        }
        let key = if native {
            field(metadata, ':', "id").unwrap_or("").to_owned()
        } else {
            id.to_owned()
        };
        let clear = native && field(metadata, ':', "state") == Some("clear");
        let records = self.pending.as_mut().unwrap_or(&mut self.records);
        if ended || clear {
            records.retain(|r| {
                if native {
                    r.signal.id != id
                        || !(key.is_empty()
                            || r.key == key
                            || r.key.starts_with(&(key.clone() + "/")))
                } else {
                    r.key != key
                }
            });
        } else {
            if !native {
                let state = field(metadata, ';', "omg_state");
                if field(metadata, ';', "type") != Some("app")
                    || field(metadata, ';', "omg_agent").is_none()
                    || !matches!(
                        state,
                        Some(
                            "idle"
                                | "working"
                                | "processing"
                                | "active"
                                | "waiting"
                                | "awaiting"
                                | "blocked"
                                | "needsAttention"
                                | "done"
                                | "completed"
                                | "error"
                                | "failed"
                        )
                    )
                {
                    return;
                }
            }
            let remote = if native {
                self.remote
            } else {
                field(metadata, ';', "omg_scope") == Some("remote")
            };
            let existing_owner = records
                .iter()
                .find(|r| r.signal.id == id && r.key == key)
                .and_then(|r| r.owner);
            if native
                && !(self.local && remote)
                && field(metadata, ':', "state") == Some("idle")
            {
                if let Some((old_pid, true)) = existing_owner {
                    if self.foreground != Some(old_pid)
                        && unsafe { libc::kill(-old_pid, 0) != 0 }
                    {
                        records.retain(|r| r.signal.id != id || r.key != key);
                        self.revision = self.revision.saturating_add(1);
                        return;
                    }
                }
            }
            let owner = if !native && !(self.local && remote) {
                let pid = id
                    .rsplit('-')
                    .next()
                    .and_then(|s| s.parse::<i32>().ok())
                    .filter(|p| *p > 1);
                match (pid, field(metadata, ';', "omg_liveness")) {
                    (Some(pid), Some("pid")) => Some((pid, false)),
                    (Some(pid), Some("pgid")) => Some((pid, true)),
                    _ => None,
                }
            } else if native && !(self.local && remote) {
                match (field(metadata, ':', "state"), existing_owner) {
                    (Some("idle"), Some((old_pid, true))) if self.foreground != Some(old_pid) => {
                        Some((old_pid, true))
                    }
                    _ => self.foreground.filter(|p| *p > 1).map(|p| (p, true)),
                }
            } else {
                None
            };
            records.retain(|r| r.signal.id != id || r.key != key);
            if records.len() >= MAX_RECORDS {
                records.remove(0);
            }
            records.push(Record {
                signal,
                key,
                remote,
                owner,
            });
        }
        self.revision = self.revision.saturating_add(1);
    }
    fn clear_remote(&mut self) {
        let before = self.records.len();
        self.records.retain(|r| !r.remote);
        if self.records.len() != before {
            self.revision = self.revision.saturating_add(1);
        }
    }
    /// Runs even without viewers. Never probes remote PIDs on the local host.
    pub fn prune(&mut self, session: i32) -> bool {
        let before = self.records.len();
        self.records.retain(|r| match r.owner {
            Some((pid, group)) => unsafe {
                libc::getsid(pid) == session && libc::kill(if group { -pid } else { pid }, 0) == 0
            },
            None => true,
        });
        if before != self.records.len() {
            self.revision = self.revision.saturating_add(1);
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Vt;

    fn report(agent: &str, state: &str) -> String {
        format!("\x1b]3008;start=omg-agent-{agent}-42;type=app;omg_agent={agent};omg_scope=remote;omg_state={state}\x07")
    }

    #[test]
    fn ghostty_collects_fragmented_hooks_without_a_viewer() {
        let mut vt = Vt::new(80, 24).unwrap();
        for agent in ["codex", "claude", "pi", "omp"] {
            for state in ["idle", "working", "needsAttention", "done"] {
                for byte in report(agent, state).bytes() {
                    vt.write(&[byte]);
                }
            }
        }
        let snapshot = vt.activity().snapshot();
        assert_eq!(snapshot.records.len(), 4);
        assert!(snapshot
            .records
            .iter()
            .all(|s| s.metadata.contains("omg_state=done")));
        vt.write(b"\x1b]3008;end=omg-agent-omp-42\x1b\\");
        assert_eq!(vt.activity().snapshot().records.len(), 3);
    }

    #[test]
    fn native_status_has_namespaced_clear_and_ignores_queries() {
        let mut vt = Vt::new(80, 24).unwrap();
        vt.write(b"\x1b]7501;state=working:app=codex:id=one/child\x07");
        vt.write(b"\x1b]7501;state=blocked:app=codex:id=two:kind=permission\x1b\\");
        vt.write(b"\x1b]7501;?\x07");
        vt.write(b"\x1b]7501;state=clear:id=one\x07");
        let snapshot = vt.activity().snapshot();
        assert_eq!(snapshot.records.len(), 1);
        assert!(snapshot.records[0].metadata.contains("id=two"));
        vt.write(b"\x1b]7501;state=clear\x07");
        assert!(vt.activity().snapshot().records.is_empty());
    }

    #[test]
    fn exiting_native_status_idle_does_not_transfer_ownership_to_shell() {
        let mut vt = Vt::new(80, 24).unwrap();
        vt.activity_mut().local = true;
        vt.activity_mut().foreground = Some(999_991);
        vt.write(b"\x1b]7501;state=working:app=antigravity\x07");
        assert_eq!(vt.activity().snapshot().records.len(), 1);
        let shell_pgid = unsafe { libc::getpgrp() };
        vt.activity_mut().foreground = Some(shell_pgid);
        vt.write(b"\x1b]7501;state=idle:app=antigravity\x07");
        assert!(vt.activity().snapshot().records.is_empty());
    }

    #[test]
    fn nested_inline_snapshot_replaces_old_state_atomically_and_survives_mid_transaction_attach() {
        let mut source = Vt::new(80, 24).unwrap();
        source.write(report("pi", "working").as_bytes());
        source.write(b"\x1b]3008;start=omg-agent-sync;begin\x07");
        source.write(report("omp", "needsAttention").as_bytes());
        let snapshot = source.activity().snapshot();
        assert_eq!(snapshot.records.len(), 1);
        assert_eq!(snapshot.pending.as_ref().unwrap().len(), 1);
        let bytes = serde_json::to_vec(&snapshot).unwrap();
        let mut outer = Vt::new(80, 24).unwrap();
        outer.write(&Snapshot::decode(&bytes).unwrap().inline_bytes());
        outer.write(b"\x1b]3008;start=omg-agent-sync;end\x07");
        assert_eq!(
            outer.activity().snapshot().records[0].id,
            "omg-agent-omp-42"
        );
        let mut empty = Vt::new(80, 24).unwrap();
        empty.write(&State::default().snapshot().inline_bytes());
        outer.write(&empty.activity().snapshot().inline_bytes());
        assert!(outer.activity().snapshot().records.is_empty());
    }

    #[test]
    fn local_holder_does_not_validate_remote_process_ids() {
        let mut vt = Vt::new(80, 24).unwrap();
        vt.activity_mut().local = true;
        vt.write(
            report("codex", "working")
                .replace(";omg_state", ";omg_liveness=pgid;omg_state")
                .as_bytes(),
        );
        assert!(!vt.activity_mut().prune(1));
        vt.activity_mut().local = false;
        vt.write(
            report("codex", "working")
                .replace(";omg_state", ";omg_liveness=pgid;omg_state")
                .as_bytes(),
        );
        assert!(vt.activity_mut().prune(1));
    }

    #[test]
    fn metadata_does_not_clear_remote_state_but_prompt_and_matching_exit_do() {
        let mut vt = Vt::new(80, 24).unwrap();
        vt.write(b"\x1b]3008;start=omg-ssh-inline-fixture;type=remote;cwd=/srv\x07");
        vt.write(report("pi", "working").as_bytes());
        vt.write(b"\x1b]7501;state=done:app=codex\x07");
        vt.write(b"\x1b]3008;start=omg-ssh-inline-fixture;type=remote;cwd=/srv\x07");
        vt.write(b"\x1b]3008;end=omg-ssh-old\x07");
        assert_eq!(vt.activity().snapshot().records.len(), 2);
        vt.write(b"\x1b]3008;end=omg-ssh-inline-fixture\x07");
        assert!(vt.activity().snapshot().records.is_empty());
        vt.write(report("pi", "working").as_bytes());
        vt.write(b"\x1b]3008;start=omg-ssh-prompt;cwd=/srv\x07");
        assert!(vt.activity().snapshot().records.is_empty());
    }

    #[test]
    fn snapshot_bounds_and_non_context_effects_are_not_replayed() {
        let mut vt = Vt::new(80, 24).unwrap();
        for pid in 1..100 {
            vt.write(
                report("omp", "idle")
                    .replace("-42;", &format!("-{pid};"))
                    .as_bytes(),
            );
        }
        vt.write(b"\x1b]52;c;c2VjcmV0\x07\x1b]777;notify;title;body\x07");
        assert_eq!(vt.activity().snapshot().records.len(), MAX_RECORDS);
        let encoded = serde_json::to_vec(&vt.activity().snapshot()).unwrap();
        let bytes = Snapshot::decode(&encoded).unwrap().inline_bytes();
        assert!(!bytes.windows(4).any(|s| s == b"]52;" || s == b"777;"));
        let invalid = r#"{"version":1,"revision":0,"records":[{"id":"omg-agent-pi","metadata":"\u001b]52;"}],"pending":null}"#;
        assert!(Snapshot::decode(invalid.as_bytes()).is_err());
    }
}
