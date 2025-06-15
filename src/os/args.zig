const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");

/// Returns an iterator over the command line arguments. This may or may
/// not allocate depending on the platform.
///
/// For Zig-aware readers: this is the same as std.process.argsWithAllocator
/// but handles macOS using NSProcessInfo instead of libc argc/argv.
pub fn iterator(allocator: Allocator) ArgIterator.InitError!ArgIterator {
    //if (true) return try std.process.argsWithAllocator(allocator);
    return .initWithAllocator(allocator);
}

/// Duck-typed to std.process.ArgIterator
pub const ArgIterator = switch (builtin.os.tag) {
    .macos => IteratorMacOS,
    else => std.process.ArgIterator,
};

/// This is an ArgIterator (duck-typed for std.process.ArgIterator) for
/// NSApplicationMain-based applications on macOS. It uses NSProcessInfo to
/// get the command line arguments since libc argc/argv pointers are not
/// valid.
///
/// I believe this should work for all macOS applications even if
/// NSApplicationMain is not used, but I haven't tested that so I'm not
/// sure. If/when libghostty is ever used outside of NSApplicationMain
/// then we can revisit this.
const IteratorMacOS = struct {
    alloc: Allocator,
    index: usize,
    count: usize,
    buf: [:0]u8,
    args: objc.Object,

    pub const InitError = Allocator.Error;

    pub fn initWithAllocator(alloc: Allocator) InitError!IteratorMacOS {
        const NSProcessInfo = objc.getClass("NSProcessInfo").?;
        const info = NSProcessInfo.msgSend(objc.Object, objc.sel("processInfo"), .{});
        const args = info.getProperty(objc.Object, "arguments");
        errdefer args.release();

        // Determine our maximum length so we can allocate the buffer to
        // fit all values.
        var max: usize = 0;
        const count: usize = @intCast(args.getProperty(c_ulong, "count"));
        for (0..count) |i| {
            const nsstr = args.msgSend(
                objc.Object,
                objc.sel("objectAtIndex:"),
                .{@as(c_ulong, @intCast(i))},
            );

            const maxlen: usize = @intCast(nsstr.msgSend(
                c_ulong,
                objc.sel("maximumLengthOfBytesUsingEncoding:"),
                .{@as(c_ulong, 4)},
            ));

            max = @max(max, maxlen);
        }

        // Allocate our buffer. We add 1 for the null terminator.
        const buf = try alloc.allocSentinel(u8, max, 0);
        errdefer alloc.free(buf);

        return .{
            .alloc = alloc,
            .index = 0,
            .count = count,
            .buf = buf,
            .args = args,
        };
    }

    pub fn deinit(self: *IteratorMacOS) void {
        self.alloc.free(self.buf);

        // Note: we don't release self.args because it is a pointer copy
        // not a retained object.
    }

    pub fn next(self: *IteratorMacOS) ?[:0]const u8 {
        if (self.index == self.count) return null;

        // NSString. No release because not a copy.
        const nsstr = self.args.msgSend(
            objc.Object,
            objc.sel("objectAtIndex:"),
            .{@as(c_ulong, @intCast(self.index))},
        );
        self.index += 1;

        // Convert to string using getCString. Our buffer should always
        // be big enough because we precomputed the maximum length.
        if (!nsstr.msgSend(
            bool,
            objc.sel("getCString:maxLength:encoding:"),
            .{
                @as([*]u8, @ptrCast(self.buf.ptr)),
                @as(c_ulong, @intCast(self.buf.len)),
                @as(c_ulong, 4), // NSUTF8StringEncoding
            },
        )) {
            // This should never happen... if it does, we just return empty.
            return "";
        }

        return std.mem.sliceTo(self.buf, 0);
    }

    pub fn skip(self: *IteratorMacOS) bool {
        if (self.index == self.count) return false;
        self.index += 1;
        return true;
    }
};

test "args" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var iter = try iterator(alloc);
    defer iter.deinit();
    try testing.expect(iter.next().?.len > 0);
}
