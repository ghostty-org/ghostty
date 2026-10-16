// Standalone mirror of the pickEglIdCast helper in pkg/opengl/egl.zig.
// Kept for fast feedback while the real test_exe runs in background on the
// 16GB host. Mirrors Zig 0.16 .pointer / .int / .comptime_int / else dispatch
// with synthetic representative types. See SESSION.md for the audit trail.

const std = @import("std");
const testing = std.testing;

const StubGetPlatformDisplay = fn (
    platform: u32,
    native_display: ?*anyopaque,
    attribs: ?[*]const u8,
) callconv(.c) ?*anyopaque;

fn stubGetPlatformDisplay(
    _: u32,
    native_display: ?*anyopaque,
    _: ?[*]const u8,
) callconv(.c) ?*anyopaque {
    return native_display;
}

fn pickEglIdCast(
    comptime T: type,
    id: T,
    platform: u32,
    attribs: ?[*]const u8,
    get: StubGetPlatformDisplay,
) ?*anyopaque {
    return switch (@typeInfo(T)) {
        .pointer => get(platform, @ptrCast(id), attribs),
        .int, .comptime_int => get(
            platform,
            @ptrFromInt(@as(usize, @intCast(id))),
            attribs,
        ),
        else => @compileError(
            "pickEglIdCast: unsupported EGLNativeDisplayType shape; " ++
                "expected .pointer or .int/.comptime_int per eglplatform.h",
        ),
    };
}

fn comptimeArmName(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .pointer => "pointer",
        .int => "int",
        .comptime_int => "comptime_int",
        else => "rejected",
    };
}

// ---- arm selection ----

test "arm selection: integer types" {
    try testing.expectEqualStrings("int", comptimeArmName(c_int));
    try testing.expectEqualStrings("int", comptimeArmName(i32));
    try testing.expectEqualStrings("int", comptimeArmName(u8));
    try testing.expectEqualStrings("int", comptimeArmName(usize));
    try testing.expectEqualStrings("comptime_int", comptimeArmName(comptime_int));
}

test "arm selection: pointer types" {
    try testing.expectEqualStrings("pointer", comptimeArmName(*u8));
    try testing.expectEqualStrings("pointer", comptimeArmName(*anyopaque));
    try testing.expectEqualStrings("pointer", comptimeArmName([*]u8));
}

test "arm selection: optional types rejected" {
    try testing.expectEqualStrings("rejected", comptimeArmName(?*u8));
    try testing.expectEqualStrings("rejected", comptimeArmName(?c_int));
    try testing.expectEqualStrings("rejected", comptimeArmName(@TypeOf(null)));
    try testing.expectEqualStrings("rejected", comptimeArmName(struct {}));
}

// ---- cast shape ----

test "integer arm: round-trip 42" {
    const id: c_int = 42;
    const got = pickEglIdCast(c_int, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == @as(?*anyopaque, @ptrFromInt(42)));
}

test "integer arm: 0 maps to null" {
    const id: c_int = 0;
    const got = pickEglIdCast(c_int, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == null);
}

test "integer arm: positive c_int round-trips (max boundary)" {
    const id: c_int = 0x7FFFFFFF;
    const got = pickEglIdCast(c_int, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == @as(?*anyopaque, @ptrFromInt(0x7FFFFFFF)));
}

test "integer arm: usize round-trip" {
    const id: usize = 0xDEADBEEF;
    const got = pickEglIdCast(usize, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == @as(?*anyopaque, @ptrFromInt(0xDEADBEEF)));
}

test "pointer arm: *u8 no-op" {
    const id: *u8 = @ptrFromInt(0x1000);
    const got = pickEglIdCast(*u8, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == @as(?*anyopaque, @ptrCast(id)));
    try testing.expect(@intFromPtr(got.?) == 0x1000);
}

test "pointer arm: *anyopaque no-op" {
    const id: *anyopaque = @ptrFromInt(0xCAFE);
    const got = pickEglIdCast(*anyopaque, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == id);
}

test "pointer arm: many-pointer [*]u8" {
    const id: [*]u8 = @ptrFromInt(0xBEEF);
    const got = pickEglIdCast([*]u8, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(@intFromPtr(got.?) == 0xBEEF);
}

test "pointer arm: 0x1 preserved (no null-mapping on pointer arm)" {
    const id: *u8 = @ptrFromInt(0x1);
    const got = pickEglIdCast(*u8, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == @as(?*anyopaque, @ptrCast(id)));
    try testing.expect(@intFromPtr(got.?) == 0x1);
}

test "comptime_int arm: literal" {
    const got = comptime pickEglIdCast(comptime_int, 7, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == @as(?*anyopaque, @ptrFromInt(7)));
}
