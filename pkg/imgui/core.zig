const std = @import("std");
const c = @import("c.zig");
const imgui = @import("main.zig");
const Allocator = std.mem.Allocator;

pub fn newFrame() void {
    c.igNewFrame();
}

pub fn endFrame() void {
    c.igEndFrame();
}

pub fn render() void {
    c.igRender();
}

pub fn showDemoWindow(open: ?*bool) void {
    c.igShowDemoWindow(@ptrCast([*c]bool, if (open) |v| v else null));
}
