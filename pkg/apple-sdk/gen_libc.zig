//! Build tool that renders a `libc.txt` file pointing at Zig's bundled
//! Darwin headers, used when cross-compiling to macOS from a non-Darwin
//! host (which does not bundle headers for other Apple platforms).

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    var args = try init.minimal.args.iterateAllocator(alloc);
    std.debug.assert(args.skip());
    const zig_lib_dir = args.next() orelse return error.NoZigLibDir;

    const include_dir = try std.fs.path.join(alloc, &.{
        zig_lib_dir,
        "libc",
        "include",
        "any-darwin-any",
    });

    // Zig's bundled stand-in for the macOS SDK: text-based libSystem
    // stubs and an SDKSettings.json.
    const darwin_dir = try std.fs.path.join(alloc, &.{
        zig_lib_dir,
        "libc",
        "darwin",
    });

    // Render the file compatible with the `--libc` Zig flag.
    const stdout = try std.Io.File.stdout().writer(init.io, &.{});
    try stdout.interface.print(
        \\include_dir={[include_dir]s}
        \\sys_include_dir={[include_dir]s}
        \\cc_dir=
        \\crt_dir={[darwin_dir]s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\darwin_sdk_dir={[darwin_dir]s}
        \\
    , .{
        .include_dir = include_dir,
        .darwin_dir = darwin_dir,
    });
    try stdout.interface.flush();
}
