const builtin = @import("builtin");

const page = @import("page.zig");
pub const PageList = @import("PageList.zig");
pub const Terminal = @import("Terminal.zig");
pub const Page = page.Page;

test {
    @import("std").testing.refAllDecls(@This());

    // todo: make top-level imports
    _ = @import("bitmap_allocator.zig");
    _ = @import("hash_map.zig");
    _ = @import("page.zig");
    _ = @import("PageList.zig");
    _ = @import("Screen.zig");
    _ = @import("point.zig");
    _ = @import("size.zig");
    _ = @import("style.zig");
}
