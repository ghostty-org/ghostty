//! Extensions/helpers for GTK objects, following a similar naming
//! style to zig-gobject. These should, wherever possible, be Zig-friendly
//! wrappers around existing GTK functionality, rather than complex new
//! helpers.

const std = @import("std");
const assert = std.debug.assert;

const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

/// Wrapper around `gobject.boxedCopy` to copy a boxed type `T`.
pub fn boxedCopy(comptime T: type, ptr: *const T) *T {
    const copy = gobject.boxedCopy(T.getGObjectType(), ptr);
    return @ptrCast(@alignCast(copy));
}

/// Wrapper around `gobject.boxedFree` to free a boxed type `T`.
pub fn boxedFree(comptime T: type, ptr: ?*T) void {
    if (ptr) |p| gobject.boxedFree(
        T.getGObjectType(),
        p,
    );
}

/// A wrapper around `glib.List.findCustom` to find an element in the list.
/// The type `T` must be the guaranteed type of every list element.
pub fn listFind(
    comptime T: type,
    list: *glib.List,
    comptime func: *const fn (*T) bool,
) ?*T {
    const elem_: ?*glib.List = list.findCustom(null, struct {
        fn callback(data: ?*const anyopaque, _: ?*const anyopaque) callconv(.c) c_int {
            const ptr = data orelse return 1;
            const v: *T = @ptrCast(@alignCast(@constCast(ptr)));
            return if (func(v)) 0 else 1;
        }
    }.callback);
    const elem = elem_ orelse return null;
    return @ptrCast(@alignCast(elem.f_data));
}

/// Wrapper around `gtk.Widget.getAncestor` to get the widget ancestor
/// of the given type `T`, or null if it doesn't exist.
pub fn getAncestor(comptime T: type, widget: *gtk.Widget) ?*T {
    const ancestor_ = widget.getAncestor(gobject.ext.typeFor(T));
    const ancestor = ancestor_ orelse return null;
    // We can assert the unwrap because getAncestor above
    return gobject.ext.cast(T, ancestor).?;
}

/// Check that an action name is valid.
///
/// Reimplementation of g_action_name_is_valid so that it can be
/// use at comptime.
///
/// See:
/// https://docs.gtk.org/gio/type_func.Action.name_is_valid.html
fn actionNameIsValid(name: [:0]const u8) bool {
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

test "actionNameIsValid" {
    const testing = std.testing;
    testing.expect(actionNameIsValid("ring-bell"));
    testing.expect(!actionNameIsValid("ring_bell"));
}

/// Create a structure for describing an action.
pub fn Action(comptime T: type) type {
    return struct {
        name: [:0]const u8,
        callback: *const fn (*gio.SimpleAction, ?*glib.Variant, *T) callconv(.c) void,
        parameter_type: ?*const glib.VariantType,
    };
}

/// Add actions to a widget that doesn't implement ActionGroup directly.
pub fn addActionsAsGroup(comptime T: type, self: *T, comptime name: [:0]const u8, comptime actions: []const Action(T)) void {
    comptime assert(actionNameIsValid(name));

    // Collect our actions into a group since we're just a plain widget that
    // doesn't implement ActionGroup directly.
    const group = gio.SimpleActionGroup.new();
    errdefer group.unref();

    const map = group.as(gio.ActionMap);
    inline for (actions) |entry| {
        comptime assert(actionNameIsValid(entry.name));
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

    self.as(gtk.Widget).insertActionGroup(
        name,
        group.as(gio.ActionGroup),
    );
}
