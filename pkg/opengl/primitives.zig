pub const c = @import("c.zig").c;

pub const Primitive = enum(c_int) {
    point = c.GL_POINTS,
    line = c.GL_LINES,
    line_strip = c.GL_LINE_STRIP,
    triangle = c.GL_TRIANGLES,
    triangle_strip = c.GL_TRIANGLE_STRIP,

    // Commented out primitive types are excluded for parity with Metal.
    //
    // line_loop = c.GL_LINE_LOOP,
    // line_adjacency = c.GL_LINES_ADJACENCY,
    // line_strip_adjacency = c.GL_LINE_STRIP_ADJACENCY,
    // triangle_fan = c.GL_TRIANGLE_FAN,
    // triangle_adjacency = c.GL_TRIANGLES_ADJACENCY,
    // triangle_strip_adjacency = c.GL_TRIANGLE_STRIP_ADJACENCY,
};
