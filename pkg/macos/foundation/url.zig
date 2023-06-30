const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const c = @import("c.zig");

pub const URL = opaque {
    pub fn createWithString(str: *foundation.String, base: ?*URL) Allocator.Error!*URL {
        return CFURLCreateWithString(
            null,
            str,
            base,
        ) orelse error.OutOfMemory;
    }

    pub fn createWithFileSystemPath(
        path: *foundation.String,
        style: URLPathStyle,
        dir: bool,
    ) Allocator.Error!*URL {
        return @as(
            ?*URL,
            @ptrFromInt(@intFromPtr(c.CFURLCreateWithFileSystemPath(
                null,
                @ptrCast(path),
                @intFromEnum(style),
                if (dir) 1 else 0,
            ))),
        ) orelse error.OutOfMemory;
    }

    pub fn createStringByReplacingPercentEscapes(
        str: *foundation.String,
        escape: *foundation.String,
    ) Allocator.Error!*foundation.String {
        return CFURLCreateStringByReplacingPercentEscapes(
            null,
            str,
            escape,
        ) orelse return error.OutOfMemory;
    }

    pub fn release(self: *URL) void {
        foundation.CFRelease(self);
    }

    pub fn copyPath(self: *URL) ?*foundation.String {
        return CFURLCopyPath(self);
    }

    pub extern "c" fn CFURLCreateWithString(
        allocator: ?*anyopaque,
        url_string: *const anyopaque,
        base_url: ?*const anyopaque,
    ) ?*URL;
    pub extern "c" fn CFURLCopyPath(*URL) ?*foundation.String;
    pub extern "c" fn CFURLCreateStringByReplacingPercentEscapes(
        allocator: ?*anyopaque,
        original: *const anyopaque,
        escape: *const anyopaque,
    ) ?*foundation.String;
};

pub const URLPathStyle = enum(c_int) {
    posix = c.kCFURLPOSIXPathStyle,
    windows = c.kCFURLWindowsPathStyle,
};

test {
    const testing = std.testing;

    const str = try foundation.String.createWithBytes("http://www.example.com/foo", .utf8, false);
    defer str.release();

    const url = try URL.createWithString(str, null);
    defer url.release();

    {
        const path = url.copyPath().?;
        defer path.release();

        var buf: [128]u8 = undefined;
        const cstr = path.cstring(&buf, .utf8).?;
        try testing.expectEqualStrings("/foo", cstr);
    }
}

test "path" {
    const testing = std.testing;

    const str = try foundation.String.createWithBytes("foo/bar.ttf", .utf8, false);
    defer str.release();

    const url = try URL.createWithFileSystemPath(str, .posix, false);
    defer url.release();

    {
        const path = url.copyPath().?;
        defer path.release();

        var buf: [128]u8 = undefined;
        const cstr = path.cstring(&buf, .utf8).?;
        try testing.expectEqualStrings("foo/bar.ttf", cstr);
    }
}
