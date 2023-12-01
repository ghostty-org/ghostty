const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const objc = @import("objc");

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
pub const ImageMap = std.AutoHashMapUnmanaged(u32, Image);

/// The state for a single image that is to be rendered. The image can be
/// pending upload or ready to use with a texture.
pub const Image = union(enum) {
    /// The image is pending upload to the GPU. The different keys are
    /// different formats since some formats aren't accepted by the GPU
    /// and require conversion.
    ///
    /// This data is owned by this union so it must be freed once the
    /// image is uploaded.
    pending_rgb: Pending,
    pending_rgba: Pending,

    /// The image is uploaded and ready to be used.
    ready: objc.Object, // MTLTexture

    /// The image is uploaded but is scheduled to be unloaded.
    unload_pending: []u8,
    unload_ready: objc.Object, // MTLTexture

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
            .pending_rgb => |p| alloc.free(p.dataSlice(3)),
            .pending_rgba => |p| alloc.free(p.dataSlice(4)),
            .unload_pending => |data| alloc.free(data),

            .ready,
            .unload_ready,
            => |obj| obj.msgSend(void, objc.sel("release"), .{}),
        }
    }

    /// Mark this image for unload whatever state it is in.
    pub fn markForUnload(self: *Image) void {
        self.* = switch (self.*) {
            .unload_pending,
            .unload_ready,
            => return,

            .ready => |obj| .{ .unload_ready = obj },
            .pending_rgb => |p| .{ .unload_pending = p.dataSlice(3) },
            .pending_rgba => |p| .{ .unload_pending = p.dataSlice(4) },
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
            .unload_ready,
            => unreachable, // invalid

            .pending_rgba => {}, // ready

            // RGB needs to be converted to RGBA because Metal textures
            // don't support RGB.
            .pending_rgb => |*p| {
                // Note: this is the slowest possible way to do this...
                const data = p.dataSlice(3);
                const pixels = data.len / 3;
                var rgba = try alloc.alloc(u8, pixels * 4);
                errdefer alloc.free(rgba);
                var i: usize = 0;
                while (i < pixels) : (i += 1) {
                    const data_i = i * 3;
                    const rgba_i = i * 4;
                    rgba[rgba_i] = data[data_i];
                    rgba[rgba_i + 1] = data[data_i + 1];
                    rgba[rgba_i + 2] = data[data_i + 2];
                    rgba[rgba_i + 3] = 255;
                }

                alloc.free(data);
                p.data = rgba.ptr;
                self.* = .{ .pending_rgba = p.* };
            },
        }
    }

    /// Upload the pending image to the GPU and change the state of this
    /// image to ready.
    pub fn upload(
        self: *Image,
        alloc: Allocator,
        device: objc.Object,
    ) !void {
        // Convert our data if we have to
        try self.convert(alloc);

        // Get our pending info
        const p = self.pending().?;

        // Create our texture
        const texture = try initTexture(p, device);
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
        self.deinit(alloc);
        self.* = .{ .ready = texture };
    }

    /// Our pixel depth
    fn depth(self: Image) u32 {
        return switch (self) {
            .pending_rgb => 3,
            .pending_rgba => 4,
            else => unreachable,
        };
    }

    /// Returns true if this image is in a pending state and requires upload.
    fn pending(self: Image) ?Pending {
        return switch (self) {
            .pending_rgb,
            .pending_rgba,
            => |p| p,

            else => null,
        };
    }

    fn initTexture(p: Pending, device: objc.Object) !objc.Object {
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

        // Initialize
        const id = device.msgSend(
            ?*anyopaque,
            objc.sel("newTextureWithDescriptor:"),
            .{desc},
        ) orelse return error.MetalFailed;

        return objc.Object.fromId(id);
    }
};
