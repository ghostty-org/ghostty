/// A surface represents one drawable terminal surface. The surface may be
/// attached to a window or it may be some other kind of surface. This struct
/// is meant to be generic to all scenarios.
const Surface = @This();

const std = @import("std");

const adw = @import("adw");
const gtk = @import("gtk");
const gdk = @import("gdk");
const glib = @import("glib");
const gio = @import("gio");
const gobject = @import("gobject");

const Allocator = std.mem.Allocator;
const build_config = @import("../../build_config.zig");
const build_options = @import("build_options");
const configpkg = @import("../../config.zig");
const apprt = @import("../../apprt.zig");
const font = @import("../../font/main.zig");
const i18n = @import("../../os/main.zig").i18n;
const input = @import("../../input.zig");
const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");
const internal_os = @import("../../os/main.zig");

const App = @import("App.zig");
const Split = @import("Split.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");
const Menu = @import("menu.zig").Menu;
const ClipboardConfirmationWindow = @import("ClipboardConfirmationWindow.zig");
const ResizeOverlay = @import("ResizeOverlay.zig");
const URLWidget = @import("URLWidget.zig");
const CloseDialog = @import("CloseDialog.zig");
const inspectorpkg = @import("inspector.zig");
const gtk_key = @import("key.zig");
const Builder = @import("Builder.zig");
const adw_version = @import("adw_version.zig");

