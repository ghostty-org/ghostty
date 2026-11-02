//! A terminal-byte viewer for a managed remote PTY inside an existing local PTY.
//! The viewer owns no AppKit window and never replaces its calling local shell.

use crate::{Frame, Vt};
use base64::Engine;
use serde::Deserialize;
use serde_json::Value;
use std::{
    ffi::c_void,
    io::{self, Read, Write},
    net::Shutdown,
    os::fd::AsRawFd,
    os::unix::net::UnixStream,
    path::Path,
    sync::{
        atomic::{AtomicI32, Ordering},
        mpsc,
    },
    time::Duration,
};

static INTERRUPTED: AtomicI32 = AtomicI32::new(0);
static WAKE: AtomicI32 = AtomicI32::new(-1);
extern "C" fn interrupted(signal: i32) {
    if signal != libc::SIGWINCH {
        INTERRUPTED.store(signal, Ordering::Relaxed);
    }
    let fd = WAKE.load(Ordering::Relaxed);
    if fd >= 0 {
        unsafe {
            libc::write(fd, [1u8].as_ptr().cast(), 1);
        }
    }
}

struct Signals(Vec<(i32, libc::sighandler_t)>);
impl Signals {
    fn install(wake: i32) -> Self {
        INTERRUPTED.store(0, Ordering::Relaxed);
        WAKE.store(wake, Ordering::Relaxed);
        Self(
            [libc::SIGINT, libc::SIGTERM, libc::SIGHUP, libc::SIGWINCH]
                .into_iter()
                .map(|signal| {
                    (signal, unsafe {
                        libc::signal(signal, interrupted as *const () as libc::sighandler_t)
                    })
                })
                .collect(),
        )
    }
}
impl Drop for Signals {
    fn drop(&mut self) {
        WAKE.store(-1, Ordering::Relaxed);
        for &(signal, previous) in &self.0 {
            unsafe {
                libc::signal(signal, previous);
            }
        }
    }
}

struct RawMode(libc::termios);
impl RawMode {
    fn enter() -> io::Result<Self> {
        let mut original = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(0, &mut original) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let mut raw = original;
        unsafe {
            libc::cfmakeraw(&mut raw);
        }
        if unsafe { libc::tcsetattr(0, libc::TCSAFLUSH, &raw) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self(original))
    }
}
impl Drop for RawMode {
    fn drop(&mut self) {
        unsafe {
            libc::tcsetattr(0, libc::TCSAFLUSH, &self.0);
        }
    }
}

fn dimensions() -> [u8; 8] {
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    unsafe {
        libc::ioctl(0, libc::TIOCGWINSZ, &mut size);
    }
    let cols = size.ws_col.clamp(1, 500);
    let rows = size.ws_row.clamp(1, 300);
    let mut bytes = [0; 8];
    bytes[..2].copy_from_slice(&cols.to_be_bytes());
    bytes[2..4].copy_from_slice(&rows.to_be_bytes());
    bytes[4..6].copy_from_slice(&size.ws_xpixel.min(16_000).to_be_bytes());
    bytes[6..].copy_from_slice(&size.ws_ypixel.min(16_000).to_be_bytes());
    bytes
}

fn encoded(value: &str) -> String {
    value
        .bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-_./~".contains(&b) {
                char::from(b).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

#[derive(Deserialize)]
pub struct Context {
    pub connection_id: String,
    pub target: String,
    pub local_cwd: String,
    #[serde(default)]
    pub active_record: Option<std::path::PathBuf>,
    #[serde(default)]
    pub owner_record: Option<std::path::PathBuf>,
}

fn persist_record(session: &Context, fields: &[(&str, Value)]) -> io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let Some(path) = &session.active_record else {
        return Ok(());
    };
    let mut value: Value = serde_json::from_slice(&crate::handoff::read_private(path)?)?;
    if value["connectionID"] != session.connection_id
        || fields.iter().all(|(key, next)| value[*key] == *next)
    {
        return Ok(());
    }
    for (key, next) in fields {
        value[*key] = next.clone();
    }
    let temporary = path.with_extension(format!("{}.tmp", crate::record::nonce()?));
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(&serde_json::to_vec(&value)?)?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temporary);
    }
    result
}

pub(crate) fn forget_context(session: &Context) {
    for path in [&session.active_record, &session.owner_record]
        .into_iter()
        .flatten()
    {
        if let Ok(bytes) = crate::handoff::read_private(path) {
            if let Ok(value) = serde_json::from_slice::<Value>(&bytes) {
                if value["connectionID"] == session.connection_id {
                    let _ = std::fs::remove_file(path);
                }
            }
        }
    }
}

