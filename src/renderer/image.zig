const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const wuffs = @import("wuffs");
const terminal = @import("../terminal/main.zig");
const global = @import("../global.zig");

const Renderer = @import("../renderer.zig").Renderer;
const GraphicsAPI = Renderer.API;
const Texture = GraphicsAPI.Texture;
const Overlay = @import("Overlay.zig");

pub const ArcPixels = @import("../datastruct/main.zig").AtomicRefCounted([]u8);

const log = std.log.scoped(.renderer_image);

/// Generic image rendering state for the renderer. This stores all
/// images and their placements and exposes only a limited public API
/// for adding images and placements and drawing them.
pub const State = struct {
    /// The full image state for the renderer that specifies what images
    /// need to be uploaded, pruned, etc.
    images: ImageMap,

    /// The placements for the Kitty image protocol, sorted by layer and
    /// then by z-index.
    kitty_placements: std.ArrayList(Placement),

    /// Where the layers of `kitty_placements` end. Placements before
    /// `kitty_bg_end` are drawn below the cell backgrounds. Placements
    /// from `kitty_bg_end` up to `kitty_text_end` are drawn below the
    /// text, and the rest are drawn above it.
    kitty_bg_end: u32,
    kitty_text_end: u32,

    /// The render state's `imagePlacementsGeneration` when
    /// `kitty_placements` was last built. Every Kitty placement comes
    /// from the render state, so a different value means
    /// `kitty_placements` is out of date.
    kitty_placements_generation: u64,

    /// The active screen's `ImageStorage.generation` when
    /// `kitty_placements` was last built. Some changes to the images
    /// don't change any placement but still need an update. For example,
    /// deleting an image that has no placements leaves the placements as
    /// they were, but its texture must be unloaded.
    kitty_storage_generation: u64,

    /// Overlays
    overlay_placements: std.ArrayList(Placement),

    pub const empty: State = .{
        .images = .empty,
        .kitty_placements = .empty,
        .kitty_bg_end = 0,
        .kitty_text_end = 0,
        .kitty_placements_generation = 0,
        .kitty_storage_generation = 0,
        .overlay_placements = .empty,
    };

    pub fn deinit(self: *State, alloc: Allocator) void {
        {
            var it = self.images.iterator();
            while (it.next()) |kv| kv.value_ptr.image.deinit(alloc);
            self.images.deinit(alloc);
        }
        self.kitty_placements.deinit(alloc);
        self.overlay_placements.deinit(alloc);
    }

    /// Upload any images to the GPU that need to be uploaded,
    /// and remove any images that are no longer needed on the GPU.
    ///
    /// If any uploads fail, they are ignored. The return value
    /// can be used to detect if upload was a total success (true)
    /// or not (false).
    pub fn upload(
        self: *State,
        alloc: Allocator,
        api: *GraphicsAPI,
    ) bool {
        var success: bool = true;
        var image_it = self.images.iterator();
        while (image_it.next()) |kv| {
            const img = &kv.value_ptr.image;
            if (img.isUnloading()) {
                img.deinit(alloc);
                self.images.removeByPtr(kv.key_ptr);
                continue;
            }

            if (img.isPending()) {
                img.upload(
                    alloc,
                    api,
                ) catch |err| {
                    log.warn("error uploading image to GPU err={}", .{err});
                    success = false;
                };
            }
        }

        return success;
    }

    pub const DrawPlacements = enum {
        kitty_below_bg,
        kitty_below_text,
        kitty_above_text,
        overlay,
    };

    /// Draw the given named set of placements.
    ///
    /// Any placements that have non-uploaded images are ignored. Any
    /// graphics API errors during drawing are also ignored.
    pub fn draw(
        self: *State,
        api: *GraphicsAPI,
        pipeline: GraphicsAPI.Pipeline,
        pass: *GraphicsAPI.RenderPass,
        placement_type: DrawPlacements,
    ) void {
        const placements: []const Placement = switch (placement_type) {
            .kitty_below_bg => self.kitty_placements.items[0..self.kitty_bg_end],
            .kitty_below_text => self.kitty_placements.items[self.kitty_bg_end..self.kitty_text_end],
            .kitty_above_text => self.kitty_placements.items[self.kitty_text_end..],
            .overlay => self.overlay_placements.items,
        };

        for (placements) |p| {
            // Look up the image
            const image = self.images.get(p.image_id) orelse {
                log.warn("image not found for placement image_id={}", .{p.image_id});
                continue;
            };

            // Get the texture
            const texture = switch (image.image) {
                .ready,
                .unload_ready,
                => |t| t,
                else => {
                    log.warn("image not ready for placement image_id={}", .{p.image_id});
                    continue;
                },
            };

            // Create our vertex buffer, which is always exactly one item.
            // future(mitchellh): we can group rendering multiple instances of a single image
            var buf = GraphicsAPI.Buffer(GraphicsAPI.shaders.Image).initFill(
                api.imageBufferOptions(),
                &.{.{
                    .grid_pos = .{
                        @as(f32, @floatFromInt(p.x)),
                        @as(f32, @floatFromInt(p.y)),
                    },

                    .cell_offset = .{
                        @as(f32, @floatFromInt(p.cell_offset_x)),
                        @as(f32, @floatFromInt(p.cell_offset_y)),
                    },

                    .source_rect = .{
                        @as(f32, @floatFromInt(p.source_x)),
                        @as(f32, @floatFromInt(p.source_y)),
                        @as(f32, @floatFromInt(p.source_width)),
                        @as(f32, @floatFromInt(p.source_height)),
                    },

                    .dest_size = .{
                        @as(f32, @floatFromInt(p.width)),
                        @as(f32, @floatFromInt(p.height)),
                    },
                }},
            ) catch |err| {
                log.warn("error creating image vertex buffer err={}", .{err});
                continue;
            };
            defer buf.deinit();

            pass.step(.{
                .pipeline = pipeline,
                .buffers = &.{buf.buffer},
                .textures = &.{texture},
                .draw = .{
                    .type = .triangle_strip,
                    .vertex_count = 4,
                },
            });
        }
    }

    /// Update our overlay state. Null value deletes any existing overlay.
    pub fn overlayUpdate(
        self: *State,
        alloc: Allocator,
        overlay_: ?Overlay,
    ) !void {
        const overlay = overlay_ orelse {
            // If we don't have an overlay, remove any existing one.
            if (self.images.getPtr(.overlay)) |data| {
                data.image.markForUnload();
            }
            return;
        };

        // Overlays are always considered new content, so we take a
        // fresh generation stamp to force replacing any existing one.
        const generation = terminal.kitty.graphics.nextGeneration(global.io());

        // Ensure we have space for our overlay placement. Do this before
        // we upload our image so we don't have to deal with cleaning
        // that up.
        self.overlay_placements.clearRetainingCapacity();
        try self.overlay_placements.ensureUnusedCapacity(alloc, 1);

        // Setup our image.
        const pending = overlay.pendingImage(alloc) catch |err| {
            if (self.images.getPtr(.overlay)) |data| data.image.markForUnload();
            return err;
        };
        defer pending.deinit(alloc);
        try self.prepImage(
            alloc,
            .overlay,
            generation,
            pending,
        );
        errdefer comptime unreachable;

        // Setup our placement
        self.overlay_placements.appendAssumeCapacity(.{
            .image_id = .overlay,
            .layer = .above_text,
            .x = 0,
            .y = 0,
            .z = 0,
            .width = pending.width,
            .height = pending.height,
            .cell_offset_x = 0,
            .cell_offset_y = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = pending.width,
            .source_height = pending.height,
        });
    }

    /// Returns true if `kittyUpdate` must run, because the placements or
    /// the images changed since it last ran. `render_state` must have
    /// just been updated from `t`.
    ///
    /// Most frames return false. A frame that only changes text returns
    /// false unless that text had or now has Kitty placeholder cells.
    ///
    /// This does not read or write state used by drawing.
    pub fn kittyRequiresUpdate(
        self: *const State,
        t: *const terminal.Terminal,
        render_state: *const terminal.RenderState,
    ) bool {
        // The placements changed.
        if (render_state.imagePlacementsGeneration() != self.kitty_placements_generation) return true;

        // The images changed. This catches changes that don't move any
        // placement, such as deleting an image with no placements.
        if (t.screens.active.kitty_images.generation != self.kitty_storage_generation) return true;

        return false;
    }

    /// Rebuild the Kitty placements from the render state, and prepare
    /// or unload the textures they need. `render_state` must have just
    /// been updated from `t`. The terminal is only read to look up
    /// images.
    ///
    /// This reads and writes state used by drawing.
    pub fn kittyUpdate(
        self: *State,
        alloc: Allocator,
        t: *const terminal.Terminal,
        render_state: *const terminal.RenderState,
    ) void {
        const storage = &t.screens.active.kitty_images;

        // Remember what we are building from, so that kittyRequiresUpdate
        // can tell when it changes.
        self.kitty_placements_generation = render_state.imagePlacementsGeneration();
        self.kitty_storage_generation = storage.generation;

        // We always clear our previous placements no matter what because
        // we rebuild them from scratch.
        self.kitty_placements.clearRetainingCapacity();

        // Go through our known images and if there are any that are no longer
        // in use then mark them to be freed.
        //
        // This never conflicts with the below because a placement can't
        // reference an image that doesn't exist.
        {
            var it = self.images.iterator();
            while (it.next()) |kv| {
                switch (kv.key_ptr.*) {
                    // We're only looking at Kitty images
                    .kitty => |id| if (storage.imageById(id)) |image| {
                        // An image whose displayed pixels are pending must
                        // not keep an older texture for the same ID drawable
                        // while its placements wait. For an animation, the
                        // displayed pixels are the current frame's.
                        if (image.renderData().isPending()) {
                            kv.value_ptr.image.markForUnload();
                        }
                    } else {
                        kv.value_ptr.image.markForUnload();
                    },

                    .overlay => {},
                }
            }
        }

        // The render state has already positioned every placement. It
        // was updated under the same lock and only returns placements it
        // can draw, so their images exist and are fully loaded.
        var it = render_state.imagePlacementIterator();
        while (it.next()) |p| {
            const image = switch (p.protocol) {
                .kitty => storage.imageById(p.image_id) orelse continue,
            };

            // For errors we log and continue. We try to place other
            // placements even if one fails.
            self.prepKittyImage(alloc, &image) catch |err| {
                log.warn("error preparing kitty placement err={}", .{err});
                continue;
            };
            self.kitty_placements.append(alloc, .{
                .image_id = .{ .kitty = image.id },
                .layer = p.layer,
                .x = p.x,
                .y = p.y,
                .z = p.z,
                .width = p.width,
                .height = p.height,
                .cell_offset_x = p.offset_x,
                .cell_offset_y = p.offset_y,
                .source_x = p.source_x,
                .source_y = p.source_y,
                .source_width = p.source_width,
                .source_height = p.source_height,
            }) catch |err| {
                log.warn("error preparing kitty placement err={}", .{err});
            };
        }

        // Sort the placements by layer, then by z-index. Placements with
        // the same z-index are ordered by image, so that the order is
        // stable from frame to frame.
        std.mem.sortUnstable(
            Placement,
            self.kitty_placements.items,
            {},
            struct {
                fn lessThan(
                    ctx: void,
                    lhs: Placement,
                    rhs: Placement,
                ) bool {
                    _ = ctx;
                    const lhs_layer = @backingInt(lhs.layer);
                    const rhs_layer = @backingInt(rhs.layer);
                    if (lhs_layer != rhs_layer) return lhs_layer < rhs_layer;
                    return lhs.z < rhs.z or
                        (lhs.z == rhs.z and lhs.image_id.zLessThan(rhs.image_id));
                }
            }.lessThan,
        );

        self.kitty_bg_end = layerEnd(self.kitty_placements.items, .below_background);
        self.kitty_text_end = layerEnd(self.kitty_placements.items, .below_text);
    }

    /// Returns the index of the first placement drawn above `layer`, or
    /// the number of placements if there is none. `placements` must be
    /// sorted by layer.
    fn layerEnd(
        placements: []const Placement,
        layer: terminal.RenderState.ImageLayer,
    ) u32 {
        for (placements, 0..) |p, i| {
            if (@backingInt(p.layer) > @backingInt(layer)) return @intCast(i);
        }
        return @intCast(placements.len);
    }

    const PrepImageError = error{
        OutOfMemory,
    };

    /// Prepare an image for upload to the GPU.
    fn prepImage(
        self: *State,
        alloc: Allocator,
        id: Id,
        generation: u64,
        pending: Image.Pending,
    ) PrepImageError!void {
        // If this image exists and its generation is the same it is the
        // identical image so we don't need to send it to the GPU.
        const gop = try self.images.getOrPut(alloc, id);
        if (gop.found_existing and
            gop.value_ptr.generation == generation)
        {
            return;
        }

        // Store it in the map
        const new_image: Image = .{ .pending = pending.clone() };
        // Transfer the new reference into the map. No fallible work remains.

        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .image = new_image,
                .generation = 0,
            };
        } else {
            gop.value_ptr.image.markForReplace(alloc, new_image);
        }

        gop.value_ptr.generation = generation;
    }

    /// Prepare the provided Kitty image for GPU upload by cloning a shared
    /// reference to its current frame as pending state in the renderer.
    fn prepKittyImage(
        self: *State,
        alloc: Allocator,
        image: *const terminal.kitty.graphics.KittyImage,
    ) PrepImageError!void {
        const pixels = image.renderPixels() orelse return;
        const gop = try self.images.getOrPut(alloc, .{ .kitty = image.id });
        if (gop.found_existing and gop.value_ptr.generation == image.generation) {
            gop.value_ptr.image.cancelUnload();
            return;
        }
        const next: Image = .{ .pending = .{
            .width = image.width,
            .height = image.height,
            .format = switch (image.format) {
                .gray => .gray,
                .gray_alpha => .gray_alpha,
                .rgb => .rgb,
                .rgba => .rgba,
                .png => unreachable,
            },
            .pixels = pixels.clone(),
        } };
        if (gop.found_existing) {
            gop.value_ptr.image.markForReplace(alloc, next);
        } else {
            gop.value_ptr.* = .{ .image = next, .generation = 0 };
        }
        gop.value_ptr.generation =
            image.generation;
    }
};

