const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const FontDescriptor = @import("./font_descriptor.zig").FontDescriptor;
const c = @import("c");

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

pub fn createFontDescriptorFromData(data: *foundation.Data) ?*FontDescriptor {
    return @ptrFromInt(@intFromPtr(c.CTFontManagerCreateFontDescriptorFromData(
        @ptrCast(data),
    )));
}
