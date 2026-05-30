//! Logging wrapper that mirrors `std.log.scoped`. On Darwin debug
//! builds it additionally delivers each entry to Apple's unified
//! logging via an inline `_os_log_impl` call so DWARF resolves the
//! call site to the original Zig source — that's what makes Xcode's
//! Jump to Source land on the right file:line during development.
//!
//! Release builds skip the inline SPI path and let the standard log
//! pipeline (logFn → `os_log_with_type` C wrapper) deliver os_log
//! entries using only public API. The trade-off is that release
//! builds attribute the log call site to the C wrapper.
//!
//! Non-Darwin targets are a pass-through to `std.log.scoped`.

const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config.zig");
const state = &@import("global.zig").state;

const inline_oslog = builtin.target.os.tag.isDarwin() and builtin.mode == .Debug;

pub fn scoped(comptime scope: @Type(.enum_literal)) type {
    const inner = std.log.scoped(scope);
    return struct {
        pub inline fn err(
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (comptime inline_oslog) emitDarwin(scope, .err, format, args);
            inner.err(format, args);
        }

        pub inline fn warn(
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (comptime inline_oslog) emitDarwin(scope, .warn, format, args);
            inner.warn(format, args);
        }

        pub inline fn info(
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (comptime inline_oslog) emitDarwin(scope, .info, format, args);
            inner.info(format, args);
        }

        pub inline fn debug(
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (comptime inline_oslog) emitDarwin(scope, .debug, format, args);
            inner.debug(format, args);
        }
    };
}

const LogType = enum(u8) {
    default = 0x00,
    info = 0x01,
    debug = 0x02,
    err = 0x10,
    fault = 0x11,
};

const OsLog = opaque {};

extern "c" fn os_log_create(
    subsystem: [*:0]const u8,
    category: [*:0]const u8,
) ?*OsLog;
extern "c" fn os_release(*OsLog) void;

extern "c" fn _os_log_impl(
    dso: *const anyopaque,
    log: *OsLog,
    log_type: u8,
    format: [*]const u8,
    buf: [*]const u8,
    size: u32,
) callconv(.c) void;

const oslog_fmt_public_s: [10:0]u8 linksection("__TEXT,__oslogstring") = "%{public}s".*;

const Dl_info = extern struct {
    dli_fname: ?[*:0]const u8,
    dli_fbase: ?*const anyopaque,
    dli_sname: ?[*:0]const u8,
    dli_saddr: ?*const anyopaque,
};

extern "c" fn dladdr(addr: *const anyopaque, info: *Dl_info) c_int;

/// Mach-O header of the image we're linked into, for `_os_log_impl`.
/// `__dso_handle` is unusable (Zig defines its own placeholder in the
/// data segment) and `_dyld_get_image_header(0)` returns the main
/// executable's header instead of ours when this code lives in a dylib
/// like ghostty.debug.dylib.
inline fn dsoHandle() *const anyopaque {
    var info: Dl_info = undefined;
    _ = dladdr(&oslog_fmt_public_s, &info);
    return info.dli_fbase.?;
}

inline fn emitDarwin(
    comptime scope: @Type(.enum_literal),
    comptime level: std.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    @setEvalBranchQuota(10_000);

    if (!state.logging.macos) return;

    const log = getScopedLog(scope) orelse return;

    var stack_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrintZ(
        &stack_buf,
        format,
        args,
    ) catch return;

    var buf: [12]u8 align(8) = undefined;
    buf[0] = 0x02;
    buf[1] = 0x01;
    buf[2] = 0x22;
    buf[3] = 0x08;
    @as(*align(1) [*:0]const u8, @ptrCast(&buf[4])).* = msg.ptr;

    _os_log_impl(
        dsoHandle(),
        log,
        @intFromEnum(comptime macLevel(level)),
        &oslog_fmt_public_s,
        &buf,
        buf.len,
    );
}

inline fn macLevel(comptime level: std.log.Level) LogType {
    return comptime switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .err,
        .err => .fault,
    };
}

inline fn getScopedLog(comptime scope: @Type(.enum_literal)) ?*OsLog {
    const Slot = struct {
        var cached: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
    };

    const existing = Slot.cached.load(.acquire);
    if (existing != 0) return @ptrFromInt(existing);

    const fresh = os_log_create(
        build_config.bundle_id,
        @tagName(scope),
    ) orelse return null;

    if (Slot.cached.cmpxchgStrong(
        0,
        @intFromPtr(fresh),
        .acq_rel,
        .acquire,
    )) |winner| {
        os_release(fresh);
        return @ptrFromInt(winner);
    }
    return fresh;
}
