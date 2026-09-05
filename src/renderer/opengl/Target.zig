//! Represents a render target.
//!
//! In this case, a texture-backed framebuffer. The color attachment is a
//! `GL_TEXTURE_2D` texture instead of a renderbuffer so that we can create
//! an EGLImage from it and export the rendered frame as a dma-buf for
//! presentation by the apprt.
//!
//! We use two textures:
//!
//!   - `texture`: `GL_SRGB8_ALPHA8`. We render to this. With
//!     `GL_FRAMEBUFFER_SRGB` enabled, the GPU automatically converts linear
//!     shader output to sRGB on write. This is required for the
//!     linear-blending color pipeline to produce correct output.
//!
//!   - `export_texture`: `GL_RGBA8`. This is the texture we actually export
//!     as a dma-buf. Mesa cannot export `GL_SRGB8_ALPHA8` textures to
//!     dma-buf, so we blit the rendered sRGB texture into this plain RGBA8
//!     texture (the blit copies the already-sRGB-encoded pixel values
//!     verbatim) and export that instead.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;
const Dmabuf = @import("../Dmabuf.zig");

const log = std.log.scoped(.opengl);

/// Options for initializing a Target
pub const Options = struct {
    /// Desired width
    width: usize,
    /// Desired height
    height: usize,
};

/// The framebuffer we render to.
framebuffer: gl.Framebuffer,

/// The sRGB color attachment texture we render to.
texture: gl.Texture,

/// A plain RGBA8 texture + framebuffer that we blit `texture` into for
/// dma-buf export. Mesa can't export sRGB textures, so we blit the
/// already-sRGB-encoded pixels into this non-sRGB texture and export it.
export_texture: gl.Texture,
export_framebuffer: gl.Framebuffer,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
    const texture = try gl.Texture.create();
    errdefer texture.destroy();
    {
        const bound_tex = try texture.bind(.@"2d");
        defer bound_tex.unbind();
        try bound_tex.parameter(.min_filter, .nearest);
        try bound_tex.parameter(.mag_filter, .nearest);
        try bound_tex.parameter(.wrap_s, .clamp_to_edge);
        try bound_tex.parameter(.wrap_t, .clamp_to_edge);
        try bound_tex.image2D(
            0,
            .srgba,
            @intCast(opts.width),
            @intCast(opts.height),
            .rgba,
            .unsigned_byte,
            null,
        );
        try bound_tex.parameter(.base_level, 0);
        try bound_tex.parameter(.max_level, 0);
    }

    const fbo = try gl.Framebuffer.create();
    errdefer fbo.destroy();
    {
        const bound_fbo = try fbo.bind(.framebuffer);
        defer bound_fbo.unbind();
        try bound_fbo.texture2D(.color0, .@"2d", texture, 0);
        switch (bound_fbo.checkStatus()) {
            .complete => {},
            else => |status| {
                log.warn("render framebuffer incomplete status={}", .{status});
                return error.FramebufferIncomplete;
            },
        }
    }

    // --- Export texture (plain RGBA8, for dma-buf export) ---
    const export_texture = try gl.Texture.create();
    errdefer export_texture.destroy();
    {
        const bound_tex = try export_texture.bind(.@"2d");
        defer bound_tex.unbind();
        try bound_tex.parameter(.min_filter, .nearest);
        try bound_tex.parameter(.mag_filter, .nearest);
        try bound_tex.parameter(.wrap_s, .clamp_to_edge);
        try bound_tex.parameter(.wrap_t, .clamp_to_edge);
        try bound_tex.image2D(
            0,
            .rgba,
            @intCast(opts.width),
            @intCast(opts.height),
            .rgba,
            .unsigned_byte,
            null,
        );
        try bound_tex.parameter(.base_level, 0);
        try bound_tex.parameter(.max_level, 0);
    }

    const export_fbo = try gl.Framebuffer.create();
    errdefer export_fbo.destroy();
    {
        const bound_fbo = try export_fbo.bind(.framebuffer);
        defer bound_fbo.unbind();
        try bound_fbo.texture2D(.color0, .@"2d", export_texture, 0);
        switch (bound_fbo.checkStatus()) {
            .complete => {},
            else => |status| {
                log.warn("export framebuffer incomplete status={}", .{status});
                return error.FramebufferIncomplete;
            },
        }
    }

    return .{
        .framebuffer = fbo,
        .texture = texture,
        .export_framebuffer = export_fbo,
        .export_texture = export_texture,
        .width = opts.width,
        .height = opts.height,
    };
}

pub fn deinit(self: *Self) void {
    self.framebuffer.destroy();
    self.texture.destroy();
    self.export_framebuffer.destroy();
    self.export_texture.destroy();
}

pub fn exportDmabuf(
    self: *const Self,
    display: *egl.Display,
    context: *egl.Context,
) !Dmabuf {
    // We disable GL_FRAMEBUFFER_SRGB while doing this blit, otherwise
    // the values may be linearized as they're copied, but even though
    // the draw framebuffer has a linear internal format, the values in
    // it should be sRGB, not linear!
    try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
        log.err("Error re-enabling GL_FRAMEBUFFER_SRGB, err={}", .{err});
    };

    const read_bind = try self.framebuffer.bind(.read);
    defer read_bind.unbind();

    const draw_bind = try self.export_framebuffer.bind(.draw);
    defer draw_bind.unbind();

    try gl.blitFramebuffer(
        0,
        0,
        @intCast(self.width),
        @intCast(self.height),
        0,
        0,
        @intCast(self.width),
        @intCast(self.height),
        .{ .color_buffer_bit = true },
        .nearest,
    );

    const image: *egl.Image = try .create(
        display,
        context,
        .{ .texture_2d = self.export_texture.id },
        &.{},
    );
    defer image.destroy(display) catch {};

    const query = try image.exportDmabufQuery(display);

    if (query.num_planes < 1 or query.num_planes > Dmabuf.max_planes) {
        log.err("DMABUF has too many planes={}", .{query.num_planes});
        return error.DmabufTooManyPlanes;
    }

    var planes: Dmabuf.Planes = .{ .count = @intCast(query.num_planes) };
    try image.exportDmabuf(
        display,
        &planes.fds,
        &planes.strides,
        &planes.offsets,
    );

    return .{
        .width = @intCast(self.width),
        .height = @intCast(self.height),
        // bitCast instead of intCast since the numerical value of fourccs
        // is rather meaningless, and we only care about the bit pattern
        .fourcc = @bitCast(query.fourcc),
        .modifier = query.modifier,
        .premultiplied = true,
        .planes = planes,
    };
}

/// Read the current contents of the framebuffer into CPU memory.
///
/// This is used by the CPU readback presentation fallback. The
/// returned data is tightly-packed RGBA8 with premultiplied alpha,
/// i.e. `width * 4` bytes per row, containing sRGB-encoded values:
/// `GL_FRAMEBUFFER_SRGB` has no effect on `ReadPixels`, so the stored
/// values are returned verbatim.
pub fn readPixelsAlloc(self: *const Self, alloc: std.mem.Allocator) ![]u8 {
    const bind = try self.framebuffer.bind(.read);
    defer bind.unbind();

    const pixels = try alloc.alloc(u8, self.width * self.height * 4);
    errdefer alloc.free(pixels);

    try gl.readPixels(
        0,
        0,
        @intCast(self.width),
        @intCast(self.height),
        .rgba,
        .unsigned_byte,
        pixels.ptr,
    );

    return pixels;
}
