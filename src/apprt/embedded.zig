//! Application runtime for the embedded version of Ghostty. The embedded
//! version is when Ghostty is embedded within a parent host application,
//! rather than owning the application lifecycle itself. This is used for
//! example for the macOS build of Ghostty so that we can use a native
//! Swift+XCode-based application.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const apprt = @import("../apprt.zig");
const input = @import("../input.zig");
const CoreApp = @import("../App.zig");
const CoreSurface = @import("../Surface.zig");
const Config = @import("../config.zig").Config;

const log = std.log.scoped(.embedded_window);

pub const App = struct {
    /// Because we only expect the embedding API to be used in embedded
    /// environments, the options are extern so that we can expose it
    /// directly to a C callconv and not pay for any translation costs.
    ///
    /// C type: ghostty_runtime_config_s
    pub const Options = extern struct {
        /// These are just aliases to make the function signatures below
        /// more obvious what values will be sent.
        const AppUD = ?*anyopaque;
        const SurfaceUD = ?*anyopaque;

        /// Userdata that is passed to all the callbacks.
        userdata: AppUD = null,

        /// Callback called to wakeup the event loop. This should trigger
        /// a full tick of the app loop.
        wakeup: *const fn (AppUD) callconv(.C) void,

        /// Reload the configuration and return the new configuration.
        /// The old configuration can be freed immediately when this is
        /// called.
        reload_config: *const fn (AppUD) callconv(.C) ?*const Config,

        /// Called to set the title of the window.
        set_title: *const fn (SurfaceUD, [*]const u8) callconv(.C) void,

        /// Read the clipboard value. The return value must be preserved
        /// by the host until the next call. If there is no valid clipboard
        /// value then this should return null.
        read_clipboard: *const fn (SurfaceUD) callconv(.C) ?[*:0]const u8,

        /// Write the clipboard value.
        write_clipboard: *const fn (SurfaceUD, [*:0]const u8) callconv(.C) void,

        /// Create a new split view. If the embedder doesn't support split
        /// views then this can be null.
        new_split: ?*const fn (SurfaceUD, input.SplitDirection) callconv(.C) void = null,

        /// Close the current surface given by this function.
        close_surface: ?*const fn (SurfaceUD, bool) callconv(.C) void = null,

        /// Focus the previous/next split (if any).
        focus_split: ?*const fn (SurfaceUD, input.SplitFocusDirection) callconv(.C) void = null,
    };

    core_app: *CoreApp,
    config: *const Config,
    opts: Options,

    pub fn init(core_app: *CoreApp, config: *const Config, opts: Options) !App {
        return .{
            .core_app = core_app,
            .config = config,
            .opts = opts,
        };
    }

    pub fn terminate(self: App) void {
        _ = self;
    }

    pub fn reloadConfig(self: *App) !?*const Config {
        // Reload
        if (self.opts.reload_config(self.opts.userdata)) |new| {
            self.config = new;
            return self.config;
        }

        return null;
    }

    pub fn wakeup(self: App) void {
        self.opts.wakeup(self.opts.userdata);
    }

    pub fn wait(self: App) !void {
        _ = self;
    }

    /// Create a new surface for the app.
    fn newSurface(self: *App, opts: Surface.Options) !*Surface {
        // Grab a surface allocation because we're going to need it.
        var surface = try self.core_app.alloc.create(Surface);
        errdefer self.core_app.alloc.destroy(surface);

        // Create the surface -- because windows are surfaces for glfw.
        try surface.init(self, opts);
        errdefer surface.deinit();

        return surface;
    }

    /// Close the given surface.
    pub fn closeSurface(self: *App, surface: *Surface) void {
        surface.deinit();
        self.core_app.alloc.destroy(surface);
    }

    pub fn redrawSurface(self: *App, surface: *Surface) void {
        _ = self;
        _ = surface;
        // No-op, we use a threaded interface so we're constantly drawing.
    }
};

