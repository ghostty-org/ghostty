const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const glib = @import("glib");
const gobject = @import("gobject");

/// A boxed type that holds a list of string slices.
pub const StringList = struct {
    arena: ArenaAllocator,
    strings: []const [:0]const u8,

    pub fn create(
        alloc: Allocator,
        strings: []const [:0]const u8,
    ) Allocator.Error!*StringList {
        var arena: ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();
        var stored = try arena_alloc.alloc([:0]const u8, strings.len);
        for (strings, 0..) |s, i| stored[i] = try arena_alloc.dupeZ(u8, s);

        const ptr = try alloc.create(StringList);
        errdefer alloc.destroy(ptr);
        ptr.* = .{ .arena = arena, .strings = stored };

        return ptr;
    }

    pub fn deinit(self: *StringList) void {
        self.arena.deinit();
    }

    pub fn destroy(self: *StringList) void {
        const alloc = self.arena.child_allocator;
        self.deinit();
        alloc.destroy(self);
    }

    /// Returns the general-purpose allocator used by this StringList.
    pub fn allocator(self: *const StringList) Allocator {
        return self.arena.child_allocator;
    }

    pub const getGObjectType = gobject.ext.defineBoxed(
        StringList,
        .{
            .name = "GhosttyStringList",
            .funcs = .{
                .copy = &struct {
                    fn copy(self: *StringList) callconv(.c) *StringList {
                        return StringList.create(
                            self.arena.child_allocator,
                            self.strings,
                        ) catch @panic("OOM");
                    }
                }.copy,
                .free = &struct {
                    fn free(self: *StringList) callconv(.c) void {
                        self.destroy();
                    }
                }.free,
            },
        },
    );
};

test "StringList create and destroy" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const input: []const [:0]const u8 = &.{ "hello", "world" };
    const list = try StringList.create(alloc, input);
    defer list.destroy();

    try testing.expectEqual(@as(usize, 2), list.strings.len);
    try testing.expectEqualStrings("hello", list.strings[0]);
    try testing.expectEqualStrings("world", list.strings[1]);
}

test "StringList create empty list" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const input: []const [:0]const u8 = &.{};
    const list = try StringList.create(alloc, input);
    defer list.destroy();

    try testing.expectEqual(@as(usize, 0), list.strings.len);
}

test "StringList boxedCopy and boxedFree" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const input: []const [:0]const u8 = &.{ "foo", "bar", "baz" };
    const original = try StringList.create(alloc, input);
    defer original.destroy();

    const copied: *StringList = @ptrCast(@alignCast(gobject.boxedCopy(
        StringList.getGObjectType(),
        original,
    )));
    defer gobject.boxedFree(StringList.getGObjectType(), copied);

    try testing.expectEqual(@as(usize, 3), copied.strings.len);
    try testing.expectEqualStrings("foo", copied.strings[0]);
    try testing.expectEqualStrings("bar", copied.strings[1]);
    try testing.expectEqualStrings("baz", copied.strings[2]);

    try testing.expect(original.strings.ptr != copied.strings.ptr);
}
