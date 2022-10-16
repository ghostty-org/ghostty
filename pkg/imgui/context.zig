const std = @import("std");
const c = @import("c.zig");
const Allocator = std.mem.Allocator;

pub const Context = opaque {
    pub fn create() Allocator.Error!*Context {
        return @ptrCast(
            ?*Context,
            c.igCreateContext(null),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn destroy(self: *Context) void {
        c.igDestroyContext(self.cval());
    }

    pub inline fn cval(self: *Context) *c.ImGuiContext {
        return @ptrCast(
            *c.ImGuiContext,
            @alignCast(@alignOf(c.ImGuiContext), self),
        );
    }
};

test {
    var ctx = try Context.create();
    defer ctx.destroy();
}
