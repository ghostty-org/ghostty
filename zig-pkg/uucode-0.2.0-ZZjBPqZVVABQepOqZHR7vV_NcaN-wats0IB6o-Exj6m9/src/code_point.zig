const std = @import("std");

pub const Iterator = struct {
    // This "i" is part of the documented API of this iterator, pointing to the
    // current location of the iterator in `code_points`.
    i: usize = 0,
    code_points: []const u21,

    const Self = @This();

    pub fn init(code_points: []const u21) Self {
        return .{
            .code_points = code_points,
        };
    }

    pub fn next(self: *Self) ?u21 {
        if (self.i >= self.code_points.len) return null;
        defer self.i += 1;
        return self.code_points[self.i];
    }

    pub fn peek(self: Self) ?u21 {
        if (self.i >= self.code_points.len) return null;
        return self.code_points[self.i];
    }
};

test "Iterator for emoji code points" {
    const code_points = &[_]u21{
        0x1F600, // 😀
        0x1F605, // 😅
        0x1F63B, // 😻
        0x1F47A, // 👺
    };

    var it = Iterator.init(code_points);
    try std.testing.expectEqual(0x1F600, it.next());
    try std.testing.expectEqual(1, it.i);
    try std.testing.expectEqual(0x1F605, it.peek());
    try std.testing.expectEqual(1, it.i);
    try std.testing.expectEqual(0x1F605, it.next());
    try std.testing.expectEqual(2, it.i);
    try std.testing.expectEqual(0x1F63B, it.next());
    try std.testing.expectEqual(3, it.i);
    try std.testing.expectEqual(0x1F47A, it.next());
    try std.testing.expectEqual(4, it.i);
    try std.testing.expectEqual(null, it.next());
    try std.testing.expectEqual(4, it.i);
}

/// Returns a custom iterator for a given Context type.
///
/// The Context must have the following methods:
///
/// * len(self: *Context) usize
/// * get(self: *Context, i: usize) ?u21 // or u21
///
/// If `get` returns null, the code continues incrementing `i` until it returns
/// a non-null result or `len` is reached, with `len` being called every
/// iteration to allow for `Context` to end early. If instead `get` has a
/// return type of non-optional `u21`, we don't loop.
pub fn CustomIterator(comptime Context: type) type {
    return struct {
        // This "i" is part of the documented API of this iterator, pointing to the
        // current location of the iterator in `code_points`.
        i: usize = 0,
        ctx: Context,

        const Self = @This();

        pub fn init(ctx: Context) Self {
            return .{
                .ctx = ctx,
            };
        }

        pub fn next(self: *Self) ?u21 {
            const getFn = @typeInfo(@TypeOf(@TypeOf(self.ctx).get)).@"fn";
            if (comptime getFn.return_type.? == ?u21) {
                while (self.i < self.ctx.len()) : (self.i += 1) {
                    const value = self.ctx.get(self.i);
                    if (value) |cp| {
                        @branchHint(.likely);
                        self.i += 1;
                        return cp;
                    }
                }
            } else {
                if (self.i < self.ctx.len()) {
                    defer self.i += 1;
                    return self.ctx.get(self.i);
                }
            }

            return null;
        }

        pub fn peek(self: Self) ?u21 {
            var it = self;
            return it.next();
        }
    };
}

test "CustomIterator for emoji code points" {
    const Wrapper = struct {
        cp: u21,
    };

    const code_points = &[_]Wrapper{
        .{ .cp = 0x1F600 }, // 😀
        .{ .cp = 0x1F605 }, // 😅
        .{ .cp = 0x1F63B }, // 😻
        .{ .cp = 0x1F47A }, // 👺
    };

    var it = CustomIterator(struct {
        points: []const Wrapper,

        pub fn len(self: @This()) usize {
            return self.points.len;
        }

        pub fn get(self: @This(), i: usize) u21 {
            return self.points[i].cp;
        }
    }).init(.{ .points = code_points });
    try std.testing.expectEqual(0x1F600, it.next());
    try std.testing.expectEqual(1, it.i);
    try std.testing.expectEqual(0x1F605, it.peek());
    try std.testing.expectEqual(1, it.i);
    try std.testing.expectEqual(0x1F605, it.next());
    try std.testing.expectEqual(2, it.i);
    try std.testing.expectEqual(0x1F63B, it.next());
    try std.testing.expectEqual(3, it.i);
    try std.testing.expectEqual(0x1F47A, it.next());
    try std.testing.expectEqual(4, it.i);
    try std.testing.expectEqual(null, it.next());
    try std.testing.expectEqual(4, it.i);
}

test "CustomIterator for emoji code points with gaps and optional get" {
    const Wrapper = struct {
        cp: ?u21,
    };

    const code_points = &[_]Wrapper{
        .{ .cp = 0x1F600 }, // 😀
        .{ .cp = null },
        .{ .cp = 0x1F605 }, // 😅
        .{ .cp = 0x1F63B }, // 😻
        .{ .cp = 0x1F47A }, // 👺
        .{ .cp = null },
        .{ .cp = null },
    };

    var it = CustomIterator(struct {
        points: []const Wrapper,

        pub fn len(self: @This()) usize {
            return self.points.len;
        }

        pub fn get(self: @This(), i: usize) ?u21 {
            return self.points[i].cp;
        }
    }).init(.{ .points = code_points });
    try std.testing.expectEqual(0x1F600, it.next());
    try std.testing.expectEqual(1, it.i);
    try std.testing.expectEqual(0x1F605, it.peek());
    try std.testing.expectEqual(1, it.i);
    try std.testing.expectEqual(0x1F605, it.next());
    try std.testing.expectEqual(3, it.i);
    try std.testing.expectEqual(0x1F63B, it.next());
    try std.testing.expectEqual(4, it.i);
    try std.testing.expectEqual(0x1F47A, it.next());
    try std.testing.expectEqual(5, it.i);
    try std.testing.expectEqual(null, it.next());
    try std.testing.expectEqual(7, it.i);
}
