const std = @import("std");
const c = @import("c.zig");
const Property = @import("main.zig").Property;

pub const ObjectSet = opaque {
    pub fn create() *ObjectSet {
        return @as(*ObjectSet, @ptrCast(c.FcObjectSetCreate()));
    }

    pub fn destroy(self: *ObjectSet) void {
        c.FcObjectSetDestroy(self.cval());
    }

    pub fn add(self: *ObjectSet, p: Property) bool {
        return c.FcObjectSetAdd(self.cval(), p.cval().ptr) == c.FcTrue;
    }

    pub inline fn cval(self: *ObjectSet) *c.struct__FcObjectSet {
        return @as(
            *c.struct__FcObjectSet,
            @ptrCast(@alignCast(@alignOf(c.struct__FcObjectSet), self)),
        );
    }
};

test "create" {
    const testing = std.testing;

    var os = ObjectSet.create();
    defer os.destroy();

    try testing.expect(os.add(.family));
}
