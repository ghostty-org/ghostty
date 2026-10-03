//! The OpenGL device context.
//!
//! This holds the EGL display and config used to create EGL
//! contexts, each corresponding to a surface, its renderer
//! object and its render thread.
//!
//! TODO: If there's a way to prefer certain devices like in
//! Vulkan or Metal we should do it here.
const Device = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;

const log = std.log.scoped(.opengl);

/// The EGL display.
///
/// Since we use the default display, this is torn down
/// automagically by the OS.
display: *egl.Display,

/// The EGL config used to create surface renderer contexts. Chosen
/// once here so that all contexts share compatible capabilities.
config: *egl.Config,

pub fn init(self: *Device, alloc: Allocator) !void {
    _ = alloc;

    try egl.load();

    const display = egl.Display.initPlatform(
        egl.c.EGL_PLATFORM_SURFACELESS_MESA,
        egl.c.EGL_DEFAULT_DISPLAY,
        null,
    ) catch |err| {
        if (err == error.BadParameter) logUnsupportedPlatform();
        return err;
    };

    log.info("EGL vendor={s}", .{display.queryString(.vendor) orelse "(unknown)"});
    log.info("EGL extensions={s}", .{display.queryString(.extensions) orelse "(unknown)"});

    // Choose a config. We need a config that is renderable with
    // OpenGL and a RGBA8 color buffer.
    const config = egl.Config.choose(display, &.{
        egl.c.EGL_SURFACE_TYPE,    0,
        egl.c.EGL_RENDERABLE_TYPE, egl.c.EGL_OPENGL_BIT,
        egl.c.EGL_RED_SIZE,        8,
        egl.c.EGL_GREEN_SIZE,      8,
        egl.c.EGL_BLUE_SIZE,       8,
        egl.c.EGL_ALPHA_SIZE,      8,
    }) catch |err| {
        log.warn("failed to choose config err={}", .{err});
        return err;
    };

    self.* = .{
        .display = display,
        .config = config,
    };
}

/// EGL_BAD_PARAMETER from eglGetPlatformDisplay means that no loaded
/// EGL driver supports the surfaceless platform. Most often that is
/// because no driver could be loaded at all, for example because the
/// system's driver needs a newer libc than Ghostty was built against,
/// so say which it is rather than leaving a bare error name.
fn logUnsupportedPlatform() void {
    // With no driver loaded, libglvnd reports no client extensions
    // at all, since every platform comes from a driver.
    const exts = egl.queryClientExtensions() orelse "";
    if (exts.len == 0) {
        log.err("no EGL driver could be loaded; check that a GPU driver " ++
            "is installed and was built against a compatible libc " ++
            "(LD_DEBUG=libs shows why a driver failed to load)", .{});
        return;
    }

    if (!egl.hasExtension(exts, "EGL_MESA_platform_surfaceless")) {
        log.err("the EGL driver does not support EGL_MESA_platform_surfaceless " ++
            "client extensions={s}", .{exts});
        return;
    }

    log.err("the EGL driver rejected the surfaceless platform; " ++
        "client extensions={s}", .{exts});
}

pub fn deinit(self: *Device) void {
    // Do not destroy the EGL display here as
    // it is shared across the entire process.
    // It will get automatically torn down by the OS.
    self.* = undefined;
}
