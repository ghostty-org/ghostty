const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");

pub const CharSet = opaque {
    pub fn create() *CharSet {
        return @ptrCast(c.FcCharSetCreate());
    }

    pub fn destroy(self: *CharSet) void {
        c.FcCharSetDestroy(self.cval());
    }

    pub fn addChar(self: *CharSet, cp: u32) bool {
        return c.FcCharSetAddChar(self.cval(), cp) == c.FcTrue;
    }

    pub fn hasChar(self: *const CharSet, cp: u32) bool {
        return c.FcCharSetHasChar(self.cvalConst(), cp) == c.FcTrue;
    }

    pub inline fn cval(self: *CharSet) *c.struct__FcCharSet {
        return @ptrCast(self);
    }

    pub inline fn cvalConst(self: *const CharSet) *const c.struct__FcCharSet {
        return @ptrCast(self);
    }
};

test "create" {
    const testing = std.testing;

    var fs = CharSet.create();
    defer fs.destroy();

    try testing.expect(!fs.hasChar(0x20));
    try testing.expect(fs.addChar(0x20));
    try testing.expect(fs.hasChar(0x20));
}