pub(crate) fn end_context(session: &Context, status: i32) {
    let _ = io::stdout().write_all(&context(session, None, Some(status)));
    let _ = io::stdout().flush();
}

fn context(context: &Context, cwd: Option<&str>, status: Option<i32>) -> Vec<u8> {
    if let Some(status) = status {
        format!(
            "\x1b]3008;end={};status={status};cwd={}\x07",
            context.connection_id,
            encoded(&context.local_cwd)
        )
        .into_bytes()
    } else {
        format!(
            "\x1b]3008;start={};type=remote;targethost={};localcwd={}{}\x07",
            context.connection_id,
            context.target,
            encoded(&context.local_cwd),
            cwd.map(|s| format!(";cwd={}", encoded(s)))
                .unwrap_or_default()
        )
        .into_bytes()
    }
}

// Adapted from herdr-core's attach RESET. Reset both screens' input modes
// before the original local shell regains its terminal.
const RESET: &[u8] = b"\x18\x1b[?2026l\x1b[?1049h\x1b[=0;1u\x1b[?1049l\x1b[?1047l\x1b[?47l\x1b[=0;1u\x1b[>4;0m\
\x1b7\x1b[4l\x1b[20l\x1b[?1l\x1b[?5l\x1b[?6l\x1b[?66l\x1b[?67l\x1b[?69l\x1b[?9l\x1b[?1000l\x1b[?1001l\x1b[?1002l\
\x1b[?1003l\x1b[?1004l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l\x1b[?2004l\x1b[?2031l\x1b[?2033l\
\x1b[?2048l\x1b[?7h\x1b[?25h\x1b[?1007h\x1b[r\x1b8\x1b[0 q\x1b(B\x1b[0m\
\x1b]104\x1b\\\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\\x1b]22;\x1b\\\r\n";

/// The local PTY (not the GUI) owns this blocking viewer. Transport reconnects
/// retain its socket and discard input until the new writer generation is ready.
pub fn view(path: &Path, open: Value, session: &Context) -> io::Result<i32> {
    let (mut wake_read, mut wake_write) = UnixStream::pair()?;
    wake_read.set_nonblocking(true)?;
    wake_write.set_nonblocking(true)?;
    let signal_wake = wake_write.try_clone()?;
    let _signals = Signals::install(signal_wake.as_raw_fd());
    let mut socket = UnixStream::connect(path)?;
    socket.set_write_timeout(Some(Duration::from_secs(2)))?;
    Frame::new(b'H', 0, serde_json::to_vec(&open)?.as_slice()).send(&mut socket)?;
    let mut reader = socket.try_clone()?;
    let (tx, rx) = mpsc::sync_channel(2);
    let worker = std::thread::spawn(move || loop {
        let result = Frame::read(&mut reader);
        let done = result.is_err();
        if tx.send(result).is_err() {
            break;
        }
        let _ = wake_write.write(&[1]);
        if done {
            break;
        }
    });
    let result = view_loop(&mut socket, &rx, &mut wake_read, session);
    let _ = socket.shutdown(Shutdown::Both);
    drop(rx);
    let _ = worker.join();
    let mut stdout = io::stdout().lock();
    let _ = stdout.write_all(RESET);
    let _ = stdout.write_all(&context(
        session,
        None,
        Some(result.as_ref().copied().unwrap_or(255)),
    ));
    let _ = stdout.flush();
    result
}

