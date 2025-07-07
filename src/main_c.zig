// This is the main file for the C API. The C API is used to embed Ghostty
// within other applications. Depending on the build settings some APIs
// may not be available (i.e. embedding into macOS exposes various Metal
// support).
//
// This currently isn't supported as a general purpose embedding API.
// This is currently used only to embed ghostty within a macOS app. However,
// it could be expanded to be general purpose in the future.

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const builtin = @import("builtin");
const build_config = @import("build_config.zig");
const main = @import("main_ghostty.zig");
const state = &@import("global.zig").state;
const apprt = @import("apprt.zig");
const internal_os = @import("os/main.zig");

// Some comptime assertions that our C API depends on.
comptime {
    assert(apprt.runtime == apprt.embedded);
}

/// Global options so we can log. This is identical to main.
pub const std_options = main.std_options;

comptime {
    // These structs need to be referenced so the `export` functions
    // are truly exported by the C API lib.
    _ = @import("config.zig").CAPI;
    _ = apprt.runtime.CAPI;
}

/// ghostty_info_s
const Info = extern struct {
    mode: BuildMode,
    version: [*]const u8,
    version_len: usize,

    const BuildMode = enum(c_int) {
        debug,
        release_safe,
        release_fast,
        release_small,
    };
};

/// Initialize ghostty global state.
export fn ghostty_init(argc: usize, argv: [*][*:0]u8) c_int {
    assert(builtin.link_libc);

    std.os.argv = argv[0..argc];
    state.init() catch |err| {
        std.log.err("failed to initialize ghostty error={}", .{err});
        return 1;
    };

    return 0;
}

/// Runs an action if it is specified. If there is no action this returns
/// false. If there is an action then this doesn't return.
export fn ghostty_cli_try_action() void {
    const action = state.action orelse return;
    std.log.info("executing CLI action={}", .{action});
    posix.exit(action.run(state.alloc) catch |err| {
        std.log.err("CLI action failed error={}", .{err});
        posix.exit(1);
    });

    posix.exit(0);
}

/// Return metadata about Ghostty, such as version, build mode, etc.
export fn ghostty_info() Info {
    return .{
        .mode = switch (builtin.mode) {
            .Debug => .debug,
            .ReleaseSafe => .release_safe,
            .ReleaseFast => .release_fast,
            .ReleaseSmall => .release_small,
        },
        .version = build_config.version_string.ptr,
        .version_len = build_config.version_string.len,
    };
}

/// Translate a string maintained by libghostty into the current
/// application language. This will return the same string (same pointer)
/// if no translation is found, so the pointer must be stable through
/// the function call.
///
/// This should only be used for singular strings maintained by Ghostty.
export fn ghostty_translate(msgid: [*:0]const u8) [*:0]const u8 {
    return internal_os.i18n._(msgid);
}
