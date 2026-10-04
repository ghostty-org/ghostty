//! Kitty drag and drop protocol (OSC 72) state machine.

const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = @import("../../quirks.zig").inlineAssert;
const osc = @import("../osc.zig");
const command = @import("dnd_command.zig");
const response = @import("dnd_response.zig");

const Metadata = command.Metadata;
const Operation = command.Operation;
const Operations = command.Operations;
const Errno = response.Errno;

const log = std.log.scoped(.kitty_dnd);

/// Maximum accumulated size of a client-sent MIME list (the accepted
/// list of a `t=m` status update). Matches kitty's MIME_LIST_SIZE_CAP.
pub const max_mime_list_bytes = 1024 * 1024;

/// The maximum number of queued data requests. Matches kitty; one more
/// is refused with EMFILE and ends the drop.
pub const max_requests = 128;

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

    // Chunk reassembly lives in the state, so before registration
    // each command stands alone. The only legitimately chunked
    // command before registration is t=a itself, which seeds the
    // reassembly on its first chunk below.
    const continuation = if (slot.*) |state| state.chunking.active else false;
    const meta = if (slot.*) |state| state.chunking.apply(raw) else raw;
    const payload = v.payload orelse "";
    const t = meta.type orelse return events;

    switch (t) {
        .register => {
            // x=1 declares the client's machine ID for remote drop
            // support. We don't support remote drop yet, so accept and ignore.
            if (meta.cell_x == 1) return events;

            // Setup our state if we haven't already
            const state = slot.* orelse state: {
                const state = try State.create(alloc);
                slot.* = state;
                _ = state.chunking.apply(raw);
                break :state state;
            };

            // Update the client ID on every registration
            state.drop.client_id = meta.client_id;

            if (try state.register(
                alloc,
                payload,
                continuation,
                meta.more,
            )) |ev| events.add(ev);
        },

        .unregister => {
            const state = slot.* orelse return events;
            // An unconcluded drop is discarded, which the embedder must
            // finish natively.
            const dropped = state.drop.dropped;
            state.destroy(alloc);
            slot.* = null;
            if (dropped) events.add(.concluded_none);
            events.add(.registration);
        },

        .status => {
            const state = slot.* orelse return events;
            if (try state.acceptStatus(alloc, meta, payload)) |ev| events.add(ev);
        },

        .request => {
            const req: command.Request = .init(meta);
            if (slot.*) |state| {
                if (try state.dataRequest(
                    alloc,
                    writer,
                    req,
                    v.terminator,
                )) |ev| events.add(ev);
            } else if (req != .conclude) {
                // Requests from an unregistered client get the same
                // error kitty sends from its zeroed drop state.
                try sendError(
                    writer,
                    req,
                    0,
                    .EPERM,
                    "drop data can only be requested after a drop",
                    v.terminator,
                );
            }
        },

        // Drag source control. Enabling (x=1, with an optional
        // machine ID payload) and disabling (x=2) offers are
        // accepted and ignored since the terminal never requests a
        // drag start. Offering a MIME list (x=0) for a new drag is
        // refused since drag-out is not implemented.
        .offer => if (meta.cell_x == 0) try refuseDragOut(
            writer,
            meta,
            v.terminator,
        ),

        // Drag-out data and start commands. A conforming client
        // never sends these because the terminal never requests a
        // drag start, but refuse them properly if one does.
        .present, .start_drag => try refuseDragOut(
            writer,
            meta,
            v.terminator,
        ),

        // Responses to drag-out requests the terminal never makes.
        .drag_event, .drag_error, .remote_data => {},

        .query => try response.encode(
            writer,
            "t=q",
            meta.client_id,
            "",
            .plain,
            v.terminator,
        ),

        // Only ever sent by the terminal. Ignore.
        .drop, .request_error => {},
    }

    return events;
}

/// Refuse a drag-out command with an error, since ghostty does not
/// implement the terminal side of client-initiated drags yet.
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

/// Send an error for a data request, echoing its keys.
fn sendError(
    writer: *std.Io.Writer,
    req: command.Request,
    client_id: u32,
    errno: Errno,
    desc: []const u8,
    terminator: osc.Terminator,
) std.Io.Writer.Error!void {
    const keys: response.RequestKeys = switch (req) {
        .conclude => .{},
        .mime => |idx| .{ .x = idx },
        .uri => |uri| .{ .x = uri.mime_idx, .y = uri.uri_idx },
        .dir => |dir| .{ .x = dir.entry, .Y = dir.handle },
    };
    try response.encodeError(
        writer,
        .drop,
        keys,
        client_id,
        errno,
        desc,
        terminator,
    );
}

