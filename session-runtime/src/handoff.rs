//! Local CLI-to-pane handoff. Only conservative interactive SSH invocations
//! qualify; commands, forwarding and control operations retain system SSH.
use std::{
    env,
    io::{self, Write},
    time::Duration,
};
pub fn interactive(args: &[String]) -> bool {
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if a == "--" {
            i += 1;
            break;
        }
        if !a.starts_with('-') {
            break;
        }
        let mut chars = a[1..].chars();
        while let Some(c) = chars.next() {
            if "p ilFJ".replace(' ', "").contains(c) {
                if chars.as_str().is_empty() {
                    i += 1;
                    if i >= args.len() {
                        return false;
                    }
                }
                break;
            }
            if !"46Avq".contains(c) {
                return false;
            }
        }
        i += 1;
    }
    i + 1 == args.len() && !args[i].is_empty() && !args[i].starts_with('-')
}
pub fn request(ssh: &str, args: &[String]) -> io::Result<()> {
    if !interactive(args) {
        return Err(io::Error::other("not an interactive native SSH request"));
    }
    if unsafe { libc::isatty(libc::STDIN_FILENO) } != 1
        || unsafe { libc::isatty(libc::STDOUT_FILENO) } != 1
    {
        return Err(io::Error::other(
            "native SSH requires an interactive terminal",
        ));
    }
    let token = env::var("OMG_SSH_HANDOFF_TOKEN").map_err(io::Error::other)?;
    let directory = env::var("OMG_SSH_HANDOFF_DIRECTORY").map_err(io::Error::other)?;
    if token.is_empty() || directory.is_empty() {
        return Err(io::Error::other(
            "native SSH is unavailable in this terminal",
        ));
    }
    let id = crate::record::nonce()?;
    let payload =
        serde_json::json!({"token":token,"ssh":ssh,"args":args,"cwd":env::current_dir()?});
    use std::os::unix::fs::OpenOptionsExt;
    let path = std::path::Path::new(&directory).join(format!("{id}.json"));
    let mut file = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&path)?;
    file.write_all(&serde_json::to_vec(&payload)?)?;
    file.sync_all()?;
    print!("\x1b]3008;start=omg-runtime-request-{id};type=app\x07");
    io::stdout().flush()?;
    // Preserve the local shell while its surface is parked behind the remote
    // pane. The GUI accepts the request into a separate native tab, after which
    // this local shell is immediately available for more commands.
    let accepted = std::path::Path::new(&directory).join(format!("{id}.accepted"));
    let failed = std::path::Path::new(&directory).join(format!("{id}.failed"));
    let start = std::time::Instant::now();
    loop {
        if let Ok(message) = std::fs::read_to_string(&failed) {
            let _ = std::fs::remove_file(&failed);
            let _ = std::fs::remove_file(&path);
            let _ = std::fs::remove_file(&accepted);
            return Err(io::Error::other(format!("OMG native SSH: {message}")));
        }
        if accepted.exists() {
            let _ = std::fs::remove_file(accepted);
            let _ = std::fs::remove_file(&path);
            return Ok(());
        }
        if !accepted.exists() && start.elapsed() > Duration::from_secs(60) {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = std::fs::remove_file(path);
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        "OMG native SSH handoff timed out",
    ))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn routes_only_interactive_shells() {
        for args in [vec!["host"], vec!["-p", "2222", "-J", "jump", "user@host"]] {
            assert!(interactive(
                &args.into_iter().map(String::from).collect::<Vec<_>>()
            ));
        }
        for args in [
            vec!["host", "ls"],
            vec!["-N", "host"],
            vec!["-L", "80:x:80", "host"],
            vec!["-T", "host"],
            vec!["-o", "RemoteCommand=ls", "host"],
        ] {
            assert!(!interactive(
                &args.into_iter().map(String::from).collect::<Vec<_>>()
            ));
        }
    }
}