const log = std.log.scoped(.gtk_surface);

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
        pub fn widget(self: Elem) *gtk.Widget {
            return switch (self) {
                .surface => |s| s.primaryWidget(),
                .split => |s| s.paned.as(gtk.Widget),
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
overlay: *gtk.Overlay,

/// Our GTK area
gl_area: *gtk.GLArea,

/// If non-null this is the widget on the overlay that shows the URL.
url_widget: ?URLWidget = null,

/// The overlay that shows resizing information.
resize_overlay: ResizeOverlay = undefined,

/// Whether or not the current surface is zoomed in (see `toggle_split_zoom`).
zoomed_in: bool = false,

/// If non-null this is the widget on the overlay which dims the surface when it is unfocused
unfocused_widget: ?*gtk.Widget = null,

/// Any active cursor we may have
cursor: ?*gdk.Cursor = null,

/// Our title. The raw value of the title. This will be kept up to date and
/// .title will be updated if we have focus.
/// When set the text in this buf will be null-terminated, because we need to
/// pass it to GTK.
title_text: ?[:0]const u8 = null,

/// The title of the surface as reported by the terminal. If it is null, the
/// title reported by the terminal is currently being used. If the title was
/// manually overridden by the user, this will be set to a non-null value
/// representing the default terminal title.
title_from_terminal: ?[:0]const u8 = null,

/// Our current working directory. We use this value for setting tooltips in
/// the headerbar subtitle if we have focus. When set, the text in this buf
/// will be null-terminated because we need to pass it to GTK.
pwd: ?[:0]const u8 = null,

/// The timer used to delay title updates in order to prevent flickering.
update_title_timer: ?c_uint = null,

/// The core surface backing this surface
core_surface: CoreSurface,

/// The font size to use for this surface once realized.
font_size: ?font.face.DesiredSize = null,

/// Cached metrics about the surface from GTK callbacks.
size: apprt.SurfaceSize,
cursor_pos: apprt.CursorPos,

/// Inspector state.
inspector: ?*inspectorpkg.Inspector = null,

/// Key input states. See gtkKeyPressed for detailed descriptions.
in_keyevent: IMKeyEvent = .false,
im_context: *gtk.IMMulticontext,
im_composing: bool = false,
im_buf: [128]u8 = undefined,
im_len: u7 = 0,

/// The surface-specific cgroup path. See App.transient_cgroup_path for
/// details on what this is.
cgroup_path: ?[]const u8 = null,

/// Our context menu.
context_menu: Menu(Surface, "context_menu", false),

/// True when we have a precision scroll in progress
precision_scroll: bool = false,

/// Flag indicating whether the surface is in secure input mode.
is_secure_input: bool = false,

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
    const gl_area = gtk.GLArea.new();
    const gl_area_widget = gl_area.as(gtk.Widget);

    // Create an overlay so we can layer the GL area with other widgets.
    const overlay = gtk.Overlay.new();
    errdefer overlay.unref();
    const overlay_widget = overlay.as(gtk.Widget);
    overlay.setChild(gl_area_widget);

    // Overlay is not focusable, but the GL area is.
    overlay_widget.setFocusable(0);
    overlay_widget.setFocusOnClick(0);

    // We grab the floating reference to the primary widget. This allows the
    // widget tree to be moved around i.e. between a split, a tab, etc.
    // without having to be really careful about ordering to
    // prevent a destroy.
    //
    // This is unref'd in the unref() method that's called by the
    // self.container through Elem.deinit.
    _ = overlay.as(gobject.Object).refSink();
    errdefer overlay.unref();

    // We want the gl area to expand to fill the parent container.
    gl_area_widget.setHexpand(1);
    gl_area_widget.setVexpand(1);

    // Various other GL properties
    gl_area_widget.setCursorFromName("text");
    gl_area.setRequiredVersion(
        renderer.OpenGL.MIN_VERSION_MAJOR,
        renderer.OpenGL.MIN_VERSION_MINOR,
    );
    gl_area.setHasStencilBuffer(0);
    gl_area.setHasDepthBuffer(0);
    gl_area.setUseEs(0);

    // Key event controller will tell us about raw keypress events.
    const ec_key = gtk.EventControllerKey.new();
    errdefer ec_key.unref();
    overlay_widget.addController(ec_key.as(gtk.EventController));
    errdefer overlay_widget.removeController(ec_key.as(gtk.EventController));

    // Focus controller will tell us about focus enter/exit events
    const ec_focus = gtk.EventControllerFocus.new();
    errdefer ec_focus.unref();
    overlay_widget.addController(ec_focus.as(gtk.EventController));
    errdefer overlay_widget.removeController(ec_focus.as(gtk.EventController));

    // Create a second key controller so we can receive the raw
    // key-press events BEFORE the input method gets them.
    const ec_key_press = gtk.EventControllerKey.new();
    errdefer ec_key_press.unref();
    overlay_widget.addController(ec_key_press.as(gtk.EventController));
    errdefer overlay_widget.removeController(ec_key_press.as(gtk.EventController));

    // Clicks
    const gesture_click = gtk.GestureClick.new();
    errdefer gesture_click.unref();
    gesture_click.as(gtk.GestureSingle).setButton(0);
    overlay_widget.addController(gesture_click.as(gtk.EventController));
    errdefer overlay_widget.removeController(gesture_click.as(gtk.EventController));

    // Mouse movement
    const ec_motion = gtk.EventControllerMotion.new();
    errdefer ec_motion.unref();
    overlay_widget.addController(ec_motion.as(gtk.EventController));
    errdefer overlay_widget.removeController(ec_motion.as(gtk.EventController));

    // Scroll events
    const ec_scroll = gtk.EventControllerScroll.new(.flags_both_axes);
    errdefer ec_scroll.unref();
    overlay_widget.addController(ec_scroll.as(gtk.EventController));
    errdefer overlay_widget.removeController(ec_scroll.as(gtk.EventController));

    // The input method context that we use to translate key events into
    // characters. This doesn't have an event key controller attached because
    // we call it manually from our own key controller.
    const im_context = gtk.IMMulticontext.new();
    errdefer im_context.unref();

    // The GL area has to be focusable so that it can receive events
    gl_area_widget.setFocusable(1);
    gl_area_widget.setFocusOnClick(1);

    // Set up to handle items being dropped on our surface. Files can be dropped
    // from Nautilus and strings can be dropped from many programs.
    const drop_target = gtk.DropTarget.new(gobject.ext.types.invalid, .flags_copy);
    errdefer drop_target.unref();
    // The order of the types matters.
    var drop_target_types = [_]gobject.Type{
        gdk.FileList.getGObjectType(),
        gio.File.getGObjectType(),
        gobject.ext.types.string,
    };
    drop_target.setGtypes(&drop_target_types, drop_target_types.len);
    overlay_widget.addController(drop_target.as(gtk.EventController));
    errdefer overlay_widget.removeController(drop_target.as(gtk.EventController));

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
        .overlay = overlay,
        .gl_area = gl_area,
        .resize_overlay = undefined,
        .title_text = null,
        .core_surface = undefined,
        .font_size = font_size,
        .init_config = init_config,
        .size = .{ .width = 800, .height = 600 },
        .cursor_pos = .{ .x = -1, .y = -1 },
        .im_context = im_context,
        .cgroup_path = cgroup_path,
        .context_menu = undefined,
    };
    errdefer self.* = undefined;

    // initialize the context menu
    self.context_menu.init(self);
    self.context_menu.setParent(overlay.as(gtk.Widget));

    // initialize the resize overlay
    self.resize_overlay.init(self, &app.config);

    // Set our default mouse shape
    try self.setMouseShape(.text);

    // GL events
    _ = gtk.Widget.signals.realize.connect(
        gl_area,
        *Surface,
        gtkRealize,
        self,
        .{},
    );
    _ = gtk.Widget.signals.unrealize.connect(
        gl_area,
        *Surface,
        gtkUnrealize,
        self,
        .{},
    );
    _ = gtk.Widget.signals.destroy.connect(
        gl_area,
        *Surface,
        gtkDestroy,
        self,
        .{},
    );
    _ = gtk.GLArea.signals.render.connect(
        gl_area,
        *Surface,
        gtkRender,
        self,
        .{},
    );
    _ = gtk.GLArea.signals.resize.connect(
        gl_area,
        *Surface,
        gtkResize,
        self,
        .{},
    );
    _ = gtk.EventControllerKey.signals.key_pressed.connect(
        ec_key_press,
        *Surface,
        gtkKeyPressed,
        self,
        .{},
    );
    _ = gtk.EventControllerKey.signals.key_released.connect(
        ec_key_press,
        *Surface,
        gtkKeyReleased,
        self,
        .{},
    );
    _ = gtk.EventControllerFocus.signals.enter.connect(
        ec_focus,
        *Surface,
        gtkFocusEnter,
        self,
        .{},
    );
    _ = gtk.EventControllerFocus.signals.leave.connect(
        ec_focus,
        *Surface,
        gtkFocusLeave,
        self,
        .{},
    );
    _ = gtk.GestureClick.signals.pressed.connect(
        gesture_click,
        *Surface,
        gtkMouseDown,
        self,
        .{},
    );
    _ = gtk.GestureClick.signals.released.connect(
        gesture_click,
        *Surface,
        gtkMouseUp,
        self,
        .{},
    );
    _ = gtk.EventControllerMotion.signals.motion.connect(
        ec_motion,
        *Surface,
        gtkMouseMotion,
        self,
        .{},
    );
    _ = gtk.EventControllerMotion.signals.leave.connect(
        ec_motion,
        *Surface,
        gtkMouseLeave,
        self,
        .{},
    );
    _ = gtk.EventControllerScroll.signals.scroll.connect(
        ec_scroll,
        *Surface,
        gtkMouseScroll,
        self,
        .{},
    );
    _ = gtk.EventControllerScroll.signals.scroll_begin.connect(
        ec_scroll,
        *Surface,
        gtkMouseScrollPrecisionBegin,
        self,
        .{},
    );
    _ = gtk.EventControllerScroll.signals.scroll_end.connect(
        ec_scroll,
        *Surface,
        gtkMouseScrollPrecisionEnd,
        self,
        .{},
    );
    _ = gtk.IMContext.signals.preedit_start.connect(
        im_context,
        *Surface,
        gtkInputPreeditStart,
        self,
        .{},
    );
    _ = gtk.IMContext.signals.preedit_changed.connect(
        im_context,
        *Surface,
        gtkInputPreeditChanged,
        self,
        .{},
    );
    _ = gtk.IMContext.signals.preedit_end.connect(
        im_context,
        *Surface,
        gtkInputPreeditEnd,
        self,
        .{},
    );
    _ = gtk.IMContext.signals.commit.connect(
        im_context,
        *Surface,
        gtkInputCommit,
        self,
        .{},
    );
    _ = gtk.DropTarget.signals.drop.connect(
        drop_target,
        *Surface,
        gtkDrop,
        self,
        .{},
    );
}