/// A protocol state change an embedder may need to act on, returned by
/// `handleCommand` and delivered through the stream handler's
/// `drag_and_drop` effect. This is a flat enum so it can cross a C API
/// unchanged; any details are read back from `Terminal.kitty_dnd`.
pub const Event = enum {
    /// The client registered (t=a), re-registered, or unregistered
    /// (t=A) to accept drops. An embedder may want to use this
    /// to setup the proper mime types to accept (e.g. on macOS)
    /// or not (unregistered).
    registration,

    /// The client answered the drag currently over the terminal.
    /// `State.clientAccepted` has the answer. Embedders can refresh the
    /// OS drag feedback immediately rather than on the next move.
    acceptance,

    /// A data request needs serving: `State.request` has it.
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

/// A data request the embedder must serve: read the data for `mime`
/// from the native drop and send it with `respondData` and
/// `respondEnd`, or fail it with `respondError`.
pub const DataRequest = struct {
    /// Identifies this request to the respond functions. Requests are
    /// never reused, so a reply for a request the client has since
    /// abandoned (by concluding the drop, or a new drag replacing it) is
    /// rejected rather than answering a later request.
    id: u32,

    /// Zero-based index into the MIME list given to `dragDrop`.
    mime_index: u32,

    /// The MIME type to read. Borrowed from the state and valid until
    /// the drop ends.
    mime: []const u8,
};

/// The per-terminal drop target state.
///
/// The primary entrypoint is `handleCommand` which takes a `*?*State`
/// slot that it can heap allocate into when DnD activates and free when
/// it deactivates.
///
/// The normal lifecycle:
///
///   1. The stream handler feeds every OSC 72 command received from the
///      client to `handleCommand`. The client registers (t=a), which
///      allocates the state into the slot and yields a `registration`
///      event so the embedder can register any declared MIME types
///      with the OS. Until then `handleCommand` only answers stateless
///      commands (queries, error responses).
///   2. A native drag enters or moves over the terminal. When the slot
///      is non-null, the embedder calls `dragMove` with the pointer
///      position, the operations the drag source allows, and the MIME
///      types of the drag. This sends the client a t=m move event;
///      when the slot is null the embedder should handle the drag as it
///      would without the protocol.
///   3. The client answers with its acceptance (t=m:o=N), recorded by
///      `handleCommand` which yields an `acceptance` event. The
///      embedder reads `clientAccepted` then and on subsequent moves
///      to give the OS drag session its feedback.
///   4. The drag either leaves (`dragLeave`) or drops (`dragDrop`). The
///      embedder keeps the native drop open after a drop: the data is
///      read from it on demand.
///   5. The client requests data (t=r:x=N). Requests are queued and
///      served one at a time in order; the first one the embedder must
///      fetch yields a `data_request` event and is available from
///      `request`. The embedder reads that MIME type from the native
///      drop (asynchronously if it must) and answers with any number
///      of `respondData` calls followed by `respondEnd`, or with
///      `respondError`. Each of those returns the next request to serve.
///   6. The client concludes the drop (t=r:o=N), yielding a
///      `concluded_*` event naming the operation it performed. The
///      embedder finishes the native drop with that operation.
///   7. The client unregisters (t=A) and `handleCommand` frees the
///      state, yielding a final `registration` event, or the terminal
///      is deinitialized and calls `destroy`.
///
/// All calls must use the allocator the state was created with (the
/// terminal's) and require the same synchronization as any other
/// terminal mutation.
pub const State = struct {
    /// Chunk reassembly for client commands. This is the only part of
    /// the state cleared by a terminal reset (RIS), matching kitty.
    chunking: command.Chunking = .{},

    /// Drop target state for the registered client.
    drop: DropTarget = .{},

    pub const DropTarget = struct {
        /// Multiplexer client ID from registration, echoed in every
        /// drop-side message the terminal sends.
        client_id: u32 = 0,

        /// The MIME list the client registered with (the t=a payload),
        /// space-separated as received and accumulated across chunks.
        /// Only needed by embedders that must register types with the
        /// OS ahead of a drag; kitty frees it after doing so, we keep
        /// it so the `registration` event can be acted on from here.
        registered_mimes: std.ArrayList(u8) = .empty,

        /// True while the pointer of a native drag is over the terminal.
        hovered: bool = false,

        /// True after the native drop until the client concludes it.
        dropped: bool = false,

        /// The client's response to the current drag, null until the
        /// client has responded. `none` means the client rejected it.
        accepted: ?Operation = null,

        /// True while a chunked t=m acceptance is being accumulated.
        accept_in_progress: bool = false,

        /// The client's accepted MIME list: space-separated while
        /// accumulating, converted to NUL-separated (with a trailing
        /// NUL) once complete, matching kitty's in-place conversion.
        accepted_mimes: std.ArrayList(u8) = .empty,

        /// The MIME types of the current native drag, in the order
        /// that data request indices refer to.
        offered: ?Offered = null,

        /// Data requests received from the client and not yet answered,
        /// served in order. The head is the request being served.
        queue: Queue = .{},

        /// The request the embedder is serving: the head of the queue,
        /// once it turned out to need data from the native drop.
        serving: ?Serving = null,

        /// The ID of the next request handed to the embedder.
        next_id: u32 = 1,
    };

    /// One queued data request.
    const Queued = struct {
        request: command.Request,
        terminator: osc.Terminator,
    };

    /// A fixed-capacity FIFO of data requests.
    const Queue = struct {
        items: [max_requests]Queued = undefined,
        head: usize = 0,
        len: usize = 0,

        fn push(self: *Queue, item: Queued) void {
            assert(self.len < max_requests);
            self.items[(self.head + self.len) % max_requests] = item;
            self.len += 1;
        }

        fn peek(self: *const Queue) ?*const Queued {
            if (self.len == 0) return null;
            return &self.items[self.head];
        }

        fn pop(self: *Queue) void {
            assert(self.len > 0);
            self.head = (self.head + 1) % max_requests;
            self.len -= 1;
        }

        fn clear(self: *Queue) void {
            self.* = .{};
        }
    };

    /// The request being served by the embedder.
    const Serving = struct {
        id: u32,
        mime_index: u32,
        terminator: osc.Terminator,
    };

    /// The MIME list of the current drag plus the pre-joined move-event
    /// payload ("mime1 mime2 " with a trailing space after every entry,
    /// matching kitty) so per-move encoding is allocation-free.
    const Offered = struct {
        mimes: []const []const u8,
        payload: []const u8,

        fn init(alloc: Allocator, mimes: []const []const u8) Allocator.Error!Offered {
            const copies = try alloc.alloc([]const u8, mimes.len);
            errdefer alloc.free(copies);

            var payload_len: usize = 0;
            for (mimes) |m| payload_len += m.len + 1;

            const payload = try alloc.alloc(u8, payload_len);
            errdefer alloc.free(payload);

            var offset: usize = 0;
            for (mimes, copies) |m, *copy| {
                @memcpy(payload[offset..][0..m.len], m);
                payload[offset + m.len] = ' ';
                copy.* = payload[offset..][0..m.len];
                offset += m.len + 1;
            }

            return .{ .mimes = copies, .payload = payload };
        }

        fn deinit(self: *const Offered, alloc: Allocator) void {
            alloc.free(self.mimes);
            alloc.free(self.payload);
        }

        fn eql(self: *const Offered, mimes: []const []const u8) bool {
            if (self.mimes.len != mimes.len) return false;
            for (self.mimes, mimes) |a, b| {
                if (!std.mem.eql(u8, a, b)) return false;
            }
            return true;
        }
    };

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
        self.freeOffered(alloc);
        self.drop.accepted_mimes.deinit(alloc);
        self.drop.registered_mimes.deinit(alloc);
    }

    /// Iterate the MIME types the client registered with, in order.
    /// Empty when the client declared none, which is the common case.
    /// The list is only needed to register exotic types with the OS,
    /// such as macOS pasteboard stuff.
    pub fn registeredMimes(self: *const State) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(
            u8,
            self.drop.registered_mimes.items,
            ' ',
        );
    }

    /// Record one chunk of a registration's MIME list.
    ///
    /// `continuation` is true for every chunk but the first of a chunked
    /// registration. Returns the registration event once the list is complete.
    fn register(
        self: *State,
        alloc: Allocator,
        payload: []const u8,
        continuation: bool,
        more: bool,
    ) Allocator.Error!?Event {
        const list = &self.drop.registered_mimes;
        if (!continuation) list.clearRetainingCapacity();

        // Matching kitty, an over-cap chunk is dropped and does not
        // complete the registration.
        if (list.items.len + payload.len > max_mime_list_bytes) return null;
        try list.appendSlice(alloc, payload);

        return if (more) null else .registration;
    }

    /// The client's acceptance response for the drag currently over the
    /// terminal, for OS drag feedback. Null when the client hasn't
    /// responded yet or `none` when the client rejected the drag. Either
    /// way the drag isn't accepted, as in kitty: a drop the client hasn't
    /// accepted is never read or concluded, so embedders refuse it.
    pub fn clientAccepted(self: *const State) ?Operation {
        if (self.drop.accept_in_progress) return null;
        return self.drop.accepted;
    }

    /// Iterate the MIME types the client accepted for the current drag,
    /// most preferred first. Empty until the client answered with a
    /// list.
    pub fn acceptedMimes(self: *const State) std.mem.TokenIterator(u8, .scalar) {
        const items = if (self.drop.accept_in_progress) "" else self.drop.accepted_mimes.items;
        return std.mem.tokenizeScalar(u8, items, 0);
    }

    /// The data request the embedder must serve, if any.
    pub fn request(self: *const State) ?DataRequest {
        const serving = self.drop.serving orelse return null;
        return .{
            .id = serving.id,
            .mime_index = serving.mime_index,
            .mime = self.drop.offered.?.mimes[serving.mime_index],
        };
    }

    /// Free the offered MIME list of the current drag.
    fn freeOffered(self: *State, alloc: Allocator) void {
        if (self.drop.offered) |*offered| {
            offered.deinit(alloc);
            self.drop.offered = null;
        }
    }

    /// Clear the per-drag state while preserving the registration,
    /// mirroring kitty's reset_drop. Called when a new drag enters and
    /// when a drop concludes.
    fn resetDrop(self: *State, alloc: Allocator) void {
        self.freeOffered(alloc);
        self.drop.accepted_mimes.clearAndFree(alloc);
        self.drop.hovered = false;
        self.drop.dropped = false;
        self.drop.accepted = null;
        self.drop.accept_in_progress = false;
        self.drop.queue.clear();
        self.drop.serving = null;
    }

    /// Handle a t=m acceptance status update from the client, mirroring
    /// kitty's drop_set_status.
    fn acceptStatus(
        self: *State,
        alloc: Allocator,
        meta: Metadata,
        payload: []const u8,
    ) Allocator.Error!?Event {
        const d = &self.drop;
        if (!d.accept_in_progress) {
            d.accepted_mimes.clearRetainingCapacity();
            d.accept_in_progress = true;
            d.accepted = .fromProtocol(meta.operation);
        }

        if (payload.len > 0) {
            // Matching kitty, an over-cap list stops accumulating and
            // never finalizes, leaving the acceptance unanswered.
            if (d.accepted_mimes.items.len + payload.len > max_mime_list_bytes) return null;
            try d.accepted_mimes.appendSlice(alloc, payload);
        }

        if (meta.more) return null;
        d.accept_in_progress = false;
        if (d.accepted_mimes.items.len > 0) {
            for (d.accepted_mimes.items) |*c| {
                if (c.* == ' ') c.* = 0;
            }
            try d.accepted_mimes.append(alloc, 0);
        }
        return .acceptance;
    }

    /// Handle a t=r data request or drop conclusion from the client,
    /// mirroring kitty's drop_enqueue_request.
    fn dataRequest(
        self: *State,
        alloc: Allocator,
        writer: *std.Io.Writer,
        req: command.Request,
        terminator: osc.Terminator,
    ) std.Io.Writer.Error!?Event {
        const d = &self.drop;

        if (req == .conclude) {
            // The client is done with the drop. A conclusion with no
            // drop in progress is a no-op.
            const dropped = d.dropped;
            self.resetDrop(alloc);
            return if (dropped) Event.concluded(req.conclude) else null;
        }

        // The user has not dropped anything, so the client is not
        // allowed to read any drag data: movement events are
        // informational only and consent to the transfer is the drop.
        if (!d.dropped) {
            try sendError(
                writer,
                req,
                d.client_id,
                .EPERM,
                "drop data can only be requested after a drop",
                terminator,
            );
            return null;
        }

        if (d.queue.len >= max_requests) {
            // Too many requests: deny and end the drop.
            try sendError(
                writer,
                req,
                d.client_id,
                .EMFILE,
                "too many drop data requests",
                terminator,
            );
            const op = self.clientAccepted() orelse .none;
            self.resetDrop(alloc);
            return Event.concluded(op);
        }

        const was_empty = d.queue.len == 0;
        d.queue.push(.{ .request = req, .terminator = terminator });
        if (!was_empty) return null;

        try self.process(writer);
        return if (d.serving != null) .data_request else null;
    }

    /// Answer queued requests that need no data from the embedder
    /// (errors) until one does or the queue is empty.
    fn process(self: *State, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const d = &self.drop;
        assert(d.serving == null);
        while (d.queue.peek()) |queued| {
            switch (queued.request) {
                .mime => |idx| {
                    const mimes = if (d.offered) |o| o.mimes else &.{};
                    if (idx >= 1 and idx <= mimes.len) {
                        d.serving = .{
                            .id = d.next_id,
                            .mime_index = @intCast(idx - 1),
                            .terminator = queued.terminator,
                        };
                        d.next_id +%= 1;
                        if (d.next_id == 0) d.next_id = 1;
                        return;
                    }

                    try sendError(
                        writer,
                        queued.request,
                        d.client_id,
                        .ENOENT,
                        "drop data request index out of bounds",
                        queued.terminator,
                    );
                },

                // Remote drop transfers (URI file contents and directory
                // handles). We never advertise remote support (no X=1
                // marker), so a conforming client never sends these.
                .uri, .dir => try sendError(
                    writer,
                    queued.request,
                    d.client_id,
                    .EINVAL,
                    "remote drop data is not supported",
                    queued.terminator,
                ),

                .conclude => unreachable,
            }

            d.queue.pop();
        }
    }

    /// Send some of the data for the request being served. The data is
    /// sent as it is given (as kitty sends data as the OS delivers it),
    /// so any chunking is acceptable. Returns error.Stale when `id` is
    /// not the request being served.
    pub fn respondData(
        self: *State,
        writer: *std.Io.Writer,
        id: u32,
        data: []const u8,
    ) (error{Stale} || std.Io.Writer.Error)!void {
        const serving = try self.servingRequest(id);
        if (data.len == 0) return;
        try response.encode(
            writer,
            dataHeader(serving).slice(),
            self.drop.client_id,
            data,
            .base64,
            serving.terminator,
        );
    }

    /// Finish the request being served by sending the end-of-data
    /// message. Returns the next request to serve, if any.
    pub fn respondEnd(
        self: *State,
        writer: *std.Io.Writer,
        id: u32,
    ) (error{Stale} || std.Io.Writer.Error)!?DataRequest {
        const serving = try self.servingRequest(id);
        try response.encode(
            writer,
            dataHeader(serving).slice(),
            self.drop.client_id,
            "",
            .base64,
            serving.terminator,
        );
        return try self.next(writer);
    }

    /// Fail the request being served, e.g. when reading the data from
    /// the native drop failed. Returns the next request to serve, if
    /// any.
    pub fn respondError(
        self: *State,
        writer: *std.Io.Writer,
        id: u32,
        errno: Errno,
    ) (error{Stale} || std.Io.Writer.Error)!?DataRequest {
        _ = try self.servingRequest(id);
        const queued = self.drop.queue.peek().?;
        try sendError(
            writer,
            queued.request,
            self.drop.client_id,
            errno,
            "drop data request failed to read data",
            queued.terminator,
        );
        return try self.next(writer);
    }

    fn servingRequest(self: *const State, id: u32) error{Stale}!Serving {
        const serving = self.drop.serving orelse return error.Stale;
        if (serving.id != id) return error.Stale;
        return serving;
    }

    /// Pop the served request and move on to the next.
    fn next(self: *State, writer: *std.Io.Writer) std.Io.Writer.Error!?DataRequest {
        self.drop.serving = null;
        self.drop.queue.pop();
        try self.process(writer);
        return self.request();
    }

    const Header = struct {
        buf: [32]u8,
        len: usize,

        fn slice(self: *const Header) []const u8 {
            return self.buf[0..self.len];
        }
    };

    fn dataHeader(serving: Serving) Header {
        var h: Header = .{ .buf = undefined, .len = 0 };
        const keys: response.RequestKeys = .{ .x = @intCast(serving.mime_index + 1) };
        h.len = (std.mem.print(&h.buf, "t=r{f}", .{keys}) catch unreachable).len;
        return h;
    }

    /// A native drag position report from the embedder.
    pub const MoveEvent = struct {
        /// Grid cell under the pointer, zero-based from the top-left.
        cell_x: u32,
        cell_y: u32,

        /// Pointer position in pixels relative to the top-left of the
        /// terminal's content area.
        pixel_x: i32,
        pixel_y: i32,

        /// The operations the drag source allows.
        operations: Operations,
    };

    /// Report a native drag moving over the terminal, sending a t=m
    /// move event to the client. `mimes` is the list of MIME types of
    /// the drag, in the order data request indices will refer to.
    ///
    /// Returns true when the drag entering discarded an unconcluded
    /// previous drop, which the embedder must finish natively.
    pub fn dragMove(
        self: *State,
        alloc: Allocator,
        writer: *std.Io.Writer,
        ev: MoveEvent,
        mimes: []const []const u8,
    ) (Allocator.Error || std.Io.Writer.Error)!bool {
        return try self.moveEvent(alloc, writer, ev, mimes, false);
    }

    /// Report a native drop onto the terminal, sending a t=M drop event
    /// listing the MIME types the data can be requested as. The
    /// embedder keeps the native drop open to serve the client's data
    /// requests until it concludes.
    ///
    /// Returns true when the drop discarded an unconcluded previous
    /// drop, which the embedder must finish natively.
    pub fn dragDrop(
        self: *State,
        alloc: Allocator,
        writer: *std.Io.Writer,
        ev: MoveEvent,
        mimes: []const []const u8,
    ) (Allocator.Error || std.Io.Writer.Error)!bool {
        return try self.moveEvent(alloc, writer, ev, mimes, true);
    }

    /// Report the native drag leaving the terminal, sending the t=m
    /// leave event (x=-1, y=-1).
    ///
    /// Ignored after a drop: some toolkits emit a leave notification
    /// for the drop itself, and the drop must survive until the client
    /// concludes.
    pub fn dragLeave(
        self: *State,
        alloc: Allocator,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (self.drop.dropped) return;
        const hovered = self.drop.hovered;
        self.drop.hovered = false;
        self.freeOffered(alloc);

        // Only a client that saw the drag enter gets the leave event,
        // matching kitty which notifies hovered windows only.
        if (!hovered) return;

        try response.encode(
            writer,
            "t=m:x=-1:y=-1",
            self.drop.client_id,
            "",
            .plain,
            .st,
        );
    }

    /// Shared implementation of move and drop events, mirroring kitty's
    /// drop_move_on_child.
    fn moveEvent(
        self: *State,
        alloc: Allocator,
        writer: *std.Io.Writer,
        ev: MoveEvent,
        mimes: []const []const u8,
        is_drop: bool,
    ) (Allocator.Error || std.Io.Writer.Error)!bool {
        var discarded = false;
        if (!self.drop.hovered) {
            discarded = self.drop.dropped;
            self.resetDrop(alloc);
            self.drop.hovered = true;
        }
        if (is_drop) {
            self.drop.dropped = true;
            self.drop.hovered = false;
        }

        // (Re)build the offered MIME list when it changed.
        if (self.drop.offered == null or !self.drop.offered.?.eql(mimes)) {
            self.freeOffered(alloc);
            self.drop.offered = try Offered.init(alloc, mimes);
        }

        var header_buf: [96]u8 = undefined;
        const header = std.mem.print(
            &header_buf,
            "t={c}:x={d}:y={d}:X={d}:Y={d}:o={d}",
            .{
                @as(u8, if (is_drop) 'M' else 'm'),
                ev.cell_x,
                ev.cell_y,
                ev.pixel_x,
                ev.pixel_y,
                ev.operations.protocolValue(),
            },
        ) catch unreachable;

        // The MIME list is sent with every move event, matching kitty
        // (the spec suggests only the first, but kitty always sends it
        // and clients depend on that).
        try response.encode(
            writer,
            header,
            self.drop.client_id,
            self.drop.offered.?.payload,
            .plain,
            .st,
        );

        return discarded;
    }
};
