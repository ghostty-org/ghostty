const std = @import("std");
const Allocator = std.mem.Allocator;

const gobject = @import("gobject");

const configpkg = @import("../../../config.zig");
const Config = configpkg.Config;

const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ghostty_config_overrides);

/// Wrapper for a ConfigOverrides object that keeps track of which settings have
/// been changed.
pub const ConfigOverrides = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gobject.Object;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyConfigOverrides",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {};

    const Private = struct {
        config_overrides: configpkg.ConfigOverrides,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: Allocator) Allocator.Error!*ConfigOverrides {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();

        const priv: *Private = self.private();
        try priv.config_overrides.init(alloc);

        return self;
    }

    pub fn get(self: *ConfigOverrides) *configpkg.ConfigOverrides {
        const priv: *Private = self.private();
        return &priv.config_overrides;
    }

    fn finalize(self: *ConfigOverrides) callconv(.c) void {
        const priv: *Private = self.private();
        priv.config_overrides.deinit();

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
        }
    };
};

test "GhosttyConfigOverrides" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const config_overrides: *ConfigOverrides = try .new(alloc);
    defer config_overrides.unref();

    const co = config_overrides.get();

    try testing.expect(co.isSet(.@"font-size") == false);
    try co.set(.@"font-size", 24.0);
    try testing.expect(co.isSet(.@"font-size") == true);
    try testing.expectApproxEqAbs(24.0, co.get(.@"font-size"), 0.01);

    try testing.expect(co.isSet(.@"working-directory") == false);
    try co.parseCLI("--working-directory=/home/ghostty");
    try testing.expect(co.isSet(.@"working-directory") == true);
    try testing.expectEqualStrings("/home/ghostty", co.get(.@"working-directory").?);
}
