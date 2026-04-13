// This is the main file for the C API. The C API is used to embed Ghostty
// within other applications. Depending on the build settings some APIs
// may not be available (i.e. embedding into macOS exposes various Metal
// support).
//
// This currently isn't supported as a general purpose embedding API.
// This is currently used only to embed ghostty within a macOS app. However,
// it could be expanded to be general purpose in the future.

const std = @import("std");
const assert = @import("quirks.zig").inlineAssert;
const posix = std.posix;
const builtin = @import("builtin");
const build_config = @import("build_config.zig");
const main = @import("main_ghostty.zig");
const state = &@import("global.zig").state;
const apprt = @import("apprt.zig");
const internal_os = @import("os/main.zig");

// Some comptime assertions that our C API depends on.
comptime {
    // We allow tests to reference this file because we unit test
    // some of the C API. At runtime though we should never get these
    // functions unless we are building libghostty.
    if (!builtin.is_test) {
        assert(apprt.runtime == apprt.embedded);
    }
}

/// Global options so we can log. This is identical to main.
pub const std_options = main.std_options;

comptime {
    // These structs need to be referenced so the `export` functions
    // are truly exported by the C API lib.

    // Our config API
    _ = @import("config.zig").CApi;

    // Any apprt-specific C API, mainly libghostty for apprt.embedded.
    if (@hasDecl(apprt.runtime, "CAPI")) _ = apprt.runtime.CAPI;

    // Our benchmark API. We probably want to gate this on a build
    // config in the future but for now we always just export it.
    _ = @import("benchmark/main.zig").CApi;
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

/// ghostty_string_s
pub const String = extern struct {
    ptr: ?[*]const u8,
    len: usize,
    sentinel: bool,

    pub const empty: String = .{
        .ptr = null,
        .len = 0,
        .sentinel = false,
    };

    pub fn fromSlice(slice: anytype) String {
        return .{
            .ptr = slice.ptr,
            .len = slice.len,
            .sentinel = sentinel: {
                const info = @typeInfo(@TypeOf(slice));
                switch (info) {
                    .pointer => |p| {
                        if (p.size != .slice) @compileError("only slices supported");
                        if (p.child != u8) @compileError("only u8 slices supported");
                        const sentinel_ = p.sentinel();
                        if (sentinel_) |sentinel| if (sentinel != 0) @compileError("only 0 is supported for sentinels");
                        break :sentinel sentinel_ != null;
                    },
                    else => @compileError("only []const u8 and [:0]const u8"),
                }
            },
        };
    }

    pub fn deinit(self: *const String) void {
        const ptr = self.ptr orelse return;
        if (self.sentinel) {
            state.alloc.free(ptr[0..self.len :0]);
        } else {
            state.alloc.free(ptr[0..self.len]);
        }
    }
};

/// Initialize ghostty global state.
pub export fn ghostty_init(argc: usize, argv: [*][*:0]u8) c_int {
    assert(builtin.link_libc);

    // Construct Zig-friendly globals from C ones.
    const args: std.process.Args = .{ .vector = argv[0..argc] };
    const environ: std.process.Environ = .{
        .block = .{ .slice = std.mem.sliceTo(std.c.environ, null) },
    };

    state.init(.{ .environ = environ, .args = args }) catch |err| {
        std.log.err("failed to initialize ghostty error={}", .{err});
        return 1;
    };

    return 0;
}

/// Runs an action if it is specified. If there is no action this returns
/// false. If there is an action then this doesn't return.
pub export fn ghostty_cli_try_action() void {
    const action = state.action orelse return;
    std.log.info("executing CLI action={}", .{action});
    std.process.exit(action.run(state.alloc, state.io_threaded.io(), state.env) catch |err| {
        std.log.err("CLI action failed error={}", .{err});
        std.process.exit(1);
    });

    std.process.exit(0);
}

/// Return metadata about Ghostty, such as version, build mode, etc.
pub export fn ghostty_info() Info {
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
pub export fn ghostty_translate(msgid: [*:0]const u8) [*:0]const u8 {
    return internal_os.i18n._(msgid);
}

/// Free a string allocated by Ghostty.
pub export fn ghostty_string_free(str: String) void {
    str.deinit();
}

// On Windows, Zig's _DllMainCRTStartup does not initialize the MSVC C
// runtime when targeting MSVC ABI. Without initialization, any C library
// function that depends on CRT internal state (setlocale, malloc from C
// dependencies, C++ constructors in glslang) crashes with null pointer
// dereferences. Declaring DllMain causes Zig's start.zig to call it
// during DLL_PROCESS_ATTACH/DETACH, and for MSVC we forward to the CRT
// bootstrap functions from libvcruntime and libucrt (already linked).
// For other ABIs (MinGW) the handler is a no-op since dllcrt2.obj already
// handles CRT init; we still need `DllMain` declared so that Zig's
// start.zig does not fall back to calling a non-function value.
//
// This is a workaround. Zig handles MinGW DLLs correctly (via dllcrt2.obj)
// but not MSVC. No upstream issue tracks this exact gap as of 2026-03-26.
// Closest: Codeberg ziglang/zig #30936 (reimplement crt0 code).
// Remove this DllMain when Zig handles MSVC DLL CRT init natively.
pub const DllMain = if (builtin.os.tag == .windows) struct {
    const BOOL = std.os.windows.BOOL;
    const HINSTANCE = std.os.windows.HINSTANCE;
    const DWORD = std.os.windows.DWORD;
    const LPVOID = std.os.windows.LPVOID;
    const TRUE = std.os.windows.TRUE;
    const FALSE = std.os.windows.FALSE;

    const DLL_PROCESS_ATTACH: DWORD = 1;
    const DLL_PROCESS_DETACH: DWORD = 0;

    const __vcrt_initialize = @extern(*const fn () callconv(.c) c_int, .{ .name = "__vcrt_initialize" });
    const __vcrt_uninitialize = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "__vcrt_uninitialize" });
    const __acrt_initialize = @extern(*const fn () callconv(.c) c_int, .{ .name = "__acrt_initialize" });
    const __acrt_uninitialize = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "__acrt_uninitialize" });

    pub fn handler(_: HINSTANCE, fdwReason: DWORD, _: LPVOID) callconv(.winapi) BOOL {
        // Only MSVC needs to bootstrap the CRT; MinGW handles it via dllcrt2.obj.
        if (builtin.abi != .msvc) return TRUE;
        switch (fdwReason) {
            DLL_PROCESS_ATTACH => {
                if (__vcrt_initialize() < 0) return FALSE;
                if (__acrt_initialize() < 0) return FALSE;
                return TRUE;
            },
            DLL_PROCESS_DETACH => {
                _ = __acrt_uninitialize(1);
                _ = __vcrt_uninitialize(1);
                return TRUE;
            },
            else => return TRUE,
        }
    }
}.handler else void;

