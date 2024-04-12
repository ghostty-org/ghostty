const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const js = @import("main.zig");
const ext = @import("extern.zig");

/// Only used with Value.init to denote a string type.
///
/// This is NOT a JS string. This is just a sentinel type so that we can
/// differentiate a slice and a "string" when trying to convert a Zig
/// value into a JS value.
pub const String = struct {
    ptr: [*]const u8,
    len: usize,

    /// Initialize a string from one of the many string representations in Zig.
    pub fn init(x: anytype) String {
        switch (@typeInfo(@TypeOf(x))) {
            .Pointer => |p| switch (p.size) {
                .One => return .{
                    .ptr = x,
                    .len = @typeInfo(p.child).Array.len,
                },

                .Slice => {
                    assert(p.child == u8);
                    return .{ .ptr = x.ptr, .len = x.len };
                },

                else => {},
            },

            else => {},
        }

        const T = @TypeOf(x);
        @compileLog(T, @typeInfo(T));
        @compileError("unsupported type");
    }

    test "constant string" {
        const testing = std.testing;
        const raw = "hello!";
        const v = init(raw);
        try testing.expectEqual(@as([*]const u8, @ptrCast(raw)), v.ptr);
        try testing.expectEqual(raw.len, v.len);
    }

    test "slice string" {
        const testing = std.testing;
        const raw = @as([]const u8, "hello!");
        const v = init(raw);
        try testing.expectEqual(@as([*]const u8, @ptrCast(raw)), v.ptr);
        try testing.expectEqual(raw.len, v.len);
    }
};

/// Only used with Value.init to denote an undefined type.
pub const Undefined = struct {};

/// A value represents a JS value. This is the low-level "untyped" interface
/// to any generic JS value. It is more ergonomic to use the higher level
/// wrappers such as Object.
pub const Value = enum(u64) {
    // Predefined values, they're all self-explanatory except maybe for
    // "runtime". The "runtime" value gives access to the "this" value
    // for the ZigJS JS class. This makes it possible to access the memory
    // for example.
    nan = @bitCast(js.Ref.nan),
    null = @bitCast(js.Ref.null),
    true = @bitCast(js.Ref.true),
    false = @bitCast(js.Ref.false),
    undefined = @bitCast(js.Ref.undefined),
    global = @bitCast(js.Ref.global),
    runtime = @bitCast(js.Ref.runtime),

    _,

    /// Converts a Zig value to a JS value.
    ///
    /// In order to tell the difference between a "string" and an array, strings
    /// must be wrapped in the String type prior to calling this. Otherwise,
    /// an array is assumed. If a string is created, the bytes pointed to by the
    /// string can be freed after this call -- they are copied to the JS side.
    ///
    /// Objects are created by passing in the empty Object struct.
    pub fn init(x: anytype) Value {
        return switch (@typeInfo(@TypeOf(x))) {
            .Null => .null,
            .Bool => if (x) .true else .false,
            .ComptimeInt => init(@as(f64, @floatFromInt(x))),
            .ComptimeFloat => init(@as(f64, @floatCast(x))),
            .Float => |t| float: {
                if (t.bits > 64) @compileError("Value only supports floats up to 64 bits");
                if (std.math.isNan(x)) break :float .nan;
                break :float @as(Value, @enumFromInt(@as(u64, @bitCast(@as(f64, @floatCast(x))))));
            },

            // All numbers in JS are 64-bit floats, so we try the conversion
            // here and accept a runtime/compile-time error if x is invalid.
            .Int => init(@as(f64, @floatFromInt(x))),

            .Pointer => |p| switch (p.size) {
                .One, .Many => init(@intFromPtr(x)),
                else => unreachable,
            },

            else => switch (@TypeOf(x)) {
                Undefined => .undefined,
                js.Value => x,
                js.Object => blk: {
                    var result: u64 = undefined;
                    ext.valueObjectCreate(&result);
                    break :blk @enumFromInt(result);
                },
                String => blk: {
                    var result: u64 = undefined;
                    ext.valueStringCreate(&result, x.ptr, x.len);
                    break :blk @enumFromInt(result);
                },
                else => unreachable,
            },
        };
    }

    /// Deinitializes the value, allowing the JS environment to GC the value.
    pub fn deinit(self: Value) void {
        // We avoid releasing values that aren't releasable. This avoids
        // crossing the js/wasm boundary for a bit of performance.
        if (self.ref().isReleasable()) ext.valueDeinit(self.ref().id);
    }

    /// Get the value of a property of an object.
    pub fn get(self: Value, n: []const u8) !Value {
        if (self.typeOf() != .object) return js.Error.InvalidType;
        var result: u64 = undefined;
        ext.valueGet(&result, self.ref().id, n.ptr, n.len);
        return @enumFromInt(result);
    }

    /// Set the value of a property on an object.
    pub fn set(self: Value, n: []const u8, v: Value) !void {
        if (self.typeOf() != .object) return js.Error.InvalidType;
        ext.valueSet(self.ref().id, n.ptr, n.len, &@as(u64, @bitCast(v.ref())));
    }

    /// Call this value as a function.
    pub fn apply(self: Value, this: Value, args: []Value) !Value {
        if (self.typeOf() != .function) return js.Error.InvalidType;
        var result: u64 = undefined;
        ext.funcApply(
            &result,
            self.ref().id,
            &@as(u64, @bitCast(this.ref())),
            @ptrCast(args.ptr),
            args.len,
        );
        return @enumFromInt(result);
    }

    /// Call "new" on this value like a constructor.
    pub fn new(self: Value, args: []Value) !Value {
        if (self.typeOf() != .function) return js.Error.InvalidType;
        var result: u64 = undefined;
        ext.valueNew(
            &result,
            self.ref().id,
            @ptrCast(args.ptr),
            args.len,
        );
        return @enumFromInt(result);
    }

    /// Returns the bool value if this is a boolean.
    pub fn boolean(self: Value) !f64 {
        if (self.typeOf() != .boolean) return js.Error.InvalidType;
        return self == .true;
    }

    /// Returns the float value if this is a number.
    pub fn float(self: Value) !f64 {
        if (self.typeOf() != .number) return js.Error.InvalidType;
        return @bitCast(@intFromEnum(self));
    }

    /// Returns the UTF-8 encoded string value. The resulting value must be
    /// freed by the caller.
    pub fn string(self: Value, alloc: Allocator) ![]u8 {
        if (self.typeOf() != .string) return js.Error.InvalidType;

        // Get the length and allocate our pointer
        const len = ext.valueStringLen(self.ref().id);
        const buf = try alloc.alloc(u8, @intCast(len));
        errdefer alloc.free(buf);

        // Copy the string into the buffer
        ext.valueStringCopy(self.ref().id, buf.ptr, buf.len);

        return buf;
    }

    /// Returns the type of this value.
    pub fn typeOf(self: Value) js.Type {
        return self.ref().typeOf();
    }

    inline fn ref(self: Value) js.Ref {
        return @bitCast(@intFromEnum(self));
    }
};

