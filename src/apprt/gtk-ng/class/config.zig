const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const CoreConfig = configpkg.Config;

const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ghostty_config);

/// Wraps a `Ghostty.Config` object in a GObject so it can be reference
/// counted. When this object is freed, the underlying config is also freed.
///
/// It is highly recommended to NOT take a reference to this object,
/// since configuration takes up a lot of memory (relatively). Instead,
/// receivers of this should usually create a `DerivedConfig` struct from
/// this, copy any memory they require, and own that structure instead.
///
/// This can also expose helpers to access configuration in ways that
/// may be more ergonomic to GTK primitives.
pub const Config = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gobject.Object;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyConfig",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const @"diagnostics-buffer" = gobject.ext.defineProperty(
            "diagnostics-buffer",
            Self,
            ?*gtk.TextBuffer,
            .{
                .accessor = gobject.ext.typedAccessor(
                    Self,
                    ?*gtk.TextBuffer,
                    .{
                        .getter = Self.diagnosticsBuffer,
                        .getter_transfer = .full,
                    },
                ),
            },
        );

        pub const @"has-diagnostics" = gobject.ext.defineProperty(
            "has-diagnostics",
            Self,
            bool,
            .{
                .default = false,
                .accessor = gobject.ext.typedAccessor(
                    Self,
                    bool,
                    .{
                        .getter = Self.hasDiagnostics,
                    },
                ),
            },
        );
    };

    const Private = struct {
        config: CoreConfig,

        pub var offset: c_int = 0;
    };

    /// Create a new GhosttyConfig from a loaded configuration.
    ///
    /// This clones the given configuration, so it is safe for the
    /// caller to free the original configuration after this call.
    pub fn new(alloc: Allocator, config: *const CoreConfig) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();

        const priv = self.private();
        priv.config = try config.clone(alloc);

        return self;
    }

    /// Get the wrapped configuration. It's unsafe to store this or access
    /// it in any way that may live beyond the lifetime of this object.
    pub fn get(self: *Self) *const CoreConfig {
        return &self.private().config;
    }

    /// Get the mutable configuration. This is usually NOT recommended
    /// because any changes to the config won't be propagated to anyone
    /// with a reference to this object. If you know what you're doing, then
    /// you can use this.
    pub fn getMut(self: *Self) *CoreConfig {
        return &self.private().config;
    }

    /// Returns whether this configuration has any diagnostics.
    pub fn hasDiagnostics(self: *Self) bool {
        const config = self.get();
        return !config._diagnostics.empty();
    }

    /// Reads the diagnostics of this configuration as a TextBuffer,
    /// or returns null if there are no diagnostics.
    pub fn diagnosticsBuffer(self: *Self) ?*gtk.TextBuffer {
        const config = self.get();
        if (config._diagnostics.empty()) return null;

        const text_buf: *gtk.TextBuffer = .new(null);
        errdefer text_buf.unref();

        var buf: [4095:0]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        for (config._diagnostics.items()) |diag| {
            fbs.reset();
            diag.write(fbs.writer()) catch |err| {
                log.warn(
                    "error writing diagnostic to buffer err={}",
                    .{err},
                );
                continue;
            };

            text_buf.insertAtCursor(&buf, @intCast(fbs.pos));
            text_buf.insertAtCursor("\n", 1);
        }

        return text_buf;
    }

    fn finalize(self: *Self) callconv(.c) void {
        self.private().config.deinit();

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
            gobject.ext.registerProperties(class, &.{
                properties.@"diagnostics-buffer",
                properties.@"has-diagnostics",
            });
        }
    };
};

// This test verifies our memory management works as expected. Since
// we use the testing allocator any leaks are detected.
test "GhosttyConfig" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var config: CoreConfig = try .default(alloc);
    defer config.deinit();
    const obj: *Config = try .new(alloc, &config);
    obj.unref();
}
