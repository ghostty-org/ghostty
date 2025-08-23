const std = @import("std");

const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Inspector = @import("../../../inspector/Inspector.zig");

const Common = @import("../class.zig").Common;
const Surface = @import("surface.zig").Surface;
const ImguiWidget = @import("imgui_widget.zig").ImguiWidget;

const log = std.log.scoped(.gtk_ghostty_inspector_widget);

/// Widget for displaying the Ghostty inspector.
pub const InspectorWidget = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = ImguiWidget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyInspectorWidget",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const surface = struct {
            pub const name = "surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = .{
                        .getter = getSurfaceValue,
                        .setter = setSurfaceValue,
                    },
                },
            );
        };
    };

    pub const signals = struct {};

    const Private = struct {
        /// The surface that we are attached to. This is NOT referenced.
        /// We attach a weak notify to the object.
        surface: ?*Surface = null,

        pub var offset: c_int = 0;
    };

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        // Clear our surface so it deactivates the inspector.
        self.setSurface(null);

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    /// Called to do initial setup of the UI.
    fn imguiSetup(
        _: *Self,
    ) callconv(.c) void {
        Inspector.setup();
    }

    /// Called for every frame to draw the UI.
    fn imguiRender(
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const surface = priv.surface orelse return;
        const core_surface = surface.core() orelse return;
        const inspector = core_surface.inspector orelse return;
        inspector.render();
    }

    //---------------------------------------------------------------
    // Public methods

    /// Queue a render of the Dear ImGui widget.
    pub fn queueRender(self: *Self) void {
        self.as(ImguiWidget).queueRender();
    }

    //---------------------------------------------------------------
    // Properties

    fn getSurfaceValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(
            value,
            self.private().surface,
        );
    }

    fn setSurfaceValue(self: *Self, value: *const gobject.Value) void {
        self.setSurface(gobject.ext.Value.get(
            value,
            ?*Surface,
        ));
    }

    pub fn getSurface(self: *Self) ?*Surface {
        return self.private().surface;
    }

    pub fn setSurface(self: *Self, surface_: ?*Surface) void {
        const priv = self.private();

        // Do nothing if we're not changing the value.
        if (surface_ == priv.surface) return;

        // Setup our notification to happen at the end because we're
        // changing values no matter what.
        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.surface.impl.param_spec);

        // Deactivate the inspector on the old surface if it exists
        // and set our value to null.
        if (priv.surface) |old| old: {
            priv.surface = null;

            // Remove our weak ref
            old.as(gobject.Object).weakUnref(
                surfaceWeakNotify,
                self,
            );

            // Deactivate the inspector
            const core_surface = old.core() orelse break :old;
            core_surface.deactivateInspector();
        }

        // Activate the inspector on the new surface.
        const surface = surface_ orelse return;
        const core_surface = surface.core() orelse return;
        core_surface.activateInspector() catch |err| {
            log.warn("failed to activate inspector err={}", .{err});
            return;
        };

        // We use a weak reference on surface to determine if the surface
        // was closed while our inspector was active.
        surface.as(gobject.Object).weakRef(
            surfaceWeakNotify,
            self,
        );

        // Store our surface. We don't need to ref this because we setup
        // the weak notify above.
        priv.surface = surface;

        self.queueRender();
    }

    //---------------------------------------------------------------
    // Signal Handlers

    fn surfaceWeakNotify(
        ud: ?*anyopaque,
        surface: *gobject.Object,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        const priv = self.private();

        // The weak notify docs call out that we can specifically use the
        // pointer values for comparison, but the objects themselves are unsafe.
        if (@intFromPtr(priv.surface) != @intFromPtr(surface)) return;

        // According to weak notify docs, "surface" is in the "dispose" state.
        // Our surface doesn't clear the core surface until the "finalize"
        // state so we should be able to safely access it here. We need to
        // be really careful though.
        const old = priv.surface orelse return;
        const core_surface = old.core() orelse return;
        core_surface.deactivateInspector();
        priv.surface = null;
        self.as(gobject.Object).notifyByPspec(properties.surface.impl.param_spec);

        // Note: in the future we should probably show some content on our
        // window to note that the surface went away in case our embedding
        // widget doesn't close itself. As I type this, our window closes
        // immediately when the surface goes away so you don't see this, but
        // for completeness sake we should clean this up.
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(ImguiWidget);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "inspector-widget",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.surface.impl,
            });

            // Signals

            // Virtual methods
            ImguiWidget.virtual_methods.setup.implement(class, imguiSetup);
            ImguiWidget.virtual_methods.render.implement(class, imguiRender);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
