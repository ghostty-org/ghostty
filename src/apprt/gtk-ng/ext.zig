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

/// Defines functions for getting and setting a property of `Owner` of type
/// `gtk.Expression`.
pub fn ExpressionAccessor(comptime Owner: type) type {
    return struct {
        getter: ?*const fn (*Owner) ?*gtk.Expression = null,
        setter: ?*const fn (*Owner, ?*gtk.Expression) void = null,
    };
}

/// Options for defining expression properties.
pub fn DefineExpressionPropertyOptions(comptime Owner: type) type {
    return struct {
        nick: ?[:0]const u8 = null,
        blurb: ?[:0]const u8 = null,
        accessor: ExpressionAccessor(Owner),
        construct: bool = false,
        construct_only: bool = false,
        lax_validation: bool = false,
        explicit_notify: bool = false,
        deprecated: bool = false,
    };
}

/// Define a property that holds a GTK Expression value.
pub fn defineExpressionProperty(
    comptime name: [:0]const u8,
    comptime Owner: type,
    comptime options: DefineExpressionPropertyOptions(Owner),
) type {
    return struct {
        /// The `gobject.ParamSpec` of the property. Initialized once the
        /// property is registered.
        pub var param_spec: *gobject.ParamSpec = undefined;

        /// Registers the property.
        ///
        /// This is a lower-level function which should generally not be used
        /// directly. Users should generally call `registerProperties` instead,
        /// which handles registration of all a class's properties at once,
        /// along with configuring behavior for
        /// `gobject.Object.virtual_methods.get_property` and
        /// `gobject.Object.virtual_methods.set_property`.
        pub fn register(class: *Owner.Class, id: c_uint) void {
            param_spec = newParamSpec();
            gobject.Object.Class.installProperty(gobject.ext.as(gobject.Object.Class, class), id, param_spec);
        }

        /// Gets the value of the property from `object` and stores it in
        /// `value`.
        pub fn get(object: *Owner, value: *gobject.Value) void {
            if (options.accessor.getter) |getter| {
                const expression = getter(object) orelse return;
                gtk.valueSetExpression(value, expression);
            }
        }

        /// Sets the value of the property on `object` from `value`.
        pub fn set(object: *Owner, value: *const gobject.Value) void {
            if (options.accessor.setter) |setter| {
                const expression = gtk.valueGetExpression(value);
                setter(object, expression);
            }
        }

        fn newParamSpec() *gobject.ParamSpec {
            const flags: gobject.ParamFlags = .{
                .readable = options.accessor.getter != null,
                .writable = options.accessor.setter != null,
                .construct = options.construct,
                .construct_only = options.construct_only,
                .lax_validation = options.lax_validation,
                .explicit_notify = options.explicit_notify,
                .deprecated = options.deprecated,
                // Since the name and options are comptime, we can set these flags
                // unconditionally.
                .static_name = true,
                .static_nick = true,
                .static_blurb = true,
            };

            return gtk.paramSpecExpression(
                name,
                options.nick orelse "",
                options.nick orelse "",
                flags,
            );
        }
    };
}

test {
    _ = actions;
}
