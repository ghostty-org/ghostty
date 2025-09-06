const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const i18n = @import("../../../os/main.zig").i18n;
const adw_version = @import("../adw_version.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Dialog = @import("dialog.zig").Dialog;

const log = std.log.scoped(.gtk_ghostty_close_confirmation_dialog);

pub const CloseConfirmationDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = Dialog;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyCloseConfirmationDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const target = struct {
            pub const name = "target";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                Target,
                .{
                    .default = .app,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "target",
                    ),
                },
            );
        };
    };

    pub const signals = struct {
        pub const @"close-request" = struct {
            pub const name = "close-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };

        pub const cancel = struct {
            pub const name = "cancel";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };

    const Private = struct {
        target: Target,
        pub var offset: c_int = 0;
    };

    pub fn new(target: Target) *Self {
        return gobject.ext.newInstance(Self, .{
            .target = target,
        });
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    pub fn present(self: *Self, parent: ?*gtk.Widget) void {
        // Setup our title/body text.
        const priv = self.private();
        self.as(Dialog.Parent).setHeading(priv.target.title());
        self.as(Dialog.Parent).setBody(priv.target.body());

        // Show it
        self.as(Dialog).present(parent);
    }

    pub fn close(self: *Self) void {
        self.as(Dialog).close();
    }

    fn response(
        self: *Self,
        response_id: [*:0]const u8,
    ) callconv(.c) void {
        if (std.mem.orderZ(u8, response_id, "close") == .eq) {
            signals.@"close-request".impl.emit(
                self,
                null,
                .{},
                null,
            );
        } else {
            signals.cancel.impl.emit(
                self,
                null,
                .{},
                null,
            );
        }
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
            gobject.ext.ensureType(Dialog);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 2,
                    .name = "close-confirmation-dialog",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.target.impl,
            });

            // Signals
            signals.@"close-request".impl.register(.{});
            signals.cancel.impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            Dialog.virtual_methods.response.implement(class, &response);
        }

        pub const as = C.Class.as;
    };
};

/// The target of a close dialog.
///
/// This is here so that we can consolidate all logic related to
/// prompting the user and closing windows/tabs/surfaces/etc.
/// together into one struct that is the sole source of truth.
pub const Target = enum(c_int) {
    app,
    tab,
    window,
    surface,

    pub fn title(self: Target) [*:0]const u8 {
        return switch (self) {
            .app => i18n._("Quit Ghostty?"),
            .tab => i18n._("Close Tab?"),
            .window => i18n._("Close Window?"),
            .surface => i18n._("Close Split?"),
        };
    }

    pub fn body(self: Target) [*:0]const u8 {
        return switch (self) {
            .app => i18n._("All terminal sessions will be terminated."),
            .tab => i18n._("All terminal sessions in this tab will be terminated."),
            .window => i18n._("All terminal sessions in this window will be terminated."),
            .surface => i18n._("The currently running process in this split will be terminated."),
        };
    }

    pub const getGObjectType = gobject.ext.defineEnum(
        Target,
        .{ .name = "GhosttyCloseConfirmationDialogTarget" },
    );
};
