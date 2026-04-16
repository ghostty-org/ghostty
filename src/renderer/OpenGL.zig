//! Graphics API wrapper for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const windows = std.os.windows;
const gl = @import("opengl");
const shadertoy = if (build_config.custom_shaders)
    @import("shadertoy.zig")
else
    @import("shadertoy_stub.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(OpenGL);

pub const GraphicsAPI = OpenGL;
pub const Target = @import("opengl/Target.zig");
pub const Frame = @import("opengl/Frame.zig");
pub const RenderPass = @import("opengl/RenderPass.zig");
pub const Pipeline = @import("opengl/Pipeline.zig");
const bufferpkg = @import("opengl/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("opengl/Sampler.zig");
pub const Texture = @import("opengl/Texture.zig");
pub const shaders = @import("opengl/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .glsl;
// The fragCoord for OpenGL shaders is +Y = up.
pub const custom_shader_y_is_down = false;

/// Because OpenGL's frame completion is always
/// sync, we have no need for multi-buffering.
pub const swap_chain_count = 1;

const log = std.log.scoped(.opengl);
const WglSwapIntervalExt = *const fn (interval: c_int) callconv(.winapi) windows.BOOL;
const wgl_swap_interval_ext_name: [*:0]const u8 = "wglSwapIntervalEXT";
const enable_gl_debug_output = false;
const enable_win32_swap_interval = false;

/// We require at least OpenGL 4.3
pub const MIN_VERSION_MAJOR = 4;
pub const MIN_VERSION_MINOR = 3;

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The most recently presented target, in case we need to present it again.
last_target: ?Target = null,

/// Runtime surface used for context ownership and size queries on Win32.
rt_surface: *apprt.Surface,
vsync_enabled: bool,
swap_interval_configured: bool = false,
swap_interval_supported: bool = false,

/// NOTE: This is an error{}!OpenGL instead of just OpenGL for parity with
///       Metal, since it needs to be fallible so does this, even though it
///       can't actually fail.
pub fn init(alloc: Allocator, opts: rendererpkg.Options) error{}!OpenGL {
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .rt_surface = opts.rt_surface,
        .vsync_enabled = opts.config.vsync,
    };
}

pub fn deinit(self: *OpenGL) void {
    self.* = undefined;
}

/// 32-bit windows cross-compilation breaks with `.c` for some reason, so...
const gl_debug_proc_callconv =
    @typeInfo(
        @typeInfo(
            @typeInfo(
                gl.c.GLDEBUGPROC,
            ).optional.child,
        ).pointer.child,
    ).@"fn".calling_convention;

fn glDebugMessageCallback(
    src: gl.c.GLenum,
    typ: gl.c.GLenum,
    id: gl.c.GLuint,
    severity: gl.c.GLenum,
    len: gl.c.GLsizei,
    msg: [*c]const gl.c.GLchar,
    user_param: ?*const anyopaque,
) callconv(gl_debug_proc_callconv) void {
    _ = user_param;

    const src_str: []const u8 = switch (src) {
        gl.c.GL_DEBUG_SOURCE_API => "OpenGL API",
        gl.c.GL_DEBUG_SOURCE_WINDOW_SYSTEM => "Window System",
        gl.c.GL_DEBUG_SOURCE_SHADER_COMPILER => "Shader Compiler",
        gl.c.GL_DEBUG_SOURCE_THIRD_PARTY => "Third Party",
        gl.c.GL_DEBUG_SOURCE_APPLICATION => "User",
        gl.c.GL_DEBUG_SOURCE_OTHER => "Other",
        else => "Unknown",
    };

    const typ_str: []const u8 = switch (typ) {
        gl.c.GL_DEBUG_TYPE_ERROR => "Error",
        gl.c.GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR => "Deprecated Behavior",
        gl.c.GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR => "Undefined Behavior",
        gl.c.GL_DEBUG_TYPE_PORTABILITY => "Portability Issue",
        gl.c.GL_DEBUG_TYPE_PERFORMANCE => "Performance Issue",
        gl.c.GL_DEBUG_TYPE_MARKER => "Marker",
        gl.c.GL_DEBUG_TYPE_PUSH_GROUP => "Group Push",
        gl.c.GL_DEBUG_TYPE_POP_GROUP => "Group Pop",
        gl.c.GL_DEBUG_TYPE_OTHER => "Other",
        else => "Unknown",
    };

    const msg_str = msg[0..@intCast(len)];

    (switch (severity) {
        gl.c.GL_DEBUG_SEVERITY_HIGH => log.err(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_MEDIUM => log.warn(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_LOW => log.info(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_NOTIFICATION => log.debug(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        else => log.warn(
            "UNKNOWN SEVERITY [{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
    });
}

/// Prepares the provided GL context, loading it with glad.
fn prepareContext(getProcAddress: anytype) !void {
    const version = try gl.glad.load(getProcAddress);
    const major = gl.glad.versionMajor(@intCast(version));
    const minor = gl.glad.versionMinor(@intCast(version));
    errdefer gl.glad.unload();
    log.debug("loaded OpenGL {}.{}", .{ major, minor });

    // Need to check version before trying to enable it
    if (major < MIN_VERSION_MAJOR or
        (major == MIN_VERSION_MAJOR and minor < MIN_VERSION_MINOR))
    {
        log.warn(
            "OpenGL version is too old. Ghostty requires OpenGL {d}.{d}",
            .{ MIN_VERSION_MAJOR, MIN_VERSION_MINOR },
        );
        return error.OpenGLOutdated;
    }

    if (enable_gl_debug_output) {
        // Enable debug output for the context.
        try gl.enable(gl.c.GL_DEBUG_OUTPUT);

        // Register our debug message callback with the OpenGL context.
        gl.glad.context.DebugMessageCallback.?(glDebugMessageCallback, null);
    }

    // Enable SRGB framebuffer for linear blending support.
    try gl.enable(gl.c.GL_FRAMEBUFFER_SRGB);
}

/// This is called early right after surface creation.
pub fn surfaceInit(surface: *apprt.Surface) !void {
    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.win32 => {
            log.debug("OpenGL.surfaceInit win32 begin", .{});
            try surface.makeGLContextCurrent();
            log.debug("OpenGL.surfaceInit win32 current", .{});
            try prepareContext(&apprt.win32.getProcAddress);
            log.debug("OpenGL.surfaceInit win32 prepared", .{});
        },

        apprt.embedded => {
            // TODO(mitchellh): this does nothing today to allow libghostty
            // to compile for OpenGL targets but libghostty is strictly
            // broken for rendering on this platforms.
        },
    }

    // These are very noisy so this is commented, but easy to uncomment
    // whenever we need to check the OpenGL extension list
    // if (builtin.mode == .Debug) {
    //     var ext_iter = try gl.ext.iterator();
    //     while (try ext_iter.next()) |ext| {
    //         log.debug("OpenGL extension available name={s}", .{ext});
    //     }
    // }
}

/// This is called just prior to spinning up the renderer
/// thread for final main thread setup requirements.
pub fn finalizeSurfaceInit(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = self;

    switch (apprt.runtime) {
        else => {},

        apprt.win32 => surface.clearGLContextCurrent(),
    }
}

/// Callback called by renderer.Thread when it begins.
pub fn threadEnter(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = self;

    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.win32 => {
            _ = surface;
        },

        apprt.embedded => {
            // TODO(mitchellh): this does nothing today to allow libghostty
            // to compile for OpenGL targets but libghostty is strictly
            // broken for rendering on this platforms.
        },
    }
}

/// Callback called by renderer.Thread when it exits.
pub fn threadExit(self: *const OpenGL) void {
    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.win32 => self.rt_surface.clearGLContextCurrent(),

        apprt.embedded => {
            // TODO: see threadEnter
        },
    }
}

pub fn displayRealized(self: *const OpenGL) void {
    _ = self;
}

fn ensureWin32SwapInterval(self: *OpenGL) void {
    if (apprt.runtime != apprt.win32) return;
    if (self.swap_interval_configured) return;
    self.swap_interval_configured = true;
    if (!enable_win32_swap_interval) {
        self.swap_interval_supported = false;
        return;
    }

    const proc = apprt.win32.getProcAddress(wgl_swap_interval_ext_name) orelse {
        log.debug("WGL swap interval extension unavailable; leaving window-vsync unmanaged", .{});
        return;
    };
    const set_swap_interval: WglSwapIntervalExt = @ptrCast(proc);
    const interval: c_int = if (self.vsync_enabled) 1 else 0;
    if (set_swap_interval(interval) == 0) {
        log.warn("failed to configure WGL swap interval interval={}", .{interval});
        return;
    }

    self.swap_interval_supported = true;
    log.debug("configured WGL swap interval interval={}", .{interval});
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameStart(self: *OpenGL) void {
    _ = self;
}

/// Actions taken after `drawFrame` is done.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameEnd(self: *OpenGL) void {
    _ = self;
}

pub fn hasVsync(self: *const OpenGL) bool {
    return self.vsync_enabled and self.swap_interval_supported;
}

pub fn initShaders(
    self: *const OpenGL,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(
        self.alloc,
        custom_shaders,
    );
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const OpenGL) !struct { width: u32, height: u32 } {
    switch (apprt.runtime) {
        apprt.win32 => {
            const size = try self.rt_surface.getSize();
            return .{
                .width = @intCast(size.width),
                .height = @intCast(size.height),
            };
        },

        else => {
            var viewport: [4]gl.c.GLint = undefined;
            gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &viewport);
            return .{
                .width = @intCast(viewport[2]),
                .height = @intCast(viewport[3]),
            };
        },
    }
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const OpenGL, width: usize, height: usize) !Target {
    return Target.init(.{
        .internal_format = if (self.blending.isLinear()) .srgba else .rgba,
        .width = width,
        .height = height,
    });
}

/// Present the provided target.
pub fn present(self: *OpenGL, target: Target) !void {
    if (target.width == 0 or target.height == 0) return;

    if (apprt.runtime == apprt.win32) {
        try self.rt_surface.makeGLContextCurrent();
        self.ensureWin32SwapInterval();
    }

    // In order to present a target we blit it to the default framebuffer.

    // We disable GL_FRAMEBUFFER_SRGB while doing this blit, otherwise the
    // values may be linearized as they're copied, but even though the draw
    // framebuffer has a linear internal format, the values in it should be
    // sRGB, not linear!
    try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
        log.err("Error re-enabling GL_FRAMEBUFFER_SRGB, err={}", .{err});
    };

    // Bind the target for reading.
    const fbobind = try target.framebuffer.bind(.read);
    defer fbobind.unbind();

    const dst_width: i32, const dst_height: i32 = if (apprt.runtime == apprt.win32) size: {
        const size = try self.surfaceSize();
        break :size .{ @intCast(size.width), @intCast(size.height) };
    } else .{ @intCast(target.width), @intCast(target.height) };

    if (dst_width <= 0 or dst_height <= 0) return;

    // Blit
    gl.glad.context.BlitFramebuffer.?(
        0,
        0,
        @intCast(target.width),
        @intCast(target.height),
        0,
        0,
        dst_width,
        dst_height,
        gl.c.GL_COLOR_BUFFER_BIT,
        gl.c.GL_NEAREST,
    );

    // Keep track of this target in case we need to repeat it.
    self.last_target = target;

    if (apprt.runtime == apprt.win32) {
        try self.rt_surface.swapGLBuffers();
    }
}

/// Present the last presented target again.
pub fn presentLastTarget(self: *OpenGL) !void {
    if (self.last_target) |target| try self.present(target);
}

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: OpenGL) bufferpkg.Options {
    _ = self;
    return .{
        .target = .array,
        .usage = .dynamic_draw,
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: OpenGL) Texture.Options {
    _ = self;
    return .{
        .format = .rgba,
        .internal_format = .srgba,
        .target = .@"2D",
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: OpenGL) Sampler.Options {
    _ = self;
    return .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(self: ImageTextureFormat) gl.Texture.Format {
        return switch (self) {
            .gray => .red,
            .rgba => .rgba,
            .bgra => .bgra,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: OpenGL,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    return .{
        .format = format.toPixelFormat(),
        .internal_format = if (srgb) .srgba else .rgba,
        .target = .@"2D",
        // TODO: Generate mipmaps for image textures and use
        //       linear_mipmap_linear filtering so that they
        //       look good even when scaled way down.
        .min_filter = .linear,
        .mag_filter = .linear,
        // TODO: Separate out background image options, use
        //       repeating coordinate modes so we don't have
        //       to do the modulus in the shader.
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const OpenGL,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    _ = self;
    const format: gl.Texture.Format, const internal_format: gl.Texture.InternalFormat =
        switch (atlas.format) {
            .grayscale => .{ .red, .red },
            .bgra => .{ .bgra, .srgba },
            else => @panic("unsupported atlas format for OpenGL texture"),
        };

    return try Texture.init(
        .{
            .format = format,
            .internal_format = internal_format,
            .target = .Rectangle,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const OpenGL,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}

test "OpenGL hasVsync requires enabled swap interval" {
    var api: OpenGL = undefined;
    api.vsync_enabled = true;
    api.swap_interval_supported = false;
    try std.testing.expect(!api.hasVsync());

    api.swap_interval_supported = true;
    try std.testing.expect(api.hasVsync());

    api.vsync_enabled = false;
    try std.testing.expect(!api.hasVsync());
}