/// Represents a single image placement on the grid.
/// A placement is a request to render an instance of an image.
pub const Placement = struct {
    /// The image being rendered. This MUST be in the image map.
    image_id: Id,

    /// The layer the placement is drawn in. Kitty placements are sorted
    /// by layer first and then by z-index. Overlays are always drawn
    /// above the text.
    layer: terminal.RenderState.ImageLayer,

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

/// Image identifier used to store and lookup images.
///
/// This is tagged by different image types to make it easier to
/// store different kinds of images in the same map without having
/// to worry about ID collisions.
pub const Id = union(enum) {
    /// Image sent to the terminal state via the kitty graphics protocol.
    /// The value is the ID assigned by the terminal.
    kitty: u32,

    /// Debug overlay. This is always composited down to a single
    /// image for now. In the future we can support layers here if we want.
    overlay,

    /// Z-ordering tie-breaker for images with the same z value.
    pub fn zLessThan(lhs: Id, rhs: Id) bool {
        // If our tags aren't the same, we sort by tag.
        if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) {
            return switch (lhs) {
                // Kitty images always sort before (lower z) non-kitty images.
                .kitty => true,

                .overlay => false,
            };
        }

        switch (lhs) {
            .kitty => |lhs_id| {
                const rhs_id = rhs.kitty;
                return lhs_id < rhs_id;
            },

            // No sensical ordering
            .overlay => return false,
        }
    }
};

