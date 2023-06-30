const std = @import("std");
const c = @import("c.zig");
const imgui = @import("main.zig");
const Allocator = std.mem.Allocator;

pub const DrawData = opaque {
    pub fn get() Allocator.Error!*DrawData {
        return @as(
            ?*DrawData,
            @ptrCast(c.igGetDrawData()),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub inline fn cval(self: *DrawData) *c.ImGuiDrawData {
        return @ptrCast(@alignCast(self));
    }
};
