const VertexArray = @This();

const c = @import("c.zig");
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
};
