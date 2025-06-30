const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const wuffs = @import("wuffs");

const Renderer = @import("../renderer.zig").Renderer;
const GraphicsAPI = Renderer.API;
const Texture = GraphicsAPI.Texture;

/// Represents a single image placement on the grid.
/// A placement is a request to render an instance of an image.
pub const Placement = struct {
    /// The image being rendered. This MUST be in the image map.
    image_id: u32,

    /// The grid x/y where this placement is located.
    x: i32,
    y: i32,
    z: i32,

    /// The width/height of the placed image.
    width: u32,
    height: u32,

    /// The offset in pixels from the top left of the cell.
    /// This is clamped to the size of a cell.
    cell_offset_x: u32,
    cell_offset_y: u32,

    /// The source rectangle of the placement.
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
};

/// The map used for storing images.
pub const ImageMap = std.AutoHashMapUnmanaged(u32, struct {
    image: Image,
    transmit_time: std.time.Instant,
});

/// The state for a single image that is to be rendered.
pub const Image = union(enum) {
    /// The image data is pending upload to the GPU.
    ///
    /// This data is owned by this union so it must be freed once uploaded.
    pending: Pending,

    /// This is the same as the pending states but there is
    /// a texture already allocated that we want to replace.
    replace: Replace,

    /// The image is uploaded and ready to be used.
    ready: Texture,

    /// The image isn't uploaded yet but is scheduled to be unloaded.
    unload_pending: Pending,
    /// The image is uploaded and is scheduled to be unloaded.
    unload_ready: Texture,
    /// The image is uploaded and scheduled to be replaced
    /// with new data, but it's also scheduled to be unloaded.
    unload_replace: Replace,

    pub const Replace = struct {
        texture: Texture,
        pending: Pending,
    };

    /// Pending image data that needs to be uploaded to the GPU.
    pub const Pending = struct {
        height: u32,
        width: u32,
        pixel_format: PixelFormat,

        /// Data is always expected to be (width * height * bpp).
        data: [*]u8,

        pub fn dataSlice(self: Pending) []u8 {
            return self.data[0..self.len()];
        }

        pub fn len(self: Pending) usize {
            return self.width * self.height * self.pixel_format.bpp();
        }

        pub const PixelFormat = enum {
            /// 1 byte per pixel grayscale.
            gray,
            /// 2 bytes per pixel grayscale + alpha.
            gray_alpha,
            /// 3 bytes per pixel RGB.
            rgb,
            /// 3 bytes per pixel BGR.
            bgr,
            /// 4 byte per pixel RGBA.
            rgba,
            /// 4 byte per pixel BGRA.
            bgra,

            /// Get bytes per pixel for this format.
            pub inline fn bpp(self: PixelFormat) usize {
                return switch (self) {
                    .gray => 1,
                    .gray_alpha => 2,
                    .rgb => 3,
                    .bgr => 3,
                    .rgba => 4,
                    .bgra => 4,
                };
            }
        };
    };

    pub fn deinit(self: Image, alloc: Allocator) void {
        switch (self) {
            .pending,
            .unload_pending,
            => |p| alloc.free(p.dataSlice()),

            .replace, .unload_replace => |r| {
                alloc.free(r.pending.dataSlice());
                r.texture.deinit();
            },

            .ready,
            .unload_ready,
            => |t| t.deinit(),
        }
    }

    /// Mark this image for unload whatever state it is in.
    pub fn markForUnload(self: *Image) void {
        self.* = switch (self.*) {
            .unload_pending,
            .unload_replace,
            .unload_ready,
            => return,

            .ready => |t| .{ .unload_ready = t },
            .pending => |p| .{ .unload_pending = p },
            .replace => |r| .{ .unload_replace = r },
        };
    }

    /// Mark the current image to be replaced with a pending one. This will
    /// attempt to update the existing texture if we have one, otherwise it
    /// will act like a new upload.
    pub fn markForReplace(self: *Image, alloc: Allocator, img: Image) !void {
        assert(img.isPending());

        // If we have pending data right now, free it.
        if (self.getPending()) |p| {
            alloc.free(p.dataSlice());
        }
        // If we have an existing texture, use it in the replace.
        if (self.getTexture()) |t| {
            self.* = .{ .replace = .{
                .texture = t,
                .pending = img.getPending().?,
            } };
            return;
        }
        // Otherwise we just become a pending image.
        self.* = .{ .pending = img.getPending().? };
    }

    /// Returns true if this image is pending upload.
    pub fn isPending(self: Image) bool {
        return self.getPending() != null;
    }

    /// Returns true if this image has an associated texture.
    pub fn hasTexture(self: Image) bool {
        return self.getTexture() != null;
    }

    /// Returns true if this image is marked for unload.
    pub fn isUnloading(self: Image) bool {
        return switch (self) {
            .unload_pending,
            .unload_replace,
            .unload_ready,
            => true,

            .pending,
            .replace,
            .ready,
            => false,
        };
    }

    /// Converts the image data to a format that can be uploaded to the GPU.
    /// If the data is already in a format that can be uploaded, this is a
    /// no-op.
    pub fn convert(self: *Image, alloc: Allocator) wuffs.Error!void {
        const p = self.getPendingPointer().?;
        // As things stand, we currently convert all images to RGBA before
        // uploading to the GPU. This just makes things easier. In the future
        // we may want to support other formats.
        if (p.pixel_format == .rgba) return;
        // If the pending data isn't RGBA we'll need to swizzle it.
        const data = p.dataSlice();
        const rgba = try switch (p.pixel_format) {
            .gray => wuffs.swizzle.gToRgba(alloc, data),
            .gray_alpha => wuffs.swizzle.gaToRgba(alloc, data),
            .rgb => wuffs.swizzle.rgbToRgba(alloc, data),
            .bgr => wuffs.swizzle.bgrToRgba(alloc, data),
            .rgba => unreachable,
            .bgra => wuffs.swizzle.bgraToRgba(alloc, data),
        };
        alloc.free(data);
        p.data = rgba.ptr;
        p.pixel_format = .rgba;
    }

    /// Prepare the pending image data for upload to the GPU.
    /// This doesn't need GPU access so is safe to call any time.
    pub fn prepForUpload(self: *Image, alloc: Allocator) !void {
        assert(self.isPending());

        try self.convert(alloc);
    }

    /// Upload the pending image to the GPU and
    /// change the state of this image to ready.
    pub fn upload(
        self: *Image,
        alloc: Allocator,
        api: *const GraphicsAPI,
    ) !void {
        assert(self.isPending());

        try self.prepForUpload(alloc);

        // Get our pending info
        const p = self.getPending().?;

        // Create our texture
        const texture = try Texture.init(
            api.imageTextureOptions(.rgba, true),
            @intCast(p.width),
            @intCast(p.height),
            p.dataSlice(),
        );

        // Uploaded. We can now clear our data and change our state.
        //
        // NOTE: For the `replace` state, this will free the old texture.
        //       We don't currently actually replace the existing texture
        //       in-place but that is an optimization we can do later.
        self.deinit(alloc);
        self.* = .{ .ready = texture };
    }

    /// Returns any pending image data for this image that requires upload.
    ///
    /// If there is no pending data to upload, returns null.
    fn getPending(self: Image) ?Pending {
        return switch (self) {
            .pending,
            .unload_pending,
            => |p| p,

            .replace,
            .unload_replace,
            => |r| r.pending,

            else => null,
        };
    }

    /// Returns the texture for this image.
    ///
    /// If there is no texture for it yet, returns null.
    fn getTexture(self: Image) ?Texture {
        return switch (self) {
            .ready,
            .unload_ready,
            => |t| t,

            .replace,
            .unload_replace,
            => |r| r.texture,

            else => null,
        };
    }

    // Same as getPending but returns a pointer instead of a copy.
    fn getPendingPointer(self: *Image) ?*Pending {
        return switch (self.*) {
            .pending => return &self.pending,
            .unload_pending => return &self.unload_pending,

            .replace => return &self.replace.pending,
            .unload_replace => return &self.unload_replace.pending,

            else => null,
        };
    }
};
