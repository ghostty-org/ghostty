//! macOS-only detachment of persistent local hosts from the app coalition.
//! A child of the GUI stays in its coalition after `setsid`, so LaunchServices
//! reports the quit app as still running in the background. A transient
//! launchd job starts `omgd detach`, which forks the host into its own session,
//! reports its pid and exits; the job is then removed and the host remains.
use std::{
    io,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

const READY_TIMEOUT: Duration = Duration::from_secs(10);

pub fn escape(value: &str) -> io::Result<String> {
    if value
        .chars()
        .any(|c| c.is_control() && c != '\t' && c != '\n')
    {
        return Err(io::Error::other(
            "launchd value contains a control character",
        ));
    }
    Ok(value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;"))
}

pub struct Job<'a> {
    pub label: &'a str,
    pub arguments: &'a [String],
    pub environment: &'a [(String, String)],
    pub working_directory: &'a Path,
    pub log: &'a Path,
    pub umask: u32,
}

pub fn plist(job: &Job<'_>) -> io::Result<String> {
    let mut out = String::from(concat!(
        r#"<?xml version="1.0" encoding="UTF-8"?>"#,
        "\n",
        r#"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#,
        "\n<plist version=\"1.0\"><dict>\n"
    ));
    let string = |key: &str, value: &str| -> io::Result<String> {
        Ok(format!(
            "<key>{key}</key><string>{}</string>\n",
            escape(value)?
        ))
    };
    out += &string("Label", job.label)?;
    out += "<key>ProgramArguments</key><array>\n";
    for argument in job.arguments {
        out += &format!("<string>{}</string>\n", escape(argument)?);
    }
    out += "</array>\n<key>EnvironmentVariables</key><dict>\n";
    for (key, value) in job.environment {
        out += &format!(
            "<key>{}</key><string>{}</string>\n",
            escape(key)?,
            escape(value)?
        );
    }
    out += "</dict>\n";
    fn path(p: &Path) -> io::Result<&str> {
        p.to_str()
            .ok_or_else(|| io::Error::other("launchd path is not UTF-8"))
    }
    out += &string("WorkingDirectory", path(job.working_directory)?)?;
    out += &string("StandardInPath", "/dev/null")?;
    out += &string("StandardOutPath", path(job.log)?)?;
    out += &string("StandardErrorPath", path(job.log)?)?;
    out += "<key>RunAtLoad</key><true/>\n<key>KeepAlive</key><false/>\n";
    out += "<key>AbandonProcessGroup</key><true/>\n";
    out += &string("ProcessType", "Interactive")?;
    out += &format!("<key>Umask</key><integer>{}</integer>\n", job.umask);
    out += "</dict></plist>\n";
    Ok(out)
}

/// Environment passed to the detached host. launchd jobs otherwise start with
/// a minimal environment; the login shell must see the app's PATH/LANG/etc.
/// XPC_SERVICE_NAME would attribute the process to the app's launchd job.
pub fn environment(vars: impl Iterator<Item = (String, String)>) -> Vec<(String, String)> {
    let mut vars: Vec<_> = vars
        .filter(|(key, _)| key != "XPC_SERVICE_NAME" && !key.starts_with("__CF"))
        .filter(|(key, value)| escape(key).is_ok() && escape(value).is_ok())
        .collect();
    vars.sort();
    vars
}

fn launchctl(args: &[&str]) -> io::Result<bool> {
    Ok(std::process::Command::new("/bin/launchctl")
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()?
        .success())
}

/// Starts `command` outside the caller's coalition. Returns Ok(None) when the
/// GUI launchd domain is unavailable so callers can use direct startup.
pub fn spawn(helper: &Path, command: &[String], log: &Path) -> io::Result<Option<u32>> {
    if !cfg!(target_os = "macos") {
        return Ok(None);
    }
    let uid = unsafe { libc::getuid() };
    let domain = format!("gui/{uid}");
    let nonce = format!(
        "{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default()
    );
    let label = format!("com.jischeng.omg.host.{nonce}");
    let dir = PathBuf::from(format!("/tmp/omg-launchd-{uid}-{nonce}"));
    std::fs::create_dir(&dir)?;
    let cleanup = |dir: &Path| {
        let _ = std::fs::remove_dir_all(dir);
    };
    let ready = dir.join("ready");
    let mut arguments = vec![
        helper.to_string_lossy().into_owned(),
        "detach".into(),
        ready.to_string_lossy().into_owned(),
        "--".into(),
    ];
    arguments.extend(command.iter().cloned());
    let umask = unsafe {
        let current = libc::umask(0o077);
        libc::umask(current);
        current as u32
    };
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
    let job_plist = dir.join("job.plist");
    let env = environment(std::env::vars());
    let text = plist(&Job {
        label: &label,
        arguments: &arguments,
        environment: &env,
        working_directory: &cwd,
        log,
        umask,
    });
    let text = match text {
        Ok(text) => text,
        Err(error) => {
            cleanup(&dir);
            return Err(error);
        }
    };
    std::fs::write(&job_plist, text)?;
    let target = format!("{domain}/{label}");
    if !launchctl(&["bootstrap", &domain, &job_plist.to_string_lossy()]).unwrap_or(false) {
        cleanup(&dir);
        return Ok(None);
    }
    let deadline = Instant::now() + READY_TIMEOUT;
    let pid = loop {
        if let Some(pid) = std::fs::read_to_string(&ready)
            .ok()
            .and_then(|s| s.trim().parse::<u32>().ok())
        {
            break Some(pid);
        }
        if Instant::now() >= deadline {
            break None;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    // The job's own process has exited (or never detached); the forked host
    // lives in its own session and is not signalled by bootout.
    let _ = launchctl(&["bootout", &target]);
    cleanup(&dir);
    pid.map(Some)
        .ok_or_else(|| io::Error::other("launchd host did not complete the detach handshake"))
}

/// `omgd detach READY -- COMMAND...`: runs as the transient launchd job.
pub fn detach(ready: &Path, command: &[String]) -> io::Result<()> {
    use std::os::unix::process::CommandExt;
    let (program, args) = command
        .split_first()
        .ok_or_else(|| io::Error::other("missing detached command"))?;
    let mut child = std::process::Command::new(program);
    child.args(args);
    unsafe {
        child.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            libc::signal(libc::SIGHUP, libc::SIG_IGN);
            Ok(())
        });
    }
    let pid = child.spawn()?.id();
    let staging = ready.with_extension("tmp");
    std::fs::write(&staging, pid.to_string())?;
    std::fs::rename(&staging, ready)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plist_escapes_values_and_abandons_process_group() {
        let args = vec!["/a b/omgd".to_string(), "x<&>\"".to_string()];
        let env = vec![("K".to_string(), "v&w".to_string())];
        let text = plist(&Job {
            label: "l",
            arguments: &args,
            environment: &env,
            working_directory: Path::new("/"),
            log: Path::new("/tmp/h.log"),
            umask: 0o22,
        })
        .unwrap();
        assert!(text.contains("<string>x&lt;&amp;&gt;&quot;</string>"));
        assert!(text.contains("<key>K</key><string>v&amp;w</string>"));
        assert!(text.contains("<key>AbandonProcessGroup</key><true/>"));
        assert!(text.contains("<key>KeepAlive</key><false/>"));
        assert!(text.contains("<integer>18</integer>"));
    }

    #[test]
    fn rejects_control_characters() {
        assert!(escape("a\u{1}b").is_err());
    }

    #[test]
    fn environment_drops_app_job_attribution() {
        let env = environment(
            [
                ("XPC_SERVICE_NAME", "application.com.x"),
                ("__CFBundleIdentifier", "com.x"),
                ("PATH", "/bin"),
                ("BAD", "a\u{1}"),
            ]
            .into_iter()
            .map(|(k, v)| (k.to_string(), v.to_string())),
        );
        assert_eq!(env, vec![("PATH".to_string(), "/bin".to_string())]);
    }
}
