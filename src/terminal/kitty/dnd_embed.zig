//! Kitty drag and drop protocol (OSC 72): the bridge to protocol
//! independent drag and drop (`terminal.dnd`). Embedders deliver the
//! protocol's events as `dnd.DropEvent`s and `dnd.DragEvent`s and report
//! native activity as `dnd.DropInput`s and `dnd.DragInput`s through these,
//! so each embedder (libghostty-vt's handler, its C API, the app) doesn't
//! map the protocol on its own.

const std = @import("std");
const Allocator = std.mem.Allocator;

const dnd = @import("../dnd.zig");
const command = @import("dnd_command.zig");
const dnd_drop = @import("dnd_drop.zig");
const dnd_state = @import("dnd_state.zig");

const Event = dnd_state.Event;
const State = dnd_state.State;

/// Whether an event is about drops, as opposed to drags.
pub fn isDrop(ev: Event) bool {
    return switch (ev) {
        .registration,
        .acceptance,
        .data_request,
        .concluded_none,
        .concluded_copy,
        .concluded_move,
        => true,

        .offers,
        .drag_start,
        .drag_image,
        .drag_data,
        .drag_cancel,
        => false,
    };
}

/// The drop event for a protocol event, with its details read from the
/// state now. Null when the details are gone, e.g. a data request
/// already answered. Everything borrowed is valid until the state
/// changes.
pub fn dropEvent(state: ?*const State, ev: Event) ?dnd.DropEvent {
    const drop = if (state) |s| &s.drop else null;
    return switch (ev) {
        .registration => .{ .registration = if (drop) |d| .{
            .accepting = d.registered,
            .mimes = d.registeredMimes(),
        } else .{ .accepting = false } },
        .acceptance => .{ .acceptance = .{
            .operation = operation((drop orelse return null).clientAccepted() orelse return null),
            .mimes = drop.?.acceptedMimes(),
        } },
        .data_request => .{ .data_request = req: {
            const r = (drop orelse return null).request() orelse return null;
            break :req .{ .id = r.id, .mime_index = r.mime_index, .mime = r.mime };
        } },
        .concluded_none => .{ .concluded = .none },
        .concluded_copy => .{ .concluded = .copy },
        .concluded_move => .{ .concluded = .move },
        else => null,
    };
}

/// Deliver the drag events for a protocol event to `emit`, with their
/// details read from the state as each is delivered: `emit` may change
/// the state, and `slot` is re-read in case it did. Data events take the
/// data from the state, so each arrives exactly once. Everything borrowed
/// is only valid during the `emit` call.
pub fn dragEvents(
    slot: *const ?*State,
    alloc: Allocator,
    ev: Event,
    ctx: anytype,
    comptime emit: fn (@TypeOf(ctx), dnd.DragEvent) void,
) Allocator.Error!void {
    const source = if (slot.*) |state| &state.drag else null;
    switch (ev) {
        .offers => emit(ctx, .{ .offers = if (source) |src| src.enabled else false }),
        .drag_image => emit(ctx, .{ .image = (source orelse return).currentImage() }),
        .drag_cancel => emit(ctx, .cancel),

        .drag_start => {
            const src = source orelse return;

            const items = try alloc.alloc(dnd.DragEvent.Offer.Item, src.mimeCount());
            defer alloc.free(items);
            for (items, 0..) |*item, i| item.* = .{
                .mime = src.mime(i).?,
                .pre_sent = src.preSent(i),
            };

            const images = try alloc.alloc(dnd.Image, src.imageCount());
            defer alloc.free(images);
            for (images, 0..) |*image, i| {
                const img = src.image(i).?;
                image.* = .{
                    .format = switch (img.format) {
                        // Expanded to RGBA when the drag starts.
                        .rgb, .rgba => .rgba,
                        .png => .png,
                        .text => .text,
                    },
                    .width = img.width,
                    .height = img.height,
                    .opacity = img.opacity,
                    .data = img.data,
                };
            }

            const ops = src.operations();
            emit(ctx, .{ .start = .{
                .operations = .{ .copy = ops.copy, .move = ops.move },
                .items = items,
                .images = images,
                .image = src.currentImage(),
            } });
        },

        // Delivered for every item with news.
        .drag_data => {
            var i: usize = 0;
            while (true) : (i += 1) {
                const state = slot.* orelse return;
                if (i >= state.drag.mimeCount()) return;
                const data = state.drag.takeData(i) catch return;
                if (data.bytes.len == 0 and data.status == .pending) continue;
                emit(ctx, .{ .data = .{
                    .index = @intCast(i),
                    .bytes = data.bytes,
                    .status = switch (data.status) {
                        .pending => .pending,
                        .complete => .complete,
                        .failed => .failed,
                    },
                } });
            }
        },

        else => {},
    }
}

