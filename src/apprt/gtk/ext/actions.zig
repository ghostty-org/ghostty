const std = @import("std");

const assert = std.debug.assert;
const testing = std.testing;

const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gValueHolds = @import("../ext.zig").gValueHolds;

/// Check that an action name is valid.
///
/// Reimplementation of `g_action_name_is_valid()` so that it can be
/// used at comptime.
///
/// See:
/// https://docs.gtk.org/gio/type_func.Action.name_is_valid.html
fn gActionNameIsValid(name: [:0]const u8) bool {
    if (name.len == 0) return false;

    for (name) |c| switch (c) {
        '-' => continue,
        '.' => continue,
        '0'...'9' => continue,
        'a'...'z' => continue,
        'A'...'Z' => continue,
        else => return false,
    };

    return true;
}

test "gActionNameIsValid" {
    try testing.expect(gActionNameIsValid("ring-bell"));
    try testing.expect(!gActionNameIsValid("ring_bell"));
}

/// Function to create a structure for describing an action.
pub fn Action(comptime T: type) type {
    return struct {
        pub const Callback = *const fn (*gio.SimpleAction, ?*glib.Variant, *T) callconv(.c) void;

        name: [:0]const u8,
        callback: Callback,
        parameter_type: ?*const glib.VariantType,

        /// Function to initialize a new action so that we can comptime check the name.
        pub fn init(comptime name: [:0]const u8, callback: Callback, parameter_type: ?*const glib.VariantType) @This() {
            comptime assert(gActionNameIsValid(name));

            return .{
                .name = name,
                .callback = callback,
                .parameter_type = parameter_type,
            };
        }
    };
}

/// Add actions to a widget that implements gio.ActionMap.
pub fn add(comptime T: type, self: *T, actions: []const Action(T)) void {
    addToMap(T, self, self.as(gio.ActionMap), actions);
}

/// Add actions to the given map.
pub fn addToMap(comptime T: type, self: *T, map: *gio.ActionMap, actions: []const Action(T)) void {
    for (actions) |entry| {
        assert(gActionNameIsValid(entry.name));
        const action = gio.SimpleAction.new(
            entry.name,
            entry.parameter_type,
        );
        defer action.unref();
        _ = gio.SimpleAction.signals.activate.connect(
            action,
            *T,
            entry.callback,
            self,
            .{},
        );
        map.addAction(action.as(gio.Action));
    }
}

/// Add actions to a widget that doesn't implement ActionGroup directly.
pub fn addAsGroup(comptime T: type, self: *T, comptime name: [:0]const u8, actions: []const Action(T)) void {
    comptime assert(gActionNameIsValid(name));

    // Collect our actions into a group since we're just a plain widget that
    // doesn't implement ActionGroup directly.
    const group = gio.SimpleActionGroup.new();
    errdefer group.unref();

    addToMap(T, self, group.as(gio.ActionMap), actions);

    self.as(gtk.Widget).insertActionGroup(
        name,
        group.as(gio.ActionGroup),
    );
}

test "adding actions to an object" {
    // This test requires a connection to an active display environment.
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    _ = glib.MainContext.acquire(null);
    defer glib.MainContext.release(null);

    const callbacks = struct {
        fn callback(_: *gio.SimpleAction, variant_: ?*glib.Variant, self: *gtk.Box) callconv(.c) void {
            const i32_variant_type = glib.ext.VariantType.newFor(i32);
            defer i32_variant_type.free();

            const variant = variant_ orelse return;
            assert(variant.isOfType(i32_variant_type) != 0);

            var value = std.mem.zeroes(gobject.Value);
            _ = value.init(gobject.ext.types.int);
            defer value.unset();

            value.setInt(variant.getInt32());

            self.as(gobject.Object).setProperty("spacing", &value);
        }
    };

    const box = gtk.Box.new(.vertical, 0);
    _ = box.as(gobject.Object).refSink();
    defer box.unref();

    {
        const i32_variant_type = glib.ext.VariantType.newFor(i32);
        defer i32_variant_type.free();

        const actions = [_]Action(gtk.Box){
            .init("test", callbacks.callback, i32_variant_type),
        };

        addAsGroup(gtk.Box, box, "test", &actions);
    }

    const expected = std.crypto.random.intRangeAtMost(i32, 1, std.math.maxInt(u31));
    const parameter = glib.Variant.newInt32(expected);

    try testing.expect(box.as(gtk.Widget).activateActionVariant("test.test", parameter) != 0);

    _ = glib.MainContext.iteration(null, @intFromBool(true));

    var value = std.mem.zeroes(gobject.Value);
    _ = value.init(gobject.ext.types.int);
    defer value.unset();

    box.as(gobject.Object).getProperty("spacing", &value);

    try testing.expect(gValueHolds(&value, gobject.ext.types.int));

    const actual = value.getInt();
    try testing.expectEqual(expected, actual);

    while (glib.MainContext.iteration(null, 0) != 0) {}
}
