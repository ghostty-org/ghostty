//! Wrapper for handling textures.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");
const gl = @import("opengl");

const OpenGL = @import("../OpenGL.zig");

const log = std.log.scoped(.opengl);

/// Options for initializing a texture.
pub const Options = struct {
    format: gl.Texture.Format,
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

/// Initialize a texture
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
        texbind.parameter(.WrapS, @intFromEnum(opts.wrap_s)) catch return error.OpenGLFailed;
        texbind.parameter(.WrapT, @intFromEnum(opts.wrap_t)) catch return error.OpenGLFailed;
        texbind.parameter(.MinFilter, @intFromEnum(opts.min_filter)) catch return error.OpenGLFailed;
        texbind.parameter(.MagFilter, @intFromEnum(opts.mag_filter)) catch return error.OpenGLFailed;
        texbind.image2D(
            0,
            opts.internal_format,
            @intCast(width),
            @intCast(height),
            opts.format,
            .UnsignedByte,
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
    texbind.subImage2D(
        0,
        @intCast(x),
        @intCast(y),
        @intCast(width),
        @intCast(height),
        self.format,
        .UnsignedByte,
        data.ptr,
    ) catch return error.OpenGLFailed;
}
