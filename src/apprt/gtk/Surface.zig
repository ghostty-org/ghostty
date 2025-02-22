/// A surface represents one drawable terminal surface. The surface may be
/// attached to a window or it may be some other kind of surface. This struct
/// is meant to be generic to all scenarios.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../../build_config.zig");
const build_options = @import("build_options");
const configpkg = @import("../../config.zig");
const apprt = @import("../../apprt.zig");
const font = @import("../../font/main.zig");
const input = @import("../../input.zig");
const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");
const internal_os = @import("../../os/main.zig");

const App = @import("App.zig");
const Split = @import("Split.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");
const ClipboardConfirmationWindow = @import("ClipboardConfirmationWindow.zig");
const ResizeOverlay = @import("ResizeOverlay.zig");
const inspector = @import("inspector.zig");
const gtk_key = @import("key.zig");
const c = @import("c.zig").c;

const log = std.log.scoped(.gtk_surface);

/// This is detected by the OpenGL renderer to move to a single-threaded
/// draw operation. This basically puts locks around our draw path.
pub const opengl_single_threaded_draw = true;

pub const Options = struct {
    /// The parent surface to inherit settings such as font size, working
    /// directory, etc. from.
    parent: ?*CoreSurface = null,
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
                .surface => |s| s.primaryWidget(),
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
            .split_tl => |ptr| @fieldParentPtr("top_left", ptr),
            .split_br => |ptr| @fieldParentPtr("bottom_right", ptr),
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

/// Represents the URL hover widgets that show the hovered URL.
/// To explain a bit how this all works since its split across a few places:
/// We create a left/right pair of labels. The left label is shown by default,
/// and the right label is hidden. When the mouse enters the left label, we
/// show the right label. When the mouse leaves the left label, we hide the
/// right label.
///
/// The hover and styling is done with a combination of GTK event controllers
/// and CSS in style.css.
pub const URLWidget = struct {
    left: *c.GtkWidget,
    right: *c.GtkWidget,

    pub fn init(surface: *const Surface, str: [:0]const u8) URLWidget {
        // Create the left
        const left = c.gtk_label_new(str.ptr);
        c.gtk_label_set_ellipsize(@ptrCast(left), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_widget_add_css_class(@ptrCast(left), "view");
        c.gtk_widget_add_css_class(@ptrCast(left), "url-overlay");
        c.gtk_widget_add_css_class(@ptrCast(left), "left");
        c.gtk_widget_set_halign(left, c.GTK_ALIGN_START);
        c.gtk_widget_set_valign(left, c.GTK_ALIGN_END);

        // Create the right
        const right = c.gtk_label_new(str.ptr);
        c.gtk_label_set_ellipsize(@ptrCast(right), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_widget_add_css_class(@ptrCast(right), "hidden");
        c.gtk_widget_add_css_class(@ptrCast(right), "view");
        c.gtk_widget_add_css_class(@ptrCast(right), "url-overlay");
        c.gtk_widget_add_css_class(@ptrCast(right), "right");
        c.gtk_widget_set_halign(right, c.GTK_ALIGN_END);
        c.gtk_widget_set_valign(right, c.GTK_ALIGN_END);

        // Setup our mouse hover event for the left
        const ec_motion = c.gtk_event_controller_motion_new();
        errdefer c.g_object_unref(ec_motion);
        c.gtk_widget_add_controller(@ptrCast(left), ec_motion);
        _ = c.g_signal_connect_data(
            ec_motion,
            "enter",
            c.G_CALLBACK(&gtkLeftEnter),
            right,
            null,
            c.G_CONNECT_DEFAULT,
        );
        _ = c.g_signal_connect_data(
            ec_motion,
            "leave",
            c.G_CALLBACK(&gtkLeftLeave),
            right,
            null,
            c.G_CONNECT_DEFAULT,
        );

        // Show it
        c.gtk_overlay_add_overlay(@ptrCast(surface.overlay), left);
        c.gtk_overlay_add_overlay(@ptrCast(surface.overlay), right);

        return .{
            .left = left,
            .right = right,
        };
    }

    pub fn deinit(self: *URLWidget, overlay: *c.GtkOverlay) void {
        c.gtk_overlay_remove_overlay(@ptrCast(overlay), @ptrCast(self.left));
        c.gtk_overlay_remove_overlay(@ptrCast(overlay), @ptrCast(self.right));
    }

    pub fn setText(self: *const URLWidget, str: [:0]const u8) void {
        c.gtk_label_set_text(@ptrCast(self.left), str.ptr);
        c.gtk_label_set_text(@ptrCast(self.right), str.ptr);
    }

    fn gtkLeftEnter(
        _: *c.GtkEventControllerMotion,
        _: c.gdouble,
        _: c.gdouble,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        const right: *c.GtkWidget = @ptrCast(@alignCast(ud orelse return));
        c.gtk_widget_remove_css_class(@ptrCast(right), "hidden");
    }

    fn gtkLeftLeave(
        _: *c.GtkEventControllerMotion,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        const right: *c.GtkWidget = @ptrCast(@alignCast(ud orelse return));
        c.gtk_widget_add_css_class(@ptrCast(right), "hidden");
    }
};

/// Whether the surface has been realized or not yet. When a surface is
/// "realized" it means that the OpenGL context is ready and the core
/// surface has been initialized.
realized: bool = false,

/// The config to use to initialize a surface.
init_config: InitConfig,

/// The GUI container that this surface has been attached to. This
/// dictates some behaviors such as new splits, etc.
container: Container = .{ .none = {} },

/// The app we're part of
app: *App,

/// The overlay, this is the primary widget
overlay: *c.GtkOverlay,

/// Our GTK area
gl_area: *c.GtkGLArea,

/// If non-null this is the widget on the overlay that shows the URL.
url_widget: ?URLWidget = null,

/// The overlay that shows resizing information.
resize_overlay: ResizeOverlay = .{},

/// Whether or not the current surface is zoomed in (see `toggle_split_zoom`).
zoomed_in: bool = false,

/// If non-null this is the widget on the overlay which dims the surface when it is unfocused
unfocused_widget: ?*c.GtkWidget = null,

/// Any active cursor we may have
cursor: ?*c.GdkCursor = null,

/// Our title. The raw value of the title. This will be kept up to date and
/// .title will be updated if we have focus.
/// When set the text in this buf will be null-terminated, because we need to
/// pass it to GTK.
title_text: ?[:0]const u8 = null,

/// Our current working directory. We use this value for setting tooltips in
/// the headerbar subtitle if we have focus. When set, the text in this buf
/// will be null-terminated because we need to pass it to GTK.
pwd: ?[:0]const u8 = null,

/// The timer used to delay title updates in order to prevent flickering.
update_title_timer: ?c.guint = null,

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
in_keyevent: IMKeyEvent = .false,
im_context: *c.GtkIMContext,
im_composing: bool = false,
im_buf: [128]u8 = undefined,
im_len: u7 = 0,

/// The surface-specific cgroup path. See App.transient_cgroup_path for
/// details on what this is.
cgroup_path: ?[]const u8 = null,

/// The state of the key event while we're doing IM composition.
/// See gtkKeyPressed for detailed descriptions.
pub const IMKeyEvent = enum {
    /// Not in a key event.
    false,

    /// In a key event but im_composing was either true or false
    /// prior to the calling IME processing. This is important to
    /// work around different input methods calling commit and
    /// preedit end in a different order.
    composing,
    not_composing,
};

/// Configuration used for initializing the surface. We have to copy some
/// data since initialization is delayed with GTK (on realize).
pub const InitConfig = struct {
    parent: bool = false,
    pwd: ?[]const u8 = null,

    pub fn init(
        alloc: Allocator,
        app: *App,
        opts: Options,
    ) Allocator.Error!InitConfig {
        const parent = opts.parent orelse return .{};

        const pwd: ?[]const u8 = if (app.config.@"window-inherit-working-directory")
            try parent.pwd(alloc)
        else
            null;
        errdefer if (pwd) |p| alloc.free(p);

        return .{
            .parent = true,
            .pwd = pwd,
        };
    }

    pub fn deinit(self: *InitConfig, alloc: Allocator) void {
        if (self.pwd) |pwd| alloc.free(pwd);
    }
};

pub fn create(alloc: Allocator, app: *App, opts: Options) !*Surface {
    var surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);
    try surface.init(app, opts);
    return surface;
}

pub fn init(self: *Surface, app: *App, opts: Options) !void {
    const gl_area = c.gtk_gl_area_new();

    // Create an overlay so we can layer the GL area with other widgets.
    const overlay = c.gtk_overlay_new();
    c.gtk_overlay_set_child(@ptrCast(overlay), gl_area);

    // Overlay is not focusable, but the GL area is.
    c.gtk_widget_set_focusable(@ptrCast(overlay), 0);
    c.gtk_widget_set_focus_on_click(@ptrCast(overlay), 0);

    // We grab the floating reference to the primary widget. This allows the
    // widget tree to be moved around i.e. between a split, a tab, etc.
    // without having to be really careful about ordering to
    // prevent a destroy.
    //
    // This is unref'd in the unref() method that's called by the
    // self.container through Elem.deinit.
    _ = c.g_object_ref_sink(@ptrCast(overlay));
    errdefer c.g_object_unref(@ptrCast(overlay));

    // We want the gl area to expand to fill the parent container.
    c.gtk_widget_set_hexpand(gl_area, 1);
    c.gtk_widget_set_vexpand(gl_area, 1);

    // Various other GL properties
    c.gtk_widget_set_cursor_from_name(@ptrCast(gl_area), "text");
    c.gtk_gl_area_set_required_version(@ptrCast(gl_area), 3, 3);
    c.gtk_gl_area_set_has_stencil_buffer(@ptrCast(gl_area), 0);
    c.gtk_gl_area_set_has_depth_buffer(@ptrCast(gl_area), 0);
    c.gtk_gl_area_set_use_es(@ptrCast(gl_area), 0);

    // Key event controller will tell us about raw keypress events.
    const ec_key = c.gtk_event_controller_key_new();
    errdefer c.g_object_unref(ec_key);
    c.gtk_widget_add_controller(@ptrCast(overlay), ec_key);
    errdefer c.gtk_widget_remove_controller(@ptrCast(overlay), ec_key);

    // Focus controller will tell us about focus enter/exit events
    const ec_focus = c.gtk_event_controller_focus_new();
    errdefer c.g_object_unref(ec_focus);
    c.gtk_widget_add_controller(@ptrCast(overlay), ec_focus);
    errdefer c.gtk_widget_remove_controller(@ptrCast(overlay), ec_focus);

    // Create a second key controller so we can receive the raw
    // key-press events BEFORE the input method gets them.
    const ec_key_press = c.gtk_event_controller_key_new();
    errdefer c.g_object_unref(ec_key_press);
    c.gtk_widget_add_controller(@ptrCast(overlay), ec_key_press);
    errdefer c.gtk_widget_remove_controller(@ptrCast(overlay), ec_key_press);

    // Clicks
    const gesture_click = c.gtk_gesture_click_new();
    errdefer c.g_object_unref(gesture_click);
    c.gtk_gesture_single_set_button(@ptrCast(gesture_click), 0);
    c.gtk_widget_add_controller(@ptrCast(@alignCast(overlay)), @ptrCast(gesture_click));

    // Mouse movement
    const ec_motion = c.gtk_event_controller_motion_new();
    errdefer c.g_object_unref(ec_motion);
    c.gtk_widget_add_controller(@ptrCast(@alignCast(overlay)), ec_motion);

    // Scroll events
    const ec_scroll = c.gtk_event_controller_scroll_new(
        c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES |
            c.GTK_EVENT_CONTROLLER_SCROLL_DISCRETE,
    );
    errdefer c.g_object_unref(ec_scroll);
    c.gtk_widget_add_controller(@ptrCast(overlay), ec_scroll);

    // The input method context that we use to translate key events into
    // characters. This doesn't have an event key controller attached because
    // we call it manually from our own key controller.
    const im_context = c.gtk_im_multicontext_new();
    errdefer c.g_object_unref(im_context);

    // The GL area has to be focusable so that it can receive events
    c.gtk_widget_set_focusable(gl_area, 1);
    c.gtk_widget_set_focus_on_click(gl_area, 1);

    // Set up to handle items being dropped on our surface. Files can be dropped
    // from Nautilus and strings can be dropped from many programs.
    const drop_target = c.gtk_drop_target_new(c.G_TYPE_INVALID, c.GDK_ACTION_COPY);
    errdefer c.g_object_unref(drop_target);
    var drop_target_types = [_]c.GType{
        c.gdk_file_list_get_type(),
        c.G_TYPE_STRING,
    };
    c.gtk_drop_target_set_gtypes(drop_target, @ptrCast(&drop_target_types), drop_target_types.len);
    c.gtk_widget_add_controller(@ptrCast(overlay), @ptrCast(drop_target));

    // Inherit the parent's font size if we have a parent.
    const font_size: ?font.face.DesiredSize = font_size: {
        if (!app.config.@"window-inherit-font-size") break :font_size null;
        const parent = opts.parent orelse break :font_size null;
        break :font_size parent.font_size;
    };

    // If the parent has a transient cgroup, then we're creating cgroups
    // for each surface if we can. We need to create a child cgroup.
    const cgroup_path: ?[]const u8 = cgroup: {
        const base = app.transient_cgroup_base orelse break :cgroup null;

        // For the unique group name we use the self pointer. This may
        // not be a good idea for security reasons but not sure yet. We
        // may want to change this to something else eventually to be safe.
        var buf: [256]u8 = undefined;
        const name = std.fmt.bufPrint(
            &buf,
            "surfaces/{X}.scope",
            .{@intFromPtr(self)},
        ) catch unreachable;

        // Create the cgroup. If it fails, no big deal... just ignore.
        internal_os.cgroup.create(base, name, null) catch |err| {
            log.err("failed to create surface cgroup err={}", .{err});
            break :cgroup null;
        };

        // Success, save the cgroup path.
        break :cgroup std.fmt.allocPrint(
            app.core_app.alloc,
            "{s}/{s}",
            .{ base, name },
        ) catch null;
    };
    errdefer if (cgroup_path) |path| app.core_app.alloc.free(path);

    // Build our initialization config
    const init_config = try InitConfig.init(app.core_app.alloc, app, opts);
    errdefer init_config.deinit(app.core_app.alloc);

    // Build our result
    self.* = .{
        .app = app,
        .container = .{ .none = {} },
        .overlay = @ptrCast(overlay),
        .gl_area = @ptrCast(gl_area),
        .resize_overlay = ResizeOverlay.init(self),
        .title_text = null,
        .core_surface = undefined,
        .font_size = font_size,
        .init_config = init_config,
        .size = .{ .width = 800, .height = 600 },
        .cursor_pos = .{ .x = -1, .y = -1 },
        .im_context = im_context,
        .cgroup_path = cgroup_path,
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
    _ = c.g_signal_connect_data(ec_motion, "leave", c.G_CALLBACK(&gtkMouseLeave), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(ec_scroll, "scroll", c.G_CALLBACK(&gtkMouseScroll), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(im_context, "preedit-start", c.G_CALLBACK(&gtkInputPreeditStart), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(im_context, "preedit-changed", c.G_CALLBACK(&gtkInputPreeditChanged), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(im_context, "preedit-end", c.G_CALLBACK(&gtkInputPreeditEnd), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(im_context, "commit", c.G_CALLBACK(&gtkInputCommit), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(drop_target, "drop", c.G_CALLBACK(&gtkDrop), self, null, c.G_CONNECT_DEFAULT);
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
    var config = try apprt.surface.newConfig(self.app.core_app, &self.app.config);
    defer config.deinit();

    if (self.init_config.pwd) |pwd| {
        // If we have a working directory we want, then we force that.
        config.@"working-directory" = pwd;
    } else if (!self.init_config.parent) {
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
        try self.core_surface.setFontSize(size);
    }

    // Note we're realized
    self.realized = true;
}

pub fn deinit(self: *Surface) void {
    self.init_config.deinit(self.app.core_app.alloc);
    if (self.title_text) |title| self.app.core_app.alloc.free(title);
    if (self.pwd) |pwd| self.app.core_app.alloc.free(pwd);

    // We don't allocate anything if we aren't realized.
    if (!self.realized) return;

    // Delete our inspector if we have one
    self.controlInspector(.hide);

    // Remove ourselves from the list of known surfaces in the app.
    self.app.core_app.deleteSurface(self);

    // Clean up our core surface so that all the rendering and IO stop.
    self.core_surface.deinit();
    self.core_surface = undefined;

    if (self.cgroup_path) |path| self.app.core_app.alloc.free(path);

    // Free all our GTK stuff
    //
    // Note we don't do anything with the "unfocused_overlay" because
    // it is attached to the overlay which by this point has been destroyed
    // and therefore the unfocused_overlay has been destroyed as well.
    c.g_object_unref(self.im_context);
    if (self.cursor) |cursor| c.g_object_unref(cursor);
    if (self.update_title_timer) |timer| _ = c.g_source_remove(timer);
    self.resize_overlay.deinit();
}

// unref removes the long-held reference to the gl_area and kicks off the
// deinit/destroy process for this surface.
pub fn unref(self: *Surface) void {
    c.g_object_unref(self.overlay);
}

pub fn destroy(self: *Surface, alloc: Allocator) void {
    self.deinit();
    alloc.destroy(self);
}

pub fn primaryWidget(self: *Surface) *c.GtkWidget {
    return @ptrCast(@alignCast(self.overlay));
}

fn render(self: *Surface) !void {
    try self.core_surface.renderer.drawFrame(self);
}

/// Called by core surface to get the cgroup.
pub fn cgroup(self: *const Surface) ?[]const u8 {
    return self.cgroup_path;
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
    self.setSplitZoom(false);

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

pub fn controlInspector(
    self: *Surface,
    mode: apprt.action.Inspector,
) void {
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

pub fn getTitleLabel(self: *Surface) ?*c.GtkWidget {
    switch (self.title) {
        .none => return null,
        .label => |label| {
            const widget = @as(*c.GtkWidget, @ptrCast(@alignCast(label)));
            return widget;
        },
    }
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

    // Also scale using font-specific DPI, which is often exposed to the user
    // via DE accessibility settings (see https://docs.gtk.org/gtk4/class.Settings.html).
    const xft_dpi_scale = xft_scale: {
        // gtk-xft-dpi is font DPI multiplied by 1024. See
        // https://docs.gtk.org/gtk4/property.Settings.gtk-xft-dpi.html
        const settings = c.gtk_settings_get_default();

        var value: c.GValue = std.mem.zeroes(c.GValue);
        defer c.g_value_unset(&value);
        _ = c.g_value_init(&value, c.G_TYPE_INT);
        c.g_object_get_property(@ptrCast(@alignCast(settings)), "gtk-xft-dpi", &value);
        const gtk_xft_dpi = c.g_value_get_int(&value);

        // As noted above gtk-xft-dpi is multiplied by 1024, so we divide by
        // 1024, then divide by the default value (96) to derive a scale. Note
        // gtk-xft-dpi can be fractional, so we use floating point math here.
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
    // If we are within a split, do not set the size.
    if (self.container.split() != null) return;

    // This operation only makes sense if we're within a window view
    // hierarchy and we're the first tab in the window.
    const window = self.container.window() orelse return;
    if (window.notebook.nPages() > 1) return;

    // Note: this doesn't properly take into account the window decorations.
    // I'm not currently sure how to do that.
    c.gtk_window_set_default_size(
        @ptrCast(window.window),
        @intCast(width),
        @intCast(height),
    );
}

pub fn setSizeLimits(self: *const Surface, min: apprt.SurfaceSize, max_: ?apprt.SurfaceSize) !void {

    // There's no support for setting max size at the moment.
    _ = max_;

    // If we are within a split, do not set the size.
    if (self.container.split() != null) return;

    // This operation only makes sense if we're within a window view
    // hierarchy and we're the first tab in the window.
    const window = self.container.window() orelse return;
    if (window.notebook.nPages() > 1) return;

    // Note: this doesn't properly take into account the window decorations.
    // I'm not currently sure how to do that.
    c.gtk_widget_set_size_request(
        @ptrCast(window.window),
        @intCast(min.width),
        @intCast(min.height),
    );
}

pub fn grabFocus(self: *Surface) void {
    if (self.container.tab()) |tab| {
        // If any other surface was focused and zoomed in, set it to non zoomed in
        // so that self can grab focus.
        if (tab.focus_child) |focus_child| {
            if (focus_child.zoomed_in and focus_child != self) {
                focus_child.setSplitZoom(false);
            }
        }
        tab.focus_child = self;
    }

    const widget = @as(*c.GtkWidget, @ptrCast(self.gl_area));
    _ = c.gtk_widget_grab_focus(widget);

    self.updateTitleLabels();
}

fn updateTitleLabels(self: *Surface) void {
    // If we have no title, then we have nothing to update.
    const title = self.getTitle() orelse return;

    // If we have a tab and are the focused child, then we have to update the tab
    if (self.container.tab()) |tab| {
        if (tab.focus_child == self) tab.setLabelText(title);
    }

    // If we have a window and are focused, then we have to update the window title.
    if (self.container.window()) |window| {
        const widget = @as(*c.GtkWidget, @ptrCast(self.gl_area));
        if (c.gtk_widget_is_focus(widget) == 1) {
            // Changing the title somehow unhides our cursor.
            // https://github.com/ghostty-org/ghostty/issues/1419
            // I don't know a way around this yet. I've tried re-hiding the
            // cursor after setting the title but it doesn't work, I think
            // due to some gtk event loop things...
            window.setTitle(title);
        }
    }
}

const zoom_title_prefix = "🔍 ";

pub fn setTitle(self: *Surface, slice: [:0]const u8) !void {
    const alloc = self.app.core_app.alloc;

    // Always allocate with the "🔍 " at the beginning and slice accordingly
    // is the surface is zoomed in or not.
    const copy: [:0]const u8 = copy: {
        const new_title = try alloc.allocSentinel(u8, zoom_title_prefix.len + slice.len, 0);
        @memcpy(new_title[0..zoom_title_prefix.len], zoom_title_prefix);
        @memcpy(new_title[zoom_title_prefix.len..], slice);
        break :copy new_title;
    };
    errdefer alloc.free(copy);

    if (self.title_text) |old| alloc.free(old);
    self.title_text = copy;

    // delay the title update to prevent flickering
    if (self.update_title_timer) |timer| {
        if (c.g_source_remove(timer) == c.FALSE) {
            log.warn("unable to remove update title timer", .{});
        }
        self.update_title_timer = null;
    }
    self.update_title_timer = c.g_timeout_add(75, updateTitleTimerExpired, self);
}

fn updateTitleTimerExpired(ctx: ?*anyopaque) callconv(.C) c.gboolean {
    const self: *Surface = @ptrCast(@alignCast(ctx));

    self.updateTitleLabels();
    self.update_title_timer = null;

    return c.FALSE;
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    if (self.title_text) |title_text| {
        return if (self.zoomed_in)
            title_text
        else
            title_text[zoom_title_prefix.len..];
    }

    return null;
}

/// Set the current working directory of the surface.
///
/// In addition, update the tab's tooltip text, and if we are the focused child,
/// update the subtitle of the containing window.
pub fn setPwd(self: *Surface, pwd: [:0]const u8) !void {
    if (self.container.tab()) |tab| {
        tab.setTooltipText(pwd);

        if (tab.focus_child == self) {
            if (self.container.window()) |window| {
                if (self.app.config.@"window-subtitle" == .@"working-directory") window.setSubtitle(pwd);
            }
        }
    }

    const alloc = self.app.core_app.alloc;

    // Failing to set the surface's current working directory is not a big
    // deal since we just used our slice parameter which is the same value.
    if (self.pwd) |old| alloc.free(old);
    self.pwd = alloc.dupeZ(u8, pwd) catch null;
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

    // Set our new cursor. We only do this if the cursor we currently
    // have is NOT set to "none" because setting the cursor causes it
    // to become visible again.
    const gl_area_widget: *c.GtkWidget = @ptrCast(@alignCast(self.gl_area));
    if (c.gtk_widget_get_cursor(gl_area_widget) != self.app.cursor_none) {
        c.gtk_widget_set_cursor(gl_area_widget, cursor);
    }

    // Free our existing cursor
    if (self.cursor) |old| c.g_object_unref(old);
    self.cursor = cursor;
}

/// Set the visibility of the mouse cursor.
pub fn setMouseVisibility(self: *Surface, visible: bool) void {
    // Note in there that self.cursor or cursor_none may be null. That's
    // not a problem because NULL is a valid argument for set cursor
    // which means to just use the parent value.
    const gl_area_widget: *c.GtkWidget = @ptrCast(@alignCast(self.gl_area));

    if (visible) {
        c.gtk_widget_set_cursor(gl_area_widget, self.cursor);
        return;
    }

    // Set our new cursor to the app "none" cursor
    c.gtk_widget_set_cursor(gl_area_widget, self.app.cursor_none);
}

pub fn mouseOverLink(self: *Surface, uri_: ?[]const u8) void {
    const uri = uri_ orelse {
        if (self.url_widget) |*widget| {
            widget.deinit(self.overlay);
            self.url_widget = null;
        }

        return;
    };

    // We need a null-terminated string
    const alloc = self.app.core_app.alloc;
    const uriZ = alloc.dupeZ(u8, uri) catch return;
    defer alloc.free(uriZ);

    // If we have a URL widget already just change the text.
    if (self.url_widget) |widget| {
        widget.setText(uriZ);
        return;
    }

    self.url_widget = URLWidget.init(self, uriZ);
}

pub fn supportsClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard,
        .selection,
        .primary,
        => true,
    };
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
    self: *Surface,
    val: [:0]const u8,
    clipboard_type: apprt.Clipboard,
    confirm: bool,
) !void {
    if (!confirm) {
        const clipboard = getClipboard(@ptrCast(self.gl_area), clipboard_type);
        c.gdk_clipboard_set_text(clipboard, val.ptr);
        // We only toast if we are copying to the standard clipboard.
        if (clipboard_type == .standard and
            self.app.config.@"app-notifications".@"clipboard-copy")
        {
            if (self.container.window()) |window|
                window.sendToast("Copied to clipboard");
        }
        return;
    }

    ClipboardConfirmationWindow.create(
        self.app,
        val,
        &self.core_surface,
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
                &self.core_surface,
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

    const notification = c.g_notification_new(t.ptr);
    defer c.g_object_unref(notification);
    c.g_notification_set_body(notification, body.ptr);

    const icon = c.g_themed_icon_new(build_config.bundle_id);
    defer c.g_object_unref(icon);
    c.g_notification_set_icon(notification, icon);

    const pointer = c.g_variant_new_uint64(@intFromPtr(&self.core_surface));
    c.g_notification_set_default_action_and_target_value(
        notification,
        "app.present-surface",
        pointer,
    );

    const g_app: *c.GApplication = @ptrCast(self.app.app);

    // We set the notification ID to the body content. If the content is the
    // same, this notification may replace a previous notification
    c.g_application_send_notification(g_app, body.ptr, notification);
}

fn showContextMenu(self: *Surface, x: f32, y: f32) void {
    const window: *Window = self.container.window() orelse {
        log.info(
            "showContextMenu invalid for container={s}",
            .{@tagName(self.container)},
        );
        return;
    };

    // Convert surface coordinate into coordinate space of the
    // context menu's parent
    var point: c.graphene_point_t = .{ .x = x, .y = y };
    if (c.gtk_widget_compute_point(
        self.primaryWidget(),
        c.gtk_widget_get_parent(@ptrCast(window.context_menu)),
        &c.GRAPHENE_POINT_INIT(point.x, point.y),
        @ptrCast(&point),
    ) == 0) {
        log.warn("failed computing point for context menu", .{});
        return;
    }

    const rect: c.GdkRectangle = .{
        .x = @intFromFloat(point.x),
        .y = @intFromFloat(point.y),
        .width = 1,
        .height = 1,
    };

    c.gtk_popover_set_pointing_to(@ptrCast(@alignCast(window.context_menu)), &rect);
    self.app.refreshContextMenu(window.window, self.core_surface.hasSelection());
    c.gtk_popover_popup(@ptrCast(@alignCast(window.context_menu)));
}

fn gtkRealize(area: *c.GtkGLArea, ud: ?*anyopaque) callconv(.C) void {
    log.debug("gl surface realized", .{});

    // We need to make the context current so we can call GL functions.
    c.gtk_gl_area_make_current(area);
    if (c.gtk_gl_area_get_error(area)) |err| {
        log.err("surface failed to realize: {s}", .{err.*.message});
        log.warn("this error is usually due to a driver or gtk bug", .{});
        log.warn("this is a common cause of this issue: https://gitlab.gnome.org/GNOME/gtk/-/issues/4950", .{});
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
    // We do this here instead of init because this allows us to release the ref
    // to the GLArea when we unrealized.
    c.gtk_im_context_set_client_widget(self.im_context, @ptrCast(@alignCast(self.overlay)));
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

        if (self.container.window()) |window| {
            window.winproto.resizeEvent() catch |err| {
                log.warn("failed to notify window protocol of resize={}", .{err});
            };
        }

        self.resize_overlay.maybeShow();
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
    x: c.gdouble,
    y: c.gdouble,
    ud: ?*anyopaque,
) callconv(.C) void {
    const event = c.gtk_event_controller_get_current_event(@ptrCast(gesture)) orelse return;

    const self = userdataSelf(ud.?);
    const gtk_mods = c.gdk_event_get_modifier_state(event);

    const button = translateMouseButton(c.gtk_gesture_single_get_current_button(@ptrCast(gesture)));
    const mods = gtk_key.translateMods(gtk_mods);

    // If we don't have focus, grab it.
    const gl_widget = @as(*c.GtkWidget, @ptrCast(self.gl_area));
    if (c.gtk_widget_has_focus(gl_widget) == 0) {
        self.grabFocus();
    }

    const consumed = self.core_surface.mouseButtonCallback(.press, button, mods) catch |err| {
        log.err("error in key callback err={}", .{err});
        return;
    };

    // If a right click isn't consumed, mouseButtonCallback selects the hovered
    // word and returns false. We can use this to handle the context menu
    // opening under normal scenarios.
    if (!consumed and button == .right) {
        self.showContextMenu(@floatCast(x), @floatCast(y));
    }
}

fn gtkMouseUp(
    gesture: *c.GtkGestureClick,
    _: c.gint,
    _: c.gdouble,
    _: c.gdouble,
    ud: ?*anyopaque,
) callconv(.C) void {
    const event = c.gtk_event_controller_get_current_event(@ptrCast(gesture)) orelse return;

    const gtk_mods = c.gdk_event_get_modifier_state(event);

    const button = translateMouseButton(c.gtk_gesture_single_get_current_button(@ptrCast(gesture)));
    const mods = gtk_key.translateMods(gtk_mods);

    const self = userdataSelf(ud.?);
    _ = self.core_surface.mouseButtonCallback(.release, button, mods) catch |err| {
        log.err("error in key callback err={}", .{err});
        return;
    };
}

fn gtkMouseMotion(
    ec: *c.GtkEventControllerMotion,
    x: c.gdouble,
    y: c.gdouble,
    ud: ?*anyopaque,
) callconv(.C) void {
    const event = c.gtk_event_controller_get_current_event(@ptrCast(ec)) orelse return;

    const self = userdataSelf(ud.?);
    const scaled = self.scaledCoordinates(x, y);

    const pos: apprt.CursorPos = .{
        .x = @floatCast(@max(0, scaled.x)),
        .y = @floatCast(scaled.y),
    };

    // There seem to be at least two cases where GTK issues a mouse motion
    // event without the cursor actually moving:
    // 1. GLArea is resized under the mouse. This has the unfortunate
    //    side effect of causing focus to potentially change when
    //    `focus-follows-mouse` is enabled.
    // 2. The window title is updated. This can cause the mouse to unhide
    //    incorrectly when hide-mouse-when-typing is enabled.
    // To prevent incorrect behavior, we'll only grab focus and
    // continue with callback logic if the cursor has actually moved.
    const is_cursor_still = @abs(self.cursor_pos.x - pos.x) < 1 and
        @abs(self.cursor_pos.y - pos.y) < 1;

    if (!is_cursor_still) {
        // If we don't have focus, and we want it, grab it.
        const gl_widget = @as(*c.GtkWidget, @ptrCast(self.gl_area));
        if (c.gtk_widget_has_focus(gl_widget) == 0 and self.app.config.@"focus-follows-mouse") {
            self.grabFocus();
        }

        // Our pos changed, update
        self.cursor_pos = pos;

        // Get our modifiers
        const gtk_mods = c.gdk_event_get_modifier_state(event);
        const mods = gtk_key.translateMods(gtk_mods);

        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }
}

fn gtkMouseLeave(
    ec: *c.GtkEventControllerMotion,
    ud: ?*anyopaque,
) callconv(.C) void {
    const event = c.gtk_event_controller_get_current_event(@ptrCast(ec)) orelse return;

    const self = userdataSelf(ud.?);

    // Get our modifiers
    const gtk_mods = c.gdk_event_get_modifier_state(event);
    const mods = gtk_key.translateMods(gtk_mods);
    self.core_surface.cursorPosCallback(.{ .x = -1, .y = -1 }, mods) catch |err| {
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
        // We invert because we apply natural scrolling to the values.
        // This behavior has existed for years without Linux users complaining
        // but I suspect we'll have to make this configurable in the future
        // or read a system setting.
        scaled.x * -1,
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
    const self = userdataSelf(ud.?);
    return if (self.keyEvent(
        .press,
        ec_key,
        keyval,
        keycode,
        gtk_mods,
    )) 1 else 0;
}

fn gtkKeyReleased(
    ec_key: *c.GtkEventControllerKey,
    keyval: c.guint,
    keycode: c.guint,
    state: c.GdkModifierType,
    ud: ?*anyopaque,
) callconv(.C) c.gboolean {
    const self = userdataSelf(ud.?);
    return if (self.keyEvent(
        .release,
        ec_key,
        keyval,
        keycode,
        state,
    )) 1 else 0;
}

/// Key press event (press or release).
///
/// At a high level, we want to construct an `input.KeyEvent` and
/// pass that to `keyCallback`. At a low level, this is more complicated
/// than it appears because we need to construct all of this information
/// and its not given to us.
///
/// For all events, we run the GdkEvent through the input method context.
/// This allows the input method to capture the event and trigger
/// callbacks such as preedit, commit, etc.
///
/// There are a couple important aspects to the prior paragraph: we must
/// send ALL events through the input method context. This is because
/// input methods use both key press and key release events to determine
/// the state of the input method. For example, fcitx uses key release
/// events on modifiers (i.e. ctrl+shift) to switch the input method.
///
/// We set some state to note we're in a key event (self.in_keyevent)
/// because some of the input method callbacks change behavior based on
/// this state. For example, we don't want to send character events
/// like "a" via the input "commit" event if we're actively processing
/// a keypress because we'd lose access to the keycode information.
/// However, a "commit" event may still happen outside of a keypress
/// event from e.g. a tablet or on-screen keyboard.
///
/// Finally, we take all of the information in order to determine if we have
/// a unicode character or if we have to map the keyval to a code to
/// get the underlying logical key, etc.
///
/// Then we can emit the keyCallback.
pub fn keyEvent(
    self: *Surface,
    action: input.Action,
    ec_key: *c.GtkEventControllerKey,
    keyval: c.guint,
    keycode: c.guint,
    gtk_mods: c.GdkModifierType,
) bool {
    // log.warn("GTKIM: keyEvent action={}", .{action});
    const event = c.gtk_event_controller_get_current_event(
        @ptrCast(ec_key),
    ) orelse return false;

    // The block below is all related to input method handling. See the function
    // comment for some high level details and then the comments within
    // the block for more specifics.
    {
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

        // We note that we're in a keypress because we want some logic to
        // depend on this. For example, we don't want to send character events
        // like "a" via the input "commit" event if we're actively processing
        // a keypress because we'd lose access to the keycode information.
        //
        // We have to maintain some additional state here of whether we
        // were composing because different input methods call the callbacks
        // in different orders. For example, ibus calls commit THEN preedit
        // end but simple calls preedit end THEN commit.
        self.in_keyevent = if (self.im_composing) .composing else .not_composing;
        defer self.in_keyevent = .false;

        // Pass the event through the input method which returns true if handled.
        // Confusingly, not all events handled by the input method result
        // in this returning true so we have to maintain some additional
        // state about whether we were composing or not to determine if
        // we should proceed with key encoding.
        //
        // Cases where the input method does not mark the event as handled:
        //
        // - If we change the input method via keypress while we have preedit
        //   text, the input method will commit the pending text but will not
        //   mark it as handled. We use the `.composing` state to detect
        //   this case.
        //
        // - If we switch input methods (i.e. via ctrl+shift with fcitx),
        //   the input method will handle the key release event but will not
        //   mark it as handled. I don't know any way to detect this case so
        //   it will result in a key event being sent to the key callback.
        //   For Kitty text encoding, this will result in modifiers being
        //   triggered despite being technically consumed. At the time of
        //   writing, both Kitty and Alacritty have the same behavior. I
        //   know of no way to fix this.
        const im_handled = c.gtk_im_context_filter_keypress(
            self.im_context,
            event,
        ) != 0;
        // log.warn("GTKIM: im_handled={} im_len={} im_composing={}", .{
        //     im_handled,
        //     self.im_len,
        //     self.im_composing,
        // });

        // If the input method handled the event, you would think we would
        // never proceed with key encoding for Ghostty but that is not the
        // case. Input methods will handle basic character encoding like
        // typing "a" and we want to associate that with the key event.
        // So we have to check additional state to determine if we exit.
        if (im_handled) {
            // If we are composing then we're in a preedit state and do
            // not want to encode any keys. For example: type a deadkey
            // such as single quote on a US international keyboard layout.
            if (self.im_composing) return true;

            // If we were composing and now we're not it means that we committed
            // the text. We also don't want to encode a key event for this.
            // Example: enable Japanese input method, press "konn" and then
            // press enter. The final enter should not be encoded and "konn"
            // (in hiragana) should be written as "こん".
            if (self.in_keyevent == .composing) return true;

            // Not composing and our input method buffer is empty. This could
            // mean that the input method reacted to this event by activating
            // an onscreen keyboard or something equivalent. We don't know.
            // But the input method handled it and didn't give us text so
            // we will just assume we should not encode this. This handles a
            // real scenario when ibus starts the emoji input method
            // (super+.).
            if (self.im_len == 0) return true;
        }

        // At this point, for the sake of explanation of internal state:
        // it is possible that im_len > 0 and im_composing == false. This
        // means that we received a commit event from the input method that
        // we want associated with the key event. This is common: its how
        // basic character translation for simple inputs like "a" work.
    }

    // We always reset the length of the im buffer. There's only one scenario
    // we reach this point with im_len > 0 and that's if we received a commit
    // event from the input method. We don't want to keep that state around
    // since we've handled it here.
    defer self.im_len = 0;

    // Get the keyvals for this event.
    const keyval_unicode = c.gdk_keyval_to_unicode(keyval);
    const keyval_unicode_unshifted: u21 = gtk_key.keyvalUnicodeUnshifted(
        @ptrCast(self.gl_area),
        event,
        keycode,
    );

    // We want to get the physical unmapped key to process physical keybinds.
    // (These are keybinds explicitly marked as requesting physical mapping).
    const physical_key = keycode: for (input.keycodes.entries) |entry| {
        if (entry.native == keycode) break :keycode entry.key;
    } else .invalid;

    // Get our modifier for the event
    const mods: input.Mods = gtk_key.eventMods(
        event,
        physical_key,
        gtk_mods,
        action,
        &self.app.winproto,
    );

    // Get our consumed modifiers
    const consumed_mods: input.Mods = consumed: {
        const raw = c.gdk_key_event_get_consumed_modifiers(event);
        const masked = raw & c.GDK_MODIFIER_MASK;
        break :consumed gtk_key.translateMods(masked);
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
    // log.warn("GTKIM: preedit start", .{});
    const self = userdataSelf(ud.?);

    // Start our composing state for the input method and reset our
    // input buffer to empty.
    self.im_composing = true;
    self.im_len = 0;
}

fn gtkInputPreeditChanged(
    ctx: *c.GtkIMContext,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self = userdataSelf(ud.?);

    // Get our pre-edit string that we'll use to show the user.
    var buf: [*c]u8 = undefined;
    _ = c.gtk_im_context_get_preedit_string(ctx, &buf, null, null);
    defer c.g_free(buf);
    const str = std.mem.sliceTo(buf, 0);

    // Update our preedit state in Ghostty core
    // log.warn("GTKIM: preedit change str={s}", .{str});
    self.core_surface.preeditCallback(str) catch |err| {
        log.err("error in preedit callback err={}", .{err});
    };
}

fn gtkInputPreeditEnd(
    _: *c.GtkIMContext,
    ud: ?*anyopaque,
) callconv(.C) void {
    // log.warn("GTKIM: preedit end", .{});
    const self = userdataSelf(ud.?);

    // End our composing state for GTK, allowing us to commit the text.
    self.im_composing = false;

    // End our preedit state in Ghostty core
    self.core_surface.preeditCallback(null) catch |err| {
        log.err("error in preedit callback err={}", .{err});
    };
}

fn gtkInputCommit(
    _: *c.GtkIMContext,
    bytes: [*:0]u8,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self = userdataSelf(ud.?);
    const str = std.mem.sliceTo(bytes, 0);

    // log.debug("GTKIM: input commit composing={} keyevent={} str={s}", .{
    //     self.im_composing,
    //     self.in_keyevent,
    //     str,
    // });

    // We need to handle commit specially if we're in a key event.
    // Specifically, GTK will send us a commit event for basic key
    // encodings like "a" (on a US layout keyboard). We don't want
    // to treat this as IME committed text because we want to associate
    // it with a key event (i.e. "a" key press).
    switch (self.in_keyevent) {
        // If we're not in a key event then this commit is from
        // some other source (i.e. on-screen keyboard, tablet, etc.)
        // and we want to commit the text to the core surface.
        .false => {},

        // If we're in a composing state and in a key event then this
        // key event is resulting in a commit of multiple keypresses
        // and we don't want to encode it alongside the keypress.
        .composing => {},

        // If we're not composing then this commit is just a normal
        // key encoding and we want our key event to handle it so
        // that Ghostty can be aware of the key event alongside
        // the text.
        .not_composing => {
            if (str.len > self.im_buf.len) {
                log.warn("not enough buffer space for input method commit", .{});
                return;
            }

            // Copy our committed text to the buffer
            @memcpy(self.im_buf[0..str.len], str);
            self.im_len = @intCast(str.len);

            // log.debug("input commit len={}", .{self.im_len});
            return;
        },
    }

    // If we reach this point from above it means we're composing OR
    // not in a keypress. In either case, we want to commit the text
    // given to us because that's what GTK is asking us to do. If we're
    // not in a keypress it means that this commit came via a non-keyboard
    // event (i.e. on-screen keyboard, tablet of some kind, etc.).

    // Committing ends composing state
    self.im_composing = false;

    // End our preedit state. Well-behaved input methods do this for us
    // by triggering a preedit-end event but some do not (ibus 1.5.29).
    self.core_surface.preeditCallback(null) catch |err| {
        log.err("error in preedit callback err={}", .{err});
    };

    // Send the text to the core surface, associated with no key (an
    // invalid key, which should produce no PTY encoding).
    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .invalid,
        .physical_key = .invalid,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = str,
    }) catch |err| {
        log.warn("error in key callback err={}", .{err});
        return;
    };
}

fn gtkFocusEnter(_: *c.GtkEventControllerFocus, ud: ?*anyopaque) callconv(.C) void {
    const self = userdataSelf(ud.?);
    if (!self.realized) return;

    // Notify our IM context
    c.gtk_im_context_focus_in(self.im_context);

    // Remove the unfocused widget overlay, if we have one
    if (self.unfocused_widget) |widget| {
        c.gtk_overlay_remove_overlay(self.overlay, widget);
        self.unfocused_widget = null;
    }

    if (self.pwd) |pwd| {
        if (self.container.window()) |window| {
            if (self.app.config.@"window-subtitle" == .@"working-directory") window.setSubtitle(pwd);
        }
    }

    // Notify our surface
    self.core_surface.focusCallback(true) catch |err| {
        log.err("error in focus callback err={}", .{err});
        return;
    };
}

fn gtkFocusLeave(_: *c.GtkEventControllerFocus, ud: ?*anyopaque) callconv(.C) void {
    const self = userdataSelf(ud.?);
    if (!self.realized) return;

    // Notify our IM context
    c.gtk_im_context_focus_out(self.im_context);

    // We only try dimming the surface if we are a split
    switch (self.container) {
        .split_br,
        .split_tl,
        => self.dimSurface(),
        else => {},
    }

    self.core_surface.focusCallback(false) catch |err| {
        log.err("error in focus callback err={}", .{err});
        return;
    };
}

/// Adds the unfocused_widget to the overlay. If the unfocused_widget has already been added, this
/// is a no-op
pub fn dimSurface(self: *Surface) void {
    const window = self.container.window() orelse {
        log.warn("dimSurface invalid for container={}", .{self.container});
        return;
    };

    // Don't dim surface if context menu is open.
    // This means we got unfocused due to it opening.
    const context_menu_open = c.gtk_widget_get_visible(window.context_menu);
    if (context_menu_open == 1) return;

    if (self.unfocused_widget != null) return;
    self.unfocused_widget = c.gtk_drawing_area_new();
    c.gtk_widget_add_css_class(self.unfocused_widget.?, "unfocused-split");
    c.gtk_overlay_add_overlay(self.overlay, self.unfocused_widget.?);
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

pub fn present(self: *Surface) void {
    if (self.container.window()) |window| {
        if (self.container.tab()) |tab| {
            if (window.notebook.getTabPosition(tab)) |position|
                _ = window.notebook.gotoNthTab(position);
        }
        c.gtk_window_present(window.window);
    }

    self.grabFocus();
}

fn detachFromSplit(self: *Surface) void {
    const split = self.container.split() orelse return;
    switch (self.container.splitSide() orelse unreachable) {
        .top_left => split.detachTopLeft(),
        .bottom_right => split.detachBottomRight(),
    }
}

fn attachToSplit(self: *Surface) void {
    const split = self.container.split() orelse return;
    split.updateChildren();
}

pub fn setSplitZoom(self: *Surface, new_split_zoom: bool) void {
    if (new_split_zoom == self.zoomed_in) return;
    const tab = self.container.tab() orelse return;

    const tab_widget = tab.elem.widget();
    const surface_widget = self.primaryWidget();

    if (new_split_zoom) {
        self.detachFromSplit();
        c.gtk_box_remove(tab.box, tab_widget);
        c.gtk_box_append(tab.box, surface_widget);
    } else {
        c.gtk_box_remove(tab.box, surface_widget);
        self.attachToSplit();
        c.gtk_box_append(tab.box, tab_widget);
    }

    self.zoomed_in = new_split_zoom;
    self.grabFocus();
}

pub fn toggleSplitZoom(self: *Surface) void {
    self.setSplitZoom(!self.zoomed_in);
}

/// Handle items being dropped on our surface.
fn gtkDrop(
    _: *c.GtkDropTarget,
    value: *c.GValue,
    x: f64,
    y: f64,
    ud: ?*anyopaque,
) callconv(.C) c.gboolean {
    _ = x;
    _ = y;
    const self = userdataSelf(ud.?);
    const alloc = self.app.core_app.alloc;

    if (g_value_holds(value, c.G_TYPE_BOXED)) {
        var data = std.ArrayList(u8).init(alloc);
        defer data.deinit();

        var shell_escape_writer: internal_os.ShellEscapeWriter(std.ArrayList(u8).Writer) = .{
            .child_writer = data.writer(),
        };
        const writer = shell_escape_writer.writer();

        const fl: *c.GdkFileList = @ptrCast(c.g_value_get_boxed(value));
        var l = c.gdk_file_list_get_files(fl);

        while (l != null) : (l = l.*.next) {
            const file: *c.GFile = @ptrCast(l.*.data);
            const path = c.g_file_get_path(file) orelse continue;

            writer.writeAll(std.mem.span(path)) catch |err| {
                log.err("unable to write path to buffer: {}", .{err});
                continue;
            };
            writer.writeAll("\n") catch |err| {
                log.err("unable to write to buffer: {}", .{err});
                continue;
            };
        }

        const string = data.toOwnedSliceSentinel(0) catch |err| {
            log.err("unable to convert to a slice: {}", .{err});
            return 1;
        };
        defer alloc.free(string);

        self.doPaste(string);

        return 1;
    }

    if (g_value_holds(value, c.G_TYPE_STRING)) {
        if (c.g_value_get_string(value)) |string| {
            self.doPaste(std.mem.span(string));
        }
        return 1;
    }

    return 1;
}

fn doPaste(self: *Surface, data: [:0]const u8) void {
    if (data.len == 0) return;

    self.core_surface.completeClipboardRequest(.paste, data, false) catch |err| switch (err) {
        error.UnsafePaste,
        error.UnauthorizedPaste,
        => {
            ClipboardConfirmationWindow.create(
                self.app,
                data,
                &self.core_surface,
                .paste,
            ) catch |window_err| {
                log.err("failed to create clipboard confirmation window err={}", .{window_err});
            };
        },
        error.OutOfMemory,
        error.NoSpaceLeft,
        => log.err("failed to complete clipboard request err={}", .{err}),
    };
}

pub fn defaultTermioEnv(self: *Surface) !std.process.EnvMap {
    const alloc = self.app.core_app.alloc;
    var env = try internal_os.getEnvMap(alloc);
    errdefer env.deinit();

    // Don't leak these GTK environment variables to child processes.
    env.remove("GDK_DEBUG");
    env.remove("GDK_DISABLE");
    env.remove("GSK_RENDERER");

    // Unset environment varies set by snaps if we're running in a snap.
    // This allows Ghostty to further launch additional snaps.
    if (env.get("SNAP")) |_| {
        env.remove("SNAP");
        env.remove("DRIRC_CONFIGDIR");
        env.remove("__EGL_EXTERNAL_PLATFORM_CONFIG_DIRS");
        env.remove("__EGL_VENDOR_LIBRARY_DIRS");
        env.remove("LD_LIBRARY_PATH");
        env.remove("LIBGL_DRIVERS_PATH");
        env.remove("LIBVA_DRIVERS_PATH");
        env.remove("VK_LAYER_PATH");
        env.remove("XLOCALEDIR");
        env.remove("GDK_PIXBUF_MODULEDIR");
        env.remove("GTK_PATH");
    }

    if (self.container.window()) |window| {
        // On some window protocols we might want to add specific
        // environment variables to subprocesses, such as WINDOWID on X11.
        try window.winproto.addSubprocessEnv(&env);
    }

    return env;
}

/// Check a GValue to see what's type its wrapping. This is equivalent to GTK's
/// `G_VALUE_HOLDS` macro but Zig's C translator does not like it.
fn g_value_holds(value_: ?*c.GValue, g_type: c.GType) bool {
    if (value_) |value| {
        if (value.*.g_type == g_type) return true;
        return c.g_type_check_value_holds(value, g_type) != 0;
    }
    return false;
}
