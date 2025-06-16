//! Application runtime implementation that uses GLFW (https://www.glfw.org/).
//!
//! This works on macOS and Linux with OpenGL and Metal.
//! (The above sentence may be out of date).

const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const glfw = @import("glfw");
const macos = @import("macos");
const objc = @import("objc");
const cli = @import("../cli.zig");
const input = @import("../input.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const Renderer = renderer.Renderer;
const apprt = @import("../apprt.zig");
const CoreApp = @import("../App.zig");
const CoreSurface = @import("../Surface.zig");
const configpkg = @import("../config.zig");
const Config = @import("../config.zig").Config;

// Get native API access on certain platforms so we can do more customization.
const glfwNative = glfw.Native(.{
    .cocoa = builtin.target.os.tag.isDarwin(),
    .x11 = builtin.os.tag == .linux,
});

/// True if darwin-specific logic is enabled
const darwin_enabled = builtin.target.os.tag.isDarwin() and
    build_config.artifact == .exe;

const log = std.log.scoped(.glfw);

pub const App = struct {
    app: *CoreApp,
    config: Config,

    /// Flips to true to quit on the next event loop tick. This
    /// never goes false and forces the event loop to exit.
    quit: bool = false,

    /// Mac-specific state.
    darwin: if (darwin_enabled) Darwin else void,

    pub const Options = struct {};

    pub fn init(core_app: *CoreApp, _: Options) !App {
        if (comptime builtin.target.os.tag.isDarwin()) {
            log.warn("WARNING WARNING WARNING: GLFW ON MAC HAS BUGS.", .{});
            log.warn("You should use the AppKit-based app instead. The official download", .{});
            log.warn("is properly built and available from GitHub. If you're building from", .{});
            log.warn("source, see the README for details on how to build the AppKit app.", .{});
        }

        if (!glfw.init(.{})) {
            if (glfw.getError()) |err| {
                log.err("error initializing GLFW err={} msg={s}", .{
                    err.error_code,
                    err.description,
                });
                return err.error_code;
            }

            return error.GlfwInitFailedUnknownReason;
        }
        glfw.setErrorCallback(glfwErrorCallback);

        // Mac-specific state. For example, on Mac we enable window tabbing.
        var darwin = if (darwin_enabled) try Darwin.init() else {};
        errdefer if (darwin_enabled) darwin.deinit();

        // Load our configuration
        var config = try Config.load(core_app.alloc);
        errdefer config.deinit();

        // If we had configuration errors, then log them.
        if (!config._diagnostics.empty()) {
            var buf = std.ArrayList(u8).init(core_app.alloc);
            defer buf.deinit();
            for (config._diagnostics.items()) |diag| {
                try diag.write(buf.writer());
                log.warn("configuration error: {s}", .{buf.items});
                buf.clearRetainingCapacity();
            }

            // If we have any CLI errors, exit.
            if (config._diagnostics.containsLocation(.cli)) {
                log.warn("CLI errors detected, exiting", .{});
                _ = core_app.mailbox.push(.{
                    .quit = {},
                }, .{ .forever = {} });
            }
        }

        // Queue a single new window that starts on launch
        // Note: above we may send a quit so this may never happen
        _ = core_app.mailbox.push(.{
            .new_window = .{},
        }, .{ .forever = {} });

        // We want the event loop to wake up instantly so we can process our tick.
        glfw.postEmptyEvent();

        return .{
            .app = core_app,
            .config = config,
            .darwin = darwin,
        };
    }

    pub fn terminate(self: *App) void {
        self.config.deinit();
        glfw.terminate();
    }

    /// Run the event loop. This doesn't return until the app exits.
    pub fn run(self: *App) !void {
        while (true) {
            // Wait for any events from the app event loop. wakeup will post
            // an empty event so that this will return.
            //
            // Warning: a known issue on macOS is that this will block while
            // a resize event is actively happening, which will prevent the
            // app tick from happening. I don't know know a way around this
            // but its not a big deal since we don't use glfw for the official
            // mac app, but noting it in case anyone builds for macos using
            // glfw.
            glfw.waitEvents();

            // Tick the terminal app
            try self.app.tick(self);

            // If the tick caused us to quit, then we're done.
            if (self.quit or self.app.surfaces.items.len == 0) {
                for (self.app.surfaces.items) |surface| {
                    surface.close(false);
                }

                return;
            }
        }
    }

    /// Wakeup the event loop. This should be able to be called from any thread.
    pub fn wakeup(self: *const App) void {
        _ = self;
        glfw.postEmptyEvent();
    }

    /// Perform a given action. Returns `true` if the action was able to be
    /// performed, `false` otherwise.
    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        switch (action) {
            .quit => self.quit = true,

            .new_window => _ = try self.newSurface(switch (target) {
                .app => null,
                .surface => |v| v,
            }),

            .new_tab => try self.newTab(switch (target) {
                .app => null,
                .surface => |v| v,
            }),

            .size_limit => switch (target) {
                .app => {},
                .surface => |surface| try surface.rt_surface.setSizeLimits(.{
                    .width = value.min_width,
                    .height = value.min_height,
                }, if (value.max_width > 0) .{
                    .width = value.max_width,
                    .height = value.max_height,
                } else null),
            },

            .initial_size => switch (target) {
                .app => {},
                .surface => |surface| try surface.rt_surface.setInitialWindowSize(
                    value.width,
                    value.height,
                ),
            },

            .toggle_fullscreen => self.toggleFullscreen(target),

            .open_config => try configpkg.edit.open(self.app.alloc),

            .set_title => switch (target) {
                .app => {},
                .surface => |surface| try surface.rt_surface.setTitle(value.title),
            },

            .mouse_shape => switch (target) {
                .app => {},
                .surface => |surface| try surface.rt_surface.setMouseShape(value),
            },

            .mouse_visibility => switch (target) {
                .app => {},
                .surface => |surface| surface.rt_surface.setMouseVisibility(switch (value) {
                    .visible => true,
                    .hidden => false,
                }),
            },

            .reload_config => try self.reloadConfig(target, value),

            // Unimplemented
            .new_split,
            .goto_split,
            .resize_split,
            .equalize_splits,
            .toggle_split_zoom,
            .present_terminal,
            .close_all_windows,
            .close_window,
            .close_tab,
            .toggle_tab_overview,
            .toggle_tab_icons,
            .toggle_window_decorations,
            .toggle_quick_terminal,
            .toggle_command_palette,
            .toggle_visibility,
            .goto_tab,
            .move_tab,
            .inspector,
            .render_inspector,
            .quit_timer,
            .float_window,
            .secure_input,
            .key_sequence,
            .desktop_notification,
            .mouse_over_link,
            .cell_size,
            .renderer_health,
            .color_change,
            .pwd,
            .config_change,
            .toggle_maximize,
            .prompt_title,
            .reset_window_size,
            .ring_bell,
            .check_for_updates,
            .undo,
            .redo,
            .show_gtk_inspector,
            => {
                log.info("unimplemented action={}", .{action});
                return false;
            },
        }

        return true;
    }

    /// Reload the configuration. This should return the new configuration.
    /// The old value can be freed immediately at this point assuming a
    /// successful return.
    ///
    /// The returned pointer value is only valid for a stable self pointer.
    fn reloadConfig(
        self: *App,
        target: apprt.action.Target,
        opts: apprt.action.ReloadConfig,
    ) !void {
        if (opts.soft) {
            switch (target) {
                .app => try self.app.updateConfig(self, &self.config),
                .surface => |core_surface| try core_surface.updateConfig(
                    &self.config,
                ),
            }
            return;
        }

        // Load our configuration
        var config = try Config.load(self.app.alloc);
        errdefer config.deinit();

        // Call into our app to update
        switch (target) {
            .app => try self.app.updateConfig(self, &config),
            .surface => |core_surface| try core_surface.updateConfig(&config),
        }

        // Update the existing config, be sure to clean up the old one.
        self.config.deinit();
        self.config = config;
    }

    /// Toggle the window to fullscreen mode.
    fn toggleFullscreen(self: *App, target: apprt.Target) void {
        _ = self;
        const surface: *Surface = switch (target) {
            .app => return,
            .surface => |v| v.rt_surface,
        };
        const win = surface.window;

        if (surface.isFullscreen()) {
            win.setMonitor(
                null,
                @intCast(surface.monitor_dims.position_x),
                @intCast(surface.monitor_dims.position_y),
                surface.monitor_dims.width,
                surface.monitor_dims.height,
                0,
            );
            return;
        }

        const monitor = win.getMonitor() orelse monitor: {
            log.warn("window had null monitor, getting primary monitor", .{});
            break :monitor glfw.Monitor.getPrimary() orelse {
                log.warn("window could not get any monitor. will not perform action", .{});
                return;
            };
        };

        const video_mode = monitor.getVideoMode() orelse {
            log.warn("failed to get video mode. will not perform action", .{});
            return;
        };

        const position = win.getPos();
        const size = surface.getSize() catch {
            log.warn("failed to get window size. will not perform fullscreen action", .{});
            return;
        };

        surface.monitor_dims = .{
            .width = size.width,
            .height = size.height,
            .position_x = position.x,
            .position_y = position.y,
        };

        win.setMonitor(monitor, 0, 0, video_mode.getWidth(), video_mode.getHeight(), 0);
    }

    /// Create a new tab in the parent surface.
    fn newTab(self: *App, parent_: ?*CoreSurface) !void {
        if (comptime !darwin_enabled) {
            log.warn("tabbing is not supported on this platform", .{});
            return;
        }

        const parent = parent_ orelse {
            _ = try self.newSurface(null);
            return;
        };

        // Create the new window
        const window = try self.newSurface(parent);

        // Add the new window the parent window
        const parent_win = glfwNative.getCocoaWindow(parent.rt_surface.window).?;
        const other_win = glfwNative.getCocoaWindow(window.window).?;
        const NSWindowOrderingMode = enum(isize) { below = -1, out = 0, above = 1 };
        const nswindow = objc.Object.fromId(parent_win);
        nswindow.msgSend(void, objc.sel("addTabbedWindow:ordered:"), .{
            objc.Object.fromId(other_win),
            NSWindowOrderingMode.above,
        });

        // Adding a new tab can cause the tab bar to appear which changes
        // our viewport size. We need to call the size callback in order to
        // update values. For example, we need this to set the proper mouse selection
        // point in the grid.
        const size = parent.rt_surface.getSize() catch |err| {
            log.err("error querying window size for size callback on new tab err={}", .{err});
            return;
        };
        parent.sizeCallback(size) catch |err| {
            log.err("error in size callback from new tab err={}", .{err});
            return;
        };
    }

    fn newSurface(self: *App, parent_: ?*CoreSurface) !*Surface {
        // Grab a surface allocation because we're going to need it.
        var surface = try self.app.alloc.create(Surface);
        errdefer self.app.alloc.destroy(surface);

        // Create the surface -- because windows are surfaces for glfw.
        try surface.init(self);
        errdefer surface.deinit();

        // If we have a parent, inherit some properties
        if (self.config.@"window-inherit-font-size") {
            if (parent_) |parent| {
                try surface.core_surface.setFontSize(parent.font_size);
            }
        }

        return surface;
    }

    /// Close the given surface.
    pub fn closeSurface(self: *App, surface: *Surface) void {
        surface.deinit();
        self.app.alloc.destroy(surface);
    }

    pub fn redrawSurface(self: *App, surface: *Surface) void {
        _ = self;
        _ = surface;

        @panic("This should never be called for GLFW.");
    }

    pub fn redrawInspector(self: *App, surface: *Surface) void {
        _ = self;
        _ = surface;

        // GLFW doesn't support the inspector
    }

    fn glfwErrorCallback(code: glfw.ErrorCode, desc: [:0]const u8) void {
        std.log.warn("glfw error={} message={s}", .{ code, desc });

        // Workaround for: https://github.com/ocornut/imgui/issues/5908
        // If we get an invalid value with "scancode" in the message we assume
        // it is from the glfw key callback that imgui sets and we clear the
        // error so that our future code doesn't crash.
        if (code == glfw.ErrorCode.InvalidValue and
            std.mem.indexOf(u8, desc, "scancode") != null)
        {
            _ = glfw.getError();
        }
    }

    pub fn keyboardLayout(self: *const App) input.KeyboardLayout {
        _ = self;

        // Not supported by glfw
        return .unknown;
    }

    /// Mac-specific settings. This is only enabled when the target is
    /// Mac and the artifact is a standalone exe. We don't target libs because
    /// the embedded API doesn't do windowing.
    const Darwin = struct {
        tabbing_id: *macos.foundation.String,

        pub fn init() !Darwin {
            const NSWindow = objc.getClass("NSWindow").?;
            NSWindow.msgSend(void, objc.sel("setAllowsAutomaticWindowTabbing:"), .{true});

            // Our tabbing ID allows all of our windows to group together
            const tabbing_id = try macos.foundation.String.createWithBytes(
                "com.mitchellh.ghostty.window",
                .utf8,
                false,
            );
            errdefer tabbing_id.release();

            // Setup our Mac settings
            return .{ .tabbing_id = tabbing_id };
        }

        pub fn deinit(self: *Darwin) void {
            self.tabbing_id.release();
            self.* = undefined;
        }
    };
};