pub const Surface = struct {
    app: *App,
    nsview: objc.Object,
    core_surface: CoreSurface,
    content_scale: apprt.ContentScale,
    size: apprt.SurfaceSize,
    cursor_pos: apprt.CursorPos,
    opts: Options,

    pub const Options = extern struct {
        /// Userdata passed to some of the callbacks.
        userdata: ?*anyopaque = null,

        /// The pointer to the backing NSView for the surface.
        nsview: *anyopaque = undefined,

        /// The scale factor of the screen.
        scale_factor: f64 = 1,
    };

    pub fn init(self: *Surface, app: *App, opts: Options) !void {
        self.* = .{
            .app = app,
            .core_surface = undefined,
            .nsview = objc.Object.fromId(opts.nsview),
            .content_scale = .{
                .x = @floatCast(opts.scale_factor),
                .y = @floatCast(opts.scale_factor),
            },
            .size = .{ .width = 800, .height = 600 },
            .cursor_pos = .{ .x = 0, .y = 0 },
            .opts = opts,
        };

        // Add ourselves to the list of surfaces on the app.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Shallow copy the config so that we can modify it.
        var config = try apprt.surface.newConfig(app.core_app, app.config);
        defer config.deinit();

        // Initialize our surface right away. We're given a view that is
        // ready to use.
        try self.core_surface.init(
            app.core_app.alloc,
            &config,
            .{ .rt_app = app, .mailbox = &app.core_app.mailbox },
            self,
        );
        errdefer self.core_surface.deinit();
    }

    pub fn deinit(self: *Surface) void {
        // Remove ourselves from the list of known surfaces in the app.
        self.app.core_app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        self.core_surface.deinit();
    }

    pub fn newSplit(self: *const Surface, direction: input.SplitDirection) !void {
        const func = self.app.opts.new_split orelse {
            log.info("runtime embedder does not support splits", .{});
            return;
        };

        func(self.opts.userdata, direction);
    }

    pub fn close(self: *const Surface, process_alive: bool) void {
        const func = self.app.opts.close_surface orelse {
            log.info("runtime embedder does not support closing a surface", .{});
            return;
        };

        func(self.opts.userdata, process_alive);
    }

    pub fn gotoSplit(self: *const Surface, direction: input.SplitFocusDirection) void {
        const func = self.app.opts.focus_split orelse {
            log.info("runtime embedder does not support focus split", .{});
            return;
        };

        func(self.opts.userdata, direction);
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn setSizeLimits(self: *Surface, min: apprt.SurfaceSize, max_: ?apprt.SurfaceSize) !void {
        _ = self;
        _ = min;
        _ = max_;
    }

    pub fn setTitle(self: *Surface, slice: [:0]const u8) !void {
        self.app.opts.set_title(
            self.opts.userdata,
            slice.ptr,
        );
    }

    pub fn getClipboardString(self: *const Surface) ![:0]const u8 {
        const ptr = self.app.opts.read_clipboard(self.opts.userdata) orelse return "";
        return std.mem.sliceTo(ptr, 0);
    }

    pub fn setClipboardString(self: *const Surface, val: [:0]const u8) !void {
        self.app.opts.write_clipboard(self.opts.userdata, val.ptr);
    }

    pub fn setShouldClose(self: *Surface) void {
        _ = self;
    }

    pub fn shouldClose(self: *const Surface) bool {
        _ = self;
        return false;
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn refresh(self: *Surface) void {
        self.core_surface.refreshCallback() catch |err| {
            log.err("error in refresh callback err={}", .{err});
            return;
        };
    }

    pub fn updateContentScale(self: *Surface, x: f64, y: f64) void {
        self.content_scale = .{
            .x = @floatCast(x),
            .y = @floatCast(y),
        };
    }

    pub fn updateSize(self: *Surface, width: u32, height: u32) void {
        // Runtimes sometimes generate superflous resize events even
        // if the size did not actually change (SwiftUI). We check
        // that the size actually changed from what we last recorded
        // since resizes are expensive.
        if (self.size.width == width and self.size.height == height) return;

        self.size = .{
            .width = width,
            .height = height,
        };

        // Call the primary callback.
        self.core_surface.sizeCallback(self.size) catch |err| {
            log.err("error in size callback err={}", .{err});
            return;
        };
    }

    pub fn mouseButtonCallback(
        self: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) void {
        self.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
            log.err("error in mouse button callback err={}", .{err});
            return;
        };
    }

    pub fn scrollCallback(
        self: *Surface,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        self.core_surface.scrollCallback(xoff, yoff, mods) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return;
        };
    }

    pub fn cursorPosCallback(self: *Surface, x: f64, y: f64) void {
        // Convert our unscaled x/y to scaled.
        self.cursor_pos = self.cursorPosToPixels(.{
            .x = @floatCast(x),
            .y = @floatCast(y),
        }) catch |err| {
            log.err(
                "error converting cursor pos to scaled pixels in cursor pos callback err={}",
                .{err},
            );
            return;
        };

        self.core_surface.cursorPosCallback(self.cursor_pos) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }

    pub fn keyCallback(
        self: *Surface,
        action: input.Action,
        key: input.Key,
        unmapped_key: input.Key,
        mods: input.Mods,
    ) void {
        // log.warn("key action={} key={} mods={}", .{ action, key, mods });
        self.core_surface.keyCallback(action, key, unmapped_key, mods) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    pub fn charCallback(self: *Surface, cp_: u32) void {
        const cp = std.math.cast(u21, cp_) orelse return;
        self.core_surface.charCallback(cp) catch |err| {
            log.err("error in char callback err={}", .{err});
            return;
        };
    }

    pub fn focusCallback(self: *Surface, focused: bool) void {
        self.core_surface.focusCallback(focused) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    /// The cursor position from the host directly is in screen coordinates but
    /// all our interface works in pixels.
    fn cursorPosToPixels(self: *const Surface, pos: apprt.CursorPos) !apprt.CursorPos {
        const scale = try self.getContentScale();
        return .{ .x = pos.x * scale.x, .y = pos.y * scale.y };
    }
};

// C API
pub const CAPI = struct {
    const global = &@import("../main.zig").state;

    /// Create a new app.
    export fn ghostty_app_new(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) ?*App {
        return app_new_(opts, config) catch |err| {
            log.err("error initializing app err={}", .{err});
            return null;
        };
    }

    fn app_new_(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) !*App {
        var core_app = try CoreApp.create(global.alloc);
        errdefer core_app.destroy();

        // Create our runtime app
        var app = try global.alloc.create(App);
        errdefer global.alloc.destroy(app);
        app.* = try App.init(core_app, config, opts.*);
        errdefer app.terminate();

        return app;
    }

    /// Tick the event loop. This should be called whenever the "wakeup"
    /// callback is invoked for the runtime.
    export fn ghostty_app_tick(v: *App) bool {
        return v.core_app.tick(v) catch |err| err: {
            log.err("error app tick err={}", .{err});
            break :err false;
        };
    }

    /// Return the userdata associated with the app.
    export fn ghostty_app_userdata(v: *App) ?*anyopaque {
        return v.opts.userdata;
    }

    export fn ghostty_app_free(v: *App) void {
        const core_app = v.core_app;
        v.terminate();
        global.alloc.destroy(v);
        core_app.destroy();
    }

    /// Create a new surface as part of an app.
    export fn ghostty_surface_new(
        app: *App,
        opts: *const apprt.Surface.Options,
    ) ?*Surface {
        return surface_new_(app, opts) catch |err| {
            log.err("error initializing surface err={}", .{err});
            return null;
        };
    }

    fn surface_new_(
        app: *App,
        opts: *const apprt.Surface.Options,
    ) !*Surface {
        return try app.newSurface(opts.*);
    }

    export fn ghostty_surface_free(ptr: *Surface) void {
        ptr.app.closeSurface(ptr);
    }

    /// Returns the app associated with a surface.
    export fn ghostty_surface_app(surface: *Surface) *App {
        return surface.app;
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_refresh(surface: *Surface) void {
        surface.refresh();
    }

    /// Update the size of a surface. This will trigger resize notifications
    /// to the pty and the renderer.
    export fn ghostty_surface_set_size(surface: *Surface, w: u32, h: u32) void {
        surface.updateSize(w, h);
    }

    /// Update the content scale of the surface.
    export fn ghostty_surface_set_content_scale(surface: *Surface, x: f64, y: f64) void {
        surface.updateContentScale(x, y);
    }

    /// Update the focused state of a surface.
    export fn ghostty_surface_set_focus(surface: *Surface, focused: bool) void {
        surface.focusCallback(focused);
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_key(
        surface: *Surface,
        action: input.Action,
        key: input.Key,
        unmapped_key: input.Key,
        mods: c_int,
    ) void {
        surface.keyCallback(
            action,
            key,
            unmapped_key,
            @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(mods))))),
        );
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_char(surface: *Surface, codepoint: u32) void {
        surface.charCallback(codepoint);
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_mouse_button(
        surface: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: c_int,
    ) void {
        surface.mouseButtonCallback(
            action,
            button,
            @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(mods))))),
        );
    }

    /// Update the mouse position within the view.
    export fn ghostty_surface_mouse_pos(surface: *Surface, x: f64, y: f64) void {
        surface.cursorPosCallback(x, y);
    }

    export fn ghostty_surface_mouse_scroll(
        surface: *Surface,
        x: f64,
        y: f64,
        scroll_mods: c_int,
    ) void {
        surface.scrollCallback(
            x,
            y,
            @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(scroll_mods))))),
        );
    }

    export fn ghostty_surface_ime_point(surface: *Surface, x: *f64, y: *f64) void {
        const pos = surface.core_surface.imePoint();
        x.* = pos.x;
        y.* = pos.y;
    }

    /// Request that the surface become closed. This will go through the
    /// normal trigger process that a close surface input binding would.
    export fn ghostty_surface_request_close(ptr: *Surface) void {
        ptr.core_surface.close();
    }

    /// Request that the surface split in the given direction.
    export fn ghostty_surface_split(ptr: *Surface, direction: input.SplitDirection) void {
        ptr.newSplit(direction) catch {};
    }

    /// Focus on the next split (if any).
    export fn ghostty_surface_split_focus(ptr: *Surface, direction: input.SplitFocusDirection) void {
        ptr.gotoSplit(direction);
    }
};
