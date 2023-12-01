const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Open a URL in the default handling application.
pub fn open(alloc: Allocator, url: []const u8) !void {
    const argv = switch (builtin.os.tag) {
        .linux => &.{ "xdg-open", url },
        .macos => &.{ "open", url },
        .windows => &.{ "rundll32", "url.dll,FileProtocolHandler", url },
        else => @compileError("unsupported OS"),
    };

    var exe = std.process.Child.init(argv, alloc);
    try exe.spawn();
}
