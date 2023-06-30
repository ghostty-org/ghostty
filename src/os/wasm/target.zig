const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");

/// The wasm target platform. This is used to toggle certain features
/// on and off since the standard triple target is often not specific
/// enough (i.e. we can't tell wasm32-freestanding is for browser or not).
pub const Target = enum {
    browser,
};

/// Our specific target platform.
pub const target: ?Target = if (!builtin.target.isWasm()) null else target: {
    const result = @as(Target, @enumFromInt(@intFromEnum(options.wasm_target)));
    // This maybe isn't necessary but I don't know if enums without a specific
    // tag type and value are guaranteed to be the same between build.zig
    // compilation and our own source compilation so I have this just in case.
    std.debug.assert(std.mem.eql(u8, @tagName(result), @tagName(options.wasm_target)));
    break :target result;
};
