const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const wuffs = @import("wuffs");
const terminal = @import("../terminal/main.zig");

const Renderer = @import("../renderer.zig").Renderer;
const GraphicsAPI = Renderer.API;
const Texture = GraphicsAPI.Texture;
const Overlay = @import("Overlay.zig");

const log = std.log.scoped(.renderer_image);

/// Generic image rendering state for the renderer. This stores all
/// images and their placements and exposes only a limited public API
/// for adding images and placements and drawing them.
pub const State = struct {
    /// The full image state for the renderer that specifies what images
    /// need to be uploaded, pruned, etc.
    images: ImageMap,

    /// The placements for the Kitty image protocol.
    kitty_placements: std.ArrayListUnmanaged(Placement),

    /// The end index (exclusive) for placements that should be
    /// drawn below the background, below the text, etc.
    kitty_bg_end: u32,
    kitty_text_end: u32,

    /// Overlays
    overlay_placements: std.ArrayListUnmanaged(Placement),

    pub const empty: State = .{
        .images = .empty,
        .kitty_placements = .empty,
        .kitty_bg_end = 0,
        .kitty_text_end = 0,
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
            const image = self.images.getPtr(p.image_id) orelse {
                log.warn("image not found for placement image_id={}", .{p.image_id});
                continue;
            };

            // Get the texture
            const texture = image.image.textureForDraw() orelse {
                log.warn("image not ready for placement image_id={}", .{p.image_id});
                continue;
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
        const generation = terminal.kitty.graphics.nextGeneration();

        // Ensure we have space for our overlay placement. Do this before
        // we upload our image so we don't have to deal with cleaning
        // that up.
        self.overlay_placements.clearRetainingCapacity();
        try self.overlay_placements.ensureUnusedCapacity(alloc, 1);

        // Setup our image.
        const pending = overlay.pendingImage();
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

    /// Update Kitty GPU state from the terminal-independent retained snapshot.
    pub fn kittyUpdate(
        self: *State,
        alloc: Allocator,
        state: *const terminal.RenderState,
    ) bool {
        const snapshot = &state.kitty;

        self.kitty_placements.ensureUnusedCapacity(alloc, snapshot.placements.items.len) catch {
            return false;
        };

        var cached = self.images.iterator();
        while (cached.next()) |entry| switch (entry.key_ptr.*) {
            .kitty => |id| if (!snapshot.images.contains(id)) entry.value_ptr.image.markForUnload(),
            .overlay => {},
        };

        var complete = true;
        for (snapshot.placements.items) |placement| {
            const image = snapshot.images.get(placement.image_id) orelse continue;
            self.prepKittyImageRetained(alloc, image) catch |err| {
                complete = false;
                log.warn("error preparing kitty image err={}", .{err});
            };
        }
        self.kitty_placements.clearRetainingCapacity();
        for (snapshot.placements.items) |p| self.kitty_placements.appendAssumeCapacity(.{
            .image_id = .{ .kitty = p.image_id },
            .x = p.x,
            .y = p.y,
            .z = p.z,
            .width = p.width,
            .height = p.height,
            .cell_offset_x = p.cell_offset_x,
            .cell_offset_y = p.cell_offset_y,
            .source_x = p.source_x,
            .source_y = p.source_y,
            .source_width = p.source_width,
            .source_height = p.source_height,
        });
        self.kitty_bg_end = snapshot.bg_end;
        self.kitty_text_end = snapshot.text_end;
        return complete;
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
        source: Image.Source,
    ) PrepImageError!void {
        // If this image exists and its generation is the same it is the
        // identical image so we don't need to send it to the GPU.
        const gop = try self.images.getOrPut(alloc, id);
        if (gop.found_existing and
            gop.value_ptr.generation == generation)
        {
            gop.value_ptr.image.cancelUnload();
            return;
        }

        // Copy the data so we own it.
        const data = if (alloc.dupe(
            u8,
            source.data,
        )) |v| v else |_| {
            if (!gop.found_existing) {
                // If this is a new entry we can just remove it since it
                // was never sent to the GPU.
                _ = self.images.remove(id);
            } else {
                // If this was an existing entry, it is invalid and
                // we must unload it.
                gop.value_ptr.image.markForUnload();
            }

            return error.OutOfMemory;
        };
        // Store it in the map
        var pending: Image.Pending = .{
            .width = source.width,
            .height = source.height,
            .pixel_format = source.pixel_format,
            .backing = .{ .renderer_owned = data },
        };
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .image = .{ .pending = pending.take() },
                .generation = 0,
            };
        } else {
            gop.value_ptr.image.markForReplace(
                alloc,
                &pending,
            );
        }
        gop.value_ptr.generation = generation;
    }

    fn prepKittyImageRetained(
        self: *State,
        alloc: Allocator,
        image: *const terminal.kitty.graphics.Image,
    ) PrepImageError!void {
        const id: Id = .{ .kitty = image.id };
        if (self.images.getPtr(id)) |entry| {
            if (entry.generation == image.generation) {
                entry.image.cancelUnload();
                return;
            }
        } else try self.images.ensureUnusedCapacity(alloc, 1);

        const retained = image.retain();
        var pending: Image.Pending = .{
            .width = image.width,
            .height = image.height,
            .pixel_format = switch (image.format) {
                .gray => .gray,
                .gray_alpha => .gray_alpha,
                .rgb => .rgb,
                .rgba => .rgba,
                .png => unreachable,
            },
            .backing = .{ .kitty_retained = retained },
        };
        const gop = self.images.getOrPutAssumeCapacity(id);
        if (gop.found_existing) gop.value_ptr.image.markForReplace(alloc, &pending) else gop.value_ptr.* = .{ .image = .{ .pending = pending.take() }, .generation = 0 };
        gop.value_ptr.generation = image.generation;
    }
};

