//! Kitty drag and drop protocol (OSC 72).
//!
//! Specification: https://sw.kovidgoyal.net/kitty/dnd-protocol/
//!
//! The protocol lets a program running in the terminal participate in
//! native OS drag and drop. A client registers to accept drops (t=a);
//! the terminal then forwards native drag movement (t=m) and drops
//! (t=M) to it and serves the dropped data on request (t=r), instead
//! of the traditional behavior of pasting dropped paths or text. See
//! `DropTarget`.
//!
//! The embedder connects the protocol to the OS: `handleCommand`
//! processes client commands and returns `Event`s saying what changed,
//! which `dropEvent` turns into protocol independent `terminal.dnd`
//! events, and the embedder reports native activity with `dropInput`
//! (or the `DropTarget` functions of `State` directly).
//!
//! ## Divergences
//!
//! These will be fixed in the future:
//!
//!   * Every client is treated as local: machine IDs (t=a:x=1) are
//!     accepted and ignored, responses never carry the X=1 remote
//!     marker, and remote file transfer requests (t=r with y or Y
//!     keys) are answered with EINVAL. A remote client (e.g. over
//!     ssh) can still receive text drops; only file-content transfer
//!     is unavailable.
//!   * The terminal never initiates drags (drag out): enabling and
//!     disabling offers (t=o:x=1, t=o:x=2) are accepted and ignored,
//!     and since the terminal never sends a drag start request a
//!     conforming client never offers a drag. Direct offers (t=o:x=0)
//!     and drag data/start commands (t=p, t=P) are refused with EPERM.
//!
//! These are on purpose forever:
//!
//!   * Responses echo the requesting command's terminator (ST or BEL)
//!     per ghostty convention; kitty always uses ST. Terminal-
//!     initiated events always use ST.

const dnd_command = @import("dnd_command.zig");
const dnd_response = @import("dnd_response.zig");
const dnd_state = @import("dnd_state.zig");
const dnd_drop = @import("dnd_drop.zig");
const dnd_embed = @import("dnd_embed.zig");

pub const EventType = dnd_command.EventType;
pub const Metadata = dnd_command.Metadata;
pub const Operation = dnd_command.Operation;
pub const Operations = dnd_command.Operations;
pub const Request = dnd_command.Request;
pub const Chunking = dnd_command.Chunking;

pub const Errno = dnd_response.Errno;
pub const RequestKeys = dnd_response.RequestKeys;
pub const encode = dnd_response.encode;
pub const encodeError = dnd_response.encodeError;

pub const State = dnd_state.State;
pub const Event = dnd_state.Event;
pub const Events = dnd_state.Events;
pub const handleCommand = dnd_state.handleCommand;

pub const dropEvent = dnd_embed.dropEvent;
pub const dropInput = dnd_embed.dropInput;
pub const InputError = dnd_embed.InputError;

pub const DropTarget = dnd_drop.DropTarget;
pub const MoveEvent = dnd_drop.MoveEvent;
pub const DataRequest = dnd_drop.DataRequest;
pub const max_mime_list_bytes = dnd_drop.max_mime_list_bytes;
pub const max_requests = dnd_drop.max_requests;

test {
    _ = dnd_command;
    _ = dnd_response;
    _ = dnd_state;
    _ = dnd_drop;
    _ = dnd_embed;
    _ = @import("dnd_test.zig");
}
