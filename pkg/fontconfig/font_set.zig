const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");
const Pattern = @import("pattern.zig").Pattern;

pub const FontSet = opaque {
    pub fn create() *FontSet {
        return @ptrCast(c.FcFontSetCreate());
    }

    pub fn destroy(self: *FontSet) void {
        c.FcFontSetDestroy(self.cval());
    }

    pub fn fonts(self: *FontSet) []*Pattern {
        const empty: [0]*Pattern = undefined;
        const s = self.cval();
        if (s.fonts == null) return &empty;
        const ptr: [*]*Pattern = @ptrCast(@alignCast(s.fonts));
        const len: usize = @intCast(s.nfont);
        return ptr[0..len];
    }

    pub fn add(self: *FontSet, pat: *Pattern) bool {
        return c.FcFontSetAdd(self.cval(), pat.cval()) == c.FcTrue;
    }

    pub fn print(self: *FontSet) void {
        c.FcFontSetPrint(self.cval());
    }

    pub inline fn cval(self: *FontSet) *c.struct__FcFontSet {
        return @ptrCast(@alignCast(self));
    }
};

test "create" {
    const testing = std.testing;

    var fs = FontSet.create();
    defer fs.destroy();

    try testing.expectEqual(@as(usize, 0), fs.fonts().len);
}
