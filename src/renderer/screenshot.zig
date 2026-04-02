//! Screenshot capture: reads the OpenGL default framebuffer and writes a PNG
//! using stb_image_write for proper deflate compression.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rendererpkg = @import("../renderer.zig");

const stbi = @cImport(@cInclude("stb_image_write.h"));

const log = std.log.scoped(.screenshot);

/// Capture the OpenGL default framebuffer once and write a PNG to every
/// path in `requests`. This avoids redundant glReadPixels calls when
/// multiple screenshot requests arrive before a single frame.
pub fn captureOpenGLMulti(
    alloc: Allocator,
    width: u32,
    height: u32,
    requests: []const rendererpkg.Message.Screenshot,
) void {
    captureOpenGLMultiImpl(alloc, width, height, requests) catch |err| {
        log.err("screenshot failed: {}", .{err});
    };
}

fn captureOpenGLMultiImpl(
    alloc: Allocator,
    width: u32,
    height: u32,
    requests: []const rendererpkg.Message.Screenshot,
) !void {
    if (width == 0 or height == 0 or requests.len == 0) return;

    const gl = @import("opengl");

    const stride: usize = @as(usize, width) * 4; // RGBA
    const pixel_bytes: usize = stride * @as(usize, height);
    const pixels = try alloc.alloc(u8, pixel_bytes);
    defer alloc.free(pixels);

    // Read from the default framebuffer (back buffer, where present() blitted to).
    gl.glad.context.ReadPixels.?(
        0,
        0,
        @intCast(width),
        @intCast(height),
        gl.c.GL_RGBA,
        gl.c.GL_UNSIGNED_BYTE,
        pixels.ptr,
    );

    // OpenGL origin is bottom-left; PNG is top-left. Flip vertically.
    flipVertical(pixels, stride, height);

    writePngMulti(requests, pixels, width, height, stride);
}

/// Capture the IOSurface backing a Metal render target and write a PNG
/// to every path in `requests`. The IOSurface pixels are BGRA; we convert
/// to RGBA in-place before writing.
pub fn captureIOSurface(
    alloc: Allocator,
    surface: anytype,
    width: u32,
    height: u32,
    requests: []const rendererpkg.Message.Screenshot,
) void {
    captureIOSurfaceImpl(alloc, surface, width, height, requests) catch |err| {
        log.err("screenshot failed: {}", .{err});
    };
}

fn captureIOSurfaceImpl(
    alloc: Allocator,
    surface: anytype,
    width: u32,
    height: u32,
    requests: []const rendererpkg.Message.Screenshot,
) !void {
    if (width == 0 or height == 0 or requests.len == 0) return;

    // Lock the IOSurface for CPU read access.
    surface.lock();
    defer surface.unlock();

    const base: [*]u8 = surface.getBaseAddress() orelse return error.NoBaseAddress;
    const bytes_per_row = surface.getBytesPerRow();

    // Copy into a contiguous RGBA buffer (IOSurface stride may differ from width*4).
    const stride: usize = @as(usize, width) * 4;
    const pixel_bytes: usize = stride * @as(usize, height);
    const pixels = try alloc.alloc(u8, pixel_bytes);
    defer alloc.free(pixels);

    for (0..height) |y| {
        const src_row = base[y * bytes_per_row ..][0..stride];
        const dst_row = pixels[y * stride ..][0..stride];
        @memcpy(dst_row, src_row);
    }

    // Convert BGRA → RGBA (swap B and R channels).
    var i: usize = 0;
    while (i < pixel_bytes) : (i += 4) {
        const tmp = pixels[i]; // B
        pixels[i] = pixels[i + 2]; // R
        pixels[i + 2] = tmp; // B
    }

    // No vertical flip needed — Metal's origin is top-left, same as PNG.

    // Write PNG to each requested path.
    writePngMulti(requests, pixels, width, height, stride);
}

/// Write the same pixel buffer as PNG to multiple paths.
fn writePngMulti(
    requests: []const rendererpkg.Message.Screenshot,
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
) void {
    for (requests) |req| {
        const result = stbi.stbi_write_png(
            req.path.ptr,
            @intCast(width),
            @intCast(height),
            4,
            pixels.ptr,
            @intCast(stride),
        );

        if (result == 0) {
            log.err("failed to write screenshot to {s}", .{req.path});
        } else {
            var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
            const abs_path = std.fs.cwd().realpath(
                std.mem.sliceTo(req.path, 0),
                &abs_buf,
            ) catch req.path;
            log.info("screenshot saved to {s}", .{abs_path});
        }
    }
}

/// Flip pixel buffer vertically in-place.
fn flipVertical(pixels: []u8, stride: usize, height: u32) void {
    var top: usize = 0;
    var bot: usize = @as(usize, height) - 1;
    while (top < bot) {
        const top_row = pixels[top * stride ..][0..stride];
        const bot_row = pixels[bot * stride ..][0..stride];
        for (top_row, bot_row) |*a, *b| {
            const tmp = a.*;
            a.* = b.*;
            b.* = tmp;
        }
        top += 1;
        bot -= 1;
    }
}
