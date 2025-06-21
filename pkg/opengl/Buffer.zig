const Buffer = @This();

const std = @import("std");
const c = @import("c.zig").c;
const errors = @import("errors.zig");
const glad = @import("glad.zig");

id: c.GLuint,

/// Create a single buffer.
pub fn create() !Buffer {
    var vbo: c.GLuint = undefined;
    glad.context.GenBuffers.?(1, &vbo);
    return Buffer{ .id = vbo };
}

/// glBindBuffer
pub fn bind(self: Buffer, target: Target) !Binding {
    glad.context.BindBuffer.?(@intFromEnum(target), self.id);
    return Binding{ .id = self.id, .target = target };
}

pub fn destroy(self: Buffer) void {
    glad.context.DeleteBuffers.?(1, &self.id);
}

pub fn bindBase(self: Buffer, target: Target, idx: c.GLuint) !void {
    glad.context.BindBufferBase.?(
        @intFromEnum(target),
        idx,
        self.id,
    );
    try errors.getError();
}

/// Binding is a bound buffer. By using this for functions that operate
/// on bound buffers, you can easily defer unbinding and in safety-enabled
/// modes verify that unbound buffers are never accessed.
pub const Binding = struct {
    id: c.GLuint,
    target: Target,

    pub fn unbind(b: Binding) void {
        glad.context.BindBuffer.?(@intFromEnum(b.target), 0);
    }

    /// Sets the data of this bound buffer. The data can be any array-like
    /// type. The size of the data is automatically determined based on the type.
    pub fn setData(
        b: Binding,
        data: anytype,
        usage: Usage,
    ) !void {
        const info = dataInfo(data);
        glad.context.BufferData.?(
            @intFromEnum(b.target),
            info.size,
            info.ptr,
            @intFromEnum(usage),
        );
        try errors.getError();
    }

    /// Sets the data of this bound buffer. The data can be any array-like
    /// type. The size of the data is automatically determined based on the type.
    pub fn setSubData(
        b: Binding,
        offset: usize,
        data: anytype,
    ) !void {
        const info = dataInfo(data);
        glad.context.BufferSubData.?(
            @intFromEnum(b.target),
            @intCast(offset),
            info.size,
            info.ptr,
        );
        try errors.getError();
    }

    /// Sets the buffer data with a null buffer that is expected to be
    /// filled in the future using subData. This requires the type just so
    /// we can setup the data size.
    pub fn setDataNull(
        b: Binding,
        comptime T: type,
        usage: Usage,
    ) !void {
        glad.context.BufferData.?(
            @intFromEnum(b.target),
            @sizeOf(T),
            null,
            @intFromEnum(usage),
        );
        try errors.getError();
    }

    /// Same as setDataNull but lets you manually specify the buffer size.
    pub fn setDataNullManual(
        b: Binding,
        size: usize,
        usage: Usage,
    ) !void {
        glad.context.BufferData.?(
            @intFromEnum(b.target),
            @intCast(size),
            null,
            @intFromEnum(usage),
        );
        try errors.getError();
    }

    fn dataInfo(data: anytype) struct {
        size: isize,
        ptr: *const anyopaque,
    } {
        return switch (@typeInfo(@TypeOf(data))) {
            .pointer => |ptr| switch (ptr.size) {
                .one => .{
                    .size = @sizeOf(ptr.child),
                    .ptr = data,
                },
                .slice => .{
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

    pub fn attributeAdvanced(
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

    pub fn attributeIAdvanced(
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
};

/// Enum for possible binding targets.
pub const Target = enum(c_uint) {
    array = c.GL_ARRAY_BUFFER,
    element_array = c.GL_ELEMENT_ARRAY_BUFFER,
    uniform = c.GL_UNIFORM_BUFFER,
    storage = c.GL_SHADER_STORAGE_BUFFER,
    _,
};

/// Enum for possible buffer usages.
pub const Usage = enum(c_uint) {
    stream_draw = c.GL_STREAM_DRAW,
    stream_read = c.GL_STREAM_READ,
    stream_copy = c.GL_STREAM_COPY,
    static_draw = c.GL_STATIC_DRAW,
    static_read = c.GL_STATIC_READ,
    static_copy = c.GL_STATIC_COPY,
    dynamic_draw = c.GL_DYNAMIC_DRAW,
    dynamic_read = c.GL_DYNAMIC_READ,
    dynamic_copy = c.GL_DYNAMIC_COPY,
    _,
};
