//! Shared framed transport and authoritative VT primitives.
//! Each session serializes PTY, VT and attachment mutation in its server loop.
use std::{
    collections::VecDeque,
    ffi::c_void,
    io::{self, Read, Write},
    os::unix::net::UnixStream,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, OnceLock,
    },
};
pub const MAX_FRAME: usize = 16 * 1024 * 1024 + 13; // envelope includes one inner frame
pub const MAX_QUEUE: usize = 32 * 1024 * 1024;
pub const MAX_PROCESS_PEER_BUFFER: usize = 128 * 1024 * 1024;
pub const DEFAULT_SCROLLBACK_MAX_BYTES: usize = 4 * 1024 * 1024;
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
pub mod holder;
unsafe extern "C" {
    fn omg_vt_new_with_pixels_scrollback(
        cols: u16,
        rows: u16,
        pixel_width: u16,
        pixel_height: u16,
        scrollback_max_bytes: usize,
        scrollback_max_lines: *const usize,
        reply: Option<extern "C" fn(*mut c_void, *const u8, usize)>,
        context: *mut c_void,
    ) -> *mut c_void;
    fn omg_vt_free(vt: *mut c_void);
    fn omg_vt_write(vt: *mut c_void, data: *const u8, len: usize);
    fn omg_vt_resize(vt: *mut c_void, cols: u16, rows: u16) -> i32;
    fn omg_vt_resize_pixels(
        vt: *mut c_void,
        cols: u16,
        rows: u16,
        pixel_width: u16,
        pixel_height: u16,
    ) -> i32;
    #[cfg(test)]
    fn omg_vt_scrollback_limits(
        vt: *mut c_void,
        scrollback_max_bytes: *mut usize,
        has_scrollback_max_lines: *mut bool,
        scrollback_max_lines: *mut usize,
    ) -> i32;
    fn omg_vt_snapshot(vt: *mut c_void, data: *mut *mut u8, len: *mut usize) -> i32;
    fn omg_vt_restore(vt: *mut c_void, data: *const u8, len: usize) -> i32;
    fn omg_vt_text(vt: *mut c_void, data: *mut *mut u8, len: *mut usize) -> i32;
    fn omg_vt_buffer_free(data: *mut u8, len: usize);
}
pub struct Vt(*mut c_void);
pub(crate) struct ScrollbackLimits {
    pub max_bytes: usize,
    pub max_lines: Option<usize>,
}

impl Vt {
    pub fn new(cols: u16, rows: u16) -> io::Result<Self> {
        Self::with_reply_pixels(
            cols,
            rows,
            cols.saturating_mul(8),
            rows.saturating_mul(16),
            None,
            std::ptr::null_mut(),
        )
    }
    pub(crate) fn with_reply_pixels(
        cols: u16,
        rows: u16,
        pixel_width: u16,
        pixel_height: u16,
        reply: Option<extern "C" fn(*mut c_void, *const u8, usize)>,
        context: *mut c_void,
    ) -> io::Result<Self> {
        Self::with_reply_pixels_scrollback(
            cols,
            rows,
            pixel_width,
            pixel_height,
            ScrollbackLimits {
                max_bytes: DEFAULT_SCROLLBACK_MAX_BYTES,
                max_lines: None,
            },
            reply,
            context,
        )
    }

