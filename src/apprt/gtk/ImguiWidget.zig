const ImguiWidget = @This();

const std = @import("std");
const assert = std.debug.assert;

const gdk = @import("gdk");
const gtk = @import("gtk");
const cimgui = @import("cimgui");
const gl = @import("opengl");

const key = @import("key.zig");
const input = @import("../../input.zig");

const log = std.log.scoped(.gtk_imgui_widget);

/// This is called every frame to populate the ImGui frame.
render_callback: ?*const fn (?*anyopaque) void = null,
render_userdata: ?*anyopaque = null,

/// Our OpenGL widget
gl_area: *gtk.GLArea,
im_context: *gtk.IMContext,

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
    const gl_area = gtk.GLArea.new();
    gl_area.setAutoRender(@intFromBool(true));

    // The GL area has to be focusable so that it can receive events
    gl_area.as(gtk.Widget).setFocusable(@intFromBool(true));
    gl_area.as(gtk.Widget).setFocusOnClick(@intFromBool(true));

    // Clicks
    const gesture_click = gtk.GestureClick.new();
    errdefer gesture_click.unref();
    gesture_click.as(gtk.GestureSingle).setButton(0);
    gl_area.as(gtk.Widget).addController(gesture_click.as(gtk.EventController));

    // Mouse movement
    const ec_motion = gtk.EventControllerMotion.new();
    errdefer ec_motion.unref();
    gl_area.as(gtk.Widget).addController(ec_motion.as(gtk.EventController));

    // Scroll events
    const ec_scroll = gtk.EventControllerScroll.new(.flags_both_axes);
    errdefer ec_scroll.unref();
    gl_area.as(gtk.Widget).addController(ec_scroll.as(gtk.EventController));

    // Focus controller will tell us about focus enter/exit events
    const ec_focus = gtk.EventControllerFocus.new();
    errdefer ec_focus.unref();
    gl_area.as(gtk.Widget).addController(ec_focus.as(gtk.EventController));

    // Key event controller will tell us about raw keypress events.
    const ec_key = gtk.EventControllerKey.new();
    errdefer ec_key.unref();
    gl_area.as(gtk.Widget).addController(ec_key.as(gtk.EventController));
    errdefer gl_area.as(gtk.Widget).removeController(ec_key.as(gtk.EventController));

    // The input method context that we use to translate key events into
    // characters. This doesn't have an event key controller attached because
    // we call it manually from our own key controller.
    const im_context = gtk.IMMulticontext.new();
    errdefer im_context.unref();

    // Signals
    _ = gtk.Widget.signals.realize.connect(
        gl_area,
        *ImguiWidget,
        gtkRealize,
        self,
        .{},
    );
    _ = gtk.Widget.signals.unrealize.connect(
        gl_area,
        *ImguiWidget,
        gtkUnrealize,
        self,
        .{},
    );
    _ = gtk.Widget.signals.destroy.connect(
        gl_area,
        *ImguiWidget,
        gtkDestroy,
        self,
        .{},
    );
    _ = gtk.GLArea.signals.render.connect(
        gl_area,
        *ImguiWidget,
        gtkRender,
        self,
        .{},
    );
    _ = gtk.GLArea.signals.resize.connect(
        gl_area,
        *ImguiWidget,
        gtkResize,
        self,
        .{},
    );
    _ = gtk.EventControllerKey.signals.key_pressed.connect(
        ec_key,
        *ImguiWidget,
        gtkKeyPressed,
        self,
        .{},
    );
    _ = gtk.EventControllerKey.signals.key_released.connect(
        ec_key,
        *ImguiWidget,
        gtkKeyReleased,
        self,
        .{},
    );
    _ = gtk.EventControllerFocus.signals.enter.connect(
        ec_focus,
        *ImguiWidget,
        gtkFocusEnter,
        self,
        .{},
    );
    _ = gtk.EventControllerFocus.signals.leave.connect(
        ec_focus,
        *ImguiWidget,
        gtkFocusLeave,
        self,
        .{},
    );
    _ = gtk.GestureClick.signals.pressed.connect(
        gesture_click,
        *ImguiWidget,
        gtkMouseDown,
        self,
        .{},
    );
    _ = gtk.GestureClick.signals.released.connect(
        gesture_click,
        *ImguiWidget,
        gtkMouseUp,
        self,
        .{},
    );
    _ = gtk.EventControllerMotion.signals.motion.connect(
        ec_motion,
        *ImguiWidget,
        gtkMouseMotion,
        self,
        .{},
    );
    _ = gtk.EventControllerScroll.signals.scroll.connect(
        ec_scroll,
        *ImguiWidget,
        gtkMouseScroll,
        self,
        .{},
    );
    _ = gtk.IMContext.signals.commit.connect(
        im_context,
        *ImguiWidget,
        gtkInputCommit,
        self,
        .{},
    );

    self.* = .{
        .gl_area = gl_area,
        .im_context = im_context.as(gtk.IMContext),
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
    self.gl_area.queueRender();
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

fn translateMouseButton(button: c_uint) ?c_int {
    return switch (button) {
        1 => cimgui.c.ImGuiMouseButton_Left,
        2 => cimgui.c.ImGuiMouseButton_Middle,
        3 => cimgui.c.ImGuiMouseButton_Right,
        else => null,
    };
}

fn gtkDestroy(_: *gtk.GLArea, self: *ImguiWidget) callconv(.c) void {
    log.debug("imgui widget destroy", .{});
    self.deinit();
}

fn gtkRealize(area: *gtk.GLArea, self: *ImguiWidget) callconv(.c) void {
    log.debug("gl surface realized", .{});

    // We need to make the context current so we can call GL functions.
    area.makeCurrent();
    if (area.getError()) |err| {
        log.err("surface failed to realize: {s}", .{err.f_message orelse "(unknown)"});
        return;
    }

    // realize means that our OpenGL context is ready, so we can now
    // initialize the ImgUI OpenGL backend for our context.
    cimgui.c.igSetCurrentContext(self.ig_ctx);
    _ = cimgui.ImGui_ImplOpenGL3_Init(null);
}

fn gtkUnrealize(area: *gtk.GLArea, self: *ImguiWidget) callconv(.c) void {
    _ = area;
    log.debug("gl surface unrealized", .{});

    cimgui.c.igSetCurrentContext(self.ig_ctx);
    cimgui.ImGui_ImplOpenGL3_Shutdown();
}

fn gtkResize(area: *gtk.GLArea, width: c_int, height: c_int, self: *ImguiWidget) callconv(.c) void {
    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    const scale_factor = area.as(gtk.Widget).getScaleFactor();
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

fn gtkRender(_: *gtk.GLArea, _: *gdk.GLContext, self: *ImguiWidget) callconv(.c) c_int {
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
    _: *gtk.EventControllerMotion,
    x: f64,
    y: f64,
    self: *ImguiWidget,
) callconv(.c) void {
    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    const scale_factor: f64 = @floatFromInt(self.gl_area.as(gtk.Widget).getScaleFactor());
    cimgui.c.ImGuiIO_AddMousePosEvent(
        io,
        @floatCast(x * scale_factor),
        @floatCast(y * scale_factor),
    );
    self.queueRender();
}

fn gtkMouseDown(
    gesture: *gtk.GestureClick,
    _: c_int,
    _: f64,
    _: f64,
    self: *ImguiWidget,
) callconv(.c) void {
    self.queueRender();

    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();

    const gdk_button = gesture.as(gtk.GestureSingle).getCurrentButton();
    if (translateMouseButton(gdk_button)) |button| {
        cimgui.c.ImGuiIO_AddMouseButtonEvent(io, button, true);
    }
}

fn gtkMouseUp(
    gesture: *gtk.GestureClick,
    _: c_int,
    _: f64,
    _: f64,
    self: *ImguiWidget,
) callconv(.c) void {
    self.queueRender();

    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    const gdk_button = gesture.as(gtk.GestureSingle).getCurrentButton();
    if (translateMouseButton(gdk_button)) |button| {
        cimgui.c.ImGuiIO_AddMouseButtonEvent(io, button, false);
    }
}

fn gtkMouseScroll(
    _: *gtk.EventControllerScroll,
    x: f64,
    y: f64,
    self: *ImguiWidget,
) callconv(.c) c_int {
    self.queueRender();

    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    cimgui.c.ImGuiIO_AddMouseWheelEvent(
        io,
        @floatCast(x),
        @floatCast(-y),
    );

    return @intFromBool(true);
}

fn gtkFocusEnter(_: *gtk.EventControllerFocus, self: *ImguiWidget) callconv(.c) void {
    self.queueRender();

    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    cimgui.c.ImGuiIO_AddFocusEvent(io, true);
}

fn gtkFocusLeave(_: *gtk.EventControllerFocus, self: *ImguiWidget) callconv(.c) void {
    self.queueRender();

    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    cimgui.c.ImGuiIO_AddFocusEvent(io, false);
}

fn gtkInputCommit(
    _: *gtk.IMMulticontext,
    bytes: [*:0]u8,
    self: *ImguiWidget,
) callconv(.c) void {
    self.queueRender();

    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
    cimgui.c.ImGuiIO_AddInputCharactersUTF8(io, bytes);
}

fn gtkKeyPressed(
    ec_key: *gtk.EventControllerKey,
    keyval: c_uint,
    keycode: c_uint,
    gtk_mods: gdk.ModifierType,
    self: *ImguiWidget,
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
    gtk_mods: gdk.ModifierType,
    self: *ImguiWidget,
) callconv(.c) void {
    _ = self.keyEvent(
        .release,
        ec_key,
        keyval,
        keycode,
        gtk_mods,
    );
}

fn keyEvent(
    self: *ImguiWidget,
    action: input.Action,
    ec_key: *gtk.EventControllerKey,
    keyval: c_uint,
    keycode: c_uint,
    gtk_mods: gdk.ModifierType,
) bool {
    _ = keycode;

    self.queueRender();

    cimgui.c.igSetCurrentContext(self.ig_ctx);
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();

    const mods = key.translateMods(gtk_mods);
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
    if (ec_key.as(gtk.EventController).getCurrentEvent()) |event| {
        _ = self.im_context.filterKeypress(event);
    }

    return true;
}
