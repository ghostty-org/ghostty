const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;

const cimgui = @import("dcimgui");
const gl = @import("opengl");
const adw = @import("adw");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");

const input = @import("../../../input.zig");
const gresource = @import("../build/gresource.zig");

const key = @import("../key.zig");
const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ghostty_imgui_widget);

/// A widget for embedding a Dear ImGui application.
///
/// It'd be a lot cleaner to use inheritance here but zig-gobject doesn't
/// currently have a way to define virtual methods, so we have to use
/// composition and signals instead.
pub const ImguiWidget = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyImguiWidget",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {};

    pub const signals = struct {};

    pub const virtual_methods = struct {
        /// This virtual method will be called to allow the Dear ImGui
        /// application to do one-time setup of the context. The correct context
        /// will be current when the virtual method is called.
        pub const setup = C.defineVirtualMethod("setup");

        /// This virtual method will be called at each frame to allow the Dear
        /// ImGui application to draw the application. The correct context will
        /// be current when the virtual method is called.
        pub const render = C.defineVirtualMethod("render");
    };

    const Private = struct {
        /// GL area where we display the Dear ImGui application.
        gl_area: *gtk.GLArea,

        /// GTK input method context
        im_context: *gtk.IMMulticontext,

        /// Dear ImGui context. We create a context per widget so that we can
        /// have multiple active imgui views in the same application.
        ig_context: ?*cimgui.c.ImGuiContext = null,

        /// Our previous instant used to calculate delta time for animations.
        instant: ?std.time.Instant = null,

        /// Tick callback ID for timed updates.
        tick_callback_id: c_uint = 0,

        /// Last render time for throttling to 30 FPS.
        last_render_time: ?std.time.Instant = null,

        pub var offset: c_int = 0;
    };

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Public methods

    /// This should be called anytime the underlying data for the UI changes
    /// so that the UI can be refreshed.
    pub fn queueRender(self: *ImguiWidget) void {
        const priv = self.private();
        priv.gl_area.queueRender();
    }

    //---------------------------------------------------------------
    // Public wrappers for virtual methods

    /// This virtual method will be called to allow the Dear ImGui application
    /// to do one-time setup of the context. The correct context will be current
    /// when the virtual method is called.
    pub fn setup(self: *Self) callconv(.c) void {
        const class = self.getClass() orelse return;
        virtual_methods.setup.call(class, self, .{});
    }

    /// This virtual method will be called at each frame to allow the Dear ImGui
    /// application to draw the application. The correct context will be current
    /// when the virtual method is called.
    pub fn render(self: *Self) callconv(.c) void {
        const class = self.getClass() orelse return;
        virtual_methods.render.call(class, self, .{});
    }

    //---------------------------------------------------------------
    // Private Methods

    /// Set our imgui context to be current, or return an error. This must be
    /// called before any Dear ImGui API calls so that they're made against
    /// the proper context.
    fn setCurrentContext(self: *Self) error{ContextNotInitialized}!void {
        const priv = self.private();
        const ig_context = priv.ig_context orelse {
            log.warn("Dear ImGui context not initialized", .{});
            return error.ContextNotInitialized;
        };
        cimgui.c.ImGui_SetCurrentContext(ig_context);
    }

    /// Initialize the frame. Expects that the context is already current.
    fn newFrame(self: *Self) void {
        const priv = self.private();
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // Determine our delta time
        const now = std.time.Instant.now() catch unreachable;
        io.DeltaTime = if (priv.instant) |prev| delta: {
            const since_ns: f64 = @floatFromInt(now.since(prev));
            const ns_per_s: f64 = @floatFromInt(std.time.ns_per_s);
            const since_s: f32 = @floatCast(since_ns / ns_per_s);
            break :delta @max(0.00001, since_s);
        } else (1.0 / 60.0);

        priv.instant = now;
    }

    /// Handle key press/release events.
    fn keyEvent(
        self: *ImguiWidget,
        action: input.Action,
        ec_key: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        gtk_mods: gdk.ModifierType,
    ) bool {
        self.queueRender();

        self.setCurrentContext() catch return false;

        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

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
            const priv = self.private();
            _ = priv.im_context.as(gtk.IMContext).filterKeypress(event);
        }

        return true;
    }

    /// Translate a GTK mouse button to a Dear ImGui mouse button.
    fn translateMouseButton(button: c_uint) ?c_int {
        return switch (button) {
            1 => cimgui.c.ImGuiMouseButton_Left,
            2 => cimgui.c.ImGuiMouseButton_Middle,
            3 => cimgui.c.ImGuiMouseButton_Right,
            else => null,
        };
    }

    /// Get the scale factor that the display is operating at.
    fn getScaleFactor(self: *Self) f64 {
        const priv = self.private();
        return @floatFromInt(priv.gl_area.as(gtk.Widget).getScaleFactor());
    }

    //---------------------------------------------------------------
    // Properties

    //---------------------------------------------------------------
    // Signal Handlers

    fn glAreaRealize(_: *gtk.GLArea, self: *Self) callconv(.c) void {
        const priv = self.private();
        assert(priv.ig_context == null);

        priv.gl_area.makeCurrent();
        if (priv.gl_area.getError()) |err| {
            log.warn("GLArea for Dear ImGui widget failed to realize: {s}", .{err.f_message orelse "(unknown)"});
            return;
        }

        priv.ig_context = cimgui.c.ImGui_CreateContext(null) orelse {
            log.warn("unable to initialize Dear ImGui context", .{});
            return;
        };
        self.setCurrentContext() catch return;

        // Setup some basic config
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.BackendPlatformName = "ghostty_gtk";

        // Realize means that our OpenGL context is ready, so we can now
        // initialize the ImgUI OpenGL backend for our context.
        _ = cimgui.ImGui_ImplOpenGL3_Init(null);

        // Call the virtual method to setup the UI.
        self.setup();

        // Add a tick callback to drive timed updates via the frame clock.
        priv.tick_callback_id = self.as(gtk.Widget).addTickCallback(
            tickCallback,
            null,
            null,
        );
    }

    /// Handle a request to unrealize the GLArea
    fn glAreaUnrealize(_: *gtk.GLArea, self: *ImguiWidget) callconv(.c) void {
        const priv = self.private();
        assert(priv.ig_context != null);

        // Remove the tick callback if it was registered.
        if (priv.tick_callback_id != 0) {
            self.as(gtk.Widget).removeTickCallback(priv.tick_callback_id);
            priv.tick_callback_id = 0;
        }

        // Unrealize is not guaranteed to be called with a current GL context,
        // so we make it current for ImGui cleanup.
        priv.gl_area.makeCurrent();
        if (priv.gl_area.getError()) |err| {
            log.warn("GLArea for Dear ImGui widget failed to realize: {s}", .{err.f_message orelse "(unknown)"});
            return;
        }

        self.setCurrentContext() catch return;
        cimgui.ImGui_ImplOpenGL3_ShutdownWithLoaderCleanup();
        cimgui.c.ImGui_DestroyContext(priv.ig_context);
        priv.ig_context = null;
    }

    /// Handle a request to resize the GLArea
    fn glAreaResize(area: *gtk.GLArea, width: c_int, height: c_int, self: *Self) callconv(.c) void {
        self.setCurrentContext() catch return;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        const scale_factor = area.as(gtk.Widget).getScaleFactor();

        // Our display size is always unscaled. We'll do the scaling in the
        // style instead. This creates crisper looking fonts.
        io.DisplaySize = .{ .x = @floatFromInt(width), .y = @floatFromInt(height) };
        io.DisplayFramebufferScale = .{ .x = 1, .y = 1 };

        // Setup a new style and scale it appropriately. We must use the
        // ImGuiStyle constructor to get proper default values (e.g.,
        // CurveTessellationTol) rather than zero-initialized values.
        var style: cimgui.c.ImGuiStyle = undefined;
        cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
        cimgui.c.ImGuiStyle_ScaleAllSizes(&style, @floatFromInt(scale_factor));
        const active_style = cimgui.c.ImGui_GetStyle();
        active_style.* = style;
    }

    /// Handle a request to render the contents of our GLArea
    fn glAreaRender(_: *gtk.GLArea, _: *gdk.GLContext, self: *Self) callconv(.c) c_int {
        self.setCurrentContext() catch return @intFromBool(false);

        // Update last render time for tick callback throttling.
        const priv = self.private();
        priv.last_render_time = std.time.Instant.now() catch null;

        // Setup our frame. We render twice because some ImGui behaviors
        // take multiple renders to process. I don't know how to make this
        // more efficient.
        for (0..2) |_| {
            cimgui.ImGui_ImplOpenGL3_NewFrame();
            self.newFrame();
            cimgui.c.ImGui_NewFrame();

            // Call the virtual method to draw the UI.
            self.render();

            // Render
            cimgui.c.ImGui_Render();
        }

        // OpenGL final render
        gl.clearColor(0x28 / 0xFF, 0x2C / 0xFF, 0x34 / 0xFF, 1.0);
        gl.clear(gl.c.GL_COLOR_BUFFER_BIT);
        cimgui.ImGui_ImplOpenGL3_RenderDrawData(cimgui.c.ImGui_GetDrawData());

        return @intFromBool(true);
    }

    fn ecFocusEnter(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        self.setCurrentContext() catch return;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddFocusEvent(io, true);
        self.queueRender();
    }

    fn ecFocusLeave(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        self.setCurrentContext() catch return;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddFocusEvent(io, false);
        self.queueRender();
    }

    fn ecKeyPressed(
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

    fn ecKeyReleased(
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

    fn ecMousePressed(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *ImguiWidget,
    ) callconv(.c) void {
        self.queueRender();
        self.setCurrentContext() catch return;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        const gdk_button = gesture.as(gtk.GestureSingle).getCurrentButton();
        if (translateMouseButton(gdk_button)) |button| {
            cimgui.c.ImGuiIO_AddMouseButtonEvent(io, button, true);
        }
    }

    fn ecMouseReleased(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *ImguiWidget,
    ) callconv(.c) void {
        self.queueRender();
        self.setCurrentContext() catch return;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        const gdk_button = gesture.as(gtk.GestureSingle).getCurrentButton();
        if (translateMouseButton(gdk_button)) |button| {
            cimgui.c.ImGuiIO_AddMouseButtonEvent(io, button, false);
        }
    }

    fn ecMouseMotion(
        _: *gtk.EventControllerMotion,
        x: f64,
        y: f64,
        self: *ImguiWidget,
    ) callconv(.c) void {
        self.queueRender();
        self.setCurrentContext() catch return;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        const scale_factor = self.getScaleFactor();
        cimgui.c.ImGuiIO_AddMousePosEvent(
            io,
            @floatCast(x * scale_factor),
            @floatCast(y * scale_factor),
        );
    }

    fn ecMouseScroll(
        _: *gtk.EventControllerScroll,
        x: f64,
        y: f64,
        self: *ImguiWidget,
    ) callconv(.c) c_int {
        self.queueRender();
        self.setCurrentContext() catch return @intFromBool(false);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddMouseWheelEvent(
            io,
            @floatCast(x),
            @floatCast(-y),
        );
        return @intFromBool(true);
    }

    fn imCommit(
        _: *gtk.IMMulticontext,
        bytes: [*:0]u8,
        self: *ImguiWidget,
    ) callconv(.c) void {
        self.queueRender();
        self.setCurrentContext() catch return;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddInputCharactersUTF8(io, bytes);
    }

    /// Tick callback for timed updates. This drives periodic redraws.
    /// Redraws are limited to 30 FPS max since our imgui widgets don't
    /// usually need higher frame rates than that.
    fn tickCallback(
        widget: *gtk.Widget,
        _: *gdk.FrameClock,
        _: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *Self = gobject.ext.cast(Self, widget) orelse return 0;
        const priv = self.private();

        const now = std.time.Instant.now() catch {
            self.queueRender();
            return 1;
        };

        // Throttle to 30 FPS (~33ms between frames)
        const frame_time_ns: u64 = std.time.ns_per_s / 30;
        const should_render = if (priv.last_render_time) |last|
            now.since(last) >= frame_time_ns
        else
            true;

        if (should_render) self.queueRender();

        return 1; // Continue the tick callback
    }

    //---------------------------------------------------------------
    // Default virtual method handlers

    /// Default setup function. Does nothing but log a warning.
    fn defaultSetup(_: *Self) callconv(.c) void {
        log.warn("default Dear ImGui setup called, this is a bug.", .{});
    }

    /// Default render function. Does nothing but log a warning.
    fn defaultRender(_: *Self) callconv(.c) void {
        log.warn("default Dear ImGui render called, this is a bug.", .{});
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    pub const getClass = C.getClass;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,

        /// Function pointers for virtual methods.
        setup: ?*const fn (*Self) callconv(.c) void,
        render: ?*const fn (*Self) callconv(.c) void,

        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "imgui-widget",
                }),
            );

            // Initialize our virtual methods with default functions.
            class.setup = defaultSetup;
            class.render = defaultRender;

            // Bindings
            class.bindTemplateChildPrivate("gl_area", .{});
            class.bindTemplateChildPrivate("im_context", .{});

            // Template Callbacks
            class.bindTemplateCallback("realize", &glAreaRealize);
            class.bindTemplateCallback("unrealize", &glAreaUnrealize);
            class.bindTemplateCallback("resize", &glAreaResize);
            class.bindTemplateCallback("render", &glAreaRender);
            class.bindTemplateCallback("focus_enter", &ecFocusEnter);
            class.bindTemplateCallback("focus_leave", &ecFocusLeave);
            class.bindTemplateCallback("key_pressed", &ecKeyPressed);
            class.bindTemplateCallback("key_released", &ecKeyReleased);
            class.bindTemplateCallback("mouse_pressed", &ecMousePressed);
            class.bindTemplateCallback("mouse_released", &ecMouseReleased);
            class.bindTemplateCallback("mouse_motion", &ecMouseMotion);
            class.bindTemplateCallback("scroll", &ecMouseScroll);
            class.bindTemplateCallback("im_commit", &imCommit);

            // Signals

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
