const Renderbuffer = @This();

const std = @import("std");
const c = @import("c.zig").c;
const errors = @import("errors.zig");
const glad = @import("glad.zig");

const Texture = @import("Texture.zig");

id: c.GLuint,

/// Create a single buffer.
pub fn create() !Renderbuffer {
    var rbo: c.GLuint = undefined;
    glad.context.GenRenderbuffers.?(1, &rbo);
    return .{ .id = rbo };
}

pub fn destroy(v: Renderbuffer) void {
    glad.context.DeleteRenderbuffers.?(1, &v.id);
}

pub fn bind(v: Renderbuffer) !Binding {
    // Keep track of the previous binding so we can restore it in unbind.
    var current: c.GLint = undefined;
    glad.context.GetIntegerv.?(c.GL_RENDERBUFFER_BINDING, &current);
    glad.context.BindRenderbuffer.?(c.GL_RENDERBUFFER, v.id);
    return .{ .previous = @intCast(current) };
}

pub const Binding = struct {
    previous: c.GLuint,

    pub fn unbind(self: Binding) void {
        glad.context.BindRenderbuffer.?(
            c.GL_RENDERBUFFER,
            self.previous,
        );
    }

    pub fn storage(
        self: Binding,
        format: Texture.InternalFormat,
        width: c.GLsizei,
        height: c.GLsizei,
    ) !void {
        _ = self;
        glad.context.RenderbufferStorage.?(
            c.GL_RENDERBUFFER,
            @intCast(@intFromEnum(format)),
            width,
            height,
        );
        try errors.getError();
    }
};
