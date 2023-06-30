const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const c = @import("c.zig");

pub fn createFontDescriptorsFromURL(url: *foundation.URL) ?*foundation.Array {
    return @ptrFromInt(@intFromPtr(c.CTFontManagerCreateFontDescriptorsFromURL(
        @ptrCast(url),
    )));
}

pub fn createFontDescriptorsFromData(data: *foundation.Data) ?*foundation.Array {
    return @ptrFromInt(@intFromPtr(c.CTFontManagerCreateFontDescriptorsFromData(
        @ptrCast(data),
    )));
}
