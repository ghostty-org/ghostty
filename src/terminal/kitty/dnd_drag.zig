//! Kitty drag and drop protocol (OSC 72): the drag source, which lets
//! the client start native drags out of the terminal and supplies their
//! data.

const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = @import("../../quirks.zig").inlineAssert;
const simd = @import("../../simd/main.zig");
const osc = @import("../osc.zig");
const command = @import("dnd_command.zig");
const response = @import("dnd_response.zig");
const dnd_drop = @import("dnd_drop.zig");

const Metadata = command.Metadata;
const Operation = command.Operation;
const Operations = command.Operations;
const Errno = response.Errno;

/// The maximum base64 payload bytes accepted for each of a drag's
/// pre-sent data and its images. Matches kitty's PRESENT_DATA_CAP,
/// which the spec requires to be at least 64MB.
pub const max_present_bytes = 64 * 1024 * 1024;

/// The maximum decoded bytes of drag data held for the embedder after
/// the drag started, i.e. received from the client and not yet taken.
/// Kitty spools this to a temporary file instead; we buffer it.
pub const max_buffered_bytes = 64 * 1024 * 1024;

/// The number of drag image slots. Matches kitty, which uses image
/// numbers 1 through 14 (`x=-1` to `x=-14`).
pub const image_slots = 16;

/// A position on the terminal, as sent when the user starts a drag.
pub const Position = struct {
    /// Grid cell, zero-based from the top-left.
    cell_x: u32,
    cell_y: u32,

    /// Pixels relative to the top-left of the terminal's content area.
    pixel_x: i32,
    pixel_y: i32,
};

/// The phase of the drag being offered.
pub const Phase = enum {
    /// No drag is offered.
    none,

    /// The client is building an offer: its MIME list, pre-sent data,
    /// and images.
    building,

    /// The client asked to start the drag (t=P:x=-1). The embedder
    /// must start the native drag and report the result with
    /// `startResult`.
    starting,

    /// The native drag is in progress.
    started,

    /// The native drag was dropped onto a target, which may still
    /// request data.
    dropped,
};

/// The format of a drag image, the protocol's `y` key.
pub const ImageFormat = enum(u8) {
    /// UTF-8 text to be rendered as the image; `width` and `height` are
    /// the numerator and denominator of the font size scale, and
    /// `opacity` the background opacity.
    text = 0,

    /// 24-bit RGB pixels. Expanded to RGBA when the drag starts.
    rgb = 24,

    /// 32-bit RGBA pixels.
    rgba = 32,

    /// A PNG image.
    png = 100,
};

/// A drag image.
pub const Image = struct {
    format: ImageFormat,
    width: u32,
    height: u32,

    /// Background opacity for text images, 0 (transparent) through
    /// 1024 (opaque).
    opacity: u32,

    /// The decoded image data.
    data: []const u8,
};

/// A notification from the embedder about the native drag, sent to the
/// client as a t=e event.
pub const Report = union(enum) {
    /// The drop target accepted the drag, preferring the given offered
    /// MIME index if known.
    accepted: ?u32,

    /// The operation the drag would perform changed.
    operation: Operation,

    /// The drag was dropped onto a target.
    dropped,

    /// The drag finished, or was canceled. This ends the drag.
    finished: bool,
};

/// The data available for one offered MIME type after the drag started.
pub const Data = struct {
    /// Bytes received since the last call, borrowed until the next
    /// call that changes drag state.
    bytes: []const u8,

    status: Status,

    pub const Status = union(enum) {
        /// More data may follow.
        pending,

        /// All data has been received.
        complete,

        /// The client failed to provide the data.
        failed: Errno,
    };
};