/// The map used for storing images.
pub const ImageMap = std.AutoHashMapUnmanaged(Id, struct {
    image: Image,

    /// The generation of the terminal image this was created from
    /// (see terminal.kitty.graphics.KittyImage.generation). Used to detect
    /// staleness: a differing generation for the same ID means the
    /// contents changed and the texture must be replaced. Zero is
    /// never a valid stored generation so it marks "not yet uploaded".
    generation: u64,
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
        width: u32,
        height: u32,
        format: PixelFormat,
        pixels: *const ArcPixels,

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

        pub fn clone(self: Pending) Pending {
            var result = self;
            result.pixels = self.pixels.clone();
            return result;
        }

        pub fn deinit(self: Pending, alloc: Allocator) void {
            self.pixels.release(alloc);
        }
    };

    /// Convert layouts that can't be uploaded directly via the GraphicsAPI
    fn convertForUpload(alloc: Allocator, shared: Pending) wuffs.Error!Pending {
        const source = &shared;
        const rgba = try switch (source.format) {
            .gray => wuffs.swizzle.gToRgba(alloc, source.pixels.value),
            .gray_alpha => wuffs.swizzle.gaToRgba(alloc, source.pixels.value),
            .rgb => wuffs.swizzle.rgbToRgba(alloc, source.pixels.value),
            .bgr => wuffs.swizzle.bgrToRgba(alloc, source.pixels.value),
            .rgba, .bgra => unreachable, // both backends upload these directly
        };
        errdefer alloc.free(rgba);
        return .{
            .width = source.width,
            .height = source.height,
            .format = .rgba,
            .pixels = try ArcPixels.init(alloc, rgba),
        };
    }

    /// Prepare the pending image data for upload to the GPU by ensuring it
    /// is in an uploadable format. This is a no-op when the pixel data is
    /// in a native upload format, and a copy when we need to swizzle the pixels
    /// into RGBA layout.
    fn prepForUpload(self: *Image, alloc: Allocator) wuffs.Error!void {
        const pending = self.getPendingPointer().?;
        // Early return when the Image's format can be mapped to a
        // GraphicsAPI format.
        if (Texture.mapImageFormat(pending.*.format) != null) return;
        const converted = try convertForUpload(alloc, pending.*);
        pending.*.deinit(alloc);
        pending.* = converted;
    }

    pub fn deinit(self: Image, alloc: Allocator) void {
        switch (self) {
            .pending,
            .unload_pending,
            => |p| p.deinit(alloc),

            .replace, .unload_replace => |r| {
                r.pending.deinit(alloc);
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

    fn cancelUnload(self: *Image) void {
        self.* = switch (self.*) {
            .unload_pending => |p| .{ .pending = p },
            .unload_replace => |r| .{ .replace = r },
            .unload_ready => |t| .{ .ready = t },
            else => return,
        };
    }

    /// Mark the current image to be replaced with a pending one. This will
    /// attempt to update the existing texture if we have one, otherwise it
    /// will act like a new upload.
    pub fn markForReplace(self: *Image, alloc: Allocator, img: Image) void {
        assert(img.isPending());

        // If we have pending data right now, free it.
        if (self.getPending()) |p| {
            p.deinit(alloc);
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

    /// Upload the pending image to the GPU and change the state of this
    /// image to ready.
    pub fn upload(
        self: *Image,
        alloc: Allocator,
        api: *const GraphicsAPI,
    ) (wuffs.Error || error{
        /// Texture creation failed, usually a GPU memory issue.
        UploadFailed,
    })!void {
        assert(self.isPending());

        // Get our pending info
        const p = self.getPendingPointer().?;

        // This allocates a copy if the graphics API cannot upload the source format and needs
        // to convert between formats.
        try self.prepForUpload(alloc);

        // Create our texture
        const texture = Texture.init(
            api.imageTextureOptions(Texture.mapImageFormat(p.*.format).?, true),
            @intCast(p.*.width),
            @intCast(p.*.height),
            p.*.pixels.value,
        ) catch return error.UploadFailed;
        errdefer comptime unreachable;

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

test "kitty renderer ignores pending payloads and removes replaced placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    t.width_px = 30;
    t.height_px = 30;

    var state: State = .empty;
    defer state.deinit(alloc);
    var render_state: terminal.RenderState = .empty;
    defer render_state.deinit(alloc);

    const storage = &t.screens.active.kitty_images;
    const tracked = t.screens.active.pages.countTrackedPins();
    const pending = try storage.addPendingImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .pending = 4 },
    });
    const pin = try t.screens.active.pages.trackPin(
        t.screens.active.cursor.page_pin.*,
    );
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });

    try render_state.update(alloc, &t);
    state.kittyUpdate(alloc, &t, &render_state);
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqual(@as(usize, 0), state.kitty_placements.items.len);
    try testing.expect(state.images.get(.{ .kitty = 1 }) == null);

    const pixels = try alloc.dupe(u8, "rgba");
    try testing.expect(pending.complete(storage, io, alloc, pixels));
    try render_state.update(alloc, &t);
    state.kittyUpdate(alloc, &t, &render_state);
    try testing.expectEqual(@as(usize, 1), state.kitty_placements.items.len);
    try testing.expectEqual(
        storage.imageById(1).?.generation,
        state.images.get(.{ .kitty = 1 }).?.generation,
    );

    // A newer pending replacement deletes the native placement and marks the
    // copied texture data for unload.
    _ = try storage.addPendingImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .pending = 4 },
    });
    try render_state.update(alloc, &t);
    state.kittyUpdate(alloc, &t, &render_state);
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
    try testing.expectEqual(@as(usize, 0), state.kitty_placements.items.len);
    try testing.expect(state.images.get(.{ .kitty = 1 }).?.image.isUnloading());
}

