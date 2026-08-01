//! Terminal snapshot binary representation and codecs.
//!
//! This is NOT a full transport-ready format to implement generic replay
//! software such as multiplexers, recorders (e.g. asciinema), etc. The goal
//! of this package is to provide a documented, binary-compatible representation
//! for a terminal state.
//!
//! We call this a "snapshot." The snapshot is purposely laid out in a way
//! that prioritizes making a terminal functional as quickly as possible.
//! To do that, it sends the active terminal state followed by a READY record,
//! then complete history.
//!
//! READY denotes that enough of the terminal state is down that it can
//! be fully rendered at that point. This is also the point where live
//! terminals can also start accepting pty bytes, typically. But the current
//! snapshot format lacks some of the information necessary to synchronize
//! pty byte state with an authoritative server.
//!
//! After READY, we send history pages (scrollback).
//!
//! ## Snapshot Format
//!
//! This documents snapshot format 1. Version 1 is the work-in-progress
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
//! Record groups have a strict order:
//!
//! ```text
//! +----------------------------------------+
//! | TERMINAL                               |
//! +----------------------------------------+
//! | SCREEN * terminal.screen_count         |
//! | PAGE * each screen.page_count          |
//! +----------------------------------------+
//! | READY                                  |
//! +----------------------------------------+
//! | HISTORY * terminal.screen_count        |
//! | PAGE * each history.page_count         |
//! +----------------------------------------+
//! | FINISH                                 |
//! +----------------------------------------+
//! ```
//!
//! The SCREEN and HISTORY sequence groups may each appear in any key order.
//! Each key must occur exactly once in each group and must identify one of the
//! screens declared by TERMINAL. SCREEN contains the complete pages needed to
//! restore each active area. HISTORY contains the older complete pages for its
//! screen in newest-to-oldest order so they can be prepended as they arrive.
//! Every SCREEN has one corresponding HISTORY, even when its history page count
//! is zero. FINISH terminates the snapshot. Bytes after FINISH belong to the
//! containing transport and are not consumed by snapshot decoding.
//!
//! READY and FINISH contain BLAKE3-256 digests of all preceding snapshot bytes.
//! READY therefore validates the renderable active-state prefix. FINISH covers
//! READY and all history as well, validating the complete snapshot and its
//! record ordering. Each SCREEN declares its complete logical history extent,
//! allowing a client to size its scrollbar at READY even though older PAGE
//! records arrive afterward.
//!
//! ## Encoding
//!
//! Encode a complete snapshot into any writer:
//!
//! ```zig
//! var output: std.Io.Writer.Allocating = .init(alloc);
//! defer output.deinit();
//!
//! try snapshot.encode(alloc, &output.writer, &terminal);
//!
//! const bytes = output.written();
//! ```
//!
//! Encoding begins at the writer's current position, so unrelated bytes may
//! precede the snapshot. The encoder buffers only the current record payload
//! to calculate its length and CRC32C; completed records stream immediately
//! and BLAKE3 checkpoint coverage is updated incrementally. Buffering is an
//! encoder implementation detail, not a requirement of the wire format.
//!
//! A failure may leave prior complete records, or a partial record if the
//! destination itself fails. Such a prefix has no valid FINISH checkpoint and
//! cannot be restored as a complete snapshot.
//!
//! Each record type usually exposes an `encode` function that encodes
//! a complete record, such as `screen.encode`.
//!
//! ## Decoding
//!
//! `snapshot.decode` consumes exactly one snapshot through FINISH and leaves
//! any following bytes unread. This permits multiple snapshots or live protocol
//! data to share a stream without waiting for the peer to close it. Transports
//! that deliver live PTY data before history finishes must multiplex that data
//! outside this ordered snapshot record sequence.
//!
//! ```zig
//! var terminal = try snapshot.decode(alloc, io, &reader);
//! defer terminal.deinit(alloc);
//! ```
//!
//! Use `snapshot.decodeExact` for a bounded file or buffer that must contain
//! only one snapshot. It preserves the stricter end-of-file check, which may
//! block when used with a live stream.

pub const checkpoint = @import("checkpoint.zig");
pub const envelope = @import("envelope.zig");
pub const grid = @import("grid.zig");
pub const history = @import("history.zig");
pub const hyperlink = @import("hyperlink.zig");
pub const page = @import("page.zig");
pub const record = @import("record.zig");
pub const screen = @import("screen.zig");
pub const style = @import("style.zig");
pub const terminal = @import("terminal.zig");

const codec = @import("snapshot.zig");
pub const EncodeError = codec.EncodeError;
pub const DecodeError = codec.DecodeError;
pub const DecodeExactError = codec.DecodeExactError;
pub const encode = codec.encode;
pub const decode = codec.decode;
pub const decodeExact = codec.decodeExact;

test {
    @import("std").testing.refAllDecls(@This());
}
