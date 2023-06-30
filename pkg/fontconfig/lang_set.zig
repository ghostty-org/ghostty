const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");

pub const LangSet = opaque {
    pub fn create() *LangSet {
        return @ptrCast(c.FcLangSetCreate());
    }

    pub fn destroy(self: *LangSet) void {
        c.FcLangSetDestroy(self.cval());
    }

    pub fn hasLang(self: *const LangSet, lang: [:0]const u8) bool {
        return c.FcLangSetHasLang(self.cvalConst(), lang.ptr) == c.FcTrue;
    }

    pub inline fn cval(self: *LangSet) *c.struct__FcLangSet {
        return @ptrCast(self);
    }

    pub inline fn cvalConst(self: *const LangSet) *const c.struct__FcLangSet {
        return @ptrCast(self);
    }
};

test "create" {
    const testing = std.testing;

    var fs = LangSet.create();
    defer fs.destroy();

    try testing.expect(!fs.hasLang("und-zsye"));
}