/// Represents a single image placement on the grid.
/// A placement is a request to render an instance of an image.
pub const Placement = struct {
    /// The image being rendered. This MUST be in the image map.
    image_id: Id,

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
    /// (see terminal.kitty.graphics.Image.generation). Used to detect
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

    /// Non-owning source data used only while copying generic images into
    /// renderer-owned pending storage.
    pub const Source = struct {
        height: u32,
        width: u32,
        pixel_format: Pending.PixelFormat,
        data: []const u8,
    };

    /// Pending image data that needs to be uploaded to the GPU.
    pub const Pending = struct {
        height: u32,
        width: u32,
        pixel_format: PixelFormat,

        /// Explicit ownership of the immutable CPU bytes. Retained Kitty data
        /// must be released with the same allocator used by terminal storage.
        backing: Backing,

        pub const Backing = union(enum) {
            /// Moved-from sentinel. Live Pending values never use this.
            none,

            /// Mutable allocation owned by the renderer allocator.
            renderer_owned: []u8,

            /// Immutable terminal image held through the core retain API.
            kitty_retained: *terminal.kitty.graphics.Image,

            pub fn dataSlice(self: *const Backing) []const u8 {
                return switch (self.*) {
                    .none => &.{},
                    .renderer_owned => |data| data,
                    .kitty_retained => |retained| retained.data,
                };
            }

            pub fn deinit(self: *Backing, alloc: Allocator) void {
                switch (self.*) {
                    .none => {},
                    .renderer_owned => |data| alloc.free(data),
                    .kitty_retained => self.kitty_retained.release(),
                }
                self.* = .none;
            }

            pub fn isRetained(self: *const Backing) bool {
                return self.* == .kitty_retained;
            }
        };

        pub fn dataSlice(self: *const Pending) []const u8 {
            const data = self.backing.dataSlice();
            assert(data.len == self.len());
            return data;
        }

        pub fn len(self: *const Pending) usize {
            return self.width * self.height * self.pixel_format.bpp();
        }

        pub fn deinit(self: *Pending, alloc: Allocator) void {
            self.backing.deinit(alloc);
        }

        /// Explicitly move this ownership-bearing value and invalidate the
        /// source so only the returned Pending may release its backing.
        pub fn take(self: *Pending) Pending {
            const result = self.*;
            self.backing = .none;
            return result;
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

    pub fn deinit(self: *Image, alloc: Allocator) void {
        switch (self.*) {
            .pending => self.pending.deinit(alloc),
            .unload_pending => self.unload_pending.deinit(alloc),

            .replace => {
                self.replace.pending.deinit(alloc);
                self.replace.texture.deinit();
            },
            .unload_replace => {
                self.unload_replace.pending.deinit(alloc);
                self.unload_replace.texture.deinit();
            },

            .ready => self.ready.deinit(),
            .unload_ready => self.unload_ready.deinit(),
        }
        self.* = undefined;
    }

    /// Mark this image for unload whatever state it is in.
    pub fn markForUnload(self: *Image) void {
        switch (self.*) {
            .unload_pending,
            .unload_replace,
            .unload_ready,
            => return,

            .ready => {
                const texture = self.ready;
                self.* = .{ .unload_ready = texture };
            },
            .pending => {
                const pending = self.pending.take();
                self.* = .{ .unload_pending = pending };
            },
            .replace => {
                const texture = self.replace.texture;
                const pending = self.replace.pending.take();
                self.* = .{ .unload_replace = .{
                    .texture = texture,
                    .pending = pending,
                } };
            },
        }
    }

    /// Cancel a pending unload without changing or duplicating ownership.
    /// This is used when the same source generation becomes active again
    /// before the renderer processes its unload transition.
    fn cancelUnload(self: *Image) void {
        switch (self.*) {
            .pending,
            .replace,
            .ready,
            => {},

            .unload_pending => {
                const pending = self.unload_pending.take();
                self.* = .{ .pending = pending };
            },
            .unload_ready => {
                const texture = self.unload_ready;
                self.* = .{ .ready = texture };
            },
            .unload_replace => {
                const texture = self.unload_replace.texture;
                const pending = self.unload_replace.pending.take();
                self.* = .{ .replace = .{
                    .texture = texture,
                    .pending = pending,
                } };
            },
        }
    }

    /// Mark the current image to be replaced with a pending one. This will
    /// attempt to update the existing texture if we have one, otherwise it
    /// will act like a new upload.
    pub fn markForReplace(
        self: *Image,
        alloc: Allocator,
        pending: *Pending,
    ) void {
        const replacement = pending.take();
        switch (self.*) {
            .pending => {
                self.pending.deinit(alloc);
                self.* = .{ .pending = replacement };
            },
            .unload_pending => {
                self.unload_pending.deinit(alloc);
                self.* = .{ .pending = replacement };
            },
            .ready => {
                const texture = self.ready;
                self.* = .{ .replace = .{
                    .texture = texture,
                    .pending = replacement,
                } };
            },
            .unload_ready => {
                const texture = self.unload_ready;
                self.* = .{ .replace = .{
                    .texture = texture,
                    .pending = replacement,
                } };
            },
            .replace => {
                self.replace.pending.deinit(alloc);
                const texture = self.replace.texture;
                self.* = .{ .replace = .{
                    .texture = texture,
                    .pending = replacement,
                } };
            },
            .unload_replace => {
                self.unload_replace.pending.deinit(alloc);
                const texture = self.unload_replace.texture;
                self.* = .{ .replace = .{
                    .texture = texture,
                    .pending = replacement,
                } };
            },
        }
    }

    /// Returns true if this image is pending upload.
    pub fn isPending(self: *const Image) bool {
        return self.getPendingPointerConst() != null;
    }

    /// Returns true if this image has an associated texture.
    pub fn hasTexture(self: *const Image) bool {
        return switch (self.*) {
            .ready, .unload_ready, .replace, .unload_replace => true,
            .pending, .unload_pending => false,
        };
    }

    fn textureForDraw(self: *const Image) ?Texture {
        return switch (self.*) {
            .ready => self.ready,
            .unload_ready => self.unload_ready,
            else => null,
        };
    }

    /// Returns true if this image is marked for unload.
    pub fn isUnloading(self: *const Image) bool {
        return switch (self.*) {
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
    fn convert(self: *Image, alloc: Allocator) wuffs.Error!void {
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
        p.backing.deinit(alloc);
        p.backing = .{ .renderer_owned = rgba };
        p.pixel_format = .rgba;
    }

    /// Prepare the pending image data for upload to the GPU.
    /// This doesn't need GPU access so is safe to call any time.
    fn prepForUpload(self: *Image, alloc: Allocator) wuffs.Error!void {
        assert(self.isPending());
        try self.convert(alloc);
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

        // No error recover is required after this call because it just
        // converts in place and is idempotent.
        try self.prepForUpload(alloc);

        // Get our pending info
        const p = self.getPendingPointerConst().?;

        // Create our texture
        const texture = Texture.init(
            api.imageTextureOptions(.rgba, true),
            @intCast(p.width),
            @intCast(p.height),
            p.dataSlice(),
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

    fn getPendingPointerConst(self: *const Image) ?*const Pending {
        return switch (self.*) {
            .pending => &self.pending,
            .unload_pending => &self.unload_pending,

            .replace => &self.replace.pending,
            .unload_replace => &self.unload_replace.pending,

            else => null,
        };
    }
};

/// Test-only convenience for constructing and transferring a Kitty image.
fn addTestImage(
    storage: *terminal.kitty.graphics.ImageStorage,
    alloc: Allocator,
    init: terminal.kitty.graphics.Image.Init,
) Allocator.Error!void {
    const image = try terminal.kitty.graphics.Image.create(alloc, init);
    errdefer image.release();
    try storage.addImage(alloc, image);
}

test "renderer kitty snapshot transfers retained images without copying" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer term.deinit(alloc);
    term.width_px = 3;
    term.height_px = 3;
    const storage = &term.screens.active.kitty_images;
    try addTestImage(storage, alloc, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = try alloc.dupe(u8, &.{ 1, 2, 3, 4 }),
    });
    try addTestImage(storage, alloc, .{
        .id = 2,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = try alloc.dupe(u8, &.{ 5, 6, 7, 8 }),
    });
    const pin = try term.screens.active.pages.trackPin(
        term.screens.active.pages.pin(.{ .active = .{} }).?,
    );
    try storage.addPlacement(alloc, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });

    var render_state = terminal.RenderState.init(.{ .kitty_graphics = true });
    defer render_state.deinit(alloc);
    try render_state.update(alloc, &term);
    const snapshot_image = render_state.kitty.images.get(1).?;
    try testing.expectEqual(@as(usize, 2), snapshot_image.refs.load(.monotonic));

    var state: State = .empty;
    defer state.deinit(alloc);
    try testing.expect(state.kittyUpdate(alloc, &render_state));
    try testing.expect(state.images.getPtr(.{ .kitty = 2 }) == null);
    const pending = state.images.getPtr(.{ .kitty = 1 }).?.image.getPendingPointerConst().?;
    try testing.expectEqual(snapshot_image.data.ptr, pending.dataSlice().ptr);
    try testing.expectEqual(@as(usize, 3), snapshot_image.refs.load(.monotonic));

    try testing.expect(state.kittyUpdate(alloc, &render_state));
    try testing.expectEqual(@as(usize, 3), snapshot_image.refs.load(.monotonic));
}

test "renderer kitty prep retains payload without copy or duplicate retain" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer term.deinit(alloc);

    var storage: terminal.kitty.graphics.ImageStorage = .{};
    defer storage.deinit(alloc, term.screens.active);

    try addTestImage(&storage, alloc, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgb,
        .data = try alloc.dupe(u8, &.{ 1, 2, 3 }),
    });
    const borrowed = storage.imageById(1).?;

    var state: State = .empty;
    defer state.deinit(alloc);
    try state.prepKittyImageRetained(alloc, borrowed);

    const pending = state.images.getPtr(.{ .kitty = 1 }).?.image.getPendingPointerConst().?;
    try testing.expectEqual(borrowed.data.ptr, pending.dataSlice().ptr);
    const payload = pending.backing.kitty_retained;
    try testing.expectEqual(@as(usize, 2), payload.refs.load(.monotonic));

    var failing = testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try state.prepKittyImageRetained(failing.allocator(), borrowed);
    try testing.expect(!failing.has_induced_failure);
    try testing.expectEqual(@as(usize, 2), payload.refs.load(.monotonic));
}

test "renderer kitty same generation cancels pending unload without retaining again" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer term.deinit(alloc);

    var storage: terminal.kitty.graphics.ImageStorage = .{};
    defer storage.deinit(alloc, term.screens.active);

    try addTestImage(&storage, alloc, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = try alloc.dupe(u8, &.{ 1, 2, 3, 4 }),
    });
    const borrowed = storage.imageById(1).?;

    var state: State = .empty;
    defer state.deinit(alloc);
    try state.prepKittyImageRetained(alloc, borrowed);

    const renderer_image = &state.images.getPtr(.{ .kitty = 1 }).?.image;
    const pending_before = renderer_image.getPendingPointerConst().?;
    const data_ptr = pending_before.dataSlice().ptr;
    const payload = pending_before.backing.kitty_retained;
    renderer_image.markForUnload();
    try testing.expect(renderer_image.isUnloading());

    var failing = testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try state.prepKittyImageRetained(failing.allocator(), borrowed);
    try testing.expect(!failing.has_induced_failure);
    try testing.expect(!renderer_image.isUnloading());
    try testing.expect(renderer_image.isPending());
    try testing.expectEqual(
        data_ptr,
        renderer_image.getPendingPointerConst().?.dataSlice().ptr,
    );
    try testing.expectEqual(@as(usize, 2), payload.refs.load(.monotonic));
}

