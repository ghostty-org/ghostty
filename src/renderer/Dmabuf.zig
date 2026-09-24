//! A DMABUF frame produced by exporting a GPU texture.
//! This may be used on apprts like GTK that require us to manually
//! export each frame and import them as textures in their UI scene graphs.
//!
//! Note that DMABUFs are independent of the graphics API used:
//! the OpenGL renderer allocates them with GBM, and Vulkan can
//! export them with a KHR external memory implementation. Therefore
//! this struct has to be placed parallel to the renderer
//! implementations.
pub const Dmabuf = @This();
pub const std = @import("std");

/// The maximum number of planes in a DMABUF that we support.
/// This matches the maximum found in apprts such as GTK.
pub const max_planes = 4;

/// Width of the texture in device pixels.
width: u32,

/// Height of the texture in device pixels.
height: u32,

/// DRM fourcc of the pixel format.
/// Ghostty renders RGBA/BGRA8 premultiplied.
fourcc: u32,

/// DRM modifier of the format.
modifier: u64,

/// Whether the data is premultiplied.
/// Ghostty's GL renderers output premultiplied alpha.
premultiplied: bool,

/// The DMABUF planes for a presented frame. The DMABUF owns the fds
/// and must either call `deinit` manually, or pass them to an apprt
/// that consumes them.
planes: Planes,

pub const Planes = struct {
    /// Number of planes. Valid planes are `planes[0..count]`.
    count: u8,

    /// File descriptor for each plane.
    fds: [max_planes]std.posix.fd_t = @splat(-1),

    /// Offset into the DMABUF where each plane starts, in bytes.
    offsets: [max_planes]c_int = @splat(0),

    /// Strides of each plane, in bytes.
    strides: [max_planes]c_int = @splat(0),

    /// Close all valid fds.
    pub fn deinit(self: Planes) void {
        for (self.fds[0..self.count]) |fd| {
            if (fd >= 0) _ = std.posix.system.close(fd);
        }
    }

    /// Validate the current planes. If any plane failed to export
    /// and has an invalid FD, we close all the known valid FDs
    /// and bail.
    pub fn validate(self: Planes) error{BadDmabuf}!void {
        var n_valid: usize = 0;
        while (n_valid < self.count) : (n_valid += 1) {
            if (self.fds[n_valid] < 0) {
                for (self.fds[0..n_valid]) |bad| _ = std.posix.system.close(bad);
                return error.BadDmabuf;
            }
        }
    }
};

pub fn deinit(self: Dmabuf) void {
    self.planes.deinit();
}
