//! Kitty drag and drop protocol (OSC 72): per-terminal state and the
//! dispatch of client commands to the drop target.

const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = @import("../../quirks.zig").inlineAssert;
const osc = @import("../osc.zig");
const command = @import("dnd_command.zig");
const response = @import("dnd_response.zig");
const dnd_drop = @import("dnd_drop.zig");

const Metadata = command.Metadata;
const Operation = command.Operation;

const log = std.log.scoped(.kitty_dnd);

/// A protocol state change an embedder may need to act on, returned by
/// `handleCommand`. The stream handler delivers each as a protocol
/// independent `dnd.DropEvent`, with its details read from the state.
pub const Event = enum {
    /// The client registered (t=a), re-registered, or unregistered
    /// (t=A) to accept drops. An embedder may want to use this
    /// to setup the proper mime types to accept (e.g. on macOS)
    /// or not (unregistered).
    registration,

    /// The client answered the drag currently over the terminal.
    /// `DropTarget.clientAccepted` has the answer. Embedders can refresh
    /// the OS drag feedback immediately rather than on the next move.
    acceptance,

    /// A data request needs serving: `DropTarget.request` has it.
    data_request,

    /// The drop ended with the client performing no operation (it
    /// canceled), a copy, or a move. The embedder finishes the native
    /// drop with that operation.
    concluded_none,
    concluded_copy,
    concluded_move,

    /// The conclusion event for a performed operation.
    pub fn concluded(op: Operation) Event {
        return switch (op) {
            .none => .concluded_none,
            .copy => .concluded_copy,
            .move => .concluded_move,
        };
    }
};

/// The events produced by one client command, in order.
pub const Events = struct {
    buf: [4]Event = undefined,
    len: usize = 0,

    pub fn slice(self: *const Events) []const Event {
        return self.buf[0..self.len];
    }

    fn add(self: *Events, ev: Event) void {
        assert(self.len < self.buf.len);
        self.buf[self.len] = ev;
        self.len += 1;
    }
};

/// The per-terminal drag and drop state.
///
/// The primary entrypoint is `handleCommand` which takes a `*?*State`
/// slot that it heap allocates into when the client registers to
/// accept drops, and frees when it unregisters.
///
/// All calls must use the allocator the state was created with (the
/// terminal's) and require the same synchronization as any other
/// terminal mutation.
pub const State = struct {
    /// Chunk reassembly for client commands. This is the only part of
    /// the state cleared by a terminal reset (RIS), matching kitty.
    chunking: command.Chunking = .{},

    /// Drop target state for the client accepting drops.
    drop: dnd_drop.DropTarget = .{},

    /// Allocate a fresh state. Done by `handleCommand` on registration.
    fn create(alloc: Allocator) Allocator.Error!*State {
        const state = try alloc.create(State);
        state.* = .{};
        return state;
    }

    /// Free the state and everything it holds.
    pub fn destroy(self: *State, alloc: Allocator) void {
        self.deinit(alloc);
        alloc.destroy(self);
    }

    fn deinit(self: *State, alloc: Allocator) void {
        self.drop.deinit(alloc);
    }

    /// True when the client isn't registered, so the state can be freed.
    fn idle(self: *const State) bool {
        return !self.drop.registered;
    }
};

/// Process one OSC 72 command received from the client, writing any
/// responses to the writer. Returns the state changes the embedder may
/// need to act on, in order.
pub fn handleCommand(
    slot: *?*State,
    alloc: Allocator,
    writer: *std.Io.Writer,
    v: osc.Command.KittyDndProtocol,
) (Allocator.Error || std.Io.Writer.Error)!Events {
    var events: Events = .{};
    const raw = Metadata.parse(v.metadata) orelse {
        log.debug("dropping malformed OSC 72 metadata", .{});
        return events;
    };

    // Registration allocates the state. Everything else
    // runs against the existing state or, before there is one, against
    // an empty one on the stack, which answers with the same errors
    // kitty sends from its zeroed state without allocating.
    const activates = activates: {
        const t = raw.type orelse break :activates false;
        break :activates t == .register and raw.cell_x != 1;
    };
    var scratch: State = .{};
    defer scratch.deinit(alloc);
    const state: *State = slot.* orelse if (activates) state: {
        const state = try State.create(alloc);
        slot.* = state;
        break :state state;
    } else &scratch;

    // Chunk reassembly lives in the state, so before registration each
    // command stands alone. The only legitimately chunked command
    // before registration is t=a itself, which seeds the reassembly on
    // its first chunk.
    const continuation = state.chunking.active;
    const meta = state.chunking.apply(raw);
    const payload = v.payload orelse "";

    if (meta.type) |t| try dispatch(
        state,
        alloc,
        writer,
        t,
        meta,
        payload,
        continuation,
        v.terminator,
        &events,
    );

    // Free the state once the client unregisters.
    if (slot.*) |s| if (s == state and state.idle()) {
        state.destroy(alloc);
        slot.* = null;
    };

    return events;
}

fn dispatch(
    state: *State,
    alloc: Allocator,
    writer: *std.Io.Writer,
    t: command.EventType,
    meta: Metadata,
    payload: []const u8,
    continuation: bool,
    terminator: osc.Terminator,
    events: *Events,
) (Allocator.Error || std.Io.Writer.Error)!void {
    switch (t) {
        .register => {
            // x=1 declares the client's machine ID for remote drop
            // support. We don't support remote drop yet, so accept and
            // ignore.
            if (meta.cell_x == 1) return;
            if (try state.drop.register(
                alloc,
                meta.client_id,
                payload,
                continuation,
                meta.more,
            )) events.add(.registration);
        },

        .unregister => {
            if (!state.drop.registered) return;
            if (state.drop.unregister(alloc)) events.add(.concluded_none);
            events.add(.registration);
        },

        .status => {
            if (!state.drop.registered) return;
            if (try state.drop.acceptStatus(alloc, meta, payload)) events.add(.acceptance);
        },

        .request => switch (try state.drop.dataRequest(alloc, writer, meta, terminator)) {
            .none => {},
            .serve => events.add(.data_request),
            .concluded => |op| events.add(.concluded(op)),
        },

        // Drag source control. Enabling (x=1, with an optional
        // machine ID payload) and disabling (x=2) offers are accepted
        // and ignored since the terminal never requests a drag start.
        // Offering a MIME list (x=0) for a new drag is refused since
        // drag out is not implemented.
        .offer => if (meta.cell_x == 0) try refuseDragOut(
            writer,
            meta,
            terminator,
        ),

        // Drag out data and start commands. A conforming client never
        // sends these because the terminal never requests a drag
        // start, but refuse them properly if one does.
        .present, .start_drag => try refuseDragOut(
            writer,
            meta,
            terminator,
        ),

        // Responses to drag out requests the terminal never makes.
        .drag_event, .drag_error, .remote_data => {},

        .query => try response.encode(
            writer,
            "t=q",
            meta.client_id,
            "",
            .plain,
            terminator,
        ),

        // Only ever sent by the terminal. Ignore.
        .drop, .request_error => {},
    }
}

fn refuseDragOut(
    writer: *std.Io.Writer,
    meta: Metadata,
    terminator: osc.Terminator,
) std.Io.Writer.Error!void {
    try response.encodeError(
        writer,
        .drag,
        .{},
        meta.client_id,
        .EPERM,
        "drag out is not supported by this terminal",
        terminator,
    );
}