fn view_loop(
    socket: &mut UnixStream,
    rx: &mpsc::Receiver<io::Result<Frame>>,
    wake: &mut UnixStream,
    session: &Context,
) -> io::Result<i32> {
    let mut generation = 0;
    let mut sequence = None;
    let mut ready = false;
    let mut raw = None;
    let mut first_picture = true;
    let mut initial_output = None;
    let mut password_input = false;
    let mut pending_password = None;
    let mut pending_cwd = None;
    let mut pending_output = Vec::new();
    let mut size = dimensions();
    let mut screen = Screen::new(
        u16::from_be_bytes([size[0], size[1]]),
        u16::from_be_bytes([size[2], size[3]]),
    )?;
    let mut stdout = io::stdout().lock();
    stdout.write_all(&context(session, None, None))?;
    stdout.flush()?;
    loop {
        let signal = INTERRUPTED.load(Ordering::Relaxed);
        if signal != 0 {
            return Ok(128 + signal);
        }
        for _ in 0..32 {
            let frame = match rx.try_recv() {
                Ok(frame) => frame?,
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => {
                    return Err(io::ErrorKind::UnexpectedEof.into())
                }
            };
            match frame.kind {
                b'T' => {
                    let status: Value = serde_json::from_slice(&frame.data)?;
                    generation = frame.seq;
                    ready = false;
                    sequence = None;
                    pending_password = Some(false);
                    pending_output.clear();
                    persist_record(
                        session,
                        &[
                            ("phase", status["state"].clone()),
                            ("attachmentGeneration", Value::from(generation)),
                            ("passwordInput", Value::Bool(false)),
                        ],
                    )?;
                    if status["state"] == "attention" {
                        return Err(io::Error::other(
                            status["message"]
                                .as_str()
                                .unwrap_or("SSH connection needs attention"),
                        ));
                    }
                }
                b'J' => {
                    let info: Value = serde_json::from_slice(&frame.data)?;
                    if info["inline_viewer"] != true {
                        return Err(io::Error::other(
                            "host did not enable inline terminal replies",
                        ));
                    }
                    initial_output = info["initial_output"]
                        .as_str()
                        .filter(|s| s.len() <= 12 * 1024)
                        .and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok());
                }
                b'S' => {
                    if first_picture && initial_output.is_some() {
                        screen = Screen::new(
                            u16::from_be_bytes([size[0], size[1]]),
                            u16::from_be_bytes([size[2], size[3]]),
                        )?;
                        pending_output = initial_output.take().unwrap();
                        screen.write(&pending_output);
                    } else {
                        screen.restore(&frame.data)?;
                        let current = dimensions();
                        pending_output =
                            screen.repaint(Some(u16::from_be_bytes([current[2], current[3]])))?;
                        pending_output.extend(screen.continuation()?);
                    }
                    screen.take_responses();
                    first_picture = false;
                    ready = false;
                    sequence = Some(frame.seq);
                    Frame::new(b'A', frame.seq, &generation.to_be_bytes()).send(socket)?;
                    Frame::new(b'W', generation, b"inline/1").send(socket)?;
                }
                b'W' if frame.seq == generation && sequence.is_some() => {
                    if raw.is_none() {
                        raw = Some(RawMode::enter()?);
                    } else {
                        // The outer PTY can still contain keys typed while this
                        // remote generation was unavailable.
                        unsafe {
                            libc::tcflush(0, libc::TCIFLUSH);
                        }
                    }
                    ready = true;
                    stdout.write_all(&pending_output)?;
                    pending_output.clear();
                    persist_record(
                        session,
                        &[
                            ("phase", Value::String("ready".into())),
                            ("attachmentGeneration", Value::from(generation)),
                        ],
                    )?;
                    size = dimensions();
                    Frame::new(b'R', generation, &size).send(socket)?;
                }
                b'O' => {
                    let previous = sequence.ok_or_else(|| {
                        io::Error::other("SSH output arrived before its snapshot")
                    })?;
                    if frame.seq != previous + frame.data.len() as u64 {
                        return Err(io::Error::other("SSH output sequence gap"));
                    }
                    screen.write(&frame.data);
                    if ready {
                        stdout.write_all(&frame.data)?;
                    } else {
                        if pending_output.len() + frame.data.len() > crate::MAX_QUEUE {
                            return Err(io::Error::other(
                                "inline presentation queue exceeded its limit",
                            ));
                        }
                        pending_output.extend_from_slice(&frame.data);
                    }
                    screen.take_responses();
                    sequence = Some(frame.seq);
                }
                b'R' if frame.data.len() == 4 || frame.data.len() == 8 => {
                    screen.vt.resize(
                        u16::from_be_bytes([frame.data[0], frame.data[1]]),
                        u16::from_be_bytes([frame.data[2], frame.data[3]]),
                    )?;
                    screen.take_responses();
                }
                b'M' => {
                    let metadata: Value = serde_json::from_slice(&frame.data)?;
                    let password = metadata["password_input"].as_bool().unwrap_or(false);
                    persist_record(session, &[("passwordInput", Value::Bool(password))])?;
                    pending_password = Some(password);
                    if let Some(cwd) = metadata["cwd"]
                        .as_str()
                        .filter(|s| s.starts_with('/') && s.len() <= 4096)
                    {
                        persist_record(
                            session,
                            &[("workingDirectory", Value::String(cwd.into()))],
                        )?;
                        pending_cwd = Some(cwd.to_owned());
                    }
                }
                b'X' => {
                    if !pending_output.is_empty() {
                        let mut ended = Screen::new(80, 24)?;
                        let mut filter = crate::terminal_output::Relay::default();
                        stdout.write_all(&filter.feed(&mut ended, &pending_output))?;
                        stdout.flush()?;
                    }
                    return std::str::from_utf8(&frame.data)
                        .ok()
                        .and_then(|s| s.parse().ok())
                        .ok_or_else(|| io::Error::other("invalid remote exit status"));
                }
                b'E' | b'B' => {
                    return Err(io::Error::other(
                        String::from_utf8_lossy(&frame.data).into_owned(),
                    ))
                }
                _ => {}
            }
            // Do not splice host metadata into a split CSI/OSC/image sequence.
            if ready && screen.continuation().is_ok_and(|bytes| bytes.is_empty()) {
                if let Some(password) = pending_password.take() {
                    if password != password_input {
                        stdout.write_all(if password {
                            b"\x1b]3008;start=omg-inline-password;1\x07"
                        } else {
                            b"\x1b]3008;start=omg-inline-password;0\x07"
                        })?;
                        password_input = password;
                    }
                }
                if let Some(cwd) = pending_cwd.take() {
                    stdout.write_all(&context(session, Some(&cwd), None))?;
                }
            }
            stdout.flush()?;
        }
        if ready {
            let current = dimensions();
            if size != current {
                size = current;
                Frame::new(b'R', generation, &size).send(socket)?;
            }
        }
        // Before writer acquisition, SSH itself owns the cooked controlling
        // terminal for authentication. Afterward drop disconnected input.
        let mut fds = [
            libc::pollfd {
                fd: if raw.is_some() { 0 } else { -1 },
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: wake.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        let count = unsafe { libc::poll(fds.as_mut_ptr(), 2, 500) };
        if count > 0 {
            if fds[1].revents & libc::POLLIN != 0 {
                let _ = wake.read(&mut [0; 256]);
            }
            if fds[0].revents & libc::POLLIN != 0 {
                let mut bytes = [0; 8192];
                let len = io::stdin().read(&mut bytes)?;
                if len == 0 {
                    return Ok(0);
                }
                if ready {
                    Frame::new(b'I', generation, &bytes[..len]).send(socket)?;
                } else if bytes[..len].contains(&3) {
                    return Ok(130);
                }
            }
            if fds[0].revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
                return Ok(0);
            }
        }
    }
}