test "kitty renderer uses the intersected source rectangle" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    t.width_px = 30;
    t.height_px = 30;

    var state: State = .empty;
    defer state.deinit(alloc);
    var render_state: terminal.RenderState = .empty;
    defer render_state.deinit(alloc);

    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 4 * 3 * 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 4,
        .height = 3,
        .format = .rgb,
        .data = .{ .ready = try ArcPixels.init(alloc, pixels) },
    });
    const pin = try t.screens.active.pages.trackPin(
        t.screens.active.cursor.page_pin.*,
    );
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .source_x = 3,
        .source_y = 1,
    });

    try render_state.update(alloc, &t);
    state.kittyUpdate(alloc, &t, &render_state);
    try testing.expectEqual(@as(usize, 1), state.kitty_placements.items.len);

    const placement = state.kitty_placements.items[0];
    try testing.expectEqual(@as(u32, 1), placement.width);
    try testing.expectEqual(@as(u32, 2), placement.height);
    try testing.expectEqual(@as(u32, 3), placement.source_x);
    try testing.expectEqual(@as(u32, 1), placement.source_y);
    try testing.expectEqual(@as(u32, 1), placement.source_width);
    try testing.expectEqual(@as(u32, 2), placement.source_height);
}

test "kitty renderer positions relative placements from the parent pin" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 10, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var state: State = .empty;
    defer state.deinit(alloc);
    var render_state: terminal.RenderState = .empty;
    defer render_state.deinit(alloc);

    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgb,
        .data = .{ .ready = try ArcPixels.init(alloc, pixels) },
    });

    // Parent at (2, 1).
    const pin = try t.screens.active.pages.trackPin(
        t.screens.active.pages.pin(.{ .active = .{ .x = 2, .y = 1 } }).?,
    );
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });

    // Child offset (3, 2) cells from the parent.
    try storage.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = 3,
            .vertical_offset = 2,
        } },
        .columns = 1,
        .rows = 1,
        .z = 1,
    });

    try render_state.update(alloc, &t);
    state.kittyUpdate(alloc, &t, &render_state);
    try testing.expectEqual(@as(usize, 2), state.kitty_placements.items.len);

    // Sorted by z: parent (z=0) first, child (z=1) second.
    const parent = state.kitty_placements.items[0];
    try testing.expectEqual(@as(i32, 2), parent.x);
    try testing.expectEqual(@as(i32, 1), parent.y);
    const child = state.kitty_placements.items[1];
    try testing.expectEqual(@as(i32, 5), child.x);
    try testing.expectEqual(@as(i32, 3), child.y);

    // The update stored the generations it was built from, so nothing
    // needs another update.
    try testing.expectEqual(render_state.imagePlacementsGeneration(), state.kitty_placements_generation);
    try testing.expectEqual(storage.generation, state.kitty_storage_generation);
    try testing.expect(!state.kittyRequiresUpdate(&t, &render_state));
}

