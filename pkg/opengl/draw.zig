const std = @import("std");
const c = @import("c");
const errors = @import("errors.zig");
const glad = @import("glad.zig");
const Primitive = @import("primitives.zig").Primitive;
const Texture = @import("Texture.zig");

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
    try errors.getError();
}

pub fn readPixels(
    x: c.GLint,
    y: c.GLint,
    width: c.GLsizei,
    height: c.GLsizei,
    format: Texture.Format,
    typ: Texture.DataType,
    data: ?*anyopaque,
) !void {
    glad.context.ReadPixels.?(
        x,
        y,
        width,
        height,
        @intFromEnum(format),
        @intFromEnum(typ),
        data,
    );
    try errors.getError();
}

pub fn blitFramebuffer(
    src_x0: c.GLint,
    src_y0: c.GLint,
    src_x1: c.GLint,
    src_y1: c.GLint,
    dst_x0: c.GLint,
    dst_y0: c.GLint,
    dst_x1: c.GLint,
    dst_y1: c.GLint,
    mask: BlitMask,
    filter: Texture.MagFilter,
) !void {
    glad.context.BlitFramebuffer.?(
        src_x0,
        src_y0,
        src_x1,
        src_y1,
        dst_x0,
        dst_y0,
        dst_x1,
        dst_y1,
        @bitCast(mask),
        @intCast(@intFromEnum(filter)),
    );
    try errors.getError();
}

pub fn pixelStore(mode: c.GLenum, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .comptime_int, .int => glad.context.PixelStorei.?(mode, value),
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

pub const BlitMask = packed struct(c.GLbitfield) {
    _pad1: u8 = 0,
    depth_buffer_bit: bool = false,
    _pad2: u1 = 0,
    stencil_buffer_bit: bool = false,
    _pad3: u3 = 0,
    color_buffer_bit: bool = false,
    _pad4: std.meta.Int(.unsigned, @bitSizeOf(c.GLbitfield) - 15) = 0,
};
