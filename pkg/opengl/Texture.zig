const Texture = @This();

const std = @import("std");
const c = @import("c");
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
    @"1d" = c.GL_TEXTURE_1D,
    @"2d" = c.GL_TEXTURE_2D,
    @"3d" = c.GL_TEXTURE_3D,
    @"1d_array" = c.GL_TEXTURE_1D_ARRAY,
    @"2d_array" = c.GL_TEXTURE_2D_ARRAY,
    rectangle = c.GL_TEXTURE_RECTANGLE,
    cube_map = c.GL_TEXTURE_CUBE_MAP,
    buffer = c.GL_TEXTURE_BUFFER,
    @"2d_multisample" = c.GL_TEXTURE_2D_MULTISAMPLE,
    @"2d_multisample_array" = c.GL_TEXTURE_2D_MULTISAMPLE_ARRAY,
};

/// Enum for possible texture parameters.
pub const Parameter = enum(c_uint) {
    base_level = c.GL_TEXTURE_BASE_LEVEL,
    compare_func = c.GL_TEXTURE_COMPARE_FUNC,
    compare_mode = c.GL_TEXTURE_COMPARE_MODE,
    lod_bias = c.GL_TEXTURE_LOD_BIAS,
    min_filter = c.GL_TEXTURE_MIN_FILTER,
    mag_filter = c.GL_TEXTURE_MAG_FILTER,
    min_lod = c.GL_TEXTURE_MIN_LOD,
    max_lod = c.GL_TEXTURE_MAX_LOD,
    max_level = c.GL_TEXTURE_MAX_LEVEL,
    swizzle_r = c.GL_TEXTURE_SWIZZLE_R,
    swizzle_g = c.GL_TEXTURE_SWIZZLE_G,
    swizzle_b = c.GL_TEXTURE_SWIZZLE_B,
    swizzle_a = c.GL_TEXTURE_SWIZZLE_A,
    wrap_s = c.GL_TEXTURE_WRAP_S,
    wrap_t = c.GL_TEXTURE_WRAP_T,
    wrap_r = c.GL_TEXTURE_WRAP_R,

    pub fn Type(comptime self: Parameter) type {
        return switch (self) {
            .min_filter => MinFilter,
            .mag_filter => MagFilter,
            .wrap_s, .wrap_t, .wrap_r => Wrap,
            else => c.GLint,
        };
    }
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

/// Minification filter for textures.
pub const MinFilter = enum(c_int) {
    nearest = c.GL_NEAREST,
    linear = c.GL_LINEAR,
    nearest_mipmap_nearest = c.GL_NEAREST_MIPMAP_NEAREST,
    linear_mipmap_nearest = c.GL_LINEAR_MIPMAP_NEAREST,
    nearest_mipmap_linear = c.GL_NEAREST_MIPMAP_LINEAR,
    linear_mipmap_linear = c.GL_LINEAR_MIPMAP_LINEAR,
};

/// Magnification filter for textures.
pub const MagFilter = enum(c_int) {
    nearest = c.GL_NEAREST,
    linear = c.GL_LINEAR,
};

/// Texture coordinate wrapping mode.
pub const Wrap = enum(c_int) {
    clamp_to_edge = c.GL_CLAMP_TO_EDGE,
    clamp_to_border = c.GL_CLAMP_TO_BORDER,
    mirrored_repeat = c.GL_MIRRORED_REPEAT,
    repeat = c.GL_REPEAT,
};

/// Data type for texture images.
pub const DataType = enum(c_uint) {
    unsigned_byte = c.GL_UNSIGNED_BYTE,

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

    pub fn parameter(b: Binding, comptime name: Parameter, value: name.Type()) errors.Error!void {
        switch (name.Type()) {
            c.GLint => glad.context.TexParameteri.?(
                @intFromEnum(b.target),
                @intFromEnum(name),
                value,
            ),
            else => switch (@typeInfo(name.Type())) {
                .@"enum" => glad.context.TexParameteri.?(
                    @intFromEnum(b.target),
                    @intFromEnum(name),
                    @intFromEnum(value),
                ),
                else => @compileError("unknown parameter type"),
            },
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
