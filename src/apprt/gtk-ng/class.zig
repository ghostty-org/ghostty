//! This files contains all the GObject classes for the GTK apprt
//! along with helpers to work with them.

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ext = @import("ext.zig");
pub const Application = @import("class/application.zig").Application;
pub const Window = @import("class/window.zig").Window;
pub const Config = @import("class/config.zig").Config;
pub const Surface = @import("class/surface.zig").Surface;

/// Common methods for all GObject classes we create.
pub fn Common(
    comptime Self: type,
    comptime Private: ?type,
) type {
    return struct {
        /// Upcast our type to a parent type or interface. This will fail at
        /// compile time if the cast isn't 100% safe. For unsafe casts,
        /// use `gobject.ext.cast` instead. We don't have a helper for that
        /// because its uncommon and unsafe behavior should be noisier.
        pub fn as(self: *Self, comptime T: type) *T {
            return gobject.ext.as(T, self);
        }

        /// Increase the reference count of the object.
        pub fn ref(self: *Self) *Self {
            return @ptrCast(@alignCast(gobject.Object.ref(self.as(gobject.Object))));
        }

        /// If the reference count is 1 and the object is floating, clear the
        /// floating attribute. Otherwise, increase the reference count by 1.
        pub fn refSink(self: *Self) *Self {
            return @ptrCast(@alignCast(gobject.Object.refSink(self.as(gobject.Object))));
        }

        /// Decrease the reference count of the object.
        pub fn unref(self: *Self) void {
            gobject.Object.unref(self.as(gobject.Object));
        }

        /// Access the private data of the object. This should be forwarded
        /// via a non-pub const usually.
        pub const private = if (Private) |P| (struct {
            fn private(self: *Self) *P {
                return gobject.ext.impl_helpers.getPrivate(
                    self,
                    P,
                    P.offset,
                );
            }
        }).private else {};

        /// Get the class for the object.
        ///
        /// This _seems_ ugly and unsafe but this is how GObject
        /// works under the hood. From the [GObject Type System
        /// Concepts](https://docs.gtk.org/gobject/concepts.html) documentation:
        ///
        ///     Every object must define two structures: its class structure
        ///     and its instance structure. All class structures must contain
        ///     as first member a GTypeClass structure. All instance structures
        ///     must contain as first member a GTypeInstance structure.
        ///     …
        ///     These constraints allow the type system to make sure that
        ///     every object instance (identified by a pointer to the object’s
        ///     instance structure) contains in its first bytes a pointer to the
        ///     object’s class structure.
        ///     …
        ///     The C standard mandates that the first field of a C structure is
        ///     stored starting in the first byte of the buffer used to hold the
        ///     structure’s fields in memory. This means that the first field of
        ///     an instance of an object B is A’s first field which in turn is
        ///     GTypeInstance‘s first field which in turn is g_class, a pointer
        ///     to B’s class structure.
        ///
        /// This means that to access the class structure for an object you cast it
        /// to `*gobject.TypeInstance` and then access the `f_g_class` field.
        ///
        /// https://gitlab.gnome.org/GNOME/glib/-/blob/2c08654b62d52a31c4e4d13d7d85e12b989e72be/gobject/gtype.h#L555-571
        /// https://gitlab.gnome.org/GNOME/glib/-/blob/2c08654b62d52a31c4e4d13d7d85e12b989e72be/gobject/gtype.h#L2673
        ///
        pub fn getClass(self: *Self) ?*Self.Class {
            const type_instance: *gobject.TypeInstance = @ptrCast(self);
            return @ptrCast(type_instance.f_g_class orelse return null);
        }

        /// Define a virtual method. The `Self.Class` type must have a field
        /// named `name` which is a function pointer in the following form:
        ///
        ///   ?*const fn (*Self) callconv(.c) void
        ///
        /// The virtual method may take additional parameters and specify
        /// a non-void return type. The parameters and return type must be
        /// valid for the C calling convention.
        pub fn defineVirtualMethod(
            comptime name: [:0]const u8,
        ) type {
            return struct {
                pub fn call(
                    class: anytype,
                    object: *ClassInstance(@TypeOf(class)),
                    params: anytype,
                ) (fn_info.return_type orelse void) {
                    const func = @field(
                        gobject.ext.as(Self.Class, class),
                        name,
                    ).?;
                    @call(.auto, func, .{
                        gobject.ext.as(Self, object),
                    } ++ params);
                }

                pub fn implement(
                    class: anytype,
                    implementation: *const ImplementFunc(@TypeOf(class)),
                ) void {
                    @field(gobject.ext.as(
                        Self.Class,
                        class,
                    ), name) = @ptrCast(implementation);
                }

                /// The type info of the virtual method.
                const fn_info = fn_info: {
                    // This is broken down like this so its slightly more
                    // readable. We expect a field named "name" on the Class
                    // with the rough type of `?*const fn` and we need the
                    // function info.
                    const Field = @FieldType(Self.Class, name);
                    const opt = @typeInfo(Field).optional;
                    const ptr = @typeInfo(opt.child).pointer;
                    break :fn_info @typeInfo(ptr.child).@"fn";
                };

                /// The instance type for a class.
                fn ClassInstance(comptime T: type) type {
                    return @typeInfo(T).pointer.child.Instance;
                }

                /// The function type for implementations. This is the same type
                /// as the virtual method but the self parameter points to the
                /// target instead of the original class.
                fn ImplementFunc(comptime T: type) type {
                    var params: [fn_info.params.len]std.builtin.Type.Fn.Param = undefined;
                    @memcpy(&params, fn_info.params);
                    params[0].type = *ClassInstance(T);
                    return @Type(.{ .@"fn" = .{
                        .calling_convention = fn_info.calling_convention,
                        .is_generic = fn_info.is_generic,
                        .is_var_args = fn_info.is_var_args,
                        .return_type = fn_info.return_type,
                        .params = &params,
                    } });
                }
            };
        }

        /// A helper that creates a property that reads and writes a
        /// private field with only shallow copies. This is good for primitives
        /// such as bools, numbers, etc.
        pub fn privateShallowFieldAccessor(
            comptime name: []const u8,
        ) gobject.ext.Accessor(
            Self,
            @FieldType(Private.?, name),
        ) {
            return gobject.ext.privateFieldAccessor(
                Self,
                Private.?,
                &Private.?.offset,
                name,
            );
        }

        /// A helper that can be used to create a property that reads and
        /// writes a private boxed gobject field type.
        ///
        /// Reading the property will result in allocating a pointer and
        /// setting it will free the previous pointer.
        ///
        /// The object class (Self) must still free the private field
        /// in finalize!
        pub fn privateBoxedFieldAccessor(
            comptime name: []const u8,
        ) gobject.ext.Accessor(
            Self,
            @FieldType(Private.?, name),
        ) {
            return .{
                .getter = &struct {
                    fn get(self: *Self, value: *gobject.Value) void {
                        gobject.ext.Value.set(
                            value,
                            @field(private(self), name),
                        );
                    }
                }.get,
                .setter = &struct {
                    fn set(self: *Self, value: *const gobject.Value) void {
                        const priv = private(self);
                        if (@field(priv, name)) |v| {
                            ext.boxedFree(
                                @typeInfo(@TypeOf(v)).pointer.child,
                                v,
                            );
                        }

                        const T = @TypeOf(@field(priv, name));
                        @field(
                            priv,
                            name,
                        ) = gobject.ext.Value.dup(value, T);
                    }
                }.set,
            };
        }

        /// A helper that can be used to create a property that reads and
        /// writes a private field gobject field type (reference counted).
        ///
        /// Reading the property will result in taking a reference to the
        /// value and writing the property will unref the previous value.
        ///
        /// The object class (Self) must still free the private field
        /// in finalize!
        pub fn privateObjFieldAccessor(
            comptime name: []const u8,
        ) gobject.ext.Accessor(
            Self,
            @FieldType(Private.?, name),
        ) {
            return .{
                .getter = &struct {
                    fn get(self: *Self, value: *gobject.Value) void {
                        gobject.ext.Value.set(
                            value,
                            @field(private(self), name),
                        );
                    }
                }.get,
                .setter = &struct {
                    fn set(self: *Self, value: *const gobject.Value) void {
                        const priv = private(self);
                        if (@field(priv, name)) |v| v.unref();

                        const T = @TypeOf(@field(priv, name));
                        @field(
                            priv,
                            name,
                        ) = gobject.ext.Value.dup(value, T);
                    }
                }.set,
            };
        }

        /// A helper that can be used to create a property that reads and
        /// writes a private `?[:0]const u8` field type.
        ///
        /// Reading the property will result in a copy of the string
        /// and callers are responsible for freeing it.
        ///
        /// Writing the property will free the previous value and copy
        /// the new value into the private field.
        ///
        /// The object class (Self) must still free the private field
        /// in finalize!
        pub fn privateStringFieldAccessor(
            comptime name: []const u8,
        ) gobject.ext.Accessor(
            Self,
            @FieldType(Private.?, name),
        ) {
            const S = struct {
                fn getter(self: *Self) ?[:0]const u8 {
                    return @field(private(self), name);
                }

                fn setter(self: *Self, value: ?[:0]const u8) void {
                    const priv = private(self);
                    if (@field(priv, name)) |v| {
                        glib.free(@constCast(@ptrCast(v)));
                    }

                    // We don't need to copy this because it was already
                    // copied by the typedAccessor.
                    @field(priv, name) = value;
                }
            };

            return gobject.ext.typedAccessor(
                Self,
                ?[:0]const u8,
                .{
                    .getter = S.getter,
                    .getter_transfer = .none,
                    .setter = S.setter,
                    .setter_transfer = .full,
                },
            );
        }

        /// Common class functions.
        pub const Class = struct {
            pub fn as(class: *Self.Class, comptime T: type) *T {
                return gobject.ext.as(T, class);
            }

            /// Bind a template child to a private entry in the class.
            pub const bindTemplateChildPrivate = if (Private) |P| (struct {
                pub fn bindTemplateChildPrivate(
                    class: *Self.Class,
                    comptime name: [:0]const u8,
                    comptime options: gtk.ext.BindTemplateChildOptions,
                ) void {
                    gtk.ext.impl_helpers.bindTemplateChildPrivate(
                        class,
                        name,
                        P,
                        P.offset,
                        options,
                    );
                }
            }).bindTemplateChildPrivate else {};

            /// Bind a function pointer to a template callback symbol.
            pub fn bindTemplateCallback(
                class: *Self.Class,
                comptime name: [:0]const u8,
                comptime func: anytype,
            ) void {
                {
                    const ptr_ti = @typeInfo(@TypeOf(func));
                    if (ptr_ti != .pointer) {
                        @compileError("bound function must be a pointer type");
                    }
                    if (ptr_ti.pointer.size != .one) {
                        @compileError("bound function must be a pointer to a function");
                    }

                    const func_ti = @typeInfo(ptr_ti.pointer.child);
                    if (func_ti != .@"fn") {
                        @compileError("bound function must be a function pointer");
                    }
                    if (func_ti.@"fn".return_type == bool) {
                        // glib booleans are ints and returning a Zig bool type
                        // I think uses a byte and causes ABI issues.
                        @compileError("bound function must return c_int instead of bool");
                    }
                }

                gtk.Widget.Class.bindTemplateCallbackFull(
                    class.as(gtk.Widget.Class),
                    name,
                    @ptrCast(func),
                );
            }
        };
    };
}

test {
    @import("std").testing.refAllDecls(@This());
}
