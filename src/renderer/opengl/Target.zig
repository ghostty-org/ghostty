//! Represents a render target.
//!
//! In this case, an OpenGL renderbuffer-backed framebuffer.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");
const gl = @import("opengl");

const log = std.log.scoped(.opengl);

/// Options for initializing a Target
pub const Options = struct {
    /// Desired width
    width: usize,
    /// Desired height
    height: usize,

    /// Internal format for the renderbuffer.
    internal_format: gl.Texture.InternalFormat,
};

/// The underlying `gl.Framebuffer` instance.
framebuffer: gl.Framebuffer,

/// The underlying `gl.Renderbuffer` instance.
renderbuffer: gl.Renderbuffer,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
    const rbo = try gl.Renderbuffer.create();
    const bound_rbo = try rbo.bind();
    defer bound_rbo.unbind();
    try bound_rbo.storage(
        opts.internal_format,
        @intCast(opts.width),
        @intCast(opts.height),
    );

    const fbo = try gl.Framebuffer.create();
    const bound_fbo = try fbo.bind(.framebuffer);
    defer bound_fbo.unbind();
    try bound_fbo.renderbuffer(.color0, rbo);

    return .{
        .framebuffer = fbo,
        .renderbuffer = rbo,
        .width = opts.width,
        .height = opts.height,
    };
}

pub fn deinit(self: *Self) void {
    self.framebuffer.destroy();
    self.renderbuffer.destroy();
}