    pub(crate) fn with_reply_pixels_scrollback(
        cols: u16,
        rows: u16,
        pixel_width: u16,
        pixel_height: u16,
        scrollback: ScrollbackLimits,
        reply: Option<extern "C" fn(*mut c_void, *const u8, usize)>,
        context: *mut c_void,
    ) -> io::Result<Self> {
        let lines = scrollback.max_lines;
        let lines_ptr = lines
            .as_ref()
            .map_or(std::ptr::null(), |value| value as *const usize);
        let p = unsafe {
            omg_vt_new_with_pixels_scrollback(
                cols,
                rows,
                pixel_width,
                pixel_height,
                scrollback.max_bytes,
                lines_ptr,
                reply,
                context,
            )
        };
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
    pub fn resize_pixels(
        &mut self,
        cols: u16,
        rows: u16,
        pixel_width: u16,
        pixel_height: u16,
    ) -> io::Result<()> {
        check(unsafe { omg_vt_resize_pixels(self.0, cols, rows, pixel_width, pixel_height) })
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

    #[cfg(test)]
    fn scrollback_limits(&self) -> io::Result<(usize, Option<usize>)> {
        let mut bytes = 0;
        let mut has_lines = false;
        let mut lines = 0;
        check(unsafe { omg_vt_scrollback_limits(self.0, &mut bytes, &mut has_lines, &mut lines) })?;
        Ok((bytes, has_lines.then_some(lines)))
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
pub struct PeerBufferBudget {
    used: AtomicUsize,
    limit: usize,
}

impl PeerBufferBudget {
    pub fn new(limit: usize) -> Self {
        Self {
            used: AtomicUsize::new(0),
            limit,
        }
    }

    fn try_reserve(&self, bytes: usize) -> bool {
        let mut current = self.used.load(Ordering::Relaxed);
        loop {
            let Some(next) = current.checked_add(bytes) else {
                return false;
            };
            if next > self.limit {
                return false;
            }
            match self.used.compare_exchange_weak(
                current,
                next,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => return true,
                Err(observed) => current = observed,
            }
        }
    }

    fn release(&self, bytes: usize) {
        let previous = self.used.fetch_sub(bytes, Ordering::Relaxed);
        debug_assert!(previous >= bytes);
    }

    #[cfg(test)]
    fn used(&self) -> usize {
        self.used.load(Ordering::Relaxed)
    }
}

static PROCESS_PEER_BUFFER_BUDGET: OnceLock<Arc<PeerBufferBudget>> = OnceLock::new();

fn process_peer_buffer_budget() -> Arc<PeerBufferBudget> {
    PROCESS_PEER_BUFFER_BUDGET
        .get_or_init(|| Arc::new(PeerBufferBudget::new(MAX_PROCESS_PEER_BUFFER)))
        .clone()
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
    buffer_budget: Arc<PeerBufferBudget>,
    queued_allocation: usize,
    incoming_allocation: usize,
}
impl Peer {
    pub fn new(socket: UnixStream, id: u64) -> io::Result<Self> {
        Self::new_with_budget(socket, id, process_peer_buffer_budget())
    }

    fn new_with_budget(
        socket: UnixStream,
        id: u64,
        buffer_budget: Arc<PeerBufferBudget>,
    ) -> io::Result<Self> {
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
            buffer_budget,
            queued_allocation: 0,
            incoming_allocation: 0,
        })
    }

    fn reserve_incoming(&mut self, additional: usize) -> io::Result<()> {
        let old_capacity = self.incoming.capacity();
        let new_length = self
            .incoming
            .len()
            .checked_add(additional)
            .ok_or_else(|| io::Error::other("peer input length overflow"))?;
        if new_length <= old_capacity {
            return Ok(());
        }
        let required = new_length - old_capacity;
        if !self.buffer_budget.try_reserve(required) {
            return Err(io::Error::other("process peer buffer budget exceeded"));
        }
        if self.incoming.try_reserve_exact(additional).is_err() {
            self.buffer_budget.release(required);
            return Err(io::Error::other("peer input allocation failed"));
        }
        let new_capacity = self.incoming.capacity();
        let delta = new_capacity - old_capacity;
        if delta > required && !self.buffer_budget.try_reserve(delta - required) {
            let existing = self.incoming_allocation;
            self.incoming = Vec::new();
            self.incoming_allocation = 0;
            self.buffer_budget.release(existing + required);
            return Err(io::Error::other("process peer buffer budget exceeded"));
        }
        if required > delta {
            self.buffer_budget.release(required - delta);
        }
        self.incoming_allocation += delta;
        Ok(())
    }

    pub fn push(&mut self, f: Frame) {
        let b = f.encode();
        let allocation = b.capacity();
        if b.len() + self.queued > MAX_QUEUE || !self.buffer_budget.try_reserve(allocation) {
            self.dead = true;
            return;
        }
        self.queued_allocation += allocation;
        self.queued += b.len();
        self.queue.push_back(b);
    }
    pub fn discard_queued_output(&mut self) {
        if self.offset == 0 {
            self.queue.clear();
            self.buffer_budget.release(self.queued_allocation);
            self.queued_allocation = 0;
            self.queued = 0;
            return;
        }
        let Some(front) = self.queue.pop_front() else {
            self.buffer_budget.release(self.queued_allocation);
            self.queued_allocation = 0;
            self.queued = 0;
            self.offset = 0;
            return;
        };
        let discarded_allocation = self.queue.iter().map(Vec::capacity).sum::<usize>();
        self.queue.clear();
        self.queued_allocation -= discarded_allocation;
        self.buffer_budget.release(discarded_allocation);
        self.queued = front.len().saturating_sub(self.offset);
        self.queue.push_back(front);
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
                        let allocation = front.capacity();
                        self.queue.pop_front();
                        self.offset = 0;
                        self.queued_allocation -= allocation;
                        self.buffer_budget.release(allocation);
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
            Ok(n) => {
                self.reserve_incoming(n)?;
                self.incoming.extend(&b[..n]);
            }
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
        if self.incoming.is_empty() && self.incoming.capacity() > 16 * 1024 {
            let allocation = self.incoming_allocation;
            self.incoming = Vec::new();
            self.incoming_allocation = 0;
            self.buffer_budget.release(allocation);
        } else if self.incoming.len() <= 16 * 1024 && self.incoming.capacity() > 16 * 1024 {
            let old_capacity = self.incoming.capacity();
            self.incoming.shrink_to_fit();
            let new_capacity = self.incoming.capacity();
            if new_capacity < old_capacity {
                self.incoming_allocation -= old_capacity - new_capacity;
                self.buffer_budget.release(old_capacity - new_capacity);
            }
        }
        Ok(out)
    }
}

impl Drop for Peer {
    fn drop(&mut self) {
        let allocation = self.queued_allocation + self.incoming_allocation;
        self.queue.clear();
        self.incoming = Vec::new();
        self.queued_allocation = 0;
        self.incoming_allocation = 0;
        self.buffer_budget.release(allocation);
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
    fn vt_scrollback_limits_keep_default_and_explicit_zero_semantics() {
        let default = Vt::new(80, 24).unwrap();
        assert_eq!(
            default.scrollback_limits().unwrap(),
            (DEFAULT_SCROLLBACK_MAX_BYTES, None)
        );

        let disabled = Vt::with_reply_pixels_scrollback(
            80,
            24,
            640,
            384,
            ScrollbackLimits {
                max_bytes: 0,
                max_lines: Some(0),
            },
            None,
            std::ptr::null_mut(),
        )
        .unwrap();
        assert_eq!(disabled.scrollback_limits().unwrap(), (0, Some(0)));
    }

    #[test]
    fn peer_queue_budget_is_shared_and_released_on_drop() {
        let budget = Arc::new(PeerBufferBudget::new(200));
        let (one, _one_remote) = UnixStream::pair().unwrap();
        let (two, _two_remote) = UnixStream::pair().unwrap();
        let (three, _three_remote) = UnixStream::pair().unwrap();
        let mut one = Peer::new_with_budget(one, 1, budget.clone()).unwrap();
        let mut two = Peer::new_with_budget(two, 2, budget.clone()).unwrap();
        let mut three = Peer::new_with_budget(three, 3, budget.clone()).unwrap();
        let frame = || Frame::new(OUTPUT, 0, &[7; 64]);

        one.push(frame());
        two.push(frame());
        three.push(frame());

        assert!(!one.dead);
        assert!(budget.used() <= 200);
        assert!(one.dead || two.dead || three.dead);
        drop(one);
        drop(two);
        drop(three);
        assert_eq!(budget.used(), 0);
    }

    #[test]
    fn partial_front_keeps_its_full_allocation_charged_until_drop() {
        let budget = Arc::new(PeerBufferBudget::new(1024 * 1024));
        let (socket, _remote) = UnixStream::pair().unwrap();
        let mut peer = Peer::new_with_budget(socket, 1, budget.clone()).unwrap();
        peer.push(Frame::new(OUTPUT, 0, &vec![1; 512 * 1024]));
        let charged = budget.used();
        assert!(charged > 512 * 1024);

        peer.flush().unwrap();
        assert!(peer.offset > 0);
        assert_eq!(budget.used(), charged);

        drop(peer);
        assert_eq!(budget.used(), 0);
    }

    #[test]
    fn discarding_queued_output_releases_only_unretained_buffers() {
        let budget = Arc::new(PeerBufferBudget::new(1024));
        let (socket, _remote) = UnixStream::pair().unwrap();
        let mut peer = Peer::new_with_budget(socket, 1, budget.clone()).unwrap();
        peer.push(Frame::new(OUTPUT, 0, b"partial front"));
        peer.push(Frame::new(OUTPUT, 1, b"discarded back"));
        let initial = budget.used();
        peer.offset = 2;

        peer.discard_queued_output();

        assert_eq!(peer.queue.len(), 1);
        assert_eq!(peer.offset, 2);
        assert_eq!(peer.queued, peer.queue.front().unwrap().len() - 2);
        assert!(budget.used() < initial);
        assert_eq!(budget.used(), peer.queue.front().unwrap().capacity());
        drop(peer);
        assert_eq!(budget.used(), 0);
    }

    #[test]
    fn partial_incoming_frame_is_charged_until_peer_drop() {
        let budget = Arc::new(PeerBufferBudget::new(128 * 1024));
        let (socket, mut remote) = UnixStream::pair().unwrap();
        remote
            .set_write_timeout(Some(std::time::Duration::from_secs(2)))
            .unwrap();
        let mut peer = Peer::new_with_budget(socket, 1, budget.clone()).unwrap();
        let payload_size = 8 * 1024;
        let header = (*b"X")
            .into_iter()
            .chain(0u64.to_be_bytes())
            .chain((payload_size as u32).to_be_bytes())
            .collect::<Vec<_>>();
        remote.write_all(&header).unwrap();
        remote.write_all(&[0; 1024]).unwrap();

        assert!(peer.read().unwrap().is_empty());
        let charged = budget.used();
        assert!(charged > 0);
        drop(peer);
        assert_eq!(budget.used(), 0);
    }

    #[test]
    fn consumed_large_frame_releases_incoming_capacity_for_another_peer() {
        let budget = Arc::new(PeerBufferBudget::new(1024 * 1024));
        let (socket, mut remote) = UnixStream::pair().unwrap();
        let mut peer = Peer::new_with_budget(socket, 1, budget.clone()).unwrap();
        let large = Frame::new(b'X', 1, &vec![b'x'; 512 * 1024]).encode();
        peer.reserve_incoming(large.len()).unwrap();
        peer.incoming.extend_from_slice(&large);
        assert!(budget.used() >= 512 * 1024);
        remote.write_all(b"x").unwrap();

        let frames = peer.read().unwrap();
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].data.len(), 512 * 1024);
        assert!(budget.used() <= 16 * 1024);
        assert!(budget.try_reserve(900 * 1024));
        budget.release(900 * 1024);
        drop(peer);
        assert_eq!(budget.used(), 0);
    }

    #[test]
    fn read_accepts_maximum_frame_followed_by_another_frame() {
        let (socket, mut remote) = UnixStream::pair().unwrap();
        let mut peer = Peer::new(socket, 1).unwrap();
        let large = Frame::new(b'X', 1, &vec![b'x'; MAX_FRAME]).encode();
        let small = Frame::new(b'Y', 2, b"next").encode();
        let split = large.len() - 8;
        peer.reserve_incoming(split).unwrap();
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
        let header = (*b"X")
            .into_iter()
            .chain(0u64.to_be_bytes())
            .chain(((MAX_FRAME + 1) as u32).to_be_bytes())
            .collect::<Vec<_>>();
        remote.write_all(&header).unwrap();

        assert!(peer.read().is_err());
    }
}
