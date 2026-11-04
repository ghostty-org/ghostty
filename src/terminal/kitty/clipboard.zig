//! Kitty clipboard protocol (OSC 5522).
//!
//! This implements the protocol semantics on top of the raw OSC capture:
//! src/terminal/osc/parsers/kitty_clipboard_protocol.zig:
//!
//! The behavior here is modeled on the kitty reference implementation
//! (kitty/clipboard.py) rather than only the prose spec, since the two
//! disagree in places. Notable reference behaviors we reproduce:
//!
//!   * Malformed metadata (any record without '=', including an empty
//!     metadata section) and an unknown or missing `type` silently drop
//!     the request with no response.
//!   * All base64 (payloads and the `mime`, `name`, and `pw` metadata
//!     values) is strict RFC 4648 per the spec's "Encoding of payloads"
//!     section: characters outside the standard alphabet (including
//!     whitespace) and incorrect padding are rejected, never silently
//!     skipped. An invalid value on `wdata` or `walias` aborts an
//!     in-flight write with EINVAL; an invalid `read` is dropped with
//!     no response since reads have no error status.
//!   * Decoded metadata and MIME-list payloads must be valid UTF-8. An
//!     invalid value on `wdata` or `walias`, or a `walias` without a
//!     target MIME type, aborts an in-flight write with EINVAL.
//!   * The `wdata` payloads for one MIME type form a single base64
//!     stream split at arbitrary packet boundaries; only the
//!     concatenation must be correctly padded. Like kitty (which
//!     resets its streaming decoder on EOF), a packet ending exactly
//!     at terminal padding restarts the stream, so independently
//!     encoded chunks also work.
//!   * `mime`, `name`, and `pw` metadata values are base64-encoded UTF-8;
//!     everything else is verbatim. Unknown keys are ignored.
//!   * `id` is sanitized by stripping characters outside [a-zA-Z0-9-_+.]
//!     and truncating to 512 bytes, then echoed verbatim in every
//!     response packet (omitted when empty).
//!   * A `type=write` silently replaces any in-flight transaction. A
//!     commit (`type=wdata` without a MIME type) with no in-flight
//!     transaction is silently ignored.
//!   * Responses never send a payload section for an empty payload,
//!     except the targets ('.') listing DATA packet which is always sent.
//!
//! Specification: https://sw.kovidgoyal.net/kitty/clipboard/

const oscpkg = @import("../osc.zig");
const protocol = @import("../osc/parsers/kitty_clipboard_protocol.zig");
const command = @import("clipboard_command.zig");
const write = @import("clipboard_write.zig");
const response = @import("clipboard_response.zig");
const grants = @import("clipboard_grants.zig");

pub const OSC = protocol.OSC;
pub const Operation = protocol.Operation;
pub const Status = protocol.Status;
pub const Terminator = oscpkg.Terminator;

pub const Metadata = command.Metadata;
pub const Payload = command.Payload;
pub const readPromptExempt = command.readPromptExempt;
pub const max_id_len = command.max_id_len;
pub const max_pw_len = command.max_pw_len;
pub const max_mime_len = command.max_mime_len;
pub const max_name_len = command.max_name_len;

pub const Content = write.Content;
pub const WriteState = write.WriteState;
pub const max_write_size = write.max_write_size;
pub const max_write_mimes = write.max_write_mimes;
pub const max_write_aliases = write.max_write_aliases;

pub const Response = response.Response;
pub const ReadSuccess = response.ReadSuccess;
pub const PasteEvent = response.PasteEvent;
pub const read_chunk_size = response.read_chunk_size;
pub const max_read_mimes = response.max_read_mimes;
pub const max_listing_mimes = response.max_listing_mimes;
pub const targets_mime = response.targets_mime;

pub const Grants = grants.Grants;
pub const otp_len = grants.otp_len;
pub const generateOtp = grants.generateOtp;

test {
    @import("std").testing.refAllDecls(@This());
}
