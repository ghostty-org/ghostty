const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const c = @import("c.zig");

pub const Number = opaque {
    pub fn create(
        comptime type_: NumberType,
        value: *const type_.ValueType(),
    ) Allocator.Error!*Number {
        return @as(?*Number, @ptrFromInt(@intFromPtr(c.CFNumberCreate(
            null,
            @intFromEnum(type_),
            value,
        )))) orelse Allocator.Error.OutOfMemory;
    }

    pub fn getValue(self: *Number, comptime t: NumberType, ptr: *t.ValueType()) bool {
        return c.CFNumberGetValue(
            @ptrCast(self),
            @intFromEnum(t),
            ptr,
        ) == 1;
    }

    pub fn release(self: *Number) void {
        c.CFRelease(self);
    }
};

pub const NumberType = enum(c.CFNumberType) {
    sint8 = c.kCFNumberSInt8Type,
    sint16 = c.kCFNumberSInt16Type,
    sint32 = c.kCFNumberSInt32Type,
    sint64 = c.kCFNumberSInt64Type,
    float32 = c.kCFNumberFloat32Type,
    float64 = c.kCFNumberFloat64Type,
    char = c.kCFNumberCharType,
    short = c.kCFNumberShortType,
    int = c.kCFNumberIntType,
    long = c.kCFNumberLongType,
    long_long = c.kCFNumberLongLongType,
    float = c.kCFNumberFloatType,
    double = c.kCFNumberDoubleType,
    cf_index = c.kCFNumberCFIndexType,
    ns_integer = c.kCFNumberNSIntegerType,
    cg_float = c.kCFNumberCGFloatType,

    pub fn ValueType(comptime self: NumberType) type {
        return switch (self) {
            .sint8 => i8,
            .sint16 => i16,
            .sint32 => i32,
            .sint64 => i64,
            .float32 => f32,
            .float64 => f64,
            .char => u8,
            .short => c_short,
            .int => c_int,
            .long => c_long,
            .long_long => c_longlong,
            .float => f32,
            .double => f64,
            else => unreachable, // TODO
        };
    }
};

test {
    const testing = std.testing;

    const inner: i8 = 42;
    const v = try Number.create(.sint8, &inner);
    defer v.release();

    var result: i8 = undefined;
    try testing.expect(v.getValue(.sint8, &result));
    try testing.expectEqual(result, inner);
}
