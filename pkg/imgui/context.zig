const std = @import("std");
const c = @import("c.zig");
const Allocator = std.mem.Allocator;

pub const Context = opaque {
    pub fn create() Allocator.Error!*Context {
        return @as(
            ?*Context,
            @ptrCast(c.igCreateContext(null)),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn destroy(self: *Context) void {
        c.igDestroyContext(self.cval());
    }

    pub fn setCurrent(self: *Context) void {
        c.igSetCurrentContext(self.cval());
    }

    pub inline fn cval(self: *Context) *c.ImGuiContext {
        return @ptrCast(@alignCast(self));
    }
};

test {
    var ctx = try Context.create();
    defer ctx.destroy();

    ctx.setCurrent();
}