test "renderer kitty retained pending survives replacement and releases old payload" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer term.deinit(alloc);

    var storage: terminal.kitty.graphics.ImageStorage = .{};
    defer storage.deinit(alloc, term.screens.active);

    try addTestImage(&storage, alloc, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = try alloc.dupe(u8, &.{ 1, 2, 3, 4 }),
    });
    const original = storage.imageById(1).?;

    var state: State = .empty;
    defer state.deinit(alloc);
    try state.prepKittyImageRetained(alloc, original);
    const old_pending = state.images.getPtr(.{ .kitty = 1 }).?.image.getPendingPointerConst().?;
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, old_pending.dataSlice());
    const old_observer = original.retain();
    defer old_observer.release();
    const old_payload = old_observer;
    try testing.expectEqual(@as(usize, 3), old_payload.refs.load(.monotonic));

    try addTestImage(&storage, alloc, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = try alloc.dupe(u8, &.{ 5, 6, 7, 8 }),
    });
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, old_pending.dataSlice());
    try testing.expectEqual(@as(usize, 2), old_payload.refs.load(.monotonic));

    const replacement = storage.imageById(1).?;
    try state.prepKittyImageRetained(alloc, replacement);
    try testing.expectEqual(@as(usize, 1), old_payload.refs.load(.monotonic));
    const new_pending = state.images.getPtr(.{ .kitty = 1 }).?.image.getPendingPointerConst().?;
    try testing.expectEqual(replacement.data.ptr, new_pending.dataSlice().ptr);
    try testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8 }, new_pending.dataSlice());
}

