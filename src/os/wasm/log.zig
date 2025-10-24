const std = @import("std");
const builtin = @import("builtin");
const wasm = @import("../wasm.zig");

// Use the correct implementation
pub const log = Freestanding.log;

/// Freestanding implementation calls an extern "log" function.
pub const Freestanding = struct {
    // The function std.log will call.
    pub fn log(
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        // The buffer for putting our log message. We try to use a stack-allocated
        // buffer first because we want to avoid allocation. If we are logging
        // an error DUE to an OOM, allocating will of course fail and we'd like
        // to see the error message so we prefer to use this.
        var buf: [2048]u8 = undefined;

        // Build the string
        const level_txt = comptime level.asText();
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        const txt = level_txt ++ prefix ++ format;

        // Format. We attempt to use a stack-allocated string first and if that
        // fails we'll try to allocate.
        var allocated: bool = false;
        const str = nosuspend std.fmt.bufPrint(&buf, txt, args) catch str: {
            allocated = true;
            break :str std.fmt.allocPrint(wasm.alloc, txt, args) catch return;
        };
        defer if (allocated) wasm.alloc.free(str);

        // Send it over to the JS side
        JS.log(str.ptr, str.len);
    }

    // We wrap our externs in this namespace so we can reuse symbols, otherwise
    // "log" would collide.
    const JS = struct {
        extern "env" fn log(ptr: [*]const u8, len: usize) void;
    };
};
