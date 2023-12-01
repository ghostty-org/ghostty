/// A surface represents one drawable terminal surface. The surface may be
/// attached to a window or it may be some other kind of surface. This struct
/// is meant to be generic to all scenarios.
const Surface = @This();

const std = @import("std");
const configpkg = @import("../../config.zig");
const apprt = @import("../../apprt.zig");
const font = @import("../../font/main.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");

const App = @import("App.zig");
const Window = @import("Window.zig");
const ClipboardConfirmationWindow = @import("ClipboardConfirmationWindow.zig");
const inspector = @import("inspector.zig");
const gtk_key = @import("key.zig");
const c = @import("c.zig");

const log = std.log.scoped(.gtk);

/// This is detected by the OpenGL renderer to move to a single-threaded
/// draw operation. This basically puts locks around our draw path.
pub const opengl_single_threaded_draw = true;

pub const Options = struct {
    /// The window that this surface is attached to.
    window: *Window,

    /// The GL area that this surface should draw to.
    gl_area: *c.GtkGLArea,

    /// The label to use as the title of this surface. This will be
    /// modified with setTitle.
    title_label: ?*c.GtkLabel = null,

    /// A font size to set on the surface once it is initialized.
    font_size: ?font.face.DesiredSize = null,

    /// True if this surface has a parent. This is a bit of a hack currently
    /// to work around newConfig unconditinally inheriting the working
    /// directory. The proper long term fix is to have the working directory
    /// inherited upstream likely at the point where this field would be set,
    /// then remove this field.
    parent: bool = false,
};

/// Where the title of this surface will go.
const Title = union(enum) {
    none: void,
    label: *c.GtkLabel,
};

/// Whether the surface has been realized or not yet. When a surface is
/// "realized" it means that the OpenGL context is ready and the core
/// surface has been initialized.
realized: bool = false,

/// See Options.parent
parent: bool = false,

/// The app we're part of
app: *App,

/// The window we're part of
window: *Window,

/// Our GTK area
gl_area: *c.GtkGLArea,

/// Any active cursor we may have
cursor: ?*c.GdkCursor = null,

/// Our title label (if there is one).
title: Title,

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