test "String" {
    _ = String;
}

test "Value.init: undefined" {
    const testing = std.testing;
    try testing.expectEqual(Value.undefined, Value.init(Undefined{}));
}

test "Value.init: null" {
    const testing = std.testing;
    try testing.expectEqual(Value.null, Value.init(null));
}

test "Value.init: pointers" {
    const testing = std.testing;
    var x: u64 = undefined;
    const v = Value.init(&x);
    try testing.expectEqual(js.Type.number, v.typeOf());
}

test "Value.init: bools" {
    const testing = std.testing;
    try testing.expectEqual(Value.true, Value.init(true));
    try testing.expectEqual(Value.false, Value.init(false));
}

test "Value.init: floats" {
    const testing = std.testing;
    try testing.expectEqual(Value.nan, Value.init(std.math.nan(f16)));
    try testing.expectEqual(Value.nan, Value.init(std.math.nan(f32)));
    try testing.expectEqual(Value.nan, Value.init(std.math.nan(f64)));

    {
        const v = Value.init(1.234);
        try testing.expectEqual(js.Type.number, v.typeOf());
        try testing.expectEqual(@as(f64, 1.234), try v.float());
    }
}

test "Value.init: ints" {
    const testing = std.testing;

    {
        const v = Value.init(14);
        try testing.expectEqual(js.Type.number, v.typeOf());
        try testing.expectEqual(@as(f64, 14), try v.float());
    }
}

test "Value.init: strings" {
    const testing = std.testing;
    const alloc = testing.allocator;
    defer ext.deinit();

    {
        const str = "hello!";
        const v = Value.init(String{ .ptr = @ptrCast(str), .len = str.len });
        defer v.deinit();
        try testing.expectEqual(js.Type.string, v.typeOf());

        const copy = try v.string(alloc);
        defer alloc.free(copy);
        try testing.expectEqualStrings(str, copy);
    }
}

test "Value: objects" {
    const testing = std.testing;
    //const alloc = testing.allocator;
    defer ext.deinit();

    const root = Value.init(js.Object{ .value = undefined });
    defer root.deinit();
    try testing.expectEqual(js.Type.object, root.typeOf());

    try root.set("count", Value.init(42));

    const count = try root.get("count");
    try testing.expectEqual(@as(f64, 42), try count.float());
}
