const Manual = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

write_cb: WriteCallback,
write_userdata: ?*anyopaque,

pub const WriteCallback = *const fn (
    ?*anyopaque,
    [*]const u8,
    usize,
) callconv(.c) void;

pub const Config = struct {
    write_cb: WriteCallback,
    write_userdata: ?*anyopaque = null,
};

pub fn init(cfg: Config) Manual {
    return .{
        .write_cb = cfg.write_cb,
        .write_userdata = cfg.write_userdata,
    };
}

pub fn deinit(self: *Manual) void {
    _ = self;
}

pub fn initTerminal(self: *Manual, term: *terminal.Terminal) void {
    _ = self;
    _ = term;
}

pub fn threadEnter(
    self: *Manual,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;
    td.backend = .{ .manual = .{} };
}

pub fn threadExit(self: *Manual, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

pub fn focusGained(
    self: *Manual,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *Manual,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = self;
    _ = grid_size;
    _ = screen_size;
}

pub fn queueWrite(
    self: *Manual,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = td;

    if (!linefeed) {
        if (data.len == 0) return;
        self.write_cb(self.write_userdata, data.ptr, data.len);
        return;
    }

    var converted: std.ArrayList(u8) = .empty;
    defer converted.deinit(alloc);

    try converted.ensureTotalCapacity(alloc, data.len * 2);
    for (data) |byte| {
        if (byte == '\r') {
            converted.appendAssumeCapacity('\r');
            converted.appendAssumeCapacity('\n');
        } else {
            converted.appendAssumeCapacity(byte);
        }
    }

    if (converted.items.len == 0) return;
    self.write_cb(self.write_userdata, converted.items.ptr, converted.items.len);
}

pub fn childExitedAbnormally(
    self: *Manual,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};
