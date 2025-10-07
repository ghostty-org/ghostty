//! Wrapper for handling samplers.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");
const gl = @import("opengl");

const OpenGL = @import("../OpenGL.zig");

const log = std.log.scoped(.opengl);

/// Options for initializing a sampler.
pub const Options = struct {
    min_filter: gl.Texture.MinFilter,
    mag_filter: gl.Texture.MagFilter,
    wrap_s: gl.Texture.Wrap,
    wrap_t: gl.Texture.Wrap,
};

sampler: gl.Sampler,

pub const Error = error{
    /// An OpenGL API call failed.
    OpenGLFailed,
};

/// Initialize a sampler
pub fn init(
    opts: Options,
) Error!Self {
    const sampler = gl.Sampler.create() catch return error.OpenGLFailed;
    errdefer sampler.destroy();
    sampler.parameter(.WrapS, @intFromEnum(opts.wrap_s)) catch return error.OpenGLFailed;
    sampler.parameter(.WrapT, @intFromEnum(opts.wrap_t)) catch return error.OpenGLFailed;
    sampler.parameter(.MinFilter, @intFromEnum(opts.min_filter)) catch return error.OpenGLFailed;
    sampler.parameter(.MagFilter, @intFromEnum(opts.mag_filter)) catch return error.OpenGLFailed;

    return .{
        .sampler = sampler,
    };
}

pub fn deinit(self: Self) void {
    self.sampler.destroy();
}
