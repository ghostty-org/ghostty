const Texture = @This();

const std = @import("std");
const c = @import("c.zig").c;
const errors = @import("errors.zig");
const glad = @import("glad.zig");

id: c.GLuint,

pub fn active(index: c_uint) errors.Error!void {
    glad.context.ActiveTexture.?(index + c.GL_TEXTURE0);
    try errors.getError();
}

/// Create a single texture.
pub fn create() errors.Error!Texture {
    var id: c.GLuint = undefined;
    glad.context.GenTextures.?(1, &id);
    try errors.getError();
    return .{ .id = id };
}

/// glBindTexture
pub fn bind(v: Texture, target: Target) !Binding {
    glad.context.BindTexture.?(@intFromEnum(target), v.id);
    try errors.getError();
    return .{ .target = target };
}

pub fn destroy(v: Texture) void {
    glad.context.DeleteTextures.?(1, &v.id);
}

/// Enum for possible texture binding targets.
pub const Target = enum(c_uint) {
    @"1D" = c.GL_TEXTURE_1D,
    @"2D" = c.GL_TEXTURE_2D,
    @"3D" = c.GL_TEXTURE_3D,
    @"1DArray" = c.GL_TEXTURE_1D_ARRAY,
    @"2DArray" = c.GL_TEXTURE_2D_ARRAY,
    Rectangle = c.GL_TEXTURE_RECTANGLE,
    CubeMap = c.GL_TEXTURE_CUBE_MAP,
    Buffer = c.GL_TEXTURE_BUFFER,
    @"2DMultisample" = c.GL_TEXTURE_2D_MULTISAMPLE,
    @"2DMultisampleArray" = c.GL_TEXTURE_2D_MULTISAMPLE_ARRAY,
};

/// Enum for possible texture parameters.
pub const Parameter = enum(c_uint) {
    BaseLevel = c.GL_TEXTURE_BASE_LEVEL,
    CompareFunc = c.GL_TEXTURE_COMPARE_FUNC,
    CompareMode = c.GL_TEXTURE_COMPARE_MODE,
    LodBias = c.GL_TEXTURE_LOD_BIAS,
    MinFilter = c.GL_TEXTURE_MIN_FILTER,
    MagFilter = c.GL_TEXTURE_MAG_FILTER,
    MinLod = c.GL_TEXTURE_MIN_LOD,
    MaxLod = c.GL_TEXTURE_MAX_LOD,
    MaxLevel = c.GL_TEXTURE_MAX_LEVEL,
    SwizzleR = c.GL_TEXTURE_SWIZZLE_R,
    SwizzleG = c.GL_TEXTURE_SWIZZLE_G,
    SwizzleB = c.GL_TEXTURE_SWIZZLE_B,
    SwizzleA = c.GL_TEXTURE_SWIZZLE_A,
    WrapS = c.GL_TEXTURE_WRAP_S,
    WrapT = c.GL_TEXTURE_WRAP_T,
    WrapR = c.GL_TEXTURE_WRAP_R,
};

/// Internal format enum for texture images.
pub const InternalFormat = enum(c_int) {
    red = c.GL_RED,
    rgb = c.GL_RGB8,
    rgba = c.GL_RGBA8,

    srgb = c.GL_SRGB8,
    srgba = c.GL_SRGB8_ALPHA8,

    rgba_compressed = c.GL_COMPRESSED_RGBA_BPTC_UNORM,
    srgba_compressed = c.GL_COMPRESSED_SRGB_ALPHA_BPTC_UNORM,

    // There are so many more that I haven't filled in.
    _,
};

/// Format for texture images
pub const Format = enum(c_uint) {
    red = c.GL_RED,
    rgb = c.GL_RGB,
    rgba = c.GL_RGBA,
    bgra = c.GL_BGRA,

    // There are so many more that I haven't filled in.
    _,
};

/// Data type for texture images.
pub const DataType = enum(c_uint) {
    UnsignedByte = c.GL_UNSIGNED_BYTE,

    // There are so many more that I haven't filled in.
    _,
};

pub const Binding = struct {
    target: Target,

    pub fn unbind(b: *const Binding) void {
        glad.context.BindTexture.?(@intFromEnum(b.target), 0);
    }

    pub fn generateMipmap(b: Binding) void {
        glad.context.GenerateMipmap.?(@intFromEnum(b.target));
    }

    pub fn parameter(b: Binding, name: Parameter, value: anytype) errors.Error!void {
        switch (@TypeOf(value)) {
            c.GLint => glad.context.TexParameteri.?(
                @intFromEnum(b.target),
                @intFromEnum(name),
                value,
            ),
            else => unreachable,
        }
        try errors.getError();
    }

    pub fn image2D(
        b: Binding,
        level: c.GLint,
        internal_format: InternalFormat,
        width: c.GLsizei,
        height: c.GLsizei,
        format: Format,
        typ: DataType,
        data: ?*const anyopaque,
    ) errors.Error!void {
        glad.context.TexImage2D.?(
            @intFromEnum(b.target),
            level,
            @intFromEnum(internal_format),
            width,
            height,
            0,
            @intFromEnum(format),
            @intFromEnum(typ),
            data,
        );
        try errors.getError();
    }

    pub fn subImage2D(
        b: Binding,
        level: c.GLint,
        xoffset: c.GLint,
        yoffset: c.GLint,
        width: c.GLsizei,
        height: c.GLsizei,
        format: Format,
        typ: DataType,
        data: ?*const anyopaque,
    ) errors.Error!void {
        glad.context.TexSubImage2D.?(
            @intFromEnum(b.target),
            level,
            xoffset,
            yoffset,
            width,
            height,
            @intFromEnum(format),
            @intFromEnum(typ),
            data,
        );
        try errors.getError();
    }

    pub fn copySubImage2D(
        b: Binding,
        level: c.GLint,
        xoffset: c.GLint,
        yoffset: c.GLint,
        x: c.GLint,
        y: c.GLint,
        width: c.GLsizei,
        height: c.GLsizei,
    ) errors.Error!void {
        glad.context.CopyTexSubImage2D.?(
            @intFromEnum(b.target),
            level,
            xoffset,
            yoffset,
            x,
            y,
            width,
            height,
        );
        try errors.getError();
    }
};
