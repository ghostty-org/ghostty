const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const dnd = @import("../kitty/dnd.zig");
const stream_terminal = @import("../stream_terminal.zig");
const terminal_c = @import("terminal.zig");
const Terminal = terminal_c.Terminal;

const log = std.log.scoped(.kitty_dnd_c);
const Result = @import("result.zig").Result;

/// A drag and drop state change, delivered through the kitty_dnd effect.
///
/// C: GhosttyKittyDndEvent
pub const Event = dnd.Event;

/// A drop operation.
///
/// C: GhosttyKittyDndOperation
pub const Operation = enum(c_int) {
    none = 0,
    copy = 1,
    move = 2,
    _,

    fn init(op: dnd.Operation) Operation {
        return switch (op) {
            .none => .none,
            .copy => .copy,
            .move => .move,
        };
    }

    fn zig(self: Operation) ?dnd.Operation {
        return switch (self) {
            .none => .none,
            .copy => .copy,
            .move => .move,
            _ => null,
        };
    }
};

/// A POSIX error name used by the protocol.
///
/// C: GhosttyKittyDndErrno
pub const Errno = enum(c_int) {
    ok = 0,
    eperm = 1,
    enoent = 2,
    eio = 3,
    einval = 4,
    emfile = 5,
    enomem = 6,
    efbig = 7,
    eisdir = 8,
    enospc = 9,
    eunknown = 10,
    _,

    fn init(e: dnd.Errno) Errno {
        return switch (e) {
            .OK => .ok,
            .EPERM => .eperm,
            .ENOENT => .enoent,
            .EIO => .eio,
            .EINVAL => .einval,
            .EMFILE => .emfile,
            .ENOMEM => .enomem,
            .EFBIG => .efbig,
            .EISDIR => .eisdir,
            .ENOSPC => .enospc,
            .EUNKNOWN => .eunknown,
        };
    }

    fn zig(self: Errno) ?dnd.Errno {
        return switch (self) {
            .ok => .OK,
            .eperm => .EPERM,
            .enoent => .ENOENT,
            .eio => .EIO,
            .einval => .EINVAL,
            .emfile => .EMFILE,
            .enomem => .ENOMEM,
            .efbig => .EFBIG,
            .eisdir => .EISDIR,
            .enospc => .ENOSPC,
            .eunknown => .EUNKNOWN,
            _ => null,
        };
    }
};

/// The phase of the drag the client offers.
///
/// C: GhosttyKittyDndPhase
pub const Phase = enum(c_int) {
    none = 0,
    building = 1,
    starting = 2,
    started = 3,
    dropped = 4,

    fn init(p: dnd.Phase) Phase {
        return switch (p) {
            .none => .none,
            .building => .building,
            .starting => .starting,
            .started => .started,
            .dropped => .dropped,
        };
    }
};

/// The format of a drag image.
///
/// C: GhosttyKittyDndImageFormat
pub const ImageFormat = enum(c_int) {
    text = 0,
    rgb = 24,
    rgba = 32,
    png = 100,
};

/// The kind of a drag progress report.
///
/// C: GhosttyKittyDndReport
pub const Report = enum(c_int) {
    accepted = 0,
    operation = 1,
    dropped = 2,
    finished = 3,
    _,
};

/// The status of drag data received from the client.
///
/// C: GhosttyKittyDndDataStatus
pub const DataStatus = enum(c_int) {
    pending = 0,
    complete = 1,
    failed = 2,
};

/// A position on the terminal. Sized struct.
///
/// C: GhosttyKittyDndPosition
pub const Position = extern struct {
    size: usize = @sizeOf(Position),
    cell_x: u32,
    cell_y: u32,
    pixel_x: i32,
    pixel_y: i32,
    /// Bitmask of the operations a native drag allows: 1 copy, 2 move.
    operations: u32,

    fn moveEvent(self: *const Position) dnd.MoveEvent {
        return .{
            .cell_x = self.cell_x,
            .cell_y = self.cell_y,
            .pixel_x = self.pixel_x,
            .pixel_y = self.pixel_y,
            .operations = .{
                .copy = self.operations & 1 != 0,
                .move = self.operations & 2 != 0,
            },
        };
    }
};

/// A data request the embedder must serve. Sized struct.
///
/// C: GhosttyKittyDndDataRequest
pub const DataRequest = extern struct {
    size: usize = @sizeOf(DataRequest),
    id: u32,
    mime_index: u32,
    mime: lib.String,
};

