const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const c = @import("c.zig");

pub fn createFontDescriptorsFromURL(url: *foundation.URL) ?*foundation.Array {
    return @as(
        ?*foundation.Array,
        @ptrFromInt(@intFromPtr(c.CTFontManagerCreateFontDescriptorsFromURL(
            @as(c.CFURLRef, @ptrCast(url)),
        ))),
    );
}

pub fn createFontDescriptorsFromData(data: *foundation.Data) ?*foundation.Array {
    return @as(
        ?*foundation.Array,
        @ptrFromInt(@intFromPtr(c.CTFontManagerCreateFontDescriptorsFromData(
            @as(c.CFDataRef, @ptrCast(data)),
        ))),
    );
}
