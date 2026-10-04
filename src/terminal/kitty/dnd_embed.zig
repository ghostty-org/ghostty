//! Kitty drag and drop protocol (OSC 72): the bridge to protocol
//! independent drag and drop (`terminal.dnd`). Embedders deliver the
//! protocol's events as `dnd.DropEvent`s and report native activity as
//! `dnd.DropInput`s through these, so each embedder doesn't map the
//! protocol on its own.

const std = @import("std");
const Allocator = std.mem.Allocator;

const dnd = @import("../dnd.zig");
const command = @import("dnd_command.zig");
const dnd_drop = @import("dnd_drop.zig");
const dnd_state = @import("dnd_state.zig");

const Event = dnd_state.Event;
const State = dnd_state.State;

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
    };
}

/// Errors applying native input.
pub const InputError = error{
    /// The program isn't accepting drops. The embedder handles the
    /// activity as it would without the protocol.
    Inactive,

    /// The input doesn't match the protocol's state: a data request that
    /// isn't the one being served.
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

fn operation(op: command.Operation) dnd.Operation {
    return switch (op) {
        .none => .none,
        .copy => .copy,
        .move => .move,
    };
}
