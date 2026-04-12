const std = @import("std");
const builtin = @import("builtin");
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const terminal_sys = @import("../sys.zig");
const Result = @import("result.zig").Result;

/// C: GhosttySysImage
pub const Image = extern struct {
    width: u32,
    height: u32,
    data: ?[*]u8,
    data_len: usize,
};

/// C: GhosttySysDecodePngFn
pub const DecodePngFn = *const fn (
    ?*anyopaque,
    *const CAllocator,
    [*]const u8,
    usize,
    *Image,
) callconv(lib.calling_conv) bool;

/// C: GhosttySysLogLevel
pub const LogLevel = enum(c_int) {
    @"error" = 0,
    warning = 1,
    info = 2,
    debug = 3,

    pub fn fromStd(level: std.log.Level) LogLevel {
        return switch (level) {
            .err => .@"error",
            .warn => .warning,
            .info => .info,
            .debug => .debug,
        };
    }
};

/// C: GhosttySysLogFn
pub const LogFn = *const fn (
    ?*anyopaque,
    LogLevel,
    [*]const u8,
    usize,
    [*]const u8,
    usize,
) callconv(lib.calling_conv) void;

/// C: GhosttySysOption
pub const Option = enum(c_int) {
    userdata = 0,
    decode_png = 1,
    log = 2,

    pub fn InType(comptime self: Option) type {
        return switch (self) {
            .userdata => ?*const anyopaque,
            .decode_png => ?DecodePngFn,
            .log => ?LogFn,
        };
    }
};

/// Global state for the sys interface so we can call through to the C
/// callbacks from Zig.
const Global = struct {
    userdata: ?*anyopaque = null,
    decode_png: ?DecodePngFn = null,
    log: ?LogFn = null,
};

/// Global state for the C sys interface.
var global: Global = .{};

/// Zig-compatible wrapper that calls through to the stored C callback.
/// The C callback allocates the pixel data through the provided allocator,
/// so we can take ownership directly.
fn decodePngWrapper(
    alloc: std.mem.Allocator,
    data: []const u8,
) terminal_sys.DecodeError!terminal_sys.Image {
    const func = global.decode_png orelse return error.InvalidData;

    const c_alloc = CAllocator.fromZig(&alloc);
    var out: Image = undefined;
    if (!func(global.userdata, &c_alloc, data.ptr, data.len, &out)) return error.InvalidData;

    const result_data = out.data orelse return error.InvalidData;

    return .{
        .width = out.width,
        .height = out.height,
        .data = result_data[0..out.data_len],
    };
}

pub fn set(
    option: Option,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(Option, @intFromEnum(option)) orelse {
            return .invalid_value;
        };
    }

    return switch (option) {
        inline else => |comptime_option| setTyped(
            comptime_option,
            @ptrCast(@alignCast(value)),
        ),
    };
}

fn setTyped(
    comptime option: Option,
    value: option.InType(),
) Result {
    switch (option) {
        .userdata => global.userdata = @constCast(value),
        .decode_png => {
            global.decode_png = value;
            terminal_sys.decode_png = if (value != null) &decodePngWrapper else null;
        },
        .log => global.log = value,
    }
    return .success;
}

/// Dispatch a log message to the installed C callback, if any.
fn emitLog(level: LogLevel, scope: []const u8, message: []const u8) void {
    const func = global.log orelse return;
    func(
        global.userdata,
        level,
        scope.ptr,
        scope.len,
        message.ptr,
        message.len,
    );
}