test "kitty renderer relative placement with negative offsets" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 10, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var state: State = .empty;
    defer state.deinit(alloc);
    var render_state: terminal.RenderState = .empty;
    defer render_state.deinit(alloc);

    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgb,
        .data = .{ .ready = try ArcPixels.init(alloc, pixels) },
    });

    const pin = try t.screens.active.pages.trackPin(
        t.screens.active.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?,
    );
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });

    // Hangs up and to the left of the viewport but still has visible
    // cells at (0, 0), so it must be kept with a negative position.
    try storage.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = -3,
            .vertical_offset = -3,
        } },
        .columns = 2,
        .rows = 2,
        .z = 1,
    });

    // Entirely off the left edge of the screen: culled.
    try storage.addPlacement(io, alloc, t.screens.active, 1, 3, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = -9,
        } },
        .columns = 2,
        .rows = 2,
        .z = 2,
    });

    try render_state.update(alloc, &t);
    state.kittyUpdate(alloc, &t, &render_state);
    try testing.expectEqual(@as(usize, 2), state.kitty_placements.items.len);
    const child = state.kitty_placements.items[1];
    try testing.expectEqual(@as(i32, -1), child.x);
    try testing.expectEqual(@as(i32, -1), child.y);
}

test "kitty renderer positions relative placements from virtual parent placeholders" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.width_px = 50;
    t.height_px = 50;
    t.modes.set(.grapheme_cluster, true);

    var state: State = .empty;
    defer state.deinit(alloc);
    var render_state: terminal.RenderState = .empty;
    defer render_state.deinit(alloc);

    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 10 * 10 * 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
        .format = .rgb,
        .data = .{ .ready = try ArcPixels.init(alloc, pixels) },
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .virtual = {} },
    });

    // Placeholder cells for the virtual placement at (1, 1) and
    // (3, 2): the minimum cell (1, 1) is the anchor for relative
    // placements rooted at the virtual placement.
    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.setAttribute(.{ .@"256_underline_color" = 1 });
    t.screens.active.cursorAbsolute(1, 1);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    t.screens.active.cursorAbsolute(3, 2);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");

    // Child of the virtual placement, offset (1, 2) cells.
    try storage.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = 1,
            .vertical_offset = 2,
        } },
        .columns = 1,
        .rows = 1,
        .z = 5,
    });

    try render_state.update(alloc, &t);
    state.kittyUpdate(alloc, &t, &render_state);
    try testing.expectEqual(render_state.imagePlacementsGeneration(), state.kitty_placements_generation);
    try testing.expectEqual(storage.generation, state.kitty_storage_generation);

    // Two placeholder runs (z=-1) plus the child (z=5), sorted by z.
    try testing.expectEqual(@as(usize, 3), state.kitty_placements.items.len);
    const child = state.kitty_placements.items[2];
    try testing.expectEqual(@as(i32, 5), child.z);
    try testing.expectEqual(@as(i32, 2), child.x);
    try testing.expectEqual(@as(i32, 3), child.y);
}

