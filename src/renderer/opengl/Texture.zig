//! Wrapper for handling textures.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const CpuImage = @import("../../terminal/image.zig").CpuImage;
const gl = @import("opengl");

const OpenGL = @import("../OpenGL.zig");

const log = std.log.scoped(.opengl);

/// Options for initializing a texture.
pub const Options = struct {
    format: gl.Texture.Format,
    /// Replicate the decoded red channel for grayscale image sampling.
    grayscale: bool = false,
    internal_format: gl.Texture.InternalFormat,
    target: gl.Texture.Target,
    min_filter: gl.Texture.MinFilter,
    mag_filter: gl.Texture.MagFilter,
    wrap_s: gl.Texture.Wrap,
    wrap_t: gl.Texture.Wrap,
};

texture: gl.Texture,

/// The width of this texture.
width: usize,
/// The height of this texture.
height: usize,

/// Format for this texture.
format: gl.Texture.Format,

/// Target for this texture.
target: gl.Texture.Target,

pub const Error = error{
    /// An OpenGL API call failed.
    OpenGLFailed,
};

/// Native upload format preserving the source's sRGB color and linear alpha.
/// Null requires conversion before uploading.
///
/// This is based on the `format` field for incoming data for glTexImage2D
/// Documented at https://registry.khronos.org/OpenGL-Refpages/gl4/html/glTexImage2D.xhtml
pub fn imageTextureFormat(format: CpuImage.Format) ?OpenGL.ImageTextureFormat {
    return switch (format) {
        .gray => .gray,
        .rgb => .rgb,
        .bgr => .bgr,
        .rgba => .rgba,
        .bgra => .bgra,
        // sRGB decoding must not be applied to the alpha component.
        .gray_alpha => null,
    };
}

/// Initialize a texture.
pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    const tex = gl.Texture.create() catch return error.OpenGLFailed;
    errdefer tex.destroy();
    {
        const texbind = tex.bind(opts.target) catch return error.OpenGLFailed;
        defer texbind.unbind();
        texbind.parameter(.wrap_s, opts.wrap_s) catch return error.OpenGLFailed;
        texbind.parameter(.wrap_t, opts.wrap_t) catch return error.OpenGLFailed;
        texbind.parameter(.min_filter, opts.min_filter) catch return error.OpenGLFailed;
        texbind.parameter(.mag_filter, opts.mag_filter) catch return error.OpenGLFailed;
        if (opts.grayscale) {
            texbind.parameter(.swizzle_g, @as(gl.c.GLint, gl.c.GL_RED)) catch return error.OpenGLFailed;
            texbind.parameter(.swizzle_b, @as(gl.c.GLint, gl.c.GL_RED)) catch return error.OpenGLFailed;
        }
        // CPU images are tightly packed, including odd-width RGB and gray.
        const unpack = try UnpackAlignment.init();
        defer unpack.deinit();
        texbind.image2D(
            0,
            opts.internal_format,
            @intCast(width),
            @intCast(height),
            opts.format,
            .unsigned_byte,
            if (data) |d| @ptrCast(d.ptr) else null,
        ) catch return error.OpenGLFailed;
    }

    return .{
        .texture = tex,
        .width = width,
        .height = height,
        .format = opts.format,
        .target = opts.target,
    };
}

pub fn deinit(self: Self) void {
    self.texture.destroy();
}

/// Replace a region of the texture with the provided data.
///
/// Does NOT check the dimensions of the data to ensure correctness.
pub fn replaceRegion(
    self: Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) Error!void {
    const texbind = self.texture.bind(self.target) catch return error.OpenGLFailed;
    defer texbind.unbind();
    const unpack = try UnpackAlignment.init();
    defer unpack.deinit();
    texbind.subImage2D(
        0,
        @intCast(x),
        @intCast(y),
        @intCast(width),
        @intCast(height),
        self.format,
        .unsigned_byte,
        data.ptr,
    ) catch return error.OpenGLFailed;
}

/// Scope pixel-unpack alignment so tightly packed data does not inherit the
/// default four-byte row padding or change another texture user's GL state.
const UnpackAlignment = struct {
    previous: gl.c.GLint,

    fn init() Error!UnpackAlignment {
        var previous: gl.c.GLint = undefined;
        gl.glad.context.GetIntegerv.?(gl.c.GL_UNPACK_ALIGNMENT, &previous);
        gl.errors.getError() catch return error.OpenGLFailed;
        gl.glad.context.PixelStorei.?(gl.c.GL_UNPACK_ALIGNMENT, 1);
        gl.errors.getError() catch return error.OpenGLFailed;
        return .{ .previous = previous };
    }

    fn deinit(self: UnpackAlignment) void {
        gl.glad.context.PixelStorei.?(gl.c.GL_UNPACK_ALIGNMENT, self.previous);
    }
};