pub fn init(self: *Surface, app: *App, opts: Options) !void {
    const widget = @as(*c.GtkWidget, @ptrCast(opts.gl_area));
    c.gtk_gl_area_set_required_version(opts.gl_area, 3, 3);
    c.gtk_gl_area_set_has_stencil_buffer(opts.gl_area, 0);
    c.gtk_gl_area_set_has_depth_buffer(opts.gl_area, 0);
    c.gtk_gl_area_set_use_es(opts.gl_area, 0);

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

    // Build our result
    self.* = .{
        .app = app,
        .window = opts.window,
        .gl_area = opts.gl_area,
        .title = if (opts.title_label) |label| .{
            .label = label,
        } else .{ .none = {} },
        .core_surface = undefined,
        .font_size = opts.font_size,
        .parent = opts.parent,
        .size = .{ .width = 800, .height = 600 },
        .cursor_pos = .{ .x = 0, .y = 0 },
        .im_context = im_context,
    };
    errdefer self.* = undefined;

    // Set our default mouse shape
    try self.setMouseShape(.text);

    // GL events
    _ = c.g_signal_connect_data(opts.gl_area, "realize", c.G_CALLBACK(&gtkRealize), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(opts.gl_area, "unrealize", c.G_CALLBACK(&gtkUnrealize), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(opts.gl_area, "destroy", c.G_CALLBACK(&gtkDestroy), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(opts.gl_area, "render", c.G_CALLBACK(&gtkRender), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(opts.gl_area, "resize", c.G_CALLBACK(&gtkResize), self, null, c.G_CONNECT_DEFAULT);

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
    var config = try apprt.surface.newConfig(self.app.core_app, &self.app.config);
    defer config.deinit();
    if (!self.parent) {
        // A hack, see the "parent" field for more information.
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

    // Note we're realized
    self.realized = true;
}

pub fn deinit(self: *Surface) void {
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
    if (!processActive) {
        self.window.closeSurface(self);
        return;
    }

    // Setup our basic message
    const alert = c.gtk_message_dialog_new(
        self.window.window,
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
    self.window.toggleFullscreen(mac_non_native);
}

pub fn newTab(self: *Surface) !void {
    try self.window.newTab(&self.core_surface);
}

pub fn hasTabs(self: *const Surface) bool {
    return self.window.hasTabs();
}

pub fn gotoPreviousTab(self: *Surface) void {
    self.window.gotoPreviousTab(self);
}

pub fn gotoNextTab(self: *Surface) void {
    self.window.gotoNextTab(self);
}

pub fn gotoTab(self: *Surface, n: usize) void {
    self.window.gotoTab(n);
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
    const scale = c.gtk_widget_get_scale_factor(@ptrCast(self.gl_area));
    return .{ .x = @floatFromInt(scale), .y = @floatFromInt(scale) };
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return self.size;
}

pub fn setInitialWindowSize(self: *const Surface, width: u32, height: u32) !void {
    // Note: this doesn't properly take into account the window decorations.
    // I'm not currently sure how to do that.
    c.gtk_window_set_default_size(
        @ptrCast(self.window.window),
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

pub fn setTitle(self: *Surface, slice: [:0]const u8) !void {
    switch (self.title) {
        .none => {},

        .label => |label| {
            c.gtk_label_set_text(label, slice.ptr);

            const widget = @as(*c.GtkWidget, @ptrCast(self.gl_area));
            if (c.gtk_widget_is_focus(widget) == 1) {
                c.gtk_window_set_title(self.window.window, c.gtk_label_get_text(label));
            }
        },
    }

    // const root = c.gtk_widget_get_root(@ptrCast(
    //     *c.GtkWidget,
    //     self.gl_area,
    // ));
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
            const window = @as(*c.GtkNative, @ptrCast(self.window.window));
            const gdk_surface = c.gtk_native_get_surface(window);
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
        _ = c.gtk_widget_grab_focus(gl_widget);
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

    // Get the unshifted unicode value of the keyval. This is used
    // by the Kitty keyboard protocol.
    const keyval_unicode_unshifted: u21 = unshifted: {
        // Note: this can't possibly always be right, specifically in the
        // case of multi-level/group keyboards. But, this works for Dvorak,
        // Norwegian, and French layouts and thats what we have real users for
        // right now.
        const lower = c.gdk_keyval_to_lower(keyval);
        const lower_unicode = c.gdk_keyval_to_unicode(lower);
        break :unshifted std.math.cast(u21, lower_unicode) orelse 0;
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

    // Get our modifiers. We have to translate modifier-only presses here
    // to state in the mods manually because GTK only does it AFTER the press
    // event.
    const mods = mods: {
        var mods = translateMods(gtk_mods);
        switch (physical_key) {
            .left_shift => {
                mods.shift = action == .press;
                if (mods.shift) mods.sides.shift = .left;
            },

            .right_shift => {
                mods.shift = action == .press;
                if (mods.shift) mods.sides.shift = .right;
            },

            .left_control => {
                mods.ctrl = action == .press;
                if (mods.ctrl) mods.sides.ctrl = .left;
            },

            .right_control => {
                mods.ctrl = action == .press;
                if (mods.ctrl) mods.sides.ctrl = .right;
            },

            .left_alt => {
                mods.alt = action == .press;
                if (mods.alt) mods.sides.alt = .left;
            },

            .right_alt => {
                mods.alt = action == .press;
                if (mods.alt) mods.sides.alt = .right;
            },

            .left_super => {
                mods.super = action == .press;
                if (mods.super) mods.sides.super = .left;
            },

            .right_super => {
                mods.super = action == .press;
                if (mods.super) mods.sides.super = .right;
            },

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

        // Before using the physical key, try to convert the keyval
        // directly to a key. This allows the use of key remapping.
        if (gtk_key.keyFromKeyval(keyval)) |key| {
            break :key key;
        }

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
    if (self.im_len == 0 and keyval_unicode > 0) {
        if (std.math.cast(u21, keyval_unicode)) |cp| {
            if (std.unicode.utf8Encode(cp, &self.im_buf)) |len| {
                self.im_len = len;
            } else |_| {}
        }
    }

    // Invoke the core Ghostty logic to handle this input.
    const consumed = self.core_surface.keyCallback(.{
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

    // If we consume the key then we want to reset the dead key state.
    if (consumed and (action == .press or action == .repeat)) {
        c.gtk_im_context_reset(self.im_context);
        self.core_surface.preeditCallback(null) catch {};
        return true;
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
        self.window.closeSurface(self);
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