/// Drag source state for the client offering drags.
///
/// The lifecycle of a drag, as seen by the embedder:
///
///   1. The client enables offering drags (t=o:x=1), yielding an
///      `offers` event.
///   2. While `enabled`, when the user starts the platform's drag
///      gesture over the terminal, the embedder calls `gesture`, which
///      asks the client to offer a drag.
///   3. The client builds an offer (t=o, t=p) and starts the drag
///      (t=P:x=-1), yielding a `drag_start` event. The embedder reads
///      the offer (`mimes`, `preSent`, `image`, `currentImage`,
///      `operations`), copying what it needs, starts the native drag,
///      and calls `startResult`. A successful start frees the pre-sent
///      data and images.
///   4. During the drag the embedder reports its progress with `report`
///      and requests data the drop target wants that wasn't pre-sent
///      with `requestData`. The client's replies yield `drag_data`
///      events and are read with `takeData`. A `drag_image` event asks
///      to change the drag image to `currentImage`.
///   5. The embedder reports the drag finished, which frees the offer,
///      or the client cancels it, yielding `drag_cancel`.
pub const DragSource = struct {
    /// True while the client offers drags (t=o:x=1).
    enabled: bool = false,

    /// Multiplexer client ID from the offer, echoed in every drag-side
    /// message the terminal sends.
    client_id: u32 = 0,

    phase: Phase = .none,

    /// The operations the offer allows, as sent (`o`); zero until set.
    allowed: u32 = 0,

    /// The offered MIME list, space-separated as received.
    mime_list: std.ArrayListUnmanaged(u8) = .empty,

    /// One entry per offered MIME type once the list is complete.
    items: []Item = &.{},

    /// Drag images by number (1 through 14), as sent.
    images: [image_slots]ImageSlot = @splat(.{}),

    /// The current drag image (t=P:x=N): an index into the images
    /// that have data, in number order.
    image_index: u32 = 0,

    /// Base64 bytes received for pre-sent data and images.
    pre_sent_bytes: usize = 0,
    image_bytes: usize = 0,

    const Item = struct {
        /// The MIME type, a slice of `mime_list`.
        mime: []const u8,

        /// Before the drag starts: the pre-sent data. After: data
        /// received from the client not yet taken by the embedder,
        /// starting at `read`.
        data: std.ArrayListUnmanaged(u8) = .empty,
        read: usize = 0,
        decoder: simd.base64.Streaming = .{},

        /// After the drag starts: the request sent to the client and
        /// the state of its reply.
        requested: bool = false,
        complete: bool = false,
        failed: ?Errno = null,

        /// Forget any reply, keeping the buffer's memory.
        fn resetReply(self: *Item) void {
            self.data.clearRetainingCapacity();
            self.read = 0;
            self.decoder = .{};
            self.requested = false;
            self.complete = false;
            self.failed = null;
        }
    };

    const ImageSlot = struct {
        started: bool = false,
        format: ImageFormat = .rgba,
        width: u32 = 0,
        height: u32 = 0,
        opacity: u32 = 0,
        data: std.ArrayListUnmanaged(u8) = .empty,
        decoder: simd.base64.Streaming = .{},
    };

    pub fn deinit(self: *DragSource, alloc: Allocator) void {
        self.freeOffer(alloc);
        self.* = .{};
    }

    /// The operations the offered drag allows.
    pub fn operations(self: *const DragSource) Operations {
        return .{
            .copy = self.allowed & 1 != 0,
            .move = self.allowed & 2 != 0,
        };
    }

    /// The offered MIME types, in the order the client offered them.
    /// Empty until the offer's MIME list is complete.
    pub fn mimeCount(self: *const DragSource) usize {
        return self.items.len;
    }

    pub fn mime(self: *const DragSource, index: usize) ?[]const u8 {
        if (index >= self.items.len) return null;
        return self.items[index].mime;
    }

    /// The data pre-sent for an offered MIME type, or null if none was.
    /// Complete once the `drag_start` event is delivered (the protocol
    /// has no end-of-data message for it) and only available until the
    /// drag starts.
    pub fn preSent(self: *const DragSource, index: usize) ?[]const u8 {
        if (self.phase != .building and self.phase != .starting) return null;
        if (index >= self.items.len) return null;
        const item = &self.items[index];
        if (item.data.items.len == 0 and !item.complete) return null;
        return item.data.items;
    }

    /// The number of drag images. Only available until the drag starts.
    pub fn imageCount(self: *const DragSource) usize {
        var n: usize = 0;
        for (&self.images) |*slot| {
            if (slot.started) n += 1;
        }
        return n;
    }

    /// A drag image, in number order. Complete once the `drag_start`
    /// event is delivered and only available until the drag starts.
    pub fn image(self: *const DragSource, index: usize) ?Image {
        var n: usize = 0;
        for (&self.images) |*slot| {
            if (!slot.started) continue;
            if (n == index) return .{
                .format = slot.format,
                .width = slot.width,
                .height = slot.height,
                .opacity = slot.opacity,
                .data = slot.data.items,
            };
            n += 1;
        }
        return null;
    }

    /// The index of the image to show for the drag, or null for no
    /// image (the index is out of range, which the protocol uses to
    /// remove the image). Image data is only available until the drag
    /// starts; embedders keep their copies to change images later.
    pub fn currentImage(self: *const DragSource) ?u32 {
        const count: usize = switch (self.phase) {
            .building, .starting => self.imageCount(),
            else => return self.image_index,
        };
        return if (self.image_index < count) self.image_index else null;
    }

    /// Free the offer while preserving whether drags are enabled,
    /// mirroring kitty's drag_free_offer.
    pub fn freeOffer(self: *DragSource, alloc: Allocator) void {
        for (self.items) |*item| item.data.deinit(alloc);
        alloc.free(self.items);
        self.items = &.{};
        self.mime_list.clearAndFree(alloc);
        self.freeImages(alloc);
        self.allowed = 0;
        self.phase = .none;
        self.pre_sent_bytes = 0;
        self.image_bytes = 0;
    }

    fn freeImages(self: *DragSource, alloc: Allocator) void {
        for (&self.images) |*slot| {
            slot.data.deinit(alloc);
            slot.* = .{};
        }
    }

    /// Whether a native drag may be in progress.
    fn active(self: *const DragSource) bool {
        return switch (self.phase) {
            .none, .building => false,
            .starting, .started, .dropped => true,
        };
    }

    /// The result of a client command.
    pub const Result = enum {
        /// Nothing for the embedder to do.
        none,

        /// The client enabled or disabled offering drags.
        offers,

        /// The client asked to start the drag.
        start,

        /// The client changed the image of the started drag.
        image,

        /// Data for the started drag arrived or failed.
        data,

        /// A native drag in progress must be canceled.
        cancel,
    };

    /// Enable offering drags (t=o:x=1). The payload, the client's
    /// machine ID for remote drags, is ignored.
    pub fn enable(self: *DragSource) Result {
        if (self.enabled) return .none;
        self.enabled = true;
        return .offers;
    }

    /// Disable offering drags (t=o:x=2), freeing any offer. Returns
    /// whether a native drag in progress must be canceled.
    pub fn disable(self: *DragSource, alloc: Allocator) bool {
        const was_active = self.active();
        self.freeOffer(alloc);
        self.enabled = false;
        return was_active;
    }

    /// Handle one chunk of a drag offer's MIME list (t=o), mirroring
    /// kitty's drag_add_mimes. `continuation` is true for every chunk
    /// but the first of a chunked offer.
    pub fn offer(
        self: *DragSource,
        alloc: Allocator,
        writer: *std.Io.Writer,
        meta: Metadata,
        payload: []const u8,
        continuation: bool,
        terminator: osc.Terminator,
    ) (Allocator.Error || std.Io.Writer.Error)!Result {
        if (!self.enabled) return try self.abort(
            alloc,
            writer,
            .EINVAL,
            "cannot add drag source mimes as not offerring drag",
            terminator,
        );

        // A new offer replaces one still being built.
        if (!continuation and self.phase == .building) self.freeOffer(alloc);

        if (meta.operation != 0 and self.allowed == 0) self.allowed = meta.operation;
        if (self.allowed == 0) return try self.abort(
            alloc,
            writer,
            .EINVAL,
            "cannot add drag source mimes as allowed operations are not set",
            terminator,
        );
        if (self.active()) return try self.abort(
            alloc,
            writer,
            .EINVAL,
            "cannot add drag source mimes as drag source is not being built",
            terminator,
        );

        self.phase = .building;
        self.client_id = meta.client_id;
        if (self.mime_list.items.len + payload.len > dnd_drop.max_mime_list_bytes) return try self.abort(
            alloc,
            writer,
            .EFBIG,
            "drag source mimes size too large",
            terminator,
        );
        try self.mime_list.appendSlice(alloc, payload);
        if (meta.more) return .none;

        // The list is complete: split it into the offered items.
        var count: usize = 0;
        var it = std.mem.tokenizeScalar(u8, self.mime_list.items, ' ');
        while (it.next()) |_| count += 1;
        const items = try alloc.alloc(Item, count);
        it.reset();
        for (items) |*item| item.* = .{ .mime = it.next().? };
        for (self.items) |*item| item.data.deinit(alloc);
        alloc.free(self.items);
        self.items = items;
        self.pre_sent_bytes = 0;
        return .none;
    }

    /// Handle pre-sent data (t=p:x>=0) or a drag image (t=p:x<0).
    pub fn present(
        self: *DragSource,
        alloc: Allocator,
        writer: *std.Io.Writer,
        meta: Metadata,
        payload: []const u8,
        terminator: osc.Terminator,
    ) (Allocator.Error || std.Io.Writer.Error)!Result {
        if (meta.cell_x < 0) return try self.addImage(alloc, writer, meta, payload, terminator);

        // Mirrors kitty's drag_add_pre_sent_data.
        const idx: usize = @intCast(meta.cell_x);
        if (self.phase != .building or idx >= self.items.len) return try self.abort(
            alloc,
            writer,
            .EINVAL,
            if (idx >= self.items.len)
                "pre-sent data item idx too large"
            else
                "drag source not being currently built, cannot add pre-sent data",
            terminator,
        );
        if (payload.len + self.pre_sent_bytes > max_present_bytes) return try self.abort(
            alloc,
            writer,
            .EFBIG,
            "too much pre-sent data",
            terminator,
        );
        self.pre_sent_bytes += payload.len;

        const item = &self.items[idx];
        if (!try decodeInto(alloc, &item.decoder, &item.data, payload)) return try self.abort(
            alloc,
            writer,
            .EINVAL,
            "error while decoding base64 pre-sent data",
            terminator,
        );
        item.complete = true;
        return .none;
    }

    /// Mirrors kitty's drag_add_image.
    fn addImage(
        self: *DragSource,
        alloc: Allocator,
        writer: *std.Io.Writer,
        meta: Metadata,
        payload: []const u8,
        terminator: osc.Terminator,
    ) (Allocator.Error || std.Io.Writer.Error)!Result {
        if (self.phase != .building) return try self.abort(
            alloc,
            writer,
            .EINVAL,
            "cannot add drag thumbnail as drag source not currently being built",
            terminator,
        );
        const number: u32 = @intCast(-@as(i64, meta.cell_x));
        if (number + 1 >= image_slots) return try self.abort(
            alloc,
            writer,
            .EFBIG,
            "too many drag thumbnails",
            terminator,
        );
        if (self.image_bytes + payload.len > max_present_bytes) return try self.abort(
            alloc,
            writer,
            .EFBIG,
            "drag thumbnails too large",
            terminator,
        );
        self.image_bytes += payload.len;

        const slot = &self.images[number];
        if (!slot.started) {
            const format = std.enums.fromInt(
                ImageFormat,
                std.math.cast(u8, meta.cell_y) orelse 255,
            ) orelse return try self.abort(
                alloc,
                writer,
                .EINVAL,
                "unknown drag thumbnail format",
                terminator,
            );
            if (format != .text and (meta.pixel_x < 1 or meta.pixel_y < 1)) return try self.abort(
                alloc,
                writer,
                .EINVAL,
                "invalid drag thumbnail image dimensions",
                terminator,
            );
            slot.* = .{
                .started = true,
                .format = format,
                .width = @intCast(@max(meta.pixel_x, 0)),
                .height = @intCast(@max(meta.pixel_y, 0)),
                .opacity = meta.operation,
            };
        }

        if (!try decodeInto(alloc, &slot.decoder, &slot.data, payload)) return try self.abort(
            alloc,
            writer,
            .EINVAL,
            "could not base64 decode drag thumbnail data",
            terminator,
        );
        return .none;
    }

    /// Change the drag image (t=P:x>=0).
    pub fn changeImage(self: *DragSource, index: u32) Result {
        self.image_index = index;
        return if (self.phase == .started) .image else .none;
    }

    /// Start the offered drag (t=P:x<0), mirroring the validation of
    /// kitty's drag_start. The embedder starts the native drag.
    pub fn start(
        self: *DragSource,
        alloc: Allocator,
        writer: *std.Io.Writer,
        terminator: osc.Terminator,
    ) (Allocator.Error || std.Io.Writer.Error)!Result {
        if (self.phase != .building) return try self.abort(
            alloc,
            writer,
            .EINVAL,
            "cannot start drag as drag source is not being built",
            terminator,
        );

        // Pre-sent data and images have no end-of-data message, so their
        // streams end here, possibly unpadded as kitty's clients send.
        for (self.items) |*item| {
            if (!try finishInto(alloc, &item.decoder, &item.data)) return try self.abort(
                alloc,
                writer,
                .EINVAL,
                "error while decoding base64 pre-sent data",
                terminator,
            );
        }
        for (&self.images) |*slot| {
            if (!try finishInto(alloc, &slot.decoder, &slot.data)) return try self.abort(
                alloc,
                writer,
                .EINVAL,
                "could not base64 decode drag thumbnail data",
                terminator,
            );
        }

        var total: usize = 0;
        for (&self.images) |*slot| {
            if (slot.data.items.len == 0) continue;
            const pixels = @as(usize, slot.width) * slot.height;
            switch (slot.format) {
                .rgb => {
                    if (slot.data.items.len != pixels * 3) return try self.abort(
                        alloc,
                        writer,
                        .EINVAL,
                        "drag thumbnail RGB data not correct size",
                        terminator,
                    );
                    try expandRgb(alloc, slot, pixels);
                },
                .rgba => if (slot.data.items.len != pixels * 4) return try self.abort(
                    alloc,
                    writer,
                    .EINVAL,
                    "drag thumbnail size incorrect",
                    terminator,
                ),

                // Decoded or rendered by the embedder.
                .png, .text => {},
            }

            total += slot.data.items.len;
            if (total > 2 * max_present_bytes) return try self.abort(
                alloc,
                writer,
                .EFBIG,
                "too large a drag thumbnail",
                terminator,
            );
        }

        // Images without data are not images (kitty skips them).
        for (&self.images) |*slot| {
            if (slot.started and slot.data.items.len == 0) {
                slot.data.deinit(alloc);
                slot.* = .{};
            }
        }

        self.phase = .starting;
        return .start;
    }

    fn expandRgb(alloc: Allocator, slot: *ImageSlot, pixels: usize) Allocator.Error!void {
        const rgba = try alloc.alloc(u8, pixels * 4);
        for (0..pixels) |i| {
            @memcpy(rgba[i * 4 ..][0..3], slot.data.items[i * 3 ..][0..3]);
            rgba[i * 4 + 3] = 0xff;
        }
        slot.data.deinit(alloc);
        slot.data = .fromOwnedSlice(rgba);
        slot.format = .rgba;
    }

    /// Report the result of starting the native drag requested by the
    /// `drag_start` event: null when it started, or the error. The
    /// embedder must have copied the pre-sent data and images it needs,
    /// since a successful start frees them, as kitty does.
    pub fn startResult(
        self: *DragSource,
        alloc: Allocator,
        writer: *std.Io.Writer,
        err: ?Errno,
    ) (error{WrongPhase} || std.Io.Writer.Error)!void {
        if (self.phase != .starting) return error.WrongPhase;

        if (err) |e| {
            _ = try self.abort(
                alloc,
                writer,
                e,
                if (e == .EPERM)
                    "permission to start drag denied, this can happen if the user has already released the drag or if the mouse has moved out of the window"
                else
                    "failed to start drag in OS",
                .st,
            );
            return;
        }

        for (self.items) |*item| {
            item.data.clearAndFree(alloc);
            item.resetReply();
        }
        self.freeImages(alloc);
        self.phase = .started;
        try response.encodeError(writer, .drag, .{}, self.client_id, .OK, "", .st);
    }

    /// Ask the client to start a drag at the given position, when the
    /// user performed the platform's drag gesture over the terminal.
    pub fn gesture(
        self: *const DragSource,
        writer: *std.Io.Writer,
        pos: Position,
    ) (error{NotEnabled} || std.Io.Writer.Error)!void {
        if (!self.enabled) return error.NotEnabled;
        var header_buf: [96]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buf,
            "t=o:x={d}:y={d}:X={d}:Y={d}",
            .{ pos.cell_x, pos.cell_y, pos.pixel_x, pos.pixel_y },
        ) catch unreachable;
        try response.encode(writer, header, self.client_id, "", .plain, .st);
    }

    /// Report the progress of the native drag to the client, mirroring
    /// kitty's drag_notify. Ignored unless the drag started.
    pub fn report(
        self: *DragSource,
        alloc: Allocator,
        writer: *std.Io.Writer,
        r: Report,
    ) std.Io.Writer.Error!void {
        switch (self.phase) {
            .started, .dropped => {},
            .none, .building, .starting => return,
        }

        var header_buf: [64]u8 = undefined;
        const header = switch (r) {
            .accepted => |idx| if (idx) |i|
                std.fmt.bufPrint(&header_buf, "t=e:x=1:y={d}", .{i}) catch unreachable
            else
                "t=e:x=1",
            .operation => |op| switch (op) {
                .move => "t=e:x=2:o=2",
                .none, .copy => "t=e:x=2:o=1",
            },
            .dropped => "t=e:x=3",
            .finished => |canceled| if (canceled) "t=e:x=4:y=1" else "t=e:x=4:y=0",
        };
        try response.encode(writer, header, self.client_id, "", .plain, .st);

        switch (r) {
            .dropped => self.phase = .dropped,
            .finished => self.freeOffer(alloc),
            .accepted, .operation => {},
        }
    }

    /// Request the data for an offered MIME type from the client, for a
    /// drop target that wants it, mirroring kitty's drag_get_data. The
    /// request is sent once; the client's reply yields `drag_data`
    /// events and is read with `takeData`. Returns error.NotFound when
    /// the drag isn't in progress or the index is out of range.
    pub fn requestData(
        self: *DragSource,
        writer: *std.Io.Writer,
        index: usize,
    ) (error{NotFound} || std.Io.Writer.Error)!void {
        switch (self.phase) {
            .started, .dropped => {},
            .none, .building, .starting => return error.NotFound,
        }
        if (index >= self.items.len) return error.NotFound;
        const item = &self.items[index];
        if (item.requested) return;
        item.resetReply();
        item.requested = true;

        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buf,
            "t=e:x=5:y={d}",
            .{index},
        ) catch unreachable;
        try response.encode(writer, header, self.client_id, "", .plain, .st);
    }

    /// Take the data received for a requested MIME type. Once complete
    /// or failed and taken, a later `requestData` asks the client again,
    /// matching kitty. Returns error.NotFound when the drag isn't in
    /// progress or the index is out of range.
    pub fn takeData(self: *DragSource, index: usize) error{NotFound}!Data {
        switch (self.phase) {
            .started, .dropped => {},
            .none, .building, .starting => return error.NotFound,
        }
        if (index >= self.items.len) return error.NotFound;
        const item = &self.items[index];

        // Drop what the previous call returned.
        if (item.read == item.data.items.len) {
            item.data.clearRetainingCapacity();
            item.read = 0;
        }

        const bytes = item.data.items[item.read..];
        item.read = item.data.items.len;
        const status: Data.Status = if (item.failed) |e|
            .{ .failed = e }
        else if (item.complete)
            .complete
        else
            .pending;

        // Finished: allow requesting it again. The returned bytes stay
        // valid since the buffer is only cleared on the next call.
        if (status != .pending) {
            item.requested = false;
            item.complete = false;
            item.failed = null;
            item.decoder = .{};
        }
        return .{ .bytes = bytes, .status = status };
    }

    /// Handle drag data (t=e) or a data error (t=E:y>=0) from the
    /// client, mirroring kitty's drag_process_item_data. `err` is the
    /// error payload for t=E, null for t=e.
    pub fn itemData(
        self: *DragSource,
        alloc: Allocator,
        writer: *std.Io.Writer,
        meta: Metadata,
        payload: []const u8,
        is_error: bool,
        terminator: osc.Terminator,
    ) (Allocator.Error || std.Io.Writer.Error)!Result {
        const started = switch (self.phase) {
            .started, .dropped => true,
            .none, .building, .starting => false,
        };
        const in_range = meta.cell_y >= 0 and @as(usize, @intCast(meta.cell_y)) < self.items.len;
        if (!started or !in_range) return try self.abort(
            alloc,
            writer,
            .EINVAL,
            if (!started)
                "cannot process drag source item data as drag has not been started"
            else
                "cannot process drag source item data as item index is out of bounds",
            terminator,
        );
        const item = &self.items[@intCast(meta.cell_y)];

        if (is_error) {
            item.failed = parseErrno(payload);
            return .data;
        }

        // An empty final chunk ends the data, which kitty's clients may
        // leave unpadded.
        if (!meta.more and payload.len == 0) {
            if (!try finishInto(alloc, &item.decoder, &item.data)) return try self.abort(
                alloc,
                writer,
                .EINVAL,
                "failed to base64 decode drag source item data",
                terminator,
            );
            item.complete = true;
            return .data;
        }

        if (item.data.items.len - item.read + payload.len / 4 * 3 > max_buffered_bytes) return try self.abort(
            alloc,
            writer,
            .EFBIG,
            "too much drag source item data",
            terminator,
        );
        if (!try decodeInto(alloc, &item.decoder, &item.data, payload)) return try self.abort(
            alloc,
            writer,
            .EINVAL,
            "failed to base64 decode drag source item data",
            terminator,
        );
        return .data;
    }

    /// Cancel the drag from the client (t=E:y=-1): free the offer.
    /// Returns whether a native drag in progress must be canceled.
    pub fn cancel(self: *DragSource, alloc: Allocator) bool {
        const was_active = self.active();
        self.freeOffer(alloc);
        return was_active;
    }

    /// Abort the offer with an error, mirroring kitty's cancel_drag.
    fn abort(
        self: *DragSource,
        alloc: Allocator,
        writer: *std.Io.Writer,
        errno: Errno,
        desc: []const u8,
        terminator: osc.Terminator,
    ) std.Io.Writer.Error!Result {
        try response.encodeError(writer, .drag, .{}, self.client_id, errno, desc, terminator);
        const was_active = self.active();
        self.freeOffer(alloc);
        return if (was_active) .cancel else .none;
    }

    /// Feed base64 payload into a streaming decoder, appending the
    /// output. Returns false on invalid base64.
    fn decodeInto(
        alloc: Allocator,
        decoder: *simd.base64.Streaming,
        list: *std.ArrayListUnmanaged(u8),
        payload: []const u8,
    ) Allocator.Error!bool {
        try list.ensureUnusedCapacity(alloc, decoder.maxLen(payload));
        const decoded = decoder.feed(
            payload,
            list.unusedCapacitySlice(),
        ) catch return false;
        list.items.len += decoded.len;
        return true;
    }

    /// Finish a streaming decoder whose stream may end unpadded,
    /// appending any remaining output. Returns false on invalid base64.
    fn finishInto(
        alloc: Allocator,
        decoder: *simd.base64.Streaming,
        list: *std.ArrayListUnmanaged(u8),
    ) Allocator.Error!bool {
        try list.ensureUnusedCapacity(alloc, 3);
        const decoded = decoder.finishUnpadded(
            list.unusedCapacitySlice(),
        ) catch return false;
        list.items.len += decoded.len;
        return true;
    }

    /// Parse a client error name, mirroring kitty's parse_errno_name:
    /// unknown names are EIO.
    fn parseErrno(payload: []const u8) Errno {
        const known = [_]Errno{ .ENOENT, .EPERM, .EINVAL, .ENOMEM, .EFBIG, .EIO, .EMFILE };
        for (known) |e| {
            if (std.mem.startsWith(u8, payload, @tagName(e))) return e;
        }
        return .EIO;
    }
};