/// Errors applying native input.
pub const InputError = error{
    /// The program isn't taking part: it isn't accepting drops or
    /// offering drags, no drag is in progress, or an index is out of
    /// range. The embedder handles the activity as it would without the
    /// protocol.
    Inactive,

    /// The input doesn't match the protocol's state: a data request that
    /// isn't the one being served, or a start result nobody asked for.
    Rejected,
} || Allocator.Error || std.Io.Writer.Error;

/// Report native drop activity, writing the messages to the program.
/// Returns the event the embedder must handle next, if any: the next
/// data request once one is answered, or a conclusion with no operation
/// for a drop the program never concluded when a new drag replaced it.
pub fn dropInput(
    state: *State,
    alloc: Allocator,
    writer: *std.Io.Writer,
    input: dnd.DropInput,
) InputError!?dnd.DropEvent {
    const target = &state.drop;
    if (!target.registered) return error.Inactive;

    switch (input) {
        .move, .drop => |motion| {
            const ev: dnd_drop.MoveEvent = .{
                .cell_x = motion.position.cell_x,
                .cell_y = motion.position.cell_y,
                .pixel_x = motion.position.pixel_x,
                .pixel_y = motion.position.pixel_y,
                .operations = .{
                    .copy = motion.operations.copy,
                    .move = motion.operations.move,
                },
            };
            const discarded = if (input == .move)
                try target.dragMove(alloc, writer, ev, motion.mimes)
            else
                try target.dragDrop(alloc, writer, ev, motion.mimes);
            return if (discarded) .{ .concluded = .none } else null;
        },

        .leave => {
            try target.dragLeave(alloc, writer);
            return null;
        },

        .data => |data| {
            target.respondData(writer, data.id, data.bytes) catch |err| return switch (err) {
                error.Stale => error.Rejected,
                error.WriteFailed => error.WriteFailed,
            };
            return null;
        },

        .end, .fail => {
            const next = (if (input == .end)
                target.respondEnd(writer, input.end)
            else
                target.respondError(writer, input.fail.id, switch (input.fail.reason) {
                    .io => .EIO,
                    .not_found => .ENOENT,
                    .denied => .EPERM,
                    .too_large => .EFBIG,
                    .out_of_memory => .ENOMEM,
                })) catch |err| return switch (err) {
                error.Stale => error.Rejected,
                error.WriteFailed => error.WriteFailed,
            };

            // Requests are served one at a time, so the next one is only
            // handed out once this one is answered.
            const r = next orelse return null;
            return .{ .data_request = .{
                .id = r.id,
                .mime_index = r.mime_index,
                .mime = r.mime,
            } };
        },
    }
}

/// Report native drag activity for the drag the program offers, writing
/// the messages to the program. Progress reports are ignored unless the
/// drag started.
pub fn dragInput(
    state: *State,
    alloc: Allocator,
    writer: *std.Io.Writer,
    input: dnd.DragInput,
) InputError!void {
    const source = &state.drag;
    if (!source.enabled) return error.Inactive;

    switch (input) {
        .gesture => |pos| source.gesture(writer, .{
            .cell_x = pos.cell_x,
            .cell_y = pos.cell_y,
            .pixel_x = pos.pixel_x,
            .pixel_y = pos.pixel_y,
        }) catch |err| return switch (err) {
            error.NotEnabled => error.Inactive,
            error.WriteFailed => error.WriteFailed,
        },

        .start_result => |result| source.startResult(alloc, writer, switch (result) {
            .started => null,
            .denied => .EPERM,
            .failed => .EIO,
        }) catch |err| return switch (err) {
            error.WrongPhase => error.Rejected,
            error.WriteFailed => error.WriteFailed,
        },

        .accepted => |index| try source.report(alloc, writer, .{ .accepted = index }),
        .operation => |op| try source.report(alloc, writer, .{ .operation = switch (op) {
            .none => .none,
            .copy => .copy,
            .move => .move,
        } }),
        .dropped => try source.report(alloc, writer, .dropped),
        .finished => |canceled| try source.report(alloc, writer, .{ .finished = canceled }),

        .request_data => |index| source.requestData(writer, index) catch |err| return switch (err) {
            error.NotFound => error.Inactive,
            error.WriteFailed => error.WriteFailed,
        },
    }
}

fn operation(op: command.Operation) dnd.Operation {
    return switch (op) {
        .none => .none,
        .copy => .copy,
        .move => .move,
    };
}
