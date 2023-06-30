const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");
const CharSet = @import("main.zig").CharSet;
const LangSet = @import("main.zig").LangSet;
const Matrix = @import("main.zig").Matrix;
const Range = @import("main.zig").Range;

pub const Type = enum(c_int) {
    unknown = c.FcTypeUnknown,
    void = c.FcTypeVoid,
    integer = c.FcTypeInteger,
    double = c.FcTypeDouble,
    string = c.FcTypeString,
    bool = c.FcTypeBool,
    matrix = c.FcTypeMatrix,
    char_set = c.FcTypeCharSet,
    ft_face = c.FcTypeFTFace,
    lang_set = c.FcTypeLangSet,
    range = c.FcTypeRange,
};

pub const Value = union(Type) {
    unknown: void,
    void: void,
    integer: i32,
    double: f64,
    string: [:0]const u8,
    bool: bool,
    matrix: *const Matrix,
    char_set: *const CharSet,
    ft_face: *anyopaque,
    lang_set: *const LangSet,
    range: *const Range,

    pub fn init(cvalue: *c.struct__FcValue) Value {
        return switch (@as(Type, @enumFromInt(cvalue.type))) {
            .unknown => .{ .unknown = {} },
            .void => .{ .void = {} },
            .string => .{ .string = std.mem.sliceTo(cvalue.u.s, 0) },
            .integer => .{ .integer = @intCast(cvalue.u.i) },
            .double => .{ .double = cvalue.u.d },
            .bool => .{ .bool = cvalue.u.b == c.FcTrue },
            .matrix => .{ .matrix = @ptrCast(cvalue.u.m) },
            .char_set => .{ .char_set = @ptrCast(cvalue.u.c) },
            .ft_face => .{ .ft_face = @ptrCast(cvalue.u.f) },
            .lang_set => .{ .lang_set = @ptrCast(cvalue.u.l) },
            .range => .{ .range = @ptrCast(cvalue.u.r) },
        };
    }

    pub fn cval(self: Value) c.struct__FcValue {
        return .{
            .type = @intFromEnum(std.meta.activeTag(self)),
            .u = switch (self) {
                .unknown => undefined,
                .void => undefined,
                .integer => |v| .{ .i = @intCast(v) },
                .double => |v| .{ .d = v },
                .string => |v| .{ .s = v.ptr },
                .bool => |v| .{ .b = if (v) c.FcTrue else c.FcFalse },
                .matrix => |v| .{ .m = @ptrCast(v) },
                .char_set => |v| .{ .c = @ptrCast(v) },
                .ft_face => |v| .{ .f = v },
                .lang_set => |v| .{ .l = @ptrCast(v) },
                .range => |v| .{ .r = @ptrCast(v) },
            },
        };
    }
};

pub const ValueBinding = enum(c_int) {
    weak = c.FcValueBindingWeak,
    strong = c.FcValueBindingStrong,
    same = c.FcValueBindingSame,
};
