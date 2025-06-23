const c = @import("c.zig").c;
const errors = @import("errors.zig");
const glad = @import("glad.zig");
const Primitive = @import("primitives.zig").Primitive;

pub fn clearColor(r: f32, g: f32, b: f32, a: f32) void {
    glad.context.ClearColor.?(r, g, b, a);
}

pub fn clear(mask: c.GLbitfield) void {
    glad.context.Clear.?(mask);
}

pub fn drawArrays(mode: c.GLenum, first: c.GLint, count: c.GLsizei) !void {
    glad.context.DrawArrays.?(mode, first, count);
    try errors.getError();
}

pub fn drawArraysInstanced(
    mode: Primitive,
    first: c.GLint,
    count: c.GLsizei,
    primcount: c.GLsizei,
) !void {
    glad.context.DrawArraysInstanced.?(
        @intCast(@intFromEnum(mode)),
        first,
        count,
        primcount,
    );
    try errors.getError();
}

pub fn drawElements(mode: c.GLenum, count: c.GLsizei, typ: c.GLenum, offset: usize) !void {
    const offsetPtr = if (offset == 0) null else @as(*const anyopaque, @ptrFromInt(offset));
    glad.context.DrawElements.?(mode, count, typ, offsetPtr);
    try errors.getError();
}

pub fn drawElementsInstanced(
    mode: c.GLenum,
    count: c.GLsizei,
    typ: c.GLenum,
    primcount: c.GLsizei,
) !void {
    glad.context.DrawElementsInstanced.?(
        mode,
        count,
        typ,
        null,
        primcount,
    );
    try errors.getError();
}

pub fn enable(cap: c.GLenum) !void {
    glad.context.Enable.?(cap);
    try errors.getError();
}

pub fn disable(cap: c.GLenum) !void {
    glad.context.Disable.?(cap);
    try errors.getError();
}

pub fn frontFace(mode: c.GLenum) !void {
    glad.context.FrontFace.?(mode);
    try errors.getError();
}

pub fn blendFunc(sfactor: c.GLenum, dfactor: c.GLenum) !void {
    glad.context.BlendFunc.?(sfactor, dfactor);
    try errors.getError();
}

pub fn viewport(x: c.GLint, y: c.GLint, width: c.GLsizei, height: c.GLsizei) !void {
    glad.context.Viewport.?(x, y, width, height);
}

pub fn pixelStore(mode: c.GLenum, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .ComptimeInt, .Int => glad.context.PixelStorei.?(mode, value),
        else => unreachable,
    }
    try errors.getError();
}

pub fn finish() void {
    glad.context.Finish.?();
}

pub fn flush() void {
    glad.context.Flush.?();
}
