//! Termio is responsible for "terminal IO." Specifically, this is the
//! reading and writing of bytes for the underlying pty or pty-like device.
//!
//! Termio is constructed of a few components:
//!   - Termio - The main shared struct that has common logic across all
//!     backends and mailboxes (defined below).
//!   - Backend - Responsible for the actual physical IO. For example, one
//!     implementation creates a subprocess, allocates and assigns a pty,
//!     and sets up a read thread on the pty.
//!   - Mailbox - Responsible for storing/dispensing event messages to
//!     the backend. This exists separately from backends because termio
//!     is built to be both single and multi-threaded.
//!
//! Termio supports (and recommends) multi-threaded operation. Multi-threading
//! enables the read/writes to generally happen on separate threads and
//! almost always improves throughput and latency under heavy IO load. To
//! enable threading, use the Thread struct. This wraps a Termio, requires
//! specific backend/mailbox capabilities, and sets up the necessary threads.

const stream_handler = @import("termio/stream_handler.zig");

const message = @import("termio/message.zig");
pub const backend = @import("termio/backend.zig");
pub const mailbox = @import("termio/mailbox.zig");
pub const Exec = @import("termio/Exec.zig");
pub const Options = @import("termio/Options.zig");
pub const Termio = @import("termio/Termio.zig");
pub const Thread = @import("termio/Thread.zig");
pub const Backend = backend.Backend;
pub const DerivedConfig = Termio.DerivedConfig;
pub const Mailbox = mailbox.Mailbox;
pub const Message = message.Message;
pub const StreamHandler = stream_handler.StreamHandler;

test {
    @import("std").testing.refAllDecls(@This());

    _ = @import("termio/shell_integration.zig");
}
