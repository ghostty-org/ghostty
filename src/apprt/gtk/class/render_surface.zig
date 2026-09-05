const std = @import("std");

const glib = @import("glib");
const gobject = @import("gobject");
const gdk = @import("gdk");
const gtk = @import("gtk");

const global = @import("../../../global.zig");
const Application = @import("application.zig").Application;
const Common = @import("../class.zig").Common;
const CoreSurface = @import("../../../Surface.zig");
const rendererpkg = @import("../../../renderer.zig");
const ExportedFrame = rendererpkg.Renderer.ExportedFrame;
const Dmabuf = @import("../../../renderer/Dmabuf.zig");
const Planes = Dmabuf.Planes;

const log = std.log.scoped(.gtk_render_surface);

/// A widget that displays the rendered output of the Ghostty renderer.
///
/// In the past, Ghostty relied on GTK's builtin `GLArea` to display the
/// rendered output within the GTK-based UI, but this had numerous
/// debilitating limitations.
///
/// Its most significant limitation is that GTK's render lifecycle lives
/// **exclusively on the main UI thread**, from initialization to drawing the
/// rendered framebuffers. This is not only inefficient but also error-prone,
/// as we offload our render work to a dedicated render thread which has
/// to be careful not to access the renderer at the same time as the main
/// thread. Initialization is also far more complex as we had to wait for
/// GTK's OpenGL context to initialize, then we can proceed with initializing
/// the renderer and then the core surface. (The GTK surface widget could not
/// assume it always has a valid core surface, which is obviously absurd!)
/// It was a messy, chicken-and-egg relationship that held us back a lot.
///
/// With our custom `RenderSurface`, the renderer instead renders frames,
/// exports them into DMABUFs, then pushes them into a queue that this widget
/// can consume at its own pace on the main thread, whenever GTK calls for it
/// to be snapshotted. This also allowed us to do triple-buffering and should
/// greatly reduce tearing. Initialization is done on the render thread and
/// always completes before the core surface is created. Furthermore, this
/// surface is actually OpenGL-agnostic, since it operates exclusively on
/// DMABUFs which can also be produced by other graphics APIs like Vulkan.
pub const RenderSurface = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyRenderSurface",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const C = Common(Self, Private);

    pub const Private = struct {
        /// The core surface, used to pull presents from the renderer.
        /// Set by the apprt Surface when it realizes the render surface.
        core_surface: ?*CoreSurface = null,

        /// The GDK Texture currently being displayed.
        texture: ?*gdk.Texture = null,

        pub var offset: c_int = 0;
    };

    const private = C.private;
    pub const as = C.as;

    pub const signals = struct {
        pub const resize = struct {
            pub const name = "resize";
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{ c_int, c_int },
                void,
            );
        };
    };

    //---------------------------------------------------------------
    // Virtual methods

    fn realize(self: *Self) callconv(.c) void {
        // Call the parent realize.
        gtk.Widget.virtual_methods.realize.call(
            Class.parent,
            self.as(gtk.Widget),
        );

        // Request a draw in case frames were produced before we
        // realized. The snapshot will pull from the renderer's queue.
        self.as(gtk.Widget).queueDraw();
    }

    fn unrealize(self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.texture) |tex| {
            tex.as(gobject.Object).unref();
            priv.texture = null;
        }

        gtk.Widget.virtual_methods.unrealize.call(
            Class.parent,
            self.as(gtk.Widget),
        );
    }

    fn sizeAllocate(
        self: *Self,
        width: c_int,
        height: c_int,
        baseline: c_int,
    ) callconv(.c) void {
        const scale = self.as(gtk.Widget).getScaleFactor();
        const device_width = width * scale;
        const device_height = height * scale;

        // Emit resize so the surface's renderSurfaceResize callback
        // forwards size updates to the core surface/renderer. We emit
        // device pixels (width*scale) so that the renderer's size matches
        // what `surfaceSize` reports and what the render target is
        // allocated at.
        signals.resize.impl.emit(self, null, .{ device_width, device_height }, null);

        gtk.Widget.virtual_methods.size_allocate.call(
            Class.parent,
            self.as(gtk.Widget),
            width,
            height,
            baseline,
        );
    }

    fn snapshot(self: *Self, snap: *gtk.Snapshot) callconv(.c) void {
        const priv = self.private();

        // Take the latest present from the renderer's queue, if any, and
        // build a texture from it. `take` closes any present that was
        // still unconsumed in the queue, but not the texture we're
        // currently displaying.
        if (priv.core_surface) |core| {
            if (core.renderer.takeFrame()) |frame| {
                self.rebuildTexture(frame) catch |err| {
                    log.warn("error building texture from frame err={}", .{err});
                };
            }
        }

        // If we have a texture, draw it.
        const texture = priv.texture orelse return;

        const widget = self.as(gtk.Widget);
        const w = widget.getWidth();
        const h = widget.getHeight();
        if (w == 0 or h == 0) return;

        // In OpenGL +Y is up but in GSK (and DirectX, Metal, Vulkan, etc.)
        // +Y is down. We therefore might need to flip the rendered image.
        snap.save();
        defer snap.restore();
        if (comptime !rendererpkg.Renderer.API.custom_shader_y_is_down) {
            snap.translate(&.{ .f_x = 0, .f_y = @floatFromInt(h) });
            snap.scale(1, -1);
        }

        snap.appendTexture(texture, &.{
            .f_origin = .{ .f_x = 0, .f_y = 0 },
            .f_size = .{ .f_width = @floatFromInt(w), .f_height = @floatFromInt(h) },
        });
    }

    //---------------------------------------------------------------
    // Presenting

    /// Return the size of this surface in device pixels. Used by the
    /// apprt surface to report the size to the renderer.
    pub fn deviceSize(self: *Self) struct { width: u32, height: u32 } {
        const scale = @max(self.as(gtk.Widget).getScaleFactor(), 1);
        const width = self.as(gtk.Widget).getWidth();
        const height = self.as(gtk.Widget).getHeight();

        return .{
            .width = @intCast(@max(width * scale, 0)),
            .height = @intCast(@max(height * scale, 0)),
        };
    }

    /// Set the core surface to pull presents from. Nothing will
    /// render when this is unset.
    pub fn setCoreSurface(self: *Self, core: ?*CoreSurface) void {
        self.private().core_surface = core;
    }

    /// Build a `GdkTexture` from the present and set it as our current
    /// texture, unrefing any previous texture.
    fn rebuildTexture(self: *Self, frame: ExportedFrame) !void {
        switch (frame) {
            .dmabuf => |dmabuf| try self.rebuildDmabufTexture(dmabuf),
            .memory => |memory| try self.rebuildMemoryTexture(memory),
        }
    }

    /// Build a `GdkDmabufTexture` from the present and set it as our
    /// current texture, unrefing any previous texture.
    fn rebuildDmabufTexture(self: *Self, frame: Dmabuf) !void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);
        const display = widget.getDisplay();

        const builder = gdk.DmabufTextureBuilder.new();
        defer builder.unref();

        builder.setDisplay(display);
        builder.setWidth(frame.width);
        builder.setHeight(frame.height);
        builder.setFourcc(frame.fourcc);
        builder.setModifier(frame.modifier);
        builder.setPremultiplied(@intFromBool(frame.premultiplied));
        builder.setNPlanes(@intCast(frame.planes.count));

        for (0..frame.planes.count) |i| {
            builder.setFd(@intCast(i), frame.planes.fds[i]);
            builder.setOffset(@intCast(i), @intCast(frame.planes.offsets[i]));
            builder.setStride(@intCast(i), @intCast(frame.planes.strides[i]));
        }

        // Build the texture. We retain ownership over the DMABUF FDs
        // until the asynchronous texture building process is complete,
        // so we have to make a heap copy of them, send them to GTK,
        // and then destroy them once successful.
        const app = Application.default();
        const alloc = app.allocator();

        const planes = try alloc.create(Planes);
        errdefer alloc.destroy(planes);

        planes.* = frame.planes;
        errdefer planes.deinit();

        var err_: ?*glib.Error = null;
        const texture = builder.build(
            dmabufDestroy,
            planes,
            &err_,
        ) orelse {
            if (err_) |err|
                log.warn("failed to build dmabuf err={s}", .{err.f_message orelse "(unknown)"});
            return error.DmabufBuildFailed;
        };

        // Swap out the old texture.
        if (priv.texture) |old| old.as(gobject.Object).unref();
        priv.texture = texture;
    }

    /// Destroy callback for `GdkDmabufTexture`. GDK calls this when the
    /// texture is released; we close the FDs and free the holder.
    fn dmabufDestroy(data: ?*anyopaque) callconv(.c) void {
        const app = Application.default();
        const alloc = app.allocator();

        const planes: *Planes = @ptrCast(@alignCast(data orelse return));
        planes.deinit();
        alloc.destroy(planes);
    }

    /// Holder for the pixel data backing a `GdkMemoryTexture`. GTK
    /// ref-counts the `GBytes` we hand it and calls `memoryDestroy`
    /// when it no longer needs the data, at which point we can return
    /// the pixels to the allocator.
    const MemoryHolder = struct {
        alloc: std.mem.Allocator,
        pixels: []u8,
    };

    /// Build a `GdkMemoryTexture` from a CPU memory frame and set it as
    /// our current texture, unrefing any previous texture. This is the
    /// fallback path for drivers that can't export DMA-BUFs.
    fn rebuildMemoryTexture(self: *Self, frame: ExportedFrame.Memory) !void {
        const priv = self.private();

        const app = Application.default();
        const alloc = app.allocator();

        const holder = alloc.create(MemoryHolder) catch |err| {
            // We own the pixels; make sure they don't leak.
            frame.deinit();
            return err;
        };
        errdefer alloc.destroy(holder);
        holder.* = .{ .alloc = alloc, .pixels = frame.pixels };

        // `GdkMemoryTexture` keeps a reference to the `GBytes` for as
        // long as it needs the pixel data, so we hand it our holder and
        // get the pixels freed via the destroy notify below.
        const bytes = glib.Bytes.newWithFreeFunc(
            holder.pixels.ptr,
            holder.pixels.len,
            &memoryDestroy,
            holder,
        );
        errdefer bytes.unref();

        const texture = gdk.MemoryTexture.new(
            @intCast(frame.width),
            @intCast(frame.height),
            .r8g8b8a8_premultiplied,
            bytes,
            frame.width * 4, // stride
        );

        // The texture holds its own reference to the bytes now.
        bytes.unref();

        // Swap out the old texture.
        if (priv.texture) |old| old.as(gobject.Object).unref();
        priv.texture = texture.as(gdk.Texture);
    }

    /// Destroy callback for the `GBytes` backing a `GdkMemoryTexture`.
    fn memoryDestroy(data: ?*anyopaque) callconv(.c) void {
        const holder: *MemoryHolder = @ptrCast(@alignCast(data orelse return));
        holder.alloc.free(holder.pixels);
        holder.alloc.destroy(holder);
    }

    //---------------------------------------------------------------
    // Class

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            // Virtual methods
            gtk.Widget.virtual_methods.realize.implement(class, &realize);
            gtk.Widget.virtual_methods.unrealize.implement(class, &unrealize);
            gtk.Widget.virtual_methods.size_allocate.implement(class, &sizeAllocate);
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);

            // Signals
            signals.resize.impl.register(.{});
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
