const VertexArray = @This();

const c = @import("c.zig").c;
const glad = @import("glad.zig");
const errors = @import("errors.zig");

id: c.GLuint,

/// Create a single vertex array object.
pub fn create() !VertexArray {
    var vao: c.GLuint = undefined;
    glad.context.GenVertexArrays.?(1, &vao);
    return VertexArray{ .id = vao };
}

/// glBindVertexArray
pub fn bind(v: VertexArray) !Binding {
    glad.context.BindVertexArray.?(v.id);
    try errors.getError();
    return .{};
}

pub fn destroy(v: VertexArray) void {
    glad.context.DeleteVertexArrays.?(1, &v.id);
}

pub const Binding = struct {
    pub fn unbind(self: Binding) void {
        _ = self;
        glad.context.BindVertexArray.?(0);
    }

    pub fn enableAttribArray(_: Binding, idx: c.GLuint) !void {
        glad.context.EnableVertexAttribArray.?(idx);
        try errors.getError();
    }

    pub fn bindingDivisor(_: Binding, idx: c.GLuint, divisor: c.GLuint) !void {
        glad.context.VertexBindingDivisor.?(idx, divisor);
        try errors.getError();
    }

    pub fn attributeBinding(
        _: Binding,
        attrib_idx: c.GLuint,
        binding_idx: c.GLuint,
    ) !void {
        glad.context.VertexAttribBinding.?(attrib_idx, binding_idx);
        try errors.getError();
    }

    pub fn attributeFormat(
        _: Binding,
        idx: c.GLuint,
        size: c.GLint,
        typ: c.GLenum,
        normalized: bool,
        offset: c.GLuint,
    ) !void {
        glad.context.VertexAttribFormat.?(
            idx,
            size,
            typ,
            @intCast(@intFromBool(normalized)),
            offset,
        );
        try errors.getError();
    }

    pub fn attributeIFormat(
        _: Binding,
        idx: c.GLuint,
        size: c.GLint,
        typ: c.GLenum,
        offset: c.GLuint,
    ) !void {
        glad.context.VertexAttribIFormat.?(
            idx,
            size,
            typ,
            offset,
        );
        try errors.getError();
    }

    pub fn attributeLFormat(
        _: Binding,
        idx: c.GLuint,
        size: c.GLint,
        offset: c.GLuint,
    ) !void {
        glad.context.VertexAttribLFormat.?(
            idx,
            size,
            c.GL_DOUBLE,
            offset,
        );
        try errors.getError();
    }

    pub fn bindVertexBuffer(
        _: Binding,
        idx: c.GLuint,
        buffer: c.GLuint,
        offset: c.GLintptr,
        stride: c.GLsizei,
    ) !void {
        glad.context.BindVertexBuffer.?(
            idx,
            buffer,
            offset,
            stride,
        );
        try errors.getError();
    }
};