test "renderer kitty retained pending survives deletion" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer term.deinit(alloc);

    var storage: terminal.kitty.graphics.ImageStorage = .{};
    defer storage.deinit(alloc, term.screens.active);

    try addTestImage(&storage, alloc, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = try alloc.dupe(u8, &.{ 1, 2, 3, 4 }),
    });
    const borrowed = storage.imageById(1).?;

    var state: State = .empty;
    defer state.deinit(alloc);
    try state.prepKittyImageRetained(alloc, borrowed);
    const pending = state.images.getPtr(.{ .kitty = 1 }).?.image.getPendingPointerConst().?;

    storage.delete(alloc, &term, .{ .id = .{ .image_id = 1, .delete = true } });
    try testing.expect(storage.imageById(1) == null);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, pending.dataSlice());
}

test "renderer kitty retained pending survives eviction" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer term.deinit(alloc);

    var storage: terminal.kitty.graphics.ImageStorage = .{ .total_limit = 4 };
    defer storage.deinit(alloc, term.screens.active);

    try addTestImage(&storage, alloc, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = try alloc.dupe(u8, &.{ 1, 2, 3, 4 }),
    });
    const borrowed = storage.imageById(1).?;

    var state: State = .empty;
    defer state.deinit(alloc);
    try state.prepKittyImageRetained(alloc, borrowed);
    const pending = state.images.getPtr(.{ .kitty = 1 }).?.image.getPendingPointerConst().?;

    try addTestImage(&storage, alloc, .{
        .id = 2,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = try alloc.dupe(u8, &.{ 5, 6, 7, 8 }),
    });
    try testing.expect(storage.imageById(1) == null);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, pending.dataSlice());
}

