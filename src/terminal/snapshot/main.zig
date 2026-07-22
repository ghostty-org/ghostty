//! Terminal snapshot binary representation and codecs.
//!
//! This is NOT a full transport-ready format to implement generic replay
//! software such as multiplexers, recorders (e.g. asciinema), etc. The goal
//! of this package is to provide a documented, binary-compatible representation
//! for a terminal state.
//!
//! We call this a "snapshot." The snapshot is purposely laid out in a way
//! that prioritizes making a terminal functional as quickly as possible.
//! To do that, it sends down the terminal state, viewport, etc. followed
//! by a "READY" event. At the READY state, the terminal is functional and
//! could in theory begin processing pty bytes. After the READY state the
//! binary format continues transmitting history and extra assets such as
//! images and so on.
//!
//! ## Snapshot Format
//!
//! This documents snapshot format 0. Version 0 is the work-in-progress
//! format that we intended to continue to break until we can promise
//! binary compatibility.
//!
//! A snapshot is one envelope followed by a sequence of records. The envelope
//! occurs once at byte zero. Every record is independently framed as a fixed
//! header followed by the number of payload bytes declared by that header.
//!
//! ```text
//! +------------------+
//! | Envelope         |
//! +------------------+
//! | Record 1 header  |
//! +------------------+
//! | Record 1 payload |
//! +------------------+
//! | Record 2 header  |
//! +------------------+
//! | Record 2 payload |
//! +------------------+
//! | ...              |
//! +------------------+
//! ```
//!
//! Records have a strict order: TERMINAL, the primary SCREEN and its
//! PAGE records, an optional alternate SCREEN and its PAGE records,
//! CONTINUATION, READY, and FINISH.

pub const envelope = @import("envelope.zig");
pub const hyperlink = @import("hyperlink.zig");
pub const page = @import("page.zig");
pub const record = @import("record.zig");
pub const style = @import("style.zig");
