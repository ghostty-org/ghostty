/// Win32 surface - represents a terminal surface within a window.
/// This is a minimal stub for now.
const Self = @This();

const std = @import("std");
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");

pub fn deinit(self: *Self) void {
    _ = self;
}