fn realize(self: *Surface) !void {
    // If this surface has already been realized, then we don't need to
    // reinitialize. This can happen if a surface is moved from one GDK
    // surface to another (i.e. a tab is pulled out into a window).
    if (self.realized) {
        // If we have no OpenGL state though, we do need to reinitialize.
        // We allow the renderer to figure that out, and then queue a draw.
        try self.core_surface.renderer.displayRealized();
        self.redraw();
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
    if (self.title_from_terminal) |title| self.app.core_app.alloc.free(title);
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

    // Remove the cgroup if we have one. We do this after deiniting the core
    // surface to ensure all processes have exited.
    if (self.cgroup_path) |path| {
        internal_os.cgroup.remove(path) catch |err| {
            // We don't want this to be fatal in any way so we just log
            // and continue. A dangling empty cgroup is not a big deal
            // and this should be rare.
            log.warn(
                "failed to remove cgroup for surface path={s} err={}",
                .{ path, err },
            );
        };

        self.app.core_app.alloc.free(path);
    }

    // Free all our GTK stuff
    //
    // Note we don't do anything with the "unfocused_overlay" because
    // it is attached to the overlay which by this point has been destroyed
    // and therefore the unfocused_overlay has been destroyed as well.
    self.im_context.unref();
    if (self.cursor) |cursor| cursor.unref();
    if (self.update_title_timer) |timer| _ = glib.Source.remove(timer);
    self.resize_overlay.deinit();
}

/// Update our local copy of any configuration that we use.
pub fn updateConfig(self: *Surface, config: *const configpkg.Config) !void {
    self.resize_overlay.updateConfig(config);
}

// unref removes the long-held reference to the gl_area and kicks off the
// deinit/destroy process for this surface.
pub fn unref(self: *Surface) void {
    self.overlay.unref();
}

pub fn destroy(self: *Surface, alloc: Allocator) void {
    self.deinit();
    alloc.destroy(self);
}

pub fn primaryWidget(self: *Surface) *gtk.Widget {
    return self.overlay.as(gtk.Widget);
}

fn render(self: *Surface) !void {
    try self.core_surface.renderer.drawFrame(true);
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
    self.gl_area.queueRender();
}

/// Close this surface.
pub fn close(self: *Surface, process_active: bool) void {
    self.closeWithConfirmation(process_active, .{ .surface = self });
}

/// Close this surface.
pub fn closeWithConfirmation(self: *Surface, process_active: bool, target: CloseDialog.Target) void {
    self.setSplitZoom(false);

    if (!process_active) {
        self.container.remove();
        return;
    }

    CloseDialog.show(target) catch |err| {
        log.err("failed to open close dialog={}", .{err});
    };
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
    self.inspector = inspectorpkg.Inspector.create(
        self,
        .{ .window = {} },
    ) catch |err| {
        log.err("failed to control inspector err={}", .{err});
        return;
    };
}

pub fn setShouldClose(self: *Surface) void {
    _ = self;
}

pub fn shouldClose(self: *const Surface) bool {
    _ = self;
    return false;
}

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    const gtk_scale: f32 = scale: {
        const widget = self.gl_area.as(gtk.Widget);
        // Future: detect GTK version 4.12+ and use gdk_surface_get_scale so we
        // can support fractional scaling.
        const scale = widget.getScaleFactor();
        if (scale <= 0) {
            log.warn("gtk_widget_get_scale_factor returned a non-positive number: {}", .{scale});
            break :scale 1.0;
        }
        break :scale @floatFromInt(scale);
    };

    // Also scale using font-specific DPI, which is often exposed to the user
    // via DE accessibility settings (see https://docs.gtk.org/gtk4/class.Settings.html).
    const xft_dpi_scale = xft_scale: {
        // gtk-xft-dpi is font DPI multiplied by 1024. See
        // https://docs.gtk.org/gtk4/property.Settings.gtk-xft-dpi.html
        const settings = gtk.Settings.getDefault() orelse break :xft_scale 1.0;
        var value = std.mem.zeroes(gobject.Value);
        defer value.unset();
        _ = value.init(gobject.ext.typeFor(c_int));
        settings.as(gobject.Object).getProperty("gtk-xft-dpi", &value);
        const gtk_xft_dpi = value.getInt();

        // Use a value of 1.0 for the XFT DPI scale if the setting is <= 0
        // See:
        // https://gitlab.gnome.org/GNOME/libadwaita/-/commit/a7738a4d269bfdf4d8d5429ca73ccdd9b2450421
        // https://gitlab.gnome.org/GNOME/libadwaita/-/commit/9759d3fd81129608dd78116001928f2aed974ead
        if (gtk_xft_dpi <= 0) {
            log.warn("gtk-xft-dpi was not set, using default value", .{});
            break :xft_scale 1.0;
        }

        // As noted above gtk-xft-dpi is multiplied by 1024, so we divide by
        // 1024, then divide by the default value (96) to derive a scale. Note
        // gtk-xft-dpi can be fractional, so we use floating point math here.
        const xft_dpi: f32 = @as(f32, @floatFromInt(gtk_xft_dpi)) / 1024.0;
        break :xft_scale xft_dpi / 96.0;
    };

    const scale = gtk_scale * xft_dpi_scale;
    return .{ .x = scale, .y = scale };
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return self.size;
}