test "kitty renderer skips updates for rows without placeholder cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.width_px = 50;
    t.height_px = 50;
    t.modes.set(.grapheme_cluster, true);

    var state: State = .empty;
    defer state.deinit(alloc);
    var render_state: terminal.RenderState = .empty;
    defer render_state.deinit(alloc);

    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 10 * 10 * 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
        .format = .rgb,
        .data = .{ .ready = try ArcPixels.init(alloc, pixels) },
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .virtual = {} },
    });
    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.setAttribute(.{ .@"256_underline_color" = 1 });
    t.screens.active.cursorAbsolute(1, 1);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    try t.setAttribute(.{ .unset = {} });

    try render_state.update(alloc, &t);
    try testing.expect(state.kittyRequiresUpdate(&t, &render_state));
    state.kittyUpdate(alloc, &t, &render_state);
    try testing.expectEqual(render_state.imagePlacementsGeneration(), state.kitty_placements_generation);
    try testing.expectEqual(storage.generation, state.kitty_storage_generation);
    try testing.expectEqual(@as(usize, 1), state.kitty_placements.items.len);

    // A row without placeholder cells changes. The render state is
    // dirty, but its placements are not.
    t.screens.active.pages.pin(.{ .active = .{ .y = 3 } }).?.markDirty();
    try render_state.update(alloc, &t);
    try testing.expect(render_state.dirty != .false);
    try testing.expect(!state.kittyRequiresUpdate(&t, &render_state));

    // Overwriting the placeholder cells removes the image.
    t.screens.active.cursorAbsolute(1, 1);
    try t.printString("x");
    try render_state.update(alloc, &t);
    try testing.expect(state.kittyRequiresUpdate(&t, &render_state));
    state.kittyUpdate(alloc, &t, &render_state);
    try testing.expectEqual(@as(usize, 0), state.kitty_placements.items.len);
}

test "kitty renderer skips updates for rows without placeholder cells with fixed placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.width_px = 50;
    t.height_px = 50;
    t.modes.set(.grapheme_cluster, true);

    var state: State = .empty;
    defer state.deinit(alloc);
    var render_state: terminal.RenderState = .empty;
    defer render_state.deinit(alloc);

    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 10 * 10 * 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
        .format = .rgb,
        .data = .{ .ready = try ArcPixels.init(alloc, pixels) },
    });

    // A virtual placement shown with placeholder cells on row 1, and a
    // fixed placement at (3, 0).
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .virtual = {} },
    });
    const pin = try t.screens.active.pages.trackPin(
        t.screens.active.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
    );
    try storage.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });
    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.setAttribute(.{ .@"256_underline_color" = 1 });
    t.screens.active.cursorAbsolute(1, 1);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    try t.setAttribute(.{ .unset = {} });

    try render_state.update(alloc, &t);
    try testing.expect(state.kittyRequiresUpdate(&t, &render_state));
    state.kittyUpdate(alloc, &t, &render_state);
    try testing.expectEqual(@as(usize, 2), state.kitty_placements.items.len);

    // A row without placeholder cells changes. The render state is
    // dirty, but neither placement is affected.
    t.screens.active.pages.pin(.{ .active = .{ .y = 3 } }).?.markDirty();
    try render_state.update(alloc, &t);
    try testing.expect(render_state.dirty != .false);
    try testing.expect(!state.kittyRequiresUpdate(&t, &render_state));
}

test "kitty renderer unloads the texture of a deleted image without placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    t.width_px = 30;
    t.height_px = 30;

    var state: State = .empty;
    defer state.deinit(alloc);
    var render_state: terminal.RenderState = .empty;
    defer render_state.deinit(alloc);

    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgb,
        .data = .{ .ready = try ArcPixels.init(alloc, pixels) },
    });
    const pin = try t.screens.active.pages.trackPin(
        t.screens.active.cursor.page_pin.*,
    );
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });
    try render_state.update(alloc, &t);
    state.kittyUpdate(alloc, &t, &render_state);
    try testing.expectEqual(@as(usize, 1), state.kitty_placements.items.len);

    // Delete the placement but keep the image. The texture stays.
    storage.delete(io, alloc, &t, .{ .id = .{ .image_id = 1, .placement_id = 1 } });
    try testing.expect(storage.imageById(1) != null);
    try render_state.update(alloc, &t);
    try testing.expect(state.kittyRequiresUpdate(&t, &render_state));
    state.kittyUpdate(alloc, &t, &render_state);
    try testing.expectEqual(@as(usize, 0), state.kitty_placements.items.len);
    try testing.expect(!state.images.get(.{ .kitty = 1 }).?.image.isUnloading());

    // Delete the image. The render state's placements don't change, but
    // the texture must still be unloaded.
    const placements_generation = render_state.imagePlacementsGeneration();
    storage.delete(io, alloc, &t, .{ .id = .{ .image_id = 1, .delete = true } });
    try testing.expect(storage.imageById(1) == null);
    try render_state.update(alloc, &t);
    try testing.expectEqual(placements_generation, render_state.imagePlacementsGeneration());
    try testing.expect(state.kittyRequiresUpdate(&t, &render_state));
    state.kittyUpdate(alloc, &t, &render_state);
    try testing.expect(state.images.get(.{ .kitty = 1 }).?.image.isUnloading());
    try testing.expect(!state.kittyRequiresUpdate(&t, &render_state));
}