struct Screen {
    vt: Vt,
    // The C callback keeps a pointer to the Vec header while Screen can move.
    #[allow(clippy::box_collection)]
    replies: Box<Vec<u8>>,
}

extern "C" fn response(context: *mut c_void, data: *const u8, len: usize) {
    let replies = unsafe { &mut *context.cast::<Vec<u8>>() };
    // Queries are bounded; a broken peer must not grow this capture indefinitely.
    if len <= 64 * 1024 - replies.len() {
        replies.extend_from_slice(unsafe { std::slice::from_raw_parts(data, len) });
    }
}

impl Screen {
    fn new(cols: u16, rows: u16) -> io::Result<Self> {
        let mut replies = Box::new(Vec::new());
        let vt = Vt::with_reply_pixels_scrollback(
            cols,
            rows,
            cols.saturating_mul(8),
            rows.saturating_mul(16),
            crate::ScrollbackLimits {
                max_bytes: 0,
                max_lines: Some(0),
            },
            Some(response),
            (&mut *replies as *mut Vec<u8>).cast(),
        )?;
        Ok(Self { vt, replies })
    }

    fn write(&mut self, bytes: &[u8]) {
        self.vt.write(bytes);
    }
    fn restore(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.vt.restore(bytes)?;
        // The outer managed terminal owns scrollback; the query mirror needs
        // only the active screen, even when a reconnect snapshot has history.
        crate::check(unsafe { crate::omg_vt_screen_only(self.vt.0) })
    }
    fn take_responses(&mut self) -> Vec<u8> {
        std::mem::take(&mut *self.replies)
    }
    fn continuation(&self) -> io::Result<Vec<u8>> {
        let mut data = std::ptr::null_mut();
        let mut len = 0;
        crate::check(unsafe { crate::omg_vt_continuation(self.vt.0, &mut data, &mut len) })?;
        let bytes = if len == 0 {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(data, len).to_vec() }
        };
        unsafe { crate::omg_vt_buffer_free(data, len) };
        Ok(bytes)
    }

    // Mode reset and active-screen filtering follow herdr-core's Terminal::paint.
    // See LICENSE.herdr and THIRD-PARTY-NOTICES.
    fn repaint(&self, preserve_rows: Option<u16>) -> io::Result<Vec<u8>> {
        let mut data = std::ptr::null_mut();
        let mut len = 0;
        let mut alternate = false;
        crate::check(unsafe {
            crate::omg_vt_paint(self.vt.0, &mut data, &mut len, &mut alternate)
        })?;
        let bytes = if len == 0 {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(data, len).to_vec() }
        };
        unsafe { crate::omg_vt_buffer_free(data, len) };
        let mut out = b"\x18\x1b[!p\x1b[?2026l\x1b[?2026h\x1b[?9l\x1b[?1000l\x1b[?1001l\x1b[?1002l\x1b[?1003l\
\x1b[?1004l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l\x1b[?2004l\x1b[?1l\
\x1b[?66l\x1b[?2031l\x1b[?2048l\x1b[=0;1u\x1b[?1049l\x1b[?1047l\x1b[?47l"
            .to_vec();
        if let Some(rows) = preserve_rows {
            // Retain the local prefix in outer scrollback before a reconnect
            // replaces the remote viewport. The whole repaint is synchronized.
            out.extend_from_slice(b"\x1b[?6l\x1b[?69l\x1b[r\x1b[999;1H");
            for _ in 0..rows {
                out.extend_from_slice(b"\r\n");
            }
        }
        out.extend_from_slice(b"\x1b[H\x1b[2J");
        out.extend_from_slice(b"\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\");
        for index in 0..3 {
            let mut rgb = [0; 3];
            if unsafe { crate::omg_vt_dynamic_color(self.vt.0, index, rgb.as_mut_ptr()) } == 0 {
                out.extend_from_slice(
                    format!(
                        "\x1b]{};rgb:{:02x}/{:02x}/{:02x}\x1b\\",
                        index + 10,
                        rgb[0],
                        rgb[1],
                        rgb[2]
                    )
                    .as_bytes(),
                );
            }
        }
        if alternate {
            out.extend_from_slice(b"\x1b[?1049h");
        }
        let skip: &[&[u8]] = &[b"\x1b[?2026h", b"\x1b[?47h", b"\x1b[?1047h", b"\x1b[?1049h"];
        let mut at = 0;
        while at < bytes.len() {
            if let Some(sequence) = skip.iter().find(|s| bytes[at..].starts_with(s)) {
                at += sequence.len();
            } else {
                out.push(bytes[at]);
                at += 1;
            }
        }
        out.extend_from_slice(b"\x1b[?2026l");
        Ok(out)
    }
}

