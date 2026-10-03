//! Kitty drag and drop protocol (OSC 72): the drop target, which
//! forwards native drags over the terminal to the client and serves
//! the dropped data on request.

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

/// Maximum accumulated size of a client-sent MIME list (a registration
/// list, an accepted list, or a drag offer). Matches kitty's
/// MIME_LIST_SIZE_CAP.
pub const max_mime_list_bytes = 1024 * 1024;

/// The maximum number of queued data requests. Matches kitty; one more
/// is refused with EMFILE and ends the drop.
pub const max_requests = 128;

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

    /// The MIME type to read. Borrowed from the drop target and valid
    /// until the drop ends.
    mime: []const u8,
};

/// Drop target state for the client registered to accept drops.
///
/// The lifecycle of a drop, as seen by the embedder:
///
///   1. The client registers (t=a), yielding a `registration` event so
///      the embedder can register any declared MIME types with the OS
///      (`registeredMimes`).
///   2. A native drag enters or moves over the terminal. While
///      `registered`, the embedder calls `dragMove` with the pointer
///      position, the operations the drag source allows, and the MIME
///      types of the drag. Otherwise it should handle the drag as it
///      would without the protocol.
///   3. The client answers with its acceptance (t=m:o=N), yielding an
///      `acceptance` event. The embedder reads `clientAccepted` then and
///      on subsequent moves to give the OS drag session its feedback.
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
pub const DropTarget = struct {
    /// True while a client is registered to accept drops.
    registered: bool = false,

    /// Multiplexer client ID from registration, echoed in every
    /// drop-side message the terminal sends.
    client_id: u32 = 0,

    /// The MIME list the client registered with (the t=a payload),
    /// space-separated as received and accumulated across chunks.
    /// Only needed by embedders that must register types with the
    /// OS ahead of a drag; kitty frees it after doing so, we keep
    /// it so the `registration` event can be acted on from here.
    registered_mimes: std.ArrayListUnmanaged(u8) = .empty,

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
    accepted_mimes: std.ArrayListUnmanaged(u8) = .empty,

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

    pub fn deinit(self: *DropTarget, alloc: Allocator) void {
        self.freeOffered(alloc);
        self.accepted_mimes.deinit(alloc);
        self.registered_mimes.deinit(alloc);
        self.* = .{};
    }

    /// Iterate the MIME types the client registered with, in order.
    /// Empty when the client declared none, which is the common case.
    /// The list is only needed to register exotic types with the OS,
    /// such as macOS pasteboard stuff.
    pub fn registeredMimes(self: *const DropTarget) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, self.registered_mimes.items, ' ');
    }

    /// The client's acceptance response for the drag currently over the
    /// terminal, for OS drag feedback. Null when the client hasn't
    /// responded yet (embedders should fall back to their default,
    /// typically copy) or `none` when the client rejected the drag.
    pub fn clientAccepted(self: *const DropTarget) ?Operation {
        if (self.accept_in_progress) return null;
        return self.accepted;
    }

    /// Iterate the MIME types the client accepted for the current drag,
    /// most preferred first. Empty until the client answered with a
    /// list.
    pub fn acceptedMimes(self: *const DropTarget) std.mem.TokenIterator(u8, .scalar) {
        const items = if (self.accept_in_progress) "" else self.accepted_mimes.items;
        return std.mem.tokenizeScalar(u8, items, 0);
    }

    /// The data request the embedder must serve, if any.
    pub fn request(self: *const DropTarget) ?DataRequest {
        const serving = self.serving orelse return null;
        return .{
            .id = serving.id,
            .mime_index = serving.mime_index,
            .mime = self.offered.?.mimes[serving.mime_index],
        };
    }

    /// Record one chunk of a registration's MIME list.
    ///
    /// `continuation` is true for every chunk but the first of a chunked
    /// registration. Returns true once the list is complete.
    pub fn register(
        self: *DropTarget,
        alloc: Allocator,
        client_id: u32,
        payload: []const u8,
        continuation: bool,
        more: bool,
    ) Allocator.Error!bool {
        self.registered = true;
        self.client_id = client_id;

        const list = &self.registered_mimes;
        if (!continuation) list.clearRetainingCapacity();

        // Matching kitty, an over-cap chunk is dropped and does not
        // complete the registration.
        if (list.items.len + payload.len > max_mime_list_bytes) return false;
        try list.appendSlice(alloc, payload);

        return !more;
    }

    /// Unregister the client, freeing all drop state. Returns true when
    /// an unconcluded drop was discarded, which the embedder must
    /// finish natively.
    pub fn unregister(self: *DropTarget, alloc: Allocator) bool {
        const dropped = self.dropped;
        self.deinit(alloc);
        return dropped;
    }

    /// Handle a t=m acceptance status update from the client, mirroring
    /// kitty's drop_set_status. Returns true once the acceptance is
    /// complete.
    pub fn acceptStatus(
        self: *DropTarget,
        alloc: Allocator,
        meta: Metadata,
        payload: []const u8,
    ) Allocator.Error!bool {
        if (!self.accept_in_progress) {
            self.accepted_mimes.clearRetainingCapacity();
            self.accept_in_progress = true;
            self.accepted = .fromProtocol(meta.operation);
        }

        if (payload.len > 0) {
            // Matching kitty, an over-cap list stops accumulating and
            // never finalizes, leaving the acceptance unanswered.
            if (self.accepted_mimes.items.len + payload.len > max_mime_list_bytes) return false;
            try self.accepted_mimes.appendSlice(alloc, payload);
        }

        if (meta.more) return false;
        self.accept_in_progress = false;
        if (self.accepted_mimes.items.len > 0) {
            for (self.accepted_mimes.items) |*c| {
                if (c.* == ' ') c.* = 0;
            }
            try self.accepted_mimes.append(alloc, 0);
        }
        return true;
    }

    /// The result of a t=r command from the client.
    pub const RequestResult = union(enum) {
        /// Nothing for the embedder to do.
        none,

        /// A data request now needs serving: see `request`.
        serve,

        /// The drop ended with the given operation. Any request being
        /// served is abandoned.
        concluded: Operation,
    };

    /// Handle a t=r data request or drop conclusion from the client,
    /// mirroring kitty's drop_enqueue_request.
    pub fn dataRequest(
        self: *DropTarget,
        alloc: Allocator,
        writer: *std.Io.Writer,
        meta: Metadata,
        terminator: osc.Terminator,
    ) std.Io.Writer.Error!RequestResult {
        const req: command.Request = .init(meta);

        if (req == .conclude) {
            // The client is done with the drop. A conclusion with no
            // drop in progress is a no-op.
            const dropped = self.dropped;
            self.resetDrop(alloc);
            return if (dropped) .{ .concluded = req.conclude } else .none;
        }

        // The user has not dropped anything, so the client is not
        // allowed to read any drag data: movement events are
        // informational only and consent to the transfer is the drop.
        if (!self.dropped) {
            try self.sendError(
                writer,
                req,
                .EPERM,
                "drop data can only be requested after a drop",
                terminator,
            );
            return .none;
        }

        if (self.queue.len >= max_requests) {
            // Too many requests: deny and end the drop.
            try self.sendError(
                writer,
                req,
                .EMFILE,
                "too many drop data requests",
                terminator,
            );
            const op = self.clientAccepted() orelse .none;
            self.resetDrop(alloc);
            return .{ .concluded = op };
        }

        const was_empty = self.queue.len == 0;
        self.queue.push(.{ .request = req, .terminator = terminator });
        if (!was_empty) return .none;

        try self.process(writer);
        return if (self.serving != null) .serve else .none;
    }

    /// Answer queued requests that need no data from the embedder
    /// (errors) until one does or the queue is empty.
    fn process(self: *DropTarget, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        assert(self.serving == null);
        while (self.queue.peek()) |queued| {
            switch (queued.request) {
                .mime => |idx| {
                    const mimes = if (self.offered) |o| o.mimes else &.{};
                    if (idx >= 1 and idx <= mimes.len) {
                        self.serving = .{
                            .id = self.next_id,
                            .mime_index = @intCast(idx - 1),
                            .terminator = queued.terminator,
                        };
                        self.next_id +%= 1;
                        if (self.next_id == 0) self.next_id = 1;
                        return;
                    }

                    try self.sendError(
                        writer,
                        queued.request,
                        .ENOENT,
                        "drop data request index out of bounds",
                        queued.terminator,
                    );
                },

                // Remote drop transfers (URI file contents and directory
                // handles). We never advertise remote support (no X=1
                // marker), so a conforming client never sends these.
                .uri, .dir => try self.sendError(
                    writer,
                    queued.request,
                    .EINVAL,
                    "remote drop data is not supported",
                    queued.terminator,
                ),

                .conclude => unreachable,
            }

            self.queue.pop();
        }
    }

    /// Send some of the data for the request being served. The data is
    /// sent as it is given (as kitty sends data as the OS delivers it),
    /// so any chunking is acceptable. Returns error.Stale when `id` is
    /// not the request being served.
    pub fn respondData(
        self: *DropTarget,
        writer: *std.Io.Writer,
        id: u32,
        data: []const u8,
    ) (error{Stale} || std.Io.Writer.Error)!void {
        const serving = try self.servingRequest(id);
        if (data.len == 0) return;
        try response.encode(
            writer,
            dataHeader(serving).slice(),
            self.client_id,
            data,
            .base64,
            serving.terminator,
        );
    }

    /// Finish the request being served by sending the end-of-data
    /// message. Returns the next request to serve, if any.
    pub fn respondEnd(
        self: *DropTarget,
        writer: *std.Io.Writer,
        id: u32,
    ) (error{Stale} || std.Io.Writer.Error)!?DataRequest {
        const serving = try self.servingRequest(id);
        try response.encode(
            writer,
            dataHeader(serving).slice(),
            self.client_id,
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
        self: *DropTarget,
        writer: *std.Io.Writer,
        id: u32,
        errno: Errno,
    ) (error{Stale} || std.Io.Writer.Error)!?DataRequest {
        _ = try self.servingRequest(id);
        const queued = self.queue.peek().?;
        try self.sendError(
            writer,
            queued.request,
            errno,
            "drop data request failed to read data",
            queued.terminator,
        );
        return try self.next(writer);
    }

    fn servingRequest(self: *const DropTarget, id: u32) error{Stale}!Serving {
        const serving = self.serving orelse return error.Stale;
        if (serving.id != id) return error.Stale;
        return serving;
    }

    /// Pop the served request and move on to the next.
    fn next(self: *DropTarget, writer: *std.Io.Writer) std.Io.Writer.Error!?DataRequest {
        self.serving = null;
        self.queue.pop();
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
        h.len = (std.fmt.bufPrint(&h.buf, "t=r{f}", .{keys}) catch unreachable).len;
        return h;
    }

    /// Send an error for a request, echoing its keys.
    fn sendError(
        self: *const DropTarget,
        writer: *std.Io.Writer,
        req: command.Request,
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
            self.client_id,
            errno,
            desc,
            terminator,
        );
    }

    fn freeOffered(self: *DropTarget, alloc: Allocator) void {
        if (self.offered) |*offered| {
            offered.deinit(alloc);
            self.offered = null;
        }
    }

    /// Clear the per-drag state while preserving the registration,
    /// mirroring kitty's reset_drop. Called when a new drag enters and
    /// when a drop concludes.
    fn resetDrop(self: *DropTarget, alloc: Allocator) void {
        self.freeOffered(alloc);
        self.accepted_mimes.clearAndFree(alloc);
        self.hovered = false;
        self.dropped = false;
        self.accepted = null;
        self.accept_in_progress = false;
        self.queue.clear();
        self.serving = null;
    }

    /// Report a native drag moving over the terminal, sending a t=m
    /// move event to the client. `mimes` is the list of MIME types of
    /// the drag, in the order data request indices will refer to.
    ///
    /// Returns true when the drag entering discarded an unconcluded
    /// previous drop, which the embedder must finish natively.
    pub fn dragMove(
        self: *DropTarget,
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
        self: *DropTarget,
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
        self: *DropTarget,
        alloc: Allocator,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (self.dropped) return;
        const hovered = self.hovered;
        self.hovered = false;
        self.freeOffered(alloc);

        // Only a client that saw the drag enter gets the leave event,
        // matching kitty which notifies hovered windows only.
        if (!hovered) return;

        try response.encode(
            writer,
            "t=m:x=-1:y=-1",
            self.client_id,
            "",
            .plain,
            .st,
        );
    }

    /// Shared implementation of move and drop events, mirroring kitty's
    /// drop_move_on_child.
    fn moveEvent(
        self: *DropTarget,
        alloc: Allocator,
        writer: *std.Io.Writer,
        ev: MoveEvent,
        mimes: []const []const u8,
        is_drop: bool,
    ) (Allocator.Error || std.Io.Writer.Error)!bool {
        var discarded = false;
        if (!self.hovered) {
            discarded = self.dropped;
            self.resetDrop(alloc);
            self.hovered = true;
        }
        if (is_drop) {
            self.dropped = true;
            self.hovered = false;
        }

        // (Re)build the offered MIME list when it changed.
        if (self.offered == null or !self.offered.?.eql(mimes)) {
            self.freeOffered(alloc);
            self.offered = try Offered.init(alloc, mimes);
        }

        var header_buf: [96]u8 = undefined;
        const header = std.fmt.bufPrint(
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
            self.client_id,
            self.offered.?.payload,
            .plain,
            .st,
        );

        return discarded;
    }
};
