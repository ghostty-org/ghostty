const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const text = @import("../text.zig");
const c = @import("c.zig");

pub const FontCollection = opaque {
    pub fn createFromAvailableFonts() Allocator.Error!*FontCollection {
        return @as(
            ?*FontCollection,
            @ptrFromInt(@intFromPtr(c.CTFontCollectionCreateFromAvailableFonts(null))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn createWithFontDescriptors(descs: *foundation.Array) Allocator.Error!*FontCollection {
        return @as(
            ?*FontCollection,
            @ptrFromInt(@intFromPtr(c.CTFontCollectionCreateWithFontDescriptors(
                @ptrCast(descs),
                null,
            ))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *FontCollection) void {
        c.CFRelease(self);
    }

    pub fn createMatchingFontDescriptors(self: *FontCollection) *foundation.Array {
        const result = c.CTFontCollectionCreateMatchingFontDescriptors(@ptrCast(self));
        if (result) |ptr| return @ptrFromInt(@intFromPtr(ptr));

        // If we have no results, we create an empty array. This is not
        // exactly matching the Mac API. We can fix this later if we want
        // but I chose this to make it slightly more Zig-like at the cost
        // of some memory in the rare case.
        return foundation.Array.create(anyopaque, &[_]*const anyopaque{}) catch unreachable;
    }
};

fn debugDumpList(list: *foundation.Array) !void {
    var i: usize = 0;
    while (i < list.getCount()) : (i += 1) {
        const desc = list.getValueAtIndex(text.FontDescriptor, i);
        {
            var buf: [128]u8 = undefined;
            const name = desc.copyAttribute(.name);
            defer name.release();
            const cstr = name.cstring(&buf, .utf8).?;

            var family_buf: [128]u8 = undefined;
            const family = desc.copyAttribute(.family_name);
            defer family.release();
            const family_cstr = family.cstring(&family_buf, .utf8).?;

            var buf2: [128]u8 = undefined;
            const url = desc.copyAttribute(.url);
            defer url.release();
            const path = path: {
                const blank = try foundation.String.createWithBytes("", .utf8, false);
                defer blank.release();

                const path = url.copyPath() orelse break :path "<no path>";
                defer path.release();

                const decoded = try foundation.URL.createStringByReplacingPercentEscapes(
                    path,
                    blank,
                );
                defer decoded.release();

                break :path decoded.cstring(&buf2, .utf8) orelse
                    "<path cannot be converted to string>";
            };

            std.log.warn("i={d} name={s} family={s} path={s}", .{ i, cstr, family_cstr, path });
        }
    }
}

test "collection" {
    const testing = std.testing;

    const v = try FontCollection.createFromAvailableFonts();
    defer v.release();

    const list = v.createMatchingFontDescriptors();
    defer list.release();

    try testing.expect(list.getCount() > 0);
}

test "from descriptors" {
    const testing = std.testing;

    const name = try foundation.String.createWithBytes("AppleColorEmoji", .utf8, false);
    defer name.release();

    const desc = try text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();

    var desc_arr = [_]*const text.FontDescriptor{desc};
    const arr = try foundation.Array.create(text.FontDescriptor, &desc_arr);
    defer arr.release();

    const v = try FontCollection.createWithFontDescriptors(arr);
    defer v.release();

    const list = v.createMatchingFontDescriptors();
    defer list.release();

    try testing.expect(list.getCount() > 0);

    // try debugDumpList(list);
}

test "from descriptors no match" {
    const testing = std.testing;

    const name = try foundation.String.createWithBytes("ThisShouldNeverExist", .utf8, false);
    defer name.release();

    const desc = try text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();

    var desc_arr = [_]*const text.FontDescriptor{desc};
    const arr = try foundation.Array.create(text.FontDescriptor, &desc_arr);
    defer arr.release();

    const v = try FontCollection.createWithFontDescriptors(arr);
    defer v.release();

    const list = v.createMatchingFontDescriptors();
    defer list.release();

    try testing.expect(list.getCount() == 0);

    //try debugDumpList(list);
}