/// A drag image. Sized struct.
///
/// C: GhosttyKittyDndImage
pub const Image = extern struct {
    size: usize = @sizeOf(Image),
    format: ImageFormat,
    width: u32,
    height: u32,
    opacity: u32,
    data: ?[*]const u8,
    data_len: usize,
};

/// Drag data received from the client. Sized struct.
///
/// C: GhosttyKittyDndDragData
pub const DragData = extern struct {
    size: usize = @sizeOf(DragData),
    data: ?[*]const u8,
    data_len: usize,
    status: DataStatus,
    @"error": Errno,
};

/// Values readable with `get`.
///
/// C: GhosttyKittyDndData
pub const Data = enum(c_int) {
    invalid = 0,
    drop_registered = 1,
    drop_registered_mimes = 2,
    drop_accepted = 3,
    drop_accepted_mimes = 4,
    drop_request = 5,
    drag_enabled = 6,
    drag_phase = 7,
    drag_operations = 8,
    drag_mime_count = 9,
    drag_image_count = 10,
    drag_current_image = 11,

    pub fn OutType(comptime self: Data) type {
        return switch (self) {
            .invalid => void,
            .drop_registered, .drag_enabled => bool,
            .drop_registered_mimes, .drop_accepted_mimes => lib.String,
            .drop_accepted => Operation,
            .drop_request => DataRequest,
            .drag_phase => Phase,
            .drag_operations, .drag_current_image => u32,
            .drag_mime_count, .drag_image_count => usize,
        };
    }
};

fn state(terminal_: Terminal) ?*dnd.State {
    const wrapper = terminal_ orelse return null;
    return wrapper.terminal.kitty_dnd;
}

pub fn get(
    terminal_: Terminal,
    data: Data,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(Data, @intFromEnum(data)) orelse {
            log.warn("kitty_dnd_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }

    if (terminal_ == null) return .invalid_value;
    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| getTyped(
            terminal_,
            comptime_data,
            @ptrCast(@alignCast(out orelse return .invalid_value)),
        ),
    };
}

fn getTyped(
    terminal_: Terminal,
    comptime data: Data,
    out: *data.OutType(),
) Result {
    const s = state(terminal_);
    switch (data) {
        .invalid => return .invalid_value,
        .drop_registered => out.* = if (s) |v| v.drop.registered else false,
        .drag_enabled => out.* = if (s) |v| v.drag.enabled else false,
        .drag_phase => out.* = .init(if (s) |v| v.drag.phase else .none),
        .drag_mime_count => out.* = if (s) |v| v.drag.mimeCount() else 0,
        .drag_image_count => out.* = if (s) |v| v.drag.imageCount() else 0,
        .drop_registered_mimes => {
            const v = s orelse return .no_value;
            if (!v.drop.registered) return .no_value;
            out.* = .init(v.drop.registered_mimes.items);
        },
        .drop_accepted => {
            const v = s orelse return .no_value;
            out.* = .init(v.drop.clientAccepted() orelse return .no_value);
        },
        .drop_accepted_mimes => {
            const v = s orelse return .no_value;
            if (v.drop.clientAccepted() == null) return .no_value;
            out.* = .init(v.drop.accepted_mimes.items);
        },
        .drop_request => {
            const v = s orelse return .no_value;
            const req = v.drop.request() orelse return .no_value;
            if (out.size < @sizeOf(DataRequest)) return .invalid_value;
            out.* = .{
                .id = req.id,
                .mime_index = req.mime_index,
                .mime = .init(req.mime),
            };
        },
        .drag_operations => {
            const v = s orelse return .no_value;
            if (v.drag.phase == .none) return .no_value;
            const ops = v.drag.operations();
            out.* = @as(u32, @intFromBool(ops.copy)) | @as(u32, @intFromBool(ops.move)) << 1;
        },
        .drag_current_image => {
            const v = s orelse return .no_value;
            out.* = v.drag.currentImage() orelse return .no_value;
        },
    }
    return .success;
}

/// The pty writer used for embedder calls, which flushes on deinit.
const Pty = struct {
    buf: [4096]u8 = undefined,
    pty: stream_terminal.PtyWriter = undefined,

    fn writer(self: *Pty) *std.Io.Writer {
        return &self.pty.writer;
    }

    fn flush(self: *Pty) void {
        // The pty writer never fails.
        self.pty.writer.flush() catch unreachable;
    }
};

/// Validate a terminal for a call that writes to the pty, returning the
/// state, or the result to return.
fn writable(terminal_: Terminal) union(enum) { ok: *dnd.State, err: Result } {
    const wrapper = terminal_ orelse return .{ .err = .invalid_value };
    if (wrapper.effects.write_pty == null) return .{ .err = .invalid_value };
    return .{ .ok = wrapper.terminal.kitty_dnd orelse return .{ .err = .no_value } };
}

fn initPty(terminal_: Terminal, pty: *Pty) void {
    pty.pty = terminal_.?.stream.handler.ptyWriter(&pty.buf);
}

fn gpa(terminal_: Terminal) std.mem.Allocator {
    return terminal_.?.terminal.gpa();
}

/// Convert a C MIME list to Zig slices.
fn mimeSlices(
    alloc: std.mem.Allocator,
    mimes: ?[*]const lib.String,
    len: usize,
) error{ OutOfMemory, Invalid }![]const []const u8 {
    const c_mimes: []const lib.String = if (mimes) |ptr| ptr[0..len] else if (len == 0) &.{} else return error.Invalid;
    const out = try alloc.alloc([]const u8, c_mimes.len);
    for (out, c_mimes) |*m, c| m.* = c.ptr[0..c.len];
    return out;
}

fn dropMoveOrDrop(
    terminal_: Terminal,
    pos_: ?*const Position,
    mimes: ?[*]const lib.String,
    mimes_len: usize,
    out_discarded: ?*bool,
    is_drop: bool,
) Result {
    const s = switch (writable(terminal_)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const pos = pos_ orelse return .invalid_value;
    if (pos.size < @sizeOf(Position)) return .invalid_value;
    if (!s.drop.registered) return .no_value;

    var sfa = std.heap.stackFallback(256, gpa(terminal_));
    const alloc = sfa.get();
    const slices = mimeSlices(alloc, mimes, mimes_len) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.Invalid => .invalid_value,
    };
    defer alloc.free(slices);

    var pty: Pty = .{};
    initPty(terminal_, &pty);
    defer pty.flush();
    const discarded = (if (is_drop)
        s.drop.dragDrop(gpa(terminal_), pty.writer(), pos.moveEvent(), slices)
    else
        s.drop.dragMove(gpa(terminal_), pty.writer(), pos.moveEvent(), slices)) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.WriteFailed => unreachable,
    };
    if (out_discarded) |ptr| ptr.* = discarded;
    return .success;
}

