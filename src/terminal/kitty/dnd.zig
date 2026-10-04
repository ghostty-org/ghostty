//! Kitty drag and drop protocol (OSC 72).
//!
//! Specification: https://sw.kovidgoyal.net/kitty/dnd-protocol/
//!
//! The protocol lets a program running in the terminal participate in
//! native OS drag and drop in both directions:
//!
//!   * Drops: a client registers to accept drops (t=a); the terminal
//!     then forwards native drag movement (t=m) and drops (t=M) to it
//!     and serves the dropped data on request (t=r), instead of the
//!     traditional behavior of pasting dropped paths or text. See
//!     `DropTarget`.
//!   * Drags: a client enables offering drags (t=o:x=1); when the user
//!     starts a drag gesture over the terminal, the terminal asks the
//!     client to offer one (t=o), and the client supplies the MIME
//!     types, data, and images of a native drag it starts (t=p, t=P)
//!     and the data a drop target requests during it (t=e). See
//!     `DragSource`.
//!
//! The embedder connects the protocol to the OS: `handleCommand`
//! processes client commands and returns `Event`s saying what changed,
//! which `dropEvent` and `dragEvents` turn into protocol independent
//! `terminal.dnd` events, and the embedder reports native activity with
//! `dropInput` and `dragInput` (or the `DropTarget` and `DragSource`
//! functions of `State` directly).
//!
//! ## Divergences
//!
//! These will be fixed in the future:
//!
//!   * Every client is treated as local: machine IDs (t=a:x=1,
//!     t=o:x=1 payloads) are accepted and ignored, responses never carry
//!     the X=1 remote marker, remote file transfer requests (t=r with y
//!     or Y keys) are answered with EINVAL, and remote drag data (t=k)
//!     is ignored. A remote client (e.g. over ssh) can still exchange
//!     text and other data; only file-content transfer is unavailable.
//!
//! These are on purpose forever:
//!
//!   * Responses echo the requesting command's terminator (ST or BEL)
//!     per ghostty convention; kitty always uses ST. Terminal-
//!     initiated events always use ST.
//!   * Drag images are passed to the embedder as received (RGB is
//!     expanded to RGBA): PNG decoding and rendering text images are
//!     the embedder's job, since they need its image and font support.
//!   * Drag data requested after the drag started is buffered in memory
//!     for the embedder to take, up to `max_buffered_bytes` unread,
//!     where kitty spools it to a temporary file.

const dnd_command = @import("dnd_command.zig");
const dnd_response = @import("dnd_response.zig");
const dnd_state = @import("dnd_state.zig");
const dnd_drop = @import("dnd_drop.zig");
const dnd_drag = @import("dnd_drag.zig");
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
pub const Sides = dnd_state.Sides;
pub const handleCommand = dnd_state.handleCommand;

pub const isDrop = dnd_embed.isDrop;
pub const dropEvent = dnd_embed.dropEvent;
pub const dragEvents = dnd_embed.dragEvents;
pub const dropInput = dnd_embed.dropInput;
pub const dragInput = dnd_embed.dragInput;
pub const InputError = dnd_embed.InputError;

pub const DropTarget = dnd_drop.DropTarget;
pub const MoveEvent = dnd_drop.MoveEvent;
pub const DataRequest = dnd_drop.DataRequest;
pub const max_mime_list_bytes = dnd_drop.max_mime_list_bytes;
pub const max_requests = dnd_drop.max_requests;

pub const DragSource = dnd_drag.DragSource;
pub const Position = dnd_drag.Position;
pub const Phase = dnd_drag.Phase;
pub const ImageFormat = dnd_drag.ImageFormat;
pub const Image = dnd_drag.Image;
pub const Report = dnd_drag.Report;
pub const Data = dnd_drag.Data;
pub const max_present_bytes = dnd_drag.max_present_bytes;
pub const max_buffered_bytes = dnd_drag.max_buffered_bytes;

test {
    _ = dnd_command;
    _ = dnd_response;
    _ = dnd_state;
    _ = dnd_drop;
    _ = dnd_drag;
    _ = dnd_embed;
    _ = @import("dnd_test.zig");
}