test "ghostty_string_s empty string" {
    const testing = std.testing;
    const empty_string = String.empty;
    defer empty_string.deinit();

    try testing.expect(empty_string.len == 0);
    try testing.expect(empty_string.sentinel == false);
}

test "ghostty_string_s c string" {
    const testing = std.testing;
    state.alloc = testing.allocator;

    const slice: [:0]const u8 = "hello";
    const allocated_slice = try testing.allocator.dupeZ(u8, slice);
    const c_null_string = String.fromSlice(allocated_slice);
    defer c_null_string.deinit();

    try testing.expect(allocated_slice[5] == 0);
    try testing.expect(@TypeOf(slice) == [:0]const u8);
    try testing.expect(@TypeOf(allocated_slice) == [:0]u8);
    try testing.expect(c_null_string.len == 5);
    try testing.expect(c_null_string.sentinel == true);
}

test "ghostty_string_s zig string" {
    const testing = std.testing;
    state.alloc = testing.allocator;

    const slice: []const u8 = "hello";
    const allocated_slice = try testing.allocator.dupe(u8, slice);
    const zig_string = String.fromSlice(allocated_slice);
    defer zig_string.deinit();

    try testing.expect(@TypeOf(slice) == []const u8);
    try testing.expect(@TypeOf(allocated_slice) == []u8);
    try testing.expect(zig_string.len == 5);
    try testing.expect(zig_string.sentinel == false);
}