test "kitty renderer uploads the current animation frame" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    t.width_px = 30;
    t.height_px = 30;

    var state: State = .empty;
    defer state.deinit(alloc);
    var render_state: terminal.RenderState = .empty;
    defer render_state.deinit(alloc);

    const storage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .ready = try ArcPixels.init(alloc, try alloc.dupe(u8, &.{ 255, 0, 0, 255 })) },
    });
    const pin = try t.screens.active.pages.trackPin(
        t.screens.active.cursor.page_pin.*,
    );
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });

    try render_state.update(alloc, &t);
    state.kittyUpdate(alloc, &t, &render_state);
    const gen1 = state.images.get(.{ .kitty = 1 }).?.generation;
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0, 255 },
        state.images.get(.{ .kitty = 1 }).?.image.pending.pixels.value,
    );

    // Attach an animation and make its extra frame current, the way
    // an animation tick would.
    const img = storage.images.getPtr(1).?;
    const anim = try alloc.create(terminal.kitty.graphics.Animation);
    anim.* = .{};
    img.animation = anim;
    try anim.frames.append(alloc, .{
        .data = try ArcPixels.init(alloc, try alloc.dupe(u8, &.{ 0, 0, 255, 255 })),
        .gap_ms = 40,
    });
    anim.current_index = 1;
    storage.markImageContentChanged(io, img);

    // The renderer must pick up the frame's pixels under a fresh
    // generation.
    try render_state.update(alloc, &t);
    state.kittyUpdate(alloc, &t, &render_state);
    const entry = state.images.get(.{ .kitty = 1 }).?;
    try testing.expect(entry.generation > gen1);
    try testing.expectEqual(anim.frames.items[0].data, entry.image.pending.pixels);
    try testing.expectEqualSlices(
        u8,
        &.{ 0, 0, 255, 255 },
        entry.image.pending.pixels.value,
    );
}

test "kitty renderer retains pixels and converts outside storage" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.dupe(u8, &.{ 1, 2 });
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .gray_alpha,
        .data = .{ .ready = try ArcPixels.init(alloc, pixels) },
    });
    const source = storage.imageById(1).?;
    const retained = source.renderPixels().?.clone();
    defer retained.release(alloc);
    var state: State = .empty;
    defer state.deinit(alloc);
    try state.prepKittyImage(alloc, &source);
    const entry = state.images.getPtr(.{ .kitty = 1 }).?;
    try testing.expectEqual(retained, entry.image.pending.pixels);
    try testing.expectEqual(pixels.ptr, entry.image.pending.pixels.value.ptr);
    const original = entry.image.pending.clone();
    defer original.deinit(alloc);
    // Removing storage cannot invalidate the pending upload.
    storage.setLimit(io, alloc, t.screens.active, 0);
    // Both the converted-pixel allocation and its control block can fail.
    for (0..2) |fail_index| {
        var failing_conversion = testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index });
        try testing.expectError(error.OutOfMemory, entry.image.prepForUpload(failing_conversion.allocator()));
        try testing.expectEqual(retained, entry.image.pending.pixels);
    }
    try entry.image.prepForUpload(alloc);
    try testing.expectEqual(Image.Pending.PixelFormat.rgba, entry.image.pending.format);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 2 }, entry.image.pending.pixels.value);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, retained.value);
    try testing.expectEqual(Image.Pending.PixelFormat.gray_alpha, original.format);
    try testing.expectEqual(@as(u32, 1), original.width);
    try testing.expectEqual(@as(u32, 1), original.height);
    try testing.expectEqual(retained, original.pixels);
    const converted = entry.image.pending.pixels;
    // Already-RGBA conversion requires no allocator and preserves identity.
    var failing = testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try entry.image.prepForUpload(failing.allocator());
    try testing.expect(!failing.has_induced_failure);
    try testing.expectEqual(converted, entry.image.pending.pixels);
}

test "kitty renderer releases pending replacement and canceled unload" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const first: Image.Pending = .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .pixels = try ArcPixels.init(alloc, try alloc.dupe(u8, "1234")),
    };
    defer first.deinit(alloc);
    var image: Image = .{ .pending = first.clone() };
    defer image.deinit(alloc);
    image.markForUnload();
    image.cancelUnload();
    try testing.expectEqual(first.pixels, image.pending.pixels);
    const second: Image.Pending = .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .pixels = try ArcPixels.init(alloc, try alloc.dupe(u8, "5678")),
    };
    image.markForReplace(alloc, .{ .pending = second });
    try testing.expectEqual(second.pixels, image.pending.pixels);
    try testing.expectEqualSlices(u8, "1234", first.pixels.value);
}

test "kitty renderer overlay snapshot survives drawing and teardown" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const snapshot = snapshot: {
        var overlay = try Overlay.init(alloc, .{
            .screen = .{ .width = 1, .height = 1 },
            .cell = .{ .width = 1, .height = 1 },
            .padding = .{},
        });
        defer overlay.deinit(alloc);
        overlay.surface.paintPixel(.{ .rgba = .{ .r = 255, .g = 0, .b = 0, .a = 255 } });
        for (0..2) |fail_index| {
            var failure = testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index });
            try testing.expectError(error.OutOfMemory, overlay.pendingImage(failure.allocator()));
        }
        const pending = try overlay.pendingImage(alloc);
        overlay.reset();
        break :snapshot pending;
    };
    defer snapshot.deinit(alloc);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, snapshot.pixels.value);
    var state: State = .empty;
    defer state.deinit(alloc);
    try state.prepImage(alloc, .overlay, 1, snapshot);
    try testing.expectEqual(snapshot.pixels, state.images.get(.overlay).?.image.pending.pixels);
}

test "kitty renderer uploads native formats without copying" {
    const testing = std.testing;
    const alloc = testing.allocator;
    for (std.enums.values(Image.Pending.PixelFormat)) |format| {
        if (Texture.mapImageFormat(format) == null) continue;
        const shared: Image.Pending = .{
            .width = 3,
            .height = 2,
            .format = format,
            .pixels = try ArcPixels.init(alloc, try alloc.alloc(u8, 3 * 2 * format.bpp())),
        };
        defer shared.deinit(alloc);
        var image: Image = .{ .pending = shared.clone() };
        defer image.deinit(alloc);
        var failing = testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
        try image.prepForUpload(failing.allocator());
        try testing.expect(!failing.has_induced_failure);
        try testing.expectEqual(shared.pixels, image.pending.pixels);
        try testing.expectEqual(shared.pixels.value.ptr, image.pending.pixels.value.ptr);
        try testing.expectEqual(format, image.pending.format);
    }
}

