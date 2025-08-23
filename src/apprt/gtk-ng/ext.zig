//! Extensions/helpers for GTK objects, following a similar naming
//! style to zig-gobject. These should, wherever possible, be Zig-friendly
//! wrappers around existing GTK functionality, rather than complex new
//! helpers.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

pub const actions = @import("ext/actions.zig");

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

/// Check a gobject.Value to see what type it is wrapping. This is equivalent to GTK's
/// `G_VALUE_HOLDS()` macro but Zig's C translator does not like it.
pub fn gValueHolds(value_: ?*const gobject.Value, g_type: gobject.Type) bool {
    const value = value_ orelse return false;
    if (value.f_g_type == g_type) return true;
    return gobject.typeCheckValueHolds(value, g_type) != 0;
}

test {
    _ = actions;
}
