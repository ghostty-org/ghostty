const ImguiWidget = @This();

const std = @import("std");
const assert = std.debug.assert;

const cimgui = @import("cimgui");
const c = @import("c.zig").c;
const key = @import("key.zig");
const gl = @import("opengl");
const input = @import("../../input.zig");

const log = std.log.scoped(.gtk_imgui_widget);

/// This is called every frame to populate the ImGui frame.
render_callback: ?*const fn (?*anyopaque) void = null,
render_userdata: ?*anyopaque = null,

/// Our OpenGL widget
gl_area: *c.GtkGLArea,
im_context: *c.GtkIMContext,

/// ImGui Context
ig_ctx: *cimgui.c.ImGuiContext,

/// Our previous instant used to calculate delta time for animations.
instant: ?std.time.Instant = null,

/// Initialize the widget. This must have a stable pointer for events.
pub fn init(self: *ImguiWidget) !void {
    // Each widget gets its own imgui context so we can have multiple
    // imgui views in the same application.
    const ig_ctx = cimgui.c.igCreateContext(null) orelse return error.OutOfMemory;
    errdefer cimgui.c.igDestroyContext(ig_ctx);
    cimgui.c.igSetCurrentContext(ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    io.BackendPlatformName = "ghostty_gtk";

    // Our OpenGL area for drawing
    const gl_area = c.gtk_gl_area_new();
    c.gtk_gl_area_set_auto_render(@ptrCast(gl_area), 1);

    // The GL area has to be focusable so that it can receive events
    c.gtk_widget_set_focusable(@ptrCast(gl_area), 1);
    c.gtk_widget_set_focus_on_click(@ptrCast(gl_area), 1);

    // Clicks
    const gesture_click = c.gtk_gesture_click_new();
    errdefer c.g_object_unref(gesture_click);
    c.gtk_gesture_single_set_button(@ptrCast(gesture_click), 0);
    c.gtk_widget_add_controller(@ptrCast(gl_area), @ptrCast(gesture_click));

    // Mouse movement
    const ec_motion = c.gtk_event_controller_motion_new();
    errdefer c.g_object_unref(ec_motion);
    c.gtk_widget_add_controller(@ptrCast(gl_area), ec_motion);

    // Scroll events
    const ec_scroll = c.gtk_event_controller_scroll_new(
        c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES |
            c.GTK_EVENT_CONTROLLER_SCROLL_DISCRETE,
    );
    errdefer c.g_object_unref(ec_scroll);
    c.gtk_widget_add_controller(@ptrCast(gl_area), ec_scroll);

    // Focus controller will tell us about focus enter/exit events
    const ec_focus = c.gtk_event_controller_focus_new();
    errdefer c.g_object_unref(ec_focus);
    c.gtk_widget_add_controller(@ptrCast(gl_area), ec_focus);

    // Key event controller will tell us about raw keypress events.
    const ec_key = c.gtk_event_controller_key_new();
    errdefer c.g_object_unref(ec_key);
    c.gtk_widget_add_controller(@ptrCast(gl_area), ec_key);
    errdefer c.gtk_widget_remove_controller(@ptrCast(gl_area), ec_key);

    // The input method context that we use to translate key events into
    // characters. This doesn't have an event key controller attached because
    // we call it manually from our own key controller.
    const im_context = c.gtk_im_multicontext_new();
    errdefer c.g_object_unref(im_context);

    // Signals
    _ = c.g_signal_connect_data(gl_area, "destroy", c.G_CALLBACK(&gtkDestroy), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gl_area, "realize", c.G_CALLBACK(&gtkRealize), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gl_area, "unrealize", c.G_CALLBACK(&gtkUnrealize), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gl_area, "render", c.G_CALLBACK(&gtkRender), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gl_area, "resize", c.G_CALLBACK(&gtkResize), self, null, c.G_CONNECT_DEFAULT);

    _ = c.g_signal_connect_data(ec_focus, "enter", c.G_CALLBACK(&gtkFocusEnter), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(ec_focus, "leave", c.G_CALLBACK(&gtkFocusLeave), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(ec_key, "key-pressed", c.G_CALLBACK(&gtkKeyPressed), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(ec_key, "key-released", c.G_CALLBACK(&gtkKeyReleased), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(ec_motion, "motion", c.G_CALLBACK(&gtkMouseMotion), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(ec_scroll, "scroll", c.G_CALLBACK(&gtkMouseScroll), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gesture_click, "pressed", c.G_CALLBACK(&gtkMouseDown), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(gesture_click, "released", c.G_CALLBACK(&gtkMouseUp), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(im_context, "commit", c.G_CALLBACK(&gtkInputCommit), self, null, c.G_CONNECT_DEFAULT);

    self.* = .{
        .gl_area = @ptrCast(gl_area),
        .im_context = @ptrCast(im_context),
        .ig_ctx = ig_ctx,
    };
}

/// Deinitialize the widget. This should ONLY be called if the widget gl_area
/// was never added to a parent. Otherwise, cleanup automatically happens
/// when the widget is destroyed and this should NOT be called.
pub fn deinit(self: *ImguiWidget) void {
    cimgui.c.igDestroyContext(self.ig_ctx);
}

/// This should be called anytime the underlying data for the UI changes
/// so that the UI can be refreshed.
pub fn queueRender(self: *const ImguiWidget) void {
    c.gtk_gl_area_queue_render(self.gl_area);
}

/// Initialize the frame. Expects that the context is already current.
fn newFrame(self: *ImguiWidget) !void {
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();

    // Determine our delta time
    const now = try std.time.Instant.now();
    io.DeltaTime = if (self.instant) |prev| delta: {
        const since_ns = now.since(prev);
        const since_s: f32 = @floatFromInt(since_ns / std.time.ns_per_s);
        break :delta @max(0.00001, since_s);
    } else (1 / 60);
    self.instant = now;
}

fn translateMouseButton(button: c.guint) ?c_int {
    return switch (button) {
        1 => cimgui.c.ImGuiMouseButton_Left,
        2 => cimgui.c.ImGuiMouseButton_Middle,
        3 => cimgui.c.ImGuiMouseButton_Right,
        else => null,
    };
}

fn gtkDestroy(v: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
    _ = v;
    log.debug("imgui widget destroy", .{});

    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    self.deinit();
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
    // initialize the ImgUI OpenGL backend for our context.
    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    cimgui.c.igSetCurrentContext(self.ig_ctx);
    _ = cimgui.ImGui_ImplOpenGL3_Init(null);
}

fn gtkUnrealize(area: *c.GtkGLArea, ud: ?*anyopaque) callconv(.C) void {
    _ = area;
    log.debug("gl surface unrealized", .{});

    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    cimgui.c.igSetCurrentContext(self.ig_ctx);
    cimgui.ImGui_ImplOpenGL3_Shutdown();
}

fn gtkResize(area: *c.GtkGLArea, width: c.gint, height: c.gint, ud: ?*anyopaque) callconv(.C) void {
    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    const scale_factor = c.gtk_widget_get_scale_factor(@ptrCast(area));
    log.debug("gl resize width={} height={} scale={}", .{
        width,
        height,
        scale_factor,
    });

    // Our display size is always unscaled. We'll do the scaling in the
    // style instead. This creates crisper looking fonts.
    io.DisplaySize = .{ .x = @floatFromInt(width), .y = @floatFromInt(height) };
    io.DisplayFramebufferScale = .{ .x = 1, .y = 1 };

    // Setup a new style and scale it appropriately.
    const style = cimgui.c.ImGuiStyle_ImGuiStyle();
    defer cimgui.c.ImGuiStyle_destroy(style);
    cimgui.c.ImGuiStyle_ScaleAllSizes(style, @floatFromInt(scale_factor));
    const active_style = cimgui.c.igGetStyle();
    active_style.* = style.*;
}

fn gtkRender(area: *c.GtkGLArea, ctx: *c.GdkGLContext, ud: ?*anyopaque) callconv(.C) c.gboolean {
    _ = area;
    _ = ctx;
    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    cimgui.c.igSetCurrentContext(self.ig_ctx);

    // Setup our frame. We render twice because some ImGui behaviors
    // take multiple renders to process. I don't know how to make this
    // more efficient.
    for (0..2) |_| {
        cimgui.ImGui_ImplOpenGL3_NewFrame();
        self.newFrame() catch |err| {
            log.err("failed to setup frame: {}", .{err});
            return 0;
        };
        cimgui.c.igNewFrame();

        // Build our UI
        if (self.render_callback) |cb| cb(self.render_userdata);

        // Render
        cimgui.c.igRender();
    }

    // OpenGL final render
    gl.clearColor(0x28 / 0xFF, 0x2C / 0xFF, 0x34 / 0xFF, 1.0);
    gl.clear(gl.c.GL_COLOR_BUFFER_BIT);
    cimgui.ImGui_ImplOpenGL3_RenderDrawData(cimgui.c.igGetDrawData());

    return 1;
}

fn gtkMouseMotion(
    _: *c.GtkEventControllerMotion,
    x: c.gdouble,
    y: c.gdouble,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    const scale_factor: f64 = @floatFromInt(c.gtk_widget_get_scale_factor(
        @ptrCast(self.gl_area),
    ));
    cimgui.c.ImGuiIO_AddMousePosEvent(
        io,
        @floatCast(x * scale_factor),
        @floatCast(y * scale_factor),
    );
    self.queueRender();
}

fn gtkMouseDown(
    gesture: *c.GtkGestureClick,
    _: c.gint,
    _: c.gdouble,
    _: c.gdouble,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    self.queueRender();

    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    const gdk_button = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
    if (translateMouseButton(gdk_button)) |button| {
        cimgui.c.ImGuiIO_AddMouseButtonEvent(io, button, true);
    }
}

fn gtkMouseUp(
    gesture: *c.GtkGestureClick,
    _: c.gint,
    _: c.gdouble,
    _: c.gdouble,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    self.queueRender();

    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    const gdk_button = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
    if (translateMouseButton(gdk_button)) |button| {
        cimgui.c.ImGuiIO_AddMouseButtonEvent(io, button, false);
    }
}

fn gtkMouseScroll(
    _: *c.GtkEventControllerScroll,
    x: c.gdouble,
    y: c.gdouble,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    self.queueRender();

    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    cimgui.c.ImGuiIO_AddMouseWheelEvent(
        io,
        @floatCast(x),
        @floatCast(-y),
    );
}

fn gtkFocusEnter(_: *c.GtkEventControllerFocus, ud: ?*anyopaque) callconv(.C) void {
    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    self.queueRender();

    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    cimgui.c.ImGuiIO_AddFocusEvent(io, true);
}

fn gtkFocusLeave(_: *c.GtkEventControllerFocus, ud: ?*anyopaque) callconv(.C) void {
    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    self.queueRender();

    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    cimgui.c.ImGuiIO_AddFocusEvent(io, false);
}

fn gtkInputCommit(
    _: *c.GtkIMContext,
    bytes: [*:0]u8,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    self.queueRender();

    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    cimgui.c.ImGuiIO_AddInputCharactersUTF8(io, bytes);
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

fn keyEvent(
    action: input.Action,
    ec_key: *c.GtkEventControllerKey,
    keyval: c.guint,
    keycode: c.guint,
    gtk_mods: c.GdkModifierType,
    ud: ?*anyopaque,
) bool {
    _ = keycode;

    const self: *ImguiWidget = @ptrCast(@alignCast(ud.?));
    self.queueRender();

    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();

    // FIXME: when this file get converted to zig-gobject
    // Translate the GTK mods and update the modifiers on every keypress
    const mods = key.translateMods(@bitCast(gtk_mods));
    cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftShift, mods.shift);
    cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftCtrl, mods.ctrl);
    cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftAlt, mods.alt);
    cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftSuper, mods.super);

    // If our keyval has a key, then we send that key event
    if (key.keyFromKeyval(keyval)) |inputkey| {
        if (inputkey.imguiKey()) |imgui_key| {
            cimgui.c.ImGuiIO_AddKeyEvent(io, imgui_key, action == .press);
        }
    }

    // Try to process the event as text
    const event = c.gtk_event_controller_get_current_event(@ptrCast(ec_key));
    if (event != null)
        _ = c.gtk_im_context_filter_keypress(self.im_context, event);

    return true;
}