test "kitty renderer releases retained pixels after storage eviction" {
    const testing = std.testing;
    const io = testing.io;
    var tracked = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = tracked.allocator();
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
        defer t.deinit(alloc);
        const storage = &t.screens.active.kitty_images;
        const pending = try storage.addPendingImage(io, alloc, t.screens.active, .{
            .id = 1,
            .width = 1,
            .height = 1,
            .format = .gray_alpha,
            .data = .{ .pending = 2 },
        });
        const pixels = try alloc.dupe(u8, &.{ 1, 2 });
        if (!pending.complete(storage, io, alloc, pixels)) {
            alloc.free(pixels);
            return error.TestUnexpectedResult;
        }
        var state: State = .empty;
        defer state.deinit(alloc);
        const source = storage.imageById(1).?;
        try state.prepKittyImage(alloc, &source);
        storage.setLimit(io, alloc, t.screens.active, 0);
        const entry = state.images.getPtr(.{ .kitty = 1 }).?;
        try entry.image.prepForUpload(alloc);
        try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 2 }, entry.image.pending.pixels.value);
    }
    try testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
}

test "renderer pending image makeMut reuses unique pixels without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    const pixels = try alloc.dupe(u8, "rgba");
    var image: Image.Pending = .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .pixels = try ArcPixels.init(alloc, pixels),
    };
    defer image.deinit(alloc);
    const original = image.pixels;
    try std.testing.expectEqual(1, image.pixels.refs.load(.monotonic));
    const temporary = image.clone();
    try std.testing.expectEqual(2, image.pixels.refs.load(.monotonic));
    temporary.deinit(alloc);
    try std.testing.expectEqual(1, image.pixels.refs.load(.monotonic));
    failing.fail_index = failing.alloc_index;
    const mutable = try ArcPixels.makeMut(&image.pixels, alloc);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(1, image.pixels.refs.load(.monotonic));
    try std.testing.expectEqual(original, image.pixels);
    try std.testing.expectEqual(pixels.ptr, mutable.ptr);
    mutable.*[0] = 'R';
    const cloned = image.clone();
    try std.testing.expectEqual(2, image.pixels.refs.load(.monotonic));
    try std.testing.expectEqualSlices(u8, "Rgba", cloned.pixels.value);
    cloned.deinit(alloc);
    try std.testing.expectEqual(1, image.pixels.refs.load(.monotonic));
}

test "renderer pending image makeMut preserves other readers" {
    const alloc = std.testing.allocator;
    var image: Image.Pending = .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .pixels = try ArcPixels.init(alloc, try alloc.dupe(u8, "rgba")),
    };
    defer image.deinit(alloc);
    const retained = image.clone();
    defer retained.deinit(alloc);

    try std.testing.expectEqual(2, image.pixels.refs.load(.monotonic));
    const mutable = try ArcPixels.makeMut(&image.pixels, alloc);
    try std.testing.expect(image.pixels != retained.pixels);
    try std.testing.expect(mutable.ptr != retained.pixels.value.ptr);
    try std.testing.expectEqual(retained.width, image.width);
    try std.testing.expectEqual(retained.height, image.height);
    try std.testing.expectEqual(retained.format, image.format);
    try std.testing.expectEqualSlices(u8, "rgba", mutable.*);
    mutable.*[0] = 'R';
    try std.testing.expectEqualSlices(u8, "rgba", retained.pixels.value);
    try std.testing.expectEqualSlices(u8, "Rgba", image.pixels.value);
    try std.testing.expectEqual(1, retained.pixels.refs.load(.monotonic));
    try std.testing.expectEqual(1, image.pixels.refs.load(.monotonic));
}

test "renderer pending image makeMut allocation failure preserves shared ownership" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var image: Image.Pending = .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .pixels = try ArcPixels.init(alloc, try alloc.dupe(u8, "rgba")),
    };
    defer image.deinit(alloc);
    const retained = image.clone();
    defer retained.deinit(alloc);

    try std.testing.expectEqual(2, image.pixels.refs.load(.monotonic));
    // Fail both the pixel copy and the replacement control block allocation.
    for (0..2) |fail_index| {
        failing.fail_index = failing.alloc_index + fail_index;
        try std.testing.expectError(error.OutOfMemory, ArcPixels.makeMut(&image.pixels, alloc));
        try std.testing.expectEqual(retained.pixels, image.pixels);
        try std.testing.expectEqual(2, image.pixels.refs.load(.monotonic));
        try std.testing.expectEqualSlices(u8, "rgba", image.pixels.value);
    }
}

test "renderer pending image retains immutable pixels without copying" {
    const alloc = std.testing.allocator;
    const data = try alloc.dupe(u8, &.{ 1, 2, 3, 4 });
    const image: Image.Pending = .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .pixels = try ArcPixels.init(alloc, data),
    };
    try std.testing.expectEqual(1, image.pixels.refs.load(.monotonic));
    const retained = image.clone();
    try std.testing.expectEqual(2, retained.pixels.refs.load(.monotonic));
    image.deinit(alloc);
    defer retained.deinit(alloc);
    try std.testing.expectEqual(1, retained.pixels.refs.load(.monotonic));
    try std.testing.expectEqual(*const ArcPixels, @TypeOf(retained.pixels));
    try std.testing.expectEqual(data.ptr, retained.pixels.value.ptr);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, retained.pixels.value);
}