impl crate::terminal_output::Screen for Screen {
    fn write(&mut self, bytes: &[u8]) {
        self.vt.write(bytes);
    }
    fn pending_responses(&self) -> usize {
        self.replies.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_filter_preserves_output_and_does_not_duplicate_authoritative_replies() {
        let mut screen = Screen::new(80, 24).unwrap();
        let mut relay = crate::terminal_output::Relay::default();
        let input = b"hello\x1b[31mred\x1b[0m\x1b[6n\x1b]2;remote\x07";
        let output: Vec<u8> = input
            .iter()
            .flat_map(|b| relay.feed(&mut screen, &[*b]))
            .collect();
        assert_eq!(output, b"hello\x1b[31mred\x1b[0m\x1b]2;remote\x07");
        assert!(!screen.take_responses().is_empty());
    }

    #[test]
    fn snapshot_restore_keeps_reply_capture_and_repaints_terminal_modes() {
        let mut original = Vt::new(20, 4).unwrap();
        original.write(b"\x1b[?1049hremote\x1b[?2004h");
        let mut screen = Screen::new(20, 4).unwrap();
        screen.restore(&original.snapshot().unwrap()).unwrap();
        assert_eq!(screen.vt.scrollback_limits().unwrap(), (0, Some(0)));
        screen.write(b"\x1b[6n");
        assert!(!screen.take_responses().is_empty());
        let mut target = Vt::new(20, 4).unwrap();
        target.write(&screen.repaint(None).unwrap());
        assert!(target.text().unwrap().contains("remote"));
        assert!(screen.continuation().unwrap().is_empty());
    }

    #[test]
    fn repaint_restores_program_colors_without_inventing_black_theme_defaults() {
        let mut screen = Screen::new(20, 4).unwrap();
        let plain = screen.repaint(None).unwrap();
        let prefix = b"]11;rgb:";
        assert!(!plain.windows(prefix.len()).any(|s| s == prefix));
        screen.write(b"\x1b]11;rgb:11/22/33\x1b\\");
        let styled = screen.repaint(None).unwrap();
        let color = b"]11;rgb:11/22/33\x1b\\";
        assert!(styled.windows(color.len()).any(|s| s == color));
    }
}