pub fn setInitialWindowSize(self: *const Surface, width: u32, height: u32) !void {
    // If we've already become realized once then we ignore this
    // request. The apprt initial_size action should only modify
    // the physical size of the window during initialization.
    // Subsequent actions are only informative in case we want to
    // implement a "return to default size" action later.
    if (self.realized) return;

    // If we are within a split, do not set the size.
    if (self.container.split() != null) return;

    // This operation only makes sense if we're within a window view
    // hierarchy and we're the first tab in the window.
    const window = self.container.window() orelse return;
    if (window.notebook.nPages() > 1) return;

    const gtk_window = window.window.as(gtk.Window);

    // Note: this doesn't properly take into account the window decorations.
    // I'm not currently sure how to do that.
    gtk_window.setDefaultSize(@intCast(width), @intCast(height));
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

    const widget = window.window.as(gtk.Widget);

    // Note: this doesn't properly take into account the window decorations.
    // I'm not currently sure how to do that.
    widget.setSizeRequest(@intCast(min.width), @intCast(min.height));
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

    _ = self.gl_area.as(gtk.Widget).grabFocus();

    self.updateTitleLabels();
}

fn updateTitleLabels(self: *Surface) void {
    // If we have no title, then we have nothing to update.
    const title = self.getTitle() orelse return;

    // If we have a tab and are the focused child, then we have to update the tab
    if (self.container.tab()) |tab| {
        if (tab.focus_child == self) tab.setTitleText(title);
    }

    // If we have a window and are focused, then we have to update the window title.
    if (self.container.window()) |window| {
        const widget = self.gl_area.as(gtk.Widget);
        if (widget.isFocus() != 0) {
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
pub const SetTitleSource = enum { user, terminal };

pub fn setTitle(self: *Surface, slice: [:0]const u8, source: SetTitleSource) !void {
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

    // The user has overridden the title
    // We only want to update the terminal provided title so that it can be restored to the most recent state.
    if (self.title_from_terminal != null and source == .terminal) {
        alloc.free(self.title_from_terminal.?);
        self.title_from_terminal = copy;
        return;
    }

    if (self.title_text) |old| alloc.free(old);
    self.title_text = copy;

    // delay the title update to prevent flickering
    if (self.update_title_timer) |timer| {
        if (glib.Source.remove(timer) == 0) {
            log.warn("unable to remove update title timer", .{});
        }
        self.update_title_timer = null;
    }
    self.update_title_timer = glib.timeoutAdd(75, updateTitleTimerExpired, self);
}

fn updateTitleTimerExpired(ud: ?*anyopaque) callconv(.c) c_int {
    const self: *Surface = @ptrCast(@alignCast(ud.?));

    self.updateTitleLabels();
    self.update_title_timer = null;

    return 0;
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    if (self.title_text) |title_text| {
        return self.resolveTitle(title_text);
    }

    return null;
}

pub fn getTerminalTitle(self: *Surface) ?[:0]const u8 {
    if (self.title_from_terminal) |title_text| {
        return self.resolveTitle(title_text);
    }

    return null;
}

fn resolveTitle(self: *Surface, title: [:0]const u8) [:0]const u8 {
    return if (self.zoomed_in)
        title
    else
        title[zoom_title_prefix.len..];
}

pub fn promptTitle(self: *Surface) !void {
    if (!adw_version.atLeast(1, 5, 0)) return;
    const window = self.container.window() orelse return;

    var builder = Builder.init("prompt-title-dialog", 1, 5);
    defer builder.deinit();

    const entry = builder.getObject(gtk.Entry, "title_entry").?;
    entry.getBuffer().setText(self.getTitle() orelse "", -1);

    const dialog = builder.getObject(adw.AlertDialog, "prompt_title_dialog").?;
    dialog.choose(window.window.as(gtk.Widget), null, gtkPromptTitleResponse, self);
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

    const cursor = gdk.Cursor.newFromName(name.ptr, null) orelse {
        log.warn("unsupported cursor name={s}", .{name});
        return;
    };
    errdefer cursor.unref();

    // Set our new cursor. We only do this if the cursor we currently
    // have is NOT set to "none" because setting the cursor causes it
    // to become visible again.
    const widget = self.gl_area.as(gtk.Widget);
    if (widget.getCursor() != self.app.cursor_none) {
        widget.setCursor(cursor);
    }

    // Free our existing cursor
    if (self.cursor) |old| old.unref();
    self.cursor = cursor;
}

/// Set the visibility of the mouse cursor.
pub fn setMouseVisibility(self: *Surface, visible: bool) void {
    // Note in there that self.cursor or cursor_none may be null. That's
    // not a problem because NULL is a valid argument for set cursor
    // which means to just use the parent value.
    const widget = self.gl_area.as(gtk.Widget);

    if (visible) {
        widget.setCursor(self.cursor);
        return;
    }

    // Set our new cursor to the app "none" cursor
    widget.setCursor(self.app.cursor_none);
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

    self.url_widget = .init(self.overlay, uriZ);
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
    const clipboard = getClipboard(self.gl_area.as(gtk.Widget), clipboard_type) orelse return;

    clipboard.readTextAsync(null, gtkClipboardRead, ud_ptr);
}

pub fn setClipboardString(
    self: *Surface,
    val: [:0]const u8,
    clipboard_type: apprt.Clipboard,
    confirm: bool,
) !void {
    if (!confirm) {
        const clipboard = getClipboard(self.gl_area.as(gtk.Widget), clipboard_type) orelse return;
        clipboard.setText(val);

        // We only toast if we are copying to the standard clipboard.
        if (clipboard_type == .standard and
            self.app.config.@"app-notifications".@"clipboard-copy")
        {
            if (self.container.window()) |window|
                window.sendToast(i18n._("Copied to clipboard"));
        }
        return;
    }

    ClipboardConfirmationWindow.create(
        self.app,
        val,
        &self.core_surface,
        .{ .osc_52_write = clipboard_type },
        self.is_secure_input,
    ) catch |window_err| {
        log.err("failed to create clipboard confirmation window err={}", .{window_err});
    };
}

const ClipboardRequest = struct {
    self: *Surface,
    state: apprt.ClipboardRequest,
};

fn gtkClipboardRead(
    source: ?*gobject.Object,
    res: *gio.AsyncResult,
    ud: ?*anyopaque,
) callconv(.c) void {
    const clipboard = gobject.ext.cast(gdk.Clipboard, source orelse return) orelse return;
    const req: *ClipboardRequest = @ptrCast(@alignCast(ud orelse return));
    const self = req.self;
    const alloc = self.app.core_app.alloc;
    defer alloc.destroy(req);

    var gerr: ?*glib.Error = null;
    const cstr_ = clipboard.readTextFinish(res, &gerr);
    if (gerr) |err| {
        defer err.free();
        log.warn("failed to read clipboard err={s}", .{err.f_message orelse "(no message)"});
        return;
    }
    const cstr = cstr_ orelse return;
    defer glib.free(cstr);
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
                self.is_secure_input,
            ) catch |window_err| {
                log.err("failed to create clipboard confirmation window err={}", .{window_err});
            };
            return;
        },

        else => log.err("failed to complete clipboard request err={}", .{err}),
    };
}

