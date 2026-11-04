//! The same explicit-request editor bridge used by ordinary OMG SSH, scoped
//! to a persistent runtime session rather than to a transient SSH connection.
use crate::{
    deploy::quote,
    lifecycle::unix_time,
    record::{nonce, Record},
};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{self, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

const SOURCE: &str = include_str!("../../src/shell-integration/omg/omg.py");

fn directory(path: &Path) -> io::Result<()> {
    match fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    crate::host::private(path)
}

fn write(path: &Path, bytes: &[u8], mode: u32) -> io::Result<()> {
    let temporary = path.with_extension(nonce()?);
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&temporary)?;
        file.write_all(bytes)?;
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

pub struct Bridge {
    pub editor: PathBuf,
    scope: PathBuf,
    generation: String,
}

impl Drop for Bridge {
    fn drop(&mut self) {
        let current = fs::read(self.scope.join("session.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok());
        if current
            .as_ref()
            .and_then(|value| value["runtime_generation"].as_str())
            == Some(self.generation.as_str())
        {
            let _ = fs::remove_dir_all(&self.scope);
        }
    }
}

pub fn prepare(state: &Path, record: &Record, tty: &str, original: &str) -> io::Result<Bridge> {
    crate::host::private(state)?;
    let python = std::env::var_os("PATH")
        .into_iter()
        .flat_map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .map(|directory| directory.join("python3"))
        .find(|path| {
            fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
        .and_then(|path| path.canonicalize().ok())
        .ok_or_else(|| io::Error::other("Python 3 is unavailable for the remote editor bridge"))?;
    let root = state.join("draft");
    directory(&root)?;
    let sessions = root.join("sessions");
    directory(&sessions)?;
    let session = format!("omg-runtime-{}", record.id.to_ascii_lowercase());
    let key = format!("{:x}", Sha256::digest(session.as_bytes()));
    let scope = sessions.join(key);
    directory(&scope)?;
    write(&root.join("omg"), SOURCE.as_bytes(), 0o700)?;
    write(
        &scope.join("session.json"),
        &serde_json::to_vec(&serde_json::json!({
            "protocol": 1, "editor": original, "created": unix_time(), "tty": tty,
            "runtime_id": record.id, "runtime_generation": record.generation,
        }))?,
        0o600,
    )?;
    let launcher = format!(
        "#!/bin/sh\nexec env OMG_REMOTE_ROOT={} {} {} editor {} \"$@\"\n",
        quote(&root.to_string_lossy()),
        quote(&python.to_string_lossy()),
        quote(&root.join("omg").to_string_lossy()),
        quote(&session)
    );
    let editor = scope.join("editor");
    write(&editor, launcher.as_bytes(), 0o700)?;
    Ok(Bridge {
        editor,
        scope,
        generation: record.generation.clone(),
    })
}
