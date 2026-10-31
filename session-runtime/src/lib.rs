//! Experimental Unix-socket vertical slice. One durable session per daemon.
//! All PTY/VT/attachment mutation is serialized by the server loop.
use std::{
    collections::VecDeque,
    ffi::c_void,
    io::{self, Read, Write},
    os::unix::net::UnixStream,
};
pub const MAX_FRAME: usize = 16 * 1024 * 1024 + 13; // envelope includes one inner frame
pub const MAX_QUEUE: usize = 32 * 1024 * 1024;
pub const SNAPSHOT: u8 = b'S';
pub const OUTPUT: u8 = b'O';
pub const INPUT: u8 = b'I';
pub const RESIZE: u8 = b'R';
pub const INFO: u8 = b'J';
pub const ACK: u8 = b'A';
pub mod containment;
pub mod supervision;
pub const CLOSE: u8 = b'K';
pub const EXIT: u8 = b'X';
pub const CLAIM: u8 = b'W';
pub mod client;
unsafe extern "C" {
    fn omg_vt_new(
        cols: u16,
        rows: u16,
        reply: Option<extern "C" fn(*mut c_void, *const u8, usize)>,
        context: *mut c_void,
    ) -> *mut c_void;
    fn omg_vt_free(vt: *mut c_void);
    fn omg_vt_write(vt: *mut c_void, data: *const u8, len: usize);
    fn omg_vt_resize(vt: *mut c_void, cols: u16, rows: u16) -> i32;
    fn omg_vt_snapshot(vt: *mut c_void, data: *mut *mut u8, len: *mut usize) -> i32;
    fn omg_vt_restore(vt: *mut c_void, data: *const u8, len: usize) -> i32;
    fn omg_vt_text(vt: *mut c_void, data: *mut *mut u8, len: *mut usize) -> i32;
    fn omg_vt_buffer_free(data: *mut u8, len: usize);
}
pub struct Vt(*mut c_void);
impl Vt {
    pub fn new(cols: u16, rows: u16) -> io::Result<Self> {
        Self::with_reply(cols, rows, None, std::ptr::null_mut())
    }
    pub(crate) fn with_reply(
        cols: u16,
        rows: u16,
        reply: Option<extern "C" fn(*mut c_void, *const u8, usize)>,
        context: *mut c_void,
    ) -> io::Result<Self> {
        let p = unsafe { omg_vt_new(cols, rows, reply, context) };
        if p.is_null() {
            Err(io::Error::other("VT allocation failed"))
        } else {
            Ok(Self(p))
        }
    }
    pub fn write(&mut self, data: &[u8]) {
        unsafe { omg_vt_write(self.0, data.as_ptr(), data.len()) }
    }
    pub fn resize(&mut self, cols: u16, rows: u16) -> io::Result<()> {
        check(unsafe { omg_vt_resize(self.0, cols, rows) })
    }
    pub fn restore(&mut self, data: &[u8]) -> io::Result<()> {
        check(unsafe { omg_vt_restore(self.0, data.as_ptr(), data.len()) })
    }
    fn bytes(&self, text: bool) -> io::Result<Vec<u8>> {
        let mut p = std::ptr::null_mut();
        let mut len = 0;
        check(unsafe {
            if text {
                omg_vt_text(self.0, &mut p, &mut len)
            } else {
                omg_vt_snapshot(self.0, &mut p, &mut len)
            }
        })?;
        let bytes = unsafe { std::slice::from_raw_parts(p, len).to_vec() };
        unsafe { omg_vt_buffer_free(p, len) };
        Ok(bytes)
    }
    pub fn snapshot(&self) -> io::Result<Vec<u8>> {
        self.bytes(false)
    }
    pub fn text(&self) -> io::Result<String> {
        Ok(String::from_utf8_lossy(&self.bytes(true)?).into_owned())
    }
}
impl Drop for Vt {
    fn drop(&mut self) {
        unsafe { omg_vt_free(self.0) }
    }
}
fn check(code: i32) -> io::Result<()> {
    if code == 0 {
        Ok(())
    } else {
        Err(io::Error::other(format!("VT error {code}")))
    }
}
#[derive(Debug)]
pub struct Frame {
    pub kind: u8,
    pub seq: u64,
    pub data: Vec<u8>,
}
impl Frame {
    pub fn new(kind: u8, seq: u64, data: &[u8]) -> Self {
        Self {
            kind,
            seq,
            data: data.to_vec(),
        }
    }
    pub fn encode(&self) -> Vec<u8> {
        let mut out = vec![self.kind];
        out.extend(self.seq.to_be_bytes());
        out.extend((self.data.len() as u32).to_be_bytes());
        out.extend(&self.data);
        out
    }
    pub fn read(r: &mut impl Read) -> io::Result<Self> {
        let mut h = [0; 13];
        r.read_exact(&mut h)?;
        let len = u32::from_be_bytes(h[9..13].try_into().unwrap()) as usize;
        if len > MAX_FRAME {
            return Err(io::Error::other("frame too large"));
        }
        let mut data = vec![0; len];
        r.read_exact(&mut data)?;
        Ok(Self {
            kind: h[0],
            seq: u64::from_be_bytes(h[1..9].try_into().unwrap()),
            data,
        })
    }
    pub fn send(&self, w: &mut impl Write) -> io::Result<()> {
        w.write_all(&self.encode())
    }
}
pub(crate) struct Peer {
    pub socket: UnixStream,
    pub incoming: Vec<u8>,
    pub queue: VecDeque<Vec<u8>>,
    pub queued: usize,
    pub offset: usize,
    pub ack: Option<u64>,
    pub dead: bool,
    pub id: u64,
}
impl Peer {
    pub fn new(socket: UnixStream, id: u64) -> io::Result<Self> {
        socket.set_nonblocking(true)?;
        Ok(Self {
            socket,
            incoming: vec![],
            queue: VecDeque::new(),
            queued: 0,
            offset: 0,
            ack: None,
            dead: false,
            id,
        })
    }
    pub fn push(&mut self, f: Frame) {
        let b = f.encode();
        if b.len() + self.queued > MAX_QUEUE {
            self.dead = true;
            return;
        }
        self.queued += b.len();
        self.queue.push_back(b);
    }
    pub fn flush(&mut self) -> io::Result<()> {
        // Bound work per peer, preserving fairness for PTY draining.
        let mut budget = 256 * 1024;
        while let Some(front) = self.queue.front() {
            if budget == 0 {
                break;
            }
            // Snapshot and metadata may leave before ACK; live data waits.
            if self.ack.is_some() && matches!(front[0], OUTPUT | RESIZE | EXIT | b'M') {
                break;
            }
            let end = front.len().min(self.offset + budget);
            match self.socket.write(&front[self.offset..end]) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(n) => {
                    self.offset += n;
                    self.queued -= n;
                    budget -= n;
                    if self.offset == front.len() {
                        self.queue.pop_front();
                        self.offset = 0;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }
    pub fn read(&mut self) -> io::Result<Vec<Frame>> {
        let mut b = [0; 16384];
        match self.socket.read(&mut b) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(n) => self.incoming.extend(&b[..n]),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
            Err(e) => return Err(e),
        }
        let mut out = vec![];
        while self.incoming.len() >= 13 {
            let len = u32::from_be_bytes(self.incoming[9..13].try_into().unwrap()) as usize;
            if len > MAX_FRAME {
                return Err(io::Error::other("frame too large"));
            }
            if self.incoming.len() < 13 + len {
                break;
            }
            out.push(Frame::read(&mut &self.incoming[..13 + len])?);
            self.incoming.drain(..13 + len);
        }
        if self.incoming.len() > MAX_FRAME + 12 {
            return Err(io::Error::other("input too large"));
        }
        Ok(out)
    }
}
pub mod deploy;
pub mod handoff;
pub mod host;
pub mod lifecycle;
pub mod location;
pub mod record;
pub mod registry;
pub mod server;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn slow_peer_is_bounded_and_snapshot_ack_gates_live_output() {
        let (socket, mut remote) = UnixStream::pair().unwrap();
        remote
            .set_read_timeout(Some(std::time::Duration::from_millis(30)))
            .unwrap();
        let mut peer = Peer::new(socket, 1).unwrap();
        peer.ack = Some(7);
        peer.push(Frame::new(SNAPSHOT, 7, b"snapshot"));
        peer.push(Frame::new(OUTPUT, 8, b"x"));
        peer.flush().unwrap();
        assert_eq!(Frame::read(&mut remote).unwrap().kind, SNAPSHOT);
        assert!(Frame::read(&mut remote).is_err());
        peer.ack = None;
        peer.flush().unwrap();
        assert_eq!(Frame::read(&mut remote).unwrap().data, b"x");
        let chunk = vec![0; 65536];
        for _ in 0..1024 {
            peer.push(Frame::new(OUTPUT, 0, &chunk));
            if peer.dead {
                break;
            }
        }
        assert!(peer.dead);
        assert!(peer.queued <= MAX_QUEUE);
    }

    #[test]
    fn read_accepts_maximum_frame_followed_by_another_frame() {
        let (socket, mut remote) = UnixStream::pair().unwrap();
        let mut peer = Peer::new(socket, 1).unwrap();
        let large = Frame::new(b'X', 1, &vec![b'x'; MAX_FRAME]).encode();
        let small = Frame::new(b'Y', 2, b"next").encode();
        let split = large.len() - 8;
        peer.incoming.extend_from_slice(&large[..split]);
        assert!(peer.read().unwrap().is_empty());
        remote.write_all(&large[split..]).unwrap();
        remote.write_all(&small).unwrap();

        let frames = peer.read().unwrap();
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].data.len(), MAX_FRAME);
        assert_eq!(frames[1].data, b"next");
    }

    #[test]
    fn read_rejects_a_frame_above_the_limit_before_reading_its_body() {
        let (socket, mut remote) = UnixStream::pair().unwrap();
        let mut peer = Peer::new(socket, 1).unwrap();
        let header = [b'X']
            .into_iter()
            .chain(0u64.to_be_bytes())
            .chain(((MAX_FRAME + 1) as u32).to_be_bytes())
            .collect::<Vec<_>>();
        remote.write_all(&header).unwrap();

        assert!(peer.read().is_err());
    }
}
