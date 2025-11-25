const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

pub const LangSet = opaque {
    pub fn create() *LangSet {
        return @ptrCast(c.FcLangSetCreate());
    }

    pub fn destroy(self: *LangSet) void {
        c.FcLangSetDestroy(self.cval());
    }

    pub fn addLang(self: *LangSet, lang: [:0]const u8) bool {
        return c.FcLangSetAdd(self.cval(), lang.ptr) == c.FcTrue;
    }

    pub fn hasLang(self: *const LangSet, lang: [:0]const u8) bool {
        return c.FcLangSetHasLang(self.cvalConst(), lang.ptr) == c.FcLangEqual;
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

test "hasLang exact match" {
    const testing = std.testing;

    // Test exact match: langset with "en-US" should return true for "en-US"
    var fs = LangSet.create();
    defer fs.destroy();
    try testing.expect(fs.addLang("en-US"));
    try testing.expect(fs.hasLang("en-US"));

    // Test exact match: langset with "und-zsye" should return true for "und-zsye"
    var fs_emoji = LangSet.create();
    defer fs_emoji.destroy();
    try testing.expect(fs_emoji.addLang("und-zsye"));
    try testing.expect(fs_emoji.hasLang("und-zsye"));

    // Test mismatch: langset with "en-US" should return false for "fr"
    try testing.expect(!fs.hasLang("fr"));

    // Test partial match: langset with "en-US" should return false for "en-GB"
    // (different territory, but we only want exact matches)
    try testing.expect(!fs.hasLang("en-GB"));
}
