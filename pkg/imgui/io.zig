const std = @import("std");
const c = @import("c.zig");
const imgui = @import("main.zig");
const Allocator = std.mem.Allocator;

pub const IO = opaque {
    pub fn get() Allocator.Error!*IO {
        return @as(
            ?*IO,
            @ptrCast(c.igGetIO()),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub inline fn cval(self: *IO) *c.ImGuiIO {
        return @ptrCast(@alignCast(self));
    }
};

test {
    const ctx = try imgui.Context.create();
    defer ctx.destroy();
    _ = try IO.get();
}