test "renderer kitty retained pending survives storage deinit" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer term.deinit(alloc);

    var storage: terminal.kitty.graphics.ImageStorage = .{};
    var storage_live = true;
    defer if (storage_live) storage.deinit(alloc, term.screens.active);

    try addTestImage(&storage, alloc, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = try alloc.dupe(u8, &.{ 1, 2, 3, 4 }),
    });
    const borrowed = storage.imageById(1).?;

    var state: State = .empty;
    defer state.deinit(alloc);
    try state.prepKittyImageRetained(alloc, borrowed);
    const pending = state.images.getPtr(.{ .kitty = 1 }).?.image.getPendingPointerConst().?;

    storage.deinit(alloc, term.screens.active);
    storage_live = false;
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, pending.dataSlice());
}

test "renderer kitty RGB conversion releases retained source" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer term.deinit(alloc);

    var storage: terminal.kitty.graphics.ImageStorage = .{};
    defer storage.deinit(alloc, term.screens.active);

    try addTestImage(&storage, alloc, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgb,
        .data = try alloc.dupe(u8, &.{ 1, 2, 3 }),
    });
    const borrowed = storage.imageById(1).?;

    var state: State = .empty;
    defer state.deinit(alloc);
    try state.prepKittyImageRetained(alloc, borrowed);

    const image = &state.images.getPtr(.{ .kitty = 1 }).?.image;
    const retained = image.getPendingPointerConst().?;
    const payload = retained.backing.kitty_retained;
    try testing.expectEqual(@as(usize, 2), payload.refs.load(.monotonic));

    try image.prepForUpload(alloc);
    const converted = image.getPendingPointerConst().?;
    try testing.expectEqual(Image.Pending.PixelFormat.rgba, converted.pixel_format);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, converted.dataSlice());
    try testing.expect(!converted.backing.isRetained());
    try testing.expectEqual(@as(usize, 1), payload.refs.load(.monotonic));
}

