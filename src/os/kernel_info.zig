const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");

pub fn getKernelInfo(alloc: std.mem.Allocator) ?[]const u8 {
    if (comptime builtin.os.tag != .linux) return null;
    const path = "/proc/sys/kernel/osrelease";
    var file = std.Io.Dir.openFileAbsolute(global.io(), path, .{}) catch return null;
    defer file.close(global.io());

    // 128 bytes should be enough to hold the kernel information
    var kernel_info_buf: [128]u8 = undefined;
    const kernel_info = kernel_info_buf[0 .. file.readPositionalAll(
        global.io(),
        &kernel_info_buf,
        0,
    ) catch return null];
    return alloc.dupe(u8, std.mem.trim(u8, kernel_info, &std.ascii.whitespace)) catch return null;
}

test "read /proc/sys/kernel/osrelease" {
    if (comptime builtin.os.tag != .linux) return null;
    const allocator = std.testing.allocator;

    const kernel_info = getKernelInfo(allocator).?;
    defer allocator.free(kernel_info);

    // Since we can't hardcode the info in tests, just check
    // if something was read from the file
    try std.testing.expect(kernel_info.len > 0);
    try std.testing.expect(!std.mem.eql(u8, kernel_info, ""));
}
