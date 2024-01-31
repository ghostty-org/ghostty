/// A surface represents one drawable terminal surface. The surface may be
/// attached to a window or it may be some other kind of surface. This struct
/// is meant to be generic to all scenarios.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");
const apprt = @import("../../apprt.zig");
const font = @import("../../font/main.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");

const App = @import("App.zig");
const Split = @import("Split.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");
const ClipboardConfirmationWindow = @import("ClipboardConfirmationWindow.zig");
const inspector = @import("inspector.zig");
const gtk_key = @import("key.zig");
const c = @import("c.zig");
const x11 = @import("x11.zig");

const log = std.log.scoped(.gtk_surface);

/// This is detected by the OpenGL renderer to move to a single-threaded
/// draw operation. This basically puts locks around our draw path.
pub const opengl_single_threaded_draw = true;

pub const Options = struct {
    /// The parent surface to inherit settings such as font size, working
    /// directory, etc. from.
    parent: ?*CoreSurface = null,

    /// A custom config to use in the surface.
    config: ?*configpkg.Config = null,
};

/// The container that this surface is directly attached to.
pub const Container = union(enum) {
    /// The surface is not currently attached to anything. This means
    /// that the GLArea has been created and potentially initialized
    /// but the widget is currently floating and not part of any parent.
    none: void,

    /// Directly attached to a tab. (i.e. no splits)
    tab_: *Tab,

    /// A split within a split hierarchy. The key determines the
    /// position of the split within the parent split.
    split_tl: *Elem,
    split_br: *Elem,

    /// The side of the split.
    pub const SplitSide = enum { top_left, bottom_right };

    /// Elem is the possible element of any container. A container can
    /// hold both a surface and a split. Any valid container should
    /// have an Elem value so that it can be properly used with
    /// splits.
    pub const Elem = union(enum) {
        /// A surface is a leaf element of the split -- a terminal
        /// surface.
        surface: *Surface,

        /// A split is a nested split within a split. This lets you
        /// for example have a horizontal split with a vertical split
        /// on the left side (amongst all other possible
        /// combinations).
        split: *Split,

        /// Returns the GTK widget to add to the paned for the given
        /// element
        pub fn widget(self: Elem) *c.GtkWidget {
            return switch (self) {
                .surface => |s| @ptrCast(s.gl_area),
                .split => |s| @ptrCast(@alignCast(s.paned)),
            };
        }

        pub fn containerPtr(self: Elem) *Container {
            return switch (self) {
                .surface => |s| &s.container,
                .split => |s| &s.container,
            };
        }

        pub fn deinit(self: Elem, alloc: Allocator) void {
            switch (self) {
                .surface => |s| s.unref(),
                .split => |s| s.destroy(alloc),
            }
        }

        pub fn grabFocus(self: Elem) void {
            switch (self) {
                .surface => |s| s.grabFocus(),
                .split => |s| s.grabFocus(),
            }
        }

        pub fn equalize(self: Elem) f64 {
            return switch (self) {
                .surface => 1,
                .split => |s| s.equalize(),
            };
        }

        /// The last surface in this container in the direction specified.
        /// Direction must be "top_left" or "bottom_right".
        pub fn deepestSurface(self: Elem, side: SplitSide) ?*Surface {
            return switch (self) {
                .surface => |s| s,
                .split => |s| (switch (side) {
                    .top_left => s.top_left,
                    .bottom_right => s.bottom_right,
                }).deepestSurface(side),
            };
        }
    };

    /// Returns the window that this surface is attached to.
    pub fn window(self: Container) ?*Window {
        return switch (self) {
            .none => null,
            .tab_ => |v| v.window,
            .split_tl, .split_br => split: {
                const s = self.split() orelse break :split null;
                break :split s.container.window();
            },
        };
    }

    /// Returns the tab container if it exists.
    pub fn tab(self: Container) ?*Tab {
        return switch (self) {
            .none => null,
            .tab_ => |v| v,
            .split_tl, .split_br => split: {
                const s = self.split() orelse break :split null;
                break :split s.container.tab();
            },
        };
    }

    /// Returns the split containing this surface (if any).
    pub fn split(self: Container) ?*Split {
        return switch (self) {
            .none, .tab_ => null,
            .split_tl => |ptr| @fieldParentPtr(Split, "top_left", ptr),
            .split_br => |ptr| @fieldParentPtr(Split, "bottom_right", ptr),
        };
    }

    /// The side that we are in the split.
    pub fn splitSide(self: Container) ?SplitSide {
        return switch (self) {
            .none, .tab_ => null,
            .split_tl => .top_left,
            .split_br => .bottom_right,
        };
    }

    /// Returns the first split with the given orientation, walking upwards in
    /// the tree.
    pub fn firstSplitWithOrientation(
        self: Container,
        orientation: Split.Orientation,
    ) ?*Split {
        return switch (self) {
            .none, .tab_ => null,
            .split_tl, .split_br => split: {
                const s = self.split() orelse break :split null;
                if (s.orientation == orientation) break :split s;
                break :split s.container.firstSplitWithOrientation(orientation);
            },
        };
    }

    /// Replace the container's element with this element. This is
    /// used by children to modify their parents to for example change
    /// from a surface to a split or a split back to a surface or
    /// a split to a nested split and so on.
    pub fn replace(self: Container, elem: Elem) void {
        // Move the element into the container
        switch (self) {
            .none => {},
            .tab_ => |t| t.replaceElem(elem),
            inline .split_tl, .split_br => |ptr| {
                const s = self.split().?;
                s.replace(ptr, elem);
            },
        }

        // Update the reverse reference to the container
        elem.containerPtr().* = self;
    }

    /// Remove ourselves from the container. This is used by
    /// children to effectively notify they're container that
    /// all children at this level are exiting.
    pub fn remove(self: Container) void {
        switch (self) {
            .none => {},
            .tab_ => |t| t.remove(),
            .split_tl => self.split().?.removeTopLeft(),
            .split_br => self.split().?.removeBottomRight(),
        }
    }
};

/// Whether the surface has been realized or not yet. When a surface is
/// "realized" it means that the OpenGL context is ready and the core
/// surface has been initialized.
realized: bool = false,

/// True if this surface had a parent to start with.
parent_surface: bool = false,

/// Custom config to use for this surface.
config: ?*configpkg.Config,

/// The GUI container that this surface has been attached to. This
/// dictates some behaviors such as new splits, etc.
container: Container = .{ .none = {} },

/// The app we're part of
app: *App,

/// Our GTK area
gl_area: *c.GtkGLArea,

/// Any active cursor we may have
cursor: ?*c.GdkCursor = null,

/// Our title. The raw value of the title. This will be kept up to date and
/// .title will be updated if we have focus.
/// When set the text in this buf will be null-terminated, because we need to
/// pass it to GTK.
title_text: ?[:0]const u8 = null,