fn getClipboard(widget: *gtk.Widget, clipboard: apprt.Clipboard) ?*gdk.Clipboard {
    return switch (clipboard) {
        .standard => widget.getClipboard(),
        .selection, .primary => widget.getPrimaryClipboard(),
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

    const notification = gio.Notification.new(t);
    defer notification.unref();
    notification.setBody(body);

    const icon = gio.ThemedIcon.new(build_config.bundle_id);
    defer icon.unref();

    notification.setIcon(icon);

    const pointer = glib.Variant.newUint64(@intFromPtr(&self.core_surface));
    notification.setDefaultActionAndTargetValue("app.present-surface", pointer);

    const app = self.app.app.as(gio.Application);

    // We set the notification ID to the body content. If the content is the
    // same, this notification may replace a previous notification
    app.sendNotification(body.ptr, notification);
}

fn gtkRealize(gl_area: *gtk.GLArea, self: *Surface) callconv(.c) void {
    log.debug("gl surface realized", .{});

    // We need to make the context current so we can call GL functions.
    gl_area.makeCurrent();
    if (gl_area.getError()) |err| {
        log.err("surface failed to realize: {s}", .{err.f_message orelse "(no message)"});
        log.warn("this error is usually due to a driver or gtk bug", .{});
        log.warn("this is a common cause of this issue: https://gitlab.gnome.org/GNOME/gtk/-/issues/4950", .{});
        return;
    }

    // realize means that our OpenGL context is ready, so we can now
    // initialize the core surface which will setup the renderer.
    self.realize() catch |err| {
        // TODO: we need to destroy the GL area here.
        log.err("surface failed to realize: {}", .{err});
        return;
    };

    // When we have a realized surface, we also attach our input method context.
    // We do this here instead of init because this allows us to release the ref
    // to the GLArea when we unrealized.
    self.im_context.as(gtk.IMContext).setClientWidget(self.overlay.as(gtk.Widget));
}

/// This is called when the underlying OpenGL resources must be released.
/// This is usually due to the OpenGL area changing GDK surfaces.
fn gtkUnrealize(gl_area: *gtk.GLArea, self: *Surface) callconv(.c) void {
    log.debug("gl surface unrealized", .{});

    // See gtkRealize for why we do this here.
    self.im_context.as(gtk.IMContext).setClientWidget(null);

    // There is no guarantee that our GLArea context is current
    // when unrealize is emitted, so we need to make it current.
    gl_area.makeCurrent();
    if (gl_area.getError()) |err| {
        // I don't know a scenario this can happen, but it means
        // we probably leaked memory because displayUnrealized
        // below frees resources that aren't specifically OpenGL
        // related. I didn't make the OpenGL renderer handle this
        // scenario because I don't know if its even possible
        // under valid circumstances, so let's log.
        log.warn(
            "gl_area_make_current failed in unrealize msg={s}",
            .{err.f_message orelse "(no message)"},
        );
        log.warn("OpenGL resources and memory likely leaked", .{});
        return;
    } else {
        self.core_surface.renderer.displayUnrealized();
    }
}

/// render signal
fn gtkRender(_: *gtk.GLArea, _: *gdk.GLContext, self: *Surface) callconv(.c) c_int {
    self.render() catch |err| {
        log.err("surface failed to render: {}", .{err});
        return 0;
    };

    return 1;
}

/// resize signal
fn gtkResize(gl_area: *gtk.GLArea, width: c_int, height: c_int, self: *Surface) callconv(.c) void {
    // Some debug output to help understand what GTK is telling us.
    {
        const scale_factor = scale: {
            const widget = gl_area.as(gtk.Widget);
            break :scale widget.getScaleFactor();
        };

        const window_scale_factor = scale: {
            const window = self.container.window() orelse break :scale 0;
            const gtk_window = window.window.as(gtk.Window);
            const gtk_native = gtk_window.as(gtk.Native);
            const gdk_surface = gtk_native.getSurface() orelse break :scale 0;
            break :scale gdk_surface.getScaleFactor();
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
fn gtkDestroy(_: *gtk.GLArea, self: *Surface) callconv(.c) void {
    log.debug("gl destroy", .{});

    const alloc = self.app.core_app.alloc;
    self.deinit();
    alloc.destroy(self);
}

/// Scale x/y by the GDK device scale.
fn scaledCoordinates(
    self: *const Surface,
    x: f64,
    y: f64,
) struct {
    x: f64,
    y: f64,
} {
    const gl_are_widget = self.gl_area.as(gtk.Widget);
    const scale_factor: f64 = @floatFromInt(
        gl_are_widget.getScaleFactor(),
    );

    return .{
        .x = x * scale_factor,
        .y = y * scale_factor,
    };
}

fn gtkMouseDown(
    gesture: *gtk.GestureClick,
    _: c_int,
    x: f64,
    y: f64,
    self: *Surface,
) callconv(.c) void {
    const event = gesture.as(gtk.EventController).getCurrentEvent() orelse return;

    const gtk_mods = event.getModifierState();

    const button = translateMouseButton(gesture.as(gtk.GestureSingle).getCurrentButton());
    const mods = gtk_key.translateMods(gtk_mods);

    // If we don't have focus, grab it.
    const gl_area_widget = self.gl_area.as(gtk.Widget);
    if (gl_area_widget.hasFocus() == 0) {
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
        self.context_menu.popupAt(@intFromFloat(x), @intFromFloat(y));
    }
}

fn gtkMouseUp(
    gesture: *gtk.GestureClick,
    _: c_int,
    _: f64,
    _: f64,
    self: *Surface,
) callconv(.c) void {
    const event = gesture.as(gtk.EventController).getCurrentEvent() orelse return;

    const gtk_mods = event.getModifierState();

    const button = translateMouseButton(gesture.as(gtk.GestureSingle).getCurrentButton());
    const mods = gtk_key.translateMods(gtk_mods);

    _ = self.core_surface.mouseButtonCallback(.release, button, mods) catch |err| {
        log.err("error in key callback err={}", .{err});
        return;
    };
}

fn gtkMouseMotion(
    ec: *gtk.EventControllerMotion,
    x: f64,
    y: f64,
    self: *Surface,
) callconv(.c) void {
    const event = ec.as(gtk.EventController).getCurrentEvent() orelse return;

    const scaled = self.scaledCoordinates(x, y);

    const pos: apprt.CursorPos = .{
        .x = @floatCast(scaled.x),
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
        const gl_area_widget = self.gl_area.as(gtk.Widget);
        if (gl_area_widget.hasFocus() == 0 and self.app.config.@"focus-follows-mouse") {
            self.grabFocus();
        }

        // Our pos changed, update
        self.cursor_pos = pos;

        // Get our modifiers
        const gtk_mods = event.getModifierState();
        const mods = gtk_key.translateMods(gtk_mods);

        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }
}

fn gtkMouseLeave(
    ec_motion: *gtk.EventControllerMotion,
    self: *Surface,
) callconv(.c) void {
    const event = ec_motion.as(gtk.EventController).getCurrentEvent() orelse return;

    // Get our modifiers
    const gtk_mods = event.getModifierState();
    const mods = gtk_key.translateMods(gtk_mods);
    self.core_surface.cursorPosCallback(.{ .x = -1, .y = -1 }, mods) catch |err| {
        log.err("error in cursor pos callback err={}", .{err});
        return;
    };
}

fn gtkMouseScrollPrecisionBegin(
    _: *gtk.EventControllerScroll,
    self: *Surface,
) callconv(.c) void {
    self.precision_scroll = true;
}

fn gtkMouseScrollPrecisionEnd(
    _: *gtk.EventControllerScroll,
    self: *Surface,
) callconv(.c) void {
    self.precision_scroll = false;
}

fn gtkMouseScroll(
    _: *gtk.EventControllerScroll,
    x: f64,
    y: f64,
    self: *Surface,
) callconv(.c) c_int {
    const scaled = self.scaledCoordinates(x, y);

    // GTK doesn't support any of the scroll mods.
    const scroll_mods: input.ScrollMods = .{ .precision = self.precision_scroll };
    // Multiply precision scrolls by 10 to get a better response from touchpad scrolling
    const multiplier: f64 = if (self.precision_scroll) 10.0 else 1.0;

    self.core_surface.scrollCallback(
        // We invert because we apply natural scrolling to the values.
        // This behavior has existed for years without Linux users complaining
        // but I suspect we'll have to make this configurable in the future
        // or read a system setting.
        scaled.x * -1 * multiplier,
        scaled.y * -1 * multiplier,
        scroll_mods,
    ) catch |err| {
        log.err("error in scroll callback err={}", .{err});
        return 0;
    };

    return 1;
}

fn gtkKeyPressed(
    ec_key: *gtk.EventControllerKey,
    keyval: c_uint,
    keycode: c_uint,
    gtk_mods: gdk.ModifierType,
    self: *Surface,
) callconv(.c) c_int {
    return @intFromBool(self.keyEvent(
        .press,
        ec_key,
        keyval,
        keycode,
        gtk_mods,
    ));
}

fn gtkKeyReleased(
    ec_key: *gtk.EventControllerKey,
    keyval: c_uint,
    keycode: c_uint,
    state: gdk.ModifierType,
    self: *Surface,
) callconv(.c) void {
    _ = self.keyEvent(
        .release,
        ec_key,
        keyval,
        keycode,
        state,
    );
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
    ec_key: *gtk.EventControllerKey,
    keyval: c_uint,
    keycode: c_uint,
    gtk_mods: gdk.ModifierType,
) bool {
    // log.warn("GTKIM: keyEvent action={}", .{action});
    const event = ec_key.as(gtk.EventController).getCurrentEvent() orelse return false;
    const key_event = gobject.ext.cast(gdk.KeyEvent, event) orelse return false;

    // The block below is all related to input method handling. See the function
    // comment for some high level details and then the comments within
    // the block for more specifics.
    {
        // This can trigger an input method so we need to notify the im context
        // where the cursor is so it can render the dropdowns in the correct
        // place.
        const ime_point = self.core_surface.imePoint();
        self.im_context.as(gtk.IMContext).setCursorLocation(&.{
            .f_x = @intFromFloat(ime_point.x),
            .f_y = @intFromFloat(ime_point.y),
            .f_width = 1,
            .f_height = 1,
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
        const im_handled = self.im_context.as(gtk.IMContext).filterKeypress(event) != 0;
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
    const keyval_unicode = gdk.keyvalToUnicode(keyval);
    const keyval_unicode_unshifted: u21 = gtk_key.keyvalUnicodeUnshifted(
        self.gl_area.as(gtk.Widget),
        key_event,
        keycode,
    );

    // We want to get the physical unmapped key to process physical keybinds.
    // (These are keybinds explicitly marked as requesting physical mapping).
    const physical_key = keycode: for (input.keycodes.entries) |entry| {
        if (entry.native == keycode) break :keycode entry.key;
    } else .unidentified;

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
        const T = @typeInfo(gdk.ModifierType);
        std.debug.assert(T.@"struct".layout == .@"packed");
        const I = T.@"struct".backing_integer.?;

        const masked = @as(I, @bitCast(key_event.getConsumedModifiers())) & @as(I, gdk.MODIFIER_MASK);
        break :consumed gtk_key.translateMods(@bitCast(masked));
    };

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
        .key = physical_key,
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
                self.im_context.as(gtk.IMContext).reset();
                self.core_surface.preeditCallback(null) catch {};
            }

            return true;
        },
    }

    return false;
}

fn gtkInputPreeditStart(
    _: *gtk.IMMulticontext,
    self: *Surface,
) callconv(.c) void {
    // log.warn("GTKIM: preedit start", .{});

    // Start our composing state for the input method and reset our
    // input buffer to empty.
    self.im_composing = true;
    self.im_len = 0;
}

fn gtkInputPreeditChanged(
    ctx: *gtk.IMMulticontext,
    self: *Surface,
) callconv(.c) void {
    // Any preedit change should mark that we're composing. Its possible this
    // is false using fcitx5-hangul and typing "dkssud<space>" ("안녕"). The
    // second "s" results in a "commit" for "안" which sets composing to false,
    // but then immediately sends a preedit change for the next symbol. With
    // composing set to false we won't commit this text. Therefore, we must
    // ensure it is set here.
    self.im_composing = true;

    // Get our pre-edit string that we'll use to show the user.
    var buf: [*:0]u8 = undefined;
    ctx.as(gtk.IMContext).getPreeditString(&buf, null, null);
    defer glib.free(buf);

    const str = std.mem.sliceTo(buf, 0);

    // Update our preedit state in Ghostty core
    // log.warn("GTKIM: preedit change str={s}", .{str});
    self.core_surface.preeditCallback(str) catch |err| {
        log.err("error in preedit callback err={}", .{err});
    };
}

fn gtkInputPreeditEnd(
    _: *gtk.IMMulticontext,
    self: *Surface,
) callconv(.c) void {
    // log.warn("GTKIM: preedit end", .{});

    // End our composing state for GTK, allowing us to commit the text.
    self.im_composing = false;

    // End our preedit state in Ghostty core
    self.core_surface.preeditCallback(null) catch |err| {
        log.err("error in preedit callback err={}", .{err});
    };
}

fn gtkInputCommit(
    _: *gtk.IMMulticontext,
    bytes: [*:0]u8,
    self: *Surface,
) callconv(.c) void {
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
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = str,
    }) catch |err| {
        log.warn("error in key callback err={}", .{err});
        return;
    };
}

fn gtkFocusEnter(_: *gtk.EventControllerFocus, self: *Surface) callconv(.c) void {
    if (!self.realized) return;

    // Notify our IM context
    self.im_context.as(gtk.IMContext).focusIn();

    // Remove the unfocused widget overlay, if we have one
    if (self.unfocused_widget) |widget| {
        self.overlay.removeOverlay(widget);
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

fn gtkFocusLeave(_: *gtk.EventControllerFocus, self: *Surface) callconv(.c) void {
    if (!self.realized) return;

    // Notify our IM context
    self.im_context.as(gtk.IMContext).focusOut();

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

/// Adds the unfocused_widget to the overlay. If the unfocused_widget has
/// already been added, this is a no-op.
pub fn dimSurface(self: *Surface) void {
    _ = self.container.window() orelse {
        log.warn("dimSurface invalid for container={}", .{self.container});
        return;
    };

    // Don't dim surface if context menu is open.
    // This means we got unfocused due to it opening.
    if (self.context_menu.isVisible()) return;

    // If there's already an unfocused_widget do nothing;
    if (self.unfocused_widget) |_| return;

    self.unfocused_widget = unfocused_widget: {
        const drawing_area = gtk.DrawingArea.new();
        const unfocused_widget = drawing_area.as(gtk.Widget);
        unfocused_widget.addCssClass("unfocused-split");
        self.overlay.addOverlay(unfocused_widget);
        break :unfocused_widget unfocused_widget;
    };
}

fn translateMouseButton(button: c_uint) input.MouseButton {
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
        window.window.as(gtk.Window).present();
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
        tab.box.remove(tab_widget);
        tab.box.append(surface_widget);
    } else {
        tab.box.remove(surface_widget);
        self.attachToSplit();
        tab.box.append(tab_widget);
    }

    self.zoomed_in = new_split_zoom;
    self.grabFocus();
}

pub fn toggleSplitZoom(self: *Surface) void {
    self.setSplitZoom(!self.zoomed_in);
}

/// Handle items being dropped on our surface.
fn gtkDrop(
    _: *gtk.DropTarget,
    value: *gobject.Value,
    _: f64,
    _: f64,
    self: *Surface,
) callconv(.c) c_int {
    const alloc = self.app.core_app.alloc;

    if (g_value_holds(value, gdk.FileList.getGObjectType())) {
        var data = std.ArrayList(u8).init(alloc);
        defer data.deinit();

        var shell_escape_writer: internal_os.ShellEscapeWriter(std.ArrayList(u8).Writer) = .{
            .child_writer = data.writer(),
        };
        const writer = shell_escape_writer.writer();

        const unboxed = value.getBoxed() orelse return 0;
        const fl: *gdk.FileList = @ptrCast(@alignCast(unboxed));
        var list: ?*glib.SList = fl.getFiles();

        while (list) |item| : (list = item.f_next) {
            const file: *gio.File = @ptrCast(@alignCast(item.f_data orelse continue));
            const path = file.getPath() orelse continue;

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
            return 0;
        };
        defer alloc.free(string);

        self.doPaste(string);

        return 1;
    }

    if (g_value_holds(value, gio.File.getGObjectType())) {
        const object = value.getObject() orelse return 0;
        const file = gobject.ext.cast(gio.File, object) orelse return 0;
        const path = file.getPath() orelse return 0;
        var data = std.ArrayList(u8).init(alloc);
        defer data.deinit();

        var shell_escape_writer: internal_os.ShellEscapeWriter(std.ArrayList(u8).Writer) = .{
            .child_writer = data.writer(),
        };
        const writer = shell_escape_writer.writer();
        writer.writeAll(std.mem.span(path)) catch |err| {
            log.err("unable to write path to buffer: {}", .{err});
            return 0;
        };
        writer.writeAll("\n") catch |err| {
            log.err("unable to write to buffer: {}", .{err});
            return 0;
        };

        const string = data.toOwnedSliceSentinel(0) catch |err| {
            log.err("unable to convert to a slice: {}", .{err});
            return 0;
        };
        defer alloc.free(string);

        self.doPaste(string);

        return 1;
    }

    if (g_value_holds(value, gobject.ext.types.string)) {
        if (value.getString()) |string| {
            const text = std.mem.span(string);
            if (text.len > 0) self.doPaste(text);
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
                self.is_secure_input,
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

    // Remove some environment variables that are set when Ghostty is launched
    // from a `.desktop` file, by D-Bus activation, or systemd.
    env.remove("GIO_LAUNCHED_DESKTOP_FILE");
    env.remove("GIO_LAUNCHED_DESKTOP_FILE_PID");
    env.remove("DBUS_STARTER_ADDRESS");
    env.remove("DBUS_STARTER_BUS_TYPE");
    env.remove("INVOCATION_ID");
    env.remove("JOURNAL_STREAM");

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
        env.remove("GDK_PIXBUF_MODULE_FILE");
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
fn g_value_holds(value_: ?*gobject.Value, g_type: gobject.Type) bool {
    if (value_) |value| {
        if (value.f_g_type == g_type) return true;
        return gobject.typeCheckValueHolds(value, g_type) != 0;
    }
    return false;
}

fn gtkPromptTitleResponse(source_object: ?*gobject.Object, result: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
    if (!adw_version.supportsDialogs()) return;
    const dialog = gobject.ext.cast(adw.AlertDialog, source_object.?).?;
    const self: *Surface = @ptrCast(@alignCast(ud));

    const response = dialog.chooseFinish(result);
    if (std.mem.orderZ(u8, "ok", response) == .eq) {
        const title_entry = gobject.ext.cast(gtk.Entry, dialog.getExtraChild().?).?;
        const title = std.mem.span(title_entry.getBuffer().getText());

        // if the new title is empty and the user has set the title previously, restore the terminal provided title
        if (title.len == 0) {
            if (self.getTerminalTitle()) |terminal_title| {
                self.setTitle(terminal_title, .user) catch |err| {
                    log.err("failed to set title={}", .{err});
                };
                self.app.core_app.alloc.free(self.title_from_terminal.?);
                self.title_from_terminal = null;
            }
        } else if (title.len > 0) {
            // if this is the first time the user is setting the title, save the current terminal provided title
            if (self.title_from_terminal == null and self.title_text != null) {
                self.title_from_terminal = self.app.core_app.alloc.dupeZ(u8, self.title_text.?) catch |err| switch (err) {
                    error.OutOfMemory => {
                        log.err("failed to allocate memory for title={}", .{err});
                        return;
                    },
                };
            }

            self.setTitle(title, .user) catch |err| {
                log.err("failed to set title={}", .{err});
            };
        }
    }
}

pub fn setSecureInput(self: *Surface, value: apprt.action.SecureInput) void {
    switch (value) {
        .on => self.is_secure_input = true,
        .off => self.is_secure_input = false,
        .toggle => self.is_secure_input = !self.is_secure_input,
    }
}

pub fn ringBell(self: *Surface) !void {
    const features = self.app.config.@"bell-features";
    const window = self.container.window() orelse {
        log.warn("failed to ring bell: surface is not attached to any window", .{});
        return;
    };

    // System beep
    if (features.system) system: {
        const surface = window.window.as(gtk.Native).getSurface() orelse break :system;
        surface.beep();
    }

    if (features.audio) audio: {
        // Play a user-specified audio file.

        const pathname, const required = switch (self.app.config.@"bell-audio-path" orelse break :audio) {
            .optional => |path| .{ path, false },
            .required => |path| .{ path, true },
        };

        const volume = std.math.clamp(self.app.config.@"bell-audio-volume", 0.0, 1.0);

        std.debug.assert(std.fs.path.isAbsolute(pathname));
        const media_file = gtk.MediaFile.newForFilename(pathname);

        if (required) {
            _ = gobject.Object.signals.notify.connect(
                media_file,
                ?*anyopaque,
                gtkStreamError,
                null,
                .{ .detail = "error" },
            );
        }
        _ = gobject.Object.signals.notify.connect(
            media_file,
            ?*anyopaque,
            gtkStreamEnded,
            null,
            .{ .detail = "ended" },
        );

        const media_stream = media_file.as(gtk.MediaStream);
        media_stream.setVolume(volume);
        media_stream.play();
    }

    if (features.attention) {
        // Request user attention
        window.winproto.setUrgent(true) catch |err| {
            log.err("failed to request user attention={}", .{err});
        };
    }

    // Mark tab as needing attention
    if (self.container.tab()) |tab| tab: {
        const page = window.notebook.getTabPage(tab) orelse break :tab;

        // Need attention if we're not the currently selected tab
        if (page.getSelected() == 0) page.setNeedsAttention(@intFromBool(true));
    }
}

/// Handle a stream that is in an error state.
fn gtkStreamError(media_file: *gtk.MediaFile, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
    const path = path: {
        const file = media_file.getFile() orelse break :path null;
        break :path file.getPath();
    };
    defer if (path) |p| glib.free(p);

    const media_stream = media_file.as(gtk.MediaStream);
    const err = media_stream.getError() orelse return;

    log.warn("error playing bell from {s}: {s} {d} {s}", .{
        path orelse "<<unknown>>",
        glib.quarkToString(err.f_domain),
        err.f_code,
        err.f_message orelse "",
    });
}

/// Stream is finished, release the memory.
fn gtkStreamEnded(media_file: *gtk.MediaFile, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
    media_file.unref();
}
