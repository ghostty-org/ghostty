const std = @import("std");

const App = @import("App.zig");
const Window = @import("Window.zig");
const Tab = @import("Tab.zig");
const Surface = @import("Surface.zig");
const adwaita = @import("adwaita.zig");

const gobject = @import("gobject");
const gio = @import("gio");
const adw = @import("adw");
const gtk = @import("gtk");

/// The dialog opened whenever the user requests to close a
/// window/tab/split/etc. but there's still one or more running
/// processes inside the target that cannot be closed automatically.
/// We then ask the user whether they want to terminate existing processes.
///
/// Implemented as a simple subclass of Adw.AlertDialog that has
/// styling and content specific to the target.
pub const CloseDialog = extern struct {
    // Mostly just GObject boilerplate
    parent: Parent,

    pub const Parent = adw.AlertDialog;

    const Private = struct {
        target: Target,

        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(CloseDialog, .{
        .instanceInit = init,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub fn new() *CloseDialog {
        return gobject.ext.newInstance(CloseDialog, .{});
    }

    pub fn show(self: *CloseDialog, target: Target) void {
        const super = self.as(Parent);

        // If we don't have a possible window to ask the user,
        // in most situations (e.g. when a split isn't attached to a window)
        // we should just close unconditionally.
        const dialog_window = target.dialogWindow() orelse {
            target.close();
            self.as(gtk.Widget).unref();
            return;
        };

        self.private().target = target;
        super.setHeading(target.title());
        super.setBody(target.body());

        super.choose(
            dialog_window.as(gtk.Widget),
            null,
            closeCallback,
            null,
        );
    }

    fn init(self: *CloseDialog, _: *Class) callconv(.C) void {
        const dialog = self.as(Parent);
        dialog.addResponse("cancel", "Cancel");
        dialog.setCloseResponse("cancel");
        dialog.setDefaultResponse("cancel");

        dialog.addResponse("close", "Close");
        dialog.setResponseAppearance("close", .destructive);
    }

    fn closeCallback(
        source_object: ?*gobject.Object,
        result: *gio.AsyncResult,
        _: ?*anyopaque,
    ) callconv(.C) void {
        const self = gobject.ext.cast(CloseDialog, source_object.?).?;
        const resp = self.as(Parent).chooseFinish(result);

        if (std.mem.orderZ(u8, resp, "close") == .eq) {
            self.private().target.close();
        }
    }

    // More GObject boilerplate
    pub fn as(self: *CloseDialog, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn private(self: *CloseDialog) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    pub const Class = extern struct {
        parent: Parent.Class,

        pub const Instance = CloseDialog;
    };

    /// The target of this close dialog.
    ///
    /// This is here so that we can consolidate all logic related to
    /// prompting the user and closing windows/tabs/surfaces/etc.
    /// together into one struct that is the sole source of truth.
    pub const Target = union(enum) {
        app: *App,
        window: *Window,
        tab: *Tab,
        surface: *Surface,

        pub fn title(self: Target) [:0]const u8 {
            return switch (self) {
                .app => "Quit Ghostty?",
                .window => "Close Window?",
                .tab => "Close Tab?",
                .surface => "Close Surface?",
            };
        }

        pub fn body(self: Target) [:0]const u8 {
            return switch (self) {
                .app => "All terminal sessions will be terminated.",
                .window => "All terminal sessions in this window will be terminated.",
                .tab => "All terminal sessions in this tab will be terminated.",
                .surface => "The currently running process in this surface will be terminated.",
            };
        }

        pub fn dialogWindow(self: Target) ?*gtk.Window {
            return switch (self) {
                .app => {
                    // Find the currently focused window. We don't store this
                    // anywhere inside the App structure for some reason, so
                    // we have to query every single open window and see which
                    // one is active (focused and receiving keyboard input)
                    const list = gtk.Window.listToplevels();
                    defer list.free();

                    const focused = list.findCustom(null, findActiveWindow);
                    return @ptrCast(@alignCast(focused.f_data));
                },
                .window => |v| @ptrCast(v.window),
                .tab => |v| @ptrCast(v.window.window),
                .surface => |v| surface: {
                    const window_ = v.container.window() orelse return null;
                    break :surface @ptrCast(window_.window);
                },
            };
        }

        fn close(self: Target) void {
            return switch (self) {
                .app => |v| v.quitNow(),
                .window => |v| gtk.Window.destroy(@ptrCast(v.window)),
                .tab => |v| v.remove(),
                .surface => |v| v.container.remove(),
            };
        }
    };
};

fn findActiveWindow(data: ?*const anyopaque, _: ?*const anyopaque) callconv(.C) c_int {
    const window: *gtk.Window = @ptrCast(@alignCast(@constCast(data orelse return -1)));

    // Confusingly, `isActive` returns 1 when active,
    // but we want to return 0 to indicate equality.
    // Abusing integers to be enums and booleans is a terrible idea, C.
    return if (window.isActive() > 0) 0 else -1;
}