/// These are used to keep track of the original monitor values so that we can
/// safely toggle on and off of fullscreen.
const MonitorDimensions = struct {
    width: u32,
    height: u32,
    position_x: i64,
    position_y: i64,
};

/// Surface represents the drawable surface for glfw. In glfw, a surface
/// is always a window because that is the only abstraction that glfw exposes.
///
/// This means that there is no way for the glfw runtime to support tabs,
/// splits, etc. without considerable effort. In fact, on Darwin, we do
/// support tabs because the minimal tabbing interface is a window abstraction,
/// but this is a bit of a hack. The native Swift runtime should be used instead
/// which uses real native tabbing.
///
/// Other runtimes a surface usually represents the equivalent of a "view"
/// or "widget" level granularity.
pub const Surface = struct {
    /// The glfw window handle
    window: glfw.Window,

    /// The glfw mouse cursor handle.
    cursor: ?glfw.Cursor,

    /// The app we're part of
    app: *App,

    /// A core surface
    core_surface: CoreSurface,

    /// This is the key event that was processed in keyCallback. This is only
    /// non-null if the event was NOT consumed in keyCallback. This lets us
    /// know in charCallback whether we should populate it and call it again.
    /// (GLFW guarantees that charCallback is called after keyCallback).
    key_event: ?input.KeyEvent = null,

    /// The monitor dimensions so we can toggle fullscreen on and off.
    monitor_dims: MonitorDimensions,

    /// Save the title text so that we can return it later when requested.
    /// This is allocated from the heap so it must be freed when we deinit the
    /// surface.
    title_text: ?[:0]const u8 = null,

    pub const Options = struct {};

    /// Initialize the surface into the given self pointer. This gives a
    /// stable pointer to the destination that can be used for callbacks.
    pub fn init(self: *Surface, app: *App) !void {
        // Create our window
        const win = glfw.Window.create(
            640,
            480,
            "ghostty",
            if (app.config.fullscreen) glfw.Monitor.getPrimary() else null,
            null,
            Renderer.glfwWindowHints(&app.config),
        ) orelse return glfw.mustGetErrorCode();
        errdefer win.destroy();

        // Setup our
        setInitialWindowPosition(
            win,
            app.config.@"window-position-x",
            app.config.@"window-position-y",
        );

        // Get our physical DPI - debug only because we don't have a use for
        // this but the logging of it may be useful
        if (builtin.mode == .Debug) {
            const monitor = win.getMonitor() orelse monitor: {
                log.warn("window had null monitor, getting primary monitor", .{});
                break :monitor glfw.Monitor.getPrimary().?;
            };
            const video_mode = monitor.getVideoMode() orelse return glfw.mustGetErrorCode();
            const physical_size = monitor.getPhysicalSize();
            const physical_x_dpi = @as(f32, @floatFromInt(video_mode.getWidth())) / (@as(f32, @floatFromInt(physical_size.width_mm)) / 25.4);
            const physical_y_dpi = @as(f32, @floatFromInt(video_mode.getHeight())) / (@as(f32, @floatFromInt(physical_size.height_mm)) / 25.4);
            log.debug("physical dpi x={} y={}", .{
                physical_x_dpi,
                physical_y_dpi,
            });
        }

        // On Mac, enable window tabbing
        if (comptime darwin_enabled) {
            const NSWindowTabbingMode = enum(usize) { automatic = 0, preferred = 1, disallowed = 2 };
            const nswindow = objc.Object.fromId(glfwNative.getCocoaWindow(win).?);

            // Tabbing mode enables tabbing at all
            nswindow.setProperty("tabbingMode", NSWindowTabbingMode.automatic);

            // All windows within a tab bar must have a matching tabbing ID.
            // The app sets this up for us.
            nswindow.setProperty("tabbingIdentifier", app.darwin.tabbing_id);
        }

        // Set our callbacks
        win.setUserPointer(&self.core_surface);
        win.setSizeCallback(sizeCallback);
        win.setCharCallback(charCallback);
        win.setKeyCallback(keyCallback);
        win.setFocusCallback(focusCallback);
        win.setRefreshCallback(refreshCallback);
        win.setScrollCallback(scrollCallback);
        win.setCursorPosCallback(cursorPosCallback);
        win.setMouseButtonCallback(mouseButtonCallback);
        win.setDropCallback(dropCallback);

        const dimensions: MonitorDimensions = dimensions: {
            const pos = win.getPos();
            const size = win.getFramebufferSize();
            break :dimensions .{
                .width = size.width,
                .height = size.height,
                .position_x = pos.x,
                .position_y = pos.y,
            };
        };

        // Build our result
        self.* = .{
            .app = app,
            .window = win,
            .cursor = null,
            .core_surface = undefined,
            .monitor_dims = dimensions,
        };
        errdefer self.* = undefined;

        // Initialize our cursor
        try self.setMouseShape(.text);

        // Add ourselves to the list of surfaces on the app.
        try app.app.addSurface(self);
        errdefer app.app.deleteSurface(self);

        // Get our new surface config
        var config = try apprt.surface.newConfig(app.app, &app.config);
        defer config.deinit();

        // Initialize our surface now that we have the stable pointer.
        try self.core_surface.init(
            app.app.alloc,
            &config,
            app.app,
            app,
            self,
        );
        errdefer self.core_surface.deinit();
    }

    pub fn deinit(self: *Surface) void {
        if (self.title_text) |t| self.core_surface.alloc.free(t);

        // Remove ourselves from the list of known surfaces in the app.
        self.app.app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        self.core_surface.deinit();

        if (comptime darwin_enabled) {
            const nswindow = objc.Object.fromId(glfwNative.getCocoaWindow(self.window).?);
            const tabgroup = nswindow.getProperty(objc.Object, "tabGroup");
            const windows = tabgroup.getProperty(objc.Object, "windows");
            switch (windows.getProperty(usize, "count")) {
                // If we're going down to one window our tab bar is going to be
                // destroyed so unset it so that the later logic doesn't try to
                // use it.
                1 => {},

                // If our tab bar is visible and we are going down to 1 window,
                // hide the tab bar. The check is "2" because our current window
                // is still present.
                2 => if (tabgroup.getProperty(bool, "tabBarVisible")) {
                    nswindow.msgSend(void, objc.sel("toggleTabBar:"), .{nswindow.value});
                },

                else => {},
            }
        }

        // We can now safely destroy our windows. We have to do this BEFORE
        // setting up the new focused window below.
        self.window.destroy();
        if (self.cursor) |c| {
            c.destroy();
            self.cursor = null;
        }
    }

    /// Checks if the glfw window is in fullscreen.
    pub fn isFullscreen(self: *Surface) bool {
        return self.window.getMonitor() != null;
    }

    /// Close this surface.
    pub fn close(self: *Surface, processActive: bool) void {
        _ = processActive;
        self.setShouldClose();
        self.deinit();
        self.app.app.alloc.destroy(self);
    }

    /// Set the initial window size. This is called exactly once at
    /// surface initialization time. This may be called before "self"
    /// is fully initialized.
    fn setInitialWindowSize(self: *const Surface, width: u32, height: u32) !void {
        const monitor = self.window.getMonitor() orelse glfw.Monitor.getPrimary() orelse {
            log.warn("window is not on a monitor, not setting initial size", .{});
            return;
        };

        const workarea = monitor.getWorkarea();
        self.window.setSize(.{
            .width = @min(width, workarea.width),
            .height = @min(height, workarea.height),
        });
    }

    /// Set the initial window position. This is called exactly once at
    /// surface initialization time. This may be called before "self"
    /// is fully initialized.
    fn setInitialWindowPosition(win: glfw.Window, x: ?i16, y: ?i16) void {
        const start_position_x = x orelse return;
        const start_position_y = y orelse return;

        log.debug("setting initial window position ({},{})", .{ start_position_x, start_position_y });
        win.setPos(.{ .x = start_position_x, .y = start_position_y });
    }

    /// Set the size limits of the window.
    /// Note: this interface is not good, we should redo it if we plan
    /// to use this more. i.e. you can't set max width but no max height,
    /// or no mins.
    fn setSizeLimits(self: *Surface, min: apprt.SurfaceSize, max_: ?apprt.SurfaceSize) !void {
        self.window.setSizeLimits(.{
            .width = min.width,
            .height = min.height,
        }, if (max_) |max| .{
            .width = max.width,
            .height = max.height,
        } else .{
            .width = null,
            .height = null,
        });
    }

    /// Returns the content scale for the created window.
    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        const scale = self.window.getContentScale();
        return apprt.ContentScale{ .x = scale.x_scale, .y = scale.y_scale };
    }

    /// Returns the size of the window in pixels. The pixel size may
    /// not match screen coordinate size but we should be able to convert
    /// back and forth using getContentScale.
    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        const size = self.window.getFramebufferSize();
        return apprt.SurfaceSize{ .width = size.width, .height = size.height };
    }

    /// Returns the cursor position in scaled pixels relative to the
    /// upper-left of the window.
    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        const unscaled_pos = self.window.getCursorPos();
        const pos = try self.cursorPosToPixels(unscaled_pos);
        return apprt.CursorPos{
            .x = @floatCast(pos.xpos),
            .y = @floatCast(pos.ypos),
        };
    }

    /// Set the flag that notes this window should be closed for the next
    /// iteration of the event loop.
    pub fn setShouldClose(self: *Surface) void {
        self.window.setShouldClose(true);
    }

    /// Returns true if the window is flagged to close.
    pub fn shouldClose(self: *const Surface) bool {
        return self.window.shouldClose();
    }

    /// Set the title of the window.
    fn setTitle(self: *Surface, slice: [:0]const u8) !void {
        if (self.title_text) |t| self.core_surface.alloc.free(t);
        self.title_text = try self.core_surface.alloc.dupeZ(u8, slice);
        self.window.setTitle(self.title_text.?.ptr);
    }

    /// Return the title of the window.
    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title_text;
    }

    /// Set the shape of the cursor.
    fn setMouseShape(self: *Surface, shape: terminal.MouseShape) !void {
        if ((comptime builtin.target.os.tag.isDarwin()) and
            !internal_os.macos.isAtLeastVersion(13, 0, 0))
        {
            // We only set our cursor if we're NOT on Mac, or if we are then the
            // macOS version is >= 13 (Ventura). On prior versions, glfw crashes
            // since we use a tab group.
            return;
        }

        const new = glfw.Cursor.createStandard(switch (shape) {
            .default => .arrow,
            .text => .ibeam,
            .crosshair => .crosshair,
            .pointer => .pointing_hand,
            .ew_resize => .resize_ew,
            .ns_resize => .resize_ns,
            .nwse_resize => .resize_nwse,
            .nesw_resize => .resize_nesw,
            .all_scroll => .resize_all,
            .not_allowed => .not_allowed,
            else => return, // unsupported, ignore
        }) orelse {
            const err = glfw.mustGetErrorCode();
            log.warn("error creating cursor: {}", .{err});
            return;
        };
        errdefer new.destroy();

        // Set our cursor before we destroy the old one
        self.window.setCursor(new);

        if (self.cursor) |c| c.destroy();
        self.cursor = new;
    }

    /// Set the visibility of the mouse cursor.
    fn setMouseVisibility(self: *Surface, visible: bool) void {
        self.window.setInputModeCursor(if (visible) .normal else .hidden);
    }

    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        _ = self;
        return switch (clipboard_type) {
            .standard => true,
            .selection, .primary => comptime builtin.os.tag == .linux,
        };
    }

    /// Start an async clipboard request.
    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !void {
        // GLFW can read clipboards immediately so just do that.
        const str: [:0]const u8 = switch (clipboard_type) {
            .standard => glfw.getClipboardString() orelse return glfw.mustGetErrorCode(),
            .selection, .primary => selection: {
                // Not supported except on Linux
                if (comptime builtin.os.tag != .linux) break :selection "";

                const raw = glfwNative.getX11SelectionString() orelse
                    return glfw.mustGetErrorCode();
                break :selection std.mem.span(raw);
            },
        };

        // Complete our request. We always allow unsafe because we don't
        // want to deal with user confirmation in this runtime.
        try self.core_surface.completeClipboardRequest(state, str, true);
    }

    /// Set the clipboard.
    pub fn setClipboardString(
        self: *const Surface,
        val: [:0]const u8,
        clipboard_type: apprt.Clipboard,
        confirm: bool,
    ) !void {
        _ = confirm;
        _ = self;
        switch (clipboard_type) {
            .standard => glfw.setClipboardString(val),
            .selection, .primary => {
                // Not supported except on Linux
                if (comptime builtin.os.tag != .linux) return;
                glfwNative.setX11SelectionString(val.ptr);
            },
        }
    }

    /// The cursor position from glfw directly is in screen coordinates but
    /// all our interface works in pixels.
    fn cursorPosToPixels(self: *const Surface, pos: glfw.Window.CursorPos) !glfw.Window.CursorPos {
        // The cursor position is in screen coordinates but we
        // want it in pixels. we need to get both the size of the
        // window in both to get the ratio to make the conversion.
        const size = self.window.getSize();
        const fb_size = self.window.getFramebufferSize();

        // If our framebuffer and screen are the same, then there is no scaling
        // happening and we can short-circuit by returning the pos as-is.
        if (fb_size.width == size.width and fb_size.height == size.height)
            return pos;

        const x_scale = @as(f64, @floatFromInt(fb_size.width)) / @as(f64, @floatFromInt(size.width));
        const y_scale = @as(f64, @floatFromInt(fb_size.height)) / @as(f64, @floatFromInt(size.height));
        return .{
            .xpos = pos.xpos * x_scale,
            .ypos = pos.ypos * y_scale,
        };
    }

    pub fn defaultTermioEnv(self: *Surface) !std.process.EnvMap {
        return try internal_os.getEnvMap(self.app.app.alloc);
    }

    fn sizeCallback(window: glfw.Window, width: i32, height: i32) void {
        _ = width;
        _ = height;

        // Get the size. We are given a width/height but this is in screen
        // coordinates and we want raw pixels. The core window uses the content
        // scale to scale appropriately.
        const core_win = window.getUserPointer(CoreSurface) orelse return;
        const size = core_win.rt_surface.getSize() catch |err| {
            log.err("error querying window size for size callback err={}", .{err});
            return;
        };

        // Call the primary callback.
        core_win.sizeCallback(size) catch |err| {
            log.err("error in size callback err={}", .{err});
            return;
        };
    }

    fn charCallback(window: glfw.Window, codepoint: u21) void {
        const core_win = window.getUserPointer(CoreSurface) orelse return;

        // We need a key event in order to process the charcallback. If it
        // isn't set then the key event was consumed.
        var key_event = core_win.rt_surface.key_event orelse return;
        core_win.rt_surface.key_event = null;

        // Populate the utf8 value for the event
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch |err| {
            log.err("error encoding codepoint={} err={}", .{ codepoint, err });
            return;
        };
        key_event.utf8 = buf[0..len];

        // On macOS we need to also disable some modifiers because
        // alt+key consumes the alt.
        if (comptime builtin.target.os.tag.isDarwin()) {
            // For GLFW, we say we always consume alt because
            // GLFW doesn't have a way to disable the alt key.
            key_event.consumed_mods.alt = true;
        }

        _ = core_win.keyCallback(key_event) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    fn keyCallback(
        window: glfw.Window,
        glfw_key: glfw.Key,
        scancode: i32,
        glfw_action: glfw.Action,
        glfw_mods: glfw.Mods,
    ) void {
        _ = scancode;

        const core_win = window.getUserPointer(CoreSurface) orelse return;

        // Convert our glfw types into our input types
        const mods: input.Mods = .{
            .shift = glfw_mods.shift,
            .ctrl = glfw_mods.control,
            .alt = glfw_mods.alt,
            .super = glfw_mods.super,
        };
        const action: input.Action = switch (glfw_action) {
            .release => .release,
            .press => .press,
            .repeat => .repeat,
        };
        const key: input.Key = switch (glfw_key) {
            .a => .key_a,
            .b => .key_b,
            .c => .key_c,
            .d => .key_d,
            .e => .key_e,
            .f => .key_f,
            .g => .key_g,
            .h => .key_h,
            .i => .key_i,
            .j => .key_j,
            .k => .key_k,
            .l => .key_l,
            .m => .key_m,
            .n => .key_n,
            .o => .key_o,
            .p => .key_p,
            .q => .key_q,
            .r => .key_r,
            .s => .key_s,
            .t => .key_t,
            .u => .key_u,
            .v => .key_v,
            .w => .key_w,
            .x => .key_x,
            .y => .key_y,
            .z => .key_z,
            .zero => .digit_0,
            .one => .digit_1,
            .two => .digit_2,
            .three => .digit_3,
            .four => .digit_4,
            .five => .digit_5,
            .six => .digit_6,
            .seven => .digit_7,
            .eight => .digit_8,
            .nine => .digit_9,
            .up => .arrow_up,
            .down => .arrow_down,
            .right => .arrow_right,
            .left => .arrow_left,
            .home => .home,
            .end => .end,
            .page_up => .page_up,
            .page_down => .page_down,
            .escape => .escape,
            .F1 => .f1,
            .F2 => .f2,
            .F3 => .f3,
            .F4 => .f4,
            .F5 => .f5,
            .F6 => .f6,
            .F7 => .f7,
            .F8 => .f8,
            .F9 => .f9,
            .F10 => .f10,
            .F11 => .f11,
            .F12 => .f12,
            .F13 => .f13,
            .F14 => .f14,
            .F15 => .f15,
            .F16 => .f16,
            .F17 => .f17,
            .F18 => .f18,
            .F19 => .f19,
            .F20 => .f20,
            .F21 => .f21,
            .F22 => .f22,
            .F23 => .f23,
            .F24 => .f24,
            .F25 => .f25,
            .kp_0 => .numpad_0,
            .kp_1 => .numpad_1,
            .kp_2 => .numpad_2,
            .kp_3 => .numpad_3,
            .kp_4 => .numpad_4,
            .kp_5 => .numpad_5,
            .kp_6 => .numpad_6,
            .kp_7 => .numpad_7,
            .kp_8 => .numpad_8,
            .kp_9 => .numpad_9,
            .kp_decimal => .numpad_decimal,
            .kp_divide => .numpad_divide,
            .kp_multiply => .numpad_multiply,
            .kp_subtract => .numpad_subtract,
            .kp_add => .numpad_add,
            .kp_enter => .numpad_enter,
            .kp_equal => .numpad_equal,
            .grave_accent => .backquote,
            .minus => .minus,
            .equal => .equal,
            .space => .space,
            .semicolon => .semicolon,
            .apostrophe => .quote,
            .comma => .comma,
            .period => .period,
            .slash => .slash,
            .left_bracket => .bracket_left,
            .right_bracket => .bracket_right,
            .backslash => .backslash,
            .enter => .enter,
            .tab => .tab,
            .backspace => .backspace,
            .insert => .insert,
            .delete => .delete,
            .caps_lock => .caps_lock,
            .scroll_lock => .scroll_lock,
            .num_lock => .num_lock,
            .print_screen => .print_screen,
            .pause => .pause,
            .left_shift => .shift_left,
            .left_control => .control_left,
            .left_alt => .alt_left,
            .left_super => .meta_left,
            .right_shift => .shift_right,
            .right_control => .control_right,
            .right_alt => .alt_right,
            .right_super => .meta_right,
            .menu => .context_menu,

            .world_1,
            .world_2,
            .unknown,
            => .unidentified,
        };

        // This is a hack for GLFW. We require our apprts to send both
        // the UTF8 encoding AND the keypress at the same time. Its critical
        // for things like ctrl sequences to work. However, GLFW doesn't
        // provide this information all at once. So we just infer based on
        // the key press. This isn't portable but GLFW is only for testing.
        const utf8 = switch (key) {
            inline else => |k| utf8: {
                if (mods.shift) break :utf8 "";
                const cp = k.codepoint() orelse break :utf8 "";
                const byte = std.math.cast(u8, cp) orelse break :utf8 "";
                break :utf8 &.{byte};
            },
        };

        const key_event: input.KeyEvent = .{
            .action = action,
            .key = key,
            .mods = mods,
            .consumed_mods = .{},
            .composing = false,
            .utf8 = utf8,
            .unshifted_codepoint = if (utf8.len > 0) @intCast(utf8[0]) else 0,
        };

        const effect = core_win.keyCallback(key_event) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };

        // Surface closed.
        if (effect == .closed) return;

        // If it wasn't consumed, we set it on our self so that charcallback
        // can make another attempt. Otherwise, we set null so the charcallback
        // is ignored.
        core_win.rt_surface.key_event = null;
        if (effect == .ignored and
            (action == .press or action == .repeat))
        {
            core_win.rt_surface.key_event = key_event;
        }
    }

    fn focusCallback(window: glfw.Window, focused: bool) void {
        const core_win = window.getUserPointer(CoreSurface) orelse return;
        core_win.focusCallback(focused) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    fn refreshCallback(window: glfw.Window) void {
        const core_win = window.getUserPointer(CoreSurface) orelse return;
        core_win.refreshCallback() catch |err| {
            log.err("error in refresh callback err={}", .{err});
            return;
        };
    }

    fn scrollCallback(window: glfw.Window, xoff: f64, yoff: f64) void {
        // Glfw doesn't support any of the scroll mods.
        const scroll_mods: input.ScrollMods = .{};

        const core_win = window.getUserPointer(CoreSurface) orelse return;
        core_win.scrollCallback(xoff, yoff, scroll_mods) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return;
        };
    }

    fn cursorPosCallback(
        window: glfw.Window,
        unscaled_xpos: f64,
        unscaled_ypos: f64,
    ) void {
        const core_win = window.getUserPointer(CoreSurface) orelse return;

        // Convert our unscaled x/y to scaled.
        const pos = core_win.rt_surface.cursorPosToPixels(.{
            .xpos = unscaled_xpos,
            .ypos = unscaled_ypos,
        }) catch |err| {
            log.err(
                "error converting cursor pos to scaled pixels in cursor pos callback err={}",
                .{err},
            );
            return;
        };

        core_win.cursorPosCallback(.{
            .x = @floatCast(pos.xpos),
            .y = @floatCast(pos.ypos),
        }, null) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }

    fn mouseButtonCallback(
        window: glfw.Window,
        glfw_button: glfw.MouseButton,
        glfw_action: glfw.Action,
        glfw_mods: glfw.Mods,
    ) void {
        const core_win = window.getUserPointer(CoreSurface) orelse return;

        // Convert glfw button to input button
        const mods: input.Mods = .{
            .shift = glfw_mods.shift,
            .ctrl = glfw_mods.control,
            .alt = glfw_mods.alt,
            .super = glfw_mods.super,
        };
        const button: input.MouseButton = switch (glfw_button) {
            .left => .left,
            .right => .right,
            .middle => .middle,
            .four => .four,
            .five => .five,
            .six => .six,
            .seven => .seven,
            .eight => .eight,
        };
        const action: input.MouseButtonState = switch (glfw_action) {
            .press => .press,
            .release => .release,
            else => unreachable,
        };

        _ = core_win.mouseButtonCallback(action, button, mods) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return;
        };
    }

    fn dropCallback(window: glfw.Window, paths: [][*:0]const u8) void {
        const surface = window.getUserPointer(CoreSurface) orelse return;

        var list = std.ArrayList(u8).init(surface.alloc);
        defer list.deinit();

        for (paths) |path| {
            const path_slice = std.mem.span(path);

            // preallocate worst case of escaping every char + space
            list.ensureTotalCapacity(path_slice.len * 2 + 1) catch |err| {
                log.err("error in drop callback err={}", .{err});
                return;
            };

            const writer = list.writer();
            for (path_slice) |c| {
                if (std.mem.indexOfScalar(u8, "\\ ()[]{}<>\"'`!#$&;|*?\t", c)) |_| {
                    writer.print("\\{c}", .{c}) catch unreachable; //  memory preallocated
                } else writer.writeByte(c) catch unreachable; // same here
            }
            writer.writeByte(' ') catch unreachable; // separate paths

            surface.textCallback(list.items) catch |err| {
                log.err("error in drop callback err={}", .{err});
                return;
            };

            list.clearRetainingCapacity(); // avoid unnecessary reallocations
        }
    }
};