/// The core surface backing this surface
core_surface: CoreSurface,

/// The font size to use for this surface once realized.
font_size: ?font.face.DesiredSize = null,

/// Cached metrics about the surface from GTK callbacks.
size: apprt.SurfaceSize,
cursor_pos: apprt.CursorPos,

/// Inspector state.
inspector: ?*inspector.Inspector = null,

/// Key input states. See gtkKeyPressed for detailed descriptions.
in_keypress: bool = false,
im_context: *c.GtkIMContext,
im_composing: bool = false,
im_buf: [128]u8 = undefined,
im_len: u7 = 0,

pub fn create(alloc: Allocator, app: *App, opts: Options) !*Surface {
    var surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);
    try surface.init(app, opts);
    return surface;
}

pub fn init(self: *Surface, app: *App, opts: Options) !void {
    const widget: *c.GtkWidget = c.gtk_gl_area_new();
    const gl_area: *c.GtkGLArea = @ptrCast(widget);

    // We grab the floating reference to GL area. This lets the
    // GL area be moved around i.e. between a split, a tab, etc.
    // without having to be really careful about ordering to
    // prevent a destroy.
    //
    // This is unref'd in the unref() method that's called by the
    // self.container through Elem.deinit.
    _ = c.g_object_ref_sink(@ptrCast(gl_area));
    errdefer c.g_object_unref(@ptrCast(gl_area));

    // We want the gl area to expand to fill the parent container.
    c.gtk_widget_set_hexpand(widget, 1);
    c.gtk_widget_set_vexpand(widget, 1);

    // Various other GL properties
    c.gtk_widget_set_cursor_from_name(@ptrCast(gl_area), "text");
    c.gtk_gl_area_set_required_version(gl_area, 3, 3);
    c.gtk_gl_area_set_has_stencil_buffer(gl_area, 0);
    c.gtk_gl_area_set_has_depth_buffer(gl_area, 0);
    c.gtk_gl_area_set_use_es(gl_area, 0);

    // Key event controller will tell us about raw keypress events.
    const ec_key = c.gtk_event_controller_key_new();
    errdefer c.g_object_unref(ec_key);
    c.gtk_widget_add_controller(widget, ec_key);
    errdefer c.gtk_widget_remove_controller(widget, ec_key);

    // Focus controller will tell us about focus enter/exit events
    const ec_focus = c.gtk_event_controller_focus_new();
    errdefer c.g_object_unref(ec_focus);
    c.gtk_widget_add_controller(widget, ec_focus);
    errdefer c.gtk_widget_remove_controller(widget, ec_focus);

    // Create a second key controller so we can receive the raw
    // key-press events BEFORE the input method gets them.
    const ec_key_press = c.gtk_event_controller_key_new();
    errdefer c.g_object_unref(ec_key_press);
    c.gtk_widget_add_controller(widget, ec_key_press);
    errdefer c.gtk_widget_remove_controller(widget, ec_key_press);

    // Clicks
    const gesture_click = c.gtk_gesture_click_new();
    errdefer c.g_object_unref(gesture_click);
    c.gtk_gesture_single_set_button(@ptrCast(gesture_click), 0);
    c.gtk_widget_add_controller(widget, @ptrCast(gesture_click));

    // Mouse movement
    const ec_motion = c.gtk_event_controller_motion_new();
    errdefer c.g_object_unref(ec_motion);
    c.gtk_widget_add_controller(widget, ec_motion);

    // Scroll events
    const ec_scroll = c.gtk_event_controller_scroll_new(
        c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES |
            c.GTK_EVENT_CONTROLLER_SCROLL_DISCRETE,
    );
    errdefer c.g_object_unref(ec_scroll);
    c.gtk_widget_add_controller(widget, ec_scroll);

    // The input method context that we use to translate key events into
    // characters. This doesn't have an event key controller attached because
    // we call it manually from our own key controller.
    const im_context = c.gtk_im_multicontext_new();
    errdefer c.g_object_unref(im_context);

    // The GL area has to be focusable so that it can receive events
    c.gtk_widget_set_focusable(widget, 1);
    c.gtk_widget_set_focus_on_click(widget, 1);

    // Inherit the parent's font size if we have a parent.
    const font_size: ?font.face.DesiredSize = font_size: {
        if (opts.config) |config| if (!config.@"window-inherit-font-size") break :font_size null;
        if (!app.config.@"window-inherit-font-size") break :font_size null;
        const parent = opts.parent orelse break :font_size null;
        break :font_size parent.font_size;
    };

    // Build our result
    self.* = .{
        .app = app,
        .container = .{ .none = {} },
        .gl_area = gl_area,
        .title_text = null,
        .core_surface = undefined,
        .font_size = font_size,
        .parent_surface = opts.parent != null,
        .config = opts.config,
        .size = .{ .width = 800, .height = 600 },
        .cursor_pos = .{ .x = 0, .y = 0 },
        .im_context = im_context,
    };
    errdefer self.* = undefined;

    // Set our default mouse shape
    try self.setMouseShape(.text);

    // GL events
    _ = c.g_signal_connect_data(gl_area, "realize", c.G_CALLBACK(&gtkRealize), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gl_area, "unrealize", c.G_CALLBACK(&gtkUnrealize), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gl_area, "destroy", c.G_CALLBACK(&gtkDestroy), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gl_area, "render", c.G_CALLBACK(&gtkRender), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gl_area, "resize", c.G_CALLBACK(&gtkResize), self, null, c.G_CONNECT_DEFAULT);

    _ = c.g_signal_connect_data(ec_key_press, "key-pressed", c.G_CALLBACK(&gtkKeyPressed), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(ec_key_press, "key-released", c.G_CALLBACK(&gtkKeyReleased), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(ec_focus, "enter", c.G_CALLBACK(&gtkFocusEnter), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(ec_focus, "leave", c.G_CALLBACK(&gtkFocusLeave), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gesture_click, "pressed", c.G_CALLBACK(&gtkMouseDown), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gesture_click, "released", c.G_CALLBACK(&gtkMouseUp), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(ec_motion, "motion", c.G_CALLBACK(&gtkMouseMotion), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(ec_scroll, "scroll", c.G_CALLBACK(&gtkMouseScroll), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(im_context, "preedit-start", c.G_CALLBACK(&gtkInputPreeditStart), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(im_context, "preedit-changed", c.G_CALLBACK(&gtkInputPreeditChanged), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(im_context, "preedit-end", c.G_CALLBACK(&gtkInputPreeditEnd), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(im_context, "commit", c.G_CALLBACK(&gtkInputCommit), self, null, c.G_CONNECT_DEFAULT);
}

fn realize(self: *Surface) !void {
    // If this surface has already been realized, then we don't need to
    // reinitialize. This can happen if a surface is moved from one GDK surface
    // to another (i.e. a tab is pulled out into a window).
    if (self.realized) {
        // If we have no OpenGL state though, we do need to reinitialize.
        // We allow the renderer to figure that out
        try self.core_surface.renderer.displayRealize();
        return;
    }

    // Add ourselves to the list of surfaces on the app.
    try self.app.core_app.addSurface(self);
    errdefer self.app.core_app.deleteSurface(self);

    // Get our new surface config
    var config = if (self.config) |config| try apprt.surface.newConfig(self.app.core_app, config) else try apprt.surface.newConfig(self.app.core_app, &self.app.config);
    defer config.deinit();

    if (!self.parent_surface) {
        // A hack, see the "parent_surface" field for more information.
        config.@"working-directory" = self.app.config.@"working-directory";
    }

    // Initialize our surface now that we have the stable pointer.
    try self.core_surface.init(
        self.app.core_app.alloc,
        &config,
        self.app.core_app,
        self.app,
        self,
    );
    errdefer self.core_surface.deinit();

    // If we have a font size we want, set that now
    if (self.font_size) |size| {
        self.core_surface.setFontSize(size);
    }

    // The Config struct is going to be cleaned up so make it harder for us to
    // make a mistake.
    self.config = null;

    // Note we're realized
    self.realized = true;
}

pub fn deinit(self: *Surface) void {
    if (self.title_text) |title| self.app.core_app.alloc.free(title);

    // We don't allocate anything if we aren't realized.
    if (!self.realized) return;

    // Delete our inspector if we have one
    self.controlInspector(.hide);

    // Remove ourselves from the list of known surfaces in the app.
    self.app.core_app.deleteSurface(self);

    // Clean up our core surface so that all the rendering and IO stop.
    self.core_surface.deinit();
    self.core_surface = undefined;

    // Free all our GTK stuff
    c.g_object_unref(self.im_context);

    if (self.cursor) |cursor| c.g_object_unref(cursor);
}

// unref removes the long-held reference to the gl_area and kicks off the
// deinit/destroy process for this surface.
pub fn unref(self: *Surface) void {
    c.g_object_unref(self.gl_area);
}

pub fn destroy(self: *Surface, alloc: Allocator) void {
    self.deinit();
    alloc.destroy(self);
}

fn render(self: *Surface) !void {
    try self.core_surface.renderer.drawFrame(self);
}

/// Queue the inspector to render if we have one.
pub fn queueInspectorRender(self: *Surface) void {
    if (self.inspector) |v| v.queueRender();
}

/// Invalidate the surface so that it forces a redraw on the next tick.
pub fn redraw(self: *Surface) void {
    c.gtk_gl_area_queue_render(self.gl_area);
}

/// Close this surface.
pub fn close(self: *Surface, processActive: bool) void {
    // If we're not part of a window hierarchy, we never confirm
    // so we can just directly remove ourselves and exit.
    const window = self.container.window() orelse {
        self.container.remove();
        return;
    };

    // If we have no process active we can just exit immediately.
    if (!processActive) {
        self.container.remove();
        return;
    }

    // Setup our basic message
    const alert = c.gtk_message_dialog_new(
        window.window,
        c.GTK_DIALOG_MODAL,
        c.GTK_MESSAGE_QUESTION,
        c.GTK_BUTTONS_YES_NO,
        "Close this terminal?",
    );
    c.gtk_message_dialog_format_secondary_text(
        @ptrCast(alert),
        "There is still a running process in the terminal. " ++
            "Closing the terminal will kill this process. " ++
            "Are you sure you want to close the terminal?\n\n" ++
            "Click 'No' to cancel and return to your terminal.",
    );

    // We want the "yes" to appear destructive.
    const yes_widget = c.gtk_dialog_get_widget_for_response(
        @ptrCast(alert),
        c.GTK_RESPONSE_YES,
    );
    c.gtk_widget_add_css_class(yes_widget, "destructive-action");

    // We want the "no" to be the default action
    c.gtk_dialog_set_default_response(
        @ptrCast(alert),
        c.GTK_RESPONSE_NO,
    );

    _ = c.g_signal_connect_data(alert, "response", c.G_CALLBACK(&gtkCloseConfirmation), self, null, c.G_CONNECT_DEFAULT);

    c.gtk_widget_show(alert);
}

pub fn controlInspector(self: *Surface, mode: input.InspectorMode) void {
    const show = switch (mode) {
        .toggle => self.inspector == null,
        .show => true,
        .hide => false,
    };

    if (!show) {
        if (self.inspector) |v| {
            v.close();
            self.inspector = null;
        }

        return;
    }

    // If we already have an inspector, we don't need to show anything.
    if (self.inspector != null) return;
    self.inspector = inspector.Inspector.create(
        self,
        .{ .window = {} },
    ) catch |err| {
        log.err("failed to control inspector err={}", .{err});
        return;
    };
}

pub fn toggleFullscreen(self: *Surface, mac_non_native: configpkg.NonNativeFullscreen) void {
    const window = self.container.window() orelse {
        log.info(
            "toggleFullscreen invalid for container={s}",
            .{@tagName(self.container)},
        );
        return;
    };

    window.toggleFullscreen(mac_non_native);
}

pub fn getTitleLabel(self: *Surface) ?*c.GtkWidget {
    switch (self.title) {
        .none => return null,
        .label => |label| {
            const widget = @as(*c.GtkWidget, @ptrCast(@alignCast(label)));
            return widget;
        },
    }
}

pub fn newSplit(self: *Surface, direction: input.SplitDirection) !void {
    const alloc = self.app.core_app.alloc;
    _ = try Split.create(alloc, self, direction);
}

pub fn gotoSplit(self: *const Surface, direction: input.SplitFocusDirection) void {
    const s = self.container.split() orelse return;
    const map = s.directionMap(switch (self.container) {
        .split_tl => .top_left,
        .split_br => .bottom_right,
        .none, .tab_ => unreachable,
    });
    const surface_ = map.get(direction) orelse return;
    if (surface_) |surface| surface.grabFocus();
}

pub fn resizeSplit(self: *const Surface, direction: input.SplitResizeDirection, amount: u16) void {
    const s = self.container.firstSplitWithOrientation(
        Split.Orientation.fromResizeDirection(direction),
    ) orelse return;
    s.moveDivider(direction, amount);
}

pub fn equalizeSplits(self: *const Surface) void {
    const tab = self.container.tab() orelse return;
    const top_split = switch (tab.elem) {
        .split => |s| s,
        else => return,
    };
    _ = top_split.equalize();
}

pub fn newTab(self: *Surface) !void {
    const window = self.container.window() orelse {
        log.info("surface cannot create new tab when not attached to a window", .{});
        return;
    };

    try window.newTab(.{ .parent = &self.core_surface });
}

pub fn hasTabs(self: *const Surface) bool {
    const window = self.container.window() orelse return false;
    return window.hasTabs();
}

pub fn gotoPreviousTab(self: *Surface) void {
    const window = self.container.window() orelse {
        log.info(
            "gotoPreviousTab invalid for container={s}",
            .{@tagName(self.container)},
        );
        return;
    };

    window.gotoPreviousTab(self);
}

pub fn gotoNextTab(self: *Surface) void {
    const window = self.container.window() orelse {
        log.info(
            "gotoNextTab invalid for container={s}",
            .{@tagName(self.container)},
        );
        return;
    };

    window.gotoNextTab(self);
}

pub fn gotoTab(self: *Surface, n: usize) void {
    const window = self.container.window() orelse {
        log.info(
            "gotoTab invalid for container={s}",
            .{@tagName(self.container)},
        );
        return;
    };

    window.gotoTab(n);
}

pub fn setShouldClose(self: *Surface) void {
    _ = self;
}

pub fn shouldClose(self: *const Surface) bool {
    _ = self;
    return false;
}

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    // Future: detect GTK version 4.12+ and use gdk_surface_get_scale so we
    // can support fractional scaling.
    const gtk_scale: f32 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.gl_area)));

    // If we are on X11, we also have to scale using Xft.dpi
    const xft_dpi_scale = if (!x11.is_current_display_server()) 1.0 else xft_scale: {
        // Here we use GTK to retrieve gtk-xft-dpi, which is Xft.dpi multiplied
        // by 1024. See https://docs.gtk.org/gtk4/property.Settings.gtk-xft-dpi.html
        const settings = c.gtk_settings_get_default();

        var value: c.GValue = std.mem.zeroes(c.GValue);
        defer c.g_value_unset(&value);
        _ = c.g_value_init(&value, c.G_TYPE_INT);
        c.g_object_get_property(@ptrCast(@alignCast(settings)), "gtk-xft-dpi", &value);
        const gtk_xft_dpi = c.g_value_get_int(&value);

        // As noted above Xft.dpi is multiplied by 1024, so we divide by 1024,
        // then divide by the default value of Xft.dpi (96) to derive a scale.
        // Note that gtk-xft-dpi can be fractional, so we use floating point
        // math here.
        const xft_dpi: f32 = @as(f32, @floatFromInt(gtk_xft_dpi)) / 1024;
        break :xft_scale xft_dpi / 96;
    };

    const scale = gtk_scale * xft_dpi_scale;
    return .{ .x = scale, .y = scale };
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return self.size;
}

pub fn setInitialWindowSize(self: *const Surface, width: u32, height: u32) !void {
    // This operation only makes sense if we're within a window view hierarchy.
    const window = self.container.window() orelse return;

    // Note: this doesn't properly take into account the window decorations.
    // I'm not currently sure how to do that.
    c.gtk_window_set_default_size(
        @ptrCast(window.window),
        @intCast(width),
        @intCast(height),
    );
}

pub fn setCellSize(self: *const Surface, width: u32, height: u32) !void {
    _ = self;
    _ = width;
    _ = height;
}

pub fn setSizeLimits(self: *Surface, min: apprt.SurfaceSize, max_: ?apprt.SurfaceSize) !void {
    _ = self;
    _ = min;
    _ = max_;
}

pub fn grabFocus(self: *Surface) void {
    if (self.container.tab()) |tab| tab.focus_child = self;

    const widget = @as(*c.GtkWidget, @ptrCast(self.gl_area));
    _ = c.gtk_widget_grab_focus(widget);

    self.updateTitleLabels();
}

fn updateTitleLabels(self: *Surface) void {
    // If we have no title, then we have nothing to update.
    const title = self.title_text orelse return;

    // If we have a tab and are the focused child, then we have to update the tab
    if (self.container.tab()) |tab| {
        if (tab.focus_child == self) c.gtk_label_set_text(tab.label_text, title.ptr);
    }

    // If we have a window and are focused, then we have to update the window title.
    if (self.container.window()) |window| {
        const widget = @as(*c.GtkWidget, @ptrCast(self.gl_area));
        if (c.gtk_widget_is_focus(widget) == 1) c.gtk_window_set_title(window.window, title.ptr);
    }
}

pub fn setTitle(self: *Surface, slice: [:0]const u8) !void {
    const alloc = self.app.core_app.alloc;
    const copy = try alloc.dupeZ(u8, slice);
    errdefer alloc.free(copy);

    if (self.title_text) |old| alloc.free(old);
    self.title_text = copy;

    self.updateTitleLabels();
}

pub fn setMouseShape(
    self: *Surface,
    shape: terminal.MouseShape,
) !void {
    const name: [:0]const u8 = switch (shape) {
        .default => "default",
        .help => "help",
        .pointer => "pointer",
        .context_menu => "context-menu",
        .progress => "progress",
        .wait => "wait",
        .cell => "cell",
        .crosshair => "crosshair",
        .text => "text",
        .vertical_text => "vertical-text",
        .alias => "alias",
        .copy => "copy",
        .no_drop => "no-drop",
        .move => "move",
        .not_allowed => "not-allowed",
        .grab => "grab",
        .grabbing => "grabbing",
        .all_scroll => "all-scroll",
        .col_resize => "col-resize",
        .row_resize => "row-resize",
        .n_resize => "n-resize",
        .e_resize => "e-resize",
        .s_resize => "s-resize",
        .w_resize => "w-resize",
        .ne_resize => "ne-resize",
        .nw_resize => "nw-resize",
        .se_resize => "se-resize",
        .sw_resize => "sw-resize",
        .ew_resize => "ew-resize",
        .ns_resize => "ns-resize",
        .nesw_resize => "nesw-resize",
        .nwse_resize => "nwse-resize",
        .zoom_in => "zoom-in",
        .zoom_out => "zoom-out",
    };

    const cursor = c.gdk_cursor_new_from_name(name.ptr, null) orelse {
        log.warn("unsupported cursor name={s}", .{name});
        return;
    };
    errdefer c.g_object_unref(cursor);

    // Set our new cursor
    c.gtk_widget_set_cursor(@ptrCast(self.gl_area), cursor);

    // Free our existing cursor
    if (self.cursor) |old| c.g_object_unref(old);
    self.cursor = cursor;
}

/// Set the visibility of the mouse cursor.
pub fn setMouseVisibility(self: *Surface, visible: bool) void {
    // Note in there that self.cursor or cursor_none may be null. That's
    // not a problem because NULL is a valid argument for set cursor
    // which means to just use the parent value.

    if (visible) {
        c.gtk_widget_set_cursor(@ptrCast(self.gl_area), self.cursor);
        return;
    }

    // Set our new cursor to the app "none" cursor
    c.gtk_widget_set_cursor(@ptrCast(self.gl_area), self.app.cursor_none);
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !void {
    // We allocate for userdata for the clipboard request. Not ideal but
    // clipboard requests aren't common so probably not a big deal.
    const alloc = self.app.core_app.alloc;
    const ud_ptr = try alloc.create(ClipboardRequest);
    errdefer alloc.destroy(ud_ptr);
    ud_ptr.* = .{ .self = self, .state = state };

    // Start our async request
    const clipboard = getClipboard(@ptrCast(self.gl_area), clipboard_type);
    c.gdk_clipboard_read_text_async(
        clipboard,
        null,
        &gtkClipboardRead,
        ud_ptr,
    );
}

pub fn setClipboardString(
    self: *const Surface,
    val: [:0]const u8,
    clipboard_type: apprt.Clipboard,
    confirm: bool,
) !void {
    if (!confirm) {
        const clipboard = getClipboard(@ptrCast(self.gl_area), clipboard_type);
        c.gdk_clipboard_set_text(clipboard, val.ptr);
        return;
    }

    ClipboardConfirmationWindow.create(
        self.app,
        val,
        self.core_surface,
        .{ .osc_52_write = clipboard_type },
    ) catch |window_err| {
        log.err("failed to create clipboard confirmation window err={}", .{window_err});
    };
}

const ClipboardRequest = struct {
    self: *Surface,
    state: apprt.ClipboardRequest,
};

fn gtkClipboardRead(
    source: ?*c.GObject,
    res: ?*c.GAsyncResult,
    ud: ?*anyopaque,
) callconv(.C) void {
    const req: *ClipboardRequest = @ptrCast(@alignCast(ud orelse return));
    const self = req.self;
    const alloc = self.app.core_app.alloc;
    defer alloc.destroy(req);

    var gerr: ?*c.GError = null;
    const cstr = c.gdk_clipboard_read_text_finish(
        @ptrCast(source orelse return),
        res,
        &gerr,
    );
    if (gerr) |err| {
        defer c.g_error_free(err);
        log.warn("failed to read clipboard err={s}", .{err.message});
        return;
    }
    defer c.g_free(cstr);
    const str = std.mem.sliceTo(cstr, 0);

    self.core_surface.completeClipboardRequest(
        req.state,
        str,
        false,
    ) catch |err| switch (err) {
        error.UnsafePaste,
        error.UnauthorizedPaste,
        => {
            // Create a dialog and ask the user if they want to paste anyway.
            ClipboardConfirmationWindow.create(
                self.app,
                str,
                self.core_surface,
                req.state,
            ) catch |window_err| {
                log.err("failed to create clipboard confirmation window err={}", .{window_err});
            };
            return;
        },

        else => log.err("failed to complete clipboard request err={}", .{err}),
    };
}

fn getClipboard(widget: *c.GtkWidget, clipboard: apprt.Clipboard) ?*c.GdkClipboard {
    return switch (clipboard) {
        .standard => c.gtk_widget_get_clipboard(widget),
        .selection, .primary => c.gtk_widget_get_primary_clipboard(widget),
    };
}
pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    return self.cursor_pos;
}

pub fn showDesktopNotification(
    self: *Surface,
    title: []const u8,
    body: []const u8,
) !void {
    // Set a default title if we don't already have one
    const t = switch (title.len) {
        0 => "Ghostty",
        else => title,
    };
    const notif = c.g_notification_new(t.ptr);
    defer c.g_object_unref(notif);
    c.g_notification_set_body(notif, body.ptr);

    // Find our icon in the current icon theme. Not pretty, but the builtin GIO
    // method "g_themed_icon_new" doesn't search XDG_DATA_DIRS, so any install
    // not in /usr/share will be unable to find an icon
    const display = c.gdk_display_get_default();
    const theme = c.gtk_icon_theme_get_for_display(display);
    const icon = c.gtk_icon_theme_lookup_icon(
        theme,
        "com.mitchellh.ghostty",
        null,
        48,
        1, // Window scale
        c.GTK_TEXT_DIR_LTR,
        0,
    );
    defer c.g_object_unref(icon);
    // Get the filepath of the icon we found
    const file = c.gtk_icon_paintable_get_file(icon);
    defer c.g_object_unref(file);
    // Create a GIO icon
    const gicon = c.g_file_icon_new(file);
    defer c.g_object_unref(gicon);
    c.g_notification_set_icon(notif, gicon);

    const g_app: *c.GApplication = @ptrCast(self.app.app);

    // We set the notification ID to the body content. If the content is the
    // same, this notification may replace a previous notification
    c.g_application_send_notification(g_app, body.ptr, notif);
}

fn gtkRealize(area: *c.GtkGLArea, ud: ?*anyopaque) callconv(.C) void {
    log.debug("gl surface realized", .{});

    // We need to make the context current so we can call GL functions.
    c.gtk_gl_area_make_current(area);
    if (c.gtk_gl_area_get_error(area)) |err| {
        log.err("surface failed to realize: {s}", .{err.*.message});
        return;
    }

    // realize means that our OpenGL context is ready, so we can now
    // initialize the core surface which will setup the renderer.
    const self = userdataSelf(ud.?);
    self.realize() catch |err| {
        // TODO: we need to destroy the GL area here.
        log.err("surface failed to realize: {}", .{err});
        return;
    };

    // When we have a realized surface, we also attach our input method context.
    // We do this here instead of init because this allows us to relase the ref
    // to the GLArea when we unrealized.
    c.gtk_im_context_set_client_widget(self.im_context, @ptrCast(self.gl_area));
}

/// This is called when the underlying OpenGL resources must be released.
/// This is usually due to the OpenGL area changing GDK surfaces.
fn gtkUnrealize(area: *c.GtkGLArea, ud: ?*anyopaque) callconv(.C) void {
    _ = area;

    log.debug("gl surface unrealized", .{});
    const self = userdataSelf(ud.?);
    self.core_surface.renderer.displayUnrealized();

    // See gtkRealize for why we do this here.
    c.gtk_im_context_set_client_widget(self.im_context, null);
}

/// render signal
fn gtkRender(area: *c.GtkGLArea, ctx: *c.GdkGLContext, ud: ?*anyopaque) callconv(.C) c.gboolean {
    _ = area;
    _ = ctx;

    const self = userdataSelf(ud.?);
    self.render() catch |err| {
        log.err("surface failed to render: {}", .{err});
        return 0;
    };

    return 1;
}

/// render signal
fn gtkResize(area: *c.GtkGLArea, width: c.gint, height: c.gint, ud: ?*anyopaque) callconv(.C) void {
    const self = userdataSelf(ud.?);

    // Some debug output to help understand what GTK is telling us.
    {
        const scale_factor = scale: {
            const widget = @as(*c.GtkWidget, @ptrCast(area));
            break :scale c.gtk_widget_get_scale_factor(widget);
        };

        const window_scale_factor = scale: {
            const window = self.container.window() orelse break :scale 0;
            const gdk_surface = c.gtk_native_get_surface(@ptrCast(window.window));
            break :scale c.gdk_surface_get_scale_factor(gdk_surface);
        };

        log.debug("gl resize width={} height={} scale={} window_scale={}", .{
            width,
            height,
            scale_factor,
            window_scale_factor,
        });
    }

    self.size = .{
        .width = @intCast(width),
        .height = @intCast(height),
    };

    // We also update the content scale because there is no signal for
    // content scale change and it seems to trigger a resize event.
    if (self.getContentScale()) |scale| {
        self.core_surface.contentScaleCallback(scale) catch |err| {
            log.err("error in content scale callback err={}", .{err});
            return;
        };
    } else |_| {}

    // Call the primary callback.
    if (self.realized) {
        self.core_surface.sizeCallback(self.size) catch |err| {
            log.err("error in size callback err={}", .{err});
            return;
        };
    }
}

/// "destroy" signal for surface
fn gtkDestroy(v: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
    _ = v;
    log.debug("gl destroy", .{});

    const self = userdataSelf(ud.?);
    const alloc = self.app.core_app.alloc;
    self.deinit();
    alloc.destroy(self);
}

/// Scale x/y by the GDK device scale.
fn scaledCoordinates(
    self: *const Surface,
    x: c.gdouble,
    y: c.gdouble,
) struct {
    x: c.gdouble,
    y: c.gdouble,
} {
    const scale_factor: f64 = @floatFromInt(
        c.gtk_widget_get_scale_factor(@ptrCast(self.gl_area)),
    );

    return .{
        .x = x * scale_factor,
        .y = y * scale_factor,
    };
}

fn gtkMouseDown(
    gesture: *c.GtkGestureClick,
    _: c.gint,
    _: c.gdouble,
    _: c.gdouble,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self = userdataSelf(ud.?);
    const event = c.gtk_event_controller_get_current_event(@ptrCast(gesture));
    const gtk_mods = c.gdk_event_get_modifier_state(event);

    const button = translateMouseButton(c.gtk_gesture_single_get_current_button(@ptrCast(gesture)));
    const mods = translateMods(gtk_mods);

    // If we don't have focus, grab it.
    const gl_widget = @as(*c.GtkWidget, @ptrCast(self.gl_area));
    if (c.gtk_widget_has_focus(gl_widget) == 0) {
        self.grabFocus();
    }

    self.core_surface.mouseButtonCallback(.press, button, mods) catch |err| {
        log.err("error in key callback err={}", .{err});
        return;
    };
}

fn gtkMouseUp(
    gesture: *c.GtkGestureClick,
    _: c.gint,
    _: c.gdouble,
    _: c.gdouble,
    ud: ?*anyopaque,
) callconv(.C) void {
    const event = c.gtk_event_controller_get_current_event(@ptrCast(gesture));
    const gtk_mods = c.gdk_event_get_modifier_state(event);

    const button = translateMouseButton(c.gtk_gesture_single_get_current_button(@ptrCast(gesture)));
    const mods = translateMods(gtk_mods);

    const self = userdataSelf(ud.?);
    self.core_surface.mouseButtonCallback(.release, button, mods) catch |err| {
        log.err("error in key callback err={}", .{err});
        return;
    };
}

fn gtkMouseMotion(
    _: *c.GtkEventControllerMotion,
    x: c.gdouble,
    y: c.gdouble,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self = userdataSelf(ud.?);
    const scaled = self.scaledCoordinates(x, y);

    self.cursor_pos = .{
        .x = @floatCast(@max(0, scaled.x)),
        .y = @floatCast(scaled.y),
    };

    self.core_surface.cursorPosCallback(self.cursor_pos) catch |err| {
        log.err("error in cursor pos callback err={}", .{err});
        return;
    };
}

fn gtkMouseScroll(
    _: *c.GtkEventControllerScroll,
    x: c.gdouble,
    y: c.gdouble,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self = userdataSelf(ud.?);
    const scaled = self.scaledCoordinates(x, y);

    // GTK doesn't support any of the scroll mods.
    const scroll_mods: input.ScrollMods = .{};

    self.core_surface.scrollCallback(
        scaled.x,
        scaled.y * -1,
        scroll_mods,
    ) catch |err| {
        log.err("error in scroll callback err={}", .{err});
        return;
    };
}

fn gtkKeyPressed(
    ec_key: *c.GtkEventControllerKey,
    keyval: c.guint,
    keycode: c.guint,
    gtk_mods: c.GdkModifierType,
    ud: ?*anyopaque,
) callconv(.C) c.gboolean {
    return if (keyEvent(.press, ec_key, keyval, keycode, gtk_mods, ud)) 1 else 0;
}

fn gtkKeyReleased(
    ec_key: *c.GtkEventControllerKey,
    keyval: c.guint,
    keycode: c.guint,
    state: c.GdkModifierType,
    ud: ?*anyopaque,
) callconv(.C) c.gboolean {
    return if (keyEvent(.release, ec_key, keyval, keycode, state, ud)) 1 else 0;
}

/// Key press event. This is where we do ALL of our key handling,
/// translation to keyboard layouts, dead key handling, etc. Key handling
/// is complicated so this comment will explain what's going on.
///
/// At a high level, we want to construct an `input.KeyEvent` and
/// pass that to `keyCallback`. At a low level, this is more complicated
/// than it appears because we need to construct all of this information
/// and its not given to us.
///
/// For press events, we run the keypress through the input method context
/// in order to determine if we're in a dead key state, completed unicode
/// char, etc. This all happens through various callbacks: preedit, commit,
/// etc. These inspect "in_keypress" if they have to and set some instance
/// state.
///
/// We then take all of the information in order to determine if we have
/// a unicode character or if we have to map the keyval to a code to
/// get the underlying logical key, etc.
///
/// Finally, we can emit the keyCallback.
///
/// Note we ALSO have an IMContext attached directly to the widget
/// which can emit preedit and commit callbacks. But, if we're not
/// in a keypress, we let those automatically work.
fn keyEvent(
    action: input.Action,
    ec_key: *c.GtkEventControllerKey,
    keyval: c.guint,
    keycode: c.guint,
    gtk_mods: c.GdkModifierType,
    ud: ?*anyopaque,
) bool {
    const self = userdataSelf(ud.?);
    const keyval_unicode = c.gdk_keyval_to_unicode(keyval);
    const event = c.gtk_event_controller_get_current_event(@ptrCast(ec_key));
    const display = c.gtk_widget_get_display(@ptrCast(self.gl_area));

    // Get the unshifted unicode value of the keyval. This is used
    // by the Kitty keyboard protocol.
    const keyval_unicode_unshifted: u21 = unshifted: {
        // We need to get the currently active keyboard layout so we know
        // what group to look at.
        const layout = c.gdk_key_event_get_layout(@ptrCast(event));

        // Get all the possible keyboard mappings for this keycode. A keycode
        // is the physical key pressed.
        var keys: [*]c.GdkKeymapKey = undefined;
        var keyvals: [*]c.guint = undefined;
        var n_keys: c_int = 0;
        if (c.gdk_display_map_keycode(
            display,
            keycode,
            @ptrCast(&keys),
            @ptrCast(&keyvals),
            &n_keys,
        ) == 0) break :unshifted 0;

        defer c.g_free(keys);
        defer c.g_free(keyvals);

        // debugging:
        // log.debug("layout={}", .{layout});
        // for (0..@intCast(n_keys)) |i| {
        //     log.debug("keymap key={} codepoint={x}", .{
        //         keys[i],
        //         c.gdk_keyval_to_unicode(keyvals[i]),
        //     });
        // }

        for (0..@intCast(n_keys)) |i| {
            if (keys[i].group == layout and
                keys[i].level == 0)
            {
                break :unshifted std.math.cast(
                    u21,
                    c.gdk_keyval_to_unicode(keyvals[i]),
                ) orelse 0;
            }
        }

        break :unshifted 0;
    };

    // We always reset our committed text when ending a keypress so that
    // future keypresses don't think we have a commit event.
    defer self.im_len = 0;

    // We only want to send the event through the IM context if we're a press
    if (action == .press or action == .repeat) {
        // This can trigger an input method so we need to notify the im context
        // where the cursor is so it can render the dropdowns in the correct
        // place.
        const ime_point = self.core_surface.imePoint();
        c.gtk_im_context_set_cursor_location(self.im_context, &.{
            .x = @intFromFloat(ime_point.x),
            .y = @intFromFloat(ime_point.y),
            .width = 1,
            .height = 1,
        });

        // We mark that we're in a keypress event. We use this in our
        // IM commit callback to determine if we need to send a char callback
        // to the core surface or not.
        self.in_keypress = true;
        defer self.in_keypress = false;

        // Pass the event through the IM controller to handle dead key states.
        // Filter is true if the event was handled by the IM controller.
        const im_handled = c.gtk_im_context_filter_keypress(self.im_context, event) != 0;
        // log.warn("im_handled={} im_len={} im_composing={}", .{ im_handled, self.im_len, self.im_composing });

        // If this is a dead key, then we're composing a character and
        // we need to set our proper preedit state.
        if (self.im_composing) preedit: {
            const text = self.im_buf[0..self.im_len];
            self.core_surface.preeditCallback(text) catch |err| {
                log.err("error in preedit callback err={}", .{err});
                break :preedit;
            };

            // If we're composing then we don't want to send the key
            // event to the core surface so we always return immediately.
            if (im_handled) return true;
        } else {
            // If we aren't composing, then we set our preedit to
            // empty no matter what.
            self.core_surface.preeditCallback(null) catch {};

            // If the IM handled this and we have no text, then we just
            // return because this probably just changed the input method
            // or something.
            if (im_handled and self.im_len == 0) return true;
        }
    }

    // We want to get the physical unmapped key to process physical keybinds.
    // (These are keybinds explicitly marked as requesting physical mapping).
    const physical_key = keycode: for (input.keycodes.entries) |entry| {
        if (entry.native == keycode) break :keycode entry.key;
    } else .invalid;

    const mods = mods: {
        const device = c.gdk_event_get_device(event);

        var mods = if (self.app.x11_xkb) |xkb|
            // Add any modifier state events from Xkb if we have them (X11
            // only). Null back from the Xkb call means there was no modifier
            // event to read. This likely means that the key event did not
            // result in a modifier change and we can safely rely on the GDK
            // state.
            xkb.modifier_state_from_notify(display) orelse translateMods(gtk_mods)
        else
            // On Wayland, we have to use the GDK device because the mods sent
            // to this event do not have the modifier key applied if it was
            // presssed (i.e. left control).
            translateMods(c.gdk_device_get_modifier_state(device));

        mods.num_lock = c.gdk_device_get_num_lock_state(device) == 1;

        switch (physical_key) {
            .left_shift => mods.sides.shift = .left,
            .right_shift => mods.sides.shift = .right,
            .left_control => mods.sides.ctrl = .left,
            .right_control => mods.sides.ctrl = .right,
            .left_alt => mods.sides.alt = .left,
            .right_alt => mods.sides.alt = .right,
            .left_super => mods.sides.super = .left,
            .right_super => mods.sides.super = .right,
            else => {},
        }

        break :mods mods;
    };

    // Get our consumed modifiers
    const consumed_mods: input.Mods = consumed: {
        const raw = c.gdk_key_event_get_consumed_modifiers(event);
        const masked = raw & c.GDK_MODIFIER_MASK;
        break :consumed translateMods(masked);
    };

    // If we're not in a dead key state, we want to translate our text
    // to some input.Key.
    const key = if (!self.im_composing) key: {
        // First, try to convert the keyval directly to a key. This allows the
        // use of key remapping and identification of keypad numerics (as
        // opposed to their ASCII counterparts)
        if (gtk_key.keyFromKeyval(keyval)) |key| {
            break :key key;
        }

        // A completed key. If the length of the key is one then we can
        // attempt to translate it to a key enum and call the key
        // callback. First try plain ASCII.
        if (self.im_len > 0) {
            if (input.Key.fromASCII(self.im_buf[0])) |key| {
                break :key key;
            }
        }

        // If that doesn't work then we try to translate the kevval..
        if (keyval_unicode != 0) {
            if (std.math.cast(u8, keyval_unicode)) |byte| {
                if (input.Key.fromASCII(byte)) |key| {
                    break :key key;
                }
            }
        }

        // If that doesn't work we use the unshifted value...
        if (std.math.cast(u8, keyval_unicode_unshifted)) |ascii| {
            if (input.Key.fromASCII(ascii)) |key| {
                break :key key;
            }
        }

        // If we have im text then this is invalid. This means that
        // the keypress generated some character that we don't know about
        // in our key enum. We don't want to use the physical key because
        // it can be simply wrong. For example on "Turkish Q" the "i" key
        // on a US layout results in "ı" which is not the same as "i" so
        // we shouldn't use the physical key.
        if (self.im_len > 0 or keyval_unicode_unshifted != 0) break :key .invalid;

        break :key physical_key;
    } else .invalid;

    // log.debug("key pressed key={} keyval={x} physical_key={} composing={} text_len={} mods={}", .{
    //     key,
    //     keyval,
    //     physical_key,
    //     self.im_composing,
    //     self.im_len,
    //     mods,
    // });

    // If we have no UTF-8 text, we try to convert our keyval to
    // a text value. We have to do this because GTK will not process
    // "Ctrl+Shift+1" (on US keyboards) as "Ctrl+!" but instead as "".
    // But the keyval is set correctly so we can at least extract that.
    if (self.im_len == 0 and keyval_unicode > 0) im: {
        if (std.math.cast(u21, keyval_unicode)) |cp| {
            // We don't want to send control characters as IM
            // text. Control characters are handled already by
            // the encoder directly.
            if (cp < 0x20) break :im;

            if (std.unicode.utf8Encode(cp, &self.im_buf)) |len| {
                self.im_len = len;
            } else |_| {}
        }
    }

    // Invoke the core Ghostty logic to handle this input.
    const effect = self.core_surface.keyCallback(.{
        .action = action,
        .key = key,
        .physical_key = physical_key,
        .mods = mods,
        .consumed_mods = consumed_mods,
        .composing = self.im_composing,
        .utf8 = self.im_buf[0..self.im_len],
        .unshifted_codepoint = keyval_unicode_unshifted,
    }) catch |err| {
        log.err("error in key callback err={}", .{err});
        return false;
    };

    switch (effect) {
        .closed => return true,
        .ignored => {},
        .consumed => if (action == .press or action == .repeat) {
            // If we were in the composing state then we reset our context.
            // We do NOT want to reset if we're not in the composing state
            // because there is other IME state that we want to preserve,
            // such as quotation mark ordering for Chinese input.
            if (self.im_composing) {
                c.gtk_im_context_reset(self.im_context);
                self.core_surface.preeditCallback(null) catch {};
            }

            return true;
        },
    }

    return false;
}

fn gtkInputPreeditStart(
    _: *c.GtkIMContext,
    ud: ?*anyopaque,
) callconv(.C) void {
    //log.debug("preedit start", .{});
    const self = userdataSelf(ud.?);
    if (!self.in_keypress) return;

    // Mark that we are now composing a string with a dead key state.
    // We'll record the string in the preedit-changed callback.
    self.im_composing = true;
    self.im_len = 0;
}

fn gtkInputPreeditChanged(
    ctx: *c.GtkIMContext,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self = userdataSelf(ud.?);
    if (!self.in_keypress) return;

    // Get our pre-edit string that we'll use to show the user.
    var buf: [*c]u8 = undefined;
    _ = c.gtk_im_context_get_preedit_string(ctx, &buf, null, null);
    defer c.g_free(buf);
    const str = std.mem.sliceTo(buf, 0);

    // If our string becomes empty we ignore this. This can happen after
    // a commit event when the preedit is being cleared and we don't want
    // to set im_len to zero. This is safe because preeditstart always sets
    // im_len to zero.
    if (str.len == 0) return;

    // Copy the preedit string into the im_buf. This is safe because
    // commit will always overwrite this.
    self.im_len = @intCast(@min(self.im_buf.len, str.len));
    @memcpy(self.im_buf[0..self.im_len], str);
}

fn gtkInputPreeditEnd(
    _: *c.GtkIMContext,
    ud: ?*anyopaque,
) callconv(.C) void {
    //log.debug("preedit end", .{});
    const self = userdataSelf(ud.?);
    if (!self.in_keypress) return;
    self.im_composing = false;
}

fn gtkInputCommit(
    _: *c.GtkIMContext,
    bytes: [*:0]u8,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self = userdataSelf(ud.?);
    const str = std.mem.sliceTo(bytes, 0);

    // If we're in a key event, then we want to buffer the commit so
    // that we can send the proper keycallback followed by the char
    // callback.
    if (self.in_keypress) {
        if (str.len <= self.im_buf.len) {
            @memcpy(self.im_buf[0..str.len], str);
            self.im_len = @intCast(str.len);

            // log.debug("input commit len={}", .{self.im_len});
        } else {
            log.warn("not enough buffer space for input method commit", .{});
        }

        return;
    }

    // We're not in a keypress, so this was sent from an on-screen emoji
    // keyboard or someting like that. Send the characters directly to
    // the surface.
    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .invalid,
        .physical_key = .invalid,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = str,
    }) catch |err| {
        log.err("error in key callback err={}", .{err});
        return;
    };
}

fn gtkFocusEnter(_: *c.GtkEventControllerFocus, ud: ?*anyopaque) callconv(.C) void {
    const self = userdataSelf(ud.?);

    // Notify our IM context
    c.gtk_im_context_focus_in(self.im_context);

    // Notify our surface
    self.core_surface.focusCallback(true) catch |err| {
        log.err("error in focus callback err={}", .{err});
        return;
    };
}

fn gtkFocusLeave(_: *c.GtkEventControllerFocus, ud: ?*anyopaque) callconv(.C) void {
    const self = userdataSelf(ud.?);

    // Notify our IM context
    c.gtk_im_context_focus_out(self.im_context);

    self.core_surface.focusCallback(false) catch |err| {
        log.err("error in focus callback err={}", .{err});
        return;
    };
}

fn gtkCloseConfirmation(
    alert: *c.GtkMessageDialog,
    response: c.gint,
    ud: ?*anyopaque,
) callconv(.C) void {
    c.gtk_window_destroy(@ptrCast(alert));
    if (response == c.GTK_RESPONSE_YES) {
        const self = userdataSelf(ud.?);
        self.container.remove();
    }
}

fn userdataSelf(ud: *anyopaque) *Surface {
    return @ptrCast(@alignCast(ud));
}

fn translateMouseButton(button: c.guint) input.MouseButton {
    return switch (button) {
        1 => .left,
        2 => .middle,
        3 => .right,
        4 => .four,
        5 => .five,
        6 => .six,
        7 => .seven,
        8 => .eight,
        9 => .nine,
        10 => .ten,
        11 => .eleven,
        else => .unknown,
    };
}

fn translateMods(state: c.GdkModifierType) input.Mods {
    var mods: input.Mods = .{};
    if (state & c.GDK_SHIFT_MASK != 0) mods.shift = true;
    if (state & c.GDK_CONTROL_MASK != 0) mods.ctrl = true;
    if (state & c.GDK_ALT_MASK != 0) mods.alt = true;
    if (state & c.GDK_SUPER_MASK != 0) mods.super = true;

    // Lock is dependent on the X settings but we just assume caps lock.
    if (state & c.GDK_LOCK_MASK != 0) mods.caps_lock = true;
    return mods;
}
