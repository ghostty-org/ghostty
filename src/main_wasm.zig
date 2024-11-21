// This is the main file for the WASM module. The WASM module has to
// export a C ABI compatible API.
const std = @import("std");
const builtin = @import("builtin");

comptime {
    _ = @import("os/wasm.zig");
    _ = @import("font/main.zig");
    _ = @import("terminal/main.zig");
    _ = @import("config.zig").Wasm;
    _ = @import("App.zig").Wasm;
}

pub const std_options: std.Options = .{
    // Set our log level. We try to get as much logging as possible but in
    // ReleaseSmall mode where we're optimizing for space, we elevate the
    // log level.
    // .log_level = switch (builtin.mode) {
    //     .Debug => .debug,
    //     .ReleaseSmall => .warn,
    //     else => .info,
    // },
    .log_level = .info,

    // Set our log function
    .logFn = @import("os/wasm/log.zig").log,
};