test "renderer kitty RGBA remains retained without an intermediate copy" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer term.deinit(alloc);

    var storage: terminal.kitty.graphics.ImageStorage = .{};
    defer storage.deinit(alloc, term.screens.active);

    try addTestImage(&storage, alloc, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = try alloc.dupe(u8, &.{ 1, 2, 3, 4 }),
    });
    const borrowed = storage.imageById(1).?;

    var state: State = .empty;
    try state.prepKittyImageRetained(alloc, borrowed);
    const image = &state.images.getPtr(.{ .kitty = 1 }).?.image;
    const payload = image.getPendingPointerConst().?.backing.kitty_retained;

    try image.prepForUpload(alloc);
    const pending = image.getPendingPointerConst().?;
    try testing.expect(pending.backing.isRetained());
    try testing.expectEqual(borrowed.data.ptr, pending.dataSlice().ptr);
    try testing.expectEqual(@as(usize, 2), payload.refs.load(.monotonic));

    state.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), payload.refs.load(.monotonic));
}

test "renderer deinit and pending unload release retained Kitty payloads" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer term.deinit(alloc);

    var storage: terminal.kitty.graphics.ImageStorage = .{};
    defer storage.deinit(alloc, term.screens.active);

    try addTestImage(&storage, alloc, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = try alloc.dupe(u8, &.{ 1, 2, 3, 4 }),
    });
    const borrowed = storage.imageById(1).?;

    var state: State = .empty;
    try state.prepKittyImageRetained(alloc, borrowed);
    const image = &state.images.getPtr(.{ .kitty = 1 }).?.image;
    const payload = image.getPendingPointerConst().?.backing.kitty_retained;
    image.markForUnload();
    try testing.expect(image.isUnloading());

    state.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), payload.refs.load(.monotonic));
}