/// Emits logs in chunks. Almost all logs will be less than the chunk size
/// but this allows emitting larger logs without heap allocation.
const LogEmitter = struct {
    c_level: LogLevel,
    scope_text: []const u8,
    writer: std.Io.Writer,

    fn init(c_level: LogLevel, scope_text: []const u8, buf: []u8) LogEmitter {
        return .{
            .c_level = c_level,
            .scope_text = scope_text,
            .writer = .{
                .vtable = &.{ .drain = drain },
                .buffer = buf,
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) error{}!usize {
        const self: *LogEmitter = @fieldParentPtr("writer", w);

        emitLog(self.c_level, self.scope_text, w.buffer[0..w.end]);
        w.end = 0;

        var written: usize = data[data.len].len * splat;
        for (data[0 .. data.len - 1]) |s| {
            emitLog(self.c_level, self.scope_text, s);
            written += s.len;
        }
        for (0..splat) |_| {
            emitLog(self.c_level, self.scope_text, data[data.len]);
        }
        return written;
    }
};

/// Custom std.log sink for C ABI builds.
///
/// When a log callback is installed via ghostty_sys_set(), messages are
/// dispatched through it. When no callback is installed, messages are
/// silently discarded. Large messages that exceed the stack buffer are
/// delivered across multiple callback invocations.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (global.log == null) return;

    const scope_text: []const u8 = if (scope == .default) "" else @tagName(scope);
    const c_level = LogLevel.fromStd(level);

    var buf: [2048]u8 = undefined;
    var ctx: LogEmitter = .init(c_level, scope_text, &buf);

    ctx.writer.print(format, args) catch {};
    ctx.writer.flush() catch {};
}

/// Built-in log callback that writes to stderr.
///
/// Formats each message as "[level](scope): message\n". Can be passed
/// directly to ghostty_sys_set(GHOSTTY_SYS_OPT_LOG, &ghostty_sys_log_stderr).
///
/// Uses std.debug.lockStderrWriter for thread-safe, mutex-protected output.
/// On freestanding/wasm targets this is a no-op (no stderr available).
pub fn logStderr(
    _: ?*anyopaque,
    level: LogLevel,
    scope_ptr: [*]const u8,
    scope_len: usize,
    message_ptr: [*]const u8,
    message_len: usize,
) callconv(lib.calling_conv) void {
    if (comptime builtin.target.cpu.arch.isWasm()) return;

    const scope = scope_ptr[0..scope_len];
    const message = message_ptr[0..message_len];

    const level_text = switch (level) {
        .@"error" => "error",
        .warning => "warning",
        .info => "info",
        .debug => "debug",
    };

    var buffer: [64]u8 = undefined;
    var stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    const writer = &stderr.file_writer.interface;

    if (scope.len > 0) {
        writer.print("[{s}]({s}): {s}\n", .{ level_text, scope, message }) catch {};
    } else {
        writer.print("[{s}]: {s}\n", .{ level_text, message }) catch {};
    }
}

test "set decode_png with null clears" {
    // Start from a known state.
    global.decode_png = null;
    terminal_sys.decode_png = null;

    try std.testing.expectEqual(Result.success, set(.decode_png, null));
    try std.testing.expect(terminal_sys.decode_png == null);
}

test "set decode_png installs wrapper" {
    const S = struct {
        fn decode(_: ?*anyopaque, _: *const CAllocator, _: [*]const u8, _: usize, out: *Image) callconv(lib.calling_conv) bool {
            out.* = .{ .width = 1, .height = 1, .data = null, .data_len = 0 };
            return true;
        }
    };

    try std.testing.expectEqual(Result.success, set(
        .decode_png,
        @ptrCast(&S.decode),
    ));
    try std.testing.expect(terminal_sys.decode_png != null);

    // Clear it again.
    try std.testing.expectEqual(Result.success, set(.decode_png, null));
    try std.testing.expect(terminal_sys.decode_png == null);
}

test "set log with null clears" {
    global.log = null;

    try std.testing.expectEqual(Result.success, set(.log, null));
    try std.testing.expect(global.log == null);
}

test "set log installs callback" {
    const S = struct {
        var called: bool = false;
        fn logCb(_: ?*anyopaque, _: LogLevel, _: [*]const u8, _: usize, _: [*]const u8, _: usize) callconv(lib.calling_conv) void {
            called = true;
        }
    };

    try std.testing.expectEqual(Result.success, set(.log, @ptrCast(&S.logCb)));
    try std.testing.expect(global.log != null);

    emitLog(.info, "test", "hello");
    try std.testing.expect(S.called);

    // Clear it again.
    S.called = false;
    try std.testing.expectEqual(Result.success, set(.log, null));
    try std.testing.expect(global.log == null);

    emitLog(.info, "test", "should not arrive");
    try std.testing.expect(!S.called);
}

test "logFn small message single chunk" {
    const S = struct {
        var call_count: usize = 0;
        var total_len: usize = 0;

        fn logCb(_: ?*anyopaque, _: LogLevel, _: [*]const u8, _: usize, msg: [*]const u8, msg_len: usize) callconv(lib.calling_conv) void {
            _ = msg;
            call_count += 1;
            total_len += msg_len;
        }
    };

    S.call_count = 0;
    S.total_len = 0;
    global.log = @ptrCast(&S.logCb);
    defer {
        global.log = null;
    }

    logFn(.info, .default, "hello", .{});

    try std.testing.expectEqual(@as(usize, 1), S.call_count);
    try std.testing.expectEqual(@as(usize, 5), S.total_len);
}

test "logFn message exceeding chunk size is split" {
    const S = struct {
        var call_count: usize = 0;
        var total_len: usize = 0;

        fn logCb(_: ?*anyopaque, _: LogLevel, _: [*]const u8, _: usize, msg: [*]const u8, msg_len: usize) callconv(lib.calling_conv) void {
            _ = msg;
            call_count += 1;
            total_len += msg_len;
            // Each chunk must not exceed the buffer size.
            std.debug.assert(msg_len <= 2048);
        }
    };

    S.call_count = 0;
    S.total_len = 0;
    global.log = @ptrCast(&S.logCb);
    defer {
        global.log = null;
    }

    // Format a message larger than the 2048-byte buffer.
    // 'A' repeated 3000 times via a fill format.
    const fill: [3000]u8 = .{0x41} ** 3000;
    logFn(.info, .default, "{s}", .{@as([]const u8, &fill)});

    try std.testing.expect(S.call_count >= 2);
    try std.testing.expectEqual(@as(usize, 3000), S.total_len);
}

test "logFn message exactly at chunk boundary" {
    const S = struct {
        var call_count: usize = 0;
        var total_len: usize = 0;

        fn logCb(_: ?*anyopaque, _: LogLevel, _: [*]const u8, _: usize, msg: [*]const u8, msg_len: usize) callconv(lib.calling_conv) void {
            _ = msg;
            call_count += 1;
            total_len += msg_len;
            std.debug.assert(msg_len <= 2048);
        }
    };

    S.call_count = 0;
    S.total_len = 0;
    global.log = @ptrCast(&S.logCb);
    defer {
        global.log = null;
    }

    // Exactly 2048 bytes — should emit one full chunk, no remainder.
    const fill: [2048]u8 = .{0x42} ** 2048;
    logFn(.info, .default, "{s}", .{@as([]const u8, &fill)});

    try std.testing.expectEqual(@as(usize, 1), S.call_count);
    try std.testing.expectEqual(@as(usize, 2048), S.total_len);
}

test "logFn message exactly double chunk size" {
    const S = struct {
        var call_count: usize = 0;
        var total_len: usize = 0;

        fn logCb(_: ?*anyopaque, _: LogLevel, _: [*]const u8, _: usize, msg: [*]const u8, msg_len: usize) callconv(lib.calling_conv) void {
            _ = msg;
            call_count += 1;
            total_len += msg_len;
            std.debug.assert(msg_len <= 2048);
        }
    };

    S.call_count = 0;
    S.total_len = 0;
    global.log = @ptrCast(&S.logCb);
    defer {
        global.log = null;
    }

    // Exactly 4096 bytes — should emit exactly two full chunks.
    const fill: [4096]u8 = .{0x43} ** 4096;
    logFn(.info, .default, "{s}", .{@as([]const u8, &fill)});

    try std.testing.expectEqual(@as(usize, 2), S.call_count);
    try std.testing.expectEqual(@as(usize, 4096), S.total_len);
}

test "set userdata" {
    var data: u32 = 42;
    try std.testing.expectEqual(Result.success, set(.userdata, @ptrCast(&data)));
    try std.testing.expect(global.userdata == @as(?*anyopaque, @ptrCast(&data)));

    // Clear it.
    try std.testing.expectEqual(Result.success, set(.userdata, null));
    try std.testing.expect(global.userdata == null);
}
