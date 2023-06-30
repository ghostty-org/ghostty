const Buffer = @This();

const std = @import("std");
const c = @import("c.zig");
const errors = @import("errors.zig");
const glad = @import("glad.zig");

id: c.GLuint,

/// Enum for possible binding targets.
pub const Target = enum(c_uint) {
    ArrayBuffer = c.GL_ARRAY_BUFFER,
    ElementArrayBuffer = c.GL_ELEMENT_ARRAY_BUFFER,
    _,
};

/// Enum for possible buffer usages.
pub const Usage = enum(c_uint) {
    StreamDraw = c.GL_STREAM_DRAW,
    StreamRead = c.GL_STREAM_READ,
    StreamCopy = c.GL_STREAM_COPY,
    StaticDraw = c.GL_STATIC_DRAW,
    StaticRead = c.GL_STATIC_READ,
    StaticCopy = c.GL_STATIC_COPY,
    DynamicDraw = c.GL_DYNAMIC_DRAW,
    DynamicRead = c.GL_DYNAMIC_READ,
    DynamicCopy = c.GL_DYNAMIC_COPY,
    _,
};

/// Binding is a bound buffer. By using this for functions that operate
/// on bound buffers, you can easily defer unbinding and in safety-enabled
/// modes verify that unbound buffers are never accessed.
pub const Binding = struct {
    target: Target,

    /// Sets the data of this bound buffer. The data can be any array-like
    /// type. The size of the data is automatically determined based on the type.
    pub inline fn setData(
        b: Binding,
        data: anytype,
        usage: Usage,
    ) !void {
        const info = dataInfo(&data);
        glad.context.BufferData.?(@intFromEnum(b.target), info.size, info.ptr, @intFromEnum(usage));
        try errors.getError();
    }

    /// Sets the data of this bound buffer. The data can be any array-like
    /// type. The size of the data is automatically determined based on the type.
    pub inline fn setSubData(
        b: Binding,
        offset: usize,
        data: anytype,
    ) !void {
        const info = dataInfo(data);
        glad.context.BufferSubData.?(@intFromEnum(b.target), @intCast(offset), info.size, info.ptr);
        try errors.getError();
    }

    /// Sets the buffer data with a null buffer that is expected to be
    /// filled in the future using subData. This requires the type just so
    /// we can setup the data size.
    pub inline fn setDataNull(
        b: Binding,
        comptime T: type,
        usage: Usage,
    ) !void {
        glad.context.BufferData.?(@intFromEnum(b.target), @sizeOf(T), null, @intFromEnum(usage));
        try errors.getError();
    }

    /// Same as setDataNull but lets you manually specify the buffer size.
    pub inline fn setDataNullManual(
        b: Binding,
        size: usize,
        usage: Usage,
    ) !void {
        glad.context.BufferData.?(@intFromEnum(b.target), @intCast(size), null, @intFromEnum(usage));
        try errors.getError();
    }

    fn dataInfo(data: anytype) struct {
        size: isize,
        ptr: *const anyopaque,
    } {
        return switch (@typeInfo(@TypeOf(data))) {
            .Pointer => |ptr| switch (ptr.size) {
                .One => .{
                    .size = @sizeOf(ptr.child) * data.len,
                    .ptr = data,
                },
                .Slice => .{
                    .size = @intCast(@sizeOf(ptr.child) * data.len),
                    .ptr = data.ptr,
                },
                else => {
                    std.log.err("invalid buffer data pointer size: {}", .{ptr.size});
                    unreachable;
                },
            },
            else => {
                std.log.err("invalid buffer data type: {s}", .{@tagName(@typeInfo(@TypeOf(data)))});
                unreachable;
            },
        };
    }

    pub inline fn enableAttribArray(_: Binding, idx: c.GLuint) !void {
        glad.context.EnableVertexAttribArray.?(idx);
    }

    /// Shorthand for vertexAttribPointer that is specialized towards the
    /// common use case of specifying an array of homogeneous types that
    /// don't need normalization. This also enables the attribute at idx.
    pub fn attribute(
        b: Binding,
        idx: c.GLuint,
        size: c.GLint,
        comptime T: type,
        offset: usize,
    ) !void {
        const info: struct {
            // Type of the each component in the array.
            typ: c.GLenum,

            // The byte offset between each full set of attributes.
            stride: c.GLsizei,

            // The size of each component used in calculating the offset.
            offset: usize,
        } = switch (@typeInfo(T)) {
            .Array => |ary| .{
                .typ = switch (ary.child) {
                    f32 => c.GL_FLOAT,
                    else => @compileError("unsupported array child type"),
                },
                .offset = @sizeOf(ary.child),
                .stride = @sizeOf(T),
            },
            else => @compileError("unsupported type"),
        };

        try b.attributeAdvanced(
            idx,
            size,
            info.typ,
            false,
            info.stride,
            offset * info.offset,
        );
        try b.enableAttribArray(idx);
    }

    /// VertexAttribDivisor
    pub fn attributeDivisor(_: Binding, idx: c.GLuint, divisor: c.GLuint) !void {
        glad.context.VertexAttribDivisor.?(idx, divisor);
        try errors.getError();
    }

    pub inline fn attributeAdvanced(
        _: Binding,
        idx: c.GLuint,
        size: c.GLint,
        typ: c.GLenum,
        normalized: bool,
        stride: c.GLsizei,
        offset: usize,
    ) !void {
        const normalized_c: c.GLboolean = if (normalized) c.GL_TRUE else c.GL_FALSE;
        const offsetPtr = if (offset > 0)
            @as(*const anyopaque, @ptrFromInt(offset))
        else
            null;

        glad.context.VertexAttribPointer.?(idx, size, typ, normalized_c, stride, offsetPtr);
        try errors.getError();
    }

    pub inline fn attributeIAdvanced(
        _: Binding,
        idx: c.GLuint,
        size: c.GLint,
        typ: c.GLenum,
        stride: c.GLsizei,
        offset: usize,
    ) !void {
        const offsetPtr = if (offset > 0)
            @as(*const anyopaque, @ptrFromInt(offset))
        else
            null;

        glad.context.VertexAttribIPointer.?(idx, size, typ, stride, offsetPtr);
        try errors.getError();
    }

    pub inline fn unbind(b: *Binding) void {
        glad.context.BindBuffer.?(@intFromEnum(b.target), 0);
        b.* = undefined;
    }
};

/// Create a single buffer.
pub inline fn create() !Buffer {
    var vbo: c.GLuint = undefined;
    glad.context.GenBuffers.?(1, &vbo);
    return Buffer{ .id = vbo };
}

/// glBindBuffer
pub inline fn bind(v: Buffer, target: Target) !Binding {
    glad.context.BindBuffer.?(@intFromEnum(target), v.id);
    return Binding{ .target = target };
}

pub inline fn destroy(v: Buffer) void {
    glad.context.DeleteBuffers.?(1, &v.id);
}
