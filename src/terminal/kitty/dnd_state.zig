//! Kitty drag and drop protocol (OSC 72): per-terminal state and the
//! dispatch of client commands to the drop target and drag source.

const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = @import("../../quirks.zig").inlineAssert;
const osc = @import("../osc.zig");
const command = @import("dnd_command.zig");
const response = @import("dnd_response.zig");
const dnd_drop = @import("dnd_drop.zig");
const dnd_drag = @import("dnd_drag.zig");

const Metadata = command.Metadata;
const Operation = command.Operation;

const log = std.log.scoped(.kitty_dnd);

/// A protocol state change an embedder may need to act on, returned by
/// `handleCommand` and delivered through the stream handler's
/// `drag_and_drop` effect. This is a flat enum so it can cross a C API
/// unchanged; any details are read back from `Terminal.kitty_dnd`.
///
/// Values are only ever appended: the C API exposes them by value.
pub const Event = enum(c_int) {
    /// The client registered (t=a), re-registered, or unregistered
    /// (t=A) to accept drops. An embedder may want to use this
    /// to setup the proper mime types to accept (e.g. on macOS)
    /// or not (unregistered).
    registration = 0,

    /// The client answered the drag currently over the terminal.
    /// `DropTarget.clientAccepted` has the answer. Embedders can refresh
    /// the OS drag feedback immediately rather than on the next move.
    acceptance = 1,

    /// A data request needs serving: `DropTarget.request` has it.
    data_request = 2,

    /// The drop ended with the client performing no operation (it
    /// canceled), a copy, or a move. The embedder finishes the native
    /// drop with that operation.
    concluded_none = 3,
    concluded_copy = 4,
    concluded_move = 5,

    /// The client enabled or disabled offering drags (t=o:x=1, x=2):
    /// read `DragSource.enabled`.
    offers = 6,

    /// The client asked to start its offered drag: the embedder starts
    /// the native drag and reports the result with
    /// `DragSource.startResult`.
    drag_start = 7,

    /// The client changed the image of the started drag to
    /// `DragSource.currentImage`.
    drag_image = 8,

    /// Data the embedder requested for the started drag arrived or
    /// failed: read it with `DragSource.takeData`.
    drag_data = 9,

    /// A native drag in progress must be canceled: the client canceled
    /// it, disabled offers, or made an error.
    drag_cancel = 10,

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

    fn addDrag(self: *Events, result: dnd_drag.DragSource.Result) void {
        switch (result) {
            .none => {},
            .offers => self.add(.offers),
            .start => self.add(.drag_start),
            .image => self.add(.drag_image),
            .data => self.add(.drag_data),
            .cancel => self.add(.drag_cancel),
        }
    }
};

/// The per-terminal drag and drop state.
///
/// The primary entrypoint is `handleCommand` which takes a `*?*State`
/// slot that it heap allocates into when the client registers to
/// accept drops or enables offering drags, and frees when it has done
/// neither.
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

    /// Drag source state for the client offering drags.
    drag: dnd_drag.DragSource = .{},

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
        self.drag.deinit(alloc);
    }

    /// True when neither side is active, so the state can be freed.
    fn idle(self: *const State) bool {
        return !self.drop.registered and !self.drag.enabled;
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

    // Commands that activate a side allocate the state. Everything else
    // runs against the existing state or, before there is one, against
    // an empty one on the stack, which answers with the same errors
    // kitty sends from its zeroed state without allocating.
    const activates = activates: {
        const t = raw.type orelse break :activates false;
        break :activates switch (t) {
            .register => raw.cell_x != 1,
            .offer => raw.cell_x == 1,
            else => false,
        };
    };
    var scratch: State = .{};
    defer scratch.deinit(alloc);
    const state: *State = slot.* orelse if (activates) state: {
        const state = try State.create(alloc);
        slot.* = state;
        break :state state;
    } else &scratch;

    // Chunk reassembly lives in the state, so before activation each
    // command stands alone. The only legitimately chunked commands
    // before activation are t=a and t=o:x=1 themselves, which seed the
    // reassembly on their first chunk.
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

    // Free the state once neither side is active.
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

        .offer => switch (meta.cell_x) {
            1 => events.addDrag(state.drag.enable()),
            2 => {
                if (!state.drag.enabled) return;
                if (state.drag.disable(alloc)) events.add(.drag_cancel);
                events.add(.offers);
            },
            0 => events.addDrag(try state.drag.offer(
                alloc,
                writer,
                meta,
                payload,
                continuation,
                terminator,
            )),
            else => {},
        },

        .present => events.addDrag(try state.drag.present(
            alloc,
            writer,
            meta,
            payload,
            terminator,
        )),

        .start_drag => if (meta.cell_x >= 0)
            events.addDrag(state.drag.changeImage(@intCast(meta.cell_x)))
        else
            events.addDrag(try state.drag.start(alloc, writer, terminator)),

        .drag_event => events.addDrag(try state.drag.itemData(
            alloc,
            writer,
            meta,
            payload,
            false,
            terminator,
        )),

        .drag_error => if (meta.cell_y == -1) {
            if (state.drag.cancel(alloc)) events.add(.drag_cancel);
        } else events.addDrag(try state.drag.itemData(
            alloc,
            writer,
            meta,
            payload,
            true,
            terminator,
        )),

        .query => try response.encode(
            writer,
            "t=q",
            meta.client_id,
            "",
            .plain,
            terminator,
        ),

        // Remote drag data. We never advertise remote support, so a
        // conforming client never sends it.
        .remote_data => {},

        // Only ever sent by the terminal. Ignore.
        .drop, .request_error => {},
    }
}