pub fn drop_move(
    terminal_: Terminal,
    pos: ?*const Position,
    mimes: ?[*]const lib.String,
    mimes_len: usize,
    out_discarded: ?*bool,
) callconv(lib.calling_conv) Result {
    return dropMoveOrDrop(terminal_, pos, mimes, mimes_len, out_discarded, false);
}

pub fn drop(
    terminal_: Terminal,
    pos: ?*const Position,
    mimes: ?[*]const lib.String,
    mimes_len: usize,
    out_discarded: ?*bool,
) callconv(lib.calling_conv) Result {
    return dropMoveOrDrop(terminal_, pos, mimes, mimes_len, out_discarded, true);
}

pub fn drop_leave(terminal_: Terminal) callconv(lib.calling_conv) Result {
    const s = switch (writable(terminal_)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    if (!s.drop.registered) return .no_value;
    var pty: Pty = .{};
    initPty(terminal_, &pty);
    defer pty.flush();
    s.drop.dragLeave(gpa(terminal_), pty.writer()) catch unreachable;
    return .success;
}

pub fn drop_respond_data(
    terminal_: Terminal,
    id: u32,
    data: ?[*]const u8,
    data_len: usize,
) callconv(lib.calling_conv) Result {
    const s = switch (writable(terminal_)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const bytes: []const u8 = if (data) |ptr| ptr[0..data_len] else if (data_len == 0) "" else return .invalid_value;
    var pty: Pty = .{};
    initPty(terminal_, &pty);
    defer pty.flush();
    s.drop.respondData(pty.writer(), id, bytes) catch |err| return switch (err) {
        error.Stale => .rejected,
        error.WriteFailed => unreachable,
    };
    return .success;
}

pub fn drop_respond_end(
    terminal_: Terminal,
    id: u32,
) callconv(lib.calling_conv) Result {
    const s = switch (writable(terminal_)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    var pty: Pty = .{};
    initPty(terminal_, &pty);
    defer pty.flush();
    _ = s.drop.respondEnd(pty.writer(), id) catch |err| return switch (err) {
        error.Stale => .rejected,
        error.WriteFailed => unreachable,
    };
    return .success;
}

pub fn drop_respond_error(
    terminal_: Terminal,
    id: u32,
    errno: Errno,
) callconv(lib.calling_conv) Result {
    const s = switch (writable(terminal_)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const e = errno.zig() orelse return .invalid_value;
    var pty: Pty = .{};
    initPty(terminal_, &pty);
    defer pty.flush();
    _ = s.drop.respondError(pty.writer(), id, e) catch |err| return switch (err) {
        error.Stale => .rejected,
        error.WriteFailed => unreachable,
    };
    return .success;
}

pub fn drag_mime(
    terminal_: Terminal,
    index: usize,
    out: ?*lib.String,
) callconv(lib.calling_conv) Result {
    if (terminal_ == null) return .invalid_value;
    const ptr = out orelse return .invalid_value;
    const s = state(terminal_) orelse return .no_value;
    ptr.* = .init(s.drag.mime(index) orelse return .no_value);
    return .success;
}

pub fn drag_pre_sent(
    terminal_: Terminal,
    index: usize,
    out: ?*lib.String,
) callconv(lib.calling_conv) Result {
    if (terminal_ == null) return .invalid_value;
    const ptr = out orelse return .invalid_value;
    const s = state(terminal_) orelse return .no_value;
    ptr.* = .init(s.drag.preSent(index) orelse return .no_value);
    return .success;
}

pub fn drag_image(
    terminal_: Terminal,
    index: usize,
    out: ?*Image,
) callconv(lib.calling_conv) Result {
    if (terminal_ == null) return .invalid_value;
    const ptr = out orelse return .invalid_value;
    if (ptr.size < @sizeOf(Image)) return .invalid_value;
    const s = state(terminal_) orelse return .no_value;
    const img = s.drag.image(index) orelse return .no_value;
    ptr.* = .{
        .format = switch (img.format) {
            .text => .text,
            .rgb => .rgb,
            .rgba => .rgba,
            .png => .png,
        },
        .width = img.width,
        .height = img.height,
        .opacity = img.opacity,
        .data = if (img.data.len > 0) img.data.ptr else null,
        .data_len = img.data.len,
    };
    return .success;
}

pub fn drag_gesture(
    terminal_: Terminal,
    pos_: ?*const Position,
) callconv(lib.calling_conv) Result {
    const s = switch (writable(terminal_)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const pos = pos_ orelse return .invalid_value;
    if (pos.size < @sizeOf(Position)) return .invalid_value;
    var pty: Pty = .{};
    initPty(terminal_, &pty);
    defer pty.flush();
    s.drag.gesture(pty.writer(), .{
        .cell_x = pos.cell_x,
        .cell_y = pos.cell_y,
        .pixel_x = pos.pixel_x,
        .pixel_y = pos.pixel_y,
    }) catch |err| return switch (err) {
        error.NotEnabled => .no_value,
        error.WriteFailed => unreachable,
    };
    return .success;
}

pub fn drag_start_result(
    terminal_: Terminal,
    errno: Errno,
) callconv(lib.calling_conv) Result {
    const s = switch (writable(terminal_)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const e = errno.zig() orelse return .invalid_value;
    var pty: Pty = .{};
    initPty(terminal_, &pty);
    defer pty.flush();
    s.drag.startResult(gpa(terminal_), pty.writer(), if (e == .OK) null else e) catch |err| return switch (err) {
        error.WrongPhase => .rejected,
        error.WriteFailed => unreachable,
    };
    return .success;
}

pub fn drag_report(
    terminal_: Terminal,
    kind: Report,
    value: i32,
) callconv(lib.calling_conv) Result {
    const s = switch (writable(terminal_)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const report: dnd.Report = switch (kind) {
        .accepted => .{ .accepted = if (value >= 0) @intCast(value) else null },
        .operation => .{
            .operation = @as(Operation, @enumFromInt(value)).zig() orelse return .invalid_value,
        },
        .dropped => .dropped,
        .finished => .{ .finished = value != 0 },
        _ => return .invalid_value,
    };
    var pty: Pty = .{};
    initPty(terminal_, &pty);
    defer pty.flush();
    s.drag.report(gpa(terminal_), pty.writer(), report) catch unreachable;
    return .success;
}

pub fn drag_request_data(
    terminal_: Terminal,
    index: usize,
) callconv(lib.calling_conv) Result {
    const s = switch (writable(terminal_)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    var pty: Pty = .{};
    initPty(terminal_, &pty);
    defer pty.flush();
    s.drag.requestData(pty.writer(), index) catch |err| return switch (err) {
        error.NotFound => .no_value,
        error.WriteFailed => unreachable,
    };
    return .success;
}

pub fn drag_take_data(
    terminal_: Terminal,
    index: usize,
    out: ?*DragData,
) callconv(lib.calling_conv) Result {
    if (terminal_ == null) return .invalid_value;
    const ptr = out orelse return .invalid_value;
    if (ptr.size < @sizeOf(DragData)) return .invalid_value;
    const s = state(terminal_) orelse return .no_value;
    const data = s.drag.takeData(index) catch return .no_value;
    ptr.* = .{
        .data = if (data.bytes.len > 0) data.bytes.ptr else null,
        .data_len = data.bytes.len,
        .status = switch (data.status) {
            .pending => .pending,
            .complete => .complete,
            .failed => .failed,
        },
        .@"error" = switch (data.status) {
            .failed => |e| .init(e),
            .pending, .complete => .ok,
        },
    };
    return .success;
}

/// Test fixture: a terminal with write_pty capturing output and the
/// kitty_dnd effect recording events.
const TestTerminal = struct {
    t: Terminal,

    var pty: std.ArrayListUnmanaged(u8) = .empty;
    var events: std.ArrayListUnmanaged(Event) = .empty;

    fn init() !TestTerminal {
        pty = .empty;
        events = .empty;
        var t: Terminal = null;
        try testing.expectEqual(Result.success, terminal_c.new(
            &lib.alloc.test_allocator,
            &t,
            80,
            24,
        ));
        try testing.expectEqual(Result.success, terminal_c.set(t, .write_pty, @ptrCast(&writePty)));
        try testing.expectEqual(Result.success, terminal_c.set(t, .kitty_dnd, @ptrCast(&onEvent)));
        return .{ .t = t };
    }

    fn deinit(self: *TestTerminal) void {
        terminal_c.free(self.t);
        pty.deinit(testing.allocator);
        events.deinit(testing.allocator);
    }

    fn writePty(_: Terminal, _: ?*anyopaque, data: [*]const u8, len: usize) callconv(lib.calling_conv) void {
        pty.appendSlice(testing.allocator, data[0..len]) catch @panic("OOM");
    }

    fn onEvent(_: Terminal, _: ?*anyopaque, ev: Event) callconv(lib.calling_conv) void {
        events.append(testing.allocator, ev) catch @panic("OOM");
    }

    fn write(self: *TestTerminal, data: []const u8) void {
        terminal_c.vt_write(self.t, data.ptr, data.len);
    }

    fn expectOutput(_: *TestTerminal, expected: []const u8) !void {
        try testing.expectEqualStrings(expected, pty.items);
        pty.clearRetainingCapacity();
    }

    fn expectEvents(_: *TestTerminal, expected: []const Event) !void {
        try testing.expectEqualSlices(Event, expected, events.items);
        events.clearRetainingCapacity();
    }
};

test "kitty_dnd effect enables the protocol" {
    var tt: TestTerminal = try .init();
    defer tt.deinit();

    tt.write("\x1b]72;t=q\x1b\\");
    try tt.expectOutput("\x1b]72;t=q\x1b\\");

    // Clearing the effect disables it.
    try testing.expectEqual(Result.success, terminal_c.set(tt.t, .kitty_dnd, null));
    tt.write("\x1b]72;t=q\x1b\\");
    tt.write("\x1b]72;t=a\x1b\\");
    try tt.expectOutput("");
    try tt.expectEvents(&.{});

    var registered = true;
    try testing.expectEqual(Result.success, get(tt.t, .drop_registered, @ptrCast(&registered)));
    try testing.expect(!registered);
}

test "kitty_dnd drop round trip" {
    var tt: TestTerminal = try .init();
    defer tt.deinit();

    var pos: Position = .{ .cell_x = 1, .cell_y = 2, .pixel_x = 10, .pixel_y = 20, .operations = 1 };
    const mimes = [_]lib.String{.init(@as([]const u8, "text/plain"))};

    // Nothing to forward to before registration.
    try testing.expectEqual(Result.no_value, drop_move(tt.t, &pos, &mimes, mimes.len, null));

    tt.write("\x1b]72;t=a;text/plain\x1b\\");
    try tt.expectEvents(&.{.registration});
    var registered = false;
    try testing.expectEqual(Result.success, get(tt.t, .drop_registered, @ptrCast(&registered)));
    try testing.expect(registered);
    var reg_mimes: lib.String = undefined;
    try testing.expectEqual(Result.success, get(tt.t, .drop_registered_mimes, @ptrCast(&reg_mimes)));
    try testing.expectEqualStrings("text/plain", reg_mimes.ptr[0..reg_mimes.len]);

    try testing.expectEqual(Result.success, drop_move(tt.t, &pos, &mimes, mimes.len, null));
    try tt.expectOutput("\x1b]72;t=m:x=1:y=2:X=10:Y=20:o=1:m=0;text/plain \x1b\\");

    // The client's acceptance.
    var op: Operation = .none;
    try testing.expectEqual(Result.no_value, get(tt.t, .drop_accepted, @ptrCast(&op)));
    tt.write("\x1b]72;t=m:o=1;text/plain\x1b\\");
    try tt.expectEvents(&.{.acceptance});
    try testing.expectEqual(Result.success, get(tt.t, .drop_accepted, @ptrCast(&op)));
    try testing.expectEqual(Operation.copy, op);

    var discarded = true;
    try testing.expectEqual(Result.success, drop(tt.t, &pos, &mimes, mimes.len, &discarded));
    try testing.expect(!discarded);
    try tt.expectOutput("\x1b]72;t=M:x=1:y=2:X=10:Y=20:o=1:m=0;text/plain \x1b\\");

    // A data request, served after the effect returned.
    tt.write("\x1b]72;t=r:x=1\x1b\\");
    try tt.expectEvents(&.{.data_request});
    var req: DataRequest = .{ .id = 0, .mime_index = 0, .mime = undefined };
    try testing.expectEqual(Result.success, get(tt.t, .drop_request, @ptrCast(&req)));
    try testing.expectEqual(@as(u32, 0), req.mime_index);
    try testing.expectEqualStrings("text/plain", req.mime.ptr[0..req.mime.len]);
    try testing.expectEqual(Result.success, drop_respond_data(tt.t, req.id, "hi", 2));
    try testing.expectEqual(Result.success, drop_respond_end(tt.t, req.id));
    try tt.expectOutput("\x1b]72;t=r:x=1:m=0;aGk=\x1b\\\x1b]72;t=r:x=1\x1b\\");
    try testing.expectEqual(Result.no_value, get(tt.t, .drop_request, @ptrCast(&req)));
    try testing.expectEqual(Result.rejected, drop_respond_end(tt.t, req.id));

    // A failed request.
    tt.write("\x1b]72;t=r:x=1\x1b\\");
    try tt.expectEvents(&.{.data_request});
    try testing.expectEqual(Result.success, get(tt.t, .drop_request, @ptrCast(&req)));
    try testing.expectEqual(Result.invalid_value, drop_respond_error(tt.t, req.id, @enumFromInt(99)));
    try testing.expectEqual(Result.success, drop_respond_error(tt.t, req.id, .eio));
    try tt.expectOutput("\x1b]72;t=R:x=1:m=0;EIO:drop data request failed to read data\x1b\\");

    tt.write("\x1b]72;t=r:o=1\x1b\\");
    try tt.expectEvents(&.{.concluded_copy});
}

test "kitty_dnd drag round trip" {
    var tt: TestTerminal = try .init();
    defer tt.deinit();

    var pos: Position = .{ .cell_x = 3, .cell_y = 4, .pixel_x = 30, .pixel_y = 40, .operations = 0 };
    try testing.expectEqual(Result.no_value, drag_gesture(tt.t, &pos));

    tt.write("\x1b]72;t=o:x=1\x1b\\");
    try tt.expectEvents(&.{.offers});
    var enabled = false;
    try testing.expectEqual(Result.success, get(tt.t, .drag_enabled, @ptrCast(&enabled)));
    try testing.expect(enabled);

    try testing.expectEqual(Result.success, drag_gesture(tt.t, &pos));
    try tt.expectOutput("\x1b]72;t=o:x=3:y=4:X=30:Y=40\x1b\\");

    // The client offers a drag with pre-sent data and an image.
    tt.write("\x1b]72;t=o:o=3;text/plain text/html\x1b\\");
    tt.write("\x1b]72;t=p:x=0;aGVsbG8=\x1b\\");
    tt.write("\x1b]72;t=p:x=-1:y=32:X=1:Y=1;/wAA/w==\x1b\\");
    var phase: Phase = .none;
    try testing.expectEqual(Result.success, get(tt.t, .drag_phase, @ptrCast(&phase)));
    try testing.expectEqual(Phase.building, phase);
    var ops: u32 = 0;
    try testing.expectEqual(Result.success, get(tt.t, .drag_operations, @ptrCast(&ops)));
    try testing.expectEqual(@as(u32, 3), ops);
    var count: usize = 0;
    try testing.expectEqual(Result.success, get(tt.t, .drag_mime_count, @ptrCast(&count)));
    try testing.expectEqual(@as(usize, 2), count);

    tt.write("\x1b]72;t=P:x=-1\x1b\\");
    try tt.expectEvents(&.{.drag_start});
    var str: lib.String = undefined;
    try testing.expectEqual(Result.success, drag_mime(tt.t, 1, &str));
    try testing.expectEqualStrings("text/html", str.ptr[0..str.len]);
    try testing.expectEqual(Result.no_value, drag_mime(tt.t, 2, &str));
    try testing.expectEqual(Result.success, drag_pre_sent(tt.t, 0, &str));
    try testing.expectEqualStrings("hello", str.ptr[0..str.len]);
    try testing.expectEqual(Result.no_value, drag_pre_sent(tt.t, 1, &str));
    var img: Image = .{ .format = .text, .width = 0, .height = 0, .opacity = 0, .data = null, .data_len = 0 };
    try testing.expectEqual(Result.success, drag_image(tt.t, 0, &img));
    try testing.expectEqual(ImageFormat.rgba, img.format);
    try testing.expectEqualSlices(u8, "\xff\x00\x00\xff", img.data.?[0..img.data_len]);
    var current: u32 = 9;
    try testing.expectEqual(Result.success, get(tt.t, .drag_current_image, @ptrCast(&current)));
    try testing.expectEqual(@as(u32, 0), current);

    try testing.expectEqual(Result.success, drag_start_result(tt.t, .ok));
    try tt.expectOutput("\x1b]72;t=E:m=0;OK\x1b\\");
    try testing.expectEqual(Result.rejected, drag_start_result(tt.t, .ok));

    // A drop target wants the HTML.
    try testing.expectEqual(Result.success, drag_request_data(tt.t, 1));
    try tt.expectOutput("\x1b]72;t=e:x=5:y=1\x1b\\");
    tt.write("\x1b]72;t=e:y=1:m=1;PGI+\x1b\\");
    tt.write("\x1b]72;t=e:y=1:m=0\x1b\\");
    try tt.expectEvents(&.{ .drag_data, .drag_data });
    var data: DragData = .{ .data = null, .data_len = 0, .status = .pending, .@"error" = .ok };
    try testing.expectEqual(Result.success, drag_take_data(tt.t, 1, &data));
    try testing.expectEqualStrings("<b>", data.data.?[0..data.data_len]);
    try testing.expectEqual(DataStatus.complete, data.status);

    try testing.expectEqual(Result.success, drag_report(tt.t, .accepted, 1));
    try testing.expectEqual(Result.invalid_value, drag_report(tt.t, .operation, 7));
    try testing.expectEqual(Result.success, drag_report(tt.t, .finished, 0));
    try tt.expectOutput("\x1b]72;t=e:x=1:y=1\x1b\\\x1b]72;t=e:x=4:y=0\x1b\\");
    try testing.expectEqual(Result.success, get(tt.t, .drag_phase, @ptrCast(&phase)));
    try testing.expectEqual(Phase.none, phase);
}

test "kitty_dnd calls need write_pty" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(&lib.alloc.test_allocator, &t, 80, 24));
    defer terminal_c.free(t);

    var pos: Position = .{ .cell_x = 0, .cell_y = 0, .pixel_x = 0, .pixel_y = 0, .operations = 1 };
    try testing.expectEqual(Result.invalid_value, drop_move(t, &pos, null, 0, null));
    try testing.expectEqual(Result.invalid_value, drop_leave(null));
    try testing.expectEqual(Result.invalid_value, get(t, .drop_registered, null));
}
