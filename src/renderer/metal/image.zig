const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const objc = @import("objc");
const wuffs = @import("wuffs");

const mtl = @import("api.zig");

/// Represents a single image placement on the grid. A placement is a
/// request to render an instance of an image.
pub const Placement = struct {
    /// The image being rendered. This MUST be in the image map.
    image_id: u32,

    /// The grid x/y where this placement is located.
    x: u32,
    y: u32,
    z: i32,

    /// The width/height of the placed image.
    width: u32,
    height: u32,

    /// The offset in pixels from the top left of the cell. This is
    /// clamped to the size of a cell.
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

/// The state for a single image that is to be rendered. The image can be
/// pending upload or ready to use with a texture.
pub const Image = union(enum) {
    /// The image is pending upload to the GPU. The different keys are
    /// different formats since some formats aren't accepted by the GPU
    /// and require conversion.
    ///
    /// This data is owned by this union so it must be freed once the
    /// image is uploaded.
    pending_gray: Pending,
    pending_gray_alpha: Pending,
    pending_rgb: Pending,
    pending_rgba: Pending,

    /// This is the same as the pending states but there is a texture
    /// already allocated that we want to replace.
    replace_gray: Replace,
    replace_gray_alpha: Replace,
    replace_rgb: Replace,
    replace_rgba: Replace,

    /// The image is uploaded and ready to be used.
    ready: objc.Object, // MTLTexture

    /// The image is uploaded but is scheduled to be unloaded.
    unload_pending: []u8,
    unload_ready: objc.Object, // MTLTexture
    unload_replace: struct { []u8, objc.Object },

    pub const Replace = struct {
        texture: objc.Object,
        pending: Pending,
    };

    /// Pending image data that needs to be uploaded to the GPU.
    pub const Pending = struct {
        height: u32,
        width: u32,

        /// Data is always expected to be (width * height * depth). Depth
        /// is based on the union key.
        data: [*]u8,

        pub fn dataSlice(self: Pending, d: u32) []u8 {
            return self.data[0..self.len(d)];
        }

        pub fn len(self: Pending, d: u32) u32 {
            return self.width * self.height * d;
        }
    };

    pub fn deinit(self: Image, alloc: Allocator) void {
        switch (self) {
            .pending_gray => |p| alloc.free(p.dataSlice(1)),
            .pending_gray_alpha => |p| alloc.free(p.dataSlice(2)),
            .pending_rgb => |p| alloc.free(p.dataSlice(3)),
            .pending_rgba => |p| alloc.free(p.dataSlice(4)),
            .unload_pending => |data| alloc.free(data),

            .replace_gray => |r| {
                alloc.free(r.pending.dataSlice(1));
                r.texture.msgSend(void, objc.sel("release"), .{});
            },

            .replace_gray_alpha => |r| {
                alloc.free(r.pending.dataSlice(2));
                r.texture.msgSend(void, objc.sel("release"), .{});
            },

            .replace_rgb => |r| {
                alloc.free(r.pending.dataSlice(3));
                r.texture.msgSend(void, objc.sel("release"), .{});
            },

            .replace_rgba => |r| {
                alloc.free(r.pending.dataSlice(4));
                r.texture.msgSend(void, objc.sel("release"), .{});
            },

            .unload_replace => |r| {
                alloc.free(r[0]);
                r[1].msgSend(void, objc.sel("release"), .{});
            },

            .ready,
            .unload_ready,
            => |obj| obj.msgSend(void, objc.sel("release"), .{}),
        }
    }

    /// Mark this image for unload whatever state it is in.
    pub fn markForUnload(self: *Image) void {
        self.* = switch (self.*) {
            .unload_pending,
            .unload_replace,
            .unload_ready,
            => return,

            .ready => |obj| .{ .unload_ready = obj },
            .pending_gray => |p| .{ .unload_pending = p.dataSlice(1) },
            .pending_gray_alpha => |p| .{ .unload_pending = p.dataSlice(2) },
            .pending_rgb => |p| .{ .unload_pending = p.dataSlice(3) },
            .pending_rgba => |p| .{ .unload_pending = p.dataSlice(4) },
            .replace_gray => |r| .{ .unload_replace = .{
                r.pending.dataSlice(1), r.texture,
            } },
            .replace_gray_alpha => |r| .{ .unload_replace = .{
                r.pending.dataSlice(2), r.texture,
            } },
            .replace_rgb => |r| .{ .unload_replace = .{
                r.pending.dataSlice(3), r.texture,
            } },
            .replace_rgba => |r| .{ .unload_replace = .{
                r.pending.dataSlice(4), r.texture,
            } },
        };
    }

    /// Replace the currently pending image with a new one. This will
    /// attempt to update the existing texture if it is already allocated.
    /// If the texture is not allocated, this will act like a new upload.
    ///
    /// This function only marks the image for replace. The actual logic
    /// to replace is done later.
    pub fn markForReplace(self: *Image, alloc: Allocator, img: Image) !void {
        assert(img.pending() != null);

        // Get our existing texture. This switch statement will also handle
        // scenarios where there is no existing texture and we can modify
        // the self pointer directly.
        const existing: objc.Object = switch (self.*) {
            // For pending, we can free the old data and become pending
            // ourselves.
            .pending_gray => |p| {
                alloc.free(p.dataSlice(1));
                self.* = img;
                return;
            },

            .pending_gray_alpha => |p| {
                alloc.free(p.dataSlice(2));
                self.* = img;
                return;
            },

            .pending_rgb => |p| {
                alloc.free(p.dataSlice(3));
                self.* = img;
                return;
            },

            .pending_rgba => |p| {
                alloc.free(p.dataSlice(4));
                self.* = img;
                return;
            },

            // If we're marked for unload but we just have pending data,
            // this behaves the same as a normal "pending": free the data,
            // become new pending.
            .unload_pending => |data| {
                alloc.free(data);
                self.* = img;
                return;
            },

            .unload_replace => |r| existing: {
                alloc.free(r[0]);
                break :existing r[1];
            },

            // If we were already pending a replacement, then we free our
            // existing pending data and use the same texture.
            .replace_gray => |r| existing: {
                alloc.free(r.pending.dataSlice(1));
                break :existing r.texture;
            },

            .replace_gray_alpha => |r| existing: {
                alloc.free(r.pending.dataSlice(2));
                break :existing r.texture;
            },

            .replace_rgb => |r| existing: {
                alloc.free(r.pending.dataSlice(3));
                break :existing r.texture;
            },

            .replace_rgba => |r| existing: {
                alloc.free(r.pending.dataSlice(4));
                break :existing r.texture;
            },

            // For both ready and unload_ready, we need to replace the
            // texture. We can't do that here, so we just mark ourselves
            // for replacement.
            .ready, .unload_ready => |tex| tex,
        };

        // We now have an existing texture, so set the proper replace key.
        self.* = switch (img) {
            .pending_gray => |p| .{ .replace_gray = .{
                .texture = existing,
                .pending = p,
            } },

            .pending_gray_alpha => |p| .{ .replace_gray_alpha = .{
                .texture = existing,
                .pending = p,
            } },

            .pending_rgb => |p| .{ .replace_rgb = .{
                .texture = existing,
                .pending = p,
            } },

            .pending_rgba => |p| .{ .replace_rgba = .{
                .texture = existing,
                .pending = p,
            } },

            else => unreachable,
        };
    }

    /// Returns true if this image is pending upload.
    pub fn isPending(self: Image) bool {
        return self.pending() != null;
    }

    /// Returns true if this image is pending an unload.
    pub fn isUnloading(self: Image) bool {
        return switch (self) {
            .unload_pending,
            .unload_ready,
            => true,

            .ready,
            .pending_rgb,
            .pending_rgba,
            => false,
        };
    }

    /// Converts the image data to a format that can be uploaded to the GPU.
    /// If the data is already in a format that can be uploaded, this is a
    /// no-op.
    pub fn convert(self: *Image, alloc: Allocator) !void {
        switch (self.*) {
            .ready,
            .unload_pending,
            .unload_replace,
            .unload_ready,
            => unreachable, // invalid

            .pending_rgba,
            .replace_rgba,
            => {}, // ready

            // RGB needs to be converted to RGBA because Metal textures
            // don't support RGB.
            .pending_rgb => |*p| {
                const data = p.dataSlice(3);
                const rgba = try wuffs.swizzle.rgbToRgba(alloc, data);
                alloc.free(data);
                p.data = rgba.ptr;
                self.* = .{ .pending_rgba = p.* };
            },

            .replace_rgb => |*r| {
                const data = r.pending.dataSlice(3);
                const rgba = try wuffs.swizzle.rgbToRgba(alloc, data);
                alloc.free(data);
                r.pending.data = rgba.ptr;
                self.* = .{ .replace_rgba = r.* };
            },

            // Gray and Gray+Alpha need to be converted to RGBA, too.
            .pending_gray => |*p| {
                const data = p.dataSlice(1);
                const rgba = try wuffs.swizzle.gToRgba(alloc, data);
                alloc.free(data);
                p.data = rgba.ptr;
                self.* = .{ .pending_rgba = p.* };
            },

            .replace_gray => |*r| {
                const data = r.pending.dataSlice(2);
                const rgba = try wuffs.swizzle.gToRgba(alloc, data);
                alloc.free(data);
                r.pending.data = rgba.ptr;
                self.* = .{ .replace_rgba = r.* };
            },

            .pending_gray_alpha => |*p| {
                const data = p.dataSlice(2);
                const rgba = try wuffs.swizzle.gaToRgba(alloc, data);
                alloc.free(data);
                p.data = rgba.ptr;
                self.* = .{ .pending_rgba = p.* };
            },

            .replace_gray_alpha => |*r| {
                const data = r.pending.dataSlice(2);
                const rgba = try wuffs.swizzle.gaToRgba(alloc, data);
                alloc.free(data);
                r.pending.data = rgba.ptr;
                self.* = .{ .replace_rgba = r.* };
            },
        }
    }

    /// Upload the pending image to the GPU and change the state of this
    /// image to ready.
    pub fn upload(
        self: *Image,
        alloc: Allocator,
        device: objc.Object,
        /// Storage mode for the MTLTexture object
        storage_mode: mtl.MTLResourceOptions.StorageMode,
    ) !void {
        // Convert our data if we have to
        try self.convert(alloc);

        // Get our pending info
        const p = self.pending().?;

        // Create our texture
        const texture = try initTexture(p, device, storage_mode);
        errdefer texture.msgSend(void, objc.sel("release"), .{});

        // Upload our data
        const d = self.depth();
        texture.msgSend(
            void,
            objc.sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
            .{
                mtl.MTLRegion{
                    .origin = .{ .x = 0, .y = 0, .z = 0 },
                    .size = .{
                        .width = @intCast(p.width),
                        .height = @intCast(p.height),
                        .depth = 1,
                    },
                },
                @as(c_ulong, 0),
                @as(*const anyopaque, p.data),
                @as(c_ulong, d * p.width),
            },
        );

        // Uploaded. We can now clear our data and change our state.
        //
        // NOTE: For "replace_*" states, this will free the old texture.
        // We don't currently actually replace the existing texture in-place
        // but that is an optimization we can do later.
        self.deinit(alloc);
        self.* = .{ .ready = texture };
    }

    /// Our pixel depth
    fn depth(self: Image) u32 {
        return switch (self) {
            .pending_rgb => 3,
            .pending_rgba => 4,
            .replace_rgb => 3,
            .replace_rgba => 4,
            else => unreachable,
        };
    }

    /// Returns true if this image is in a pending state and requires upload.
    fn pending(self: Image) ?Pending {
        return switch (self) {
            .pending_rgb,
            .pending_rgba,
            => |p| p,

            .replace_rgb,
            .replace_rgba,
            => |r| r.pending,

            else => null,
        };
    }

    fn initTexture(
        p: Pending,
        device: objc.Object,
        /// Storage mode for the MTLTexture object
        storage_mode: mtl.MTLResourceOptions.StorageMode,
    ) !objc.Object {
        // Create our descriptor
        const desc = init: {
            const Class = objc.getClass("MTLTextureDescriptor").?;
            const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
            const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
            break :init id_init;
        };

        // Set our properties
        desc.setProperty("pixelFormat", @intFromEnum(mtl.MTLPixelFormat.rgba8uint));
        desc.setProperty("width", @as(c_ulong, @intCast(p.width)));
        desc.setProperty("height", @as(c_ulong, @intCast(p.height)));

        desc.setProperty(
            "resourceOptions",
            mtl.MTLResourceOptions{
                // Indicate that the CPU writes to this resource but never reads it.
                .cpu_cache_mode = .write_combined,
                .storage_mode = storage_mode,
            },
        );

        // Initialize
        const id = device.msgSend(
            ?*anyopaque,
            objc.sel("newTextureWithDescriptor:"),
            .{desc},
        ) orelse return error.MetalFailed;

        return objc.Object.fromId(id);
    }
};
