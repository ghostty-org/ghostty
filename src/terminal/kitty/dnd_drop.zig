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

const log = std.log.scoped(.kitty_dnd);

/// Maximum accumulated size of a client-sent MIME list (the accepted
/// list of a `t=m` status update). Matches kitty's MIME_LIST_SIZE_CAP.
pub const max_mime_list_bytes = 1024 * 1024;

/// Process one OSC 72 command received from the client, writing any
/// responses to the writer. Returns the state change the embedder may
/// need to act on, if any.
pub fn handleCommand(
    slot: *?*State,
    alloc: Allocator,
    writer: *std.Io.Writer,
    v: osc.Command.KittyDndProtocol,
) (Allocator.Error || std.Io.Writer.Error)!?Event {
    const raw = Metadata.parse(v.metadata) orelse {
        log.debug("dropping malformed OSC 72 metadata", .{});
        return null;
    };

    // Chunk reassembly lives in the state, so before registration
    // each command stands alone. The only legitimately chunked
    // command before registration is t=a itself, which seeds the
    // reassembly on its first chunk below.
    const continuation = if (slot.*) |state| state.chunking.active else false;
    const meta = if (slot.*) |state| state.chunking.apply(raw) else raw;
    const payload = v.payload orelse "";
    const t = meta.type orelse return null;

    switch (t) {
        .register => {
            // x=1 declares the client's machine ID for remote drop
            // support. We don't support remote drop yet, so accept and ignore.
            if (meta.cell_x == 1) return null;

            // Setup our state if we haven't already
            const state = slot.* orelse state: {
                const state = try State.create(alloc);
                slot.* = state;
                _ = state.chunking.apply(raw);
                break :state state;
            };

            // Update the client ID on every registration
            state.drop.client_id = meta.client_id;

            return try state.register(
                alloc,
                payload,
                continuation,
                meta.more,
            );
        },

        .unregister => {
            const state = slot.* orelse return null;
            state.destroy(alloc);
            slot.* = null;
            return .registration;
        },

        .status => {
            const state = slot.* orelse return null;
            return try state.acceptStatus(alloc, meta, payload);
        },

        .request => return try dataRequest(
            slot.*,
            alloc,
            writer,
            meta,
            v.terminator,
        ),

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

    return null;
}

/// Handle a t=r data request or drop conclusion from the client.
/// Requests from an unregistered client (no state) get the same
/// errors kitty sends from its zeroed drop state.
fn dataRequest(
    state: ?*State,
    alloc: Allocator,
    writer: *std.Io.Writer,
    meta: Metadata,
    terminator: osc.Terminator,
) (Allocator.Error || std.Io.Writer.Error)!?Event {
    // Responses echo the registration's client ID, matching kitty.
    const client_id = if (state) |s| s.drop.client_id else 0;

    switch (command.Request.init(meta)) {
        .conclude => |op| {
            // The client is done with the drop: free the held data and
            // report the operation it performed. Kitty hands that to
            // the still-open OS drag session; ours ended at drop time
            // (see dnd.zig), so the embedder decides what to do with
            // it. A conclusion with no drop in progress is a no-op.
            const s = state orelse return null;
            const dropped = s.drop.dropped;
            s.resetDrop(alloc);
            return if (dropped) Event.concluded(op) else null;
        },

        .mime => |idx| {
            const keys: response.RequestKeys = .{ .x = idx };
            const items = (if (state) |s| s.drop.items else null) orelse {
                try response.encodeError(
                    writer,
                    .drop,
                    keys,
                    client_id,
                    .ENOENT,
                    "no drop data available",
                    terminator,
                );
                return null;
            };
            if (idx < 1 or @as(usize, @intCast(idx)) > items.len) {
                try response.encodeError(
                    writer,
                    .drop,
                    keys,
                    client_id,
                    .ENOENT,
                    "drop data request index out of bounds",
                    terminator,
                );
                return null;
            }

            var header_buf: [32]u8 = undefined;
            const header = std.fmt.bufPrint(
                &header_buf,
                "t=r{f}",
                .{keys},
            ) catch unreachable;

            // The data chunks followed by the empty end-of-data
            // message, which is how the client detects completion.
            // An empty item is just the end-of-data message alone;
            // clients treat a duplicate as a second completion.
            const item = items[@intCast(idx - 1)];
            if (item.data.len > 0) try response.encode(
                writer,
                header,
                client_id,
                item.data,
                .base64,
                terminator,
            );
            try response.encode(writer, header, client_id, "", .base64, terminator);
            return null;
        },

        // Remote drop transfers (URI file contents and directory
        // handles). We never advertise remote support (no X=1
        // marker), so a conforming client never sends these.
        .uri => |uri| try response.encodeError(
            writer,
            .drop,
            .{ .x = uri.mime_idx, .y = uri.uri_idx },
            client_id,
            .EINVAL,
            "remote drop data is not supported",
            terminator,
        ),
        .dir => |dir| try response.encodeError(
            writer,
            .drop,
            .{ .x = dir.entry, .Y = dir.handle },
            client_id,
            .EINVAL,
            "remote drop data is not supported",
            terminator,
        ),
    }

    return null;
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

    /// The client concluded a drop, performing no operation (it
    /// canceled), a copy, or a move. The held drop data has been freed.
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
///      types it can serve if dropped. This sends the client a t=m
///      move event; when the slot is null the embedder should handle
///      the drag as it would without the protocol.
///   3. The client answers with its acceptance (t=m:o=N), recorded by
///      `handleCommand` which yields an `acceptance` event. The
///      embedder reads `clientAccepted` then and on subsequent moves
///      to give the OS drag session its feedback.
///   4. The drag either leaves, and the embedder calls `dragLeave` to
///      send the t=m leave event, or drops: the embedder captures the
///      representations it advertised and calls `dragDrop`, which
///      copies and holds them and sends the client a t=M drop event. A
///      new drag entering before the client concludes discards the
///      held drop.
///   5. The client requests data (t=r:x=N), which `handleCommand`
///      serves from the held copies, and then concludes the drop
///      (t=r:o=N), which frees them and yields a `concluded_*` event
///      naming the operation the client performed.
///   6. The client unregisters (t=A) and `handleCommand` frees the
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

        /// The data captured at drop time, parallel to `offered`.
        items: ?[]const Item = null,
    };

    /// One dropped representation: a MIME type and its data.
    pub const Item = struct {
        mime: []const u8,
        data: []const u8,
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

    /// The maximum number of dropped items. Embedders provide a small
    /// curated set of representations (see dnd.zig), so this is a
    /// generous bound that keeps the MIME list assembly on the stack.
    pub const max_items = 16;

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
        self.freeDragData(alloc);
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
    /// responded yet (embedders should fall back to their default,
    /// typically copy) or `none` when the client rejected the drag.
    pub fn clientAccepted(self: *const State) ?Operation {
        if (self.drop.accept_in_progress) return null;
        return self.drop.accepted;
    }

    /// Free the per-drag data (offered MIME list and held drop items).
    fn freeDragData(self: *State, alloc: Allocator) void {
        if (self.drop.offered) |*offered| {
            offered.deinit(alloc);
            self.drop.offered = null;
        }
        if (self.drop.items) |items| {
            for (items) |item| {
                alloc.free(item.mime);
                alloc.free(item.data);
            }
            alloc.free(items);
            self.drop.items = null;
        }
    }

    /// Clear the per-drag state while preserving the registration,
    /// mirroring kitty's reset_drop. Called when a new drag enters and
    /// when a drop concludes.
    fn resetDrop(self: *State, alloc: Allocator) void {
        self.freeDragData(alloc);
        self.drop.accepted_mimes.clearAndFree(alloc);
        self.drop.hovered = false;
        self.drop.dropped = false;
        self.drop.accepted = null;
        self.drop.accept_in_progress = false;
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
    /// move event to the client. `mimes` is the list of MIME types the
    /// terminal can provide for this drag, in the order data request
    /// indices will refer to.
    pub fn dragMove(
        self: *State,
        alloc: Allocator,
        writer: *std.Io.Writer,
        ev: MoveEvent,
        mimes: []const []const u8,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        try self.moveEvent(
            alloc,
            writer,
            ev,
            mimes,
            false,
        );
    }

    /// Report a native drop onto the terminal. The items' data is
    /// copied and held so the client's data requests can be served; it
    /// is freed when the client concludes the drop, a new drag enters,
    /// or the client unregisters.
    ///
    /// Sends a t=M drop event listing the items' MIME types.
    pub fn dragDrop(
        self: *State,
        alloc: Allocator,
        writer: *std.Io.Writer,
        ev: MoveEvent,
        items: []const Item,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        // Copy the items so they can be served after this call returns.
        // Items beyond the cap are dropped so the held list always
        // matches the advertised MIME list.
        const accepted_items = items[0..@min(items.len, max_items)];
        const copies = try alloc.alloc(Item, accepted_items.len);
        errdefer alloc.free(copies);
        var copied: usize = 0;
        errdefer for (copies[0..copied]) |item| {
            alloc.free(item.mime);
            alloc.free(item.data);
        };
        for (accepted_items, copies) |item, *copy| {
            const mime = try alloc.dupe(u8, item.mime);
            errdefer alloc.free(mime);
            const data = try alloc.dupe(u8, item.data);
            copy.* = .{ .mime = mime, .data = data };
            copied += 1;
        }

        // The move handling below resets per-drag state when this drop
        // arrives without a preceding move, so the items are attached
        // after it runs. Collect the MIME list first.
        var mimes_buf: [max_items][]const u8 = undefined;
        const mimes = mimes_buf[0..copies.len];
        for (mimes, copies) |*m, item| m.* = item.mime;

        try self.moveEvent(
            alloc,
            writer,
            ev,
            mimes,
            true,
        );

        assert(self.drop.items == null);
        self.drop.items = copies;
    }

    /// Report the native drag leaving the terminal, sending the t=m
    /// leave event (x=-1, y=-1).
    ///
    /// Ignored after a drop: some toolkits emit a leave notification
    /// for the drop itself, and the held data must survive until the
    /// client concludes.
    pub fn dragLeave(
        self: *State,
        alloc: Allocator,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (self.drop.dropped) return;
        const hovered = self.drop.hovered;
        self.drop.hovered = false;
        if (self.drop.offered) |*offered| {
            offered.deinit(alloc);
            self.drop.offered = null;
        }

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
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        if (!self.drop.hovered) {
            self.resetDrop(alloc);
            self.drop.hovered = true;
        }
        if (is_drop) {
            self.drop.dropped = true;
            self.drop.hovered = false;
        }

        // (Re)build the offered MIME list when it changed.
        if (self.drop.offered == null or !self.drop.offered.?.eql(mimes)) {
            if (self.drop.offered) |*offered| offered.deinit(alloc);
            self.drop.offered = null;
            self.drop.offered = try Offered.init(alloc, mimes);
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
            self.drop.client_id,
            self.drop.offered.?.payload,
            .plain,
            .st,
        );
    }
};
